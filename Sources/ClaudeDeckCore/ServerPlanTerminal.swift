import Darwin
import Foundation

/// Control frames of ServerPlan's terminal WebSocket (text JSON; pty bytes travel as binary frames).
/// CONTRACT: `{"type":"resize","cols","rows"}` from the client, `{"type":"exit","code"}` and
/// (proposed) `{"type":"error","message"}` from the server.
public enum ServerPlanTerminalMessage: Equatable, Sendable {
    case resize(cols: Int, rows: Int)
    case exit(code: Int)
    case error(String)

    public var json: String {
        let object: [String: Any] = switch self {
        case .resize(let cols, let rows): ["type": "resize", "cols": cols, "rows": rows]
        case .exit(let code): ["type": "exit", "code": code]
        case .error(let message): ["type": "error", "message": message]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public init?(json: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "resize":
            guard let cols = object["cols"] as? Int, let rows = object["rows"] as? Int else { return nil }
            self = .resize(cols: cols, rows: rows)
        case "exit": self = .exit(code: object["code"] as? Int ?? 0)
        case "error": self = .error(object["message"] as? String ?? "")
        default: return nil
        }
    }
}

/// The process behind a ServerPlan terminal session: ClaudeDeck runs its own executable with
/// `--serverplan-terminal` in a normal terminal pty, and this pumps that pty to the panel's
/// terminal WebSocket and back. The panel does the SSH; no SSH secret ever reaches this Mac.
///
/// The WebSocket URL (with its single-use, short-lived ticket) comes in the environment, read
/// once and removed. Everything typed goes out raw (the tty is put in raw mode), and the pty's
/// size goes out on start and on every SIGWINCH.
public enum ServerPlanTerminalBridge {
    public static let argument = "--serverplan-terminal"
    public static let urlVariable = "CLAUDEDECK_SERVERPLAN_WS"

    public static func run() -> Never {
        guard let raw = getenv(urlVariable).map({ String(cString: $0) }), let url = URL(string: raw) else {
            fail(String(localized: "No ServerPlan terminal address was given."))
        }
        unsetenv(urlVariable)
        let bridge = Bridge(url: url)
        bridge.start()
        dispatchMain()
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\r\n\(message)\r\n".utf8))
        exit(1)
    }

    private final class Bridge: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        let url: URL
        var task: URLSessionWebSocketTask?
        var session: URLSession?
        var saved = termios()
        var rawMode = false
        var sources: [DispatchSourceProtocol] = []
        let queue = DispatchQueue(label: "serverplan.terminal")

        init(url: URL) { self.url = url }

        func start() {
            enterRawMode()
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.webSocketTask(with: url)
            task.maximumMessageSize = 16 << 20
            self.task = task
            task.resume()
            receive()

            signal(SIGWINCH, SIG_IGN)
            let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: queue)
            winch.setEventHandler { [weak self] in self?.sendSize() }
            winch.resume()
            sources.append(winch)
            for sig in [SIGHUP, SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                source.setEventHandler { [weak self] in self?.finish(code: 0, message: nil) }
                source.resume()
                sources.append(source)
            }

            let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
            input.setEventHandler { [weak self] in
                guard let self else { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let n = read(STDIN_FILENO, &buffer, buffer.count)
                if n <= 0 { self.finish(code: 0, message: nil); return }
                self.task?.send(.data(Data(buffer[0..<n]))) { _ in }
            }
            input.resume()
            sources.append(input)
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            queue.async { self.sendSize() }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            queue.async { self.finish(code: 0, message: String(localized: "Connection to ServerPlan closed.")) }
        }

        func sendSize() {
            var size = winsize()
            guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return }
            task?.send(.string(ServerPlanTerminalMessage.resize(cols: Int(size.ws_col), rows: Int(size.ws_row)).json)) { _ in }
        }

        func receive() {
            task?.receive { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .failure(let error):
                        self.finish(code: 1, message: String(localized: "ServerPlan terminal: \(error.localizedDescription)"))
                    case .success(.data(let data)):
                        self.write(data)
                        self.receive()
                    case .success(.string(let text)):
                        switch ServerPlanTerminalMessage(json: text) {
                        case .exit(let code)?: self.finish(code: Int32(truncatingIfNeeded: code), message: nil)
                        case .error(let message)?: self.write(Data("\r\n\(message)\r\n".utf8)); self.receive()
                        case .resize?: self.receive()
                        case nil:
                            // CONTRACT: a server that sends output as text frames.
                            self.write(Data(text.utf8))
                            self.receive()
                        }
                    @unknown default:
                        self.receive()
                    }
                }
            }
        }

        func write(_ data: Data) {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { if errno == EINTR { continue }; return }
                    offset += n
                }
            }
        }

        func finish(code: Int32, message: String?) {
            leaveRawMode()
            if let message { FileHandle.standardError.write(Data("\r\n\(message)\r\n".utf8)) }
            task?.cancel(with: .normalClosure, reason: nil)
            exit(code)
        }

        func enterRawMode() {
            guard isatty(STDIN_FILENO) != 0, tcgetattr(STDIN_FILENO, &saved) == 0 else { return }
            var raw = saved
            cfmakeraw(&raw)
            if tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 { rawMode = true }
        }

        func leaveRawMode() {
            guard rawMode else { return }
            tcsetattr(STDIN_FILENO, TCSANOW, &saved)
            rawMode = false
        }
    }
}
