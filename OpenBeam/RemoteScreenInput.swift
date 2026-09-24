//
//  RemoteScreenInput.swift
//  OpenBeam
//
//  Turns the mouse and keyboard events a viewer window receives into EVENT
//  messages for the host. Pointer positions are mapped through the picture's
//  on-screen rectangle; keys travel as physical keycodes, never characters.
//

import AppKit

final class RemoteScreenInput {
    /// Chords the viewer keeps for itself instead of sending: ⌃⌥⌘F toggles
    /// fullscreen, ⌃⌥⌘W closes the viewer, ⌃⌥⌘R hands the keyboard back to this
    /// Mac, ⌃⌥⌘← / → switch the host display and ⌃⌥⌘↓ shows them all.
    /// Everything else goes to the host.
    private static let localChord: NSEvent.ModifierFlags = [.control, .option, .command]

    enum LocalCommand {
        case previousDisplay, nextDisplay, displayPicker
    }

    private weak var viewer: RemoteScreenViewer?
    private var cursorHidden = false
    /// The display chords, run by the window. Main queue.
    var onLocalCommand: ((LocalCommand) -> Void)?
    /// While set, key presses go to it (the display picker) instead of the host;
    /// it returns whether it used the key.
    var localKeys: ((UInt16) -> Bool)?
    /// While true, the pointer stays on this Mac (the picker is open over the picture).
    var pointerSuspended = false

    init(viewer: RemoteScreenViewer) {
        self.viewer = viewer
    }

    // MARK: - Pointer

    func mouse(_ event: NSEvent, in view: ScreenView) {
        guard !pointerSuspended else { return }
        let (x, y) = normalized(event, in: view)
        let kind: InputEventMessage.Kind
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: kind = .move
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .buttonDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .buttonUp
        default: return
        }
        let button = kind == .move ? 0 : UInt8(clamping: event.buttonNumber)
        let clicks = kind == .move ? 0 : UInt8(clamping: event.clickCount)
        viewer?.send(InputEventMessage(kind: kind, button: button, clicks: clicks, flags: flags(event), x: x, y: y))
    }

    func scroll(_ event: NSEvent) {
        guard !pointerSuspended else { return }
        viewer?.send(InputEventMessage(kind: .scroll,
                                       button: event.hasPreciseScrollingDeltas ? 1 : 0,
                                       scrollPhase: UInt8(clamping: event.phase.rawValue),
                                       momentumPhase: UInt8(clamping: event.momentumPhase.rawValue),
                                       flags: flags(event),
                                       x: event.scrollingDeltaX, y: event.scrollingDeltaY))
    }

    /// 0…1 from the top left of the remote screen, clamped to its edges.
    private func normalized(_ event: NSEvent, in view: ScreenView) -> (Double, Double) {
        let p = view.convert(event.locationInWindow, from: nil)
        let r = view.imageRect
        guard r.width > 0, r.height > 0 else { return (0.5, 0.5) }
        return (min(max((p.x - r.minX) / r.width, 0), 1), min(max(1 - (p.y - r.minY) / r.height, 0), 1))
    }

    func pointerEntered() {
        guard !cursorHidden else { return }
        NSCursor.hide()  // the host's own cursor is in the picture
        cursorHidden = true
    }

    func pointerExited() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    // MARK: - Keyboard

    /// From the view's own key events. These only arrive when the system-wide
    /// tap did not take the key first: the tap is off, or an app turned on secure
    /// input, which hides keys from every tap. Handled exactly as the tap's.
    func key(_ event: NSEvent, in window: NSWindow?) {
        guard let cgEvent = event.cgEvent, let type = CGEventType(rawValue: UInt32(event.type.rawValue)) else { return }
        key(cgEvent, type: type, in: window)
    }

    /// Every key goes to the host, including the ones other apps have claimed
    /// as global shortcuts, except the viewer's own chords, which run here, and
    /// keys the display picker is taking. Main thread.
    func key(_ event: CGEvent, type: CGEventType, in window: NSWindow?) {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if type == .keyDown,
           NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)).intersection([.control, .option, .command, .shift]) == Self.localChord,
           runLocalChord(keyCode: keyCode, in: window) {
            return
        }
        if type != .flagsChanged, let localKeys {
            if type == .keyDown { DispatchQueue.main.async { _ = localKeys(keyCode) } }
            return
        }
        let kind: InputEventMessage.Kind = type == .keyDown ? .keyDown : type == .keyUp ? .keyUp : .modifiersChanged
        viewer?.send(InputEventMessage(kind: kind, keyCode: keyCode, flags: flags.rawValue))
    }

    /// Runs the viewer's own chord for this key, if it is one. Keycodes, not
    /// characters, so the chords sit in the same place on every layout. The
    /// work runs after the event is handled: it may close the window and with
    /// it the tap this event is still inside.
    private func runLocalChord(keyCode: UInt16, in window: NSWindow?) -> Bool {
        let action: () -> Void
        switch keyCode {
        case 3: action = { window?.toggleFullScreen(nil) }  // kVK_ANSI_F
        case 13: action = { window?.close() }  // kVK_ANSI_W; a borderless full-screen window has no close button to "perform"
        case 15: action = { [weak self] in  // kVK_ANSI_R: let go, and give the keyboard back to this Mac
            self?.releaseAll()
            NSApp.deactivate()
        }
        case 123: action = { [weak self] in self?.onLocalCommand?(.previousDisplay) }  // kVK_LeftArrow
        case 124: action = { [weak self] in self?.onLocalCommand?(.nextDisplay) }  // kVK_RightArrow
        case 125: action = { [weak self] in self?.onLocalCommand?(.displayPicker) }  // kVK_DownArrow
        default: return false
        }
        DispatchQueue.main.async(execute: action)
        return true
    }

    /// A media key, as NX_KEYTYPE_* and its state.
    func mediaKey(type: UInt16, down: Bool, isRepeat: Bool) {
        viewer?.send(InputEventMessage(kind: .mediaKey, button: down ? 1 : 0, clicks: isRepeat ? 1 : 0, keyCode: type))
    }

    /// NSEvent's modifier bits sit where CGEventFlags keeps them, Fn included.
    private func flags(_ event: NSEvent) -> UInt64 {
        UInt64(event.modifierFlags.rawValue)
    }

    /// Lets go of everything on the host, for when this window stops receiving input.
    func releaseAll() {
        pointerExited()
        viewer?.releaseAll()
    }
}

/// A keyboard tap at the HID level, ahead of every app's global shortcuts
/// (Raycast, Rectangle, ⌘Tab, Spotlight). While `isFocused` says the viewer has
/// the focus, it takes each key for the host and keeps it from this Mac, and
/// media keys too if the user chose so; otherwise it lets everything through
/// untouched. Needs the Accessibility permission.
final class SystemKeyboardCapture {
    private let input: RemoteScreenInput
    private let isFocused: () -> Bool
    private weak var window: NSWindow?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(input: RemoteScreenInput, window: NSWindow, isFocused: @escaping () -> Bool) {
        self.input = input
        self.window = window
        self.isFocused = isFocused
    }

    /// Installs the tap on the main run loop; false if the system refused it,
    /// which is what happens without the Accessibility permission.
    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << Self.systemDefined)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: { _, type, event, refcon in
                                              let capture = Unmanaged<SystemKeyboardCapture>.fromOpaque(refcon!).takeUnretainedValue()
                                              return capture.handle(type, event)
                                          },
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    deinit { stop() }

    /// NX_SYSDEFINED, which CGEventType has no case for.
    private static let systemDefined: UInt32 = 14

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type.rawValue == Self.systemDefined {
            // Media keys: subtype 8, key type in the high half of data1, state in the next byte.
            guard isFocused(), RemoteScreenPreferences.sendsMediaKeys,
                  let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8
            else { return Unmanaged.passUnretained(event) }
            let data1 = ns.data1
            let state = (data1 & 0xFF00) >> 8
            guard state == 0xA || state == 0xB else { return Unmanaged.passUnretained(event) }
            input.mediaKey(type: UInt16(truncatingIfNeeded: (data1 & 0xFFFF_0000) >> 16), down: state == 0xA, isRepeat: data1 & 0x1 == 1)
            return nil
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switches a slow tap off; switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            guard isFocused() else { return Unmanaged.passUnretained(event) }
            input.key(event, type: type, in: window)
            return nil  // the host's now, not this Mac's
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
