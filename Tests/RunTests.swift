import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard actual == expected else {
        let detail = message.isEmpty ? "" : " (\(message))"
        throw TestFailure(description: "\(file):\(line) expected \(expected), got \(actual)\(detail)")
    }
}

private func expectTrue(
    _ condition: Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition else {
        throw TestFailure(description: "\(file):\(line) assertion failed\(message.isEmpty ? "" : ": \(message)")")
    }
}

// MARK: - ShortcutStateMachine Tests

private func testBasicOptionTabCycleAndWrapAround() throws {
    var sm = ShortcutStateMachine()

    // Hold Option + press Tab -> starts loading token 1
    let r1 = sm.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.tab, modifiers: [.option])
    try expectTrue(r1.intercept, "Option+Tab keyDown should be intercepted")
    try expectEqual(r1.action, .startLoading(token: 1))
    try expectTrue(sm.isSessionActive)

    // Release Tab while still holding Option -> swallowed
    let r1Up = sm.handleKeyEvent(isKeyDown: false, keyCode: KeyCode.tab, modifiers: [.option])
    try expectTrue(r1Up.intercept, "Paired Tab keyUp must be swallowed")
    try expectEqual(r1Up.action, .none)

    // Background enumeration finishes with 3 items -> selects index 1 (previous app)
    let loadAction = sm.didFinishLoading(itemCount: 3, token: 1)
    try expectEqual(loadAction, .presentPanel(selectedIndex: 1))

    // Press Tab again -> index 2
    let r2 = sm.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.tab, modifiers: [.option])
    try expectEqual(r2.action, .updateSelection(index: 2))

    // Press Tab again -> wraps to index 0
    let r3 = sm.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.tab, modifiers: [.option])
    try expectEqual(r3.action, .updateSelection(index: 0))

    // Press Shift+Tab -> wraps backward to index 2
    let r4 = sm.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.tab, modifiers: [.option, .shift])
    try expectEqual(r4.action, .updateSelection(index: 2))

    // Release Option -> commits index 2 and resets to idle
    let commit = sm.handleFlagsChanged(modifiers: [])
    try expectEqual(commit, .commitSelection(index: 2))
    try expectTrue(!sm.isSessionActive)
}

private func testModifierIsolationLetsCmdAndCtrlShortcutsPassThrough() throws {
    var sm = ShortcutStateMachine()

    // Cmd+Option+Tab must NOT be intercepted when idle
    let cmdOptTab = sm.handleKeyEvent(
        isKeyDown: true,
        keyCode: KeyCode.tab,
        modifiers: [.option, .command]
    )
    try expectTrue(!cmdOptTab.intercept, "Cmd+Option+Tab should pass through")
    try expectEqual(cmdOptTab.action, .none)

    // Ctrl+Option+Tab must NOT be intercepted when idle
    let ctrlOptTab = sm.handleKeyEvent(
        isKeyDown: true,
        keyCode: KeyCode.tab,
        modifiers: [.option, .control]
    )
    try expectTrue(!ctrlOptTab.intercept, "Ctrl+Option+Tab should pass through")
    try expectEqual(ctrlOptTab.action, .none)

    // Plain Tab must NOT be intercepted
    let plainTab = sm.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.tab, modifiers: [])
    try expectTrue(!plainTab.intercept)
    try expectEqual(plainTab.action, .none)
}

private func testEscapeCancelsAndSwallowsPairedKeyUpWithoutLeak() throws {
    var sm = ShortcutStateMachine()

    _ = sm.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.tab, modifiers: [.option])
    _ = sm.didFinishLoading(itemCount: 4, token: 1)

    // Press Escape while Option is still held
    let escDown = sm.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.escape, modifiers: [.option])
    try expectTrue(escDown.intercept, "Escape keyDown must be intercepted")
    try expectEqual(escDown.action, .cancel)
    try expectTrue(!sm.isSessionActive, "Session should immediately return to idle")

    // Release Escape AFTER session already returned to idle -> must STILL be swallowed!
    let escUp = sm.handleKeyEvent(isKeyDown: false, keyCode: KeyCode.escape, modifiers: [.option])
    try expectTrue(escUp.intercept, "Escape keyUp must not leak to frontmost app")
    try expectEqual(escUp.action, .none)

    // Subsequent unrelated Escape when idle must pass through normally
    let nextEscDown = sm.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.escape, modifiers: [])
    try expectTrue(!nextEscDown.intercept)
    let nextEscUp = sm.handleKeyEvent(isKeyDown: false, keyCode: KeyCode.escape, modifiers: [])
    try expectTrue(!nextEscUp.intercept)
}

private func testQuickOptionReleaseDuringLoadingAndMidLoadEscapeCancel() throws {
    // Subcase A: Quick tap Option+Tab and release Option before load completes -> commits immediately on load
    var smQuick = ShortcutStateMachine()
    _ = smQuick.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.tab, modifiers: [.option])
    _ = smQuick.handleKeyEvent(isKeyDown: false, keyCode: KeyCode.tab, modifiers: [.option])
    let releaseAction = smQuick.handleFlagsChanged(modifiers: [])
    try expectEqual(releaseAction, .none)

    let quickFinish = smQuick.didFinishLoading(itemCount: 3, token: 1)
    try expectEqual(quickFinish, .commitSelection(index: 1))
    try expectTrue(!smQuick.isSessionActive)

    // Subcase B: Release Option during load, then press Escape BEFORE load finishes -> cancels pending switch!
    var smAbort = ShortcutStateMachine()
    _ = smAbort.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.tab, modifiers: [.option])
    _ = smAbort.handleFlagsChanged(modifiers: [])
    let escDuringLoad = smAbort.handleKeyEvent(isKeyDown: true, keyCode: KeyCode.escape, modifiers: [])
    try expectTrue(escDuringLoad.intercept)
    try expectEqual(escDuringLoad.action, .cancel)

    // Stale token completion is ignored
    let staleLoad = smAbort.didFinishLoading(itemCount: 3, token: 1)
    try expectEqual(staleLoad, .none)
}

// MARK: - SwitcherOrdering & Scheme B Tests

private func testSchemeBMultiInstanceRegularAppsStaySeparateAndDisambiguateTitles() throws {
    let chrome1 = RunningAppSnapshot(
        pid: 1001,
        bundleIdentifier: "com.google.Chrome",
        bundlePath: "/Applications/Google Chrome.app",
        localizedName: "Google Chrome",
        isRegular: true,
        isActive: true
    )
    let chrome2 = RunningAppSnapshot(
        pid: 1002,
        bundleIdentifier: "com.google.Chrome",
        bundlePath: "/Applications/Google Chrome.app",
        localizedName: "Google Chrome",
        isRegular: true,
        isActive: false
    )
    let safari = RunningAppSnapshot(
        pid: 2001,
        bundleIdentifier: "com.apple.Safari",
        bundlePath: "/Applications/Safari.app",
        localizedName: "Safari",
        isRegular: true,
        isActive: false
    )

    var tracker = AppActivationTracker()
    tracker.recordActivation(safari)
    tracker.recordActivation(chrome2)
    tracker.recordActivation(chrome1)
    // Activation stack is now: chrome1 (1001) -> chrome2 (1002) -> safari (2001)

    let discovered = [
        DiscoveredAppWindows(app: chrome1, windows: [
            DiscoveredWindow(token: .synthetic(1), title: "Personal Profile", isMinimized: false),
            DiscoveredWindow(token: .synthetic(2), title: "Shopping", isMinimized: false)
        ]),
        DiscoveredAppWindows(app: chrome2, windows: [
            DiscoveredWindow(token: .synthetic(3), title: "Sandbox Debug", isMinimized: false)
        ]),
        DiscoveredAppWindows(app: safari, windows: [
            DiscoveredWindow(token: .synthetic(4), title: "Apple Developer", isMinimized: false)
        ])
    ]

    let items = SwitcherOrdering.buildSwitcherItems(
        discovered: discovered,
        candidateApps: [chrome1, chrome2, safari],
        frontmostApp: chrome1,
        frontmostFocusedWindow: .synthetic(1),
        previousOrder: [],
        applicationOrder: tracker.applicationOrder
    )

    try expectEqual(items.count, 4)

    // Primary pass has 3 distinct entries in activation order: chrome1, chrome2, safari
    try expectEqual(items[0].app.pid, 1001)
    try expectTrue(items[0].isApplicationEntry)
    try expectEqual(items[0].displayTitle, "Google Chrome — Personal Profile")

    try expectEqual(items[1].app.pid, 1002)
    try expectTrue(items[1].isApplicationEntry)
    try expectEqual(items[1].displayTitle, "Google Chrome — Sandbox Debug")

    try expectEqual(items[2].app.pid, 2001)
    try expectTrue(items[2].isApplicationEntry)
    // Unique primary app name stays concise without window title suffix
    try expectEqual(items[2].displayTitle, "Safari")

    // Additional window of chrome1 follows at the end
    try expectEqual(items[3].app.pid, 1001)
    try expectTrue(!items[3].isApplicationEntry)
    try expectEqual(items[3].displayTitle, "Google Chrome — Shopping")
}

private func testAccessoryDockSubAppsMergeAndSameBundleHelpersExcluded() throws {
    let wechatPath = "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app"
    let chromePath = "/Applications/Google Chrome.app"

    let wechatUI = RunningAppSnapshot(
        pid: 3001,
        bundleIdentifier: "com.tencent.xinWeChat.WeChatAppEx",
        bundlePath: wechatPath,
        localizedName: "WeChatAppEx",
        isRegular: false,
        isActive: true
    )
    let wechatHelper = RunningAppSnapshot(
        pid: 3002,
        bundleIdentifier: "com.tencent.xinWeChat.WeChatAppEx",
        bundlePath: wechatPath,
        localizedName: "WeChatAppEx",
        isRegular: false,
        isActive: false
    )
    let chromeRegular = RunningAppSnapshot(
        pid: 4001,
        bundleIdentifier: "com.google.Chrome",
        bundlePath: chromePath,
        localizedName: "Google Chrome",
        isRegular: true,
        isActive: false
    )
    let chromeAccessoryHelper = RunningAppSnapshot(
        pid: 4002,
        bundleIdentifier: "com.google.Chrome.helper",
        bundlePath: chromePath,
        localizedName: "Google Chrome",
        isRegular: false,
        isActive: false
    )

    let dockPaths: Set<String> = [wechatPath, chromePath]
    let candidates = SwitcherOrdering.filterCandidateApps(
        runningApps: [wechatHelper, wechatUI, chromeRegular, chromeAccessoryHelper],
        dockBundlePaths: dockPaths
    )

    // chromeAccessoryHelper must be excluded because chromeRegular already owns chromePath
    try expectEqual(candidates.map(\.pid), [3002, 3001, 4001])

    // Windowless WeChatAppEx processes merge into a single entry preferring the active PID (3001)
    let items = SwitcherOrdering.buildSwitcherItems(
        discovered: [],
        candidateApps: candidates,
        frontmostApp: wechatUI,
        frontmostFocusedWindow: nil,
        previousOrder: [],
        applicationOrder: [wechatUI.groupKey, chromeRegular.groupKey]
    )

    try expectEqual(items.count, 2)
    try expectEqual(items[0].app.pid, 3001)
    try expectEqual(items[0].displayTitle, "WeChatAppEx")
    try expectEqual(items[1].app.pid, 4001)
}

private func testAllMinimizedWindowsAttachFallbackRestoreTokenOnlyWhenNeeded() throws {
    let finder = RunningAppSnapshot(pid: 5001, bundlePath: "/System/Library/CoreServices/Finder.app", localizedName: "Finder")
    let notes = RunningAppSnapshot(pid: 5002, bundlePath: "/System/Applications/Notes.app", localizedName: "Notes")

    let discovered = [
        // Finder: ALL windows minimized -> primary entry should carry fallbackRestoreToken = .synthetic(10)
        DiscoveredAppWindows(app: finder, windows: [
            DiscoveredWindow(token: .synthetic(10), title: "Downloads", isMinimized: true),
            DiscoveredWindow(token: .synthetic(11), title: "Documents", isMinimized: true)
        ]),
        // Notes: 1 minimized + 1 visible -> primary entry must NOT auto-unminimize minimized window
        DiscoveredAppWindows(app: notes, windows: [
            DiscoveredWindow(token: .synthetic(20), title: "Archived Note", isMinimized: true),
            DiscoveredWindow(token: .synthetic(21), title: "Active Note", isMinimized: false)
        ])
    ]

    let items = SwitcherOrdering.buildSwitcherItems(
        discovered: discovered,
        candidateApps: [finder, notes],
        frontmostApp: nil,
        frontmostFocusedWindow: nil,
        previousOrder: [],
        applicationOrder: [finder.groupKey, notes.groupKey]
    )

    let finderPrimary = items.first { $0.app.pid == 5001 && $0.isApplicationEntry }
    let notesPrimary = items.first { $0.app.pid == 5002 && $0.isApplicationEntry }

    try expectEqual(finderPrimary?.fallbackRestoreToken, .synthetic(10))
    try expectEqual(notesPrimary?.fallbackRestoreToken, nil)
}

private func testPreviousOrderPreservationAndFocusedWindowPromotion() throws {
    let terminal = RunningAppSnapshot(pid: 6001, bundlePath: "/System/Applications/Utilities/Terminal.app", localizedName: "Terminal")
    let discovered = [
        DiscoveredAppWindows(app: terminal, windows: [
            DiscoveredWindow(token: .synthetic(1), title: "zsh — 1", isMinimized: false),
            DiscoveredWindow(token: .synthetic(2), title: "zsh — 2", isMinimized: false),
            DiscoveredWindow(token: .synthetic(3), title: "zsh — 3", isMinimized: false)
        ])
    ]

    let previousOrder = [
        SwitcherItem(app: terminal, windowToken: .synthetic(2), title: "zsh — 2", isMinimized: false),
        SwitcherItem(app: terminal, windowToken: .synthetic(3), title: "zsh — 3", isMinimized: false),
        SwitcherItem(app: terminal, windowToken: .synthetic(1), title: "zsh — 1", isMinimized: false)
    ]

    // Window 3 is currently focused -> promoted ahead of preserved order [2, 3, 1] => [3, 2, 1]
    let items = SwitcherOrdering.buildSwitcherItems(
        discovered: discovered,
        candidateApps: [terminal],
        frontmostApp: terminal,
        frontmostFocusedWindow: .synthetic(3),
        previousOrder: previousOrder,
        applicationOrder: [terminal.groupKey]
    )

    try expectEqual(items.map(\.windowToken), [.synthetic(3), .synthetic(2), .synthetic(1)])
    try expectTrue(items[0].isApplicationEntry)
    try expectTrue(!items[1].isApplicationEntry)
    try expectTrue(!items[2].isApplicationEntry)
}

@main
struct TestRunner {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("testBasicOptionTabCycleAndWrapAround", testBasicOptionTabCycleAndWrapAround),
            ("testModifierIsolationLetsCmdAndCtrlShortcutsPassThrough", testModifierIsolationLetsCmdAndCtrlShortcutsPassThrough),
            ("testEscapeCancelsAndSwallowsPairedKeyUpWithoutLeak", testEscapeCancelsAndSwallowsPairedKeyUpWithoutLeak),
            ("testQuickOptionReleaseDuringLoadingAndMidLoadEscapeCancel", testQuickOptionReleaseDuringLoadingAndMidLoadEscapeCancel),
            ("testSchemeBMultiInstanceRegularAppsStaySeparateAndDisambiguateTitles", testSchemeBMultiInstanceRegularAppsStaySeparateAndDisambiguateTitles),
            ("testAccessoryDockSubAppsMergeAndSameBundleHelpersExcluded", testAccessoryDockSubAppsMergeAndSameBundleHelpersExcluded),
            ("testAllMinimizedWindowsAttachFallbackRestoreTokenOnlyWhenNeeded", testAllMinimizedWindowsAttachFallbackRestoreTokenOnlyWhenNeeded),
            ("testPreviousOrderPreservationAndFocusedWindowPromotion", testPreviousOrderPreservationAndFocusedWindowPromotion)
        ]

        var passed = 0
        for (name, body) in tests {
            do {
                try body()
                passed += 1
                print("[PASS] \(name)")
            } catch {
                fputs("[FAIL] \(name): \(error)\n", stderr)
                exit(1)
            }
        }
        print("All \(passed)/\(tests.count) tests passed.")
    }
}
