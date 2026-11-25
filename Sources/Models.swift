import AppKit
import ApplicationServices

enum AppConstants {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "local.optiontab.minimal"
    static let dockBundleIdentifier = "com.apple.dock"
    static let axMessagingTimeout: Float = 0.15
}

enum KeyCode {
    static let tab: Int64 = 48
    static let escape: Int64 = 53
}

struct ShortcutModifiers: OptionSet, Sendable, Equatable {
    let rawValue: UInt8

    static let option  = ShortcutModifiers(rawValue: 1 << 0)
    static let shift   = ShortcutModifiers(rawValue: 1 << 1)
    static let command = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(cgFlags: CGEventFlags) {
        var bits: ShortcutModifiers = []
        if cgFlags.contains(.maskAlternate) { bits.insert(.option) }
        if cgFlags.contains(.maskShift) { bits.insert(.shift) }
        if cgFlags.contains(.maskCommand) { bits.insert(.command) }
        if cgFlags.contains(.maskControl) { bits.insert(.control) }
        self = bits
    }
}

enum LayoutMetrics {
    static let maxVisibleRows = 12
    static let rowStride: CGFloat = 44
    static let rowHeight: CGFloat = 42
    static let verticalPadding: CGFloat = 16
    static let horizontalInset: CGFloat = 8
    static let panelWidth: CGFloat = 520
    static let panelCornerRadius: CGFloat = 12
    static let rowCornerRadius: CGFloat = 7
    static let iconFrame = NSRect(x: 9, y: 5, width: 32, height: 32)
    static let labelFrame = NSRect(x: 50, y: 10, width: 520 - 75, height: 24)
    static let panelBackgroundAlpha: CGFloat = 0.97
    static let selectionHighlightAlpha: CGFloat = 0.8
    static let fallbackScreenFrame = NSRect(x: 0, y: 0, width: 1280, height: 800)
}

struct AXWindowRef: @unchecked Sendable, Equatable {
    let element: AXUIElement

    static func == (lhs: AXWindowRef, rhs: AXWindowRef) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

enum WindowToken: Sendable, Equatable {
    case ax(AXWindowRef)
    case synthetic(Int)

    var axElement: AXUIElement? {
        if case let .ax(ref) = self { return ref.element }
        return nil
    }
}

struct RunningAppSnapshot: Sendable, Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let bundlePath: String?
    let localizedName: String
    let isRegular: Bool
    let isProhibited: Bool
    let isActive: Bool

    /// Scheme B grouping key:
    /// - `.regular` processes each own an independent Dock / Command-Tab icon (`open -n` instances stay separate by PID).
    /// - Non-regular Dock sub-apps (such as `WeChatAppEx`) merge helper processes sharing the same `.app` bundle path.
    var groupKey: String {
        if isRegular {
            return "pid:\(pid)"
        }
        if let bundlePath {
            return "bundle:\(bundlePath)"
        }
        return "pid:\(pid)"
    }

    var bundleGroupKey: String? {
        bundlePath.map { "bundle:\($0)" }
    }

    var iconCacheKey: String {
        bundlePath ?? "pid:\(pid)"
    }

    @MainActor
    init(runningApplication app: NSRunningApplication) {
        self.pid = app.processIdentifier
        self.bundleIdentifier = app.bundleIdentifier
        self.bundlePath = app.bundleURL?.standardizedFileURL.path
        self.localizedName = app.localizedName ?? "App"
        let policy = app.activationPolicy
        self.isRegular = (policy == .regular)
        self.isProhibited = (policy == .prohibited)
        self.isActive = app.isActive
    }

    init(
        pid: pid_t,
        bundleIdentifier: String? = nil,
        bundlePath: String? = nil,
        localizedName: String,
        isRegular: Bool = true,
        isProhibited: Bool = false,
        isActive: Bool = false
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.localizedName = localizedName
        self.isRegular = isRegular
        self.isProhibited = isProhibited
        self.isActive = isActive
    }
}

struct DiscoveredWindow: Sendable, Equatable {
    let token: WindowToken
    let title: String
    let isMinimized: Bool
}

struct DiscoveredAppWindows: Sendable {
    let app: RunningAppSnapshot
    let windows: [DiscoveredWindow]
}

struct SwitcherItem: Sendable, Equatable {
    let app: RunningAppSnapshot
    let windowToken: WindowToken?
    let title: String
    let isMinimized: Bool
    var isApplicationEntry: Bool = false
    var hasPeerWithSameDisplayName: Bool = false
    var fallbackRestoreToken: WindowToken? = nil

    var displayTitle: String {
        if isApplicationEntry {
            if hasPeerWithSameDisplayName, windowToken != nil, !title.isEmpty, title != app.localizedName {
                return "\(app.localizedName) — \(title)"
            }
            return app.localizedName
        }
        return "\(app.localizedName) — \(title)"
    }

    func matches(_ other: SwitcherItem) -> Bool {
        guard app.groupKey == other.app.groupKey else { return false }
        return windowToken == other.windowToken
    }
}
