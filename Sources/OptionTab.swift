import AppKit
@preconcurrency import ApplicationServices
import os

@MainActor
private final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "Switcher")
    private let panelController = SwitcherPanelController()
    private var stateMachine = ShortcutStateMachine()
    private var activationTracker = AppActivationTracker()

    private var eventTap: CFMachPort?
    private var workspaceObservers = [NSObjectProtocol]()
    private var currentItems = [SwitcherItem]()
    private var previousWindowOrder = [SwitcherItem]()
    private var cachedDockBundlePaths = Set<String>()
    private var isDockCacheDirty = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility permission not granted; prompting user and exiting.")
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            NSApp.terminate(nil)
            return
        }

        guard setupEventTap() else {
            logger.error("Failed to create CGEventTap; exiting.")
            NSApp.terminate(nil)
            return
        }

        seedInitialWindowStackOrder()
        registerWorkspaceObservers()

        if let frontmost = NSWorkspace.shared.frontmostApplication {
            activationTracker.recordActivation(RunningAppSnapshot(runningApplication: frontmost))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func setupEventTap() -> Bool {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap,
              let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        self.eventTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func seedInitialWindowStackOrder() {
        let runningByPID = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, RunningAppSnapshot(runningApplication: $0))
            }
        )
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var orderedOwners = [RunningAppSnapshot]()
        for windowInfo in windowList where (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
            guard let pid = (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let snapshot = runningByPID[pid],
                  snapshot.isRegular else {
                continue
            }
            orderedOwners.append(snapshot)
        }
        activationTracker.seedInitialOrder(windowOwners: orderedOwners)
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        let activateObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activationTracker.recordActivation(RunningAppSnapshot(runningApplication: app))
            }
        }

        let launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isDockCacheDirty = true
            }
        }

        let terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isDockCacheDirty = true
                if let app {
                    self.panelController.invalidateCachedIcon(for: RunningAppSnapshot(runningApplication: app))
                }
                let activeSnapshots = NSWorkspace.shared.runningApplications.map(RunningAppSnapshot.init(runningApplication:))
                self.activationTracker.pruneInactiveKeys(activeApps: activeSnapshots)
            }
        }

        workspaceObservers = [activateObserver, launchObserver, terminateObserver]
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let coordinatorAddress = Int(bitPattern: userInfo)
        let modifiers = ShortcutModifiers(cgFlags: event.flags)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let shouldIntercept = MainActor.assumeIsolated { () -> Bool in
            guard let pointer = UnsafeMutableRawPointer(bitPattern: coordinatorAddress) else {
                return false
            }
            let coordinator = Unmanaged<AppCoordinator>.fromOpaque(pointer).takeUnretainedValue()
            return coordinator.processTapEvent(type: type, modifiers: modifiers, keyCode: keyCode)
        }
        return shouldIntercept ? nil : Unmanaged.passUnretained(event)
    }

    private func processTapEvent(
        type: CGEventType,
        modifiers: ShortcutModifiers,
        keyCode: Int64
    ) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            guard AXIsProcessTrusted() else {
                logger.error("Accessibility permission revoked at runtime; cancelling session and terminating.")
                cancelSession()
                NSApp.terminate(nil)
                return false
            }
            logger.notice("CGEventTap was disabled (\(String(describing: type.rawValue))); re-enabling.")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }

        if type == .flagsChanged {
            let action = stateMachine.handleFlagsChanged(modifiers: modifiers)
            executeAction(action)
            return false
        }

        guard type == .keyDown || type == .keyUp else {
            return false
        }

        let result = stateMachine.handleKeyEvent(
            isKeyDown: type == .keyDown,
            keyCode: keyCode,
            modifiers: modifiers
        )
        executeAction(result.action)
        return result.intercept
    }

    private func executeAction(_ action: ShortcutAction) {
        switch action {
        case .none:
            break
        case let .startLoading(token):
            beginLoadingWindows(token: token)
        case let .presentPanel(selectedIndex):
            panelController.present(items: currentItems, selectedIndex: selectedIndex)
        case let .updateSelection(index):
            panelController.updateSelection(selectedIndex: index, items: currentItems)
        case let .commitSelection(index):
            commitSelection(at: index)
        case .cancel:
            cancelSession()
        }
    }

    private func beginLoadingWindows(token: Int) {
        let workspace = NSWorkspace.shared
        if let frontmost = workspace.frontmostApplication {
            activationTracker.recordActivation(RunningAppSnapshot(runningApplication: frontmost))
        }

        // Snapshot all AppKit state on @MainActor before dispatching blocking AX IPC work.
        let runningApps = workspace.runningApplications.map(RunningAppSnapshot.init(runningApplication:))
        activationTracker.pruneInactiveKeys(activeApps: runningApps)

        let frontmostSnapshot = workspace.frontmostApplication.map(RunningAppSnapshot.init(runningApplication:))
        let dockPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: AppConstants.dockBundleIdentifier)
            .first?
            .processIdentifier ?? 0

        let hasNonRegularCandidates = runningApps.contains { !$0.isRegular && !$0.isProhibited && $0.bundlePath != nil }
        let shouldRefreshDock = isDockCacheDirty && hasNonRegularCandidates
        let existingDockPaths = cachedDockBundlePaths
        let orderSnapshot = previousWindowOrder
        let appOrderSnapshot = activationTracker.applicationOrder
        let bundleRanksSnapshot = activationTracker.fallbackBundleRanks

        Task { [weak self] in
            let (items, refreshedDockPaths) = await Task.detached(priority: .userInitiated) { () -> ([SwitcherItem], Set<String>?) in
                let refreshed: Set<String>?
                if shouldRefreshDock, dockPID > 0 {
                    refreshed = AccessibilityService.fetchDockApplicationPaths(dockPID: dockPID)
                } else {
                    refreshed = nil
                }
                let effectiveDockPaths = refreshed ?? existingDockPaths

                let candidates = SwitcherOrdering.filterCandidateApps(
                    runningApps: runningApps,
                    dockBundlePaths: effectiveDockPaths
                )
                let discovery = AccessibilityService.discoverWindows(
                    for: candidates,
                    frontmostPID: frontmostSnapshot?.pid
                )
                let builtItems = SwitcherOrdering.buildSwitcherItems(
                    discovered: discovery.discovered,
                    candidateApps: candidates,
                    frontmostApp: frontmostSnapshot,
                    frontmostFocusedWindow: discovery.frontmostFocusedWindow,
                    previousOrder: orderSnapshot,
                    applicationOrder: appOrderSnapshot,
                    fallbackBundleRanks: bundleRanksSnapshot
                )
                return (builtItems, refreshed)
            }.value

            guard let self else { return }
            if let refreshedDockPaths {
                self.cachedDockBundlePaths = refreshedDockPaths
                self.isDockCacheDirty = false
            }
            self.handleLoadedItems(items, token: token)
        }
    }

    private func handleLoadedItems(_ items: [SwitcherItem], token: Int) {
        let nextAction = stateMachine.didFinishLoading(itemCount: items.count, token: token)
        guard nextAction != .none else { return }

        currentItems = items
        previousWindowOrder = items
        executeAction(nextAction)
    }

    private func cancelSession() {
        stateMachine.reset()
        currentItems.removeAll()
        panelController.hide()
    }

    private func commitSelection(at selectedIndex: Int) {
        panelController.hide()
        guard currentItems.indices.contains(selectedIndex) else {
            cancelSession()
            return
        }

        let chosen = currentItems[selectedIndex]
        var updatedOrder = currentItems
        updatedOrder.insert(updatedOrder.remove(at: selectedIndex), at: 0)
        previousWindowOrder = updatedOrder
        currentItems.removeAll()

        if chosen.isApplicationEntry {
            let pid = chosen.app.pid
            let restoreToken = chosen.fallbackRestoreToken
            DispatchQueue.global(qos: .userInitiated).async {
                if let restoreElement = restoreToken?.axElement {
                    AccessibilityService.unminimizeIfNeeded(restoreElement)
                }
                let succeeded = AccessibilityService.activateProcessWindowGroup(pid: pid)
                if !succeeded {
                    DispatchQueue.main.async {
                        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
                    }
                }
            }
            return
        }

        guard let targetToken = chosen.windowToken, targetToken.axElement != nil else {
            let pid = chosen.app.pid
            DispatchQueue.global(qos: .userInitiated).async {
                if !AccessibilityService.activateProcessWindowGroup(pid: pid) {
                    DispatchQueue.main.async {
                        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
                    }
                }
            }
            return
        }

        let pid = chosen.app.pid
        DispatchQueue.global(qos: .userInitiated).async {
            if let element = targetToken.axElement {
                AccessibilityService.unminimizeIfNeeded(element)
            }
            DispatchQueue.main.async {
                _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
                DispatchQueue.global(qos: .userInitiated).async {
                    if let element = targetToken.axElement {
                        AccessibilityService.raiseAndFocusSpecificWindow(element)
                    }
                }
            }
        }
    }
}

@main
struct OptionTabMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppCoordinator()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
