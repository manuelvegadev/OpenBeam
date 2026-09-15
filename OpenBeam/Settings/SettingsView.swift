//
//  SettingsView.swift
//  OpenBeam
//
//  The settings window's contents.
//

import SwiftUI

enum SettingsPane: String, Hashable, CaseIterable {
    case general, updates, clipboard, about

    var label: (title: String, symbol: String) {
        switch self {
        case .general:   ("General", "gearshape")
        case .updates:   ("Updates", "arrow.down.circle")
        case .clipboard: ("Clipboard", "doc.on.clipboard")
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

    private func osName(_ os: String) -> String {
        switch os {
        case ClipSync.osIdentifier: "macOS"
        case "windows": "Windows"
        case "linux": "Linux"
        default: os
        }
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
