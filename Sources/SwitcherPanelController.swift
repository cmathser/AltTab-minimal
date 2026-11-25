import AppKit

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SwitcherPanelController {
    private var panel: NSPanel?
    private var scrollView: NSScrollView?
    private var rowViews = [NSView]()
    private var titleLabels = [NSTextField]()
    private var iconCache = [String: NSImage]()

    func present(items: [SwitcherItem], selectedIndex: Int) {
        guard !items.isEmpty else {
            hide()
            return
        }

        rowViews.removeAll(keepingCapacity: true)
        titleLabels.removeAll(keepingCapacity: true)

        let visibleCount = min(items.count, LayoutMetrics.maxVisibleRows)
        let separatorIndex = SwitcherOrdering.sectionSeparatorIndex(in: items)
        let visibleSeparatorHeight: CGFloat = (separatorIndex.map { $0 < visibleCount } ?? false)
            ? LayoutMetrics.sectionSeparatorAreaHeight
            : 0
        let documentSeparatorHeight: CGFloat = separatorIndex != nil
            ? LayoutMetrics.sectionSeparatorAreaHeight
            : 0
        let panelHeight = CGFloat(visibleCount) * LayoutMetrics.rowStride
            + LayoutMetrics.verticalPadding
            + visibleSeparatorHeight
        let panelWidth = LayoutMetrics.panelWidth
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? LayoutMetrics.fallbackScreenFrame
        let panelRect = NSRect(
            x: screenFrame.midX - panelWidth / 2,
            y: screenFrame.midY - panelHeight / 2,
            width: panelWidth,
            height: panelHeight
        )

        let panel = self.panel ?? makePanel(initialRect: panelRect)
        panel.setFrame(panelRect, display: false)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        scrollView.hasVerticalScroller = items.count > visibleCount
        scrollView.drawsBackground = false

        let documentHeight = CGFloat(items.count) * LayoutMetrics.rowStride
            + LayoutMetrics.verticalPadding
            + documentSeparatorHeight
        let documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: documentHeight))
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(LayoutMetrics.panelBackgroundAlpha)
            .cgColor
        documentView.layer?.cornerRadius = LayoutMetrics.panelCornerRadius

        var resolvedSeparatorCGColor: CGColor = NSColor.separatorColor.cgColor
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedSeparatorCGColor = NSColor.separatorColor.cgColor
        }

        for (index, item) in items.enumerated() {
            if let sep = separatorIndex, index == sep {
                let separatorOriginY = CGFloat(index) * LayoutMetrics.rowStride
                    + LayoutMetrics.horizontalInset
                    + floor((LayoutMetrics.sectionSeparatorAreaHeight - LayoutMetrics.sectionSeparatorThickness) / 2)
                    - 1
                let separatorView = NSView(
                    frame: NSRect(
                        x: LayoutMetrics.sectionSeparatorHorizontalInset,
                        y: separatorOriginY,
                        width: panelWidth - LayoutMetrics.sectionSeparatorHorizontalInset * 2,
                        height: LayoutMetrics.sectionSeparatorThickness
                    )
                )
                separatorView.wantsLayer = true
                separatorView.layer?.backgroundColor = resolvedSeparatorCGColor
                documentView.addSubview(separatorView)
            }

            let isSelected = (index == selectedIndex)
            let extraOffset = (separatorIndex.map { index >= $0 } ?? false)
                ? LayoutMetrics.sectionSeparatorAreaHeight
                : 0
            let rowOriginY = CGFloat(index) * LayoutMetrics.rowStride + LayoutMetrics.horizontalInset + extraOffset
            let rowFrame = NSRect(
                x: LayoutMetrics.horizontalInset,
                y: rowOriginY,
                width: panelWidth - LayoutMetrics.horizontalInset * 2,
                height: LayoutMetrics.rowHeight
            )

            let rowView = NSView(frame: rowFrame)
            rowView.wantsLayer = true
            rowView.layer?.cornerRadius = LayoutMetrics.rowCornerRadius
            rowView.layer?.backgroundColor = selectionBackgroundColor(isSelected: isSelected)

            let iconView = NSImageView(frame: LayoutMetrics.iconFrame)
            iconView.image = resolveIcon(for: item.app)
            rowView.addSubview(iconView)

            let label = NSTextField(labelWithString: item.displayTitle)
            label.frame = LayoutMetrics.labelFrame
            label.lineBreakMode = .byTruncatingTail
            label.attributedStringValue = makeTitleAttributedString(for: item, isSelected: isSelected)
            rowView.addSubview(label)

            documentView.addSubview(rowView)
            rowViews.append(rowView)
            titleLabels.append(label)
        }

        scrollView.documentView = documentView
        panel.contentView = scrollView
        panel.orderFrontRegardless()

        self.panel = panel
        self.scrollView = scrollView
        scrollRowIntoView(at: selectedIndex)
    }

    func updateSelection(selectedIndex: Int, items: [SwitcherItem]) {
        guard let scrollView, rowViews.count == items.count else {
            present(items: items, selectedIndex: selectedIndex)
            return
        }
        for index in rowViews.indices {
            let isSelected = (index == selectedIndex)
            rowViews[index].layer?.backgroundColor = selectionBackgroundColor(isSelected: isSelected)
            titleLabels[index].attributedStringValue = makeTitleAttributedString(for: items[index], isSelected: isSelected)
        }
        if rowViews.indices.contains(selectedIndex) {
            scrollView.contentView.scrollToVisible(rowViews[selectedIndex].frame)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        scrollView = nil
        rowViews.removeAll(keepingCapacity: true)
        titleLabels.removeAll(keepingCapacity: true)
    }

    func invalidateCachedIcon(for app: RunningAppSnapshot) {
        iconCache.removeValue(forKey: app.iconCacheKey)
    }

    private func makePanel(initialRect: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        return panel
    }

    private func makeTitleAttributedString(for item: SwitcherItem, isSelected: Bool) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let primaryColor: NSColor = isSelected ? .white : .labelColor
        let result = NSMutableAttributedString(
            string: item.primaryTitle,
            attributes: [
                .font: font,
                .foregroundColor: primaryColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        if let secondaryTitle = item.secondaryTitle {
            let secondaryColor: NSColor = isSelected
                ? NSColor.white.withAlphaComponent(LayoutMetrics.selectedSecondaryTextAlpha)
                : .secondaryLabelColor
            result.append(
                NSAttributedString(
                    string: " — \(secondaryTitle)",
                    attributes: [
                        .font: font,
                        .foregroundColor: secondaryColor,
                        .paragraphStyle: paragraphStyle
                    ]
                )
            )
        }

        return result
    }

    private func selectionBackgroundColor(isSelected: Bool) -> CGColor {
        if isSelected {
            return NSColor.controlAccentColor
                .withAlphaComponent(LayoutMetrics.selectionHighlightAlpha)
                .cgColor
        }
        return NSColor.clear.cgColor
    }

    private func scrollRowIntoView(at index: Int) {
        guard let scrollView, rowViews.indices.contains(index) else { return }
        scrollView.contentView.scrollToVisible(rowViews[index].frame)
    }

    private func resolveIcon(for app: RunningAppSnapshot) -> NSImage? {
        let key = app.iconCacheKey
        if let cached = iconCache[key] {
            return cached
        }
        let resolved: NSImage?
        if let path = app.bundlePath {
            resolved = NSWorkspace.shared.icon(forFile: path)
        } else {
            resolved = NSRunningApplication(processIdentifier: app.pid)?.icon
        }
        if let resolved {
            iconCache[key] = resolved
        }
        return resolved
    }
}
