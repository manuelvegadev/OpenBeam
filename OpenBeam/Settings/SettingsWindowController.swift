//
//  SettingsWindowController.swift
//  OpenBeam
//
//  The window that hosts the SwiftUI settings.
//

import AppKit
import SwiftUI

/// A window that closes on Escape.
///
/// `NSWindow` routes Escape to `cancelOperation(_:)` and, with no default button
/// and no sheet, nothing answers it. Every other macOS settings window closes on
/// Escape, so this one does too.
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// Opens and reuses the single settings window.
///
/// The pane picker is an `NSToolbar` in `.preference` style rather than a
/// SwiftUI `TabView`. A `TabView` is built for the `Settings` scene, where its
/// tab strip is merged into the window's toolbar; dropped into an ordinary
/// window it draws a second header band under the title bar, with the tabs
/// straddling the seam. The toolbar is what the Settings scene uses underneath,
/// and it puts the tabs *in* the title bar where they belong.
///
/// Using a toolbar also means the content is one `Form` rather than a container
/// that sizes to its tallest child, so the window can follow each pane's height.
@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate {

    /// Fixed: a settings form has one comfortable measure and resizing it with
    /// the pane would reflow every description. Owned by the view.
    private static let width = SettingsView.width
    private static let resizeDuration: TimeInterval = 0.3

    private let model: SettingsModel
    private var window: NSWindow?
    /// Whether the settings window is actually on screen. Callers use this to
    /// skip work that only matters while someone is looking at it.
    var isVisible: Bool { window?.isVisible ?? false }
    private var hosting: NSHostingView<SettingsView>?
    private var pane: SettingsPane = .general

    init(model: SettingsModel) {
        self.model = model
        super.init()
    }

    func show() {
        model.refresh()

        let window = window ?? makeWindow()
        self.window = window

        // The status menu is still tearing down its event tracking when this
        // runs; activating inside that leaves the window behind the menu.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // A window made in code releases itself when it closes, and the
        // reference here does not survive that: reopening Settings would retain
        // freed memory and crash. This controller owns the window and reuses it.
        window.isReleasedWhenClosed = false
        // Just "Settings": the toolbar underneath already names the pane, and
        // the version has its own row in About.
        window.title = "Settings"

        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = Self.identifier(for: pane)
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        let hosting = NSHostingView(rootView: makeRootView())
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 320)
        // Glued to the top with its own height, rather than resizing with the
        // window. A hosting view that grows alongside the window animates its
        // own top edge on a separate timeline from the window's, and the form
        // visibly slides during the transition. Pinned like this the content
        // does not move at all — the window simply reveals or covers space
        // below it.
        hosting.autoresizingMask = [.width, .minYMargin]
        // A plain container, not the content view: an NSHostingView as content
        // view sizes the window from its own fitting size, which fights the
        // explicit sizing below.
        let container = NSView(frame: hosting.frame)
        container.addSubview(hosting)
        window.contentView = container
        self.hosting = hosting

        window.center()
        return window
    }

    private func makeRootView() -> SettingsView {
        SettingsView(model: model, pane: pane) { [weak self] height in
            self?.fit(to: height)
        }
    }

    /// Resizes the window to the height the current pane asked for.
    private func fit(to contentHeight: CGFloat) {
        guard let window, let container = window.contentView, let hosting else { return }

        // Size the content to itself and glue it to the top of the container.
        // Explicitly outside any animation: this must snap, or it becomes the
        // very drift the pinning is meant to prevent.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            hosting.frame = NSRect(x: 0,
                                   y: container.bounds.height - contentHeight,
                                   width: Self.width,
                                   height: contentHeight)
        }

        // `contentHeight` is what SwiftUI laid out; the title bar and toolbar
        // sit outside it. Sizing the window to that number alone leaves it a
        // header too short, and the bottom padding is what disappears.
        let chrome = window.frame.height - window.contentLayoutRect.height
        let target = (contentHeight + chrome).rounded(.up)
        guard abs(window.frame.height - target) > 0.5 else { return }

        // Keep the title bar where it is. A resize anchors the bottom-left, so a
        // taller pane pushes the whole window upward and the toolbar appears to
        // jump.
        var frame = window.frame
        frame.origin.y = frame.maxY - target
        frame.size.height = target

        // The first pane is sized before `show()` orders the window front, so
        // an invisible window is the one case that must not animate — otherwise
        // it opens mid-grow.
        guard window.isVisible else {
            window.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            context.allowsImplicitAnimation = true
            window.setFrame(frame, display: true)
        }
    }

    // MARK: - Toolbar

    private static func identifier(for pane: SettingsPane) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(pane.rawValue)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(Self.identifier(for:))
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    /// What makes the items behave as a pane picker rather than as buttons.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.label.title
        item.paletteLabel = pane.label.title
        item.image = NSImage(systemSymbolName: pane.label.symbol,
                             accessibilityDescription: pane.label.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(pane)
    }

    /// Switches to `pane`, for a menu item that opens settings at a particular place.
    func select(_ pane: SettingsPane) {
        self.pane = pane
        // Handling the action ourselves means AppKit does not move the
        // selection for us, and the highlight would stay on the pane we left.
        window?.toolbar?.selectedItemIdentifier = Self.identifier(for: pane)
        hosting?.rootView = makeRootView()
    }
}
