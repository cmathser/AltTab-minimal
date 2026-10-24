import AppKit
import ApplicationServices

private struct Window {
    let app: NSRunningApplication
    let element: AXUIElement
    let title: String
}

private final class Switcher: NSObject, NSApplicationDelegate {
    private var tap: CFMachPort?
    private var panel: NSPanel?
    private var windows = [Window]()
    private var selected = 0
    private var pendingSteps = 0
    private var optionHeld = false
    private var loading = false
    private var generation = 0
    private var previous: Window?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AXIsProcessTrusted() else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            NSApp.terminate(nil)
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: Self.callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            NSApp.terminate(nil)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, pointer in
        guard let pointer else { return Unmanaged.passUnretained(event) }
        let switcher = Unmanaged<Switcher>.fromOpaque(pointer).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = switcher.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return switcher.handle(type, event) ? nil : Unmanaged.passUnretained(event)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let option = event.flags.contains(.maskAlternate)
        if type == .flagsChanged, optionHeld, !option {
            optionHeld = false
            if !loading { finish() }
            return false
        }
        guard type == .keyDown || type == .keyUp else { return false }
        if code == 48, option || optionHeld {
            if type == .keyDown { advance(event.flags.contains(.maskShift) ? -1 : 1) }
            return true
        }
        if code == 53, optionHeld {
            if type == .keyDown { cancel() }
            return true
        }
        return false
    }

    private func advance(_ step: Int) {
        if !optionHeld {
            optionHeld = true
            loading = true
            pendingSteps = step
            generation += 1
            let token = generation
            let last = previous
            DispatchQueue.global(qos: .userInitiated).async {
                let found = Self.enumerateWindows(previous: last)
                DispatchQueue.main.async { self.loaded(found, token: token) }
            }
            return
        }
        if loading { pendingSteps += step; return }
        guard !windows.isEmpty else { return }
        selected = Self.wrap(selected + step, windows.count)
        draw()
    }

    private func loaded(_ found: [Window], token: Int) {
        guard token == generation else { return }
        windows = found
        loading = false
        guard !found.isEmpty else { cancel(); return }
        selected = Self.wrap(pendingSteps, found.count)
        if optionHeld { draw() } else { finish() }
    }

    private static func wrap(_ value: Int, _ count: Int) -> Int { ((value % count) + count) % count }

    private static func enumerateWindows(previous: Window?) -> [Window] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var found = [Window]()
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let elements = value as? [AXUIElement] else { continue }
            for element in elements {
                var role: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                      role as? String == kAXWindowRole as String else { continue }
                var title: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
                found.append(Window(app: app, element: element, title: (title as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? "Window"))
            }
        }
        let front = NSWorkspace.shared.frontmostApplication
        let focused = front.flatMap { app -> AXUIElement? in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        if let front, let focused, let index = found.firstIndex(where: { $0.app.processIdentifier == front.processIdentifier && CFEqual($0.element, focused) }) {
            found.insert(found.remove(at: index), at: 0)
        }
        if let previous, let index = found.firstIndex(where: { $0.app.processIdentifier == previous.app.processIdentifier && CFEqual($0.element, previous.element) }), index > 1 {
            found.insert(found.remove(at: index), at: 1)
        }
        return found
    }

    private func draw() {
        panel?.orderOut(nil)
        let visibleCount = min(windows.count, 12)
        let height = CGFloat(visibleCount * 44 + 16)
        let width: CGFloat = 520
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let rect = NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        let panel = panel ?? NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(rect, display: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = windows.count > visibleCount
        scroll.drawsBackground = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(windows.count * 44 + 16)))
        document.wantsLayer = true
        document.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        document.layer?.cornerRadius = 12
        for (index, window) in windows.enumerated() {
            let row = NSView(frame: NSRect(x: 8, y: document.frame.height - CGFloat((index + 1) * 44) - 8, width: width - 16, height: 42))
            row.wantsLayer = true
            row.layer?.backgroundColor = (index == selected ? NSColor.controlAccentColor.withAlphaComponent(0.8) : .clear).cgColor
            row.layer?.cornerRadius = 7
            let icon = NSImageView(frame: NSRect(x: 9, y: 5, width: 32, height: 32))
            icon.image = window.app.icon
            row.addSubview(icon)
            let label = NSTextField(labelWithString: "\(window.app.localizedName ?? "App") — \(window.title)")
            label.frame = NSRect(x: 50, y: 10, width: width - 75, height: 24)
            label.lineBreakMode = .byTruncatingTail
            label.textColor = index == selected ? .white : .labelColor
            row.addSubview(label)
            document.addSubview(row)
        }
        scroll.documentView = document
        panel.contentView = scroll
        panel.orderFrontRegardless()
        self.panel = panel
        if let row = document.subviews[safe: selected] { scroll.contentView.scrollToVisible(row.frame) }
    }

    private func cancel() {
        generation += 1
        optionHeld = false
        loading = false
        windows.removeAll()
        panel?.orderOut(nil)
    }

    private func finish() {
        panel?.orderOut(nil)
        guard windows.indices.contains(selected) else { cancel(); return }
        let window = windows[selected]
        previous = window
        windows.removeAll()
        DispatchQueue.global(qos: .userInitiated).async {
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(window.element, kAXMinimizedAttribute as CFString, &minimized) == .success, minimized as? Bool == true {
                AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            _ = window.app.activate(options: [])
            AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

let application = NSApplication.shared
private let delegate = Switcher()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
