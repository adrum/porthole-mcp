#if DEBUG
import Foundation
import Darwin
import MachO

final class Harness {
    static let shared = Harness()

    private var client: HubClient?
    private var monitor: ChangeMonitor?
    private let lock = NSLock()
    lazy var platform: Platform = makePlatform()

    var endpointDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return client.map { "unix:\($0.socketPath)" }
    }

    func start(_ options: Porthole.Options) {
        lock.lock()
        defer { lock.unlock() }
        guard client == nil else { return }
        let env = ProcessInfo.processInfo.environment
        if env["PORTHOLE_MCP_DISABLE"] == "1" {
            log("disabled by PORTHOLE_MCP_DISABLE")
            return
        }
        // The second guard after #if DEBUG: a configuration that defines DEBUG
        // in a build signed for distribution (a "Staging" or "Beta" scheme)
        // still never connects.
        if let reason = DistributionCheck.refusal() {
            log("not started: \(reason)")
            return
        }
        let path: String
        do {
            path = try SocketDirectory.hubSocketPath(options: options, env: env)
        } catch let e as HarnessError {
            log("not started: \(e.message)")
            return
        } catch {
            log("not started: \(error)")
            return
        }
        let p = platform
        if Thread.isMainThread {
            p.prepare()
        } else {
            DispatchQueue.main.async { p.prepare() }
        }
        let c = HubClient(socketPath: path, hello: { [weak self] in self?.hello() ?? [:] }) { [weak self] method, params in
            guard let self else { throw HarnessError.failed("harness stopped") }
            return try self.handle(method, params)
        }
        client = c
        c.start()
        if env["PORTHOLE_MCP_CAPTURE_LOGS"] != "0" {
            LogCapture.start { [weak c] stream, line in
                c?.notify("log", ["stream": stream, "text": line])
            }
        }
        let m = ChangeMonitor(signature: { p.changeSignature() }) { [weak c] in
            c?.notify("uiChanged", [:])
        }
        monitor = m
        if Thread.isMainThread {
            m.start()
        } else {
            DispatchQueue.main.async { m.start() }
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        client?.stop()
        client = nil
        let m = monitor
        monitor = nil
        DispatchQueue.main.async { m?.stop() }
    }

    /// Tell the hub the hook list changed.
    func hooksChanged() {
        lock.lock()
        let c = client
        lock.unlock()
        c?.notify("hooksChanged", ["hooks": Hooks.shared.names])
    }

    var appId: String {
        Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    }

    var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    func hello() -> [String: Any] {
        let p = platform
        return [
            "protocol": 2,
            "appId": appId,
            "name": appName,
            "pid": Int(getpid()),
            "platform": p.platformName,
            "simulator": p.isSimulator,
            "toolkits": p.toolkits(),
            "capabilities": ["tree", "screenshot", "press", "pressAt", "fill", "key", "focus", "scroll", "hooks"],
            "hooks": Hooks.shared.names,
        ]
    }

    // MARK: requests from the hub

    func handle(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let p = platform
        let window = params["window"] as? String
        // Reading leaves a minimized window in the Dock; drawing and input
        // need it back on screen.
        switch method {
        case "windows", "tree": p.readyWindows(window: window, restore: false)
        case "screenshot", "act": p.readyWindows(window: window, restore: true)
        default: break
        }
        switch method {
        case "windows":
            return ["windows": onMain { p.windows() }]
        case "tree":
            let a11y = params["a11y"] as? Bool ?? false
            let tree = try onMain { try p.tree(window: window, a11y: a11y) }
            return onMain { tree.json() }
        case "screenshot":
            var scale: CGFloat = 1
            if let n = params["scale"] as? NSNumber {
                guard n.doubleValue > 0, n.doubleValue <= 3 else {
                    throw HarnessError.invalid("scale must be a number in (0, 3]")
                }
                scale = CGFloat(n.doubleValue)
            }
            let node = params["node"] as? String
            let png = try onMain { try p.screenshot(window: window, node: node, scale: scale) }
            return ["png": png.base64EncodedString()]
        case "act":
            return ["detail": try p.act(params)]
        case "runHook":
            guard let name = params["name"] as? String, !name.isEmpty else { throw HarnessError.invalid("runHook needs a name") }
            guard let hook = Hooks.shared.get(name) else {
                let known = Hooks.shared.names
                throw HarnessError.notFound("no hook named \"\(name)\"" + (known.isEmpty ? "; the app registered none" : "; registered: \(known.joined(separator: ", "))"))
            }
            onMain { hook() }
            return [:]
        default:
            throw HarnessError.invalid("unknown method \(method)")
        }
    }

    private func makePlatform() -> Platform {
        #if os(macOS)
        return MacPlatform()
        #elseif os(watchOS)
        return WatchPlatform()
        #else
        return IOSPlatform()
        #endif
    }
}

/// Keeps the app connected to the hub: dial, say hello, answer requests in
/// order, and on any failure wait (0.25 s, doubling to 5 s) and dial again,
/// for as long as the app runs.
final class HubClient {
    let socketPath: String
    private let hello: () -> [String: Any]
    private let handler: (String, [String: Any]) throws -> [String: Any]
    private let lock = NSLock()
    private var connection: WebSocketClient?
    private var stopped = false
    private let work = DispatchQueue(label: "porthole-mcp.requests")
    /// Notifications go out in order without blocking the caller (often the
    /// main thread).
    private let outbox = DispatchQueue(label: "porthole-mcp.notifications")
    /// Log lines from before the hub connected, sent once it does.
    private var early: [String] = []

    init(socketPath: String, hello: @escaping () -> [String: Any], handler: @escaping (String, [String: Any]) throws -> [String: Any]) {
        self.socketPath = socketPath
        self.hello = hello
        self.handler = handler
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "porthole-mcp.hub"
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let c = connection
        lock.unlock()
        c?.closeSocket()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func notify(_ method: String, _ params: [String: Any]) {
        let text = Self.json(["jsonrpc": "2.0", "method": method, "params": params])
        outbox.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let c = self.connected ? self.connection : nil
            if c == nil, method == "log", self.early.count < 500 {
                self.early.append(text)
            }
            self.lock.unlock()
            try? c?.send(text: text)
        }
    }

    /// True once `hello` succeeded on the current connection.
    private var connected = false

    static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func run() {
        var delay = 0.25
        var reportedWaiting = false
        while !isStopped {
            do {
                try SocketDirectory.checkHubSocket(socketPath)
                let c = try WebSocketClient(unixPath: socketPath, path: "/v2/app")
                lock.lock()
                connection = c
                lock.unlock()
                let target = try sayHello(c)
                outbox.sync {
                    self.lock.lock()
                    let pending = self.early
                    self.early.removeAll()
                    self.connected = true
                    self.lock.unlock()
                    for text in pending { try? c.send(text: text) }
                }
                log("connected to the porthole-mcp hub as \(target)")
                reportedWaiting = false
                delay = 0.25
                // While an agent may be driving the app, keep macOS from
                // napping it: a covered, backgrounded app would otherwise
                // answer and redraw late, and wait_for would crawl.
                let activity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Porthole: connected to an agent's hub")
                defer { ProcessInfo.processInfo.endActivity(activity) }
                let why = serve(c)
                lock.lock()
                connection = nil
                connected = false
                lock.unlock()
                c.closeSocket()
                if !isStopped { log("lost the hub (\(why)); reconnecting") }
            } catch let e as HarnessError {
                if !reportedWaiting {
                    log("waiting for the porthole-mcp hub at \(socketPath): \(e.message). Start it with porthole-mcp (your agent does this) or porthole-mcp install.")
                    reportedWaiting = true
                }
            } catch {
                if !reportedWaiting {
                    log("waiting for the porthole-mcp hub: \(error)")
                    reportedWaiting = true
                }
            }
            if isStopped { break }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 5)
        }
    }

    private func sayHello(_ c: WebSocketClient) throws -> String {
        try c.send(text: Self.json(["jsonrpc": "2.0", "id": 0, "method": "hello", "params": hello()]))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            switch c.receive() {
            case .text(let text):
                guard let msg = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                if let result = msg["result"] as? [String: Any], let target = result["target"] as? String {
                    return target
                }
                if let error = msg["error"] as? [String: Any] {
                    throw HarnessError.failed("the hub refused hello: \(error["message"] as? String ?? "unknown error")")
                }
            case .closed(let why):
                throw HarnessError.failed(why)
            case .idle:
                continue
            }
        }
        throw HarnessError.failed("the hub didn't answer hello")
    }

    /// Read until the connection ends; requests run in order on `work`, so
    /// pings keep flowing while a long action runs.
    private func serve(_ c: WebSocketClient) -> String {
        while !isStopped {
            switch c.receive() {
            case .idle:
                continue
            case .closed(let why):
                return why
            case .text(let text):
                guard let msg = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let method = msg["method"] as? String else { continue }
                guard let id = msg["id"] else { continue }
                let params = msg["params"] as? [String: Any] ?? [:]
                work.async { [handler] in
                    var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
                    do {
                        reply["result"] = try handler(method, params)
                    } catch let e as HarnessError {
                        reply["error"] = ["code": e.code, "message": e.message, "data": ["kind": e.kind]]
                    } catch {
                        reply["error"] = ["code": -32004, "message": "\(error)", "data": ["kind": "failed"]]
                    }
                    try? c.send(text: Self.json(reply))
                }
            }
        }
        return "stopped"
    }
}

/// True when the app's own code (not just a system framework) links
/// SwiftUI. Xcode Debug builds put the code in a `.debug.dylib` inside
/// the bundle, so every image under the bundle counts.
func appLinksSwiftUI() -> Bool {
    let bundlePath = Bundle.main.bundlePath
    for i in 0..<_dyld_image_count() {
        guard let cname = _dyld_get_image_name(i), let header = _dyld_get_image_header(i) else { continue }
        let path = String(cString: cname)
        guard i == 0 || path.hasPrefix(bundlePath) else { continue }
        if linkedLibraries(header).contains(where: { $0.contains("/SwiftUI.framework/") }) { return true }
    }
    return false
}

/// Install names of the dylibs a Mach-O image links.
func linkedLibraries(_ header: UnsafePointer<mach_header>) -> [String] {
    var out: [String] = []
    let raw = UnsafeRawPointer(header)
    var cursor = raw.advanced(by: MemoryLayout<mach_header_64>.size)
    for _ in 0..<header.pointee.ncmds {
        let cmd = cursor.assumingMemoryBound(to: load_command.self).pointee
        if cmd.cmd == UInt32(LC_LOAD_DYLIB) || cmd.cmd == UInt32(LC_LOAD_WEAK_DYLIB) || cmd.cmd == UInt32(LC_REEXPORT_DYLIB) {
            let dylib = cursor.assumingMemoryBound(to: dylib_command.self).pointee
            let name = cursor.advanced(by: Int(dylib.dylib.name.offset)).assumingMemoryBound(to: CChar.self)
            out.append(String(cString: name))
        }
        cursor = cursor.advanced(by: Int(cmd.cmdsize))
    }
    return out
}

/// True when a framework image with this name is loaded in the process.
func imageLoaded(_ fragment: String) -> Bool {
    for i in 0..<_dyld_image_count() {
        if let name = _dyld_get_image_name(i), strstr(name, fragment) != nil {
            return true
        }
    }
    return false
}
#endif
