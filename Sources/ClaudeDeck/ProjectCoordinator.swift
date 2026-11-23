import ClaudeDeckCore
import SwiftUI

/// A coordinator project (`Project.coordinator`): its sessions may act on every project, e.g.
/// set any project's status. Only the owner turns it on, from the project's context menu.
extension AppModel {
    func setCoordinator(_ id: UUID, _ on: Bool) {
        guard let project = deck.project(id), project.isCoordinator != on else { return }
        mutate { $0.updateProject(id) { $0.isCoordinator = on } }
        logAgent("ClaudeDeck", inbound: false, "\(project.name) is " + (on ? "now a coordinator project" : "no longer a coordinator project"))
    }
}

/// The project menu's coordinator switch (owner only: there is no command for it).
struct CoordinatorToggle: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        Toggle("Coordinator project (may write every project's status and rename projects)", isOn: Binding(
            get: { project.isCoordinator },
            set: { model.setCoordinator(project.id, $0) }
        ))
    }
}
