import ApplicationServices
import Foundation

enum AccessibilityService {
    private static let excludedWindowSubroles: Set<String> = [
        kAXFloatingWindowSubrole as String,
        kAXSystemFloatingWindowSubrole as String
    ]

    private static func makeApplicationElement(
        pid: pid_t,
        timeout: Float = AppConstants.axMessagingTimeout
    ) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private static func copyBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyAttribute(element, attribute) as? Bool
    }

    private static func copyURLAttribute(_ element: AXUIElement, _ attribute: String) -> URL? {
        copyAttribute(element, attribute) as? URL
    }

    private static func copyElementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        copyAttribute(element, attribute) as? [AXUIElement]
    }

    private static func copyAXElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        // Safe CoreFoundation bridge after verifying AXUIElementGetTypeID().
        let pointer = Unmanaged.passUnretained(raw).toOpaque()
        return Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
    }

    static func fetchDockApplicationPaths(dockPID: pid_t) -> Set<String> {
        guard dockPID > 0 else { return [] }
        let root = makeApplicationElement(pid: dockPID)
        var paths = Set<String>()
        for list in copyElementArrayAttribute(root, kAXChildrenAttribute as String) ?? [] {
            AXUIElementSetMessagingTimeout(list, AppConstants.axMessagingTimeout)
            for item in copyElementArrayAttribute(list, kAXChildrenAttribute as String) ?? [] {
                AXUIElementSetMessagingTimeout(item, AppConstants.axMessagingTimeout)
                guard copyStringAttribute(item, kAXSubroleAttribute as String) == "AXApplicationDockItem",
                      let url = copyURLAttribute(item, kAXURLAttribute as String) else {
                    continue
                }
                paths.insert(url.standardizedFileURL.path)
            }
        }
        return paths
    }

    static func discoverWindows(
        for candidateApps: [RunningAppSnapshot],
        frontmostPID: pid_t?
    ) -> (discovered: [DiscoveredAppWindows], frontmostFocusedWindow: WindowToken?) {
        guard !candidateApps.isEmpty else {
            let focused = frontmostPID.flatMap(fetchFocusedWindow)
            return ([], focused)
        }

        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var slots: [DiscoveredAppWindows?]

            init(count: Int) {
                self.slots = [DiscoveredAppWindows?](repeating: nil, count: count)
            }

            func store(_ value: DiscoveredAppWindows, at index: Int) {
                lock.lock()
                slots[index] = value
                lock.unlock()
            }

            func compactValues() -> [DiscoveredAppWindows] {
                lock.lock()
                defer { lock.unlock() }
                return slots.compactMap { $0 }
            }
        }

        let box = ResultBox(count: candidateApps.count)
        DispatchQueue.concurrentPerform(iterations: candidateApps.count) { index in
            let app = candidateApps[index]
            let windows = discoverWindowsForSingleApp(app)
            if !windows.isEmpty {
                box.store(DiscoveredAppWindows(app: app, windows: windows), at: index)
            }
        }

        let focused = frontmostPID.flatMap(fetchFocusedWindow)
        return (box.compactValues(), focused)
    }

    private static func discoverWindowsForSingleApp(_ app: RunningAppSnapshot) -> [DiscoveredWindow] {
        let axApp = makeApplicationElement(pid: app.pid)
        guard var elements = copyElementArrayAttribute(axApp, kAXWindowsAttribute as String),
              !elements.isEmpty else {
            return []
        }

        if let preferred = copyAXElementAttribute(axApp, kAXFocusedWindowAttribute as String)
            ?? copyAXElementAttribute(axApp, kAXMainWindowAttribute as String),
           let index = elements.firstIndex(where: { CFEqual($0, preferred) }) {
            elements.insert(elements.remove(at: index), at: 0)
        }

        var windows = [DiscoveredWindow]()
        windows.reserveCapacity(elements.count)

        for element in elements {
            AXUIElementSetMessagingTimeout(element, AppConstants.axMessagingTimeout)
            guard copyStringAttribute(element, kAXRoleAttribute as String) == (kAXWindowRole as String) else {
                continue
            }
            if let subrole = copyStringAttribute(element, kAXSubroleAttribute as String) {
                if excludedWindowSubroles.contains(subrole) {
                    continue
                }
                if subrole == "AXUnknown",
                   (copyStringAttribute(element, kAXTitleAttribute as String) ?? "").isEmpty {
                    continue
                }
            }

            let rawTitle = copyStringAttribute(element, kAXTitleAttribute as String) ?? ""
            let resolvedTitle = rawTitle.isEmpty ? app.localizedName : rawTitle
            let isMinimized = copyBoolAttribute(element, kAXMinimizedAttribute as String) ?? false
            windows.append(
                DiscoveredWindow(
                    token: .ax(AXWindowRef(element: element)),
                    title: resolvedTitle,
                    isMinimized: isMinimized
                )
            )
        }

        return windows
    }

    private static func fetchFocusedWindow(pid: pid_t) -> WindowToken? {
        guard pid > 0 else { return nil }
        let axApp = makeApplicationElement(pid: pid)
        guard let focused = copyAXElementAttribute(axApp, kAXFocusedWindowAttribute as String) else {
            return nil
        }
        return .ax(AXWindowRef(element: focused))
    }

    static func unminimizeIfNeeded(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, AppConstants.axMessagingTimeout)
        if copyBoolAttribute(element, kAXMinimizedAttribute as String) == true {
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    static func raiseAndFocusSpecificWindow(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, AppConstants.axMessagingTimeout)
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func activateProcessWindowGroup(pid: pid_t) -> Bool {
        OptionTabActivateApplication(pid) == 0
    }
}
