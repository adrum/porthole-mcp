#if DEBUG && os(watchOS)
import Foundation
import CoreGraphics
import ImageIO
import PortholeTouch

/// watchOS: SwiftUI apps run on a private UIKit that the SDK doesn't
/// expose, so everything goes through the Objective-C runtime by selector.
/// The tree comes from the accessibility elements (with automation on, as
/// on iOS), presses use `accessibilityActivate`, scrolling uses
/// `accessibilityScroll:`, and screenshots render the window's layer.
/// Best effort, and meant for the Simulator.
final class WatchPlatform: Platform {
    let platformName = "watchos"
    #if targetEnvironment(simulator)
    let isSimulator = true
    #else
    let isSimulator = false
    #endif
    private var enabledAt: Date?

    func prepare() {
        guard enabledAt == nil else { return }
        log("accessibility: \(PortholeEnableAccessibilityAutomation())")
        enabledAt = Date()
    }

    private func settleAccessibility() {
        prepare()
        if let at = enabledAt, Date().timeIntervalSince(at) < 0.5 {
            RunLoop.current.run(until: at.addingTimeInterval(0.5))
        }
    }

    func toolkits() -> [String] {
        appLinksSwiftUI() ? ["swiftui"] : ["watchkit"]
    }

    /// No public QuartzCore on watchOS: the hub polls instead.
    func changeSignature() -> Int? { nil }

    // MARK: windows

    private func application() -> NSObject? {
        guard let cls = NSClassFromString("UIApplication") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("sharedApplication")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    private func allWindows() -> [NSObject] {
        guard let app = application(), let windows = Dyn.obj(app, "windows") as? [NSObject] else { return [] }
        return windows.filter { Dyn.bool($0, "isHidden") != true && (Dyn.rect($0, "bounds")?.width ?? 0) > 1 }
    }

    private func windowId(_ w: NSObject) -> String {
        Identifiers.shared.id(for: w, prefix: "w")
    }

    func windows() -> [[String: Any]] {
        allWindows().map { w in
            let f = Dyn.rect(w, "frame") ?? .zero
            return [
                "id": windowId(w),
                "title": "",
                "key": Dyn.bool(w, "isKeyWindow") ?? false,
                "frame": ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height],
            ]
        }
    }

    private func resolveWindow(_ id: String?) throws -> NSObject {
        let all = allWindows()
        if let id {
            guard let w = all.first(where: { windowId($0) == id }) else {
                throw HarnessError.notFound("no visible window \"\(id)\"")
            }
            return w
        }
        guard let w = all.first(where: { Dyn.bool($0, "isKeyWindow") == true }) ?? all.first else {
            throw HarnessError.notFound("the app has no visible windows (or watchOS doesn't expose them to the harness)")
        }
        return w
    }

    // MARK: tree

    private static let traits: [(UInt64, String)] = [
        (1 << 0, "button"), (1 << 1, "link"), (1 << 2, "image"), (1 << 3, "selected"), (1 << 6, "staticText"),
        (1 << 8, "notEnabled"), (1 << 10, "searchField"), (1 << 12, "adjustable"), (1 << 16, "header"), (1 << 53, "toggle"),
    ]

    func tree(window: String?, a11y: Bool) throws -> Tree {
        settleAccessibility()
        let w = try resolveWindow(window)
        let bounds = Dyn.rect(w, "bounds") ?? .zero
        let root = Node(role: "window", frame: CGRect(origin: .zero, size: bounds.size))
        root.element = w
        var visited = Set<ObjectIdentifier>([ObjectIdentifier(w)])
        for k in children(of: w) {
            visit(k, parent: root, clip: root.frame, a11y: a11y, depth: 1, visited: &visited)
        }
        let tree = Tree(windowId: windowId(w), root: root)
        if a11y {
            measureContrast(root, pixels: render(w, scale: 2).flatMap { PixelBuffer($0, scale: 2) })
        }
        return tree
    }

    private func children(of o: NSObject) -> [NSObject] {
        if let els = Dyn.obj(o, "accessibilityElements") as? [NSObject], !els.isEmpty { return els }
        if let n = Dyn.int(o, "accessibilityElementCount"), n > 0, n != NSNotFound {
            return (0..<n).compactMap { Dyn.objAt(o, "accessibilityElementAtIndex:", $0) as? NSObject }
        }
        return (Dyn.obj(o, "subviews") as? [NSObject]) ?? []
    }

    private func visit(_ o: NSObject, parent: Node, clip: CGRect, a11y: Bool, depth: Int, visited: inout Set<ObjectIdentifier>) {
        guard depth < 96, !visited.contains(ObjectIdentifier(o)) else { return }
        visited.insert(ObjectIdentifier(o))
        if Dyn.bool(o, "isHidden") == true || Dyn.bool(o, "accessibilityElementsHidden") == true { return }
        let isElement = Dyn.bool(o, "isAccessibilityElement") ?? false
        let kids = isElement ? [] : children(of: o)
        let frame = Dyn.rect(o, "accessibilityFrame") ?? .zero
        guard frame.isUsable else {
            for k in kids { visit(k, parent: parent, clip: clip, a11y: a11y, depth: depth + 1, visited: &visited) }
            return
        }
        guard frame.intersection(clip).isUsable else { return }
        let identifier = Dyn.string(o, "accessibilityIdentifier")
        guard isElement || identifier != nil else {
            for k in kids { visit(k, parent: parent, clip: clip, a11y: a11y, depth: depth + 1, visited: &visited) }
            return
        }
        let traits = Dyn.uint64(o, "accessibilityTraits") ?? 0
        let label = Dyn.string(o, "accessibilityLabel")
        let value = Dyn.string(o, "accessibilityValue")
        let node = Node(role: Self.role(traits, isElement: isElement, label: label), frame: frame)
        node.element = o
        node.identifier = identifier
        node.name = label
        switch node.role {
        case "switch":
            let on = value == "1" || value?.lowercased() == "on"
            node.value = on
            if on { node.states["checked"] = true }
        case "textfield":
            node.value = value ?? ""
        default:
            if let value, value != label { node.value = value }
        }
        if traits & (1 << 8) != 0 { node.states["enabled"] = false }
        if traits & (1 << 3) != 0 { node.states["selected"] = true }
        if a11y {
            var facts: [String: Any] = ["element": isElement, "class": NSStringFromClass(type(of: o))]
            if let label { facts["label"] = label }
            if let value { facts["value"] = value }
            if let hint = Dyn.string(o, "accessibilityHint") { facts["hint"] = hint }
            let names = Self.traits.filter { traits & $0.0 != 0 }.map(\.1)
            if !names.isEmpty { facts["traits"] = names }
            node.a11y = facts
        }
        node.parent = parent
        parent.children.append(node)
        for k in kids { visit(k, parent: node, clip: clip, a11y: a11y, depth: depth + 1, visited: &visited) }
    }

    static func role(_ t: UInt64, isElement: Bool, label: String?) -> String {
        if t & (1 << 53) != 0 { return "switch" }
        if t & (1 << 10) != 0 || t & (1 << 18) != 0 { return "textfield" }
        if t & (1 << 12) != 0 { return "slider" }
        if t & (1 << 1) != 0 { return "link" }
        if t & (1 << 0) != 0 { return "button" }
        if t & (1 << 2) != 0 { return "image" }
        if t & (1 << 6) != 0 || t & (1 << 16) != 0 { return "text" }
        if isElement { return label == nil ? "other" : "text" }
        return "group"
    }

    // MARK: screenshot

    /// The window's layer rendered into a bitmap (top-left origin).
    private func render(_ w: NSObject, scale: CGFloat) -> CGImage? {
        guard let layer = Dyn.obj(w, "layer") as? NSObject, let bounds = Dyn.rect(w, "bounds") else { return nil }
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The watch draws on black.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let sel = NSSelectorFromString("renderInContext:")
        guard layer.responds(to: sel), let m = class_getInstanceMethod(type(of: layer), sel) else { return nil }
        typealias Render = @convention(c) (AnyObject, Selector, CGContext) -> Void
        unsafeBitCast(method_getImplementation(m), to: Render.self)(layer, sel, ctx)
        return ctx.makeImage()
    }

    func screenshot(window: String?, node: String?, scale: CGFloat) throws -> Data {
        let w = try resolveWindow(window)
        guard var image = render(w, scale: scale) else {
            throw HarnessError.unsupported("this watchOS doesn't let the harness render the window")
        }
        if let node {
            settleAccessibility()
            let tree = try self.tree(window: window, a11y: false)
            let f = try tree.node(node).frame
            let px = CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale).integral
            guard let cropped = image.cropping(to: px) else { throw HarnessError.failed("crop failed") }
            image = cropped
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw HarnessError.failed("PNG encoding failed")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw HarnessError.failed("PNG encoding failed") }
        return data as Data
    }

    // MARK: actions

    func act(_ body: [String: Any]) throws -> String {
        let action = try body.required("action")
        let window = body.string("window")
        func lookup() throws -> Node {
            try onMain { try tree(window: window, a11y: false).node(try body.required("node")) }
        }
        switch action {
        case "press":
            let node = try lookup()
            if node.states["enabled"] == false {
                throw HarnessError.failed("\(node.role) \"\(node.name ?? node.id)\" is disabled")
            }
            let ok = onMain { (node.element as? NSObject).flatMap { Dyn.perform($0, "accessibilityActivate") } ?? false }
            guard ok else {
                throw HarnessError.unsupported("\(node.role) \"\(node.name ?? node.id)\" has no activate action; watchOS has no touch synthesis yet")
            }
            Thread.sleep(forTimeInterval: 0.15)
            onMain {}
            return "activated \(node.role) via accessibility"
        case "scroll":
            let dy = body.number("dy") ?? 0
            let dx = body.number("dx") ?? 0
            // UIAccessibilityScrollDirection: right 1, left 2, up 3, down 4.
            let direction = abs(dy) >= abs(dx) ? (dy > 0 ? 4 : 3) : (dx > 0 ? 1 : 2)
            let start: Node? = try body.string("node").map { _ in try lookup() }
            let scrolled = try onMain { () -> Bool in
                var cur: Node? = try start ?? tree(window: window, a11y: false).root
                while let n = cur {
                    if let o = n.element as? NSObject, Dyn.boolWithInt(o, "accessibilityScroll:", direction) == true { return true }
                    cur = n.parent
                }
                return false
            }
            guard scrolled else { throw HarnessError.unsupported("nothing here scrolls through accessibility") }
            return "scrolled a page \(["", "right", "left", "up", "down"][direction])"
        case "pressAt", "fill", "key", "focus":
            throw HarnessError.unsupported("watchOS supports press and scroll; \(action) needs touch or keyboard synthesis, which the harness doesn't have on watchOS yet")
        default:
            throw HarnessError.invalid("unknown action \"\(action)\"")
        }
    }
}

extension Dyn {
    static func int(_ o: NSObject, _ name: String) -> Int? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel), let m = class_getInstanceMethod(type(of: o), sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(method_getImplementation(m), to: F.self)(o, sel)
    }

    static func objAt(_ o: NSObject, _ name: String, _ index: Int) -> AnyObject? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel), let m = class_getInstanceMethod(type(of: o), sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, Int) -> AnyObject?
        return unsafeBitCast(method_getImplementation(m), to: F.self)(o, sel, index)
    }

    static func boolWithInt(_ o: NSObject, _ name: String, _ arg: Int) -> Bool? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel), let m = class_getInstanceMethod(type(of: o), sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, Int) -> Bool
        return unsafeBitCast(method_getImplementation(m), to: F.self)(o, sel, arg)
    }
}
#endif
