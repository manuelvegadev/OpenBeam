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
    private let systemAudioTap = SystemAudioTap()
    private let ndiSender = NDISender()
    private let ndiFinder = NDIFinder()
    private let ndiReceiver = NDIReceiver()
    private let ndiAudioReceiver = NDIAudioReceiver()
    private let audioPlayer = AudioOutputPlayer()
    private let audioMonitor = AudioMonitor()
    private let audioHealth = AudioHealth()
    private let audioHealthNotifier = AudioHealthNotifier()
    /// Shown at the top of the menu when the audio path has been dropping
    /// blocks, and hidden the rest of the time — the same shape as the update
    /// notice above it, and for the same reason: a line that is always there
    /// saying "fine" is a line nobody reads when it stops saying it.
    private var audioHealthItem: NSMenuItem!
    /// Runs whether or not the menu is open. The fault this watches for
    /// happens in the middle of a call, which is exactly when nothing else in
    /// this app is running.
    private var healthTimer: Timer?
    private var statsAudioItems: [NSMenuItem] = []
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
    /// exclusive for video: receiving takes the camera down, so one machine
    /// never sends and receives frames at the same time.
    ///
    /// Audio is not on the tabs at all. Either machine can send a stream and
    /// play one, because the far end of a call is only worth having if it can
    /// be heard as well as seen.
    private enum AppMode: String { case send, receive }

    private static let modeDefaultsKey = "mode"

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// The project's home. The menu's GitHub button and the About pane's links
    /// both derive from this, so a rename cannot leave one of them behind.
    static let repoURL = URL(string: "https://github.com/manuelvegadev/OpenBeam")!
    private static let ndiSourceDefaultsKey = "ndiSource"
    /// Send keeps the key it has always had; Receive's is new, so an install
    /// that has never chosen keeps the behaviour it had before there was
    /// anything to choose.
    private static func audioSourceDefaultsKey(for mode: AppMode) -> String {
        mode == .send ? "audioSource" : "audioSourceReceive"
    }
    private static let playbackOutputDefaultsKey = "playbackOutput"
    private static let monitorOutputDefaultsKey = "monitorOutput"
    private static let listenSourceDefaultsKey = "listenSource"
    /// Stored for "send nothing", which a missing key cannot mean: that is a
    /// machine that has never chosen, and it sends its microphone.
    private static let offIdentifier = "off"

    /// Held in a lock because the capture and audio threads read it on every
    /// frame — `ensureNDIStarted` must not revive the sender just after Receive
    /// took our source off the network.
    private let modeState = OSAllocatedUnfairLock(initialState: AppMode.send)
    private var mode: AppMode { modeState.withLock { $0 } }
    private var modeControl: NSSegmentedControl!
    /// Which modes show which item, recorded as each is built.
    private var itemVisibility: [(item: NSMenuItem, modes: Set<AppMode>)] = []
    private var virtualCameraItem: NSMenuItem!
    /// Says whether this machine is publishing a source, in either mode.
    private var ndiStatusItem: NSMenuItem!
    /// Every picker carries its own answer in its title, so the menu says what
    /// this machine is set to without four submenus having to be opened.
    private var cameraItem: NSMenuItem!
    private var audioItem: NSMenuItem!
    private var sourceItem: NSMenuItem!
    private var listenItem: NSMenuItem!
    private var playbackItem: NSMenuItem!
    /// Where the monitor is playing. Shown only while it is: see `refreshMonitor`.
    private var monitorItem: NSMenuItem!
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
    /// The monitor button beside the meter, and the gap it keeps from it.
    private static let monitorButtonSize: CGFloat = 16
    private static let monitorButtonGap: CGFloat = 8
    /// The widest the menu is allowed to get. Past this a source name is
    /// trimmed rather than stretching the menu across the screen.
    private static let maxWidth: CGFloat = 460
    private var menuRows: [MenuRowView] = []
    /// Reading `menu.size` below re-enters `menuNeedsUpdate`; without this the
    /// row resizing would recurse.
    private var syncingMenuWidth = false

    /// The one audio source Send puts on the network. NDI carries a single
    /// audio stream, so a microphone and a machine's own output are
    /// alternatives rather than two switches.
    ///
    /// Kept here because `AudioController.stop()` forgets its device across a
    /// trip through Receive, and one value rather than a flag beside an id, so
    /// "off with a device remembered" cannot happen.
    private enum AudioSource: Equatable {
        case off
        /// Whatever `AVCaptureDevice.default(for: .audio)` resolves to.
        case defaultInput
        case input(uid: String)
        case output(AudioOutputTarget)
    }

    /// The audio source is remembered per mode, because the two roles send
    /// different things: the machine you sit at sends your voice, the one in
    /// the call sends what the call is saying. One setting for both would
    /// change what a machine publishes every time the tab was touched.
    ///
    /// Their defaults differ for the same reason. Send has always captured a
    /// microphone; Receive has always published nothing at all, and a client
    /// that put its microphone on the network the moment it was updated would
    /// be a surprise nobody asked for.
    private var audioSources: [AppMode: AudioSource] = [.send: .defaultInput, .receive: .off]

    private var audioSource: AudioSource {
        get { audioSources[mode] ?? .off }
        set {
            audioSources[mode] = newValue
            UserDefaults.standard.set(Self.identifier(for: newValue) ?? Self.offIdentifier,
                                      forKey: Self.audioSourceDefaultsKey(for: mode))
        }
    }

    /// The source Send listens to, which is the other machine's way back: the
    /// receiving machine is in a call, and this is how its side of it is heard
    /// here. Receive needs no such setting — it listens to the source it is
    /// already taking.
    private var selectedListenSource: String? {
        didSet { UserDefaults.standard.set(selectedListenSource, forKey: Self.listenSourceDefaultsKey) }
    }

    /// Where a machine plays what it is given, or nil for nowhere — which is the
    /// default, because a machine that starts making noise by itself the first
    /// time it receives is not a good surprise.
    /// What `startAudioCapture` last acted on. Starting a controller stops and
    /// reopens its device, so this is what makes running it again harmless —
    /// and being harmless is what lets it sit in `reconcile()` with the rest.
    private var appliedAudioSource: AudioSource?

    private var playbackTarget: AudioOutputTarget? {
        didSet {
            UserDefaults.standard.set(playbackTarget.map { Self.identifier(for: $0) },
                                      forKey: Self.playbackOutputDefaultsKey)
        }
    }

    /// Last read of the virtual camera, refreshed on menu opens and on the
    /// stats tick. Cached because every read walks the CoreMediaIO device list.
    private var virtualCamera = VirtualCamera.Status()

    private var cameraSubmenu: NSMenu!
    private var audioSubmenu: NSMenu!
    private var ndiSourceSubmenu: NSMenu!
    private var listenSubmenu: NSMenu!
    private var remoteScreenSubmenu: NSMenu!
    private var keepAwakeSubmenu: NSMenu!
    private var playbackSubmenu: NSMenu!
    private var monitorSubmenu: NSMenu!
    private var statsSubmenu: NSMenu!

    private var meterTrackLayer: CALayer!
    private var meterFillLayer: CALayer!
    /// The button beside the meter, which plays what the meter is showing.
    private var monitorButton: NSButton!
    /// Off at launch, and not remembered anywhere. Monitoring is something you
    /// do while chasing a problem, and a machine that comes up playing its own
    /// microphone out of its speakers is not a good surprise.
    private var isMonitoring = false
    /// What the button was last drawn as. `refreshMonitorButton` runs on the
    /// stats tick, and a new symbol image a second would be a redraw an hour
    /// for an answer that changes when the user changes something.
    private var monitorLook: MonitorLook?

    private enum MonitorLook { case unavailable, ready, playing }
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
        #if DEBUG
        if RemoteScreenTestHarness.runIfRequested() { return }
        #endif
        let saved = AppMode(rawValue: UserDefaults.standard.string(forKey: Self.modeDefaultsKey) ?? "") ?? .send
        modeState.withLock { $0 = saved }
        for mode in [AppMode.send, .receive] {
            guard let stored = UserDefaults.standard.string(forKey: Self.audioSourceDefaultsKey(for: mode))
            else { continue }
            audioSources[mode] = Self.audioSource(for: stored)
        }
        playbackTarget = Self.outputTarget(for: UserDefaults.standard.string(forKey: Self.playbackOutputDefaultsKey))
        selectedMonitorOutput = Self.outputTarget(for: UserDefaults.standard.string(forKey: Self.monitorOutputDefaultsKey))
        selectedListenSource = UserDefaults.standard.string(forKey: Self.listenSourceDefaultsKey)
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
        clipSyncManager.remoteScreen.onStateChanged = { [weak self] in
            guard let self else { return }
            self.updateRemoteScreenIndicator()
            if self.settingsWindow?.isVisible == true { self.settingsModel?.refresh() }
        }
        clipSyncManager.start()
        KeepAwake.shared.launch()
        // The menu reads its state when it opens; only settings needs telling.
        KeepAwake.shared.onChange = { [weak self] in
            guard let self, self.settingsWindow?.isVisible == true else { return }
            self.settingsModel?.refresh()
        }
        startHealthTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeepAwake.shared.shutdown()
        healthTimer?.invalidate()
        healthTimer = nil
        stopStatsTimer()
        stopLevelTimer()
        cameraController.stop()
        audioController.stop()
        systemAudioTap.stop()
        ndiSender.stop()
        ndiReceiver.stop()
        ndiAudioReceiver.stop()
        audioPlayer.stop()
        audioMonitor.stop()
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

        // --- Audio health notice ---
        // Hidden until there is something to say. Pressing it starts the
        // count again, which is what you want the moment you have read it:
        // the question is never "has it ever broken" but "is it breaking now".
        audioHealthItem = NSMenuItem(title: "",
                                     action: #selector(resetAudioHealth(_:)),
                                     keyEquivalent: "")
        audioHealthItem.target = self
        audioHealthItem.toolTip = "Click to start counting again"
        audioHealthItem.isHidden = true
        menu.addItem(audioHealthItem)

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
        //
        // The meter and, beside it, the way to hear what it is showing. A bar
        // moving says audio is arriving; it does not say it is arriving
        // intact, and that is the question a stream that has gone robotic
        // raises. The button is here rather than in a submenu because the
        // answer is worth having while the bar is in front of you.
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

        let monitorSize = Self.monitorButtonSize
        let monitor = NSButton(frame: NSRect(x: Self.baseWidth - Self.contentInsetX - monitorSize,
                                             y: (containerHeight - monitorSize) / 2,
                                             width: monitorSize, height: monitorSize))
        monitor.bezelStyle = .inline
        monitor.isBordered = false
        monitor.target = self
        monitor.action = #selector(toggleAudioMonitor(_:))
        monitorButton = monitor
        meterContainer.addSubview(monitor)
        refreshMonitor()

        meterContainer.layoutHandler = { [weak self] bounds in
            guard let self, let track = self.meterTrackLayer else { return }
            monitor.frame.origin.x = bounds.width - Self.contentInsetX - monitorSize
            track.frame.size.width = max(0, bounds.width - 2 * Self.contentInsetX
                                            - Self.monitorButtonGap - monitorSize)
            // The fill is a fraction of the track, redrawn on the next tick.
            self.meterFillLayer.frame.size.width = min(self.meterFillLayer.frame.width, track.frame.width)
        }
        addRow(meterContainer, to: menu)

        // --- What this machine puts on the network ---
        //
        // Two headings rather than one list. Three of these items are about
        // audio and each is about a different half of it — what is sent, what
        // is heard, where it comes out — and without the headings the menu
        // reads as three ways of saying the same thing.
        menu.addItem(.sectionHeader(title: "Sending"))

        cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraSubmenu = NSMenu()
        cameraSubmenu.delegate = self
        cameraItem.submenu = cameraSubmenu
        add(cameraItem, to: menu, visibleIn: [.send])

        // In both modes: the machine in the call is the one whose audio the
        // other end wants, and it is the one in Receive.
        audioItem = NSMenuItem(title: "Audio", action: nil, keyEquivalent: "")
        audioSubmenu = NSMenu()
        audioSubmenu.delegate = self
        audioItem.submenu = audioSubmenu
        add(audioItem, to: menu)

        // Under this heading because it is the answer to "is anything of mine
        // going out at all", which in Receive depends on the item above it.
        ndiStatusItem = NSMenuItem(title: "NDI: \(NDISender.sourceName)", action: nil, keyEquivalent: "")
        ndiStatusItem.isEnabled = false
        add(ndiStatusItem, to: menu)

        let restartNDI = NSMenuItem(title: "Restart NDI",
                                    action: #selector(restartNDISender(_:)),
                                    keyEquivalent: "")
        restartNDI.target = self
        add(restartNDI, to: menu)

        // --- What this machine takes off the network ---
        menu.addItem(.sectionHeader(title: "Receiving"))

        // Receive's picker feeds the virtual camera, and the audio that comes
        // with it is what this machine plays. Send has no such stream, so it
        // is told which source to listen to instead.
        sourceItem = NSMenuItem(title: "NDI Source", action: nil, keyEquivalent: "")
        ndiSourceSubmenu = NSMenu()
        ndiSourceSubmenu.delegate = self
        sourceItem.submenu = ndiSourceSubmenu
        add(sourceItem, to: menu, visibleIn: [.receive])

        listenItem = NSMenuItem(title: "Listen to", action: nil, keyEquivalent: "")
        listenSubmenu = NSMenu()
        listenSubmenu.delegate = self
        listenItem.submenu = listenSubmenu
        add(listenItem, to: menu, visibleIn: [.send])

        playbackItem = NSMenuItem(title: "Play audio on", action: nil, keyEquivalent: "")
        playbackSubmenu = NSMenu()
        playbackSubmenu.delegate = self
        playbackItem.submenu = playbackSubmenu
        add(playbackItem, to: menu)

        // Where the monitor is playing, which is only a question while it is
        // playing. Hidden the rest of the time rather than sitting there
        // saying nothing: this menu already carries four audio choices, and a
        // fifth that matters for one minute in a hundred is a fifth too many.
        //
        // Deliberately not registered with `itemVisibility`: that answers
        // "which tab", and this line is answered by whether the button is lit.
        // Two owners of one `isHidden` is how a row comes back from a tab
        // switch that nobody asked to see it.
        monitorItem = NSMenuItem(title: "Monitoring on", action: nil, keyEquivalent: "")
        monitorSubmenu = NSMenu()
        monitorSubmenu.delegate = self
        monitorItem.submenu = monitorSubmenu
        monitorItem.isHidden = true
        menu.addItem(monitorItem)

        virtualCameraItem = NSMenuItem(title: "Virtual camera", action: nil, keyEquivalent: "")
        virtualCameraItem.target = self
        add(virtualCameraItem, to: menu, visibleIn: [.receive])

        // Seeing and driving another Mac is independent of the camera tabs.
        let remoteScreenItem = NSMenuItem(title: "Remote Screen", action: nil, keyEquivalent: "")
        remoteScreenSubmenu = NSMenu()
        remoteScreenSubmenu.delegate = self
        remoteScreenItem.submenu = remoteScreenSubmenu
        add(remoteScreenItem, to: menu)

        let keepAwakeItem = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
        keepAwakeSubmenu = NSMenu()
        keepAwakeSubmenu.delegate = self
        keepAwakeItem.submenu = keepAwakeSubmenu
        add(keepAwakeItem, to: menu)

        menu.addItem(.separator())

        // --- Statistics (collapsible via submenu) ---
        let statsItem = NSMenuItem(title: "Statistics", action: nil, keyEquivalent: "")
        statsSubmenu = NSMenu()

        statsResolutionItem = addDisabledItem(to: statsSubmenu, title: "—")
        statsFPSItem = addDisabledItem(to: statsSubmenu, title: "—")
        statsDataRateItem = addDisabledItem(to: statsSubmenu, title: "—")
        statsFramesSentItem = addDisabledItem(to: statsSubmenu, title: "Sent: 0")
        statsDroppedItem = addDisabledItem(to: statsSubmenu, title: "Dropped: 0")

        // The three stages audio passes through, each reporting what only it
        // can see. Always present, saying "OK" when there is nothing wrong:
        // in here, unlike in the menu above, the absence of a fault is the
        // answer somebody came looking for.
        statsSubmenu.addItem(.separator())
        statsSubmenu.addItem(.sectionHeader(title: "Audio"))
        statsAudioItems = (0..<4).map { _ in addDisabledItem(to: statsSubmenu, title: "—") }

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

    /// Adds an item and states, where the item is built rather than in a list
    /// at the other end of the builder, which modes show it. Everything goes
    /// through here — including the rows both modes show, which would otherwise
    /// be indistinguishable from a row whose visibility someone forgot to
    /// state.
    private func add(_ item: NSMenuItem,
                     to menu: NSMenu,
                     visibleIn modes: Set<AppMode> = [.send, .receive]) {
        menu.addItem(item)
        itemVisibility.append((item, modes))
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
        // Every stage reports to the same counter, which is what lets the
        // culprit be named rather than guessed at. The monitor's own player is
        // deliberately left out: its underruns are its own.
        audioController.health = audioHealth
        systemAudioTap.health = audioHealth
        ndiSender.health = audioHealth
        audioPlayer.health = audioHealth

        cameraController.onFrame = { [weak self] pixelBuffer in
            guard let self else { return }

            self.record(width: CVPixelBufferGetWidth(pixelBuffer),
                        height: CVPixelBufferGetHeight(pixelBuffer))
            self.ndiSender.send(pixelBuffer: pixelBuffer)

            // Built only when it will be shown: this is a full-resolution copy.
            guard self.wantsPreviewFrames, let image = Self.createCGImage(from: pixelBuffer) else { return }
            self.present(image)
        }

        // Each capture goes to the wire and, when the monitor is on, to this
        // machine's own output as well. The monitor is handed the same buffer
        // list the sender is, rather than a copy taken somewhere further down:
        // what it plays has to be what left, or it is answering a different
        // question from the one that was asked.
        audioController.onAudio = { [weak self] buffer in
            guard let self else { return }
            self.ndiSender.send(audioBuffer: buffer)
            self.audioMonitor.play(buffer.audioBufferList, format: buffer.format)
        }

        // The other thing that can fill the same stream. Only one of the two
        // is ever running — `startAudioCapture` sees to that — so they never
        // reach the sender at once.
        systemAudioTap.onAudio = { [weak self] bufferList, format in
            guard let self else { return }
            self.ndiSender.send(audio: bufferList, format: format)
            self.audioMonitor.play(bufferList, format: format)
        }

        // In Receive the audio comes off the network instead, and goes to a
        // speaker on this machine rather than to NDI.
        ndiAudioReceiver.onAudio = { [weak self] audio in
            guard let self else { return }
            self.audioHealth.received(frames: audio.frameCount,
                                      sampleRate: audio.sampleRate,
                                      channels: audio.channelCount)
            self.audioPlayer.play(audio)
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

    /// The one place a mode change happens. The two video pipelines are
    /// exclusive, so each is fully torn down before the other starts; audio
    /// crosses the change untouched, apart from the source coming down when
    /// Receive is left with nothing to put on it.
    private func apply(mode newMode: AppMode) {
        modeState.withLock { $0 = newMode }
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeDefaultsKey)
        modeControl?.selectedSegment = (newMode == .send) ? 0 : 1

        // Monitoring does not follow a tab switch. What it plays is decided by
        // the tab — the capture on one, the received stream on the other — and
        // a microphone that starts coming out of the speakers because someone
        // looked at the other tab is the one surprise worth ruling out here.
        isMonitoring = false

        for (item, modes) in itemVisibility { item.isHidden = !modes.contains(newMode) }

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

        case .receive:
            cameraController.stop()
            refreshVirtualCamera()
            // The extension keeps its own selection across launches; ours is
            // only a fallback for when it has none.
            if virtualCamera.selectedSource == nil, let remembered = selectedNDISource {
                VirtualCamera.select(source: remembered)
                refreshVirtualCamera()
            }
        }

        reconcile()
        // The menu stays open across a tab switch, so the titles have to
        // follow; every other mutation closes it and they are restated on the
        // next open.
        refreshTitles()
        resetStatsDisplay()
    }

    /// Everything that follows from the settings, run together. Each of these
    /// is a reconciler that compares what should be running with what is, so
    /// running all four costs nothing when nothing changed — and that is what
    /// lets every mutation call one function instead of choosing a subset.
    /// Choosing the subset per call site is how a stream comes to be silently
    /// not started.
    private func reconcile() {
        startAudioCapture()
        syncAudioMonitor()
        syncNDIPublishing()
        syncReceiveSession()
        syncAudioPlayback()
    }

    /// Runs the capture the chosen source needs and stops the other one. NDI
    /// carries a single audio stream, so the two are alternatives — and this
    /// runs in either mode, because the audio a machine sends is not tied to
    /// whether it is the one sending video.
    private func startAudioCapture() {
        guard appliedAudioSource != audioSource else { return }
        appliedAudioSource = audioSource

        switch audioSource {
        case .off:
            audioController.stop()
            systemAudioTap.stop()
        case .defaultInput:
            systemAudioTap.stop()
            audioController.start()
        case .input(let uid):
            systemAudioTap.stop()
            audioController.start(deviceID: uid)
        case .output(let target):
            audioController.stop()
            systemAudioTap.start(target: target)
        }
    }

    private enum MonitoredAudio { case capture, received }

    /// What the monitor button offers to play, which is the audio the meter is
    /// showing: the capture this machine is putting on the network — the audio
    /// that ends up at the virtual microphone at the other end — or the stream
    /// it is taking off it, which is what its own virtual microphone is being
    /// given.
    ///
    /// Nil when there is nothing to hear, and nil when it is already coming out
    /// of a speaker here: a second engine on the same audio would only play it
    /// twice.
    private var monitoredAudio: MonitoredAudio? {
        switch mode {
        case .send:
            return publishesAudio ? .capture : nil
        case .receive:
            guard playbackTarget == nil else { return nil }
            return listenSource != nil ? .received : nil
        }
    }

    private var monitorsCapture: Bool { isMonitoring && monitoredAudio == .capture }
    private var monitorsReceived: Bool { isMonitoring && monitoredAudio == .received }

    /// Where the monitor plays, once the user has said.
    ///
    /// Its own setting rather than a reuse of "Play audio on", because the two
    /// answer different questions: that one is where a stream plays for as
    /// long as it runs, and on the machine sitting in the call the right
    /// answer to it is "nowhere" — playing the far end into that room would
    /// only put it back into the meeting. Monitoring still has to come out
    /// somewhere, and on exactly that machine it could not: a Mac whose output
    /// is being tapped is a Mac whose default output is a virtual device, and
    /// the monitor played into it and was never heard.
    private var selectedMonitorOutput: AudioOutputTarget? {
        didSet {
            UserDefaults.standard.set(selectedMonitorOutput.map { Self.identifier(for: $0) },
                                      forKey: Self.monitorOutputDefaultsKey)
        }
    }

    /// Where it plays now. Falling through to the playback device and then to
    /// the system default is what keeps a Mac with speakers from needing the
    /// setting at all.
    private var monitorOutput: AudioOutputTarget {
        selectedMonitorOutput ?? playbackTarget ?? .systemDefault
    }

    /// The monitor's own player, which exists for the capture alone. Nothing
    /// else plays what a machine is sending, whereas the received stream
    /// already has a player behind "Play audio on" — so monitoring that is
    /// `playbackDestination`'s business, not this one's.
    private func syncAudioMonitor() {
        // A monitor left on with nothing to play is a lit button that does
        // nothing: the source it was turned on for has been switched off or
        // taken away.
        if monitoredAudio == nil { isMonitoring = false }

        if monitorsCapture {
            audioMonitor.start(target: monitorOutput)
        } else {
            audioMonitor.stop()
        }
    }

    /// The source this machine plays. Receive is already taking one, so that is
    /// the one to listen to; Send has to be told which of the machines on the
    /// network is the one talking back.
    private var listenSource: String? {
        switch mode {
        case .receive:  return currentSource
        case .send:     return selectedListenSource
        }
    }

    /// Playback follows the same rule as the camera extension rather than the
    /// preview's: it runs whenever this machine has something to play and
    /// somewhere to play it, menu open or closed. Listening to the other
    /// machine is not something you do only while a menu is on screen.
    private func syncAudioPlayback() {
        guard let destination = playbackDestination, let source = listenSource else {
            if ndiAudioReceiver.isRunning { audioHealth.streamEnded() }
            ndiAudioReceiver.stop()
            audioPlayer.stop()
            return
        }

        audioPlayer.start(target: destination)

        guard !(ndiAudioReceiver.isRunning && ndiAudioReceiver.sourceName == source) else { return }
        audioHealth.streamEnded()
        ndiAudioReceiver.start(source: source)
    }

    /// Where the received stream comes out. The monitor is the second reason
    /// to play it at all: the user chose nowhere, and pressing the button asks
    /// to hear it anyway. Deliberately not written back to `playbackTarget` —
    /// monitoring is a way of listening to a stream for a minute, not a routing
    /// choice to be remembered and found still in force a week later.
    private var playbackDestination: AudioOutputTarget? {
        if let playbackTarget { return playbackTarget }
        return monitorsReceived ? monitorOutput : nil
    }

    /// Discovery and the preview receiver run while the menu is on screen —
    /// discovery in either mode, because Send's "Listen to" picker needs the
    /// same list Receive's does, and the preview only where there is one.
    /// Both facts live here rather than being re-checked at each of the places
    /// that can change one of them.
    private func syncReceiveSession() {
        guard menuIsOpen else {
            ndiReceiver.stop()
            ndiFinder.stop()
            return
        }

        ndiFinder.start()

        guard mode == .receive, let source = currentSource else {
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

    /// Whether this machine has audio to put on the network. In Receive that
    /// is the whole of what it publishes.
    private var publishesAudio: Bool { audioSource != .off }

    /// Send always has a camera to publish; Receive publishes only what its
    /// audio picker says. Stated once, because the sender's lifecycle and the
    /// line that reports it have to agree.
    private var shouldPublish: Bool { mode == .send || publishesAudio }

    /// Puts the source on the network, or takes it off when there is nothing
    /// left to put on it — which in Receive is what turning audio off means.
    /// Send keeps its source either way: the camera is still on it.
    ///
    /// The sender's only owner. It used to come up on the first frame or
    /// buffer a capture delivered, which a microphone does from the moment it
    /// opens — so the difference never showed until a tapped output, which on
    /// macOS 26 runs no I/O cycle at all while its device is idle. A machine
    /// that had chosen to send its system audio then stayed invisible on the
    /// network until something happened to play on it, and the other end cannot
    /// pick a source it cannot see.
    ///
    /// Being the only owner is also what lets the capture callbacks be three
    /// lines: they had to ask, per frame and per buffer, a question that only
    /// changes when the user changes something.
    private func syncNDIPublishing() {
        if shouldPublish {
            if !ndiSender.isActive, !ndiSender.start() {
                print("[OpenBeam] NDI unavailable")
            }
        } else if ndiSender.isActive {
            ndiSender.stop()
        }
        refreshNDIStatus()
    }

    /// Restates every picker's title from what it is actually set to. Called
    /// before the menu is shown rather than kept in step from each place that
    /// can change one of them: the answers come from the controllers, and the
    /// controllers change on their own — a device is unplugged, a microphone
    /// is refused, the default output moves.
    private func refreshTitles() {
        guard let cameraItem else { return }

        cameraItem.title = Self.fittedTitle("Camera: ", cameraName ?? "None")
        audioItem.title = Self.fittedTitle("Audio: ", audioDescription)
        sourceItem.title = Self.fittedTitle("NDI Source: ", currentSource ?? "None")
        listenItem.title = Self.fittedTitle("Listen to: ", selectedListenSource ?? "None")
        playbackItem.title = Self.fittedTitle("Play audio on: ", Self.name(of: playbackTarget))
        refreshMonitor()
    }

    private var cameraName: String? {
        guard let id = cameraController.currentDeviceID else { return nil }
        return AVCaptureDevice(uniqueID: id)?.localizedName
    }

    /// Names the kind as well as the device. "Mic" and "System audio" are the
    /// distinction the whole picker exists to make, and a device name alone
    /// does not carry it: plenty of devices are both an input and an output.
    private var audioDescription: String {
        switch audioSource {
        case .off:
            return "None"
        case .defaultInput, .input:
            let running = audioController.currentDeviceID.flatMap { AVCaptureDevice(uniqueID: $0)?.localizedName }
            if let running { return "Mic — \(running)" }
            if case .input(let uid) = audioSource,
               let named = AVCaptureDevice(uniqueID: uid)?.localizedName { return "Mic — \(named)" }
            return "Mic — system microphone"
        case .output(let target):
            return "System audio — \(Self.name(of: target))"
        }
    }

    private static func name(of target: AudioOutputTarget?) -> String {
        switch target {
        case nil:                   return "None"
        case .systemDefault:        return "Default output"
        case .device(let uid):      return AudioDevices.device(uid: uid)?.name ?? uid
        }
    }

    /// The monitor's button and its line, restated together because they are
    /// two halves of one answer.
    ///
    /// The button says whether there is anything to listen to, whether it is
    /// playing, and — in the tooltip — which of the two streams pressing it
    /// would play. That last one matters: the button means "my microphone" on
    /// one tab and "the far end" on the other, and nothing else on the row
    /// says which. The line says where it is coming out, which is the question
    /// a monitor that is plainly on and plainly silent raises.
    private func refreshMonitor() {
        guard let monitorButton else { return }

        let monitored = monitoredAudio
        let playing = isMonitoring && monitored != nil
        let look: MonitorLook = monitored == nil ? .unavailable : (playing ? .playing : .ready)

        if look != monitorLook {
            monitorLook = look
            monitorButton.isEnabled = look != .unavailable
            monitorButton.image = Self.headphones(playing ? .controlAccentColor
                                                  : (monitored == nil ? .tertiaryLabelColor : .secondaryLabelColor))
            monitorButton.setAccessibilityLabel(playing ? "Stop monitoring audio" : "Monitor audio")
        }

        switch (playing, monitored) {
        case (true, _):
            monitorButton.toolTip = "Stop listening"
        case (false, .capture):
            monitorButton.toolTip = "Listen to what this Mac is sending — on headphones, "
                + "or the microphone will hear it back"
        case (false, .received):
            monitorButton.toolTip = "Listen to what this Mac is receiving"
        case (false, nil):
            monitorButton.toolTip = (playbackTarget != nil && listenSource != nil)
                ? "Already playing on \(Self.name(of: playbackTarget))"
                : "Nothing to listen to"
        }

        monitorItem?.isHidden = !playing
        if playing {
            let title = Self.fittedTitle("Monitoring on: ", Self.name(of: monitorOutput))
            if monitorItem.title != title { monitorItem.title = title }
        }
    }

    /// The button's symbol, with its colour drawn into it rather than left to
    /// the button to apply.
    ///
    /// A borderless button in a menu item view ignores `contentTintColor` and
    /// draws a template image dark — which on this menu is a control nobody
    /// can see. Colouring the image takes the question of whose appearance is
    /// in force out of the drawing, and resolving the colour here rather than
    /// in a drawing handler is what makes it the menu's: a handler runs later,
    /// against the same appearance that got it wrong.
    private static func headphones(_ color: NSColor) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)
        else { return nil }

        let bounds = NSRect(x: 0, y: 0, width: monitorButtonSize, height: monitorButtonSize)
        symbol.size = bounds.size

        let image = NSImage(size: bounds.size)
        image.lockFocus()
        symbol.draw(in: bounds)
        color.set()
        bounds.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }

    /// The source line, which in Receive depends on whether audio is being
    /// sent back. Cheap enough for the stats tick, and that is what keeps it
    /// honest when the sender comes up on the first buffer rather than here.
    private func refreshNDIStatus() {
        guard let ndiStatusItem else { return }
        let title = ndiSender.isActive ? "NDI: \(NDISender.sourceName)" : "NDI: not publishing"
        if ndiStatusItem.title != title { ndiStatusItem.title = title }
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
            // A call can pick the virtual camera up while the menu is open, and
            // the source can be changed in NDI Virtual Input — which is how a
            // change made outside this app reaches the playback below.
            refreshVirtualCamera()
        }

        reconcile()
        // After `reconcile`, which is what turns a monitor off when the source
        // it was playing has gone.
        refreshMonitor()
        updateAudioHealth()
    }

    // MARK: - Audio Health

    /// Every 5 seconds, awake or not. Often enough that a burst is noticed
    /// while it is still happening, rare enough to be free: the reading is a
    /// lock and a sum over sixty small structs.
    private func startHealthTimer() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.updateAudioHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
        updateAudioHealth()
    }

    private func updateAudioHealth() {
        let report = audioHealth.report

        if let stage = report.stage, report.faults > 0 {
            let title = "Audio: " + AudioHealthNotifier.summary(report, stage: stage)
            if audioHealthItem.title != title { audioHealthItem.title = title }
            audioHealthItem.isHidden = false
        } else {
            audioHealthItem.isHidden = true
        }

        audioHealthNotifier.consider(report)
        if menuIsOpen { renderAudioStats(report) }
    }

    /// The stage-by-stage detail. Durations as well as counts, because "late"
    /// and "how late" are different questions and only the second one says
    /// whether the margin was ever close.
    private func renderAudioStats(_ report: AudioHealth.Report) {
        guard statsAudioItems.count == 4 else { return }

        // One decimal below 10 ms: the interesting figures here are fractions
        // of a millisecond, and rounding them all to "0 ms" hides whether the
        // margin was ever close.
        func ms(_ seconds: Double) -> String {
            let value = seconds * 1000
            return String(format: value < 10 ? "%.1f ms" : "%.0f ms", value)
        }

        // "OK" is only worth printing about something that ran. A stage that
        // is switched off saying it is fine is the same false answer as a
        // meter that reads zero because nothing is plugged in.
        let capturing = publishesAudio
        let receiving = ndiAudioReceiver.isRunning

        let lines = [
            !capturing ? "Capture: not sending audio"
                : report.captureLate > 0
                ? "Capture: \(report.captureLate) late, worst \(ms(report.worstWork))"
                : "Capture: OK, worst \(ms(report.worstWork))",
            !capturing ? "NDI send: —" : "NDI send: worst \(ms(report.worstSend))",
            !receiving ? "Network: not receiving audio"
                : report.networkGaps > 0
                ? "Network: \(report.networkGaps) gaps, worst \(ms(report.worstGap))"
                : (report.formatChanges > 0 ? "Network: \(report.formatChanges) format changes" : "Network: OK"),
            !receiving ? "Playback: —"
                : report.underruns + report.driftDrops + report.rebuilds > 0
                ? "Playback: \(report.underruns) dry, \(report.driftDrops) drift, \(report.rebuilds) rebuilds"
                : "Playback: OK",
        ]
        for (item, line) in zip(statsAudioItems, lines) where item.title != line {
            item.title = line
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
        let peak = currentAudioPeak
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

    /// The audio each mode is about: what Send is putting on the network, and
    /// what Receive is taking off it. A machine now has both — Send can listen
    /// to the far end and Receive can send its audio back — so the meter shows
    /// the other one only when the first is silent for want of being switched
    /// on at all.
    ///
    /// In Receive the played stream is preferred over the proxy one: it is the
    /// same audio, seen at full quality instead of through the preview.
    private var currentAudioPeak: Float {
        switch mode {
        case .send:
            return capturePeak ?? (audioPlayer.isPlaying ? audioPlayer.currentPeak : 0)
        case .receive:
            return audioPlayer.isPlaying ? audioPlayer.currentPeak : ndiReceiver.currentPeak
        }
    }

    /// The peak of whichever capture the audio picker asked for, and nil when
    /// it asked for none — taken from the choice rather than by asking each
    /// controller in turn whether it happens to be running, which was a policy
    /// written as a priority order and stated nowhere.
    private var capturePeak: Float? {
        switch audioSource {
        case .off:                  return nil
        case .defaultInput, .input: return audioController.currentPeak
        case .output:               return systemAudioTap.currentPeak
        }
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

    // MARK: - Remote screen

    /// One "View" line per paired Mac, and, while another Mac controls this one,
    /// who it is and a way to stop it.
    private func updateRemoteScreenSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let remote = clipSyncManager.remoteScreen
        let peers = clipSyncManager.pairedPeers.sorted { $0.displayName < $1.displayName }
        if let hostID = remote.hostingPeerID {
            let name = peers.first { $0.peerID == hostID }?.displayName ?? "Another Mac"
            _ = addDisabledItem(to: menu, title: "\(name) is controlling this Mac")
            let stop = NSMenuItem(title: "Stop Remote Control", action: #selector(stopRemoteControl(_:)), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
            menu.addItem(.separator())
        }
        if peers.isEmpty {
            _ = addDisabledItem(to: menu, title: "No paired Macs")
        }
        let online = Set(clipSyncManager.discoveredPeers.map(\.peerID))
        for peer in peers {
            let item = NSMenuItem(title: "View \(peer.displayName)", action: #selector(viewRemoteScreen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = peer.peerID
            item.state = remote.isViewing(peer.peerID) ? .on : .off
            item.isEnabled = online.contains(peer.peerID)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Remote Screen Settings…", action: #selector(openRemoteScreenSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    @objc private func viewRemoteScreen(_ sender: NSMenuItem) {
        guard let peerID = sender.representedObject as? String,
              let peer = clipSyncManager.pairedPeers.first(where: { $0.peerID == peerID }) else { return }
        clipSyncManager.remoteScreen.view(peer)
    }

    @objc private func stopRemoteControl(_ sender: Any) {
        clipSyncManager.remoteScreen.stopHosting()
    }

    @MainActor
    @objc private func openRemoteScreenSettings(_ sender: Any) {
        openSettings(sender)
        settingsWindow?.select(.remoteScreen)
    }

    /// While another Mac controls this one, the menu bar icon says so in color:
    /// the one place that is always on screen.
    private func updateRemoteScreenIndicator() {
        guard let button = statusItem.button else { return }
        let hosting = clipSyncManager.remoteScreen.hostingPeerID != nil
        button.contentTintColor = hosting ? .systemOrange : nil
        button.setAccessibilityLabel(hosting ? "OpenBeam — this Mac is being controlled" : "OpenBeam")
    }

    // MARK: - Keep awake

    private func updateKeepAwakeSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let awake = KeepAwake.shared
        if let until = awake.manualUntil {
            _ = addDisabledItem(to: menu, title: "On until \(until.formatted(date: .omitted, time: .shortened))")
        } else if awake.reasons.contains(.remoteControl), !awake.reasons.contains(.manual) {
            _ = addDisabledItem(to: menu, title: "On while this Mac is being controlled")
        }
        let off = NSMenuItem(title: "Off", action: #selector(keepAwakeOff(_:)), keyEquivalent: "")
        off.target = self
        off.state = awake.reasons.contains(.manual) ? .off : .on
        menu.addItem(off)
        let hours = DateComponentsFormatter()
        hours.unitsStyle = .full
        hours.allowedUnits = [.hour]
        for duration in KeepAwake.durations {
            let title = duration.flatMap { hours.string(from: $0).map { "For \($0)" } } ?? "Indefinitely"
            let item = NSMenuItem(title: title, action: #selector(keepAwakeFor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = duration
            // A timed session shows its end time above rather than a check here.
            item.state = duration == nil && awake.reasons.contains(.manual) && awake.manualUntil == nil ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let display = NSMenuItem(title: "Keep Display On", action: #selector(toggleKeepDisplayOn(_:)), keyEquivalent: "")
        display.target = self
        display.state = awake.keepsDisplayOn ? .on : .off
        menu.addItem(display)
        let lid = NSMenuItem(title: "Even With the Lid Closed", action: #selector(toggleLidClosed(_:)), keyEquivalent: "")
        lid.target = self
        lid.state = awake.staysAwakeLidClosed ? .on : .off
        menu.addItem(lid)
    }

    @objc private func keepAwakeOff(_ sender: Any) {
        KeepAwake.shared.stopManual()
    }

    @objc private func keepAwakeFor(_ sender: NSMenuItem) {
        KeepAwake.shared.startManual(for: sender.representedObject as? TimeInterval)
    }

    @objc private func toggleKeepDisplayOn(_ sender: Any) {
        KeepAwake.shared.keepsDisplayOn.toggle()
    }

    /// Asks for the one-time authorization the first time it is turned on.
    @objc private func toggleLidClosed(_ sender: Any) {
        let awake = KeepAwake.shared
        if !awake.staysAwakeLidClosed, !awake.lidClosedAuthorized {
            NSApp.activate(ignoringOtherApps: true)
            guard awake.authorizeLidClosed() else { return }
        }
        awake.staysAwakeLidClosed.toggle()
    }

    /// Brings up the update Sparkle already found in the background. Asking it
    /// to check again is what re-presents that update — it is still in hand, so
    /// nothing is downloaded twice.
    @MainActor
    @objc private func installAvailableUpdate(_ sender: Any) {
        updaterController.checkForUpdates()
    }

    /// Starts the minute again. What someone wants the moment they have read
    /// the line is to know whether it is still happening, and the only way to
    /// ask that is to clear what has already been counted.
    @objc private func resetAudioHealth(_ sender: NSMenuItem) {
        audioHealth.reset()
        updateAudioHealth()
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
        reconcile()
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
        audioSource = Self.audioSource(for: sender.representedObject as? String)
        reconcile()
    }

    @objc private func selectListenSource(_ sender: NSMenuItem) {
        selectedListenSource = sender.representedObject as? String
        reconcile()
    }

    /// The one place monitoring is turned on and off. Unlike every other
    /// control in this menu it changes nothing that is remembered — pressing it
    /// is a question about right now.
    @objc private func toggleAudioMonitor(_ sender: NSButton) {
        isMonitoring.toggle()
        reconcile()
        refreshMonitor()
    }

    @objc private func selectMonitorOutput(_ sender: NSMenuItem) {
        selectedMonitorOutput = Self.outputTarget(for: sender.representedObject as? String)
        reconcile()
        refreshMonitor()
    }

    @objc private func selectPlaybackOutput(_ sender: NSMenuItem) {
        playbackTarget = Self.outputTarget(for: sender.representedObject as? String)
        reconcile()
    }

    // MARK: - Naming a selection

    // The menu, the check mark and `UserDefaults` all name an audio selection
    // the same way, so a round trip through any of them cannot change what it
    // means. Device UIDs contain colons of their own, which is why only the
    // first one separates the kind from the id.

    private static func identifier(for source: AudioSource) -> String? {
        switch source {
        case .off:              return nil
        case .defaultInput:     return "input"
        case .input(let uid):   return "input:\(uid)"
        case .output(let target): return identifier(for: target)
        }
    }

    private static func identifier(for target: AudioOutputTarget) -> String {
        switch target {
        case .systemDefault:        return "output"
        case .device(let uid):      return "output:\(uid)"
        }
    }

    private static func audioSource(for identifier: String?) -> AudioSource {
        switch identifier {
        case nil, offIdentifier:    return .off
        case "input":               return .defaultInput
        case "output":              return .output(.systemDefault)
        default:
            guard let (kind, id) = split(identifier) else { return .off }
            return kind == "output" ? .output(.device(uid: id)) : .input(uid: id)
        }
    }

    private static func outputTarget(for identifier: String?) -> AudioOutputTarget? {
        guard case .output(let target) = audioSource(for: identifier) else { return nil }
        return target
    }

    private static func split(_ identifier: String?) -> (kind: String, id: String)? {
        guard let identifier else { return nil }
        let parts = identifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// What the audio picker puts its check mark on. An input reports the
    /// device that is actually running rather than the choice, so "the system
    /// microphone" ticks the microphone it resolved to; an output reports the
    /// choice, so "Default output" stays ticked when the default changes under
    /// it.
    private var audioSelectionID: String? {
        switch audioSource {
        case .off:                      return nil
        case .defaultInput, .input:
            return audioController.currentDeviceID.map { Self.identifier(for: .input(uid: $0)) } ?? nil
        case .output(let target):       return Self.identifier(for: target)
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
            reconcile()
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
        // Before the first stats tick, which is a second away: the audio
        // lines would otherwise read "—" for that second, which looks like an
        // answer and is not one.
        updateAudioHealth()

        if mode == .receive { refreshVirtualCamera() }
        reconcile()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem.menu {
            // Reading `menu.size` below re-enters this method; without the
            // guard here the re-entrant pass would restate every title — which
            // now means a device lookup each — to measure a width it is in the
            // middle of measuring.
            guard !syncingMenuWidth else { return }
            // Titles first: they are what the width is then measured from.
            refreshTitles()
            syncRowWidths(menu)
        } else if menu === cameraSubmenu {
            updateCameraSubmenu(menu)
        } else if menu === audioSubmenu {
            updateAudioSubmenu(menu)
        } else if menu === ndiSourceSubmenu {
            updateNDISourceSubmenu(menu)
        } else if menu === playbackSubmenu {
            updatePlaybackSubmenu(menu)
        } else if menu === monitorSubmenu {
            updateMonitorSubmenu(menu)
        } else if menu === listenSubmenu {
            updateListenSubmenu(menu)
        } else if menu === remoteScreenSubmenu {
            updateRemoteScreenSubmenu(menu)
        } else if menu === keepAwakeSubmenu {
            updateKeepAwakeSubmenu(menu)
        }
    }

    private func updateNDISourceSubmenu(_ menu: NSMenu) {
        // Discovery starts with the menu, so the first open often finds nothing.
        populateSelectionMenu(menu,
                              entries: otherSources.map { ($0, $0) },
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
        let microphones = AudioController.availableInputs.compactMap { device in
            Self.identifier(for: .input(uid: device.uniqueID)).map { (title: device.localizedName, id: $0) }
        }
        populateSelectionMenu(menu,
                              sections: [MenuSection(header: "Microphones", entries: microphones),
                                         MenuSection(header: "System audio", entries: Self.outputEntries())],
                              currentID: audioSelectionID,
                              action: #selector(selectAudio(_:)),
                              includeNone: true,
                              emptyText: "No audio devices found")
    }

    private func updateListenSubmenu(_ menu: NSMenu) {
        populateSelectionMenu(menu,
                              entries: otherSources.map { ($0, $0) },
                              currentID: selectedListenSource,
                              action: #selector(selectListenSource(_:)),
                              includeNone: true,
                              emptyText: "Looking for sources…")
    }

    /// Every source on the network except this machine's own, which both
    /// pickers have reason to leave out. Listening to yourself is a loop with a
    /// delay on it, and pointing the virtual camera at your own source would
    /// put a machine's own speakers into the call it is sitting in — which is
    /// newly possible now that Receive publishes its audio.
    ///
    /// NDI advertises a source as `HOST (name)`, and the name is ours.
    private var otherSources: [String] {
        let ours = "(\(NDISender.sourceName))"
        return ndiFinder.sources.filter { !$0.hasSuffix(ours) }.sorted()
    }

    private func updatePlaybackSubmenu(_ menu: NSMenu) {
        populateSelectionMenu(menu,
                              entries: Self.outputEntries(),
                              currentID: playbackTarget.map { Self.identifier(for: $0) },
                              action: #selector(selectPlaybackOutput(_:)),
                              includeNone: true,
                              emptyText: "No outputs found")
    }

    /// No None: the monitor is only asked where it plays while it is playing,
    /// and "nowhere" is what the button next to it already means. The tick
    /// sits on whatever the fallback resolved to when nothing has been chosen,
    /// so picking that same entry is a no-op rather than a surprise.
    private func updateMonitorSubmenu(_ menu: NSMenu) {
        populateSelectionMenu(menu,
                              entries: Self.outputEntries(),
                              currentID: Self.identifier(for: monitorOutput),
                              action: #selector(selectMonitorOutput(_:)),
                              includeNone: false,
                              emptyText: "No outputs found")
    }

    /// The outputs both audio pickers offer, headed by the one that means
    /// "whatever this Mac is playing through" rather than a fixed device.
    private static func outputEntries() -> [(title: String, id: String)] {
        [(title: "Default output", id: identifier(for: .systemDefault))]
            + AudioDevices.outputs().map { (title: $0.name, id: identifier(for: .device(uid: $0.uid))) }
    }

    /// A run of entries under one heading. Only the audio picker has more
    /// than one: microphones and outputs are different kinds of thing, and the
    /// list reads as a single jumble without saying so.
    private struct MenuSection {
        let header: String?
        let entries: [(title: String, id: String)]
    }

    /// The one shape every picker in this menu has: an optional None, the
    /// entries with a checkmark on the current one, and a disabled line when
    /// there is nothing to pick. Cameras, audio devices and NDI sources all
    /// differ only in where the pairs come from.
    private func populateSelectionMenu(_ menu: NSMenu,
                                       entries: [(title: String, id: String)],
                                       currentID: String?,
                                       action: Selector,
                                       includeNone: Bool,
                                       emptyText: String) {
        populateSelectionMenu(menu,
                              sections: [MenuSection(header: nil, entries: entries)],
                              currentID: currentID,
                              action: action,
                              includeNone: includeNone,
                              emptyText: emptyText)
    }

    private func populateSelectionMenu(_ menu: NSMenu,
                                       sections: [MenuSection],
                                       currentID: String?,
                                       action: Selector,
                                       includeNone: Bool,
                                       emptyText: String) {
        menu.removeAllItems()

        let sections = sections.filter { !$0.entries.isEmpty }

        if includeNone {
            let noneItem = NSMenuItem(title: "None", action: action, keyEquivalent: "")
            noneItem.target = self
            noneItem.representedObject = nil
            noneItem.state = (currentID == nil) ? .on : .off
            menu.addItem(noneItem)
        }

        for section in sections {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            if let header = section.header { menu.addItem(.sectionHeader(title: header)) }

            for entry in section.entries {
                let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                item.state = (entry.id == currentID) ? .on : .off
                menu.addItem(item)
            }
        }

        if sections.isEmpty {
            _ = addDisabledItem(to: menu, title: emptyText)
        }
    }
}
