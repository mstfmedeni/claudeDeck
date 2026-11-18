import SwiftUI

/// A plain terminal's program status (Program Status on the Mac), with the Mac's labels and
/// colors: Running green, Needs input red, Finished yellow, Failed (exit N) orange. Working,
/// blocked and finished follow the colors picked for running, attention and "your turn".
enum ProgramStyle {
    static let states: Set<String> = ["working", "blocked", "finished", "failed"]

    /// A state this build can show (a newer Mac's other states read as a plain terminal).
    static func knows(_ program: RemoteProgramStatus) -> Bool { states.contains(program.state) }

    static func label(_ program: RemoteProgramStatus) -> String {
        switch program.state {
        case "working": String(localized: "Running")
        case "blocked":
            switch program.kind {
            case "permission": String(localized: "Needs permission")
            case "question": String(localized: "Asking a question")
            case "auth": String(localized: "Needs sign-in")
            default: String(localized: "Needs input")
            }
        case "finished": String(localized: "Finished")
        case "failed": program.exitCode.map { String(localized: "Failed (exit \(Int($0)))") } ?? String(localized: "Failed")
        default: String(localized: "Terminal")
        }
    }

    /// The session state whose color it takes; nil for failed (orange of its own).
    static func colorState(_ program: RemoteProgramStatus) -> RemoteSession.State? {
        switch program.state {
        case "working": .running
        case "blocked": .needsPermission
        case "finished": .idle
        case "failed": nil
        default: .shell
        }
    }

    static func color(_ program: RemoteProgramStatus, custom: String) -> Color {
        colorState(program).map { SessionStyle.color($0, custom: custom) } ?? .orange
    }

    static func textColor(_ program: RemoteProgramStatus, custom: String) -> Color {
        colorState(program).map { SessionStyle.textColor(on: $0, custom: custom) } ?? .white
    }

    /// The Mac puts the label in front of the detail for older phones ("Failed (exit 1) · npm
    /// test"); with the badge showing it, only the rest.
    static func detail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let parts = detail.components(separatedBy: " · ")
        let rest = parts.dropFirst().joined(separator: " · ")
        return rest.isEmpty ? nil : rest
    }
}

extension RemoteStore {
    /// The session's detail as the list and the header show it (without the program's label).
    func detail(of session: RemoteSession) -> String? {
        program(of: session) == nil ? session.detail : ProgramStyle.detail(session.detail)
    }
}
