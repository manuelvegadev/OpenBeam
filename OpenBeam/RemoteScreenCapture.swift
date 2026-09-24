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
    var onFrame: ((Frame) -> Void)?
    /// When the stream ends by itself, for example because the display went away.
    var onStop: (() -> Void)?

    private let queue = DispatchQueue(label: "com.openbeam.remotescreen.capture", qos: .userInteractive)
    private var stream: SCStream?

    /// The largest size inside `maxWidth` × `maxHeight` with the display's aspect
    /// ratio, never above the display's own pixels, both sides even.
    static func fittedSize(display: CGDirectDisplayID, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        let pixels = pixelSize(of: display)
        let pixelWidth = Double(pixels.width), pixelHeight = Double(pixels.height)
        let limitW = Double(min(maxWidth, RemoteScreen.maxDimension)), limitH = Double(min(maxHeight, RemoteScreen.maxDimension))
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
        self.stream = stream
        let mode = CGDisplayCopyDisplayMode(displayID)
        captureLog.info("capturing display \(displayID, privacy: .public) (\(mode?.pixelWidth ?? 0, privacy: .public)×\(mode?.pixelHeight ?? 0, privacy: .public) px @ \(mode?.refreshRate ?? 0, privacy: .public) Hz) at \(width, privacy: .public)×\(height, privacy: .public)")
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
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
        self.stream = nil
        onStop?()
    }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    private static func machToNs(_ t: UInt64) -> UInt64 { t * UInt64(timebase.numer) / UInt64(timebase.denom) }
}
