import Foundation

/// In-app harness for porthole-mcp. Debug builds only: in release builds these
/// calls compile to nothing.
///
/// ```swift
/// #if DEBUG
/// import Porthole
/// #endif
///
/// #if DEBUG
/// Porthole.start()
/// Porthole.registerHook("reset") { store.reset() }
/// #endif
/// ```
public enum Porthole {
    /// Where the harness connects. By default the porthole-mcp hub's socket,
    /// `/tmp/porthole-mcp-<uid>/hub.sock`.
    public struct Options {
        /// The hub to dial: `unix:/path/to/hub.sock`.
        public var hub: String?
        /// The hub's directory (default `$PORTHOLE_MCP_DIR` or `/tmp/porthole-mcp-<uid>`).
        public var directory: String?

        public init(hub: String? = nil, directory: String? = nil) {
            self.hub = hub
            self.directory = directory
        }
    }

    #if DEBUG
    /// Connect the app to the porthole-mcp hub, now and whenever the hub
    /// (re)starts. Environment overrides: `PORTHOLE_MCP_HUB`, `PORTHOLE_MCP_DIR`,
    /// `PORTHOLE_MCP_DISABLE=1`. Safe to call more than once.
    public static func start() {
        start(Options())
    }

    /// Start the harness with explicit options. Environment overrides still
    /// win, so a test runner can redirect any app.
    public static func start(_ options: Options) {
        Harness.shared.start(options)
    }

    /// Disconnect from the hub.
    public static func stop() {
        Harness.shared.stop()
    }

    /// Register a named closure the agent can run (for example to reset
    /// state). Hooks run on the main thread.
    public static func registerHook(_ name: String, _ body: @escaping () -> Void) {
        Hooks.shared.register(name, body)
    }

    /// The hub the harness dials, once started.
    public static var endpoint: String? {
        Harness.shared.endpointDescription
    }
    #else
    @inlinable public static func start() {}
    @inlinable public static func start(_ options: Options) {}
    @inlinable public static func stop() {}
    @inlinable public static func registerHook(_ name: String, _ body: @escaping () -> Void) {}
    @inlinable public static var endpoint: String? { nil }
    #endif
}

#if DEBUG
/// C entry point used when the harness is injected as a dylib.
@_cdecl("PortholeStart")
public func PortholeStartC() {
    if Thread.isMainThread {
        Porthole.start()
    } else {
        DispatchQueue.main.async { Porthole.start() }
    }
}

final class Hooks {
    static let shared = Hooks()
    private let lock = NSLock()
    private var hooks: [String: () -> Void] = [:]

    func register(_ name: String, _ body: @escaping () -> Void) {
        lock.lock()
        hooks[name] = body
        lock.unlock()
        Harness.shared.hooksChanged()
    }

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hooks.keys.sorted()
    }

    func get(_ name: String) -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return hooks[name]
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[Porthole] \(message)\n".utf8))
}

/// Run on the main thread and wait for the result.
func onMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread {
        return try body()
    }
    return try DispatchQueue.main.sync(execute: body)
}
#endif
