import Foundation

enum ShortcutAction: Equatable, Sendable {
    case none
    case startLoading(token: Int)
    case presentPanel(selectedIndex: Int)
    case updateSelection(index: Int)
    case commitSelection(index: Int)
    case cancel
}

struct ShortcutStateMachine: Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case loading(optionDown: Bool, pendingSteps: Int, token: Int)
        case active(selectedIndex: Int, itemCount: Int, token: Int)
    }

    private(set) var phase: Phase = .idle
    private(set) var generation: Int = 0
    private var swallowedKeyCodes = Set<Int64>()

    var isSessionActive: Bool {
        phase != .idle
    }

    mutating func handleFlagsChanged(modifiers: ShortcutModifiers) -> ShortcutAction {
        let optionDown = modifiers.contains(.option)
        switch phase {
        case .idle:
            return .none
        case let .loading(_, pendingSteps, token):
            phase = .loading(optionDown: optionDown, pendingSteps: pendingSteps, token: token)
            return .none
        case let .active(selectedIndex, _, _):
            guard !optionDown else { return .none }
            phase = .idle
            return .commitSelection(index: selectedIndex)
        }
    }

    mutating func handleKeyEvent(
        isKeyDown: Bool,
        keyCode: Int64,
        modifiers: ShortcutModifiers
    ) -> (intercept: Bool, action: ShortcutAction) {
        if !isKeyDown {
            if swallowedKeyCodes.remove(keyCode) != nil {
                return (true, .none)
            }
            return (false, .none)
        }

        if keyCode == KeyCode.tab {
            let step = modifiers.contains(.shift) ? -1 : 1
            switch phase {
            case .idle:
                guard modifiers.contains(.option),
                      modifiers.isDisjoint(with: [.command, .control]) else {
                    return (false, .none)
                }
                swallowedKeyCodes.insert(keyCode)
                generation += 1
                let token = generation
                phase = .loading(optionDown: true, pendingSteps: step, token: token)
                return (true, .startLoading(token: token))

            case let .loading(optionDown, pendingSteps, token):
                guard optionDown || modifiers.contains(.option) else {
                    return (false, .none)
                }
                swallowedKeyCodes.insert(keyCode)
                phase = .loading(
                    optionDown: modifiers.contains(.option),
                    pendingSteps: pendingSteps + step,
                    token: token
                )
                return (true, .none)

            case let .active(selectedIndex, itemCount, token):
                swallowedKeyCodes.insert(keyCode)
                guard itemCount > 0 else { return (true, .none) }
                let nextIndex = SwitcherOrdering.wrapIndex(selectedIndex + step, count: itemCount)
                phase = .active(selectedIndex: nextIndex, itemCount: itemCount, token: token)
                return (true, .updateSelection(index: nextIndex))
            }
        }

        if keyCode == KeyCode.escape, phase != .idle {
            swallowedKeyCodes.insert(keyCode)
            generation += 1
            phase = .idle
            return (true, .cancel)
        }

        return (false, .none)
    }

    mutating func didFinishLoading(itemCount: Int, token: Int) -> ShortcutAction {
        guard case let .loading(optionDown, pendingSteps, currentToken) = phase,
              currentToken == token else {
            return .none
        }
        guard itemCount > 0 else {
            phase = .idle
            return .cancel
        }
        let selectedIndex = SwitcherOrdering.wrapIndex(pendingSteps, count: itemCount)
        if optionDown {
            phase = .active(selectedIndex: selectedIndex, itemCount: itemCount, token: token)
            return .presentPanel(selectedIndex: selectedIndex)
        } else {
            phase = .idle
            return .commitSelection(index: selectedIndex)
        }
    }

    mutating func reset() {
        generation += 1
        phase = .idle
        swallowedKeyCodes.removeAll()
    }
}
