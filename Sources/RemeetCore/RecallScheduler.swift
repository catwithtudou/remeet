import Foundation

public enum RecallSchedule {
    public static func next(after date: Date, frequency: RecallFrequency, calendar: Calendar,
                            customMinutes: Int = RecallSettings().customIntervalMinutes, anchor: Date? = nil) -> Date {
        if frequency == .custom {
            let minutes = RecallSettings.customIntervalRange.contains(customMinutes) ? customMinutes : RecallSettings().customIntervalMinutes
            let interval = Double(minutes) * 60
            let start = min(anchor ?? date, date)
            let steps = floor(date.timeIntervalSince(start) / interval) + 1
            return start.addingTimeInterval(steps * interval)
        }
        // Search wall-clock slots, including BOTH absolute occurrences of repeated DST times.
        // This runs once per reschedule, not as a polling loop.
        var result = Date.distantFuture
        for minuteOfDay in stride(from: 0, to: 24 * 60, by: frequency.rawValue) {
            let match = DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0)
            for repetition in [Calendar.RepeatedTimePolicy.first, .last] {
                if let candidate = calendar.nextDate(after: date, matching: match,
                    matchingPolicy: .strict, repeatedTimePolicy: repetition), candidate > date {
                    result = min(result, candidate)
                }
            }
        }
        return result
    }
}

@MainActor
public protocol RecallCancellation: AnyObject { func cancel() }

@MainActor
private final class FoundationTimerCancellation: RecallCancellation {
    let timer: Timer
    init(_ timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
}

@MainActor
public final class RecallScheduler {
    public enum Event: Equatable { case scheduled, recovered }
    public typealias ArmTimer = (Date, @escaping @MainActor () -> Void) -> any RecallCancellation
    public private(set) var nextDate: Date? { didSet { onNextDate(nextDate) } }
    private let onNextDate: (Date?) -> Void
    private var customMinutes: Int
    private var intervalAnchor: Date?
    private var frequency: RecallFrequency
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let armTimer: ArmTimer
    private let onEvent: (Event) -> Void
    private var cancellation: (any RecallCancellation)?
    private var generation = 0
    private var suspended = false
    private var lastHandled: Date?

    public init(frequency: RecallFrequency, customMinutes: Int = RecallSettings().customIntervalMinutes, now: @escaping () -> Date = Date.init,
                calendar: @escaping () -> Calendar = { .autoupdatingCurrent },
                armTimer: ArmTimer? = nil, onNextDate: @escaping (Date?) -> Void = { _ in }, onEvent: @escaping (Event) -> Void) {
        self.frequency = frequency
        self.customMinutes = customMinutes
        self.onNextDate = onNextDate
        self.now = now
        self.calendar = calendar
        self.armTimer = armTimer ?? Self.systemTimer
        self.onEvent = onEvent
    }

    public func start() { scheduleNext() }

    public func changeFrequency(_ frequency: RecallFrequency, customMinutes: Int = RecallSettings().customIntervalMinutes) {
        self.frequency = frequency
        self.customMinutes = customMinutes
        intervalAnchor = now()
        scheduleNext()
    }

    public func suspend() {
        suspended = true
        cancelTimer()
    }

    public func resumeOrRealign() {
        suspended = false
        recoverIfMissed()
        scheduleNext()
    }

    public func stop() { suspended = true; cancelTimer(); nextDate = nil }

    private func recoverIfMissed() {
        let current = now()
        if let due = nextDate, current >= due, (frequency == .custom || (lastHandled.map({ due > $0 }) ?? true)) {
            lastHandled = current
            onEvent(.recovered)
        }
    }

    private func scheduleNext() {
        cancelTimer()
        let current = now()
        if intervalAnchor.map({ current < $0 }) ?? true { intervalAnchor = current }
        let due = RecallSchedule.next(after: current, frequency: frequency, calendar: calendar(),
                                      customMinutes: customMinutes, anchor: intervalAnchor)
        nextDate = due
        guard !suspended else { return }
        arm(due)
    }

    private func arm(_ due: Date) {
        let token = generation
        cancellation = armTimer(due) { [weak self] in
            guard let self, self.generation == token, !self.suspended else { return }
            self.cancelTimer()
            let current = self.now()
            if current < due { self.arm(due); return }
            if self.frequency == .custom || (self.lastHandled.map({ due > $0 }) ?? true) {
                // A delayed callback after sleep must never become a catch-up popup.
                let timely = current.timeIntervalSince(due) <= 5
                self.lastHandled = timely ? due : current
                self.onEvent(timely ? .scheduled : .recovered)
            }
            self.scheduleNext()
        }
    }

    private func cancelTimer() {
        generation += 1
        cancellation?.cancel()
        cancellation = nil
    }

    private static func systemTimer(at date: Date, action: @escaping @MainActor () -> Void) -> any RecallCancellation {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        return FoundationTimerCancellation(timer)
    }
}

public struct ActivityGate: Sendable {
    public enum Reason: Hashable, Sendable { case systemSleep, screenSleep, inactiveSession, locked }
    private var reasons: Set<Reason> = []
    public var isActive: Bool { reasons.isEmpty }
    public init() {}
    public mutating func set(_ reason: Reason, inactive: Bool) {
        if inactive { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}
