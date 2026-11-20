// claudedeck-ptyd: keeps ClaudeDeck's sessions running while the app is closed (Settings ›
// Sessions › "Keep sessions running when ClaudeDeck quits"). See PtydServer.
//
//   claudedeck-ptyd [--dir <folder>] [--idle-exit <seconds>] [--ring-bytes <n>] [--build <id>]
//
// --dir         folder for ptyd.sock / ptyd.lock (default: the app's data folder)
// --idle-exit   exit after this long without sessions or clients (the app's child mode)
// --resume-fd   internal: the previous image of this process exec'd into this one after an
//               update and left its sessions in this descriptor (PtydHandover)
//
// No signal handlers on purpose: ignored signals would be inherited by the sessions' processes.
import ClaudeDeckCore
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// The path this image was loaded from, before anything else: an update may move the file away
// later, and the updated binary lands at this path (PtydServer's self-update).
let executablePath = Bundle.main.executableURL?.resolvingSymlinksInPath().path
// Likewise its signature's designated requirement: an updated binary must satisfy it.
let ownRequirement = PtydUpgradeCheck.ownDesignatedRequirement()

let paths = value("--dir").map { PtydPaths(directory: URL(fileURLWithPath: $0)) } ?? PtydPaths.default()
// Inside ClaudeDeck.app (Contents/MacOS) the main bundle is the app: its build number.
let build = value("--build") ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev"
var options = PtydServer.Options(paths: paths, build: build)
if let idle = value("--idle-exit").flatMap(Double.init) { options.idleExit = idle }
if let ring = value("--ring-bytes").flatMap(Int.init), ring > 0 { options.ringBytes = ring }
// Tests: pretend to be another protocol version.
if let version = value("--protocol-version").flatMap(Int.init) { options.protocolVersion = version }
if let oldest = value("--oldest-client").flatMap(Int.init) { options.oldestCompatibleClient = oldest }
options.executablePath = executablePath
options.arguments = CommandLine.arguments
options.designatedRequirement = ownRequirement.requirement
if let interval = value("--watch-interval").flatMap(Double.init) { options.watchInterval = interval }
// Tests: exec into the same build (the signature is still checked).
options.allowSameBuildUpgrade = arguments.contains("--upgrade-allow-same-build")

// Under launchd (the app's launch agent) stderr goes nowhere: log next to the socket instead.
if let job = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"], job.hasSuffix(".ptyd") {
    freopen(paths.log.path, "a", stderr)
    chmod(paths.log.path, 0o600)
}
setvbuf(stderr, nil, _IOLBF, 0)
nonisolated(unsafe) let formatter = ISO8601DateFormatter()
@Sendable func log(_ line: String) {
    FileHandle.standardError.write(Data("\(formatter.string(from: Date())) ptyd[\(getpid())] \(line)\n".utf8))
}
let server = PtydServer(options: options, log: log)
if let problem = ownRequirement.problem { log("self-update disabled: \(problem)") }

if let resumeFD = value("--resume-fd").flatMap(Int32.init) {
    // The previous image handed its sessions over. Whatever happens here, this process must not
    // exit: its children's ptys would close and every session would end. If the state can't be
    // taken over, it stays alive without serving (the app sees an unresponsive helper, holds
    // its sessions and offers the restart).
    do {
        let handover = try PtydHandover.read(fd: resumeFD)
        close(resumeFD)
        try server.resume(handover)
    } catch {
        log("resume failed: \(error); staying alive without serving so the sessions keep running")
    }
} else {
    do {
        try server.start()
    } catch PtydServer.StartError.alreadyRunning {
        // Another helper serves this folder: nothing to do (exit 0 so launchd doesn't retry at once).
        log("another helper is running for \(paths.directory.path)")
        exit(0)
    } catch {
        log("\(error)")
        exit(1)
    }
}
dispatchMain()
