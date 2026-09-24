//
//  ScreenRenderer.swift
//  OpenBeam
//
//  The viewer's picture of the remote screen: one GPU texture that FRAME
//  patches are copied into, and a Metal view that shows each new state the
//  moment it lands.
//

import AppKit
import Metal
import QuartzCore
import os

private let rendererLog = Logger(subsystem: "com.openbeam.remotescreen", category: "renderer")

/// Draws the canvas texture over the whole viewport; the viewport does the
/// letterboxing. Compiled at run time, so building OpenBeam needs no Metal toolchain.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct RemoteScreenVertex {
    float4 position [[position]];
    float2 uv;
};

// One triangle that covers the viewport, from the vertex index alone.
vertex RemoteScreenVertex remoteScreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    RemoteScreenVertex out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

fragment float4 remoteScreenFragment(RemoteScreenVertex in [[stage_in]],
                                     texture2d<float> screen [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(screen.sample(s, in.uv).rgb, 1.0);
}
"""

/// What the viewer knows about one received FRAME.
struct ScreenFrameInfo {
    var index: UInt64
    var width: Int
    var height: Int
    var whole: Bool
    var captureHostNs: UInt64
    var sendHostNs: UInt64
    var receivedNs: UInt64
    var inputSeq: UInt64
}

/// The remote screen as one texture. Patches are copied in by blits on the same
/// command queue that draws, so a draw always sees every patch committed before it.
final class ScreenCanvas: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    /// Called after each FRAME is committed, from the receiving thread.
    var onUpdate: (() -> Void)?

    private let lock = NSLock()
    private var texture: MTLTexture?
    private var latest: ScreenFrameInfo?

    // Buffers the socket's pixels are copied into; one is reused only after the
    // blit that read it has finished.
    private var staging: [MTLBuffer?] = Array(repeating: nil, count: 4)
    private var nextStaging = 0
    private let stagingFree = DispatchSemaphore(value: 4)

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        commandQueue = queue
    }

    /// A shared buffer of at least `length` bytes, waiting while all are in flight.
    func stagingBuffer(length: Int) -> MTLBuffer? {
        stagingFree.wait()
        let i = nextStaging
        nextStaging = (nextStaging + 1) % staging.count
        if staging[i] == nil || staging[i]!.length < length {
            staging[i] = device.makeBuffer(length: max(length, 1), options: .storageModeShared)
        }
        guard let buffer = staging[i] else {
            stagingFree.signal()
            return nil
        }
        return buffer
    }

    /// Copies the rects' pixels, packed back to back in `buffer`, into the texture.
    func apply(_ rects: [ScreenRect], from buffer: MTLBuffer, info: ScreenFrameInfo) {
        lock.lock()
        if texture == nil || texture!.width != info.width || texture!.height != info.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: info.width, height: info.height, mipmapped: false)
            desc.usage = .shaderRead
            desc.storageMode = .private
            texture = device.makeTexture(descriptor: desc)
        }
        let target = texture
        lock.unlock()
        guard let target, let cmd = commandQueue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else {
            stagingFree.signal()
            return
        }
        var offset = 0
        for r in rects {
            let rowBytes = Int(r.width) * 4
            blit.copy(from: buffer, sourceOffset: offset, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * Int(r.height),
                      sourceSize: MTLSize(width: Int(r.width), height: Int(r.height), depth: 1),
                      to: target, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: Int(r.x), y: Int(r.y), z: 0))
            offset += rowBytes * Int(r.height)
        }
        blit.endEncoding()
        cmd.addCompletedHandler { [stagingFree] _ in stagingFree.signal() }
        cmd.commit()

        lock.lock()
        latest = info
        lock.unlock()
        onUpdate?()
    }

    /// The texture and the newest frame not yet drawn, if there is one.
    func takeLatest() -> (MTLTexture, ScreenFrameInfo)? {
        lock.lock()
        defer { lock.unlock() }
        guard let info = latest, let texture else { return nil }
        latest = nil
        return (texture, info)
    }
}

/// Shows the canvas letterboxed in the view, drawing as soon as a frame lands
/// rather than on the next display tick: measured ~5 ms sooner on screen.
final class ScreenView: NSView {
    /// Called with each frame and the host time it reached the glass (0 if dropped).
    var onPresented: ((ScreenFrameInfo, CFTimeInterval) -> Void)?
    /// On the main queue, when the remote screen's size changes.
    var onRemoteSizeChange: ((CGSize) -> Void)?
    /// The remote screen's size, for mapping pointer positions onto it.
    private(set) var remoteSize = CGSize(width: 16, height: 9)
    let renderQueue = DispatchQueue(label: "com.openbeam.remotescreen.render", qos: .userInteractive)

    private let canvas: ScreenCanvas
    private let pipeline: MTLRenderPipelineState
    private var drawnSize = CGSize.zero  // renderQueue only
    private let statsLayer = CATextLayer()
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Receives the mouse and keyboard while this view is first responder.
    var input: RemoteScreenInput?

    var showsStats = false {
        didSet { statsLayer.isHidden = !showsStats }
    }

    init?(frame: NSRect, canvas: ScreenCanvas) {
        self.canvas = canvas
        guard let pipeline = Self.pipeline(for: canvas.device) else { return nil }
        self.pipeline = pipeline
        super.init(frame: frame)
        wantsLayer = true
        statsLayer.isHidden = true
        statsLayer.fontSize = 13
        statsLayer.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        statsLayer.foregroundColor = NSColor.white.cgColor
        statsLayer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        statsLayer.cornerRadius = 6
        statsLayer.zPosition = 1
        layer!.addSublayer(statsLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Compiled once per GPU and kept: every reconnect makes a new view, and
    /// compiling from source takes a noticeable moment on the main thread.
    private static var pipelines: [ObjectIdentifier: MTLRenderPipelineState] = [:]  // main thread

    private static func pipeline(for device: MTLDevice) -> MTLRenderPipelineState? {
        if let cached = pipelines[ObjectIdentifier(device)] { return cached }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "remoteScreenVertex")
            desc.fragmentFunction = library.makeFunction(name: "remoteScreenFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: desc)
            pipelines[ObjectIdentifier(device)] = pipeline
            return pipeline
        } catch {
            rendererLog.error("pipeline: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = canvas.device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.maximumDrawableCount = 2
        l.displaySyncEnabled = true
        l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        l.backgroundColor = NSColor.black.cgColor
        return l
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        if trackingAreas.isEmpty {
            // Always active: hovering the picture moves the host's pointer even
            // while another window has the keyboard, like a KVM.
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
    }

    // MARK: Input, handed to `input`

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { input?.pointerEntered() }
    override func mouseExited(with event: NSEvent) { input?.pointerExited() }
    override func mouseMoved(with event: NSEvent) { input?.mouse(event, in: self) }
    override func mouseDragged(with event: NSEvent) { input?.mouse(event, in: self) }
    override func rightMouseDragged(with event: NSEvent) { input?.mouse(event, in: self) }
    override func otherMouseDragged(with event: NSEvent) { input?.mouse(event, in: self) }
    override func mouseDown(with event: NSEvent) { input?.mouse(event, in: self) }
    override func mouseUp(with event: NSEvent) { input?.mouse(event, in: self) }
    override func rightMouseDown(with event: NSEvent) { input?.mouse(event, in: self) }
    override func rightMouseUp(with event: NSEvent) { input?.mouse(event, in: self) }
    override func otherMouseDown(with event: NSEvent) { input?.mouse(event, in: self) }
    override func otherMouseUp(with event: NSEvent) { input?.mouse(event, in: self) }
    override func scrollWheel(with event: NSEvent) { input?.scroll(event) }

    override func keyDown(with event: NSEvent) { input?.key(event, in: window) }
    override func keyUp(with event: NSEvent) { input?.key(event, in: window) }
    override func flagsChanged(with event: NSEvent) { input?.key(event, in: window) }

    /// ⌘-shortcuts reach here before keyDown, and the menu would take them;
    /// while this view has focus they belong to the host.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let input, event.type == .keyDown, window?.firstResponder === self else { return false }
        input.key(event, in: window)
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        statsLayer.contentsScale = scale
        statsLayer.frame = CGRect(x: 12, y: bounds.height - 12 - 44, width: min(bounds.width - 24, 760), height: 44)
    }

    func setStatsText(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statsLayer.string = text
        CATransaction.commit()
    }

    /// Where the remote screen sits in this view, in points.
    var imageRect: CGRect {
        let s = min(bounds.width / remoteSize.width, bounds.height / remoteSize.height)
        let w = remoteSize.width * s, h = remoteSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// Draws the newest canvas state, if there is one. Call on `renderQueue`.
    func renderLatest() {
        guard let (texture, info) = canvas.takeLatest(),
              let drawable = metalLayer.nextDrawable(),
              let cmd = canvas.commandQueue.makeCommandBuffer()
        else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        let scale = min(dw / Double(info.width), dh / Double(info.height))
        let w = Double(info.width) * scale, h = Double(info.height) * scale
        enc.setViewport(MTLViewport(originX: (dw - w) / 2, originY: (dh - h) / 2, width: w, height: h, znear: 0, zfar: 1))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        let presented = onPresented
        drawable.addPresentedHandler { d in presented?(info, d.presentedTime) }
        cmd.present(drawable)
        cmd.commit()
        let size = CGSize(width: info.width, height: info.height)
        if size != drawnSize {
            drawnSize = size
            DispatchQueue.main.async {
                self.remoteSize = size
                self.onRemoteSizeChange?(size)
            }
        }
    }
}
