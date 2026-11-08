#if DEBUG
import Foundation
import Darwin
#if canImport(QuartzCore) && !os(watchOS)
import QuartzCore
#endif

/// Tells the hub when something on screen changed: after each turn of the
/// main run loop (at most ten times a second) it hashes the visible windows'
/// layer trees and sends `uiChanged` when the hash moved.
final class ChangeMonitor {
    private let signature: () -> Int?
    private let changed: () -> Void
    private var observer: CFRunLoopObserver?
    private var last: Int?
    private var lastCheck: CFAbsoluteTime = 0
    private var deferred = false
    private let interval: CFAbsoluteTime = 0.1

    init(signature: @escaping () -> Int?, changed: @escaping () -> Void) {
        self.signature = signature
        self.changed = changed
    }

    /// Call on the main thread.
    func start() {
        guard observer == nil else { return }
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] _, _ in
            self?.tick()
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let wait = interval - (now - lastCheck)
        if wait > 0 {
            // Too soon: check once more when the interval is up, so the last
            // change before the run loop goes idle isn't missed.
            if !deferred {
                deferred = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.deferred = false
                    self?.tick()
                }
            }
            return
        }
        lastCheck = now
        guard let sig = signature() else { return }
        if let last, last != sig { changed() }
        last = sig
    }
}

#if canImport(QuartzCore) && !os(watchOS)
/// A hash of what a layer tree shows: geometry, visibility and the identity
/// of each layer's contents (a redraw replaces them). Layers narrower than
/// 4 points, like a blinking text caret, are skipped.
func hashLayerTree(_ layer: CALayer, into h: inout Hasher, depth: Int = 0, budget: inout Int) {
    guard budget > 0, depth < 64, !layer.isHidden, layer.opacity > 0.01 else { return }
    budget -= 1
    let b = layer.bounds
    if b.width >= 4 {
        h.combine(Int(b.width.rounded()))
        h.combine(Int(b.height.rounded()))
        h.combine(Int(layer.position.x.rounded()))
        h.combine(Int(layer.position.y.rounded()))
        h.combine(Int((layer.opacity * 10).rounded()))
        if let c = layer.contents as AnyObject? { h.combine(ObjectIdentifier(c)) }
        if let t = layer as? CATextLayer, let s = t.string as? String { h.combine(s) }
    }
    for sub in layer.sublayers ?? [] {
        hashLayerTree(sub, into: &h, depth: depth + 1, budget: &budget)
    }
}
#endif

/// Copies what the app writes to stdout and stderr to the hub, still
/// passing it through to the original destination (the Xcode console).
enum LogCapture {
    private static var started = false
    private static let maxPerSecond = 200

    static func start(_ send: @escaping (_ stream: String, _ line: String) -> Void) {
        guard !started else { return }
        started = true
        for (fd, name) in [(STDOUT_FILENO, "stdout"), (STDERR_FILENO, "stderr")] {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { continue }
            let original = dup(fd)
            guard original >= 0, dup2(fds[1], fd) >= 0 else {
                close(fds[0]); close(fds[1])
                continue
            }
            close(fds[1])
            if fd == STDOUT_FILENO {
                // A pipe would make stdout fully buffered; keep print() timely.
                setvbuf(stdout, nil, _IOLBF, 0)
            }
            let reader = fds[0]
            let thread = Thread {
                pump(reader: reader, passthrough: original, stream: name, send: send)
            }
            thread.name = "porthole-mcp.\(name)"
            thread.start()
        }
    }

    private static func pump(reader: Int32, passthrough: Int32, stream: String, send: (String, String) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        var windowStart = Date()
        var sentInWindow = 0
        var dropped = 0
        while true {
            let n = read(reader, &chunk, chunk.count)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return
            }
            _ = chunk.withUnsafeBytes { write(passthrough, $0.baseAddress, n) }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if Date().timeIntervalSince(windowStart) >= 1 {
                    if dropped > 0 { send(stream, "[porthole-mcp skipped \(dropped) lines]") }
                    windowStart = Date()
                    sentInWindow = 0
                    dropped = 0
                }
                if sentInWindow < maxPerSecond {
                    sentInWindow += 1
                    send(stream, line)
                } else {
                    dropped += 1
                }
            }
            if buffer.count > 65536 {
                // A very long line without a newline: send what we have.
                send(stream, String(decoding: buffer, as: UTF8.self))
                buffer.removeAll()
            }
        }
    }
}
#endif
