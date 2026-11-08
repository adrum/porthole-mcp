#if DEBUG
import Foundation
import Darwin

/// Where the hub listens (docs/protocol.md, "The hub").
enum SocketDirectory {
    /// `$PORTHOLE_MCP_DIR` or `/tmp/porthole-mcp-<uid>`. Always the literal host
    /// `/tmp`: in the Simulator `NSTemporaryDirectory()` points inside the
    /// simulated device.
    static func defaultPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let dir = env["PORTHOLE_MCP_DIR"], !dir.isEmpty {
            return dir
        }
        return "/tmp/porthole-mcp-\(getuid())"
    }

    /// The hub socket to dial: `$PORTHOLE_MCP_HUB` (`unix:/path`), then the
    /// options, then `<dir>/hub.sock`.
    static func hubSocketPath(options: Porthole.Options, env: [String: String]) throws -> String {
        if let hub = env["PORTHOLE_MCP_HUB"], !hub.isEmpty {
            return try parse(hub)
        }
        if let hub = options.hub {
            return try parse(hub)
        }
        let dir = env["PORTHOLE_MCP_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? options.directory ?? defaultPath(env: env)
        return (dir as NSString).appendingPathComponent("hub.sock")
    }

    static func parse(_ hub: String) throws -> String {
        if hub.hasPrefix("unix:") { return String(hub.dropFirst(5)) }
        if hub.hasPrefix("/") { return hub }
        if hub.hasPrefix("ws://") || hub.hasPrefix("wss://") {
            throw HarnessError.unsupported("connecting to a hub over the network (\(hub)) isn't supported yet; use unix:/path")
        }
        throw HarnessError.invalid("PORTHOLE_MCP_HUB must be unix:/path/to/hub.sock, not \(hub)")
    }

    /// Only dial a hub socket that belongs to this user, so another user
    /// can't stand in for the hub.
    static func checkHubSocket(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw HarnessError.failed(errno == ENOENT ? "the hub isn't running (no \(path))" : "can't stat \(path): \(String(cString: strerror(errno)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            throw HarnessError.failed("\(path) is not a socket")
        }
        guard st.st_uid == getuid() else {
            throw HarnessError.failed("\(path) belongs to uid \(st.st_uid), not \(getuid()); refusing to connect")
        }
    }
}
#endif
