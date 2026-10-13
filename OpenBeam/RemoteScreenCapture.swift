//
//  RemoteScreenCapture.swift
//  OpenBeam
//
//  Captures one display for a remote screen session with ScreenCaptureKit, and
//  reports each new image together with the regions that changed in it.
//

import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import os

private let captureLog = Logger(subsystem: "com.openbeam.remotescreen", category: "capture")

final class RemoteScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame {
        let buffer: CVPixelBuffer
        let captureHostNs: UInt64
        /// Changed regions in the buffer's pixels; nil when ScreenCaptureKit gave none.
        let dirtyRects: [CGRect]?
    }

    /// On the capture queue, once per new image.
    var onFrame: ((Frame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }
    /// When the stream ends by itself, for example because the display went away.
    var onStop: (() -> Void)? {
        get { lock.withLock { _onStop } }
        set { lock.withLock { _onStop = newValue } }
    }

    private let queue = DispatchQueue(label: "com.openbeam.remotescreen.capture", qos: .userInteractive)

    // Behind `lock`: the session ends from its own threads while ScreenCaptureKit
    // reads the callbacks on the capture queue and reports a stop on its own,
    // and a closure or an SCStream swapped mid-read can be released twice.
    private let lock = NSLock()
    private var stream: SCStream?
    private var _onFrame: ((Frame) -> Void)?
    private var _onStop: (() -> Void)?
    /// Bumped by stop(), so a start() still awaiting ScreenCaptureKit knows
    /// its stream is no longer wanted rather than leaving it running.
    private var generation = 0
    /// Set by close(): no stream is installed after it, whenever start() began.
    private var closed = false

    /// The largest size inside `maxWidth` × `maxHeight` with the display's aspect
    /// ratio, never above the display's own pixels, both sides even.
    static func fittedSize(display: CGDirectDisplayID, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        let pixels = pixelSize(of: display)
        // At least 1 on every side: a display going offline reads 0×0, the
        // limits come from the viewer, and 0/0 is a NaN that Int() traps on.
        let pixelWidth = Double(max(pixels.width, 1)), pixelHeight = Double(max(pixels.height, 1))
        let limitW = Double(min(max(maxWidth, 1), RemoteScreen.maxDimension)), limitH = Double(min(max(maxHeight, 1), RemoteScreen.maxDimension))
        let scale = min(limitW / pixelWidth, limitH / pixelHeight, 1)
        func even(_ v: Double) -> Int { max(2, Int(v) & ~1) }
        return (even(pixelWidth * scale), even(pixelHeight * scale))
    }

    /// A display's own pixels in its current mode (6192×2592 for a HiDPI desktop
    /// that looks like 3096×1296).
    static func pixelSize(of display: CGDirectDisplayID) -> (width: Int, height: Int) {
        let mode = CGDisplayCopyDisplayMode(display)
        return (mode?.pixelWidth ?? Int(CGDisplayPixelsWide(display)), mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(display)))
    }

    func start(display displayID: CGDirectDisplayID, width: Int, height: Int) async throws {
        let wanted = lock.withLock { generation }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RemoteScreenError.protocolViolation("display \(displayID) is not available to capture")
        }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        // A ceiling above any display's refresh: at exactly 1/refresh, captures that
        // land a hair early are dropped, which cost ~10 fps and ~5 ms in measurements.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        config.showsCursor = true
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let current = lock.withLock { () -> Bool in
            guard !closed, generation == wanted else { return false }
            self.stream = stream
            return true
        }
        guard current else {
            try? await stream.stopCapture()
            return
        }
        let mode = CGDisplayCopyDisplayMode(displayID)
        captureLog.info("capturing display \(displayID, privacy: .public) (\(mode?.pixelWidth ?? 0, privacy: .public)×\(mode?.pixelHeight ?? 0, privacy: .public) px @ \(mode?.refreshRate ?? 0, privacy: .public) Hz) at \(width, privacy: .public)×\(height, privacy: .public)")
    }

    /// Stops for good: the session is over. Unlike stop(), which a restart
    /// follows, it also turns away a start() that read its generation after it.
    func close() {
        lock.withLock { closed = true }
        stop()
    }

    func stop() {
        let stopped = lock.withLock { () -> SCStream? in
            generation += 1
            defer { stream = nil }
            return stream
        }
        guard let stream = stopped else { return }
        stream.stopCapture { error in
            if let error { captureLog.error("stop: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)), status == .complete,
              let buffer = sampleBuffer.imageBuffer
        else { return }
        let displayTime = (info[.displayTime] as? UInt64).map(Self.machToNs) ?? monotonicNs()
        let rects = (info[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        onFrame?(Frame(buffer: buffer, captureHostNs: displayTime, dirtyRects: rects))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureLog.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        let wasCurrent = lock.withLock { () -> Bool in
            guard self.stream === stream else { return false }
            self.stream = nil
            return true
        }
        if wasCurrent { onStop?() }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    private static func machToNs(_ t: UInt64) -> UInt64 { t * UInt64(timebase.numer) / UInt64(timebase.denom) }
}
