import Darwin
import Foundation

/// Small POSIX helpers shared by the helper (PtydServer) and the app (PtydClient).
enum PtydSocket {
    enum Failure: Error, CustomStringConvertible {
        case pathTooLong(String)
        case sys(String, Int32)

        var description: String {
            switch self {
            case .pathTooLong(let path): "socket path too long: \(path)"
            case .sys(let call, let code): "\(call): \(String(cString: strerror(code)))"
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func setBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }

    /// Children must not inherit the helper's sockets, ptys or lock.
    static func setCloseOnExec(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func setNoSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Listening socket at `path`, readable and writable by the owner only.
    static func listen(at path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.sys("socket", errno) }
        setCloseOnExec(fd)
        unlink(path)
        // 0600 from the start: no window where another user could connect.
        let oldMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure.sys("bind", code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw Failure.sys("listen", code)
        }
        setNonBlocking(fd)
        return fd
    }

    /// Connects to `path` (blocking). The caller sets timeouts afterwards.
    static func connect(to path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.sys("socket", errno) }
        setCloseOnExec(fd)
        setNoSigPipe(fd)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Failure.sys("connect", code)
        }
        return fd
    }

    /// The uid on the other end of a Unix socket.
    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Writes everything (blocking socket). False if the peer is gone.
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, bytes.count - offset)
            }
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            return false
        }
        return true
    }
}
