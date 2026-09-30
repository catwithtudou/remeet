import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import RemeetCore
#endif

@MainActor
final class RecallPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Geometry is clamped by the controller. Allow the black surface to join
    // the physical notch at the screen edge instead of avoiding the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Coordinates use AppKit's global screen space, including displays above/left of the primary.
struct NotchGeometry {
    let anchor: NSPoint // Bottom center of the physical notch, or the fallback top edge.
    let width: CGFloat
    let depth: CGFloat
    static let compactSymbolSide: CGFloat = 18
    static let compactWing = compactSymbolSide + 12 // 6 pt clear space on either side of the mark.

    var indicatorFrame: NSRect {
        let height = depth > 0 ? depth : 24
        let span = depth > 0 ? width + 2 * Self.compactWing : 28
        return NSRect(x: anchor.x - span / 2, y: anchor.y + depth - height,
                      width: span, height: height)
    }
    var cameraFrame: NSRect {
        NSRect(x: anchor.x - width / 2, y: anchor.y, width: width, height: depth)
    }
    var symbolFrame: NSRect {
        let frame = indicatorFrame
        let side = min(Self.compactSymbolSide, max(0, frame.height - 4))
        let regionWidth = depth > 0 ? Self.compactWing : frame.width
        return NSRect(x: frame.minX + (regionWidth - side) / 2,
                      y: frame.midY - side / 2, width: side, height: side)
    }
}

@MainActor
private final class TrackingContainer: NSView {
    var onPointerChange: (() -> Void)?
    var showsSurface = false { didSet { needsDisplay = true } }
    var showsIndicator = false { didSet { needsDisplay = true } }
    var hasContent = false { didSet { needsDisplay = true } }
    private var pointerInside = false { didSet { needsDisplay = true } }
    var indicatorSymbolFrame = NSRect.zero
    var bottomRadius: CGFloat = 22 { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        guard showsSurface || showsIndicator else { return }
        let w = bounds.width, h = bounds.height
        let r = min(bottomRadius, w / 2, h)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: h))
        path.line(to: NSPoint(x: 0, y: r))
        path.curve(to: NSPoint(x: r, y: 0),
                   controlPoint1: NSPoint(x: 0, y: r * 0.45),
                   controlPoint2: NSPoint(x: r * 0.45, y: 0))
        path.line(to: NSPoint(x: w - r, y: 0))
        path.curve(to: NSPoint(x: w, y: r),
                   controlPoint1: NSPoint(x: w - r * 0.45, y: 0),
                   controlPoint2: NSPoint(x: w, y: r * 0.45))
        path.line(to: NSPoint(x: w, y: h))
        path.close()
        NSColor.black.setFill()
        path.fill()
        if showsIndicator {
            RemeetArtwork.drawMark(in: indicatorSymbolFrame, happy: pointerInside && hasContent,
                                   muted: !hasContent)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let newArea = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(newArea)
        area = newArea
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; onPointerChange?() }
    override func mouseExited(with event: NSEvent) { pointerInside = false; onPointerChange?() }
}

/// Header frames are kept outside the camera gap, in the panel's local coordinates.
struct NotchHeaderLayout {
    static let wingWidth: CGFloat = 112
    let size: NSSize
    let cameraWidth: CGFloat

    var left: NSRect {
        NSRect(x: 12, y: 0, width: Self.wingWidth - 24, height: size.height)
    }
    var right: NSRect {
        NSRect(x: size.width - Self.wingWidth + 12, y: 0,
               width: Self.wingWidth - 24, height: size.height)
    }
    var fits: Bool { size.width >= cameraWidth + 2 * Self.wingWidth }
}

private typealias HeaderState<Value> = SwiftUI.State<Value>

private struct RecallHeaderStatus: View {
    @HeaderState<Bool> private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: RemeetArtwork.image(size: 22, happy: hovering))
                .frame(width: 22, height: 22)
                .rotationEffect(.degrees(hovering && !reduceMotion ? -8 : 0))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
                .accessibilityHidden(true)
            Text("回顾中").foregroundStyle(.white.opacity(0.7))
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在回顾笔记")
        .environment(\.colorScheme, .dark)
    }
}

private struct RecallHeaderActions: View {
    let next: () -> Void
    let collapse: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            control("arrow.triangle.2.circlepath", label: "换一条", id: "nextQuote", action: next)
            control("gearshape", label: "打开设置", id: "openSettings", action: openSettings)
            control("chevron.up", label: "收起", id: "collapseQuote", action: collapse)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private func control(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
        .help(label)
    }
}

struct QuoteCard: View {
    let quote: Quote
    let textHeight: CGFloat
    let fontSize: CGFloat
    let sourceSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(quote.text)
                    .font(.system(size: fontSize))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: textHeight)
            .id(quote.text)
            if let source = quote.source, !source.isEmpty {
                Text(source).font(.system(size: sourceSize)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(20)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

/// A short, interruptible geometry transition. The content keeps its final font
/// size; only the black surface and clipping bounds grow around the notch.
private struct PanelTransition {
    let from: NSRect
    let to: NSRect
    let fromOpacity: CGFloat
    let fromRadius: CGFloat
    let expanded: Bool
    let start: Double
    let duration: Double

    func values(at progress: Double) -> (frame: NSRect, opacity: CGFloat, radius: CGFloat) {
        let p = CGFloat(min(1, max(0, progress)))
        let eased = p * p * (3 - 2 * p)
        let frame = NSRect(
            x: from.minX + (to.minX - from.minX) * eased,
            y: from.minY + (to.minY - from.minY) * eased,
            width: from.width + (to.width - from.width) * eased,
            height: from.height + (to.height - from.height) * eased)
        // Reveal after there is room to read. On collapse, hide text early.
        let textProgress = expanded ? min(1, max(0, (p - 0.25) / 0.75)) : min(1, p / 0.45)
        let textEase = textProgress * textProgress * (3 - 2 * textProgress)
        return (frame, fromOpacity + ((expanded ? 1 : 0) - fromOpacity) * textEase,
                fromRadius + ((expanded ? 22 : 10) - fromRadius) * eased)
    }
}

@MainActor
final class NotchPanelController {
    private let panel = RecallPanel(contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let container = TrackingContainer(frame: .zero)
    private var hosting: NSHostingView<QuoteCard>?
    private var headerStatus: NSHostingView<RecallHeaderStatus>?
    private var headerActions: NSHostingView<RecallHeaderActions>?
    private var headerHeight: CGFloat { max(32, connectionHeight) }
    private var contentSize = NSSize.zero
    private var renderedQuote: Quote?
    private var renderedTextHeight: CGFloat = 0
    private var renderedFontSize: CGFloat = 0
    private var renderedWidth: CGFloat = 0
    private var fontSize = CGFloat(RecallSettings().fontSize)
    private var preferredWidth = CGFloat(RecallSettings().panelWidth)
    private var maxTextHeight = CGFloat(RecallSettings().maxTextHeight)
    private var state = PresentationState()
    private var timer: Timer?
    private var generation = 0
    private var motionTimer: Timer?
    private var motionGeneration = 0
    private var transition: PanelTransition?
    private let reduceMotion: () -> Bool
    private var quote: Quote?
    private var previewQuote: Quote?
    private var active = false
    private var hoverEnabled = true
    private var showIndicator = true
    private var screenSelection = "auto"
    private var currentScreen: NSScreen?
    private var anchor = NSPoint.zero
    private var connectionHeight: CGFloat = 0
    private var hotWidth: CGFloat = 160
    var onNext: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var isPresented: Bool { state.isPresented }
    #if DEBUG
    var indicatorIsVisible: Bool { panel.isVisible && container.showsIndicator }
    var windowIsVisible: Bool { panel.isVisible }
    var windowLevel: NSWindow.Level { panel.level }
    var physicalNotchFrame: NSRect { geometry.cameraFrame }
    var indicatorSymbolFrame: NSRect { geometry.symbolFrame }
    var displayedQuote: Quote? { renderedQuote }
    var windowFrame: NSRect { panel.frame }
    var hostedFrame: NSRect? { hosting?.frame }
    var canBecomeKey: Bool { panel.canBecomeKey }
    var notchInset: CGFloat { connectionHeight }
    var contentInset: CGFloat { headerHeight }
    var displayedFontSize: CGFloat? { hosting?.rootView.fontSize }
    var displayedTextHeight: CGFloat? { hosting?.rootView.textHeight }
    var headerFrames: [NSRect] {
        [headerStatus?.frame, headerActions?.frame].compactMap { $0 }.map {
            $0.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        }
    }
    var headerIsVisible: Bool { headerActions?.isHidden == false && (headerActions?.alphaValue ?? 0) > 0 }
    var isAnimating: Bool { transition != nil }
    var contentOpacity: CGFloat { hosting?.alphaValue ?? 0 }
    var surfaceIsVisible: Bool { container.showsSurface }
    func advanceAnimationForTesting(to fraction: Double) { advanceMotion(to: fraction) }
    #endif

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.reduceMotion = reduceMotion
        panel.title = "回见 · Remeet 回顾卡片"
        panel.identifier = NSUserInterfaceItemIdentifier("recallPanel")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        container.onPointerChange = { [weak self] in self?.updatePointer() }
        relocate()
    }

    func configure(quote: Quote?, active: Bool, hoverEnabled: Bool, showIndicator: Bool = true, screen: String,
                   fontSize: Int = RecallSettings().fontSize, panelWidth: Int = RecallSettings().panelWidth, maxTextHeight: Int = RecallSettings().maxTextHeight) {
        let screenChanged = screen != screenSelection
        let needsFreshEntry = (!self.active && active) || (self.quote == nil && quote != nil)
        self.quote = quote
        previewQuote = nil
        self.active = active
        self.hoverEnabled = hoverEnabled
        self.showIndicator = showIndicator
        self.fontSize = CGFloat(RecallSettings.fontSizeRange.contains(fontSize) ? fontSize : RecallSettings().fontSize)
        self.preferredWidth = CGFloat(RecallSettings.panelWidthRange.contains(panelWidth) ? panelWidth : RecallSettings().panelWidth)
        self.maxTextHeight = CGFloat(RecallSettings.textHeightRange.contains(maxTextHeight) ? maxTextHeight : RecallSettings().maxTextHeight)
        screenSelection = screen
        if !hoverEnabled { state.cancelPendingHover() }
        let immediately = !active || quote == nil || screenChanged
        if immediately { state.collapse() }
        if screenChanged { relocate() } else { render(animated: !immediately) }
        if needsFreshEntry { suppressStationaryHover() }
    }

    func preview(_ quote: Quote, duration: Double) {
        guard active, self.quote != nil else { return }
        previewQuote = quote
        state.present(now: ProcessInfo.processInfo.systemUptime, duration: duration)
        render()
    }

    func present(duration: Double) {
        previewQuote = nil
        guard active, quote != nil else { return }
        state.present(now: ProcessInfo.processInfo.systemUptime, duration: duration)
        render()
    }

    func collapse(immediately: Bool = false) { state.collapse(); render(animated: !immediately) }

    private var geometry: NotchGeometry {
        NotchGeometry(anchor: anchor, width: hotWidth, depth: connectionHeight)
    }

    private var hotFrame: NSRect {
        if active && showIndicator { return geometry.indicatorFrame }
        return NSRect(x: anchor.x - hotWidth / 2, y: anchor.y - 8, width: hotWidth, height: 8)
    }

    private var compactFrame: NSRect {
        if showIndicator { return geometry.indicatorFrame }
        let height = max(1, connectionHeight)
        return NSRect(x: anchor.x - hotWidth / 2,
                      y: anchor.y + connectionHeight - height, width: hotWidth, height: height)
    }

    private func suppressStationaryHover() {
        guard !state.isPresented else { return }
        state.suppressStationaryHover(inside: hotFrame.contains(NSEvent.mouseLocation))
        cancelTimer()
    }

    func relocate() {
        state.collapse()
        cancelMotion()
        let screens = NSScreen.screens
        let primary = screens.first { $0.displayID == CGMainDisplayID() } ?? screens.first
        let automatic = screens.first { CGDisplayIsBuiltin($0.displayID) != 0 && $0.safeAreaInsets.top > 0 } ?? primary
        if screenSelection == "primary" { currentScreen = primary }
        else if screenSelection == "auto" { currentScreen = automatic }
        else { currentScreen = screens.first { $0.stableID == screenSelection } ?? automatic }
        guard let screen = currentScreen else { finishCollapsed(); cancelTimer(); return }
        connectionHeight = screen.safeAreaInsets.top
        anchor = NSPoint(x: screen.frame.midX,
                         y: connectionHeight > 0 ? screen.frame.maxY - connectionHeight : screen.visibleFrame.maxY)
        if connectionHeight > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hotWidth = max(1, right.minX - left.maxX)
            anchor.x = (left.maxX + right.minX) / 2
        } else { hotWidth = 160 }
        render(animated: false)
        suppressStationaryHover()
    }

    private func render(animated: Bool = true) {
        cancelTimer()
        guard active, let quote = previewQuote ?? quote, let screen = currentScreen else {
            cancelMotion()
            finishCollapsed()
            return
        }
        if state.isPresented {
            let cameraWidth = connectionHeight > 0 ? hotWidth : 0
            // Keep the expanded panel centered on the real camera, even for nonzero screen origins.
            let availableWidth = max(1, 2 * min(anchor.x - screen.frame.minX - 12,
                                                screen.frame.maxX - anchor.x - 12))
            let width = min(max(preferredWidth, cameraWidth + 2 * NotchHeaderLayout.wingWidth), availableWidth)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            let measured = (quote.text as NSString).boundingRect(
                with: NSSize(width: max(1, width - 40), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: style])
            let sourceSize = max(11, fontSize - 5)
            let sourceFont = NSFont.systemFont(ofSize: sourceSize)
            let sourceHeight = ceil(sourceFont.ascender - sourceFont.descender + sourceFont.leading)
            let footer: CGFloat = (quote.source?.isEmpty == false) ? 52 + sourceHeight : 40
            let textHeight = min(max(24, ceil(measured.height) + 4), maxTextHeight,
                                 max(24, screen.visibleFrame.height - footer - headerHeight - 24))
            contentSize = NSSize(width: width, height: textHeight + footer)
            let height = contentSize.height + headerHeight
            let frame = NSRect(x: max(screen.frame.minX + 12,
                                     min(anchor.x - width / 2, screen.frame.maxX - width - 12)),
                               y: anchor.y + connectionHeight - height, width: width, height: height)
            if hosting == nil || renderedQuote != quote || renderedTextHeight != textHeight || renderedFontSize != fontSize || renderedWidth != width {
                let card = QuoteCard(quote: quote, textHeight: textHeight, fontSize: fontSize, sourceSize: sourceSize)
                if let hosting { hosting.rootView = card }
                else {
                    let host = NSHostingView(rootView: card)
                    // Fixed content size avoids reflow and font scaling as the panel grows.
                    host.autoresizingMask = []
                    host.alphaValue = 0
                    container.addSubview(host)
                    hosting = host
                }
                renderedQuote = quote
                renderedTextHeight = textHeight
                renderedFontSize = fontSize
                renderedWidth = width
            }
            if headerStatus == nil {
                let status = NSHostingView(rootView: RecallHeaderStatus())
                let actions = NSHostingView(rootView: RecallHeaderActions(
                    next: { [weak self] in self?.onNext?() },
                    collapse: { [weak self] in self?.collapse() },
                    openSettings: { [weak self] in self?.openSettings() }))
                for host in [status as NSView, actions as NSView] {
                    host.autoresizingMask = []
                    host.alphaValue = 0
                    container.addSubview(host)
                }
                headerStatus = status
                headerActions = actions
            }
            if !container.showsSurface {
                applyFrame(compactFrame)
                container.bottomRadius = 10
            }
            let wasExpanded = container.showsSurface
            container.showsIndicator = false
            container.showsSurface = true
            panel.ignoresMouseEvents = false
            // Cover menu bar items inside the card, while leaving system menus above it.
            // Do not continually reorder against another notch application.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            if !wasExpanded || !panel.isVisible { panel.orderFrontRegardless() }
            transitionTo(frame, expanded: true, animated: animated)
        } else if container.showsSurface {
            // The shrinking surface is visual only; it must not intercept clicks.
            panel.ignoresMouseEvents = true
            transitionTo(compactFrame, expanded: false, animated: animated)
        } else {
            cancelMotion()
            finishCollapsed()
        }
        reconcilePointer()
        scheduleTimer()
    }

    private func transitionTo(_ frame: NSRect, expanded: Bool, animated: Bool) {
        if animated, !reduceMotion(), let transition, transition.to == frame, transition.expanded == expanded {
            layoutContent()
            return
        }
        cancelMotion()
        guard animated, !reduceMotion(), panel.frame != frame else {
            applyFrame(frame)
            setContentOpacity(expanded ? 1 : 0)
            container.bottomRadius = expanded ? 22 : 10
            if !expanded { finishCollapsed() }
            return
        }
        let value = PanelTransition(from: panel.frame, to: frame,
            fromOpacity: hosting?.alphaValue ?? 0, fromRadius: container.bottomRadius,
            expanded: expanded, start: ProcessInfo.processInfo.systemUptime,
            duration: expanded ? 0.30 : 0.24)
        transition = value
        layoutContent()
        let token = motionGeneration
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.motionGeneration == token, let motion = self.transition else { return }
                self.advanceMotion(to: (ProcessInfo.processInfo.systemUptime - motion.start) / motion.duration)
            }
        }
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceMotion(to progress: Double) {
        guard let motion = transition else { return }
        let values = motion.values(at: progress)
        applyFrame(values.frame)
        setContentOpacity(values.opacity)
        container.bottomRadius = values.radius
        if progress >= 1 {
            cancelMotion()
            if !motion.expanded { finishCollapsed() }
            reconcilePointer()
            cancelTimer()
            scheduleTimer()
        }
    }

    private func applyFrame(_ frame: NSRect) {
        panel.setFrame(frame, display: true)
        layoutContent()
        container.needsDisplay = true
    }

    private func layoutContent() {
        // Content's top edge stays below the physical camera area throughout motion.
        hosting?.frame = NSRect(x: (container.bounds.width - contentSize.width) / 2,
                               y: container.bounds.height - headerHeight - contentSize.height,
                               width: contentSize.width, height: contentSize.height)
        let layout = NotchHeaderLayout(size: NSSize(width: contentSize.width, height: headerHeight),
                                       cameraWidth: connectionHeight > 0 ? hotWidth : 0)
        let offsetX = (container.bounds.width - contentSize.width) / 2
        let offsetY = container.bounds.height - headerHeight
        let left = layout.left.offsetBy(dx: offsetX, dy: offsetY)
        let right = layout.right.offsetBy(dx: offsetX, dy: offsetY)
        headerStatus?.frame = left
        headerActions?.frame = right
        // During expansion, reveal controls only once their full hit areas fit.
        // They never slide across or receive clicks inside the physical camera gap.
        let fits = layout.fits && container.bounds.contains(left) && container.bounds.contains(right)
        headerStatus?.isHidden = !fits
        headerActions?.isHidden = !fits
    }

    private func setContentOpacity(_ opacity: CGFloat) {
        hosting?.alphaValue = opacity
        // Fade in across the final 24 pt of expansion instead of popping in
        // when the fixed-size hit targets first fit inside the surface.
        let reveal = min(1, max(0, (container.bounds.width - contentSize.width + 24) / 24))
        headerStatus?.alphaValue = opacity * reveal
        headerActions?.alphaValue = opacity * reveal
    }

    private func cancelMotion() {
        motionGeneration += 1
        motionTimer?.invalidate()
        motionTimer = nil
        transition = nil
    }

    private func finishCollapsed() {
        previewQuote = nil
        hosting?.removeFromSuperview()
        hosting = nil
        headerStatus?.removeFromSuperview()
        headerActions?.removeFromSuperview()
        headerStatus = nil
        headerActions = nil
        renderedQuote = nil
        container.showsSurface = false
        container.showsIndicator = active && showIndicator && currentScreen != nil
        container.hasContent = quote != nil
        container.toolTip = container.showsIndicator ? (quote == nil ? "回见 · 暂无内容" : "回见正在运行") : nil
        panel.level = container.showsIndicator && connectionHeight > 0
            ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) : .floating
        let symbol = geometry.symbolFrame
        container.indicatorSymbolFrame = symbol.offsetBy(dx: -hotFrame.minX, dy: -hotFrame.minY)
        panel.setFrame(hotFrame, display: true)
        panel.ignoresMouseEvents = !hoverEnabled || quote == nil
        if active, currentScreen != nil, (showIndicator || (quote != nil && hoverEnabled)) {
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        else { panel.orderOut(nil) }
    }

    private func reconcilePointer() {
        // Keep the thin entry strip continuous with a surface that is still growing.
        let interactionFrame = state.isPresented ? panel.frame.union(hotFrame) : hotFrame
        state.pointerChanged(inside: interactionFrame.contains(NSEvent.mouseLocation),
            now: ProcessInfo.processInfo.systemUptime, hoverEnabled: hoverEnabled)
    }

    private func updatePointer() {
        guard active, quote != nil else { return }
        reconcilePointer()
        cancelTimer()
        scheduleTimer()
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
        generation += 1
    }

    private func scheduleTimer() {
        guard let deadline = state.nextDeadline else { return }
        let token = generation
        let timer = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.state.advance(to: ProcessInfo.processInfo.systemUptime)
                self.render()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func openSettings() {
        collapse()
        onOpenSettings?()
    }

    func shutdown() { cancelTimer(); cancelMotion(); panel.orderOut(nil) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var stableID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return "display-\(displayID)"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
