import Foundation

struct AppActivationTracker: Sendable {
    private(set) var applicationOrder = [String]()
    private var bundleFallbackOrder = [String]()

    mutating func seedInitialOrder(windowOwners: [RunningAppSnapshot]) {
        for app in windowOwners where !app.isProhibited && app.bundleIdentifier != AppConstants.bundleIdentifier {
            let key = app.groupKey
            if !applicationOrder.contains(key) {
                applicationOrder.append(key)
            }
            if let bundleKey = app.bundleGroupKey, !bundleFallbackOrder.contains(bundleKey) {
                bundleFallbackOrder.append(bundleKey)
            }
        }
    }

    mutating func recordActivation(_ app: RunningAppSnapshot, excludedBundleIdentifier: String = AppConstants.bundleIdentifier) {
        guard !app.isProhibited, app.bundleIdentifier != excludedBundleIdentifier else { return }
        let key = app.groupKey
        applicationOrder.removeAll { $0 == key }
        applicationOrder.insert(key, at: 0)

        if let bundleKey = app.bundleGroupKey {
            bundleFallbackOrder.removeAll { $0 == bundleKey }
            bundleFallbackOrder.insert(bundleKey, at: 0)
        }
    }

    mutating func pruneInactiveKeys(activeApps: [RunningAppSnapshot]) {
        var validKeys = Set<String>()
        var validBundleKeys = Set<String>()
        validKeys.reserveCapacity(activeApps.count)
        for app in activeApps {
            validKeys.insert(app.groupKey)
            if let bundleKey = app.bundleGroupKey {
                validBundleKeys.insert(bundleKey)
            }
        }
        applicationOrder.removeAll { !validKeys.contains($0) }
        bundleFallbackOrder.removeAll { !validBundleKeys.contains($0) }
    }

    var fallbackBundleRanks: [String: Int] {
        Dictionary(uniqueKeysWithValues: bundleFallbackOrder.enumerated().map { ($0.element, $0.offset) })
    }
}

enum SwitcherOrdering {
    static func wrapIndex(_ value: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((value % count) + count) % count
    }

    /// Filters running apps down to switchable candidates under Scheme B:
    /// - All `.regular` apps (excluding OptionTab itself) are included.
    /// - Non-regular apps are included only if their `.app` bundle path is in the Dock AND
    ///   no `.regular` running process already represents that same `.app` bundle path.
    static func filterCandidateApps(
        runningApps: [RunningAppSnapshot],
        dockBundlePaths: Set<String>,
        excludedBundleIdentifier: String = AppConstants.bundleIdentifier
    ) -> [RunningAppSnapshot] {
        var regularBundlePaths = Set<String>()
        for app in runningApps where app.isRegular && app.bundleIdentifier != excludedBundleIdentifier {
            if let path = app.bundlePath {
                regularBundlePaths.insert(path)
            }
        }

        return runningApps.filter { app in
            guard !app.isProhibited, app.bundleIdentifier != excludedBundleIdentifier else { return false }
            if app.isRegular { return true }
            guard let path = app.bundlePath else { return false }
            return dockBundlePaths.contains(path) && !regularBundlePaths.contains(path)
        }
    }

    static func buildSwitcherItems(
        discovered: [DiscoveredAppWindows],
        candidateApps: [RunningAppSnapshot],
        frontmostApp: RunningAppSnapshot?,
        frontmostFocusedWindow: WindowToken?,
        previousOrder: [SwitcherItem],
        applicationOrder: [String],
        fallbackBundleRanks: [String: Int] = [:]
    ) -> [SwitcherItem] {
        var items = [SwitcherItem]()
        for entry in discovered {
            for window in entry.windows {
                let title = window.title.isEmpty ? entry.app.localizedName : window.title
                items.append(
                    SwitcherItem(
                        app: entry.app,
                        windowToken: window.token,
                        title: title,
                        isMinimized: window.isMinimized
                    )
                )
            }
        }

        // Include running candidate apps without accessible windows (e.g. windowless Dock apps or WeChatAppEx).
        var representedKeys = Set(items.map(\.app.groupKey))
        let groupedCandidates = Dictionary(grouping: candidateApps, by: \.groupKey)
        for app in candidateApps {
            let key = app.groupKey
            guard representedKeys.insert(key).inserted else { continue }
            let instances = groupedCandidates[key] ?? [app]
            let target = instances.first(where: \.isActive)
                ?? instances.first(where: \.isRegular)
                ?? app
            items.append(
                SwitcherItem(
                    app: target,
                    windowToken: nil,
                    title: target.localizedName,
                    isMinimized: false
                )
            )
        }

        // Preserve previous within-session / post-selection window ordering in O(N) average time.
        if !previousOrder.isEmpty {
            var buckets = [String: [Int]]()
            for (index, item) in items.enumerated() {
                buckets[item.app.groupKey, default: []].append(index)
            }
            var consumed = [Bool](repeating: false, count: items.count)
            var reordered = [SwitcherItem]()
            reordered.reserveCapacity(items.count)

            for old in previousOrder {
                guard let indices = buckets[old.app.groupKey] else { continue }
                if let matchedIndex = indices.first(where: { !consumed[$0] && items[$0].matches(old) }) {
                    consumed[matchedIndex] = true
                    reordered.append(items[matchedIndex])
                }
            }
            for (index, item) in items.enumerated() where !consumed[index] {
                reordered.append(item)
            }
            items = reordered
        }

        // Ensure the currently focused window of the frontmost app leads its app's window list.
        if let frontmostApp, let frontmostFocusedWindow,
           let focusedIndex = items.firstIndex(where: {
               $0.app.groupKey == frontmostApp.groupKey && $0.windowToken == frontmostFocusedWindow
           }) {
            let focusedItem = items.remove(at: focusedIndex)
            items.insert(focusedItem, at: 0)
        }

        return sortAndPartitionItems(
            items,
            applicationOrder: applicationOrder,
            fallbackBundleRanks: fallbackBundleRanks
        )
    }

    static func sortAndPartitionItems(
        _ items: [SwitcherItem],
        applicationOrder: [String],
        fallbackBundleRanks: [String: Int] = [:]
    ) -> [SwitcherItem] {
        var ranks = [String: Int]()
        ranks.reserveCapacity(applicationOrder.count)
        for (offset, key) in applicationOrder.enumerated() where ranks[key] == nil {
            ranks[key] = offset
        }

        let fallbackOffsetBase = ranks.count
        var nextUnrankedSlot = 0
        for item in items where ranks[item.app.groupKey] == nil {
            defer { nextUnrankedSlot += 1 }
            if let bundleKey = item.app.bundleGroupKey, let fallback = fallbackBundleRanks[bundleKey] {
                ranks[item.app.groupKey] = fallbackOffsetBase + fallback * 1024 + nextUnrankedSlot
            } else {
                ranks[item.app.groupKey] = fallbackOffsetBase + (fallbackBundleRanks.count + 1) * 1024 + nextUnrankedSlot
            }
        }

        let sorted = items.enumerated().sorted { left, right in
            let leftRank = ranks[left.element.app.groupKey] ?? Int.max
            let rightRank = ranks[right.element.app.groupKey] ?? Int.max
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)

        // Track whether an application has any unminimized window; if all its windows are minimized,
        // attach the first minimized window token so activating the primary app entry restores it.
        var hasVisibleWindowByGroup = [String: Bool]()
        var firstMinimizedTokenByGroup = [String: WindowToken]()
        for item in sorted {
            let key = item.app.groupKey
            if item.windowToken != nil {
                if !item.isMinimized {
                    hasVisibleWindowByGroup[key] = true
                } else if firstMinimizedTokenByGroup[key] == nil {
                    firstMinimizedTokenByGroup[key] = item.windowToken
                }
            }
        }

        var seenGroups = Set<String>()
        var primary = [SwitcherItem]()
        var additional = [SwitcherItem]()
        primary.reserveCapacity(sorted.count)

        for var item in sorted {
            let key = item.app.groupKey
            item.isApplicationEntry = seenGroups.insert(key).inserted
            if item.isApplicationEntry {
                if hasVisibleWindowByGroup[key] != true {
                    item.fallbackRestoreToken = firstMinimizedTokenByGroup[key]
                }
                primary.append(item)
            } else {
                additional.append(item)
            }
        }

        return primary + additional
    }

    /// Returns the index where the additional-windows section begins, or `nil` when no separator is needed.
    static func sectionSeparatorIndex(in items: [SwitcherItem]) -> Int? {
        guard let firstAdditional = items.firstIndex(where: { !$0.isApplicationEntry }),
              firstAdditional > 0 else {
            return nil
        }
        return firstAdditional
    }
}
