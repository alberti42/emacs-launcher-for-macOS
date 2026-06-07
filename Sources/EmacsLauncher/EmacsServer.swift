//
// EmacsServer — a minimal, native Swift client for the Emacs server protocol.
//
// This replaces shelling out to the `emacsclient` binary: we speak the same
// wire protocol directly over the daemon's local AF_UNIX socket. Only the local
// socket case is supported (no TCP/server-file auth, no tty/signal handling, no
// daemon-starting) — that's all this launcher needs, and it keeps the app fully
// self-contained with no dependency on an emacsclient binary on disk.
//
// Protocol (see Emacs lib-src/emacsclient.c):
//   * Connect to a Unix-domain stream socket.
//   * Send one '\n'-terminated line of space-separated tokens. Argument values
//     are quoted with `quote`: a leading '-' is prefixed with '&', spaces become
//     '&_', newlines '&n', and '&' is doubled — so a value never contains a raw
//     space or newline that would be read as a token separator.
//   * Read '\n'-terminated reply lines: `-emacs-pid N`, `-print STR`,
//     `-print-nonl STR`, `-error STR` (STR is itself quoted).
//
import Foundation

enum EmacsServer {

    /// Parsed reply from one server exchange.
    struct Reply {
        var pid: Int?
        var prints: [String]     // unquoted -print / -print-nonl payloads, in order
        var error: String?       // unquoted -error payload, if any
    }

    // MARK: Socket location

    /// Resolve the daemon's local socket path, mirroring emacsclient's search:
    /// $EMACS_SOCKET_NAME, then $XDG_RUNTIME_DIR/emacs/<name>, then
    /// <tmpdir>/emacs<uid>/<name>. `serverName` is the Emacs `server-name`.
    static func socketPath(serverName: String = "server") -> String? {
        let env = ProcessInfo.processInfo.environment
        if let name = env["EMACS_SOCKET_NAME"], !name.isEmpty {
            // With a slash it's a full path; otherwise a server-name component.
            return name.contains("/") ? name : "\(defaultDir())/\(name)"
        }
        if let xdg = env["XDG_RUNTIME_DIR"], !xdg.isEmpty {
            return "\(trimSlash(xdg))/emacs/\(serverName)"
        }
        return "\(defaultDir())/\(serverName)"
    }

    /// `<tmpdir>/emacs<uid>` — the directory holding the default socket.
    private static func defaultDir() -> String {
        "\(tmpDir())/emacs\(geteuid())"
    }

    /// The per-user temp dir: $TMPDIR, else Darwin's _CS_DARWIN_USER_TEMP_DIR
    /// (value 65537, as hard-coded in emacsclient.c too), else /tmp.
    private static func tmpDir() -> String {
        if let t = ProcessInfo.processInfo.environment["TMPDIR"], !t.isEmpty {
            return trimSlash(t)
        }
        let CS_DARWIN_USER_TEMP_DIR: Int32 = 65537
        var buf = [CChar](repeating: 0, count: 1024)
        let n = confstr(CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        if n > 0, n <= buf.count {
            return trimSlash(String(cString: buf))
        }
        return "/tmp"
    }

    private static func trimSlash(_ s: String) -> String {
        s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    // MARK: Command building

    /// A bare directive, e.g. `-nowait `.
    static func token(_ name: String) -> [UInt8] {
        Array("\(name) ".utf8)
    }

    /// A directive with a quoted argument, e.g. `-file <quoted-path> `.
    static func token(_ name: String, _ value: String) -> [UInt8] {
        Array("\(name) ".utf8) + quote(value) + [0x20]
    }

    /// Quote a value per the protocol. Operates byte-wise so non-ASCII (UTF-8)
    /// file names pass through untouched.
    static func quote(_ s: String) -> [UInt8] {
        var out = [UInt8]()
        let bytes = Array(s.utf8)
        for (i, b) in bytes.enumerated() {
            if i == 0, b == 0x2D { out.append(0x26) }          // leading '-' -> '&-'
            switch b {
            case 0x20: out.append(0x26); out.append(0x5F)      // ' '  -> '&_'
            case 0x0A: out.append(0x26); out.append(0x6E)      // '\n' -> '&n'
            case 0x26: out.append(0x26); out.append(0x26)      // '&'  -> '&&'
            default:   out.append(b)
            }
        }
        return out
    }

    /// Inverse of `quote`, for decoding reply payloads.
    private static func unquote(_ bytes: ArraySlice<UInt8>) -> String {
        var out = [UInt8]()
        var it = bytes.startIndex
        while it < bytes.endIndex {
            var c = bytes[it]; it = bytes.index(after: it)
            if c == 0x26, it < bytes.endIndex {                // '&'
                c = bytes[it]; it = bytes.index(after: it)
                if c == 0x5F { c = 0x20 } else if c == 0x6E { c = 0x0A }
            }
            out.append(c)
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Exchange

    /// True if the socket accepts a connection right now (i.e. the daemon is up).
    static func isReachable(_ path: String) -> Bool {
        guard let fd = connect(path) else { return false }
        close(fd)
        return true
    }

    /// Connect, send `command` (a '\n' is appended), read the whole reply, and
    /// return it parsed. Returns nil if the socket can't be reached (no daemon).
    static func send(_ path: String, _ command: [UInt8]) -> Reply? {
        guard let fd = connect(path) else { return nil }
        defer { close(fd) }

        var payload = command
        payload.append(0x0A)
        var off = 0
        payload.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while off < payload.count {
                let n = write(fd, base + off, payload.count - off)
                if n <= 0 { break }
                off += n
            }
        }

        var data = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return parse(data)
    }

    private static func parse(_ data: [UInt8]) -> Reply {
        var reply = Reply(pid: nil, prints: [], error: nil)
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: 0x0A) {
            let line = data[start..<nl]
            start = data.index(after: nl)
            handle(line, into: &reply)
        }
        return reply
    }

    private static func handle(_ line: ArraySlice<UInt8>, into reply: inout Reply) {
        func rest(after prefix: String) -> ArraySlice<UInt8>? {
            let p = Array(prefix.utf8)
            guard line.count >= p.count else { return nil }
            var i = line.startIndex
            for b in p { if line[i] != b { return nil }; i = line.index(after: i) }
            return line[i...]
        }
        if let r = rest(after: "-emacs-pid ") {
            reply.pid = Int(String(decoding: r, as: UTF8.self).trimmingCharacters(in: .whitespaces))
        } else if let r = rest(after: "-print ") {
            reply.prints.append(unquote(r))
        } else if let r = rest(after: "-print-nonl ") {
            reply.prints.append(unquote(r))
        } else if let r = rest(after: "-error ") {
            reply.error = unquote(r)
        }
    }

    /// Open and connect an AF_UNIX stream socket to `path`, with a read timeout.
    private static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { close(fd); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                _ = strncpy(dst, path, capacity - 1)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        guard rc == 0 else { close(fd); return nil }

        // Don't hang forever if the daemon stalls; it normally closes promptly.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }
}
