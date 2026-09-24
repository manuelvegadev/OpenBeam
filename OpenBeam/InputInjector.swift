//
//  InputInjector.swift
//  OpenBeam
//
//  Posts a remote screen viewer's input as this Mac's own, with CGEvent. Keeps
//  track of every key, modifier and button it pressed, so that it can let go of
//  all of them when the viewer leaves: a key stuck down on an unattended Mac is
//  the one failure this must never have.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

private let injectorLog = Logger(subsystem: "com.openbeam.remotescreen", category: "injector")

final class InputInjector: RemoteInputSink, @unchecked Sendable {
    /// Whether this app may post input events, optionally asking the user.
    static func hasPermission(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
    }

    private var displayID: CGDirectDisplayID
    private let lock = NSLock()
    private var keysDown = Set<UInt16>()
    private var modifiersDown = Set<UInt16>()
    private var buttonsDown = Set<UInt8>()
    private var scrollRemainder = (x: 0.0, y: 0.0)

    /// Modifier keycodes (kVK_*) and the CGEventFlags bit each one sets. Caps Lock
    /// is left out on purpose: it toggles, so "releasing" it would flip it.
    private static let modifierFlags: [UInt16: CGEventFlags] = [
        55: .maskCommand, 54: .maskCommand,
        56: .maskShift, 60: .maskShift,
        58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl,
        63: .maskSecondaryFn,
    ]

    init(display: CGDirectDisplayID) {
        displayID = display
    }

    func use(display: CGDirectDisplayID) {
        lock.lock()
        displayID = display
        lock.unlock()
    }

    func inject(_ e: InputEventMessage) {
        lock.lock()
        defer { lock.unlock() }
        switch e.kind {
        case .move:
            let point = location(e)
            if let button = buttonsDown.min() {
                post(mouse: Self.types(for: button).drag, at: point, button: button, clicks: 0)
            } else {
                post(mouse: .mouseMoved, at: point, button: 0, clicks: 0)
            }
        case .buttonDown:
            buttonsDown.insert(e.button)
            post(mouse: Self.types(for: e.button).down, at: location(e), button: e.button, clicks: e.clicks)
        case .buttonUp:
            buttonsDown.remove(e.button)
            post(mouse: Self.types(for: e.button).up, at: location(e), button: e.button, clicks: e.clicks)
        case .scroll:
            scroll(e)
        case .keyDown, .keyUp:
            let down = e.kind == .keyDown
            if down { keysDown.insert(e.keyCode) } else { keysDown.remove(e.keyCode) }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: e.keyCode, keyDown: down)
            event?.flags = CGEventFlags(rawValue: e.flags)
            event?.post(tap: .cghidEventTap)
        case .modifiersChanged:
            if let bit = Self.modifierFlags[e.keyCode] {
                if CGEventFlags(rawValue: e.flags).contains(bit) {
                    modifiersDown.insert(e.keyCode)
                } else {
                    modifiersDown.remove(e.keyCode)
                }
            }
            postFlagsChanged(keyCode: e.keyCode, flags: CGEventFlags(rawValue: e.flags))
        case .mediaKey:
            postMediaKey(type: e.keyCode, down: e.button == 1, isRepeat: e.clicks == 1)
        }
    }

    func releaseAll() {
        lock.lock()
        defer { lock.unlock() }
        guard !keysDown.isEmpty || !modifiersDown.isEmpty || !buttonsDown.isEmpty else { return }
        injectorLog.info("releasing \(self.keysDown.count, privacy: .public) keys, \(self.modifiersDown.count, privacy: .public) modifiers, \(self.buttonsDown.count, privacy: .public) buttons")
        for key in keysDown {
            CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        }
        keysDown.removeAll()
        let here = CGEvent(source: nil)?.location ?? .zero
        for button in buttonsDown {
            post(mouse: Self.types(for: button).up, at: here, button: button, clicks: 1)
        }
        buttonsDown.removeAll()
        var remaining = modifiersDown.reduce(CGEventFlags()) { $0.union(Self.modifierFlags[$1] ?? []) }
        for key in modifiersDown {
            remaining.subtract(Self.modifierFlags[key] ?? [])
            postFlagsChanged(keyCode: key, flags: remaining)
        }
        modifiersDown.removeAll()
    }

    // MARK: - Posting

    /// A normalized position on the captured display, in global points.
    private func location(_ e: InputEventMessage) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        let x = min(max(e.x, 0), 1), y = min(max(e.y, 0), 1)
        return CGPoint(x: b.minX + min(x * b.width, b.width - 1), y: b.minY + min(y * b.height, b.height - 1))
    }

    private static func types(for button: UInt8) -> (down: CGEventType, up: CGEventType, drag: CGEventType) {
        switch button {
        case 0: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case 1: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        default: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }

    private func post(mouse type: CGEventType, at point: CGPoint, button: UInt8, clicks: UInt8) {
        let cgButton = CGMouseButton(rawValue: UInt32(button)) ?? .center
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        if button >= 2 { event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
        if clicks > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)) }
        event.post(tap: .cghidEventTap)
    }

    private func postFlagsChanged(keyCode: UInt16, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Media keys are system-defined events (subtype 8, NX_SUBTYPE_AUX_CONTROL_BUTTONS),
    /// with the key type and its state packed into data1.
    private func postMediaKey(type: UInt16, down: Bool, isRepeat: Bool) {
        let state = down ? 0xA : 0xB
        let data1 = Int(type) << 16 | state << 8 | (isRepeat ? 1 : 0)
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
            .cgEvent?.post(tap: .cghidEventTap)
    }

    // The wire carries NSEvent.Phase values; CGEvent numbers the same phases differently.

    private static func scrollPhase(_ ns: UInt8) -> Int64 {
        switch ns {
        case 1: return 1  // began
        case 2, 4: return 2  // stationary, changed
        case 8: return 4  // ended
        case 16: return 8  // cancelled
        case 32: return 128  // may begin
        default: return 0
        }
    }

    private static func momentumPhase(_ ns: UInt8) -> Int64 {
        switch ns {
        case 1: return 1  // began
        case 2, 4: return 2  // continuing
        case 8, 16: return 3  // ended
        default: return 0
        }
    }

    /// Trackpad deltas arrive in points, often fractional; whole points are
    /// posted and the rest carried over, so slow scrolls still move.
    private func scroll(_ e: InputEventMessage) {
        let precise = e.button == 1
        var dx = e.x, dy = e.y
        if precise {
            dx += scrollRemainder.x
            dy += scrollRemainder.y
            scrollRemainder = (dx - dx.rounded(.towardZero), dy - dy.rounded(.towardZero))
        }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2,
                                  wheel1: Int32(dy.rounded(.towardZero)), wheel2: Int32(dx.rounded(.towardZero)), wheel3: 0)
        else { return }
        if precise {
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Self.scrollPhase(e.scrollPhase))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Self.momentumPhase(e.momentumPhase))
        }
        event.flags = CGEventFlags(rawValue: e.flags)
        event.post(tap: .cghidEventTap)
    }
}
