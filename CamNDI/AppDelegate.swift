//
//  AppDelegate.swift
//  CamNDI
//
//  NSStatusItem tray icon and menu — app entry point.
//

import AppKit
import AVFoundation
import os

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var previewLayer: CALayer!
    private var menuIsOpen = false

    private let cameraController = CameraController()
    private let audioController = AudioController()
    private let ndiSender = NDISender()

    private var cameraSubmenu: NSMenu!
    private var audioSubmenu: NSMenu!
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
        startStatsTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statsTimer?.invalidate()
        levelTimer?.invalidate()
        cameraController.stop()
        audioController.stop()
        ndiSender.stop()
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
                                       accessibilityDescription: "CamNDI")
            }
            button.setAccessibilityLabel("CamNDI")
        }

        let menu = NSMenu()
        menu.delegate = self

        // --- Header bar ---
        let headerItem = NSMenuItem()
        let headerView = NSView(frame: NSRect(x: 0, y: 0, width: 336, height: 30))

        let titleLabel = NSTextField(labelWithString: "CamNDI")
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
        previewLayer.backgroundColor = NSColor.black.cgColor
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
        let quitItem = NSMenuItem(title: "Quit CamNDI",
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

            // Only render preview when the menu is visible
            guard self.menuIsOpen else { return }

            guard let cgImage = Self.createCGImage(from: pixelBuffer) else { return }

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
                print("[CamNDI] NDI unavailable")
            }
        }
    }

    // MARK: - Preview Helper

    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
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

    // MARK: - Stats Timer

    private func startStatsTimer() {
        prevStatsTime = CFAbsoluteTimeGetCurrent()
        prevFramesSent = 0
        prevCaptureFrameCount = 0

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
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

        statsResolutionItem.title = "\(frameStats.width)×\(frameStats.height)"
        statsFPSItem.title = "Capture \(String(format: "%.1f", captureFPS)) fps → NDI \(String(format: "%.1f", ndiSentFPS)) fps"
        statsDataRateItem.title = "\(String(format: "%.1f", dataRateMBps)) MB/s"
        statsFramesSentItem.title = "Sent: \(formatCount(sent))"
        statsDroppedItem.title = "Dropped: \(formatCount(ndiSender.droppedFrames))"
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
        NSWorkspace.shared.open(URL(string: "https://github.com/manuelvegadev/CamNDI")!)
    }

    @objc private func restartNDISender(_ sender: NSMenuItem) {
        _ = ndiSender.restart()
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
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            menuIsOpen = true
            startLevelTimer()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusItem.menu {
            menuIsOpen = false
            stopLevelTimer()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === cameraSubmenu {
            updateCameraSubmenu(menu)
        } else if menu === audioSubmenu {
            updateAudioSubmenu(menu)
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
