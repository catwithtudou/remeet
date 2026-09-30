/// Monotonic times keep reading deadlines independent of wall-clock adjustments.
public struct PresentationState: Sendable {
    public private(set) var isPresented = false
    public private(set) var pointerInside = false
    public private(set) var suppressedUntilExit = false
    private var readingDeadline: Double?
    private var hoverDeadline: Double?
    private var exitDeadline: Double?

    public init() {}

    public var nextDeadline: Double? {
        if let hoverDeadline { return hoverDeadline }
        guard isPresented, !pointerInside else { return nil }
        return max(readingDeadline ?? 0, exitDeadline ?? 0)
    }

    public mutating func pointerChanged(inside: Bool, now: Double, hoverEnabled: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside {
            exitDeadline = nil
            if !isPresented, !suppressedUntilExit, hoverEnabled {
                hoverDeadline = now + 0.2
            }
        } else {
            suppressedUntilExit = false
            hoverDeadline = nil
            if isPresented { exitDeadline = now + 0.3 }
        }
    }

    public mutating func present(now: Double, duration: Double) {
        isPresented = true
        readingDeadline = now + duration
        hoverDeadline = nil
        exitDeadline = nil
    }

    public mutating func advance(to now: Double) {
        if let hoverDeadline, now >= hoverDeadline {
            self.hoverDeadline = nil
            if pointerInside, !suppressedUntilExit {
                isPresented = true
                readingDeadline = nil
            }
        }
        if isPresented, !pointerInside,
           now >= max(readingDeadline ?? 0, exitDeadline ?? 0) {
            collapse()
        }
    }

    public mutating func cancelPendingHover() { hoverDeadline = nil }

    public mutating func suppressStationaryHover(inside: Bool) {
        pointerInside = inside
        suppressedUntilExit = inside
        hoverDeadline = nil
    }

    public mutating func collapse() {
        isPresented = false
        suppressedUntilExit = pointerInside
        readingDeadline = nil
        hoverDeadline = nil
        exitDeadline = nil
    }
}
