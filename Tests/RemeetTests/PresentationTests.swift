import Testing
@testable import RemeetCore

@Test func quickPassAcrossHotZoneDoesNotOpen() {
    var state = PresentationState()
    state.pointerChanged(inside: true, now: 0, hoverEnabled: true)
    state.pointerChanged(inside: false, now: 0.1, hoverEnabled: true)
    state.advance(to: 1)
    #expect(!state.isPresented)
    #expect(state.nextDeadline == nil)
}

@Test func hoverBridgeDoesNotFlickerAndClosesAfterExit() {
    var state = PresentationState()
    state.pointerChanged(inside: true, now: 0, hoverEnabled: true)
    state.advance(to: 0.2)
    #expect(state.isPresented)
    state.pointerChanged(inside: false, now: 1, hoverEnabled: true)
    state.pointerChanged(inside: true, now: 1.1, hoverEnabled: true)
    state.advance(to: 1.5)
    #expect(state.isPresented)
    state.pointerChanged(inside: false, now: 2, hoverEnabled: true)
    state.advance(to: 2.31)
    #expect(!state.isPresented)
}

@Test func timedReadingHonorsHoverAndReset() {
    var state = PresentationState()
    state.present(now: 0, duration: 10)
    state.pointerChanged(inside: true, now: 5, hoverEnabled: true)
    state.advance(to: 15)
    #expect(state.isPresented)
    state.present(now: 15, duration: 10)
    state.pointerChanged(inside: false, now: 16, hoverEnabled: true)
    state.advance(to: 20)
    #expect(state.isPresented)
    state.advance(to: 25)
    #expect(!state.isPresented)
}

@Test func manualCollapseSuppressesReentryUntilPointerLeaves() {
    var state = PresentationState()
    state.pointerChanged(inside: true, now: 0, hoverEnabled: true)
    state.present(now: 0, duration: 10)
    state.collapse()
    state.advance(to: 100)
    #expect(!state.isPresented)
    #expect(state.suppressedUntilExit)
    state.pointerChanged(inside: false, now: 101, hoverEnabled: true)
    state.pointerChanged(inside: true, now: 102, hoverEnabled: true)
    state.advance(to: 102.2)
    #expect(state.isPresented)
}

@Test func disablingHoverCancelsPendingOpenButDoesNotBlockManualOpen() {
    var state = PresentationState()
    state.pointerChanged(inside: true, now: 0, hoverEnabled: true)
    state.cancelPendingHover()
    state.advance(to: 1)
    #expect(!state.isPresented)
    state.present(now: 1, duration: 5)
    #expect(state.isPresented)
}

@Test func collapseCancelsOldDeadlineAndNewPresentationSurvives() {
    var state = PresentationState()
    state.present(now: 0, duration: 10)
    state.collapse()
    #expect(state.nextDeadline == nil)
    state.present(now: 9, duration: 10)
    state.advance(to: 10)
    #expect(state.isPresented)
    state.advance(to: 19)
    #expect(!state.isPresented)
}

@Test func overlappingSleepAndLockReasonsRequireAllToRecover() {
    var gate = ActivityGate()
    gate.set(.systemSleep, inactive: true)
    gate.set(.screenSleep, inactive: true)
    gate.set(.locked, inactive: true)
    gate.set(.systemSleep, inactive: false)
    gate.set(.screenSleep, inactive: false)
    #expect(!gate.isActive)
    gate.set(.locked, inactive: false)
    #expect(gate.isActive)
}

@Test func resumeDoesNotOpenUnderStationaryPointer() {
    var state = PresentationState()
    state.suppressStationaryHover(inside: true)
    state.pointerChanged(inside: true, now: 1, hoverEnabled: true)
    state.advance(to: 2)
    #expect(!state.isPresented)
    state.pointerChanged(inside: false, now: 3, hoverEnabled: true)
    state.pointerChanged(inside: true, now: 4, hoverEnabled: true)
    state.advance(to: 4.2)
    #expect(state.isPresented)
}
