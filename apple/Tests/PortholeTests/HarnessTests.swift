import XCTest
import Darwin
@testable import Porthole

final class SocketDirectoryTests: XCTestCase {
    func testHubSocketPathPrecedence() throws {
        XCTAssertEqual(try SocketDirectory.hubSocketPath(options: .init(), env: [:]), "/tmp/porthole-mcp-\(getuid())/hub.sock")
        XCTAssertEqual(try SocketDirectory.hubSocketPath(options: .init(directory: "/tmp/d"), env: [:]), "/tmp/d/hub.sock")
        XCTAssertEqual(try SocketDirectory.hubSocketPath(options: .init(directory: "/tmp/d"), env: ["PORTHOLE_MCP_DIR": "/tmp/e"]), "/tmp/e/hub.sock")
        XCTAssertEqual(try SocketDirectory.hubSocketPath(options: .init(hub: "unix:/tmp/h.sock"), env: ["PORTHOLE_MCP_DIR": "/tmp/e"]), "/tmp/h.sock")
        XCTAssertEqual(try SocketDirectory.hubSocketPath(options: .init(hub: "unix:/tmp/h.sock"), env: ["PORTHOLE_MCP_HUB": "unix:/tmp/x.sock"]), "/tmp/x.sock")
        XCTAssertThrowsError(try SocketDirectory.parse("ws://192.168.1.2:9000"))
        XCTAssertThrowsError(try SocketDirectory.parse("hub.sock"))
    }

    func testOnlyDialsOwnSockets() throws {
        XCTAssertThrowsError(try SocketDirectory.checkHubSocket("/tmp/definitely-missing-\(getpid()).sock")) { e in
            XCTAssertTrue((e as! HarnessError).message.contains("isn't running"))
        }
        let file = "/tmp/aut-file-\(getpid())"
        FileManager.default.createFile(atPath: file, contents: Data())
        defer { unlink(file) }
        XCTAssertThrowsError(try SocketDirectory.checkHubSocket(file)) { e in
            XCTAssertTrue((e as! HarnessError).message.contains("not a socket"))
        }
    }
}

final class WebSocketFrameTests: XCTestCase {
    func testRoundTripsEverySizeClass() throws {
        for size in [0, 5, 125, 126, 300, 65535, 70000] {
            let payload = Data((0..<size).map { UInt8($0 % 251) })
            for masked in [true, false] {
                let frame = WebSocketFrame.encode(.text, payload, masked: masked)
                let decoded = try XCTUnwrap(try WebSocketFrame.decode(frame))
                XCTAssertTrue(decoded.fin)
                XCTAssertEqual(decoded.opcode, WebSocketFrame.Opcode.text.rawValue)
                XCTAssertEqual(decoded.payload, payload)
                XCTAssertEqual(decoded.length, frame.count)
                XCTAssertNil(try WebSocketFrame.decode(frame.prefix(frame.count - 1)), "a partial frame isn't decoded")
            }
        }
    }

    func testAcceptKeyMatchesTheRFCExample() {
        XCTAssertEqual(WebSocketFrame.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}

/// A minimal hub for one connection, written against the same frame code.
private final class FakeHub {
    let path: String
    private let listener: Int32
    private var conn: Int32 = -1
    private var buffer = Data()

    init(path: String? = nil) throws {
        self.path = path ?? "/tmp/aut-hub-\(getpid())-\(UInt32.random(in: 0..<UInt32.max)).sock"
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let b = Array(self.path.utf8)
            raw.copyBytes(from: b)
            raw[b.count] = 0
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0, listen(listener, 1) == 0 else { throw HarnessError.failed("bind") }
    }

    deinit {
        if conn >= 0 { close(conn) }
        close(listener)
        unlink(path)
    }

    private func readMore() throws {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = recv(conn, &chunk, chunk.count, 0)
        guard n > 0 else { throw HarnessError.failed("closed") }
        buffer.append(chunk, count: n)
    }

    /// Accept the harness and finish its upgrade; returns the request head.
    func accept() throws -> String {
        conn = Darwin.accept(listener, nil, nil)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let sep = Data("\r\n\r\n".utf8)
        while buffer.range(of: sep) == nil { try readMore() }
        let end = buffer.range(of: sep)!
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<end.upperBound)
        let key = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }!
            .split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
        let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WebSocketFrame.acceptKey(for: key))\r\n\r\n"
        _ = reply.withCString { Darwin.send(conn, $0, strlen($0), 0) }
        return head
    }

    func receive() throws -> [String: Any] {
        while true {
            if let f = try WebSocketFrame.decode(buffer) {
                buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + f.length)
                if f.opcode == WebSocketFrame.Opcode.text.rawValue {
                    return try JSONSerialization.jsonObject(with: f.payload) as! [String: Any]
                }
                continue
            }
            try readMore()
        }
    }

    func send(_ obj: [String: Any]) throws {
        let frame = WebSocketFrame.encode(.text, try JSONSerialization.data(withJSONObject: obj), masked: false)
        _ = frame.withUnsafeBytes { Darwin.send(conn, $0.baseAddress, $0.count, 0) }
    }
}

/// Run `body` off the main thread while the main run loop turns, as an
/// app's would: the harness does UI work and runs hooks on the main thread.
private func whileMainRuns(_ body: @escaping () throws -> Void) throws {
    var result: Result<Void, Error>?
    DispatchQueue.global().async {
        let r = Result { try body() }
        DispatchQueue.main.async { result = r }
    }
    let deadline = Date().addingTimeInterval(20)
    while result == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    try XCTUnwrap(result).get()
}

final class HubClientTests: XCTestCase {
    func testHelloThenRequestsThenErrors() throws {
        let hub = try FakeHub()
        Porthole.registerHook("t") {}
        let client = HubClient(socketPath: hub.path, hello: { Harness.shared.hello() }) { method, params in
            try Harness.shared.handle(method, params)
        }
        client.start()
        defer { client.stop() }

        try whileMainRuns {
            let head = try hub.accept()
            XCTAssertTrue(head.hasPrefix("GET /v2/app HTTP/1.1"), head)
            let hello = try hub.receive()
            XCTAssertEqual(hello["method"] as? String, "hello")
            let params = try XCTUnwrap(hello["params"] as? [String: Any])
            XCTAssertEqual(params["protocol"] as? Int, 2)
            XCTAssertEqual(params["pid"] as? Int, Int(getpid()))
            XCTAssertEqual(params["platform"] as? String, "macos")
            XCTAssertTrue((params["hooks"] as? [String] ?? []).contains("t"))
            try hub.send(["jsonrpc": "2.0", "id": hello["id"]!, "result": ["protocol": 2, "hub": "test", "target": "x-1"]])

            try hub.send(["jsonrpc": "2.0", "id": 7, "method": "runHook", "params": ["name": "t"]])
            let ok = try hub.receive()
            XCTAssertEqual(ok["id"] as? Int, 7)
            XCTAssertNotNil(ok["result"])

            try hub.send(["jsonrpc": "2.0", "id": 8, "method": "runHook", "params": ["name": "zz"]])
            let missing = try hub.receive()
            let err = try XCTUnwrap(missing["error"] as? [String: Any])
            XCTAssertEqual(err["code"] as? Int, -32001)
            XCTAssertEqual((err["data"] as? [String: Any])?["kind"] as? String, "not_found")
            XCTAssertTrue((err["message"] as? String ?? "").contains("registered: t"))

            try hub.send(["jsonrpc": "2.0", "id": 9, "method": "bogus"])
            let unknown = try hub.receive()
            XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602)
    
        }
    }

    func testReconnectsWhenTheHubAppears() throws {
        let path = "/tmp/aut-late-\(getpid()).sock"
        unlink(path)
        let client = HubClient(socketPath: path, hello: { ["protocol": 2] }) { _, _ in [:] }
        client.start()
        defer { client.stop() }
        Thread.sleep(forTimeInterval: 0.6)
        // The hub starts after the app: the client keeps trying until it does.
        let hub = try FakeHub(path: path)
        let head = try hub.accept()
        XCTAssertTrue(head.hasPrefix("GET /v2/app"))
        XCTAssertEqual(try hub.receive()["method"] as? String, "hello")
    }

    func testEarlyLogLinesArriveAfterHello() throws {
        let hub = try FakeHub()
        let client = HubClient(socketPath: hub.path, hello: { ["protocol": 2] }) { _, _ in [:] }
        // Printed before the hub connection exists.
        client.notify("log", ["stream": "stdout", "text": "booting"])
        client.start()
        defer { client.stop() }
        try whileMainRuns {
            _ = try hub.accept()
            let hello = try hub.receive()
            try hub.send(["jsonrpc": "2.0", "id": hello["id"]!, "result": ["protocol": 2, "hub": "test", "target": "x-1"]])
            let log = try hub.receive()
            XCTAssertEqual(log["method"] as? String, "log")
            XCTAssertEqual((log["params"] as? [String: Any])?["text"] as? String, "booting")
            client.notify("uiChanged", [:])
            XCTAssertEqual(try hub.receive()["method"] as? String, "uiChanged")
        }
    }

    func testChangeMonitorReportsChangedSignatures() {
        var value = 0
        var changes = 0
        let monitor = ChangeMonitor(signature: { value }) { changes += 1 }
        monitor.start()
        defer { monitor.stop() }
        let spin = { (seconds: Double) in RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        spin(0.25)
        XCTAssertEqual(changes, 0, "an unchanged screen reports nothing")
        value = 1
        DispatchQueue.main.async {}
        spin(0.3)
        XCTAssertEqual(changes, 1)
        value = 2
        DispatchQueue.main.async {}
        spin(0.3)
        XCTAssertEqual(changes, 2)
    }

    func testRoleMapping() {
        XCTAssertEqual(MacPlatform.mapRole("AXCheckBox", "AXSwitch"), "switch")
        XCTAssertEqual(MacPlatform.mapRole("AXCheckBox", nil), "checkbox")
        XCTAssertEqual(MacPlatform.mapRole("AXTextField", "AXSecureTextField"), "securefield")
        XCTAssertEqual(MacPlatform.mapRole("AXRadioButton", "AXTabButton"), "tab")
        XCTAssertEqual(MacPlatform.mapRole("AXOutline", nil), "list")
        XCTAssertEqual(MacPlatform.mapRole("AXWhatever", nil), "other")
    }
}
