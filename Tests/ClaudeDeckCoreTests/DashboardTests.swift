import Foundation
import Testing
@testable import ClaudeDeckCore

@Suite struct ActivityLedgerTests {
    let t0 = Date(timeIntervalSince1970: 1_789_999_200) // on the hour
    let a = UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!
    let project = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!

    @Test func recordsOnlyTransitions() {
        var ledger = ActivityLedger()
        let r1 = ledger.record(session: a, project: project, activity: .off, at: t0)
        #expect(!r1) // never seen: nothing to draw
        let r2 = ledger.record(session: a, project: project, activity: .running, at: t0)
        #expect(r2)
        let r3 = ledger.record(session: a, project: project, activity: .running, detail: "Bash: ls", at: t0 + 10)
        #expect(!r3)
        let r4 = ledger.record(session: a, project: project, activity: .idle, at: t0 + 20)
        #expect(r4)
        #expect(ledger.events.count == 2)
        #expect(ledger.current(a)?.activity == .idle)
    }

    @Test func segmentsAreClippedToTheWindowAndLastUntilNow() {
        var ledger = ActivityLedger()
        ledger.record(session: a, project: project, activity: .running, at: t0)
        ledger.record(session: b, project: project, activity: .permission, at: t0 + 300)
        ledger.record(session: a, project: project, activity: .idle, at: t0 + 600)
        ledger.record(session: a, project: project, activity: .off, at: t0 + 900)
        let window = DateInterval(start: t0 + 100, end: t0 + 1200)
        let segments = ledger.segments(in: window, now: t0 + 1200)
        #expect(segments.count == 3)
        #expect(segments[0] == LedgerSegment(session: a, project: project, activity: .running, detail: nil, start: t0 + 100, end: t0 + 600))
        #expect(segments[1].session == b && segments[1].start == t0 + 300 && segments[1].end == t0 + 1200)
        #expect(segments[2].activity == .idle && segments[2].end == t0 + 900) // off isn't drawn
    }

    @Test func responseTimesCountAnsweredPromptsOnly() {
        var ledger = ActivityLedger()
        ledger.record(session: a, project: project, activity: .running, at: t0)
        ledger.record(session: a, project: project, activity: .permission, at: t0 + 100)
        ledger.record(session: a, project: project, activity: .running, at: t0 + 145) // answered after 45 s
        ledger.record(session: b, project: project, activity: .question, at: t0 + 200)
        ledger.record(session: b, project: project, activity: .off, at: t0 + 400) // closed, not answered
        ledger.record(session: a, project: project, activity: .question, at: t0 + 500)
        ledger.record(session: a, project: project, activity: .idle, at: t0 + 530)
        let responses = ledger.responses(since: t0)
        #expect(responses.map(\.waited) == [45, 30])
        #expect(responses.map(\.activity) == [.permission, .question])
        #expect(ledger.responses(since: t0 + 200).count == 1)
    }

    @Test func workingSecondsAreSplitAcrossHours() {
        var ledger = ActivityLedger()
        ledger.record(session: a, project: project, activity: .running, at: t0 + 3000) // 10 min before the next hour
        ledger.record(session: b, project: project, activity: .running, at: t0 + 3300)
        ledger.record(session: b, project: project, activity: .idle, at: t0 + 3700)
        ledger.record(session: a, project: project, activity: .idle, at: t0 + 3900) // 5 min into it
        let hours = ledger.workingSeconds(byHourSince: t0, now: t0 + 7200)[project] ?? [:]
        #expect(hours[t0] == TimeInterval(600 + 300))
        #expect(hours[t0 + 3600] == TimeInterval(300 + 100))
    }

    @Test func closeAllEndsOpenSessions() {
        var ledger = ActivityLedger()
        ledger.record(session: a, project: project, activity: .running, at: t0)
        ledger.record(session: b, project: project, activity: .idle, at: t0)
        ledger.closeAll(at: t0 + 60)
        #expect(ledger.current(a)?.activity == .off)
        #expect(ledger.current(b)?.activity == .off)
        #expect(ledger.segments(in: DateInterval(start: t0, end: t0 + 3600), now: t0 + 3600).allSatisfy { $0.end == t0 + 60 })
    }

    @Test func pruneKeepsTheStateAtTheCutoff() {
        var ledger = ActivityLedger()
        let old = t0 - ActivityLedger.keep - 600
        ledger.record(session: a, project: project, activity: .running, at: old)
        ledger.record(session: b, project: project, activity: .idle, at: old)
        ledger.record(session: b, project: project, activity: .off, at: old + 60)
        ledger.record(usage: UsageSample(at: old, fiveHour: 10, sevenDay: 5))
        ledger.record(session: a, project: project, activity: .idle, at: t0 - 60)
        ledger.prune(now: t0)
        #expect(ledger.events.count == 2) // a carried over as running at the cut-off, then idle; b gone
        #expect(ledger.events[0].activity == .running && ledger.events[0].at == t0 - ActivityLedger.keep)
        #expect(ledger.usage.isEmpty)
        #expect(ledger.current(b) == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        var ledger = ActivityLedger()
        ledger.record(session: a, project: project, activity: .running, detail: "Edit: Views.swift", at: t0)
        ledger.record(usage: UsageSample(at: t0, fiveHour: 40, fiveHourResetsAt: t0 + 3600, sevenDay: 12))
        ledger.savedAt = t0
        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(ActivityLedger.self, from: data)
        #expect(decoded == ledger)
        #expect(decoded.current(a)?.detail == "Edit: Views.swift")
    }
}

@Suite struct UsageProjectionTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func usesTheRecentSlope() throws {
        // 30 % an hour over the last hour: 60 → 90 % in 2 more hours... 70 % now → 100 % in 1 h.
        let samples = stride(from: 0, through: 4, by: 1).map { i in
            (at: now.addingTimeInterval(Double(i - 4) * 15 * 60), percent: 40 + Double(i) * 7.5)
        }
        let window = UsageWindow(usedPercent: 70, resetsAt: now.addingTimeInterval(2 * 3600))
        let p = try #require(UsageProjection.project(current: window, length: 5 * 3600, samples: samples, now: now))
        #expect(p.fromRecentSamples)
        #expect(abs(p.ratePerHour - 30) < 0.01)
        #expect(abs(p.limitAt!.timeIntervalSince(now) - 3600) < 1)
        #expect(p.hitsLimitBeforeReset)
    }

    @Test func fallsBackToTheWindowsAveragePace() throws {
        // 2 h into a 5 h window at 20 %: 10 %/h, 100 % in 8 h — after the reset in 3 h.
        let window = UsageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(3 * 3600))
        let p = try #require(UsageProjection.project(current: window, length: 5 * 3600, samples: [], now: now))
        #expect(!p.fromRecentSamples)
        #expect(abs(p.ratePerHour - 10) < 0.001)
        #expect(abs(p.limitAt!.timeIntervalSince(now) - 8 * 3600) < 1)
        #expect(!p.hitsLimitBeforeReset)
    }

    @Test func ignoresReadingsFromBeforeAReset() throws {
        // High readings from the previous window, then a drop: only the new window's count.
        let samples: [(at: Date, percent: Double)] = [
            (now.addingTimeInterval(-80 * 60), 95), (now.addingTimeInterval(-70 * 60), 98),
            (now.addingTimeInterval(-40 * 60), 2), (now.addingTimeInterval(-20 * 60), 6), (now, 10),
        ]
        let window = UsageWindow(usedPercent: 10, resetsAt: now.addingTimeInterval(4 * 3600 + 20 * 60))
        let p = try #require(UsageProjection.project(current: window, length: 5 * 3600, samples: samples, now: now))
        #expect(p.fromRecentSamples)
        #expect(abs(p.ratePerHour - 12) < 0.01)
    }

    @Test func flatUsageNeverHitsTheLimit() throws {
        let samples = (0..<4).map { (at: now.addingTimeInterval(Double($0 - 3) * 600), percent: 50.0) }
        let window = UsageWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(3600))
        let p = try #require(UsageProjection.project(current: window, length: 5 * 3600, samples: samples, now: now))
        #expect(p.limitAt == nil)
        #expect(!p.hitsLimitBeforeReset)
    }

    @Test func exhaustedIsNow() throws {
        let p = try #require(UsageProjection.project(current: UsageWindow(usedPercent: 100, resetsAt: nil), length: 5 * 3600, samples: [], now: now))
        #expect(p.limitAt == now)
    }
}

@Suite struct TranscriptPulseTests {
    let since = Date(timeIntervalSince1970: 0)
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let lines = #"""
    {"type":"user","timestamp":"2026-11-18T09:05:00.000Z","message":{"role":"user","content":"Fix the cart total"}}
    {"type":"user","timestamp":"2026-11-18T09:05:01.000Z","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}
    {"type":"assistant","timestamp":"2026-11-18T09:05:10.000Z","message":{"id":"m1","content":[{"type":"text","text":"Looking."}],"usage":{"output_tokens":120}}}
    {"type":"assistant","timestamp":"2026-11-18T09:05:11.000Z","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}],"usage":{"output_tokens":120}}}
    {"type":"assistant","timestamp":"2026-11-18T09:06:00.000Z","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{}}],"usage":{"output_tokens":300}}}
    {"type":"user","timestamp":"2026-11-18T09:06:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]},"toolUseResult":{"type":"update","filePath":"/p/Cart.ts","structuredPatch":[{"lines":[" a","-b","+c","+d"]}]}}
    {"type":"assistant","timestamp":"2026-11-18T10:15:00.000Z","message":{"id":"m3","content":[{"type":"tool_use","id":"t3","name":"Write","input":{}},{"type":"tool_use","id":"t4","name":"mcp__github__create_issue","input":{}}],"usage":{"output_tokens":50}}}
    {"type":"user","timestamp":"2026-11-18T10:15:02.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"ok"}]},"toolUseResult":{"type":"create","filePath":"/p/coupons.ts","content":"one\ntwo\nthree\n","structuredPatch":[]}}
    {"type":"user","timestamp":"2026-11-18T10:16:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"boom","is_error":true}]},"toolUseResult":{"type":"update","filePath":"/p/Cart.ts","structuredPatch":[{"lines":["+x"]}]}}
    {"type":"assistant","timestamp":"2026-11-18T10:17:00.000Z","isSidechain":true,"message":{"id":"s1","content":[{"type":"text","text":"sub"}],"usage":{"output_tokens":999}}}
    """#

    private func hour(_ h: Int) -> Date { utc.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: h))! }

    @Test func countsPerHour() {
        var pulse = TranscriptPulse(since: since, calendar: utc)
        pulse.append(lines + "\n")
        let nine = pulse.digest.hours[hour(9)]
        #expect(nine?.prompts == 1)
        #expect(nine?.replies == 1)
        #expect(nine?.toolCalls == 2)
        #expect(nine?.outputTokens == 420) // m1 counted once
        #expect(nine?.added == 2 && nine?.removed == 1)
        let ten = pulse.digest.hours[hour(10)]
        #expect(ten?.toolCalls == 2)
        #expect(ten?.added == 3) // the created file; the failed edit doesn't count
        #expect(ten?.outputTokens == 50) // the sidechain line is left out
    }

    @Test func tracksToolsAndFilesPerDay() {
        var pulse = TranscriptPulse(since: since, calendar: utc)
        pulse.append(lines)
        let day = utc.startOfDay(for: hour(9))
        #expect(pulse.digest.tools[day] == ["Read": 1, "Edit": 1, "Write": 1, "github: create_issue": 1])
        let files = pulse.digest.files[day] ?? [:]
        #expect(files["/p/Cart.ts"]?.edits == 1)
        #expect(files["/p/Cart.ts"]?.added == 2)
        #expect(files["/p/coupons.ts"]?.added == 3)
    }

    @Test func skipsLinesBeforeSince() {
        var pulse = TranscriptPulse(since: hour(10), calendar: utc)
        pulse.append(lines)
        #expect(pulse.digest.hours[hour(9)] == nil)
        #expect(pulse.digest.hours[hour(10)]?.toolCalls == 2)
    }

    @Test func readsOnlyWhatWasAppended() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pulse-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let all = lines.split(separator: "\n").map(String.init)
        try (all[0...2].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        var pulse = TranscriptPulse(since: since, calendar: utc)
        let ok = pulse.read(url)
        #expect(ok)
        #expect(pulse.digest.hours[hour(9)]?.replies == 1)
        // A half-written line waits for the next read.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((all[3] + "\n" + all[4].prefix(20)).utf8))
        _ = pulse.read(url)
        #expect(pulse.digest.hours[hour(9)]?.toolCalls == 1)
        try handle.write(contentsOf: Data((all[4].dropFirst(20) + "\n").utf8))
        try handle.close()
        _ = pulse.read(url)
        #expect(pulse.digest.hours[hour(9)]?.toolCalls == 2)
        #expect(pulse.digest.hours[hour(9)]?.replies == 1) // nothing counted twice
        // Rewritten shorter: the caller starts over.
        try "".write(to: url, atomically: true, encoding: .utf8)
        let reread = pulse.read(url)
        #expect(!reread)
    }

    @Test func digestsAddUp() {
        var a = TranscriptPulse(since: since, calendar: utc)
        a.append(lines)
        var sum = PulseDigest()
        sum += a.digest
        sum += a.digest
        #expect(sum.hours[hour(9)]?.toolCalls == 4)
        #expect(sum.files[utc.startOfDay(for: hour(9))]?["/p/Cart.ts"]?.edits == 2)
        #expect(sum.total(in: DateInterval(start: hour(9), end: hour(11))).added == 10)
    }

    @Test func heatmapRowsEndToday() {
        let now = hour(10).addingTimeInterval(1800)
        let map = ActivityHeatmap.build(days: 7, now: now, calendar: utc) { start in
            start == hour(9) ? 5 : start == hour(11) ? 9 : 0
        }
        #expect(map.cells.count == 7 * 24)
        #expect(map.cells.first { $0.day == 6 && $0.hour == 9 }?.value == 5)
        #expect(map.cells.first { $0.day == 6 && $0.hour == 11 }?.value == 0) // the future stays empty
        #expect(map.maxValue == 5)
    }
}

@Suite struct DashboardTabTests {
    @Test func dashboardTabIsRestored() throws {
        var list = WorkspaceTabList()
        list.open(.dashboard)
        let data = try JSONEncoder().encode(list.persistable)
        let restored = try JSONDecoder().decode(WorkspaceTabList.self, from: data).restored { _ in true }
        #expect(restored.tabs == [.sessions, .dashboard])
        #expect(restored.selected == .dashboard)
    }
}
