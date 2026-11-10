#if DEBUG && (os(iOS) || os(tvOS) || os(visionOS))
import UIKit
import PortholeTouch

/// iOS, tvOS and visionOS: the tree merges UIAccessibility elements and
/// containers (SwiftUI's elements included, once accessibility automation is
/// on) with the view hierarchy. On iOS and visionOS presses, drags and
/// scrolls go through the real touch pipeline; tvOS has no touch screen, so
/// presses use the element's own action and keys drive focus. Typing goes
/// through UIKeyInput/UITextInput everywhere.
final class IOSPlatform: Platform {
    #if os(tvOS)
    let platformName = "tvos"
    #elseif os(visionOS)
    let platformName = "visionos"
    #else
    let platformName = "ios"
    #endif
    #if targetEnvironment(simulator)
    let isSimulator = true
    #else
    let isSimulator = false
    #endif
    private var enabledAt: Date?

    func prepare() {
        guard enabledAt == nil else { return }
        let what = PortholeEnableAccessibilityAutomation()
        enabledAt = Date()
        log("accessibility: \(what)")
    }

    private func settleAccessibility() {
        prepare()
        if let at = enabledAt, Date().timeIntervalSince(at) < 0.5 {
            RunLoop.current.run(until: at.addingTimeInterval(0.5))
        }
    }

    func toolkits() -> [String] {
        var kits = ["uikit"]
        if appLinksSwiftUI() { kits.append("swiftui") }
        if ["RCTBridge", "RCTHost", "RCTSurfaceHostingView", "RCTRootView"].contains(where: { NSClassFromString($0) != nil }) {
            kits.append("react-native")
        }
        #if os(iOS) && canImport(CarPlay)
        if CarPlayBridge.shared.isConnected { kits.append("carplay") }
        #endif
        return kits
    }

    func changeSignature() -> Int? {
        var h = Hasher()
        var budget = 20000
        for w in allWindows() {
            h.combine(ObjectIdentifier(w))
            hashLayerTree(w.layer, into: &h, budget: &budget)
        }
        return h.finalize()
    }

    // MARK: windows

    private func isSystemWindow(_ w: UIWindow) -> Bool {
        let name = NSStringFromClass(type(of: w))
        return name.contains("Keyboard") || name.contains("TextEffects") || name.contains("RemoteKeyboard")
    }

    private func allWindows() -> [UIWindow] {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foreground = scenes.filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        var windows = (foreground.isEmpty ? scenes : foreground).flatMap(\.windows)
        #if os(iOS) && canImport(CarPlay)
        // A navigation app's CarPlay map window lives in a CarPlay scene.
        if let car = CarPlayBridge.shared.window, !windows.contains(car) { windows.append(car) }
        #endif
        return windows
            .filter { !$0.isHidden && $0.alpha > 0.01 && !isSystemWindow($0) && $0.bounds.width > 1 }
            .sorted { $0.windowLevel > $1.windowLevel }
    }

    /// Whether the window's scene is in the foreground, on screen.
    private func isForeground(_ w: UIWindow) -> Bool {
        w.windowScene.map { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive } ?? true
    }

    private func windowId(_ w: UIWindow) -> String {
        Identifiers.shared.id(for: w, prefix: "w")
    }

    func windows() -> [[String: Any]] {
        var list = allWindows().map { w -> [String: Any] in
            [
                "id": windowId(w),
                "title": w.windowScene?.title ?? w.rootViewController?.title ?? "",
                "key": w.isKeyWindow,
                "frame": ["x": w.frame.minX, "y": w.frame.minY, "w": w.frame.width, "h": w.frame.height],
                "foreground": isForeground(w),
            ]
        }
        #if os(iOS) && canImport(CarPlay)
        if let car = CarPlayBridge.shared.windowInfo() { list.append(car) }
        #endif
        return list
    }

    private func resolveWindow(_ id: String?) throws -> UIWindow {
        let all = allWindows()
        if let id {
            guard let w = all.first(where: { windowId($0) == id }) else {
                throw HarnessError.notFound("no visible window \"\(id)\"; windows: \(all.map(windowId).joined(separator: ", "))")
            }
            return w
        }
        if let key = all.first(where: \.isKeyWindow) { return key }
        guard let first = all.first else { throw HarnessError.notFound("the app has no visible windows") }
        return first
    }

    // MARK: tree

    private struct Context {
        let window: UIWindow
        let focused: UIView?
        var a11y = false
        var visited = Set<ObjectIdentifier>()
    }

    func tree(window: String?, a11y: Bool) throws -> Tree {
        #if os(iOS) && canImport(CarPlay)
        if window == CarPlayBridge.windowId { return try CarPlayBridge.shared.tree() }
        #endif
        settleAccessibility()
        let w = try resolveWindow(window)
        if a11y {
            // Measure the settled screen, not a frame of a transition.
            waitForWindowStillness(w)
        }
        let tree = build(w, a11y: a11y)
        if a11y {
            measureContrast(tree.root, pixels: render(w, bounds: w.bounds, scale: 2).flatMap { PixelBuffer($0, scale: 2) })
        }
        return tree
    }

    /// Run the main run loop until nothing in the window animates (up to
    /// 1.5 s). The text caret blinks forever, so it doesn't count.
    private func waitForWindowStillness(_ w: UIWindow) {
        func animating(_ v: UIView, _ depth: Int) -> Bool {
            if depth > 40 || v.isHidden { return false }
            let name = NSStringFromClass(type(of: v))
            if name.contains("Caret") || name.contains("Cursor") || name.contains("TextSelection") { return false }
            if let keys = v.layer.animationKeys(), !keys.isEmpty { return true }
            return v.subviews.contains { animating($0, depth + 1) }
        }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, animating(w, 0) || isTransitioning(w) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// True while a view controller in the window is mid-transition (a push,
    /// a presentation). Interruptible transitions run on property animators,
    /// which don't show up as layer animations.
    private func isTransitioning(_ w: UIWindow) -> Bool {
        func check(_ vc: UIViewController?, _ depth: Int) -> Bool {
            guard let vc, depth < 20 else { return false }
            if vc.transitionCoordinator != nil { return true }
            if vc.children.contains(where: { check($0, depth + 1) }) { return true }
            return check(vc.presentedViewController, depth + 1)
        }
        return check(w.rootViewController, 0)
    }

    private func build(_ w: UIWindow, a11y: Bool = false) -> Tree {
        var ctx = Context(window: w, focused: FirstResponder.find() as? UIView)
        ctx.a11y = a11y
        let root = Node(role: "window", frame: w.bounds)
        root.name = w.windowScene?.title.flatMap { $0.isEmpty ? nil : $0 }
        root.element = w
        root.view = w
        ctx.visited.insert(ObjectIdentifier(w))
        for k in children(of: w) {
            visit(k, parent: root, clip: w.bounds, host: w, depth: 1, ctx: &ctx)
        }
        let tree = Tree(windowId: windowId(w), root: root)
        markCovered(tree, window: w)
        return tree
    }

    /// Accessibility children when the object is a container; otherwise its
    /// subviews. Following only one of the two avoids listing SwiftUI and
    /// UIKit controls twice.
    private func children(of o: NSObject) -> [NSObject] {
        if let els = o.accessibilityElements, !els.isEmpty {
            return els.compactMap { $0 as? NSObject }
        }
        let n = o.accessibilityElementCount()
        if n != NSNotFound, n > 0 {
            return (0..<n).compactMap { o.accessibilityElement(at: $0) as? NSObject }
        }
        if let v = o as? UIView {
            return v.subviews
        }
        return []
    }

    private func visit(_ o: NSObject, parent: Node, clip: CGRect, host: UIView, depth: Int, ctx: inout Context) {
        guard depth < 96, !ctx.visited.contains(ObjectIdentifier(o)) else { return }
        ctx.visited.insert(ObjectIdentifier(o))
        let w = ctx.window
        let view = o as? UIView
        if let v = view {
            if v.isHidden || v.alpha < 0.01 { return }
            if v is UIWindow { return }
            let name = NSStringFromClass(type(of: v))
            if name.contains("ScrollIndicator") { return }
        }
        if o.accessibilityElementsHidden {
            // Visible but hidden from VoiceOver: worth knowing in an audit.
            if ctx.a11y, let v = view, let text = visibleText(v) {
                let f = v.convert(v.bounds, to: w)
                if f.intersection(clip).isUsable {
                    let node = Node(role: "text", frame: f)
                    node.name = text
                    node.element = v
                    node.view = v
                    node.a11y = ["element": false, "hiddenFromAccessibility": true, "text": text]
                    node.parent = parent
                    parent.children.append(node)
                }
            }
            return
        }
        let frame: CGRect
        if let v = view {
            frame = v.convert(v.bounds, to: w)
        } else {
            frame = w.convert(o.accessibilityFrame, from: screenSpace(w))
        }
        let hostView = view ?? host
        let isElement = o.isAccessibilityElement
        let kids = isElement ? [] : children(of: o)
        guard frame.isUsable else {
            for k in kids { visit(k, parent: parent, clip: clip, host: hostView, depth: depth + 1, ctx: &ctx) }
            return
        }
        let visible = frame.intersection(clip)
        guard visible.isUsable else { return }
        let childClip = (view?.clipsToBounds ?? false) || view is UIScrollView ? visible : clip

        let identifier = Dyn.string(o, "accessibilityIdentifier")
        let role = Self.role(o, isElement: isElement)
        let structural = ["scrollview", "list", "row", "cell", "tab", "switch", "slider", "textfield", "securefield", "textarea"].contains(role)
        guard isElement || identifier != nil || structural else {
            let before = countNodes(parent)
            for k in kids { visit(k, parent: parent, clip: childClip, host: hostView, depth: depth + 1, ctx: &ctx) }
            // Audits: visible text, or a view that takes touches, that
            // VoiceOver can't reach (nothing under it became an element).
            if ctx.a11y, let v = view, countNodes(parent) == before {
                var facts: [String: Any] = ["element": false]
                var role: String?
                if let text = visibleText(v) {
                    role = "text"
                    facts["text"] = text
                    facts["hiddenFromAccessibility"] = true
                } else if takesTouches(v) {
                    role = "other"
                    facts["unreachable"] = true
                    facts["interactive"] = true
                }
                if let role {
                    let node = Node(role: role, frame: frame)
                    node.name = facts["text"] as? String
                    node.element = v
                    node.view = v
                    node.a11y = facts
                    node.parent = parent
                    parent.children.append(node)
                }
            }
            return
        }
        let node = Node(role: role, frame: frame)
        node.element = o
        node.view = hostView
        // A table row's accessibility proxy and the cell inside it report
        // the same identifier; it belongs to the outer one.
        node.identifier = identifier == parent.identifier ? nil : identifier
        describe(node, o, ctx: ctx)
        node.parent = parent
        parent.children.append(node)
        for k in kids {
            visit(k, parent: node, clip: childClip, host: hostView, depth: depth + 1, ctx: &ctx)
        }
        // An empty container that is neither a view nor an element is
        // bookkeeping (UIKit's hidden navigation toolbar, for one).
        if view == nil, !isElement, node.children.isEmpty {
            parent.children.removeLast()
            return
        }
        // Likewise an empty private UIKit container (iOS 27's floating bar
        // container spans the window and draws nothing).
        if let v = view, !isElement, node.children.isEmpty, NSStringFromClass(type(of: v)).hasPrefix("_UI"), visibleText(v) == nil {
            parent.children.removeLast()
            return
        }
        // A container whose only child is the same element again (React
        // Native's <Text> exposes its text as one fragment) is one node.
        if !isElement, node.children.count == 1, let only = node.children.first, only.children.isEmpty,
           abs(only.frame.minX - node.frame.minX) < 1, abs(only.frame.minY - node.frame.minY) < 1,
           abs(only.frame.width - node.frame.width) < 1, abs(only.frame.height - node.frame.height) < 1,
           node.name != nil, node.name == only.name {
            node.children = []
            node.identifier = node.identifier ?? only.identifier
            if node.role == "group" || node.role == "other" { node.role = only.role }
            node.name = node.name ?? only.name
            node.value = node.value ?? only.value
            node.states.merge(only.states) { a, _ in a }
        }
    }

    /// UIKit's private "toggle" trait, set on SwiftUI Toggles and switches.
    private static let toggleTrait = UIAccessibilityTraits(rawValue: 1 << 53)
    /// Private "text entry" trait.
    private static let textEntryTrait = UIAccessibilityTraits(rawValue: 1 << 18)

    static func role(_ o: NSObject, isElement: Bool) -> String {
        switch o {
        #if !os(tvOS)
        case is UISwitch: return "switch"
        case is UISlider: return "slider"
        #endif
        case let t as UITextField: return t.isSecureTextEntry ? "securefield" : "textfield"
        case let t as UITextView: return isEditable(t) ? "textarea" : "text"
        case is UITableView, is UICollectionView: return "list"
        case is UITableViewCell: return "row"
        case is UICollectionViewCell: return "cell"
        case is UIScrollView: return "scrollview"
        case is UIButton: return "button"
        case is UILabel: return "text"
        case is UIImageView where isElement: return "image"
        default: break
        }
        let name = NSStringFromClass(type(of: o))
        if name.contains("TabBarButton") { return "tab" }
        if name.contains("TableViewCellAccessibilityElement") { return "row" }
        if name.contains("CollectionViewCellAccessibilityElement") { return "cell" }
        let t = o.accessibilityTraits
        if t.contains(toggleTrait) { return "switch" }
        if t.contains(.searchField) || t.contains(textEntryTrait) { return "textfield" }
        if t.contains(.adjustable) { return "slider" }
        if t.contains(.link) { return "link" }
        if t.contains(.button) || t.contains(.keyboardKey) { return t.contains(.tabBar) ? "tab" : "button" }
        if t.contains(.image) { return "image" }
        if t.contains(.tabBar) { return "group" }
        if t.contains(.staticText) || t.contains(.header) { return "text" }
        if isElement { return (o.accessibilityLabel?.isEmpty == false) ? "text" : "other" }
        return "group"
    }

    private func describe(_ node: Node, _ o: NSObject, ctx: Context) {
        let label = o.accessibilityLabel.flatMap { $0.isEmpty ? nil : $0 }
        let axValue = o.accessibilityValue.flatMap { $0.isEmpty ? nil : $0 }
        switch node.role {
        case "textfield", "securefield":
            if let tf = o as? UITextField {
                node.name = (label != tf.text ? label : nil) ?? tf.placeholder
                node.value = tf.text ?? ""
            } else {
                node.name = label
                node.value = axValue ?? ""
            }
        case "textarea":
            node.name = label
            node.value = (o as? UITextView)?.text ?? axValue ?? ""
        case "switch":
            node.name = label
            #if os(tvOS)
            let on = axValue == "1" || axValue?.lowercased() == "on"
            #else
            let on = (o as? UISwitch)?.isOn ?? (axValue == "1" || axValue?.lowercased() == "on")
            #endif
            node.value = on
            if on { node.states["checked"] = true }
        case "slider":
            node.name = label
            #if os(tvOS)
            if let v = axValue { node.value = v }
            #else
            if let s = o as? UISlider { node.value = Double(s.value) } else if let v = axValue { node.value = v }
            #endif
        case "text":
            node.name = label ?? (o as? UILabel)?.text ?? axValue
        default:
            node.name = label
            if let v = axValue, v != label { node.value = v }
        }
        let t = o.accessibilityTraits
        if t.contains(.notEnabled) || (o as? UIControl)?.isEnabled == false {
            node.states["enabled"] = false
        }
        if t.contains(.selected) || ((o as? UIControl)?.isSelected == true && node.role != "switch") {
            node.states["selected"] = true
        }
        if let f = ctx.focused, let v = node.view as? UIView,
           ["textfield", "securefield", "textarea"].contains(node.role), f === v || f.isDescendant(of: v) {
            node.states["focused"] = true
        }
        #if os(tvOS)
        // The focus engine's focused item (what the remote acts on).
        if let item = ctx.window.windowScene?.focusSystem?.focusedItem as? NSObject, item === o {
            node.states["focused"] = true
        }
        #endif
        if ctx.a11y {
            node.a11y = a11yFacts(o)
        }
    }

    private static let traitNames: [(UIAccessibilityTraits, String)] = [
        (.button, "button"), (.link, "link"), (.header, "header"), (.searchField, "searchField"), (.image, "image"),
        (.selected, "selected"), (.playsSound, "playsSound"), (.keyboardKey, "keyboardKey"), (.staticText, "staticText"),
        (.summaryElement, "summaryElement"), (.notEnabled, "notEnabled"), (.updatesFrequently, "updatesFrequently"),
        (.startsMediaSession, "startsMediaSession"), (.adjustable, "adjustable"), (.tabBar, "tabBar"), (toggleTrait, "toggle"),
    ]

    /// What VoiceOver gets for an element, next to what the screen shows.
    private func a11yFacts(_ o: NSObject) -> [String: Any] {
        var a: [String: Any] = ["element": o.isAccessibilityElement, "class": NSStringFromClass(type(of: o))]
        if let l = o.accessibilityLabel, !l.isEmpty { a["label"] = l }
        if let v = o.accessibilityValue, !v.isEmpty { a["value"] = v }
        if let h = o.accessibilityHint, !h.isEmpty { a["hint"] = h }
        let traits = Self.traitNames.filter { o.accessibilityTraits.contains($0.0) }.map(\.1)
        if !traits.isEmpty { a["traits"] = traits }
        if let v = o as? UIView {
            if let text = visibleText(v) {
                a["text"] = text
            } else if !(v is UITextField || v is UITextView) {
                // A view that draws no text has no text contrast to measure.
                a["noText"] = true
            }
            if let font = font(of: v) {
                a["font"] = ["size": Double(font.0.pointSize), "dynamicType": font.1]
            }
        }
        return a
    }

    private func visibleText(_ v: UIView) -> String? {
        let t: String?
        switch v {
        case let l as UILabel: t = l.text
        case let b as UIButton: t = b.currentTitle ?? b.configuration?.title
        case let f as UITextField: t = f.text?.isEmpty == false ? f.text : f.placeholder
        case let tv as UITextView: t = tv.text
        default:
            // React Native's <Text> draws attributed text without a UILabel.
            t = (Dyn.obj(v, "attributedText") as? NSAttributedString)?.string
        }
        guard let t, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return t
    }

    /// The font and whether it follows Dynamic Type.
    private func font(of v: UIView) -> (UIFont, Bool)? {
        switch v {
        case let l as UILabel: return (l.font, l.adjustsFontForContentSizeCategory)
        case let b as UIButton:
            guard let l = b.titleLabel else { return nil }
            return (l.font, l.adjustsFontForContentSizeCategory)
        case let f as UITextField: return f.font.map { ($0, f.adjustsFontForContentSizeCategory) }
        case let t as UITextView: return t.font.map { ($0, t.adjustsFontForContentSizeCategory) }
        default: return nil
        }
    }

    /// A view a person can operate by touch: a control, or one with its own
    /// gesture recognizers (UIKit's private ones don't count).
    private func takesTouches(_ v: UIView) -> Bool {
        guard v.isUserInteractionEnabled else { return false }
        if let c = v as? UIControl, c.isEnabled, !(v is UITextField) { return true }
        return (v.gestureRecognizers ?? []).contains { g in
            g.isEnabled && !NSStringFromClass(type(of: g)).hasPrefix("_") && !(v is UIScrollView)
        }
    }

    private func countNodes(_ n: Node) -> Int {
        var c = 0
        n.walk { _ in c += 1 }
        return c
    }

    /// Covered: a touch at the node's center would land in another window
    /// on top, or on a view outside the node's own view and its ancestors.
    private func markCovered(_ tree: Tree, window w: UIWindow) {
        let above = allWindows().filter { $0 !== w && $0.windowLevel >= w.windowLevel }
        tree.root.walk { node in
            guard node !== tree.root, let view = node.view as? UIView else { return }
            let visible = node.frame.intersection(tree.root.frame)
            guard visible.isUsable else { return }
            let p = visible.center
            for other in above {
                let q = other.convert(p, from: w)
                if let hit = other.hitTest(q, with: nil), hit !== other || other.rootViewController?.view != nil {
                    if hit !== other {
                        node.covered = true
                        return
                    }
                }
            }
            guard let hit = w.hitTest(p, with: nil) else { return }
            if hit === view || hit.isDescendant(of: view) || view.isDescendant(of: hit) { return }
            node.covered = true
        }
    }

    // MARK: screenshot

    func screenshot(window: String?, node: String?, scale: CGFloat) throws -> Data {
        #if os(iOS) && canImport(CarPlay)
        if window == CarPlayBridge.windowId {
            throw HarnessError.unsupported("CarPlay templates are drawn by the system, outside the app, so they can't be rendered in-process; inspect window carplay instead (a navigation app's map window can be captured)")
        }
        #endif
        let w = try resolveWindow(window)
        var bounds = w.bounds
        if let node {
            settleAccessibility()
            let tree = build(w)
            bounds = try tree.node(node).frame.intersection(w.bounds)
            guard bounds.isUsable else { throw HarnessError.failed("element \(node) has no visible area") }
        }
        guard let png = renderImage(w, bounds: bounds, scale: scale).pngData() else {
            throw HarnessError.failed("PNG encoding failed")
        }
        return png
    }

    /// The window drawn in-process (no screen capture).
    private func renderImage(_ w: UIWindow, bounds: CGRect, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        // Behind the window is the system background, as on screen.
        let system = systemBackground(w)
        let background = (w.backgroundColor ?? system).resolvedColor(with: w.traitCollection)
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            system.setFill()
            ctx.fill(bounds)
            background.setFill()
            ctx.fill(bounds)
            // drawHierarchy has the system's render server draw the window
            // now. For a window whose scene isn't in the foreground the
            // render server isn't drawing it, and asking it to (seen on a
            // visionOS Simulator) takes down the Simulator's shell and the
            // app with it. Draw the layers in-process then instead: no
            // render server, at the cost of some system effects.
            if isForeground(w) {
                w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
            } else {
                w.layer.render(in: ctx.cgContext)
            }
        }
    }

    private func render(_ w: UIWindow, bounds: CGRect, scale: CGFloat) -> CGImage? {
        renderImage(w, bounds: bounds, scale: scale).cgImage
    }

    // MARK: actions

    func act(_ body: [String: Any]) throws -> String {
        let action = try body.required("action")
        let window = body.string("window")
        #if os(iOS) && canImport(CarPlay)
        if window == CarPlayBridge.windowId { return try CarPlayBridge.shared.act(body) }
        #endif
        func lookup(_ id: String) throws -> (UIWindow, Node) {
            let (w, node) = try onMain { () throws -> (UIWindow, Node) in
                let w = try resolveWindow(window)
                settleAccessibility()
                return (w, try build(w).node(id))
            }
            // Like a person, wait for the element to stop moving (a sheet
            // sliding in) before acting, then look it up again for its
            // final frame.
            guard waitForStillness(node) else { return (w, node) }
            return try onMain {
                let w = try resolveWindow(window)
                return (w, try build(w).node(id))
            }
        }
        switch action {
        case "press":
            let (w, node) = try lookup(try body.required("node"))
            return try press(node, in: w)
        case "pressAt":
            guard let x = body.number("x"), let y = body.number("y") else {
                throw HarnessError.invalid("pressAt needs numeric x and y")
            }
            let w = try onMain { try resolveWindow(window) }
            try tap(CGPoint(x: x, y: y), in: w)
            return "tapped at (\(x), \(y))"
        case "fill":
            guard let text = body["text"] as? String else { throw HarnessError.invalid("fill needs \"text\"") }
            let (w, node) = try lookup(try body.required("node"))
            return try fill(node, text: text, in: w)
        case "focus":
            let (w, node) = try lookup(try body.required("node"))
            return try focus(node, in: w)
        case "key":
            let key = try body.required("key")
            let mods = try Modifiers(body["modifiers"])
            let detail = try onMain { try sendKey(key, mods) }
            settle(0.1)
            return detail
        case "scroll":
            let dx = body.number("dx") ?? 0
            let dy = body.number("dy") ?? 0
            let w = try onMain { try resolveWindow(window) }
            let node = try body.string("node").map { try lookup($0).1 }
            return try scroll(node, dx: dx, dy: dy, in: w)
        default:
            throw HarnessError.invalid("unknown action \"\(action)\"; use press, pressAt, fill, key, focus or scroll")
        }
    }

    /// True when a layer between the node's view and its window is
    /// animating (a presentation, a push, a scroll settling).
    private func isAnimating(_ node: Node) -> Bool {
        if let w = (node.view as? UIView)?.window, isTransitioning(w) { return true }
        var cur = (node.element as? UIView) ?? (node.view as? UIView)
        while let v = cur {
            if let keys = v.layer.animationKeys(), !keys.isEmpty { return true }
            cur = v.superview
        }
        return false
    }

    /// Wait up to 1.5 s for the node to stop animating. Returns whether it
    /// was animating at first.
    private func waitForStillness(_ node: Node) -> Bool {
        guard onMain({ isAnimating(node) }) else { return false }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, onMain({ isAnimating(node) }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
        onMain {}
    }

    private func systemBackground(_ w: UIWindow) -> UIColor {
        #if os(tvOS)
        return w.traitCollection.userInterfaceStyle == .dark ? .black : .white
        #else
        return UIColor.systemBackground.resolvedColor(with: w.traitCollection)
        #endif
    }

    /// The coordinate space accessibility frames are in.
    private func screenSpace(_ w: UIWindow) -> UICoordinateSpace {
        #if os(visionOS)
        // visionOS has no screen; frames are in the window scene's space.
        return w.windowScene?.coordinateSpace ?? w
        #else
        return w.screen.coordinateSpace
        #endif
    }

    private func touchUnavailable() -> String? {
        #if os(tvOS)
        return "tvOS has no touch screen"
        #else
        return onMain { PortholeTouchSequence.unavailableReason() }
        #endif
    }

    /// A tap through the real touch pipeline: down, a short hold, up.
    private func tap(_ p: CGPoint, in w: UIWindow) throws {
        if let reason = touchUnavailable() {
            throw HarnessError.unsupported("can't synthesize touches here: \(reason). Target an element instead of a point.")
        }
        #if !os(tvOS)
        guard let seq = onMain({ PortholeTouchSequence(window: w, point: p) }) else {
            throw HarnessError.failed("could not start a touch")
        }
        Thread.sleep(forTimeInterval: 0.06)
        onMain { seq.end() }
        settle(0.2)
        #endif
    }

    /// A press without touches: the element's accessibility activation, a
    /// control's primary action, or selecting a table or collection cell
    /// through its delegate (what a remote's select does on tvOS).
    private func pressWithoutTouches(_ node: Node, why: String) throws -> String {
        let done = onMain { () -> String? in
            let o = node.element as? NSObject
            if let o, o.accessibilityActivate() { return "activated \(node.role) via accessibility" }
            if let c = (o as? UIControl) ?? (node.view as? UIControl) {
                let event: UIControl.Event = c.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside
                c.sendActions(for: event)
                return "sent the \(type(of: c))'s primary action"
            }
            var v = (o as? UIView) ?? (node.view as? UIView)
            while let cur = v {
                if let cell = cur as? UICollectionViewCell, let cv = cur.superview(of: UICollectionView.self),
                   let ip = cv.indexPath(for: cell) {
                    cv.selectItem(at: ip, animated: false, scrollPosition: [])
                    cv.delegate?.collectionView?(cv, didSelectItemAt: ip)
                    return "selected collection item \(ip.item)"
                }
                if let cell = cur as? UITableViewCell, let tv = cur.superview(of: UITableView.self),
                   let ip = tv.indexPath(for: cell) {
                    tv.selectRow(at: ip, animated: false, scrollPosition: .none)
                    tv.delegate?.tableView?(tv, didSelectRowAt: ip)
                    return "selected table row \(ip.row)"
                }
                v = cur.superview
            }
            return nil
        }
        guard let done else {
            throw HarnessError.unsupported("can't press \(node.role) \"\(node.name ?? node.id)\": \(why), and it has no activate action, control action or cell to select")
        }
        settle(0.15)
        return done
    }

    private func press(_ node: Node, in w: UIWindow) throws -> String {
        if node.states["enabled"] == false {
            throw HarnessError.failed("\(node.role) \"\(node.name ?? node.id)\" is disabled")
        }
        let (point, activated) = onMain { () -> (CGPoint, Bool) in
            let o = node.element as? NSObject
            // SwiftUI elements have no view of their own; their activate
            // action runs the control (a Toggle's switch, a Button's action).
            if let o, !(o is UIView), node.view !== o, o.accessibilityActivate() {
                return (.zero, true)
            }
            let visible = node.frame.intersection(w.bounds)
            var p = visible.center
            if let o {
                let ap = w.convert(o.accessibilityActivationPoint, from: screenSpace(w))
                if visible.insetBy(dx: -1, dy: -1).contains(ap) { p = ap }
            }
            return (p, false)
        }
        if activated {
            settle(0.15)
            return "activated \(node.role) via accessibility"
        }
        if let reason = touchUnavailable() {
            return try pressWithoutTouches(node, why: reason)
        }
        try tap(point, in: w)
        return "tapped \(node.role) at (\(Int(point.x)), \(Int(point.y)))"
    }

    /// The real text input behind a node: the view itself, a text input
    /// inside it (React Native wraps its field), or one under its center.
    private func textInput(for node: Node, in w: UIWindow) -> (UIResponder & UITextInput)? {
        func search(_ v: UIView, _ depth: Int) -> (UIResponder & UITextInput)? {
            if let t = v as? UITextField { return t }
            if let t = v as? UITextView, isEditable(t) { return t }
            guard depth < 6 else { return nil }
            for s in v.subviews { if let t = search(s, depth + 1) { return t } }
            return nil
        }
        if let v = node.element as? UIView, let t = search(v, 0) { return t }
        var hit = w.hitTest(node.frame.intersection(w.bounds).center, with: nil)
        while let h = hit {
            if let t = search(h, 4) { return t }
            hit = h.superview
            if hit === node.view as? UIView { break }
        }
        if let v = node.view as? UIView, let t = search(v, 0) { return t }
        return nil
    }

    private func focusInput(_ node: Node, in w: UIWindow) throws -> UIResponder & UITextInput {
        if node.states["enabled"] == false {
            throw HarnessError.failed("\(node.role) \"\(node.name ?? node.id)\" is disabled")
        }
        guard let input = onMain({ textInput(for: node, in: w) }) else {
            throw HarnessError.unsupported("\(node.role) \"\(node.name ?? node.id)\" is not a text field")
        }
        if !onMain({ input.isFirstResponder }) {
            // Tap it like a user would, so focus handlers (React Native's
            // onFocus) run; fall back to becoming first responder.
            if touchUnavailable() == nil, let v = input as? UIView {
                let p = onMain { v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: w) }
                try? tap(p, in: w)
            }
            if !onMain({ input.isFirstResponder || input.becomeFirstResponder() }) {
                throw HarnessError.failed("\(node.role) \"\(node.name ?? node.id)\" refused focus")
            }
        }
        return input
    }

    private func fill(_ node: Node, text: String, in w: UIWindow) throws -> String {
        let input = try focusInput(node, in: w)
        onMain {
            if let all = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument), !all.isEmpty {
                input.selectedTextRange = all
                input.deleteBackward()
            }
            if !text.isEmpty {
                input.insertText(text)
            }
        }
        settle(0.15)
        return "typed \(text.count) characters into \(type(of: input))"
    }

    private func focus(_ node: Node, in w: UIWindow) throws -> String {
        let input = try focusInput(node, in: w)
        return "focused \(type(of: input))"
    }

    private func sendKey(_ key: String, _ mods: Modifiers) throws -> String {
        #if os(tvOS)
        // Outside a text field, keys are the remote's buttons.
        if !(FirstResponder.find() is UIKeyInput) {
            return try remoteButton(key)
        }
        #endif
        guard let responder = FirstResponder.find() else {
            throw HarnessError.failed("nothing has keyboard focus; fill or focus a field first")
        }
        if mods.contains(.cmd) && key.count == 1 {
            let actions: [String: Selector] = [
                "a": #selector(UIResponderStandardEditActions.selectAll(_:)),
                "c": #selector(UIResponderStandardEditActions.copy(_:)),
                "x": #selector(UIResponderStandardEditActions.cut(_:)),
                "v": #selector(UIResponderStandardEditActions.paste(_:)),
            ]
            if let sel = actions[key.lowercased()], responder.canPerformAction(sel, withSender: nil) {
                responder.perform(sel, with: nil)
                return "performed cmd+\(key.lowercased())"
            }
            if key.lowercased() == "z", let undo = responder.undoManager, undo.canUndo {
                undo.undo()
                return "undo"
            }
        }
        if !mods.subtracting(.shift).isEmpty {
            throw HarnessError.unsupported("on iOS, keys go through the text-input path; only cmd+a/c/x/v/z are supported with modifiers")
        }
        if let named = KeyName(rawValue: key) {
            if named == .escape {
                responder.resignFirstResponder()
                return "dismissed the keyboard"
            }
            guard let input = responder as? (UIResponder & UITextInput) else {
                throw HarnessError.unsupported("\(type(of: responder)) does not accept text input")
            }
            switch named {
            case .enter:
                return pressReturn(input)
            case .tab: input.insertText("\t")
            case .space: input.insertText(" ")
            case .backspace: input.deleteBackward()
            case .delete:
                if let sel = input.selectedTextRange {
                    if sel.isEmpty, let end = input.position(from: sel.start, offset: 1),
                       let r = input.textRange(from: sel.start, to: end) {
                        input.replace(r, withText: "")
                    } else {
                        input.replace(sel, withText: "")
                    }
                }
            case .left, .right, .up, .down, .home, .end, .pageUp, .pageDown:
                guard let sel = input.selectedTextRange else { break }
                let target: UITextPosition?
                switch named {
                case .left: target = input.position(from: sel.start, offset: -1)
                case .right: target = input.position(from: sel.end, offset: 1)
                case .up: target = input.position(from: sel.start, in: .up, offset: 1)
                case .down: target = input.position(from: sel.end, in: .down, offset: 1)
                case .home, .pageUp: target = input.beginningOfDocument
                default: target = input.endOfDocument
                }
                if let t = target ?? (named == .up ? input.beginningOfDocument : named == .down ? input.endOfDocument : nil) {
                    input.selectedTextRange = input.textRange(from: t, to: t)
                }
            case .escape: break
            }
            return "sent \(key) to \(type(of: input))"
        }
        guard key.count == 1 else {
            throw HarnessError.invalid("unknown key \"\(key)\"; use Enter, Tab, Escape, Backspace, Delete, Space, arrows, Home, End, PageUp, PageDown, or one character")
        }
        guard let input = responder as? UIKeyInput else {
            throw HarnessError.unsupported("\(type(of: responder)) does not accept text input")
        }
        input.insertText(mods.contains(.shift) ? key.uppercased() : key)
        return "typed \(key) into \(type(of: input))"
    }

    #if os(tvOS)
    /// Enter and Space select the focused item; Escape is Menu (dismiss or
    /// go back).
    private func remoteButton(_ key: String) throws -> String {
        guard let w = allWindows().first(where: \.isKeyWindow) ?? allWindows().first else {
            throw HarnessError.notFound("the app has no visible windows")
        }
        switch key {
        case KeyName.enter.rawValue, KeyName.space.rawValue:
            guard let item = w.windowScene?.focusSystem?.focusedItem as? UIView else {
                throw HarnessError.failed("nothing is focused to select")
            }
            let node = Node(role: "other", frame: item.convert(item.bounds, to: w))
            node.element = item
            node.view = item
            return try pressWithoutTouches(node, why: "tvOS has no touch screen")
        case KeyName.escape.rawValue:
            var top = w.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            if let top, top !== w.rootViewController {
                top.dismiss(animated: true)
                return "dismissed \(type(of: top)) (Menu)"
            }
            if let nav = (top as? UINavigationController) ?? top?.navigationController ?? findNavigation(top),
               nav.viewControllers.count > 1 {
                nav.popViewController(animated: true)
                return "went back (Menu)"
            }
            throw HarnessError.unsupported("Menu has nothing to dismiss or go back from")
        case KeyName.up.rawValue, KeyName.down.rawValue, KeyName.left.rawValue, KeyName.right.rawValue:
            throw HarnessError.unsupported("moving tvOS focus with arrow keys isn't supported yet; click the element you want instead")
        default:
            throw HarnessError.unsupported("on tvOS, only Enter, Space and Escape work outside a text field")
        }
    }

    private func findNavigation(_ vc: UIViewController?) -> UINavigationController? {
        guard let vc else { return nil }
        if let nav = vc as? UINavigationController { return nav }
        for child in vc.children {
            if let nav = findNavigation(child) { return nav }
        }
        return nil
    }
    #endif

    /// Return the way the keyboard does: through UIKeyboardImpl when we can,
    /// otherwise the sequence UIKit runs for the return key.
    private func pressReturn(_ input: UIResponder & UITextInput) -> String {
        if PortholeKeyboardType("\n") {
            return "pressed return via the keyboard"
        }
        if let tf = input as? UITextField {
            if tf.delegate?.textFieldShouldReturn?(tf) ?? true {
                tf.sendActions(for: .editingDidEndOnExit)
                tf.sendActions(for: .primaryActionTriggered)
            }
            return "pressed return on UITextField"
        }
        input.insertText("\n")
        return "inserted a newline"
    }

    private func scrollViews(in v: UIView, _ out: inout [UIScrollView]) {
        if v.isHidden || v.alpha < 0.01 { return }
        if let s = v as? UIScrollView, s.isScrollEnabled, !(v is UITextView) { out.append(s) }
        for sub in v.subviews { scrollViews(in: sub, &out) }
    }

    private func findScrollView(_ node: Node?, in w: UIWindow) throws -> UIScrollView {
        try onMain {
            if let node {
                var v: UIView? = node.element as? UIView ?? node.view as? UIView
                if !(v is UIScrollView) {
                    // SwiftUI scroll views are elements without a view: find the
                    // scroll view under the element's center.
                    let hit = w.hitTest(node.frame.intersection(w.bounds).center, with: nil)
                    var h = hit
                    while let c = h, !(c is UIScrollView) { h = c.superview }
                    if let s = h as? UIScrollView { return s }
                    while let c = v, !(c is UIScrollView) { v = c.superview }
                }
                if let s = v as? UIScrollView { return s }
                throw HarnessError.unsupported("\(node.role) \"\(node.name ?? node.id)\" is not in a scroll view")
            }
            var all: [UIScrollView] = []
            scrollViews(in: w, &all)
            let best = all.max { a, b in
                let ra = a.convert(a.bounds, to: w).intersection(w.bounds)
                let rb = b.convert(b.bounds, to: w).intersection(w.bounds)
                return ra.width * ra.height < rb.width * rb.height
            }
            guard let best else { throw HarnessError.unsupported("no scroll view on screen") }
            return best
        }
    }

    /// Scroll with synthesized drags (finger moves opposite to the content),
    /// repeated until the requested distance is covered or content ends.
    private func scroll(_ node: Node?, dx: CGFloat, dy: CGFloat, in w: UIWindow) throws -> String {
        let sv = try findScrollView(node, in: w)
        let (visible, start) = onMain { () -> (CGRect, CGPoint) in
            let r = sv.convert(sv.bounds, to: w).intersection(w.bounds).inset(by: w.safeAreaInsets)
            return (r, sv.contentOffset)
        }
        guard visible.isUsable else { throw HarnessError.failed("the scroll view has no visible area") }
        if touchUnavailable() != nil {
            let moved = onMain { () -> CGPoint in
                let maxX = max(-sv.adjustedContentInset.left, sv.contentSize.width - sv.bounds.width + sv.adjustedContentInset.right)
                let maxY = max(-sv.adjustedContentInset.top, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
                let o = CGPoint(x: min(max(start.x + dx, -sv.adjustedContentInset.left), maxX),
                                y: min(max(start.y + dy, -sv.adjustedContentInset.top), maxY))
                sv.setContentOffset(o, animated: false)
                return CGPoint(x: o.x - start.x, y: o.y - start.y)
            }
            return "scrolled by (\(Int(moved.x)), \(Int(moved.y))) without touches"
        }
        let maxStepX = visible.width * 0.35
        let maxStepY = visible.height * 0.35
        var remaining = CGPoint(x: dx, y: dy)
        for _ in 0..<12 {
            if abs(remaining.x) < 4 && abs(remaining.y) < 4 { break }
            let step = CGPoint(x: max(-maxStepX, min(maxStepX, remaining.x)), y: max(-maxStepY, min(maxStepY, remaining.y)))
            let before = onMain { sv.contentOffset }
            // The pan recognizer swallows its ~10 pt start threshold; add it
            // back so a drag moves the content by the step it was asked for.
            func slop(_ v: CGFloat) -> CGFloat { v == 0 ? 0 : v + (v > 0 ? 10 : -10) }
            try drag(from: visible.center, by: CGPoint(x: -slop(step.x), y: -slop(step.y)), in: w)
            let after = onMain { sv.contentOffset }
            let moved = CGPoint(x: after.x - before.x, y: after.y - before.y)
            if abs(moved.x) < 0.5 && abs(moved.y) < 0.5 { break }
            remaining.x -= moved.x
            remaining.y -= moved.y
        }
        let end = onMain { sv.contentOffset }
        return "dragged \(type(of: sv)) by (\(Int(end.x - start.x)), \(Int(end.y - start.y)))"
    }

    /// One drag: down, a smooth move, a pause so there is no fling, up.
    private func drag(from p: CGPoint, by d: CGPoint, in w: UIWindow) throws {
        #if os(tvOS)
        throw HarnessError.unsupported("tvOS has no touch screen")
        #else
        guard let seq = onMain({ PortholeTouchSequence(window: w, point: p) }) else {
            throw HarnessError.failed("could not start a touch")
        }
        let steps = 12
        for i in 1...steps {
            Thread.sleep(forTimeInterval: 0.016)
            let t = CGFloat(i) / CGFloat(steps)
            onMain { seq.move(to: CGPoint(x: p.x + d.x * t, y: p.y + d.y * t)) }
        }
        let end = CGPoint(x: p.x + d.x, y: p.y + d.y)
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 0.03)
            onMain { seq.move(to: end) }
        }
        onMain { seq.end() }
        settle(0.15)
        #endif
    }
}

/// Finds the first responder with the standard nil-targeted action trick.
enum FirstResponder {
    fileprivate static weak var found: UIResponder?

    static func find() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.porthole_captureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return found
    }
}

extension UIResponder {
    @objc fileprivate func porthole_captureFirstResponder(_ sender: Any?) {
        FirstResponder.found = self
    }
}
#endif

#if DEBUG && (os(iOS) || os(tvOS) || os(visionOS))
/// tvOS text views can't be edited.
func isEditable(_ t: UITextView) -> Bool {
    #if os(tvOS)
    return false
    #else
    return t.isEditable
    #endif
}

extension UIView {
    /// The nearest ancestor of a class.
    func superview<T: UIView>(of type: T.Type) -> T? {
        var v = superview
        while let cur = v {
            if let t = cur as? T { return t }
            v = cur.superview
        }
        return nil
    }
}
#endif
