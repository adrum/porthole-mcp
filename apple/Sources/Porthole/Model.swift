#if DEBUG
import Foundation
import CoreGraphics

/// One element of the UI tree (protocol v1 Node), plus the platform object
/// behind it so actions can reach it.
final class Node {
    var id = ""
    var role: String
    var name: String?
    var value: Any?
    var states: [String: Bool] = [:]
    var covered = false
    /// Window coordinates, top-left origin.
    var frame: CGRect
    var children: [Node] = []
    /// The accessibility element or view this node came from.
    var element: AnyObject?
    /// The nearest real view at or above the element.
    var view: AnyObject?
    /// The accessibility identifier, if any (before de-duplication).
    var identifier: String?
    /// Accessibility facts for audits (`GET /v1/tree?a11y=1`).
    var a11y: [String: Any]?
    weak var parent: Node?

    init(role: String, frame: CGRect) {
        self.role = role
        self.frame = frame
    }

    func json() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "role": role,
            "frame": ["x": round1(frame.origin.x), "y": round1(frame.origin.y), "w": round1(frame.width), "h": round1(frame.height)],
        ]
        if let name, !name.isEmpty { d["name"] = name }
        if let value { d["value"] = value }
        if !states.isEmpty { d["states"] = states }
        if covered { d["covered"] = true }
        if let a11y, !a11y.isEmpty { d["a11y"] = a11y }
        if !children.isEmpty { d["children"] = children.map { $0.json() } }
        return d
    }

    func walk(_ body: (Node) -> Void) {
        body(self)
        for c in children { c.walk(body) }
    }

    func isDescendant(of other: Node) -> Bool {
        var p = parent
        while let n = p {
            if n === other { return true }
            p = n.parent
        }
        return false
    }
}

private func round1(_ v: CGFloat) -> Double {
    (Double(v) * 10).rounded() / 10
}

/// A built tree plus an id index.
struct Tree {
    let windowId: String
    let root: Node
    let index: [String: Node]

    /// Assign ids: the accessibility identifier when set (duplicates get
    /// `@2`, `@3`, ... in tree order), otherwise a synthesized `_xxx` id that
    /// is stable for the life of the underlying object.
    init(windowId: String, root: Node) {
        var index: [String: Node] = [:]
        var seen: [String: Int] = [:]
        root.walk { n in
            if let ident = n.identifier, !ident.isEmpty {
                let count = (seen[ident] ?? 0) + 1
                seen[ident] = count
                n.id = count == 1 ? ident : "\(ident)@\(count)"
            } else {
                n.id = Identifiers.shared.id(for: n.element ?? n)
            }
            // Should never collide, but never let one node shadow another.
            while index[n.id] != nil { n.id += "'" }
            index[n.id] = n
        }
        root.id = windowId
        index[windowId] = root
        self.windowId = windowId
        self.root = root
        self.index = index
    }

    func node(_ id: String) throws -> Node {
        guard let n = index[id] else {
            throw HarnessError.notFound("no element with id \"\(id)\" in window \(windowId); the UI may have changed, inspect again")
        }
        return n
    }

    func json() -> [String: Any] {
        ["window": windowId, "root": root.json()]
    }
}

/// Synthesized ids, stable for the life of the object they name.
final class Identifiers {
    static let shared = Identifiers()
    private let table = NSMapTable<AnyObject, NSString>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private var next = 1
    private let lock = NSLock()

    func id(for object: AnyObject, prefix: String = "_") -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = table.object(forKey: object) {
            return existing as String
        }
        let id = prefix + String(next, radix: 36)
        next += 1
        table.setObject(id as NSString, forKey: object)
        return id
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var isUsable: Bool { width > 0.5 && height > 0.5 && !isNull && !isInfinite && origin.x.isFinite && origin.y.isFinite }
}

/// Key names from docs/protocol.md.
enum KeyName: String {
    case enter = "Enter", tab = "Tab", escape = "Escape", backspace = "Backspace", delete = "Delete", space = "Space"
    case up = "ArrowUp", down = "ArrowDown", left = "ArrowLeft", right = "ArrowRight"
    case home = "Home", end = "End", pageUp = "PageUp", pageDown = "PageDown"
}

struct Modifiers: OptionSet {
    let rawValue: Int
    static let cmd = Modifiers(rawValue: 1)
    static let shift = Modifiers(rawValue: 2)
    static let alt = Modifiers(rawValue: 4)
    static let ctrl = Modifiers(rawValue: 8)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ names: Any?) throws {
        var m = Modifiers()
        for case let name as String in (names as? [Any]) ?? [] {
            switch name.lowercased() {
            case "cmd", "command", "meta": m.insert(.cmd)
            case "shift": m.insert(.shift)
            case "alt", "option": m.insert(.alt)
            case "ctrl", "control": m.insert(.ctrl)
            default: throw HarnessError.invalid("unknown modifier \"\(name)\"; use cmd, shift, alt or ctrl")
            }
        }
        self = m
    }
}

/// What a platform implements. Tree, windows and screenshot are called on
/// the main thread; `act` is called off the main thread and hops as needed.
protocol Platform: AnyObject {
    var platformName: String { get }
    var isSimulator: Bool { get }
    func toolkits() -> [String]
    func windows() -> [[String: Any]]
    /// With `a11y`, nodes carry accessibility facts and the tree also lists
    /// visible things VoiceOver can't reach.
    func tree(window: String?, a11y: Bool) throws -> Tree
    func screenshot(window: String?, node: String?, scale: CGFloat) throws -> Data
    func act(_ body: [String: Any]) throws -> String
    /// Called once at start on the main thread.
    func prepare()
    /// A cheap hash of what's on screen, for noticing changes (main thread).
    /// Nil when the platform can't compute one.
    func changeSignature() -> Int?
    /// Called off the main thread before a request that needs a window, to
    /// get one on screen first (unhide the app; with `restore`, bring the
    /// window back from the Dock). It waits between visits to the main
    /// thread, so AppKit can actually show the window meanwhile.
    func readyWindows(window: String?, restore: Bool)
}

extension Platform {
    func readyWindows(window: String?, restore: Bool) {}
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }

    func required(_ key: String) throws -> String {
        guard let s = self[key] as? String, !s.isEmpty else {
            throw HarnessError.invalid("missing \"\(key)\"")
        }
        return s
    }

    func number(_ key: String) -> CGFloat? {
        (self[key] as? NSNumber).map { CGFloat($0.doubleValue) }
    }
}

/// Dynamic access to accessibility methods by selector. SwiftUI's private
/// element classes implement the methods without declaring protocol
/// conformance, so Swift casts fail; selectors don't.
enum Dyn {
    static func obj(_ o: NSObject, _ name: String) -> Any? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel) else { return nil }
        return o.perform(sel)?.takeUnretainedValue()
    }

    static func string(_ o: NSObject, _ name: String) -> String? {
        switch obj(o, name) {
        case let s as String: return s.isEmpty ? nil : s
        case let a as NSAttributedString: return a.string.isEmpty ? nil : a.string
        default: return nil
        }
    }

    static func bool(_ o: NSObject, _ name: String) -> Bool? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel), let m = class_getInstanceMethod(type(of: o), sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(m), to: F.self)(o, sel)
    }

    static func rect(_ o: NSObject, _ name: String) -> CGRect? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel), let m = class_getInstanceMethod(type(of: o), sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(method_getImplementation(m), to: F.self)(o, sel)
    }

    static func point(_ o: NSObject, _ name: String) -> CGPoint? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel), let m = class_getInstanceMethod(type(of: o), sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> CGPoint
        return unsafeBitCast(method_getImplementation(m), to: F.self)(o, sel)
    }

    static func uint64(_ o: NSObject, _ name: String) -> UInt64? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel), let m = class_getInstanceMethod(type(of: o), sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> UInt64
        return unsafeBitCast(method_getImplementation(m), to: F.self)(o, sel)
    }

    /// Call a `- (BOOL)name` action method.
    static func perform(_ o: NSObject, _ name: String) -> Bool? {
        bool(o, name)
    }

    static func setBool(_ o: NSObject, _ name: String, _ value: Bool) -> Bool {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel), let m = class_getInstanceMethod(type(of: o), sel) else { return false }
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(m), to: F.self)(o, sel, value)
        return true
    }
}
#endif
