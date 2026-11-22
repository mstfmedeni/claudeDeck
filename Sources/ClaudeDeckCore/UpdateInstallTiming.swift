import Foundation

/// When a downloaded update installs by itself (Settings › General › "Install updates
/// automatically"). Relaunching only detaches from the session helper, so sessions it keeps
/// carry on; the update waits while anything would be lost or interrupted.
public enum UpdateInstallTiming {
    public struct State: Sendable, Equatable {
        /// Running sessions the relaunch would end (not kept in the session helper).
        public var sessionsOutsideHelper: Int
        /// The helper is being restarted or upgraded right now.
        public var helperBusy: Bool
        /// An editor window with unsaved changes, or a sheet/alert waiting for an answer.
        public var pendingUserInput: Bool
        /// Seconds since the last keyboard/mouse input anywhere on the Mac.
        public var systemIdle: TimeInterval
        /// Seconds since ClaudeDeck was last the frontmost app (0 while it is).
        public var inactiveFor: TimeInterval

        public init(sessionsOutsideHelper: Int, helperBusy: Bool, pendingUserInput: Bool,
                    systemIdle: TimeInterval, inactiveFor: TimeInterval) {
            self.sessionsOutsideHelper = sessionsOutsideHelper
            self.helperBusy = helperBusy
            self.pendingUserInput = pendingUserInput
            self.systemIdle = systemIdle
            self.inactiveFor = inactiveFor
        }
    }

    public enum Decision: Sendable, Equatable {
        case install
        case wait(Reason)
    }

    public enum Reason: Sendable, Equatable {
        case sessionsOutsideHelper
        case helperBusy
        case pendingUserInput
        case ownerActive
    }

    /// Nobody touched the Mac for this long…
    public static let idleNeeded: TimeInterval = 120
    /// …or ClaudeDeck has been in the background this long.
    public static let inactiveNeeded: TimeInterval = 5 * 60

    public static func decide(_ s: State) -> Decision {
        if s.sessionsOutsideHelper > 0 { return .wait(.sessionsOutsideHelper) }
        if s.helperBusy { return .wait(.helperBusy) }
        if s.pendingUserInput { return .wait(.pendingUserInput) }
        if s.systemIdle < idleNeeded && s.inactiveFor < inactiveNeeded { return .wait(.ownerActive) }
        return .install
    }
}
