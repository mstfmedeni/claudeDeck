import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct UIVisibilityTests {
    @Test func visibleByDefault() {
        let v = UIVisibility()
        #expect(v.screenVisible)
        #expect(v.windowsVisible)
        #expect(!v.needsSharingCheck)
    }

    @Test func windowsNeedAWindowOnScreenAndTheAppShown() {
        var v = UIVisibility()
        v.windowOnScreen = false
        #expect(!v.windowsVisible)
        #expect(v.screenVisible) // the menu bar is still in view
        v.windowOnScreen = true
        v.appHidden = true
        #expect(!v.windowsVisible)
        #expect(v.screenVisible)
    }

    @Test func nothingIsVisibleWithTheScreenOffLockedOrSwitchedAway() {
        for change: (inout UIVisibility) -> Void in [
            { $0.displaysAsleep = true },
            { $0.hasScreens = false },
            { $0.screenLocked = true },
            { $0.sessionActive = false },
        ] {
            var v = UIVisibility()
            change(&v)
            #expect(!v.screenVisible)
            #expect(!v.windowsVisible) // even with a window "on screen"
            #expect(v.needsSharingCheck)
        }
    }

    @Test func screenSharingCountsAsVisible() {
        // Monitor cut off by its smart plug, window covered: a remote viewer still sees the Mac.
        var v = UIVisibility()
        v.hasScreens = false
        v.displaysAsleep = true
        v.windowOnScreen = false
        v.screenSharing = true
        #expect(v.screenVisible)
        #expect(v.windowsVisible)
        // Keeps checking, so the end of the session pauses again.
        #expect(v.needsSharingCheck)
    }

    @Test func sharingIsOnlyCheckedWhileOtherwisePaused() {
        var v = UIVisibility()
        v.screenSharing = true
        #expect(!v.needsSharingCheck)
        v.appHidden = true
        #expect(v.needsSharingCheck)
    }

    @Test func sharingDaemonName() {
        #expect(ScreenSharingDetector.isSharingProcess("screensharingd"))
        #expect(!ScreenSharingDetector.isSharingProcess("ScreenSharingSubscriber"))
        #expect(!ScreenSharingDetector.isSharingProcess("ARDAgent"))
    }

    @Test func processListIncludesThisProcess() {
        let names = ScreenSharingDetector.processNames()
        #expect(names.count > 1)
        let me = String(ProcessInfo.processInfo.processName.prefix(16))
        #expect(names.contains(me))
    }
}
