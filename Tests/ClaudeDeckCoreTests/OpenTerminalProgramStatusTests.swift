import Foundation
import Testing
@testable import ClaudeDeckCore

/// `claudedeck list` / `wait` with Program Status, and `claudedeck open` keeping the shell integration.
@Suite struct SessionCLIProgramStatusTests {
    @Test func blockedIsBlockedWithExitThree() {
        let progress = SessionCLI.programProgress(.blocked, exitCode: nil, fallback: .running)
        #expect(progress == .blocked("blocked"))
        #expect(progress.exit == .blocked)
        #expect(progress.exit.rawValue == 3)
        #expect(progress.result == "blocked")
        #expect(SessionCLI.waitText(progress, detail: "Deploy?") == "blocked: needs input — Deploy?")
    }

    @Test func workingIsRunning() {
        #expect(SessionCLI.programProgress(.working, exitCode: nil, fallback: .finished(nil)) == .running)
        #expect(SessionCLI.programProgress(.working, exitCode: nil, fallback: .failed(2)) == .running)
    }

    @Test func resultsFillInWhatTheShellDidntKnow() {
        #expect(SessionCLI.programProgress(.failed, exitCode: 2, fallback: .finished(nil)) == .failed(2))
        #expect(SessionCLI.programProgress(.failed, exitCode: nil, fallback: .finished(nil)) == .failed(1))
        #expect(SessionCLI.programProgress(.finished, exitCode: 0, fallback: .finished(nil)) == .finished(0))
        // The program got past its blocked state but the shell hadn't seen anything since.
        #expect(SessionCLI.programProgress(.finished, exitCode: nil, fallback: .blocked("blocked")) == .finished(0))
    }

    @Test func newerShellKnowledgeWins() {
        // A command typed a moment ago: the previous result doesn't end the wait.
        #expect(SessionCLI.programProgress(.finished, exitCode: 0, fallback: .running) == .running)
        // The exit code of the command `open` ran is the one asked about.
        #expect(SessionCLI.programProgress(.finished, exitCode: 0, fallback: .failed(4)) == .failed(4))
        #expect(SessionCLI.programProgress(nil, exitCode: nil, fallback: .finished(nil)) == .finished(nil))
    }

    @Test func claudeBlockedTextsUnchanged() {
        #expect(SessionCLI.waitText(.blocked("needsPermission"), detail: nil) == "blocked: needs permission")
        #expect(SessionCLI.waitText(.blocked("needsAnswer"), detail: nil) == "blocked: asking a question")
    }
}

@Suite struct OpenCommandShellIntegrationTests {
    @Test func withoutIntegrationTheScriptIsUnchanged() {
        let args = ShellIntegration.commandArgs(shell: "/bin/zsh", command: "npm test", exitFile: "/tmp/e", integration: nil)
        #expect(args == ["-l", "-i", "-c", #"trap : INT; "$0" -c "$1"; code=$?; trap - INT; printf '%s\n' "$code" > "$2"; exec "$0" -l"#,
                         "/bin/zsh", "npm test", "/tmp/e"])
    }

    @Test func bashKeepsItsInitFile() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let args = ShellIntegration.commandArgs(shell: "/bin/bash", command: "make", exitFile: "/tmp/e", integration: (.bash, folder))
        #expect(args.last == "/tmp/x/bash/claudedeck.bash")
        #expect(args[3].hasSuffix(#"exec "$0" --init-file "$3""#))
        #expect(args[3].contains(#"printf '\033]133;C\007'"#))
        let zsh = ShellIntegration.commandArgs(shell: "/bin/zsh", command: "make", exitFile: "/tmp/e", integration: (.zsh, folder))
        #expect(zsh.last == "/tmp/x/zsh")
        #expect(zsh[3].hasSuffix(#"export ZDOTDIR="$3"; exec "$0" -l"#))
    }

    /// Runs the wrapper under a pseudo-terminal (the shell it becomes is interactive only on a
    /// tty): the command is marked, its code saved, and the shell it becomes still marks prompts.
    func run(_ shell: ShellIntegration.Shell, path: String) throws -> (output: String, exit: String)? {
        guard FileManager.default.isExecutableFile(atPath: path), FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else { return nil }
        let root = FileManager.default.temporaryDirectory.appending(path: "cd-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home"), folder = root.appending(path: "integration"), exitFile = root.appending(path: "exit")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try ShellIntegration.install(in: folder)
        let launch = ShellIntegration.launch(shell, folder: folder, environment: [:])
        let args = ShellIntegration.commandArgs(shell: path, command: "exit 3", exitFile: exitFile.path, integration: (shell, folder))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/usr/bin/env", "-i", "HOME=\(home.path)", "PATH=/usr/bin:/bin", "TERM=dumb"]
            + launch.environment.map { "\($0.key)=\($0.value)" } + [path] + args
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        // The final shell reads this at its prompt: a command that prints a marker, then exit.
        Thread.sleep(forTimeInterval: 1.5)
        stdin.fileHandleForWriting.write(Data("echo AFTER\nexit\n".utf8))
        try stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate() }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let code = (try? String(contentsOf: exitFile, encoding: .utf8)) ?? ""
        return (String(decoding: data, as: UTF8.self), code.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(arguments: [(ShellIntegration.Shell.zsh, "/bin/zsh"), (ShellIntegration.Shell.bash, "/bin/bash")])
    func theShellAfterTheCommandKeepsTheIntegration(_ shell: ShellIntegration.Shell, _ path: String) throws {
        guard let result = try run(shell, path: path) else { return }
        #expect(result.exit == "3")
        #expect(result.output.contains("\u{1B}]133;C\u{07}"))
        #expect(result.output.contains("\u{1B}]133;D;3\u{07}"))
        // Only the hooks print a prompt mark: the shell the wrapper became has them.
        #expect(result.output.contains("\u{1B}]133;A\u{07}"))
        #expect(result.output.contains("AFTER"))
    }
}
