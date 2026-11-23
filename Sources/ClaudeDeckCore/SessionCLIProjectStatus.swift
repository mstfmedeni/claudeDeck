import Foundation

/// `claudedeck project status get|set|clear`: the routes, the refusals and the script's part
/// (interpolated into `SessionCLI.script` and `SessionCLI.skill`). The rules are in ProjectStatus.swift.
extension SessionCLI {
    /// `/v1/cli/project-status` and `/v1/cli/projects/{ref}/status`; nil for every other path.
    static func projectStatusMatch(method: String, rest: [String]) -> Match? {
        func expect(_ wanted: String, _ route: Route) -> Match { method == wanted ? .route(route) : .methodNotAllowed }
        if rest == ["project-status"] { return expect("GET", .projectStatuses) }
        if rest.count == 3, rest[0] == "projects", rest[2] == "status" {
            let ref = AgentHTTP.percentDecode(rest[1])
            return method == "POST" ? .route(.setProjectStatus(ref)) : expect("GET", .showProjectStatus(ref))
        }
        return nil
    }

    /// A refusal with a message the command prints after the code.
    public static func failure(_ status: Int, _ code: String, message: String, exit: Exit) -> AgentHTTPResponse {
        let object: [String: String] = ["error": code, "message": message]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        var response = AgentHTTPResponse(status: status, body: data, contentType: "application/json; charset=utf-8")
        response.headers[exitHeader] = String(exit.rawValue)
        return response
    }

    /// `set`/`clear` of another project's status without the coordinator switch (`403 not_your_project`).
    public static let notYourProject = failure(403, "not_your_project",
                                               message: "a session sets its own project's status (the owner can let one project set every project's)",
                                               exit: .refused)

    public static func projectStatusRefusal(_ refusal: ProjectStatus.Refusal) -> AgentHTTPResponse {
        let message = switch refusal {
        case .emptyText: "--text is empty"
        case .textTooLong: "--text is at most \(ProjectStatus.maxText) characters (the sidebar shows \(ProjectStatus.displayLimit))"
        case .summaryTooLong: "--summary is at most \(ProjectStatus.maxSummary) characters"
        case .badTone: "--tone is ok, wait or warn"
        }
        return failure(400, refusal.rawValue, message: message, exit: .usage)
    }

    // MARK: The script's part

    /// Lines of `claudedeck help`.
    static let projectStatusUsage = #"""
      claudedeck project status set PROJECT --text TEXT [--summary TEXT|-] [--tone ok|wait|warn] [--json]
          The short status next to the project's name in ClaudeDeck's sidebar ("1.0 in review",
          "Live · Nov 22", "Design"). TEXT: up to ~24 characters show (longer is cut with "…",
          over 80 refused). --summary (- reads stdin, at most 600 characters): the tooltip, e.g.
          what was done last and the next step. --tone colors it: ok green, wait orange, warn red.
          Only this session's own project (self), unless the owner made this project a
          coordinator project.
      claudedeck project status get [PROJECT] [--json]
          One project's status, or every project's without PROJECT.
      claudedeck project status clear PROJECT [--json]
          Removes it (same rule as set).
    """#

    /// The shell function behind `claudedeck project status …`.
    static let projectStatusScript = #"""
    cmd_project_status() {
      action=${1:-get}
      [ $# -gt 0 ] && shift
      case "$action" in get|set|clear) ;;
        *) die "project status: try claudedeck project status get [PROJECT], set PROJECT --text TEXT, or clear PROJECT" ;; esac
      cmd="project status $action"; project=""; text=""; summary=""; tone=""; have_text=0
      while [ $# -gt 0 ]; do
        case "$action:$1" in
          *:--json) json=1 ;;
          set:--text) [ $# -ge 2 ] || die "$cmd: --text needs text"; text=$2; have_text=1; shift ;;
          set:--text=*) text=${1#*=}; have_text=1 ;;
          set:--summary) [ $# -ge 2 ] || die "$cmd: --summary needs text (- reads stdin)"; summary=$2; shift ;;
          set:--summary=*) summary=${1#*=} ;;
          set:--tone) [ $# -ge 2 ] || die "$cmd: --tone needs ok, wait or warn"; tone=$2; shift ;;
          set:--tone=*) tone=${1#*=} ;;
          *:-*) die "$cmd: unknown option $1" ;;
          *) [ -z "$project" ] || die "$cmd: one PROJECT only"; project=$1 ;;
        esac
        shift
      done
      case "$tone" in ""|ok|wait|warn) ;; *) die "$cmd: --tone is ok, wait or warn" ;; esac
      if [ "$action" = set ]; then
        [ "$have_text" = 1 ] && [ -n "$text" ] || die "project status set: --text is required"
        [ "$summary" = "-" ] && summary=$(cat)
      fi
      [ "$action" = get ] || [ -n "$project" ] || die "$cmd: which project? (an id, a name, a path or self)"
      need_session
      if [ -z "$project" ]; then
        call /project-status -G --data-urlencode "format=$(fmt)"
        finish
      fi
      ref=$(project_ref "$project")
      case "$action" in
        get) call "/projects/$ref/status" -G --data-urlencode "format=$(fmt)" ;;
        set) call "/projects/$ref/status" --data-urlencode "text=$text" --data-urlencode "summary=$summary" \
          --data-urlencode "tone=$tone" --data-urlencode "format=$(fmt)" ;;
        clear) call "/projects/$ref/status" --data-urlencode "clear=1" --data-urlencode "format=$(fmt)" ;;
      esac
      finish
    }
    """#

    /// The skill's section.
    static let projectStatusSkill = #"""
    ### Project status (leads)

    Each project shows a short status next to its name in ClaudeDeck's sidebar (and on the
    phone), so the owner sees at a glance where every project stands. If you lead the work in a
    project, update it at each milestone: when a phase starts or ends, a build goes to review,
    a release ships, the project waits on the owner, or it stops.

    ```sh
    claudedeck project status set self --text "1.0 in review" --tone wait \
      --summary "Done: 1.0 submitted to App Store review. Next: answer review notes, then 1.0.1."
    claudedeck project status set self --text "Live · Nov 22" --tone ok --summary - < notes.txt
    claudedeck project status get            # every project; get PROJECT for one
    claudedeck project status clear self
    ```

    - `--text`: a few words; about 24 characters show (longer is cut with "…", over 80 is
      refused). Say the state, not the activity: "1.0.1 waiting (PPO)", "Design", "Stopped".
    - `--summary`: the tooltip, a few lines (at most 600 characters): what was done last and the
      next step.
    - `--tone`: `ok` (green: live, done), `wait` (orange: in review, waiting on someone), `warn`
      (red: broken, blocked, stopped). Leave it out for a neutral status.
    - Only your own project (`self`), unless the owner made your project a coordinator project
      (its context menu in ClaudeDeck); `not_your_project` (exit 4) otherwise.
    - A status older than 7 days is dimmed: refresh it when it is still true.
    """#
}

// MARK: The command's answers

/// `GET /v1/cli/projects/{ref}/status`, `POST` (set/clear), and each entry of `GET /v1/cli/project-status`.
public struct SessionCLIProjectStatus: Encodable, Sendable, Equatable {
    public var projectId: UUID
    public var project: String
    public var text: String?
    public var summary: String?
    public var tone: String?
    public var updatedAt: Date?
    public var updatedBy: String?
    /// Older than `ProjectStatus.staleAfter` (dimmed in the sidebar).
    public var stale: Bool
    /// This project's sessions may set every project's status.
    public var coordinator: Bool

    public init(project: Project, now: Date = Date()) {
        projectId = project.id
        self.project = project.name
        text = project.status?.text
        summary = project.status?.summary
        tone = project.status?.tone?.rawValue
        updatedAt = project.status?.updatedAt
        updatedBy = project.status?.updatedBy
        stale = project.status?.isStale(now: now) ?? false
        coordinator = project.isCoordinator
    }

    private enum CodingKeys: String, CodingKey { case projectId, project, text, summary, tone, updatedAt, updatedBy, stale, coordinator }

    /// Every key is always there (null when unset).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectId, forKey: .projectId)
        try c.encode(project, forKey: .project)
        try c.encode(text, forKey: .text)
        try c.encode(summary, forKey: .summary)
        try c.encode(tone, forKey: .tone)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(updatedBy, forKey: .updatedBy)
        try c.encode(stale, forKey: .stale)
        try c.encode(coordinator, forKey: .coordinator)
    }
}

extension SessionCLI {
    /// `project status get PROJECT`: "app: 1.0 in review [wait] · 2026-11-22 14:05 by lead", then the summary.
    public static func projectStatusText(_ info: SessionCLIProjectStatus) -> String {
        guard let text = info.text else { return "\(info.project): no status" }
        var line = "\(info.project): \(text)"
        if let tone = info.tone { line += " [\(tone)]" }
        if let at = info.updatedAt { line += " · " + statusDate(at) }
        if let by = info.updatedBy { line += " by \(by)" }
        if info.stale { line += " (stale)" }
        if let summary = info.summary { line += "\n" + summary }
        return line
    }

    /// `project status get`: one row per project.
    public static func projectStatusesText(_ infos: [SessionCLIProjectStatus]) -> String {
        let header = ["ID", "TONE", "UPDATED", "BY", "PROJECT", "STATUS"]
        let rows = infos.map { info in
            [String(info.projectId.uuidString.prefix(8)), info.tone ?? "-", info.updatedAt.map(statusDate) ?? "-",
             info.updatedBy ?? "-", info.project, (info.text ?? "-") + (info.stale ? " (stale)" : "")]
        }
        return table([header] + rows)
    }

    private static func statusDate(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format.string(from: date)
    }
}
