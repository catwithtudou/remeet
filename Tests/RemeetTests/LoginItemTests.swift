import ServiceManagement
import Testing
@testable import Remeet

@Suite @MainActor
struct LoginItemTests {
    @Test func registrationUsesSystemReadbackAndDoesNotRegisterOnInitialization() {
        var status = SMAppService.Status.notRegistered
        var requests: [Bool] = []
        let controller = LoginItemController(readStatus: { status }, updateRegistration: { enabled in
            requests.append(enabled)
            status = enabled ? .enabled : .notRegistered
        })
        #expect(!controller.isEnabled && requests.isEmpty)
        controller.setEnabled(true)
        #expect(controller.isEnabled && requests == [true])
        controller.setEnabled(true)
        #expect(requests == [true])
        controller.setEnabled(false)
        #expect(!controller.isEnabled && requests == [true, false])
        controller.setEnabled(false)
        #expect(requests == [true, false])
    }

    @Test func pendingApprovalAndExternalRevocationNeverClaimEnabledOrReregister() {
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        let controller = LoginItemController(readStatus: { status }, updateRegistration: { _ in
            registrations += 1
            status = .requiresApproval
        })
        controller.setEnabled(true)
        #expect(!controller.isEnabled && controller.status == .requiresApproval)
        controller.setEnabled(true)
        #expect(registrations == 1)
        status = .enabled
        controller.refresh()
        #expect(controller.isEnabled)
        status = .requiresApproval
        controller.setEnabled(true) // Refresh before acting on an old settings-window snapshot.
        #expect(!controller.isEnabled && registrations == 1)
        status = .notRegistered
        controller.refresh()
        #expect(!controller.isEnabled && controller.status == .notRegistered)
    }

    @Test(arguments: [false, true])
    func failurePreservesSystemStateAndCanBeRetried(enabling: Bool) {
        enum Failure: Error { case unavailable }
        var status: SMAppService.Status = enabling ? .notRegistered : .enabled
        var fail = true
        let controller = LoginItemController(readStatus: { status }, updateRegistration: { enabled in
            if fail { throw Failure.unavailable }
            status = enabled ? .enabled : .notRegistered
        })
        controller.setEnabled(enabling)
        #expect(controller.isEnabled == !enabling)
        #expect(controller.errorMessage != nil)
        fail = false
        controller.setEnabled(enabling)
        #expect(controller.isEnabled == enabling && controller.errorMessage == nil)
    }

    @Test func successfulCallWithoutEnabledReadbackDoesNotClaimSuccess() {
        let controller = LoginItemController(readStatus: { .notFound }, updateRegistration: { _ in })
        controller.setEnabled(true)
        #expect(!controller.isEnabled && controller.status == .notFound)
    }
}
