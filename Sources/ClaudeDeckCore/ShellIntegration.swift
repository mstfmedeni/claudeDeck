import Foundation

/// ClaudeDeck's own shell integration for plain terminals with Program Status on: OSC 133 marks
/// (`C` when a command runs, `D;<exit>` when it finishes, `A` at each prompt) so builds and tests
/// show working / finished / failed without the program knowing about OSC 7501.
///
/// The user's dotfiles are never touched. zsh: `ZDOTDIR` points at a folder of ours whose
/// `.zshenv` puts the user's `ZDOTDIR` back, sources their `.zshenv` and adds the hooks; zsh then
/// reads the user's `.zprofile`, `.zshrc` and `.zlogin` as usual. bash: started with
/// `--init-file`, which reads the login files a login shell would (`/etc/profile`, then the first
/// of `~/.bash_profile`, `~/.bash_login`, `~/.profile`) and adds the hooks. Other shells get none.
public enum ShellIntegration {
    public enum Shell: Equatable, Sendable {
        case zsh, bash
    }

    /// The env var that carries the user's own `ZDOTDIR` (when they had one) into our `.zshenv`.
    public static let userZDOTDIRKey = "CLAUDEDECK_USER_ZDOTDIR"

    public static func shell(forPath path: String) -> Shell? {
        switch (path as NSString).lastPathComponent {
        case "zsh": .zsh
        case "bash": .bash
        default: nil
        }
    }

    /// How to start `shell` with the integration in `folder`: extra environment, arguments, and
    /// whether it still runs as a login shell (argv[0] starting with "-").
    public static func launch(_ shell: Shell, folder: URL, environment: [String: String])
        -> (environment: [String: String], args: [String], login: Bool) {
        switch shell {
        case .zsh:
            var env: [String: String] = ["ZDOTDIR": folder.appending(path: "zsh").path]
            if let user = environment["ZDOTDIR"] { env[userZDOTDIRKey] = user }
            return (env, ["-l"], true)
        case .bash:
            // A login bash ignores --init-file: ours reads the login files itself.
            return ([:], ["--init-file", folder.appending(path: "bash/claudedeck.bash").path], false)
        }
    }

    /// `claudedeck open`'s command: an interactive login shell runs it as a job of its own (Ctrl+C
    /// stops only the command), writes its exit code to `exitFile`, then becomes the user's shell
    /// (same pid). With the integration (`integration`, as passed to `launch`) the command is
    /// marked like one typed at the prompt (OSC 133 C, then D with its code) and the shell it
    /// becomes keeps the hooks: zsh gets our `ZDOTDIR` back (our `.zshenv` put the user's in place
    /// in the first shell), bash starts with `--init-file` again.
    public static func commandArgs(shell: String, command: String, exitFile: String, integration: (shell: Shell, folder: URL)?) -> [String] {
        let run = #"trap : INT; "$0" -c "$1"; code=$?; trap - INT; "#
        let save = #"printf '%s\n' "$code" > "$2"; "#
        guard let integration else {
            return ["-l", "-i", "-c", run + save + #"exec "$0" -l"#, shell, command, exitFile]
        }
        let marked = #"printf '\033]133;C\007'; "# + run + #"printf '\033]133;D;%s\007' "$code"; "# + save
        switch integration.shell {
        case .zsh:
            let rearm = #"if [ -n "${ZDOTDIR+x}" ]; then export \#(userZDOTDIRKey)="$ZDOTDIR"; else unset \#(userZDOTDIRKey); fi; "#
                + #"export ZDOTDIR="$3"; exec "$0" -l"#
            return ["-l", "-i", "-c", marked + rearm, shell, command, exitFile, integration.folder.appending(path: "zsh").path]
        case .bash:
            return ["-l", "-i", "-c", marked + #"exec "$0" --init-file "$3""#, shell, command, exitFile,
                    integration.folder.appending(path: "bash/claudedeck.bash").path]
        }
    }

    /// Writes the scripts into `folder` (only what changed).
    public static func install(in folder: URL) throws {
        for (path, contents) in files {
            let url = folder.appending(path: path)
            if (try? String(contentsOf: url, encoding: .utf8)) == contents { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public static let files: [String: String] = [
        "zsh/.zshenv": zshenv,
        "zsh/claudedeck-integration.zsh": zshHooks,
        "bash/claudedeck.bash": bash,
    ]

    static let zshenv = #"""
    # ClaudeDeck shell integration (Program Status). Puts the user's ZDOTDIR back, loads their
    # .zshenv, then adds the OSC 133 hooks; zsh reads the rest of their startup files as usual.
    if [[ -n "${CLAUDEDECK_USER_ZDOTDIR+x}" ]]; then
      export ZDOTDIR="$CLAUDEDECK_USER_ZDOTDIR"
      unset CLAUDEDECK_USER_ZDOTDIR
    else
      unset ZDOTDIR
    fi
    _claudedeck_dir="${${(%):-%x}:A:h}"
    if [[ -f "${ZDOTDIR:-$HOME}/.zshenv" && -r "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
      builtin source "${ZDOTDIR:-$HOME}/.zshenv"
    fi
    if [[ -o interactive ]]; then
      builtin source "$_claudedeck_dir/claudedeck-integration.zsh"
    fi
    unset _claudedeck_dir

    """#

    static let zshHooks = #"""
    # ClaudeDeck shell integration: OSC 133 C when a command runs, D;<exit> when it finishes,
    # A at every prompt.
    if [[ -z "${_claudedeck_hooks-}" ]]; then
      typeset -g _claudedeck_hooks=1 _claudedeck_running=0
      _claudedeck_preexec() {
        _claudedeck_running=1
        builtin printf '\033]133;C\007'
      }
      _claudedeck_precmd() {
        local ret=$?
        if (( _claudedeck_running )); then
          builtin printf '\033]133;D;%s\007' "$ret"
          _claudedeck_running=0
        fi
        builtin printf '\033]133;A\007'
      }
      autoload -Uz add-zsh-hook
      add-zsh-hook preexec _claudedeck_preexec
      add-zsh-hook precmd _claudedeck_precmd
    fi

    """#

    static let bash = #"""
    # ClaudeDeck shell integration (Program Status). Reads the files a login bash would, then adds
    # OSC 133 marks: C when a command runs, D;<exit> when it finishes, A at every prompt.
    if [ -r /etc/profile ]; then . /etc/profile; fi
    if [ -r ~/.bash_profile ]; then . ~/.bash_profile
    elif [ -r ~/.bash_login ]; then . ~/.bash_login
    elif [ -r ~/.profile ]; then . ~/.profile
    fi
    if [ -z "${_claudedeck_hooks-}" ]; then
      _claudedeck_hooks=1
      _claudedeck_running=0
      _claudedeck_at_prompt=0
      _claudedeck_preexec() {
        [ "$_claudedeck_at_prompt" = 1 ] || return 0
        _claudedeck_at_prompt=0
        case "$BASH_COMMAND" in _claudedeck_precmd*) return 0 ;; esac
        _claudedeck_running=1
        builtin printf '\033]133;C\007'
      }
      _claudedeck_precmd() {
        local ret=$?
        if [ "$_claudedeck_running" = 1 ]; then
          builtin printf '\033]133;D;%s\007' "$ret"
          _claudedeck_running=0
        fi
        builtin printf '\033]133;A\007'
        _claudedeck_at_prompt=1
      }
      # Someone else's DEBUG trap (bash-preexec…) stays: then only prompts are marked.
      if [ -z "$(trap -p DEBUG)" ]; then trap '_claudedeck_preexec' DEBUG; fi
      PROMPT_COMMAND="_claudedeck_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
    fi

    """#
}
