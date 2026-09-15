//
//  AppDelegate.swift
//  OpenBeam
//
//  NSStatusItem tray icon and menu — app entry point.
//

import AppKit
import AVFoundation
import CoreImage
import os

/// A menu item view that lays its contents out from its own width.
///
/// AppKit stretches item views to the menu's width, and the menu is as wide as
/// its longest text item — so a hardcoded layout leaves the preview and the
/// tabs short of the right edge as soon as a source name is long.
private final class MenuRowView: NSView {

    var layoutHandler: ((NSRect) -> Void)?
    /// Set by rows whose height follows their width — only the preview, which
    /// keeps 16:9. Rows without one keep the height they were built with.
    var heightForWidth: ((CGFloat) -> CGFloat)?

    /// Resizes to `width`, applying the row's own height rule, and lays out.
    func fit(to width: CGFloat) {
        setFrameSize(NSSize(width: width, height: heightForWidth?(width) ?? frame.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Layer frames set here would otherwise animate into place.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutHandler?(bounds)
        CATransaction.commit()
    }
}

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
    private let ndiFinder = NDIFinder()
    private let ndiReceiver = NDIReceiver()
    private let clipSyncManager = ClipSyncManager()
    private let netMonitor = NetTrafficMonitor()

    // Settings and updates. The updater is a stored property because Sparkle's
    // controller stops the moment it is deallocated.
    private let launchAtLogin = LaunchAtLogin()
    private var updaterController: UpdaterController!
    // Built the first time the settings window is opened. Constructing the
    // model costs an SMAppService round-trip and a pass over every controller,
    // which most launches never need.
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    /// Shown at the top of the menu when a background check found an update we
    /// deliberately did not interrupt the user with.
    private var updateAvailableItem: NSMenuItem!
    private var checkForUpdatesItem: NSMenuItem!

    /// Which half of the host/client pair this machine plays. The two are
    /// exclusive: receiving takes the camera, the microphone and our own NDI
    /// source down, so one machine never sends and receives at the same time.
    private enum AppMode: String { case send, receive }

    private static let modeDefaultsKey = "mode"

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// The project's home. The menu's GitHub button and the About pane's links
    /// both derive from this, so a rename cannot leave one of them behind.
    static let repoURL = URL(string: "https://github.com/manuelvegadev/OpenBeam")!
    private static let ndiSourceDefaultsKey = "ndiSource"

    /// Held in a lock because the capture and audio threads read it on every
    /// frame — `ensureNDIStarted` must not revive the sender just after Receive
    /// took our source off the network.
    private let modeState = OSAllocatedUnfairLock(initialState: AppMode.send)
    private var mode: AppMode { modeState.withLock { $0 } }
    private var modeControl: NSSegmentedControl!
    /// Items only one mode shows, recorded as each is built.
    private var itemVisibility: [(item: NSMenuItem, mode: AppMode)] = []
    private var virtualCameraItem: NSMenuItem!
    /// The width every row starts from; the menu grows past it only when a text
    /// item needs more, and the rows then follow.
    private static let baseWidth: CGFloat = 336
    /// Horizontal inset shared by the preview, the meter, the tabs and the
    /// title. 14 pt is where AppKit itself starts an item's text and draws the
    /// separators, measured off a screenshot: anything else reads as misaligned
    /// against the rows the system draws.
    private static let contentInsetX: CGFloat = 14
    /// Vertical padding around the preview and the meter.
    private static let contentInsetY: CGFloat = 8
    /// The widest the menu is allowed to get. Past this a source name is
    /// trimmed rather than stretching the menu across the screen.
    private static let maxWidth: CGFloat = 460
    private var menuRows: [MenuRowView] = []
    /// Reading `menu.size` below re-enters `menuNeedsUpdate`; without this the
    /// row resizing would recurse.
    private var syncingMenuWidth = false

    /// The microphone the user picked, kept because `AudioController.stop()`
    /// forgets its device across a trip through Receive. One value rather than
    /// a flag beside an id, so "off with a device remembered" cannot happen.
    private enum MicSelection { case system, off, device(String) }
    private var micSelection: MicSelection = .system

    /// Last read of the virtual camera, refreshed on menu opens and on the
    /// stats tick. Cached because every read walks the CoreMediaIO device list.
    private var virtualCamera = VirtualCamera.Status()

    private var cameraSubmenu: NSMenu!
    private var audioSubmenu: NSMenu!
    private var ndiSourceSubmenu: NSMenu!
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
        let saved = AppMode(rawValue: UserDefaults.standard.string(forKey: Self.modeDefaultsKey) ?? "") ?? .send
        modeState.withLock { $0 = saved }
        buildStatusItem()
        configurePipeline()
        apply(mode: saved)
        // After the status item, so that if Sparkle's updater fails to start —
        // it reports that with a modal alert a second later — the app is not a
        // lone dialog with nothing behind it.
        updaterController = UpdaterController()
        updaterController.onQuietUpdateStateChanged = { [weak self] pending in
            self?.updateAvailableItem.isHidden = !pending
        }
        checkForUpdatesItem.target = updaterController.menuTarget
        checkForUpdatesItem.action = updaterController.menuAction

        // An update replaces the bundle and so its ad-hoc signature, which macOS
        // may take as reason to drop the login item. Put it back if the user
        // asked for it — off the main thread, because both the status read and
        // the re-registration are synchronous XPC to the login-item daemon and
        // nothing on screen is waiting for them.
        DispatchQueue.global(qos: .utility).async { [launchAtLogin] in
            launchAtLogin.reconcile()
        }

        MainMenu.install(settingsTarget: self, settingsAction: #selector(openSettings(_:)))

        // ClipSync announces every discovery, pair and unpair. The settings
        // mirror only matters while someone is looking at it, so an app that has
        // never opened the window does no work here at all.
        clipSyncManager.onStateChanged = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.settingsWindow?.isVisible == true else { return }
                self.settingsModel?.refresh()
            }
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
        ndiReceiver.stop()
        ndiFinder.stop()
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
                                       accessibilityDescription: "OpenBeam")
            }
            button.setAccessibilityLabel("OpenBeam")
        }

        let menu = NSMenu()
        menu.delegate = self

        // --- Update notice ---
        // A background check that found something does not interrupt the user
        // (see `UpdaterController`); this is where they find out instead. Hidden
        // until there is something to say.
        updateAvailableItem = NSMenuItem(title: "Update available — Install…",
                                         action: #selector(installAvailableUpdate(_:)),
                                         keyEquivalent: "")
        updateAvailableItem.target = self
        updateAvailableItem.isHidden = true
        menu.addItem(updateAvailableItem)

        // --- Header bar ---
        let headerView = MenuRowView(frame: NSRect(x: 0, y: 0, width: Self.baseWidth, height: 30))

        // The version sits beside the name so a bug report can name the exact
        // build without anyone having to go looking for it.
        let title = NSMutableAttributedString(
            string: "OpenBeam",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                         .foregroundColor: NSColor.labelColor])
        title.append(NSAttributedString(
            string: "  \(Self.appVersion)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))

        let titleLabel = NSTextField(labelWithAttributedString: title)
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: Self.contentInsetX, y: (30 - titleLabel.frame.height) / 2)
        headerView.addSubview(titleLabel)

        let ghSize: CGFloat = 16
        let ghButton = NSButton(frame: NSRect(x: Self.baseWidth - Self.contentInsetX - ghSize,
                                              y: (30 - ghSize) / 2, width: ghSize, height: ghSize))
        ghButton.bezelStyle = .inline
        ghButton.isBordered = false
        if let img = NSImage(named: "GitHubMark") {
            img.size = NSSize(width: ghSize, height: ghSize)
            ghButton.image = img
        }
        ghButton.target = self
        ghButton.action = #selector(openGitHub(_:))
        headerView.addSubview(ghButton)

        headerView.layoutHandler = { bounds in
            ghButton.frame.origin.x = bounds.width - Self.contentInsetX - ghButton.frame.width
        }
        addRow(headerView, to: menu)

        // --- Mode tabs ---
        // A custom view rather than two menu items: clicking a menu item closes
        // the menu, and switching modes with the preview in sight is the point.
        let modeView = MenuRowView(frame: NSRect(x: 0, y: 0, width: Self.baseWidth, height: 32))
        let tabs = NSSegmentedControl(labels: ["Send", "Receive"],
                                      trackingMode: .selectOne,
                                      target: self,
                                      action: #selector(modeChanged(_:)))
        tabs.segmentDistribution = .fillEqually
        // A segmented control draws its bezel inside its frame — AppKit reports
        // how far in — so the frame is widened by that much to put the *bezel*
        // on the same inset as the preview and the meter.
        let bezel = tabs.alignmentRectInsets
        tabs.frame.origin = NSPoint(x: Self.contentInsetX - bezel.left, y: 3)
        tabs.frame.size.height = 26
        tabs.selectedSegment = (mode == .send) ? 0 : 1
        modeControl = tabs
        modeView.addSubview(tabs)
        modeView.layoutHandler = { bounds in
            tabs.frame.size.width = bounds.width - 2 * Self.contentInsetX + bezel.left + bezel.right
        }
        addRow(modeView, to: menu)

        // --- Live preview ---
        let container = MenuRowView(frame: NSRect(x: 0, y: 0, width: Self.baseWidth, height: 0))
        container.wantsLayer = true
        container.heightForWidth = Self.previewRowHeight(for:)

        previewLayer = CALayer()
        // No background: an empty preview shows the menu's own vibrant
        // material through it rather than a black slab.
        previewLayer.backgroundColor = nil
        previewLayer.cornerRadius = 6
        previewLayer.masksToBounds = true
        previewLayer.contentsGravity = .resizeAspect
        previewLayer.actions = ["contents": NSNull()]
        container.layer?.addSublayer(previewLayer)

        container.layoutHandler = { [weak self] bounds in
            self?.previewLayer?.frame = bounds.insetBy(dx: Self.contentInsetX, dy: Self.contentInsetY)
        }
        addRow(container, to: menu)

        // --- Audio level meter ---
        let meterHeight: CGFloat = 8
        let containerHeight: CGFloat = 18
        let meterContainer = MenuRowView(frame: NSRect(x: 0, y: 0, width: Self.baseWidth, height: containerHeight))
        meterContainer.wantsLayer = true

        let meterY = (containerHeight - meterHeight) / 2

        meterTrackLayer = CALayer()
        meterTrackLayer.frame = CGRect(x: Self.contentInsetX, y: meterY, width: 0, height: meterHeight)
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

        meterContainer.layoutHandler = { [weak self] bounds in
            guard let self, let track = self.meterTrackLayer else { return }
            track.frame.size.width = bounds.width - 2 * Self.contentInsetX
            // The fill is a fraction of the track, redrawn on the next tick.
            self.meterFillLayer.frame.size.width = min(self.meterFillLayer.frame.width, track.frame.width)
        }
        addRow(meterContainer, to: menu)

        menu.addItem(.separator())

        // --- Camera selection submenu ---
        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraSubmenu = NSMenu()
        cameraSubmenu.delegate = self
        cameraItem.submenu = cameraSubmenu
        add(cameraItem, to: menu, visibleIn: .send)

        // --- Microphone selection submenu ---
        let audioItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        audioSubmenu = NSMenu()
        audioSubmenu.delegate = self
        audioItem.submenu = audioSubmenu
        add(audioItem, to: menu, visibleIn: .send)

        // --- NDI source selection (Receive) ---
        let sourceItem = NSMenuItem(title: "NDI Source", action: nil, keyEquivalent: "")
        ndiSourceSubmenu = NSMenu()
        ndiSourceSubmenu.delegate = self
        sourceItem.submenu = ndiSourceSubmenu
        add(sourceItem, to: menu, visibleIn: .receive)

        // --- Virtual camera status (Receive) ---
        virtualCameraItem = NSMenuItem(title: "Virtual camera", action: nil, keyEquivalent: "")
        virtualCameraItem.target = self
        add(virtualCameraItem, to: menu, visibleIn: .receive)

        // An ordinary member of the send-only block: hiding it with the block
        // is what stops Receive showing two separators in a row.
        add(.separator(), to: menu, visibleIn: .send)

        // --- NDI source label + restart ---
        let ndiLabel = NSMenuItem(title: "NDI: \(NDISender.sourceName)", action: nil, keyEquivalent: "")
        ndiLabel.isEnabled = false
        add(ndiLabel, to: menu, visibleIn: .send)

        let restartNDI = NSMenuItem(title: "Restart NDI",
                                    action: #selector(restartNDISender(_:)),
                                    keyEquivalent: "")
        restartNDI.target = self
        add(restartNDI, to: menu, visibleIn: .send)

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

        // --- Settings and updates ---
        // The key equivalent is cosmetic: it only fires while this menu is open,
        // since a status item menu is not in a window's responder chain. The one
        // that works anywhere is in `MainMenu`.
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings(_:)),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Target and action are set once the updater exists; Sparkle's own
        // controller validates the item, so it greys itself out mid-session.
        checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        menu.addItem(checkForUpdatesItem)

        menu.addItem(.separator())

        // --- Quit ---
        let quitItem = NSMenuItem(title: "Quit OpenBeam",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Adds an item only one mode shows, stating that where the item is built
    /// instead of in a list at the other end of the builder.
    private func add(_ item: NSMenuItem, to menu: NSMenu, visibleIn mode: AppMode) {
        menu.addItem(item)
        itemVisibility.append((item, mode))
    }

    /// Adds a row whose contents are laid out from its own width, applying the
    /// layout once so the geometry is spelled in the handler and nowhere else.
    private func addRow(_ row: MenuRowView, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = row
        row.fit(to: Self.baseWidth)
        menuRows.append(row)
        menu.addItem(item)
    }

    private func addDisabledItem(to menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    // MARK: - Pipeline

    /// Wires the three frame sources to their sinks. Nothing is started here —
    /// `apply(mode:)` decides which half of the pipeline runs.
    private func configurePipeline() {
        cameraController.onFrame = { [weak self] pixelBuffer in
            guard let self else { return }

            self.ensureNDIStarted()
            self.record(width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer))
            self.ndiSender.send(pixelBuffer: pixelBuffer)

            // Built only when it will be shown: this is a full-resolution copy.
            guard self.wantsPreviewFrames, let image = Self.createCGImage(from: pixelBuffer) else { return }
            self.present(image)
        }

        audioController.onAudio = { [weak self] buffer in
            guard let self else { return }
            self.ensureNDIStarted()
            self.ndiSender.send(audioBuffer: buffer)
        }

        // In Receive the frames come off the network instead, at proxy
        // resolution: the full-resolution stream is the extension's business.
        ndiReceiver.onFrame = { [weak self] image in
            guard let self else { return }

            self.record(width: image.width, height: image.height)
            self.present(image)
        }
    }

    /// The frame counters behind the resolution and fps lines, written by
    /// whichever pipeline is running.
    private func record(width: Int, height: Int) {
        statsLock.withLock {
            $0.width = width
            $0.height = height
            $0.count += 1
        }
    }

    /// False when building a preview image would be thrown away — the menu is
    /// closed, or the intro animation owns the layer.
    private var wantsPreviewFrames: Bool { menuIsOpen && previewIntro != .running }

    /// Puts a frame on the preview layer. Called from the capture and receive
    /// threads; the layer itself is only ever touched on the main one.
    private func present(_ cgImage: CGImage) {
        guard wantsPreviewFrames else { return }

        if previewIntro == .pending {
            // Built here rather than on the main thread: the menu is opening
            // and its own animation is running there. A second frame can reach
            // this before the state flips, which only costs one extra ladder —
            // the main thread keeps whichever arrives first.
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

    // MARK: - Mode

    /// The one place a mode change happens. Send and Receive are exclusive, so
    /// each side is fully torn down before the other starts.
    private func apply(mode newMode: AppMode) {
        modeState.withLock { $0 = newMode }
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeDefaultsKey)
        modeControl?.selectedSegment = (newMode == .send) ? 0 : 1

        for (item, visibility) in itemVisibility { item.isHidden = visibility != newMode }

        // The counters describe one pipeline or the other, never a mix.
        statsLock.withLock { $0 = (0, 0, 0) }
        prevCaptureFrameCount = 0
        ndiReceiver.resetStats()
        ndiSender.resetStats()
        previewLayer?.contents = nil
        previewIntro = .pending

        switch newMode {
        case .send:
            cameraController.start(deviceID: cameraController.currentDeviceID)
            switch micSelection {
            case .system: audioController.start()
            case .device(let id): audioController.start(deviceID: id)
            case .off: break
            }

        case .receive:
            cameraController.stop()
            audioController.stop()
            // Takes our own source off the network: in Receive this machine is
            // a consumer, and leaving it advertised invites a loop.
            ndiSender.stop()

            refreshVirtualCamera()
            // The extension keeps its own selection across launches; ours is
            // only a fallback for when it has none.
            if virtualCamera.selectedSource == nil, let remembered = selectedNDISource {
                VirtualCamera.select(source: remembered)
                refreshVirtualCamera()
            }
        }

        syncReceiveSession()
        resetStatsDisplay()
    }

    /// Discovery and the preview receiver run exactly when this machine is
    /// receiving *and* the menu is on screen. Both facts live here rather than
    /// being re-checked at each of the four places that can change one of them.
    private func syncReceiveSession() {
        guard mode == .receive, menuIsOpen else {
            ndiReceiver.stop()
            ndiFinder.stop()
            return
        }

        ndiFinder.start()

        guard let source = currentSource else {
            ndiReceiver.stop()
            return
        }
        guard !(ndiReceiver.isRunning && ndiReceiver.sourceName == source) else { return }

        ndiReceiver.start(source: source)
    }

    /// The preview keeps 16:9 at whatever width the menu ends up with.
    private static func previewRowHeight(for width: CGFloat) -> CGFloat {
        ((width - 2 * contentInsetX) * 9 / 16).rounded() + 2 * contentInsetY
    }

    /// A menu is as wide as its longest text item, and AppKit stretches the
    /// item views to match. The rows are reset to the base width first, so a
    /// menu that grew for a long source name can shrink again when it goes.
    private func syncRowWidths(_ menu: NSMenu) {
        guard !syncingMenuWidth else { return }
        syncingMenuWidth = true
        defer { syncingMenuWidth = false }

        setRowWidths(Self.baseWidth)
        setRowWidths(min(Self.maxWidth, max(Self.baseWidth, menu.size.width)))
    }

    private func setRowWidths(_ width: CGFloat) {
        for row in menuRows { row.fit(to: width) }
    }

    /// The source last chosen here. The extension is the real owner of the
    /// selection; this only survives it being reinstalled or reset.
    private var selectedNDISource: String? {
        get { UserDefaults.standard.string(forKey: Self.ndiSourceDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.ndiSourceDefaultsKey) }
    }

    /// The source the virtual camera is on, or the one we would put it on. The
    /// extension owns the selection; ours only covers it having none.
    private var currentSource: String? { virtualCamera.selectedSource ?? selectedNDISource }

    /// Re-reads the virtual camera and restates the status line. Only called in
    /// Receive: the read walks the CoreMediaIO device list, which in Send would
    /// be paid at launch for a line that is hidden anyway.
    private func refreshVirtualCamera() {
        guard let item = virtualCameraItem else { return }

        virtualCamera = VirtualCamera.status()

        let title: String
        switch (virtualCamera.isInstalled, virtualCamera.selectedSource) {
        case (false, _):
            title = "Virtual camera not installed — get NDI Tools"
        case (true, nil):
            title = "Virtual camera: no source selected"
        case (true, let source?):
            title = Self.fittedTitle("Virtual camera: \(virtualCamera.isInUse ? "in use" : "idle") — ", source)
        }

        item.action = virtualCamera.isInstalled ? nil : #selector(openNDITools(_:))
        // Setting an unchanged title still invalidates the item, and this runs
        // once a second.
        if item.title != title { item.title = title }
    }

    /// Trims a source name so the menu stays within `maxWidth`. The rows follow
    /// the menu's width on their own; this is only the cap on how far it grows.
    private static func fittedTitle(_ prefix: String, _ source: String) -> String {
        // What AppKit puts around an item's text — the state column on the left
        // and the margin on the right. Measured: a 308 pt title made a 356 pt menu.
        let chrome: CGFloat = 48
        let budget = maxWidth - chrome
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]

        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: attributes).width
        }

        guard width(prefix + source) > budget else { return prefix + source }

        var trimmed = source
        while !trimmed.isEmpty, width(prefix + trimmed + "…") > budget {
            trimmed.removeLast()
        }
        return prefix + trimmed + "…"
    }

    private func ensureNDIStarted() {
        guard mode == .send else { return }
        if !ndiSender.isActive {
            if !ndiSender.start() {
                print("[OpenBeam] NDI unavailable")
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
        (prevFramesSent, prevBytesSent) = activeCounters
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
        switch mode {
        case .send:
            statsFPSItem.title = "Capture \(num(captureFPS, 1)) fps → NDI \(num(ndiFPS, 1)) fps"
            statsDataRateItem.title = "Capture \(num(captureMBps, 1)) MB/s | Wire \(num(wireMBps, 2)) MB/s"
            statsFramesSentItem.title = "Sent: \(formatCount(ndiSender.framesSent))"
            statsDroppedItem.title = "Dropped: \(formatCount(ndiSender.droppedFrames))"

        case .receive:
            // The figures describe our proxy preview, not what the extension
            // pulls at full resolution — that traffic is in its process, not ours.
            statsFPSItem.title = "Preview \(num(captureFPS, 1)) fps"
            statsDataRateItem.title = "Preview \(num(captureMBps, 2)) MB/s"
            statsFramesSentItem.title = "Received: \(formatCount(ndiReceiver.framesReceived))"
            statsDroppedItem.title = "Source: \(ndiReceiver.sourceName ?? currentSource ?? "—")"
        }
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

    /// The frame and byte totals of whichever pipeline is running, so the seed
    /// and the tick cannot end up reading different ones.
    private var activeCounters: (frames: Int64, bytes: Int64) {
        mode == .send
            ? (ndiSender.framesSent, ndiSender.bytesSent)
            : (ndiReceiver.framesReceived, ndiReceiver.bytesReceived)
    }

    private func updateStats() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - prevStatsTime
        guard elapsed > 0 else { return }

        let frameStats = statsLock.withLock { $0 }
        let captureFPS = Double(frameStats.count - prevCaptureFrameCount) / elapsed
        prevCaptureFrameCount = frameStats.count

        let (sent, totalBytes) = activeCounters
        let ndiSentFPS = Double(sent - prevFramesSent) / elapsed
        let bytesInInterval = totalBytes - prevBytesSent

        prevFramesSent = sent
        prevBytesSent = totalBytes
        prevStatsTime = now

        let dataRateMBps = (Double(bytesInInterval) / elapsed) / (1024.0 * 1024.0)

        renderStats(captureFPS: captureFPS,
                    ndiFPS: ndiSentFPS,
                    captureMBps: dataRateMBps,
                    wireMBps: netMonitor.bytesPerSecondOut / (1024.0 * 1024.0))

        if mode == .receive {
            // A call can pick the virtual camera up while the menu is open.
            refreshVirtualCamera()
        }
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
        // In Receive the audio is the source's, arriving with the proxy stream;
        // it is played by whatever app took the virtual microphone, not by us.
        let peak = (mode == .send) ? audioController.currentPeak : ndiReceiver.currentPeak
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

    @MainActor
    @objc private func openSettings(_ sender: Any) {
        if settingsWindow == nil {
            let model = SettingsModel(camera: cameraController,
                                      clipSync: clipSyncManager,
                                      updater: updaterController,
                                      launchAtLogin: launchAtLogin)
            settingsModel = model
            settingsWindow = SettingsWindowController(model: model)
        }
        settingsWindow?.show()
    }

    /// Brings up the update Sparkle already found in the background. Asking it
    /// to check again is what re-presents that update — it is still in hand, so
    /// nothing is downloaded twice.
    @MainActor
    @objc private func installAvailableUpdate(_ sender: Any) {
        updaterController.checkForUpdates()
    }

    @objc private func openGitHub(_ sender: Any) {
        NSWorkspace.shared.open(Self.repoURL)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        apply(mode: sender.selectedSegment == 0 ? .send : .receive)
    }

    @objc private func selectNDISource(_ sender: NSMenuItem) {
        let source = sender.representedObject as? String
        selectedNDISource = source
        VirtualCamera.select(source: source)
        refreshVirtualCamera()
    }

    @objc private func openNDITools(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(VirtualCamera.toolsDownloadURL)
    }

    @objc private func restartNDISender(_ sender: NSMenuItem) {
        _ = ndiSender.restart()
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? String else { return }
        cameraController.switchCamera(deviceID: deviceID)
    }

    @objc private func selectAudio(_ sender: NSMenuItem) {
        // Remembered so a trip through Receive, which stops the controller,
        // does not silently bring the default microphone back.
        if let deviceID = sender.representedObject as? String {
            micSelection = .device(deviceID)
            audioController.switchInput(deviceID: deviceID)
        } else {
            micSelection = .off
            audioController.stop()
        }
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            setMenuVisible(true)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusItem.menu {
            setMenuVisible(false)
        }
    }

    /// Everything that runs only while the menu is on screen, started and
    /// stopped from one place so the two halves cannot drift apart.
    private func setMenuVisible(_ visible: Bool) {
        menuIsOpen = visible

        guard visible else {
            stopLevelTimer()
            netMonitor.stop()
            stopStatsTimer()
            syncReceiveSession()
            // Release the full-resolution frame; it would otherwise be
            // retained for as long as the menu stays closed.
            previewLayer?.contents = nil
            previewLayer?.removeAllAnimations()
            previewIntro = .pending
            return
        }

        startLevelTimer()
        netMonitor.start()
        resetStatsDisplay()
        startStatsTimer()

        if mode == .receive { refreshVirtualCamera() }
        syncReceiveSession()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem.menu {
            syncRowWidths(menu)
        } else if menu === cameraSubmenu {
            updateCameraSubmenu(menu)
        } else if menu === audioSubmenu {
            updateAudioSubmenu(menu)
        } else if menu === ndiSourceSubmenu {
            updateNDISourceSubmenu(menu)
        }
    }

    private func updateNDISourceSubmenu(_ menu: NSMenu) {
        // Discovery starts with the menu, so the first open often finds nothing.
        populateSelectionMenu(menu,
                              entries: ndiFinder.sources.sorted().map { ($0, $0) },
                              currentID: currentSource,
                              action: #selector(selectNDISource(_:)),
                              includeNone: true,
                              emptyText: "Looking for sources…")

        if virtualCamera.isInstalled, !virtualCamera.canSelectSource {
            menu.addItem(.separator())
            _ = addDisabledItem(to: menu, title: "Choose the source in NDI Virtual Input")
        }
    }

    private func updateCameraSubmenu(_ menu: NSMenu) {
        populateSelectionMenu(menu,
                              entries: CameraController.availableCameras.map { ($0.localizedName, $0.uniqueID) },
                              currentID: cameraController.currentDeviceID,
                              action: #selector(selectCamera(_:)),
                              includeNone: false,
                              emptyText: "No cameras found")
    }

    private func updateAudioSubmenu(_ menu: NSMenu) {
        populateSelectionMenu(menu,
                              entries: AudioController.availableInputs.map { ($0.localizedName, $0.uniqueID) },
                              currentID: audioController.currentDeviceID,
                              action: #selector(selectAudio(_:)),
                              includeNone: true,
                              emptyText: "No microphones found")
    }

    /// The one shape every picker in this menu has: an optional None, the
    /// entries with a checkmark on the current one, and a disabled line when
    /// there is nothing to pick. Cameras, microphones and NDI sources all
    /// differ only in where the pairs come from.
    private func populateSelectionMenu(_ menu: NSMenu,
                                       entries: [(title: String, id: String)],
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
            if !entries.isEmpty {
                menu.addItem(.separator())
            }
        }

        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.state = (entry.id == currentID) ? .on : .off
            menu.addItem(item)
        }

        if entries.isEmpty {
            _ = addDisabledItem(to: menu, title: emptyText)
        }
    }
}
