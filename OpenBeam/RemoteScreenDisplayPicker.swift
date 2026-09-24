//
//  RemoteScreenDisplayPicker.swift
//  OpenBeam
//
//  The host's displays drawn the way System Settings → Displays arranges them:
//  each monitor at its place and proportion, the main one with its menu bar,
//  the shared one outlined in the accent color. Shown over the viewer to pick
//  which display to see, and briefly after switching with ⌃⌥⌘← / →.
//

import AppKit

final class RemoteScreenDisplayPicker: NSView {
    /// A display clicked, or chosen with Return.
    var onChoose: ((UInt32) -> Void)?
    /// A click outside the panel.
    var onDismiss: (() -> Void)?

    private(set) var displays: [ScreenDisplayInfo] = []
    /// The display being shown.
    var current: UInt32 = 0 { didSet { needsDisplay = true } }
    /// The one the keyboard is on; the current one until an arrow moves it.
    private(set) var highlighted: UInt32 = 0
    /// Interactive: takes clicks and keys. Otherwise a passing notice that lets
    /// every click through to the picture beneath.
    var isInteractive = false

    private static let panelPadding: CGFloat = 28
    private static let arrangementSize = CGSize(width: 520, height: 240)

    override var isFlipped: Bool { true }  // display coordinates run top down, as here

    func update(displays: [ScreenDisplayInfo], current: UInt32) {
        self.displays = displays
        self.current = current
        if !displays.contains(where: { $0.id == highlighted }) { highlighted = current }
        needsDisplay = true
    }

    func resetHighlight() {
        highlighted = current
        needsDisplay = true
    }

    /// Moves the keyboard highlight left or right through the arrangement.
    func moveHighlight(by step: Int) {
        guard let next = neighbor(of: highlighted, step: step) else { return }
        highlighted = next
        needsDisplay = true
    }

    /// The display `step` places along from `id`, left to right then top to
    /// bottom as they sit, wrapping around the ends.
    func neighbor(of id: UInt32, step: Int) -> UInt32? {
        let order = displays.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard !order.isEmpty else { return nil }
        let index = order.firstIndex { $0.id == id } ?? 0
        return order[(index + step + order.count) % order.count].id
    }

    // MARK: - Layout

    /// The arrangement's own extent, in host points.
    private var union: CGRect {
        displays.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.pointWidth, height: $1.pointHeight)) }
    }

    /// The arrangement scaled to fit the largest area the panel allows.
    private var arrangementSize: CGSize {
        let u = union
        guard !u.isNull, u.width > 0, u.height > 0 else { return Self.arrangementSize }
        let scale = min(Self.arrangementSize.width / u.width, Self.arrangementSize.height / u.height)
        return CGSize(width: u.width * scale, height: u.height * scale)
    }

    /// Snug around the arrangement, with room below it for the hint.
    private var panelRect: CGRect {
        let inner = arrangementSize
        let size = CGSize(width: max(inner.width, 360) + Self.panelPadding * 2,
                          height: inner.height + Self.panelPadding * 2 + 30)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Each display's rectangle in this view.
    private func layout() -> [(ScreenDisplayInfo, CGRect)] {
        guard !displays.isEmpty else { return [] }
        let u = union
        let inner = arrangementSize
        let scale = inner.width / u.width
        let origin = CGPoint(x: panelRect.midX - inner.width / 2, y: panelRect.minY + Self.panelPadding)
        return displays.map { d in
            let r = CGRect(x: origin.x + (d.x - u.minX) * scale, y: origin.y + (d.y - u.minY) * scale,
                           width: d.pointWidth * scale, height: d.pointHeight * scale)
            return (d, r.insetBy(dx: 3, dy: 3))  // the gap System Settings leaves between displays
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: panelRect, xRadius: 18, yRadius: 18)
        NSColor(white: 0.12, alpha: 0.92).setFill()
        panel.fill()
        NSColor(white: 1, alpha: 0.08).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        for (display, rect) in layout() {
            let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            // A dusk-blue desktop, standing in for the wallpaper Settings shows.
            NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.62, alpha: 1),
                       ending: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.30, alpha: 1))?.draw(in: shape, angle: -90)
            if display.main {
                // The menu bar, which is how Settings marks the main display.
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSColor(white: 1, alpha: 0.85).setFill()
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(3, rect.height * 0.045)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if display.id == current || display.id == highlighted {
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 8, yRadius: 8)
                ring.lineWidth = display.id == highlighted ? 3 : 2
                (display.id == highlighted ? NSColor.controlAccentColor : NSColor(white: 1, alpha: 0.55)).setStroke()
                ring.stroke()
            }
            drawLabel(display, in: rect)
        }

        let hint = isInteractive
            ? "← → to choose    Return to show    Esc to close"
            : "⌃⌥⌘← →  switch displays    ⌃⌥⌘↓  show all"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.6),
        ]
        let size = hint.size(withAttributes: attributes)
        hint.draw(at: CGPoint(x: panelRect.midX - size.width / 2, y: panelRect.maxY - Self.panelPadding + 6 - size.height / 2),
                  withAttributes: attributes)
    }

    private func drawLabel(_ display: ScreenDisplayInfo, in rect: CGRect) {
        let name = NSAttributedString(string: display.name, attributes: [
            .font: NSFont.systemFont(ofSize: min(13, max(9, rect.height / 7)), weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let detail = NSAttributedString(string: "\(Int(display.pointWidth)) × \(Int(display.pointHeight))", attributes: [
            .font: NSFont.systemFont(ofSize: min(11, max(8, rect.height / 9))),
            .foregroundColor: NSColor(white: 1, alpha: 0.7),
        ])
        let height = name.size().height + detail.size().height
        guard rect.height > height + 4, rect.width > 30 else { return }
        var y = rect.midY - height / 2
        for line in [name, detail] {
            let width = min(line.size().width, rect.width - 8)
            line.draw(in: CGRect(x: rect.midX - width / 2, y: y, width: width, height: line.size().height))
            y += line.size().height
        }
    }

    // MARK: - Input

    /// Passes clicks through unless interactive.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (display, _) = layout().first(where: { $0.1.contains(p) }) {
            onChoose?(display.id)
        } else if !panelRect.contains(p) {
            onDismiss?()
        }
    }

    // Swallowed while open, so nothing reaches the picture underneath.
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
