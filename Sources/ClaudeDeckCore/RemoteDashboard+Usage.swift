import Foundation

// The Mac's side of RemoteDashboard: UsageProjection isn't part of the phone's build.

extension RemoteDashboard.Window {
    /// From the current reading and the recorded samples. The pace and the limit are rounded
    /// (0.1 %/h, the minute) so the same pace gives the same value on the next build.
    public static func make(_ current: UsageWindow, length: TimeInterval, samples: [(at: Date, percent: Double)], now: Date,
                            recent: TimeInterval = 90 * 60, minimumSpan: TimeInterval = 15 * 60) -> Self {
        let projection = UsageProjection.project(current: current, length: length, samples: samples, now: now,
                                                 recent: recent, minimumSpan: minimumSpan)
        let limit = projection?.limitAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) }
        let rate = projection.map { ($0.ratePerHour * 10).rounded() / 10 }
        return Self(usedPercent: (current.usedPercent * 10).rounded() / 10, resetsAt: current.resetsAt, limitAt: limit, ratePerHour: rate)
    }
}
