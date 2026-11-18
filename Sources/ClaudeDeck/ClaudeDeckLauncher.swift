import ClaudeDeckCore

/// The executable's entry point: ClaudeDeck itself, or (with `--serverplan-terminal`, run by a
/// ServerPlan terminal session) the terminal bridge, before any app state is created.
@main
enum ClaudeDeckLauncher {
    static func main() {
        if CommandLine.arguments.dropFirst().first == ServerPlanTerminalBridge.argument {
            ServerPlanTerminalBridge.run()
        }
        ClaudeDeckApp.main()
    }
}
