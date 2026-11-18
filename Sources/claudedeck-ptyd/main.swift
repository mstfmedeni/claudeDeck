// claudedeck-ptyd: keeps ClaudeDeck's sessions running while the app is closed (Settings ›
// Sessions › "Keep sessions running when ClaudeDeck quits"). See PtydServer.
//
//   claudedeck-ptyd [--dir <folder>] [--idle-exit <seconds>] [--ring-bytes <n>] [--build <id>]
//
// --dir         folder for ptyd.sock / ptyd.lock (default: the app's data folder)
// --idle-exit   exit after this long without sessions or clients (the app's child mode)
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

let paths = value("--dir").map { PtydPaths(directory: URL(fileURLWithPath: $0)) } ?? PtydPaths.default()
// Inside ClaudeDeck.app (Contents/MacOS) the main bundle is the app: its build number.
let build = value("--build") ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev"
var options = PtydServer.Options(paths: paths, build: build)
if let idle = value("--idle-exit").flatMap(Double.init) { options.idleExit = idle }
if let ring = value("--ring-bytes").flatMap(Int.init), ring > 0 { options.ringBytes = ring }
// Tests: pretend to be another protocol version.
if let version = value("--protocol-version").flatMap(Int.init) { options.protocolVersion = version }
if let oldest = value("--oldest-client").flatMap(Int.init) { options.oldestCompatibleClient = oldest }

setvbuf(stderr, nil, _IOLBF, 0)
nonisolated(unsafe) let formatter = ISO8601DateFormatter()
let server = PtydServer(options: options) { line in
    FileHandle.standardError.write(Data("\(formatter.string(from: Date())) ptyd[\(getpid())] \(line)\n".utf8))
}
do {
    try server.start()
} catch PtydServer.StartError.alreadyRunning {
    // Another helper serves this folder: nothing to do (exit 0 so launchd doesn't retry at once).
    FileHandle.standardError.write(Data("ptyd: another helper is running for \(paths.directory.path)\n".utf8))
    exit(0)
} catch {
    FileHandle.standardError.write(Data("ptyd: \(error)\n".utf8))
    exit(1)
}
dispatchMain()
