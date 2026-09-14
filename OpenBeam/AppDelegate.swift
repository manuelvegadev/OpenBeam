//
//  AppDelegate.swift
//  Open Beam
//
//  NSStatusItem tray icon and menu — app entry point.
//

import AppKit
import AVFoundation
import CoreImage
import os

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var previewLayer: CALayer!
    private var menuIsOpen = false
    /// The preview is emptied on close, so the next frame fades back in.
    private enum PreviewIntro { case pending, running, done }
    private var previewIntro: PreviewIntro = .pending

    private let cameraController = CameraController()
    private let audioController = AudioController()
    private let ndiSender = NDISender()
    private let clipSyncManager = ClipSyncManager()
    private let netMonitor = NetTrafficMonitor()

    private var cameraSubmenu: NSMenu!
    private var audioSubmenu: NSMenu!
    private var clipboardSubmenu: NSMenu!
    private var statsSubmenu: NSMenu!

    private var meterTrackLayer: CALayer!
    private var meterFillLayer: CALayer!
    private var levelTimer: Timer?
    private var displayedLevel: Double = 0
    private var meterBand: MeterBand = .normal

    private enum MeterBand { case normal, warning, critical }
    private static let meterColorNormal = NSColor.systemGreen.cgColor
    private static let meterColorWarning = NSColor.systemYellow.cgColor
    private static let meterColorCritical = NSColor.systemRed.cgColor

    // Stats
    private var statsTimer: Timer?
    private var statsResolutionItem: NSMenuItem!
    private var statsFPSItem: NSMenuItem!
    private var statsDataRateItem: NSMenuItem!
    private var statsFramesSentItem: NSMenuItem!
    private var statsDroppedItem: NSMenuItem!
    private var pixelFormatToggleItem: NSMenuItem!
    private var prevFramesSent: Int64 = 0
    private var prevBytesSent: Int64 = 0
    private var prevStatsTime: CFAbsoluteTime = 0
    private var prevCaptureFrameCount: Int64 = 0

    // Frame stats — protected by statsLock (written on capture queue, read on main)
    private let statsLock = OSAllocatedUnfairLock(initialState: (width: 0, height: 0, count: Int64(0)))

    // MARK: - Entry Point

    static func main() {
        signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        startPipeline()
        clipSyncManager.onStateChanged = { [weak self] in
            // No persistent submenu items to mutate eagerly; the menu rebuilds on open.
            _ = self
        }
        clipSyncManager.onPairRequestPresented = { [weak self] in
            self?.statusItem.menu?.cancelTracking()
        }
        clipSyncManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStatsTimer()
        stopLevelTimer()
        cameraController.stop()
        audioController.stop()
        ndiSender.stop()
        clipSyncManager.stop()
        netMonitor.stop()
    }

    // MARK: - Status Bar Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let icon = NSImage(named: "MenuBarIcon") {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "camera.fill",
                                       accessibilityDescription: "Open Beam")
            }
            button.setAccessibilityLabel("Open Beam")
        }

        let menu = NSMenu()
        menu.delegate = self

        // --- Header bar ---
        let headerItem = NSMenuItem()
        let headerView = NSView(frame: NSRect(x: 0, y: 0, width: 336, height: 30))

        let titleLabel = NSTextField(labelWithString: "Open Beam")
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 14, y: (30 - titleLabel.frame.height) / 2)
        headerView.addSubview(titleLabel)

        let ghButton = NSButton(frame: NSRect(x: 336 - 14 - 20, y: (30 - 20) / 2, width: 20, height: 20))
        ghButton.bezelStyle = .inline
        ghButton.isBordered = false
        if let img = NSImage(named: "GitHubMark") {
            img.size = NSSize(width: 16, height: 16)
            ghButton.image = img
        }
        ghButton.target = self
        ghButton.action = #selector(openGitHub(_:))
        headerView.addSubview(ghButton)

        headerItem.view = headerView
        menu.addItem(headerItem)

        // --- Live preview ---
        let previewItem = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 336, height: 196))
        container.wantsLayer = true

        previewLayer = CALayer()
        previewLayer.frame = CGRect(x: 8, y: 8, width: 320, height: 180)
        // No background: an empty preview shows the menu's own vibrant
        // material through it rather than a black slab.
        previewLayer.backgroundColor = nil
        previewLayer.cornerRadius = 6
        previewLayer.masksToBounds = true
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.actions = ["contents": NSNull()]
        container.layer?.addSublayer(previewLayer)

        previewItem.view = container
        menu.addItem(previewItem)

        // --- Audio level meter ---
        let meterItem = NSMenuItem()
        let meterHeight: CGFloat = 8
        let meterWidth: CGFloat = 320
        let containerHeight: CGFloat = 18
        let meterContainer = NSView(frame: NSRect(x: 0, y: 0, width: 336, height: containerHeight))
        meterContainer.wantsLayer = true

        let meterY = (containerHeight - meterHeight) / 2

        meterTrackLayer = CALayer()
        meterTrackLayer.frame = CGRect(x: 8, y: meterY, width: meterWidth, height: meterHeight)
        meterTrackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        meterTrackLayer.cornerRadius = meterHeight / 2
        meterTrackLayer.cornerCurve = .continuous
        meterTrackLayer.masksToBounds = true

        meterFillLayer = CALayer()
        meterFillLayer.frame = CGRect(x: 0, y: 0, width: 0, height: meterHeight)
        meterFillLayer.backgroundColor = NSColor.systemGreen.cgColor
        meterFillLayer.cornerRadius = meterHeight / 2
        meterFillLayer.cornerCurve = .continuous
        meterFillLayer.anchorPoint = .zero
        meterTrackLayer.addSublayer(meterFillLayer)

        meterContainer.layer?.addSublayer(meterTrackLayer)

        meterItem.view = meterContainer
        menu.addItem(meterItem)

        menu.addItem(.separator())

        // --- Camera selection submenu ---
        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraSubmenu = NSMenu()
        cameraSubmenu.delegate = self
        cameraItem.submenu = cameraSubmenu
        menu.addItem(cameraItem)

        // --- Microphone selection submenu ---
        let audioItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        audioSubmenu = NSMenu()
        audioSubmenu.delegate = self
        audioItem.submenu = audioSubmenu
        menu.addItem(audioItem)

        // --- Clipboard sync submenu ---
        let clipboardItem = NSMenuItem(title: "Clipboard Sync", action: nil, keyEquivalent: "")
        clipboardSubmenu = NSMenu()
        clipboardSubmenu.delegate = self
        clipboardItem.submenu = clipboardSubmenu
        menu.addItem(clipboardItem)

        menu.addItem(.separator())

        // --- NDI source label + restart ---
        let ndiLabel = NSMenuItem(title: "NDI: \(NDISender.sourceName)", action: nil, keyEquivalent: "")
        ndiLabel.isEnabled = false
        menu.addItem(ndiLabel)

        let restartNDI = NSMenuItem(title: "Restart NDI",
                                    action: #selector(restartNDISender(_:)),
                                    keyEquivalent: "")
        restartNDI.target = self
        menu.addItem(restartNDI)

        pixelFormatToggleItem = NSMenuItem(title: "Send as UYVY (4:2:2)",
                                           action: #selector(togglePixelFormat(_:)),
                                           keyEquivalent: "")
        pixelFormatToggleItem.target = self
        pixelFormatToggleItem.state = (cameraController.pixelFormat == .uyvy422) ? .on : .off
        menu.addItem(pixelFormatToggleItem)

        menu.addItem(.separator())

        // --- Statistics (collapsible via submenu) ---
        let statsItem = NSMenuItem(title: "Statistics", action: nil, keyEquivalent: "")
        statsSubmenu = NSMenu()

        statsResolutionItem = addDisabledItem(to: statsSubmenu, title: "—")
        statsFPSItem = addDisabledItem(to: statsSubmenu, title: "—")
        statsDataRateItem = addDisabledItem(to: statsSubmenu, title: "—")
        statsFramesSentItem = addDisabledItem(to: statsSubmenu, title: "Sent: 0")
        statsDroppedItem = addDisabledItem(to: statsSubmenu, title: "Dropped: 0")

        statsItem.submenu = statsSubmenu
        menu.addItem(statsItem)

        menu.addItem(.separator())

        // --- Quit ---
        let quitItem = NSMenuItem(title: "Quit Open Beam",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addDisabledItem(to menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    // MARK: - Pipeline

    private func startPipeline() {
        cameraController.onFrame = { [weak self] pixelBuffer in
            guard let self else { return }

            self.ensureNDIStarted()

            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            self.statsLock.withLock {
                $0.width = w
                $0.height = h
                $0.count += 1
            }

            self.ndiSender.send(pixelBuffer: pixelBuffer)

            // Render the preview only while the menu is visible, and not while
            // the intro animation owns the layer — building the image first and
            // discarding it on the main thread wasted a full-resolution copy per
            // frame for the whole intro.
            guard self.menuIsOpen, self.previewIntro != .running else { return }

            guard let cgImage = Self.createCGImage(from: pixelBuffer) else { return }

            if self.previewIntro == .pending {
                // Built here rather than on the main thread: the menu is opening
                // and its own animation is running there. A second frame can
                // reach this before the state flips, which only costs one extra
                // ladder — the main thread keeps whichever arrives first.
                let ladder = Self.previewIntroLadder(from: cgImage)
                DispatchQueue.main.async {
                    guard self.previewIntro == .pending else { return }
                    self.previewIntro = .running
                    self.runPreviewIntro(ladder: ladder)
                }
                return
            }

            DispatchQueue.main.async {
                self.previewLayer?.contents = cgImage
            }
        }

        audioController.onAudio = { [weak self] buffer in
            guard let self else { return }
            self.ensureNDIStarted()
            self.ndiSender.send(audioBuffer: buffer)
        }

        cameraController.start()
        audioController.start()
    }

    private func ensureNDIStarted() {
        if !ndiSender.isActive {
            if !ndiSender.start() {
                print("[Open Beam] NDI unavailable")
            }
        }
    }

    // MARK: - Preview Helper

    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let previewCIContext = CIContext(options: nil)

    private static func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        // BGRA: zero-copy path through CGContext on the locked base address.
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)

            guard let ctx = CGContext(data: base,
                                      width: w,
                                      height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: stride,
                                      space: sRGBColorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                                  CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            return ctx.makeImage()
        }

        // Non-BGRA (e.g. UYVY): let Core Image handle the YUV→RGB conversion.
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return previewCIContext.createCGImage(ci, from: ci.extent)
    }

    // MARK: - Stats Timer

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        // Seed from the live counters: capture keeps running while the menu is
        // closed, so zeroing would make the first tick report everything since
        // launch as if it had happened in one second.
        prevStatsTime = CFAbsoluteTimeGetCurrent()
        prevFramesSent = ndiSender.framesSent
        prevBytesSent = ndiSender.bytesSent
        prevCaptureFrameCount = statsLock.withLock { $0.count }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    /// Rates need two samples, so they show placeholders until the first tick.
    private func resetStatsDisplay() {
        renderStats(captureFPS: nil, ndiFPS: nil, captureMBps: nil, wireMBps: nil)
    }

    /// The single place the stats labels are spelled. A nil rate renders as a
    /// placeholder, so the reset pass and the timer tick cannot drift apart.
    private func renderStats(captureFPS: Double?,
                             ndiFPS: Double?,
                             captureMBps: Double?,
                             wireMBps: Double?) {
        func num(_ value: Double?, _ decimals: Int) -> String {
            guard let value else { return "—" }
            return String(format: "%.\(decimals)f", value)
        }
        let frameStats = statsLock.withLock { $0 }
        statsResolutionItem.title = frameStats.width > 0
            ? "\(frameStats.width)×\(frameStats.height)"
            : "—"
        statsFPSItem.title = "Capture \(num(captureFPS, 1)) fps → NDI \(num(ndiFPS, 1)) fps"
        statsDataRateItem.title = "Capture \(num(captureMBps, 1)) MB/s | Wire \(num(wireMBps, 2)) MB/s"
        statsFramesSentItem.title = "Sent: \(formatCount(ndiSender.framesSent))"
        statsDroppedItem.title = "Dropped: \(formatCount(ndiSender.droppedFrames))"
    }

    /// A ladder of progressively sharper copies of the first frame. Core
    /// Animation cannot interpolate between two images, so the resolve is
    /// stepped through discrete frames rather than cross-faded.
    private static func previewIntroLadder(from frame: CGImage) -> [CGImage] {
        // Work from a quarter-size bitmap: the preview is 320pt wide, so no
        // detail is lost, and every rung then blurs 480x270 instead of
        // re-running the downscale from 1080p. Clamping stops the blur sampling
        // the transparency beyond the edges, which would darken the border into
        // a vignette.
        let scaled = CIImage(cgImage: frame).transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let extent = scaled.extent
        guard let small = previewCIContext.createCGImage(scaled, from: extent) else { return [frame] }
        let clamped = CIImage(cgImage: small).clampedToExtent()

        let rungs = 9
        var ladder = (0..<rungs).compactMap { i -> CGImage? in
            let radius = 15.0 * pow(1.0 - Double(i) / Double(rungs), 2.0)
            let rung = clamped.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
            return previewCIContext.createCGImage(rung, from: extent)
        }
        ladder.append(frame)
        return ladder
    }

    /// Brings the preview up from nothing: the layer fades in from fully
    /// transparent while its content resolves from blurred to sharp. Behind the
    /// fade, what shows is the menu's own translucent material.
    private func runPreviewIntro(ladder: [CGImage]) {
        guard let layer = previewLayer else { return }

        let duration: CFTimeInterval = 0.45
        let curve = CAMediaTimingFunction(name: .easeOut)

        // Both are plain property animations on the same layer, so they
        // compose. A CATransition for the content change would not: it renders
        // through its own compositing path and the opacity animation alongside
        // it is ignored, which made the frame appear at full opacity at once.
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0.0
        fadeIn.toValue = 1.0
        fadeIn.duration = duration
        fadeIn.timingFunction = curve

        let resolve = CAKeyframeAnimation(keyPath: "contents")
        resolve.values = ladder
        resolve.calculationMode = .discrete
        resolve.duration = duration
        resolve.timingFunction = curve

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            if self?.previewIntro == .running { self?.previewIntro = .done }
        }
        layer.contents = ladder.last
        layer.add(fadeIn, forKey: "previewFade")
        layer.add(resolve, forKey: "previewResolve")
        CATransaction.commit()
    }

    private func updateStats() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - prevStatsTime
        guard elapsed > 0 else { return }

        let frameStats = statsLock.withLock { $0 }
        let captureFPS = Double(frameStats.count - prevCaptureFrameCount) / elapsed
        prevCaptureFrameCount = frameStats.count

        let sent = ndiSender.framesSent
        let ndiSentFPS = Double(sent - prevFramesSent) / elapsed

        let totalBytes = ndiSender.bytesSent
        let bytesInInterval = totalBytes - prevBytesSent

        prevFramesSent = sent
        prevBytesSent = totalBytes
        prevStatsTime = now

        let dataRateMBps = (Double(bytesInInterval) / elapsed) / (1024.0 * 1024.0)

        renderStats(captureFPS: captureFPS,
                    ndiFPS: ndiSentFPS,
                    captureMBps: dataRateMBps,
                    wireMBps: netMonitor.bytesPerSecondOut / (1024.0 * 1024.0))
    }

    // MARK: - Audio Level Meter

    private func startLevelTimer() {
        guard levelTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateLevelMeter()
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func updateLevelMeter() {
        let peak = audioController.currentPeak
        // Map linear peak → dBFS → 0…1 over the −60 dB to 0 dB range.
        let target: Double
        if peak > 0.0001 {
            let db = 20.0 * Foundation.log10(Double(peak))
            target = max(0, min(1, (db + 60.0) / 60.0))
        } else {
            target = 0
        }
        // Fast attack, smooth decay so the meter doesn't strobe.
        if target >= displayedLevel {
            displayedLevel = target
        } else {
            displayedLevel += (target - displayedLevel) * 0.3
        }

        let trackBounds = meterTrackLayer.bounds
        let fillWidth = max(0, trackBounds.width * CGFloat(displayedLevel))

        let band: MeterBand
        if displayedLevel >= 0.95 { band = .critical }
        else if displayedLevel >= 0.85 { band = .warning }
        else { band = .normal }

        // Disable implicit animations so the bar tracks the audio in real time.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        meterFillLayer.frame = CGRect(x: 0, y: 0, width: fillWidth, height: trackBounds.height)
        if band != meterBand {
            meterBand = band
            switch band {
            case .normal: meterFillLayer.backgroundColor = Self.meterColorNormal
            case .warning: meterFillLayer.backgroundColor = Self.meterColorWarning
            case .critical: meterFillLayer.backgroundColor = Self.meterColorCritical
            }
        }
        CATransaction.commit()
    }

    private func formatCount(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: - Actions

    @objc private func openGitHub(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "https://github.com/manuelvegadev/OpenBeam")!)
    }

    @objc private func restartNDISender(_ sender: NSMenuItem) {
        _ = ndiSender.restart()
    }

    @objc private func togglePixelFormat(_ sender: NSMenuItem) {
        let new: CameraPixelFormat = (cameraController.pixelFormat == .uyvy422) ? .bgra32 : .uyvy422
        cameraController.setPixelFormat(new)
        sender.state = (new == .uyvy422) ? .on : .off
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? String else { return }
        cameraController.switchCamera(deviceID: deviceID)
    }

    @objc private func selectAudio(_ sender: NSMenuItem) {
        if let deviceID = sender.representedObject as? String {
            audioController.switchInput(deviceID: deviceID)
        } else {
            audioController.stop()
        }
    }

    @objc private func toggleClipboardSync(_ sender: NSMenuItem) {
        clipSyncManager.isEnabled.toggle()
    }

    @objc private func requestClipSyncPair(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let peer = clipSyncManager.discoveredPeers.first(where: { $0.peerID == id }) else { return }
        clipSyncManager.requestPair(with: peer)
    }

    @objc private func unpairClipSync(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let peer = clipSyncManager.pairedPeers.first(where: { $0.peerID == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \"\(peer.displayName)\"?"
        alert.informativeText = "You'll need to pair again to resume clipboard sync."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Forget")
        if alert.runModal() == .alertSecondButtonReturn {
            clipSyncManager.unpair(peerID: id)
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            menuIsOpen = true
            startLevelTimer()
            netMonitor.start()
            resetStatsDisplay()
            startStatsTimer()
            pixelFormatToggleItem.state = (cameraController.pixelFormat == .uyvy422) ? .on : .off
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusItem.menu {
            menuIsOpen = false
            stopLevelTimer()
            netMonitor.stop()
            stopStatsTimer()
            // Release the last frame: it is a full-resolution image that would
            // otherwise sit in memory for as long as the menu stays closed.
            // Release the full-resolution frame; it would otherwise be
            // retained for as long as the menu stays closed.
            previewLayer?.contents = nil
            previewLayer?.removeAllAnimations()
            previewIntro = .pending
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === cameraSubmenu {
            updateCameraSubmenu(menu)
        } else if menu === audioSubmenu {
            updateAudioSubmenu(menu)
        } else if menu === clipboardSubmenu {
            updateClipboardSubmenu(menu)
        }
    }

    private func updateClipboardSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // --- Enabled toggle ---
        let toggle = NSMenuItem(title: "Enabled",
                                action: #selector(toggleClipboardSync(_:)),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = clipSyncManager.isEnabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())

        // --- Discovered (unpaired) ---
        let discoveredHeader = NSMenuItem(title: "Discovered", action: nil, keyEquivalent: "")
        discoveredHeader.isEnabled = false
        menu.addItem(discoveredHeader)

        let pairedIDs = Set(clipSyncManager.pairedPeers.map(\.peerID))
        let unpairedDiscovered = clipSyncManager.discoveredPeers.filter { !pairedIDs.contains($0.peerID) }

        if unpairedDiscovered.isEmpty {
            let placeholder = NSMenuItem(title: "    No devices found", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        } else {
            for peer in unpairedDiscovered {
                let title = "    \(peer.displayName) (\(peer.os))"
                let item = NSMenuItem(title: title,
                                      action: #selector(requestClipSyncPair(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = peer.peerID
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // --- Paired ---
        let pairedHeader = NSMenuItem(title: "Paired", action: nil, keyEquivalent: "")
        pairedHeader.isEnabled = false
        menu.addItem(pairedHeader)

        if clipSyncManager.pairedPeers.isEmpty {
            let placeholder = NSMenuItem(title: "    No paired devices", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        } else {
            for peer in clipSyncManager.pairedPeers.sorted(by: { $0.displayName < $1.displayName }) {
                let title = "    \(peer.displayName) (\(peer.os)) — Forget"
                let item = NSMenuItem(title: title,
                                      action: #selector(unpairClipSync(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = peer.peerID
                menu.addItem(item)
            }
        }
    }

    private func updateCameraSubmenu(_ menu: NSMenu) {
        populateDeviceMenu(menu,
                           devices: CameraController.availableCameras,
                           currentID: cameraController.currentDeviceID,
                           action: #selector(selectCamera(_:)),
                           includeNone: false,
                           emptyText: "No cameras found")
    }

    private func updateAudioSubmenu(_ menu: NSMenu) {
        populateDeviceMenu(menu,
                           devices: AudioController.availableInputs,
                           currentID: audioController.currentDeviceID,
                           action: #selector(selectAudio(_:)),
                           includeNone: true,
                           emptyText: "No microphones found")
    }

    private func populateDeviceMenu(_ menu: NSMenu,
                                    devices: [AVCaptureDevice],
                                    currentID: String?,
                                    action: Selector,
                                    includeNone: Bool,
                                    emptyText: String) {
        menu.removeAllItems()

        if includeNone {
            let noneItem = NSMenuItem(title: "None", action: action, keyEquivalent: "")
            noneItem.target = self
            noneItem.representedObject = nil
            noneItem.state = (currentID == nil) ? .on : .off
            menu.addItem(noneItem)
            if !devices.isEmpty {
                menu.addItem(.separator())
            }
        }

        for device in devices {
            let item = NSMenuItem(title: device.localizedName, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = (device.uniqueID == currentID) ? .on : .off
            menu.addItem(item)
        }

        if devices.isEmpty {
            let placeholder = NSMenuItem(title: emptyText, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        }
    }
}
