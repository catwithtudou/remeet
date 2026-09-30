import Foundation
import Testing
@testable import RemeetCore

private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: zone)!
    return value
}

@Test func wallClockAlignmentAndStrictFuture() {
    let now = date("2026-09-28T09:37:00+08:00")
    for frequency in RecallFrequency.allCases where frequency != .custom {
        #expect(RecallSchedule.next(after: now, frequency: frequency, calendar: calendar())
                == date("2026-09-28T10:00:00+08:00"))
    }
    let boundary = date("2026-09-28T10:00:00+08:00")
    #expect(RecallSchedule.next(after: boundary, frequency: .halfHour, calendar: calendar())
            == date("2026-09-28T10:30:00+08:00"))
    #expect(RecallSchedule.next(after: boundary, frequency: .twoHours, calendar: calendar())
            == date("2026-09-28T12:00:00+08:00"))
    #expect(RecallSchedule.next(after: date("2026-09-28T23:59:59+08:00"), frequency: .hourly, calendar: calendar())
            == date("2026-09-29T00:00:00+08:00"))
}

@Test func daylightSavingSkippedAndRepeatedHours() {
    let zone = calendar("America/Los_Angeles")
    #expect(RecallSchedule.next(after: date("2026-03-08T01:59:00-08:00"), frequency: .hourly, calendar: zone)
            == date("2026-03-08T03:00:00-07:00"))
    #expect(RecallSchedule.next(after: date("2026-03-08T01:59:00-08:00"), frequency: .twoHours, calendar: zone)
            == date("2026-03-08T04:00:00-07:00"))
    #expect(RecallSchedule.next(after: date("2026-11-01T01:00:00-07:00"), frequency: .hourly, calendar: zone)
            == date("2026-11-01T01:00:00-08:00"))
    #expect(RecallSchedule.next(after: date("2026-11-01T01:30:00-07:00"), frequency: .halfHour, calendar: zone)
            == date("2026-11-01T01:00:00-08:00"))
}

@MainActor
private final class FakeTimers {
    final class Job: RecallCancellation {
        let date: Date
        let action: @MainActor () -> Void
        var canceled = false
        init(date: Date, action: @escaping @MainActor () -> Void) { self.date = date; self.action = action }
        func cancel() { canceled = true }
        // Deliberately allows firing a canceled job to exercise generation guards.
        func fire() { action() }
    }
    var now = date("2026-09-28T09:37:00+08:00")
    var zone = calendar()
    var jobs: [Job] = []
    var events: [RecallScheduler.Event] = []
    var activeCount: Int { jobs.filter { !$0.canceled }.count }
    func makeScheduler() -> RecallScheduler {
        RecallScheduler(frequency: .hourly, now: { self.now }, calendar: { self.zone }, armTimer: { due, action in
            let job = Job(date: due, action: action)
            self.jobs.append(job)
            return job
        }, onEvent: { self.events.append($0) })
    }
}

@Test @MainActor func duplicateAndCanceledTimersCannotDeliver() throws {
    let fake = FakeTimers()
    let scheduler = fake.makeScheduler()
    scheduler.start()
    let first = try #require(fake.jobs.last)
    fake.now = first.date
    first.fire()
    first.fire()
    #expect(fake.events == [.scheduled])
    #expect(fake.activeCount == 1)
    let stale = try #require(fake.jobs.last)
    fake.now = date("2026-09-28T10:15:00+08:00")
    scheduler.changeFrequency(.halfHour)
    #expect(scheduler.nextDate == date("2026-09-28T10:30:00+08:00"))
    #expect(fake.activeCount == 1)
    stale.fire()
    #expect(fake.events == [.scheduled])
    scheduler.stop()
    #expect(fake.activeCount == 0)
}

@Test @MainActor func sleepRecoveryCoalescesMissedSlotsSilently() throws {
    let fake = FakeTimers()
    let scheduler = fake.makeScheduler()
    scheduler.start()
    let stale = try #require(fake.jobs.last)
    scheduler.suspend()
    #expect(fake.activeCount == 0)
    fake.now = date("2026-09-28T14:15:00+08:00")
    stale.fire()
    #expect(fake.events.isEmpty)
    scheduler.resumeOrRealign()
    scheduler.resumeOrRealign()
    #expect(fake.events == [.recovered])
    #expect(scheduler.nextDate == date("2026-09-28T15:00:00+08:00"))
    #expect(fake.activeCount == 1)
    scheduler.stop()
}

@Test @MainActor func missedSleepNotificationStillCannotCauseLatePopup() throws {
    let fake = FakeTimers()
    let scheduler = fake.makeScheduler()
    scheduler.start()
    fake.now = date("2026-09-28T13:15:00+08:00")
    try #require(fake.jobs.last).fire()
    #expect(fake.events == [.recovered])
    #expect(scheduler.nextDate == date("2026-09-28T14:00:00+08:00"))
    scheduler.stop()
}

@Test @MainActor func clockRollbackDoesNotDeliverSameAbsoluteSlotTwice() throws {
    let fake = FakeTimers()
    let scheduler = fake.makeScheduler()
    scheduler.start()
    fake.now = date("2026-09-28T10:00:00+08:00")
    try #require(fake.jobs.last).fire()
    fake.now = date("2026-09-28T09:50:00+08:00")
    scheduler.resumeOrRealign()
    scheduler.changeFrequency(.halfHour)
    scheduler.changeFrequency(.hourly)
    fake.now = date("2026-09-28T10:00:00+08:00")
    try #require(fake.jobs.last).fire()
    #expect(fake.events == [.scheduled])
    #expect(scheduler.nextDate == date("2026-09-28T11:00:00+08:00"))
    scheduler.stop()
}

@Test @MainActor func timeZoneChangeRebuildsOneTimerWithoutReminder() {
    let fake = FakeTimers()
    let scheduler = fake.makeScheduler()
    scheduler.start()
    scheduler.changeFrequency(.twoHours)
    fake.zone = calendar("Asia/Kathmandu")
    scheduler.resumeOrRealign()
    #expect(scheduler.nextDate == date("2026-09-28T08:00:00+05:45"))
    #expect(fake.events.isEmpty)
    #expect(fake.activeCount == 1)
    scheduler.stop()
}

@Test @MainActor func customIntervalKeepsItsPhaseAndRecoversWithoutCatchup() throws {
    let fake = FakeTimers()
    let scheduler = fake.makeScheduler()
    scheduler.start()
    let old = try #require(fake.jobs.last)
    scheduler.changeFrequency(.custom, customMinutes: 17)
    #expect(scheduler.nextDate == date("2026-09-28T09:54:00+08:00"))
    old.fire()
    #expect(fake.events.isEmpty)
    fake.now = date("2026-09-28T09:54:02+08:00")
    try #require(fake.jobs.last).fire()
    #expect(fake.events == [.scheduled])
    #expect(scheduler.nextDate == date("2026-09-28T10:11:00+08:00"))
    // Changing zone and waking before the deadline must not restart an interval.
    fake.zone = calendar("America/Los_Angeles")
    scheduler.resumeOrRealign()
    #expect(scheduler.nextDate == date("2026-09-28T10:11:00+08:00"))
    let stale = try #require(fake.jobs.last)
    scheduler.suspend()
    fake.now = date("2026-09-28T11:50:00+08:00")
    scheduler.resumeOrRealign()
    stale.fire()
    scheduler.resumeOrRealign()
    #expect(fake.events == [.scheduled, .recovered])
    #expect(scheduler.nextDate == date("2026-09-28T11:53:00+08:00"))
    #expect(fake.activeCount == 1)
    scheduler.changeFrequency(.custom, customMinutes: 90)
    #expect(scheduler.nextDate == date("2026-09-28T13:20:00+08:00"))
    #expect(fake.events == [.scheduled, .recovered])
    fake.now = date("2026-09-28T09:00:00+08:00")
    scheduler.resumeOrRealign()
    #expect(scheduler.nextDate == date("2026-09-28T10:30:00+08:00"))
    fake.now = try #require(scheduler.nextDate)
    try #require(fake.jobs.last).fire()
    #expect(fake.events == [.scheduled, .recovered, .scheduled])
    scheduler.stop()
    #expect(scheduler.nextDate == nil)
    #expect(fake.activeCount == 0)
}
