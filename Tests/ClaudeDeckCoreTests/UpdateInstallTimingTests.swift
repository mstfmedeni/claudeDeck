import ClaudeDeckCore
import Testing

@Suite struct UpdateInstallTimingTests {
    private func state(outside: Int = 0, helperBusy: Bool = false, pending: Bool = false,
                       idle: Double = 600, inactive: Double = 600) -> UpdateInstallTiming.State {
        .init(sessionsOutsideHelper: outside, helperBusy: helperBusy, pendingUserInput: pending,
              systemIdle: idle, inactiveFor: inactive)
    }

    @Test func installsWhenEverythingIsKeptAndNobodyIsThere() {
        #expect(UpdateInstallTiming.decide(state()) == .install)
    }

    @Test func waitsForSessionsTheRelaunchWouldEnd() {
        #expect(UpdateInstallTiming.decide(state(outside: 1)) == .wait(.sessionsOutsideHelper))
    }

    @Test func waitsForHelperAndUnansweredInput() {
        #expect(UpdateInstallTiming.decide(state(helperBusy: true)) == .wait(.helperBusy))
        #expect(UpdateInstallTiming.decide(state(pending: true)) == .wait(.pendingUserInput))
    }

    @Test func waitsWhileTheOwnerUsesClaudeDeck() {
        #expect(UpdateInstallTiming.decide(state(idle: 5, inactive: 0)) == .wait(.ownerActive))
    }

    @Test func ownerBusyInAnotherAppForAWhileIsFine() {
        #expect(UpdateInstallTiming.decide(state(idle: 5, inactive: 400)) == .install)
    }

    @Test func idleMacWithClaudeDeckInFrontIsFine() {
        #expect(UpdateInstallTiming.decide(state(idle: 200, inactive: 0)) == .install)
    }
}
