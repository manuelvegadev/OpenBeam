//
//  SettingsView.swift
//  OpenBeam
//
//  The settings window's contents.
//

import SwiftUI

enum SettingsPane: String, Hashable, CaseIterable {
    case general, updates, clipboard, remoteScreen, about

    var label: (title: String, symbol: String) {
        switch self {
        case .general:   ("General", "gearshape")
        case .updates:   ("Updates", "arrow.down.circle")
        case .clipboard: ("Clipboard", "doc.on.clipboard")
        case .remoteScreen: ("Remote Screen", "display")
        case .about:     ("About", "info.circle")
        }
    }
}

/// Built from stock SwiftUI controls on purpose.
///
/// An earlier version drew its own panels, rows and hover states so it could
/// apply Liquid Glass by hand. That was a mistake: on macOS 26 and later the
/// system already gives `Form`, `Section` and `TabView` the glass treatment,
/// and a hand-drawn approximation only manages to look *nearly* right — the
/// hover highlight, for one, was a plain rectangle sitting inside a rounded
/// panel. Nothing here styles a container; the platform decides how a grouped
/// form looks on whatever macOS is running it.
struct SettingsView: View {

    /// The one comfortable measure for a settings form; the window takes its
    /// width from here rather than declaring a second 480 of its own.
    static let width: CGFloat = 480

    let model: SettingsModel
    /// Which pane to show. The picker is the window's toolbar, not a control in
    /// here — see `SettingsWindowController`.
    let pane: SettingsPane
    /// How tall this pane wants to be, so the window can follow it. No default:
    /// a view built without it would leave the window stuck at its initial size.
    let onContentHeightChange: (CGFloat) -> Void

    var body: some View {
        Group {
            switch pane {
            case .general:   GeneralPane(model: model)
            case .updates:   UpdatesPane(model: model)
            case .clipboard: ClipboardPane(model: model)
            case .remoteScreen: RemoteScreenPane(model: model)
            case .about:     AboutPane(model: model)
            }
        }
        .frame(width: Self.width)
        // `.fixedSize` vertically is what makes the form report the height it
        // actually needs instead of filling whatever the window gives it, and
        // the measurement is taken here — before the frame below — so it is the
        // content's own height and not the window's.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            onContentHeightChange(height)
        }
        // Pinned to the top so the window's height animation plays out at the
        // bottom edge. Without this the form is centred in the hosting view and
        // drifts upward through the whole resize.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - General

private struct GeneralPane: View {

    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.openAtLogin },
                    set: { model.setOpenAtLogin($0) }
                )) {
                    Text("Open at login")
                    // A second Text in a Toggle's label is how a grouped form
                    // renders a description; it needs no styling from us.
                    Text(model.isInstalled
                         ? "Start OpenBeam when you log in."
                         : "Available once OpenBeam is in your Applications folder.")
                }
                .disabled(!model.isInstalled)

                if model.isInstalled && model.openAtLoginNeedsApproval {
                    LabeledContent("Login items") {
                        Button("Open Login Items…") { model.openLoginItemsSettings() }
                    }
                    Text("macOS is holding this off until you allow it.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.sendsUYVY },
                    set: { model.setSendsUYVY($0) }
                )) {
                    Text("Send as UYVY (4:2:2)")
                    Text("Halves the colour data on the wire. Lighter on the network, and the camera's own format decides whether you can see the difference.")
                }
            } header: {
                Text("Sending")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.keepAwakeDisplayOn },
                    set: { model.setKeepAwakeDisplayOn($0) }
                )) {
                    Text("Keep the display on")
                    Text("While Keep Awake is on, the screen stays lit too, not just the Mac.")
                }

                Toggle(isOn: Binding(
                    get: { model.keepAwakeLidClosed },
                    set: { model.setKeepAwakeLidClosed($0) }
                )) {
                    Text("Even with the lid closed")
                    Text("Without an external display, macOS sleeps on closing the lid whatever else says. Turning this on asks for your password once. On battery it lets go below \(KeepAwake.batteryFloor) %.")
                }

                if model.keepAwakeLidAuthorized {
                    LabeledContent("Lid-closed permission") {
                        Button("Remove…") { model.removeKeepAwakeLidAuthorization() }
                    }
                }
            } header: {
                Text("Keep Awake")
            } footer: {
                Text("Turn Keep Awake on from the menu bar. OpenBeam also keeps this Mac awake by itself while another Mac is controlling it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates

private struct UpdatesPane: View {

    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.checksAutomatically },
                    set: { model.setChecksAutomatically($0) }
                )) {
                    Text("Check for updates automatically")
                    Text("Once a day. A found update waits in the menu rather than interrupting you.")
                }

                Toggle(isOn: Binding(
                    get: { model.downloadsAutomatically },
                    set: { model.setDownloadsAutomatically($0) }
                )) {
                    Text("Download in the background")
                    Text("Fetch an update before you ask for it, so installing is immediate.")
                }
                .disabled(!model.checksAutomatically || !model.allowsAutomaticUpdates)
            } header: {
                Text("Checking")
            }

            Section {
                LabeledContent("Version", value: model.version)
                LabeledContent("Last checked", value: lastChecked)
                LabeledContent("Updates") {
                    Button("Check Now") { model.checkForUpdates() }
                        .disabled(!model.canCheckForUpdates)
                }

                if !model.isInstalled {
                    Text("OpenBeam cannot update itself from here. Move it to your Applications folder and open it from there.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("This copy")
            }
        }
        .formStyle(.grouped)
    }

    private var lastChecked: String {
        guard let date = model.lastUpdateCheck else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Clipboard

private struct ClipboardPane: View {

    let model: SettingsModel
    /// Forgetting a peer means pairing again from both ends, so it keeps the
    /// confirmation the menu used to ask for.
    @State private var peerToForget: PairedPeer?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.clipSyncEnabled },
                    set: { model.setClipSyncEnabled($0) }
                )) {
                    Text("Sync the clipboard")
                    Text("Copy on one machine, paste on another. Only devices you have paired.")
                }

                Toggle(isOn: Binding(
                    get: { model.clipSyncSyncsImages },
                    set: { model.setClipSyncSyncsImages($0) }
                )) {
                    Text("Sync copied images")
                    Text("A screenshot copied on one machine pastes as a picture on the other, without going through a file.")
                }
                .disabled(!model.clipSyncEnabled)

                Toggle(isOn: Binding(
                    get: { model.clipSyncSyncsFiles },
                    set: { model.setClipSyncSyncsFiles($0) }
                )) {
                    Text("Sync copied files")
                    Text("Copying files puts them on the other machine's clipboard too. Text only when this is off.")
                }
                .disabled(!model.clipSyncEnabled)
            }

            Section {
                Picker("Largest text:", selection: Binding(
                    get: { model.clipSyncMaxTextBytes },
                    set: { model.setClipSyncMaxTextBytes($0) }
                )) {
                    ForEach(ClipSyncPreferences.textByteChoices, id: \.self) { bytes in
                        Text(byteLimit(bytes)).tag(bytes)
                    }
                }

                Picker("Largest transfer:", selection: Binding(
                    get: { model.clipSyncMaxTransferBytes },
                    set: { model.setClipSyncMaxTransferBytes($0) }
                )) {
                    ForEach(ClipSyncPreferences.transferByteChoices, id: \.self) { bytes in
                        Text(byteLimit(bytes)).tag(bytes)
                    }
                }
                .disabled(!model.clipSyncSyncsFiles && !model.clipSyncSyncsImages)
            } header: {
                Text("Limits")
            } footer: {
                // A grouped form centres a footer by default, which reads as a
                // caption under the box rather than as prose about it.
                Text("Text over the limit stays on this machine rather than being sent. Images and file transfers over it are refused in either direction. The largest of each is as much as the protocol carries.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                if model.pairedPeers.isEmpty {
                    Text("No paired devices yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.pairedPeers, id: \.peerID) { peer in
                        LabeledContent {
                            Button("Forget") { peerToForget = peer }
                        } label: {
                            Text(peer.displayName)
                            Text(osName(peer.os))
                        }
                    }
                }
            } header: {
                Text("Paired")
            }

            Section {
                if model.discoveredPeers.isEmpty {
                    Text("No devices found on this network.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.discoveredPeers, id: \.peerID) { peer in
                        LabeledContent {
                            Button("Pair") { model.pair(peer) }
                        } label: {
                            Text(peer.displayName)
                            Text(osName(peer.os))
                        }
                    }
                }
            } header: {
                Text("Discovered")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            peerToForget.map { "Forget \"\($0.displayName)\"?" } ?? "",
            isPresented: Binding(get: { peerToForget != nil },
                                 set: { if !$0 { peerToForget = nil } }),
            presenting: peerToForget
        ) { peer in
            Button("Forget", role: .destructive) { model.forget(peer) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You'll need to pair again to resume clipboard sync.")
        }
    }

    /// Sizes here are round powers of two picked from a list, so they read
    /// better as "256 KB" than as the 262,144 bytes a byte formatter spells.
    private func byteLimit(_ bytes: Int) -> String {
        let mb = 1024 * 1024
        return bytes >= mb ? "\(bytes / mb) MB" : "\(bytes / 1024) KB"
    }

    private func osName(_ os: String) -> String {
        switch os {
        case ClipSync.osIdentifier: "macOS"
        case "windows": "Windows"
        case "linux": "Linux"
        default: os
        }
    }
}

// MARK: - Remote screen

private struct RemoteScreenPane: View {

    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                if model.pairedPeers.isEmpty {
                    Text("Pair a Mac in Clipboard first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.pairedPeers, id: \.peerID) { peer in
                        Toggle(isOn: Binding(
                            get: { model.remoteScreenAllowedPeers.contains(peer.peerID) },
                            set: { model.setRemoteScreenAllowed($0, for: peer) }
                        )) {
                            Text(peer.displayName)
                            Text("Can see this screen and use its keyboard and mouse.")
                        }
                    }
                }
            } header: {
                Text("Allow control of this Mac")
            } footer: {
                footnote("Off for every Mac until you turn it on here; pairing alone never allows it. While another Mac is in control, the OpenBeam icon in the menu bar turns orange.")
            }

            Section {
                permissionRow("Screen Recording", granted: model.remoteScreenHasScreenRecording,
                              action: model.requestScreenRecording)
                permissionRow("Accessibility", granted: model.remoteScreenHasAccessibility,
                              action: model.requestAccessibility)
            } header: {
                Text("Permissions")
            } footer: {
                footnote("A Mac being controlled needs both. A Mac viewing another needs Accessibility to send the shortcuts other apps have claimed.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.remoteScreenSendsShortcuts },
                    set: { model.setRemoteScreenSendsShortcuts($0) }
                )) {
                    Text("Send system shortcuts")
                    Text("⌘Tab, Spotlight, Raycast and every other global shortcut go to the other Mac while its window has the focus.")
                }

                Toggle(isOn: Binding(
                    get: { model.remoteScreenSendsMediaKeys },
                    set: { model.setRemoteScreenSendsMediaKeys($0) }
                )) {
                    Text("Send media keys")
                    Text("Volume, brightness and playback keys control the other Mac instead of this one.")
                }

                Toggle(isOn: Binding(
                    get: { model.remoteScreenRequestsRetina },
                    set: { model.setRemoteScreenRequestsRetina($0) }
                )) {
                    Text("Full Retina resolution")
                    Text("Every pixel of the other Mac's HiDPI desktop, drawn without rescaling. About three times the data; applies to the next screen you open.")
                }

                Toggle("Open in full screen", isOn: Binding(
                    get: { model.remoteScreenOpensFullScreen },
                    set: { model.setRemoteScreenOpensFullScreen($0) }
                ))

                Toggle(isOn: Binding(
                    get: { model.remoteScreenShowsStats },
                    set: { model.setRemoteScreenShowsStats($0) }
                )) {
                    Text("Show statistics")
                    Text("Frame rate and latency over the picture.")
                }
            } header: {
                Text("When viewing another Mac")
            } footer: {
                footnote("⌃⌥⌘R gives the keyboard back to this Mac, ⌃⌥⌘F toggles full screen and ⌃⌥⌘W closes the viewer.")
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: action)
            }
        }
    }

    /// Leading-aligned, as the Clipboard pane's footer explains.
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - About

private struct AboutPane: View {

    let model: SettingsModel

    private static let repo = AppDelegate.repoURL
    private static let profile = URL(string: "https://github.com/manuelvegadev")!
    private static let license = AppDelegate.repoURL.appendingPathComponent("blob/main/LICENSE")
    private static let ndi = URL(string: "https://ndi.video/")!
    private static let phosphor = URL(string: "https://phosphoricons.com/")!

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    // The icon the system gave this bundle, rather than a second
                    // copy from the asset catalogue that could drift from it.
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenBeam").font(.title2.weight(.semibold))
                        Text("Version \(model.version)").foregroundStyle(.secondary)
                        Text("A webcam on one Mac, a webcam on the other.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                LabeledContent("Source code") { Link("GitHub", destination: Self.repo) }
                LabeledContent("Made by") { Link("@manuelvegadev", destination: Self.profile) }
                LabeledContent("License") { Link("MIT", destination: Self.license) }
            } header: {
                Text("Project")
            }

            Section {
                LabeledContent("NDI® by Vizrt") { Link("ndi.video", destination: Self.ndi) }
                LabeledContent("Phosphor Icons") { Link("phosphoricons.com", destination: Self.phosphor) }
                Text("NDI® is a registered trademark of Vizrt NDI AB. OpenBeam is not affiliated with Vizrt.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Built with")
            }
        }
        .formStyle(.grouped)
    }
}
