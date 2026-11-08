#if DEBUG
import Foundation
import Darwin
import CryptoKit

/// A failure the hub reports to the agent. `kind` and `code` follow
/// docs/protocol.md; `message` says what to do next where it can.
struct HarnessError: Error {
    let kind: String
    let code: Int
    let message: String

    static func notFound(_ m: String) -> HarnessError { HarnessError(kind: "not_found", code: -32001, message: m) }
    static func invalid(_ m: String) -> HarnessError { HarnessError(kind: "invalid_request", code: -32602, message: m) }
    static func unsupported(_ m: String) -> HarnessError { HarnessError(kind: "unsupported", code: -32003, message: m) }
    static func failed(_ m: String) -> HarnessError { HarnessError(kind: "failed", code: -32004, message: m) }
}

/// WebSocket frames (RFC 6455): enough for JSON text messages, pings and
/// closes. Clients mask what they send; servers don't.
enum WebSocketFrame {
    enum Opcode: UInt8 {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    static func encode(_ opcode: Opcode, _ payload: Data, masked: Bool) -> Data {
        var out = Data([0x80 | opcode.rawValue])
        let maskBit: UInt8 = masked ? 0x80 : 0
        let n = payload.count
        if n < 126 {
            out.append(maskBit | UInt8(n))
        } else if n <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8(n >> 8))
            out.append(UInt8(n & 0xFF))
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF)) }
        }
        if masked {
            var key = [UInt8](repeating: 0, count: 4)
            for i in 0..<4 { key[i] = UInt8.random(in: 0...255) }
            out.append(contentsOf: key)
            var body = [UInt8](payload)
            for i in 0..<body.count { body[i] ^= key[i % 4] }
            out.append(contentsOf: body)
        } else {
            out.append(payload)
        }
        return out
    }

    struct Decoded {
        let fin: Bool
        let opcode: UInt8
        let payload: Data
        let length: Int
    }

    /// One frame from the start of `buffer`, or nil if it isn't complete yet.
    static func decode(_ buffer: Data) throws -> Decoded? {
        let b = [UInt8](buffer.prefix(14))
        guard b.count >= 2 else { return nil }
        let fin = b[0] & 0x80 != 0
        let opcode = b[0] & 0x0F
        let masked = b[1] & 0x80 != 0
        var length = Int(b[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = Int(b[2]) << 8 | Int(b[3])
            offset = 4
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            var n: UInt64 = 0
            for i in 2..<10 { n = n << 8 | UInt64(b[i]) }
            guard n < UInt64(64 << 20) else { throw HarnessError.invalid("WebSocket frame too large") }
            length = Int(n)
            offset = 10
        }
        var key: [UInt8] = []
        if masked {
            guard b.count >= offset + 4 else { return nil }
            key = Array(b[offset..<offset + 4])
            offset += 4
        }
        guard buffer.count >= offset + length else { return nil }
        let start = buffer.startIndex + offset
        var payload = [UInt8](buffer[start..<start + length])
        if masked {
            for i in 0..<payload.count { payload[i] ^= key[i % 4] }
        }
        return Decoded(fin: fin, opcode: opcode, payload: Data(payload), length: offset + length)
    }

    static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }
}

/// A client WebSocket over a Unix socket, used from one reader thread with
/// sends from any thread.
final class WebSocketClient {
    enum Event {
        case text(String)
        case closed(String)
        case idle
    }

    private let fd: Int32
    private var buffer = Data()
    private var fragments = Data()
    private let writeLock = NSLock()
    private var isClosed = false

    /// Connect to a Unix socket and upgrade `path`.
    init(unixPath: String, path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HarnessError.failed("socket: \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(unixPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw HarnessError.failed("hub socket path too long: \(unixPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else {
            let e = String(cString: strerror(errno))
            close(fd)
            throw HarnessError.failed("connect \(unixPath): \(e)")
        }
        do {
            try handshake(path: path)
        } catch {
            close(fd)
            throw error
        }
        // Reads time out so the reader thread can notice a stop request.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        closeSocket()
    }

    private func handshake(path: String) throws {
        var keyBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { keyBytes[i] = UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        let request = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try writeAll(Data(request.utf8))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard try readMore() else { throw HarnessError.failed("the hub closed the connection during the handshake") }
            if buffer.count > 16384 { throw HarnessError.failed("handshake reply too large") }
        }
        let end = buffer.range(of: separator)!
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<end.upperBound)
        guard head.hasPrefix("HTTP/1.1 101") else {
            throw HarnessError.failed("the hub refused the upgrade: \(head.split(separator: "\r\n").first ?? "")")
        }
        let accept = head.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-accept:") }
            .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) }
        guard accept == WebSocketFrame.acceptKey(for: key) else {
            throw HarnessError.failed("the hub's handshake reply has the wrong Sec-WebSocket-Accept")
        }
    }

    /// Read whatever is available into the buffer. False when the peer closed.
    private func readMore() throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &chunk, chunk.count, 0)
        if n > 0 {
            buffer.append(chunk, count: n)
            return true
        }
        if n == 0 { return false }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { throw TimedOut() }
        throw HarnessError.failed("read: \(String(cString: strerror(errno)))")
    }

    private struct TimedOut: Error {}

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw HarnessError.failed("write: \(String(cString: strerror(errno)))")
                }
                sent += n
            }
        }
    }

    func send(text: String) throws {
        try send(.text, Data(text.utf8))
    }

    private func send(_ opcode: WebSocketFrame.Opcode, _ payload: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { throw HarnessError.failed("the hub connection is closed") }
        try writeAll(WebSocketFrame.encode(opcode, payload, masked: true))
    }

    /// The next text message, `.idle` after a second with nothing, or
    /// `.closed`. Answers pings itself.
    func receive() -> Event {
        while true {
            do {
                if let frame = try WebSocketFrame.decode(buffer) {
                    buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + frame.length)
                    switch frame.opcode {
                    case WebSocketFrame.Opcode.text.rawValue, WebSocketFrame.Opcode.continuation.rawValue,
                         WebSocketFrame.Opcode.binary.rawValue:
                        fragments.append(frame.payload)
                        if frame.fin {
                            let text = String(decoding: fragments, as: UTF8.self)
                            fragments.removeAll()
                            return .text(text)
                        }
                    case WebSocketFrame.Opcode.ping.rawValue:
                        try? send(.pong, frame.payload)
                    case WebSocketFrame.Opcode.close.rawValue:
                        try? send(.close, Data())
                        return .closed("the hub closed the connection")
                    default:
                        break
                    }
                    continue
                }
                guard try readMore() else { return .closed("the hub went away") }
            } catch is TimedOut {
                return .idle
            } catch let e as HarnessError {
                return .closed(e.message)
            } catch {
                return .closed("\(error)")
            }
        }
    }

    func closeSocket() {
        writeLock.lock()
        defer { writeLock.unlock() }
        if !isClosed {
            isClosed = true
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }
}
#endif
