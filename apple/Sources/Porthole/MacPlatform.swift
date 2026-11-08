#if DEBUG && os(macOS)
import AppKit

/// macOS: the tree comes from NSAccessibility (read in-process through
/// selectors, so SwiftUI's private element classes work too), merged with
/// NSView facts. Actions use accessibility press actions, control actions or
/// events delivered to the window. No system Accessibility permission is used.
final class MacPlatform: Platform {
    let platformName = "macos"
    let isSimulator = false
    private var accessibilityEnabledAt: Date?

    func prepare() {
        enableAccessibility()
    }

    /// SwiftUI builds its accessibility nodes only when an assistive client
    /// is around. Setting AXEnhancedUserInterface on our own NSApp turns that
    /// on in-process.
    private func enableAccessibility() {
        guard accessibilityEnabledAt == nil else { return }
        // Porthole.start() may run before NSApplication exists (a SwiftUI
        // App's init). Try again once the run loop is going.
        guard let app = NSApp else {
            DispatchQueue.main.async { [weak self] in self?.enableAccessibility() }
            return
        }
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        accessibilityEnabledAt = Date()
    }

    private func settleAccessibility() {
        enableAccessibility()
        if let at = accessibilityEnabledAt, Date().timeIntervalSince(at) < 0.4 {
            RunLoop.current.run(until: at.addingTimeInterval(0.4))
        }
    }

    func toolkits() -> [String] {
        var kits = ["appkit"]
        if appLinksSwiftUI() { kits.append("swiftui") }
        return kits
    }

    func changeSignature() -> Int? {
        var h = Hasher()
        var budget = 20000
        func walk(_ v: NSView, _ depth: Int) {
            guard budget > 0, depth < 64, !v.isHidden, v.alphaValue > 0.01 else { return }
            budget -= 1
            let f = v.frame
            h.combine(Int(f.minX.rounded())); h.combine(Int(f.minY.rounded()))
            h.combine(Int(f.width.rounded())); h.combine(Int(f.height.rounded()))
            // Plain AppKit controls may not have layers: hash what they show.
            if let c = v as? NSControl {
                h.combine(c.stringValue)
                h.combine(c.isEnabled)
                if let b = c as? NSButton { h.combine(b.state.rawValue) }
            }
            if let layer = v.layer { hashLayerTree(layer, into: &h, budget: &budget) }
            for s in v.subviews { walk(s, depth + 1) }
        }
        for w in visibleWindows() {
            h.combine(w.windowNumber)
            if let c = w.contentView { walk(c, 0) }
        }
        return h.finalize()
    }

    // MARK: windows

    private func visibleWindows() -> [NSWindow] {
        guard let app = NSApp else { return [] }
        return app.orderedWindows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 1 && $0.frame.height > 1 }
    }

    /// Windows an agent can reach: the visible ones, then the minimized ones.
    /// A hidden app (⌘H) is unhidden first, without activating it, since none
    /// of its windows count as visible while it's hidden.
    private func drivableWindows() -> [NSWindow] {
        guard let app = NSApp else { return [] }
        if app.isHidden {
            app.unhideWithoutActivation()
        }
        func reachable() -> [NSWindow] {
            let visible = visibleWindows()
            let minimized = app.windows.filter { $0.isMiniaturized && $0.contentView != nil && !visible.contains($0) }
            return visible + minimized
        }
        // A window on its way into the Dock, or out of a hidden app, is
        // neither visible nor minimized until the animation ends. Give it
        // time before deciding the app has no windows.
        var windows = reachable()
        let deadline = Date().addingTimeInterval(1.5)
        while windows.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            windows = reachable()
        }
        return windows
    }

    /// A minimized window can't be drawn or take input: restore it, and wait
    /// out the Dock animation.
    private func restoreIfMinimized(_ w: NSWindow) {
        guard w.isMiniaturized else { return }
        w.deminiaturize(nil)
        let deadline = Date().addingTimeInterval(1.5)
        while (w.isMiniaturized || !w.isVisible) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func windowId(_ w: NSWindow) -> String {
        "w\(w.windowNumber)"
    }

    func windows() -> [[String: Any]] {
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return drivableWindows().map { w in
            let f = w.frame
            return [
                "id": windowId(w),
                "title": w.title,
                "key": w.isKeyWindow,
                "minimized": w.isMiniaturized,
                "frame": ["x": f.minX, "y": screenTop - f.maxY, "w": f.width, "h": f.height],
            ]
        }
    }

    private func resolveWindow(_ id: String?) throws -> NSWindow {
        let all = drivableWindows()
        if let id {
            guard let w = all.first(where: { windowId($0) == id }) else {
                let ids = all.map { "\(windowId($0)) \"\($0.title)\"" }.joined(separator: ", ")
                throw HarnessError.notFound("no window \"\(id)\"; windows: \(ids.isEmpty ? "none" : ids)")
            }
            restoreIfMinimized(w)
            return w
        }
        if let key = NSApp?.keyWindow, key.isVisible, key.contentView != nil { return key }
        // No key window (the app is in the background): the frontmost one,
        // or a minimized one when nothing else is open.
        guard let first = all.first else {
            throw HarnessError.notFound("the app has no open windows")
        }
        restoreIfMinimized(first)
        return first.attachedSheet ?? first
    }

    // MARK: tree

    private struct Context {
        let window: NSWindow
        let content: NSView
        /// The content view's rect in screen coordinates (bottom-left origin).
        let contentScreen: CGRect
        let focusedView: NSView?
        var a11y = false
        var elements: [ObjectIdentifier: Node] = [:]

        func toWindow(_ screen: CGRect) -> CGRect {
            CGRect(x: screen.minX - contentScreen.minX,
                   y: contentScreen.maxY - screen.maxY,
                   width: screen.width, height: screen.height)
        }

        func toScreen(_ p: CGPoint) -> CGPoint {
            CGPoint(x: contentScreen.minX + p.x, y: contentScreen.maxY - p.y)
        }
    }

    private static let skippedRoles: Set<String> = ["AXScrollBar", "AXValueIndicator", "AXGrowArea", "AXColumn", "AXIncrementor"]
    private static let actionable: Set<String> = ["button", "link", "textfield", "securefield", "textarea", "checkbox", "switch", "slider", "menuitem", "tab"]

    func tree(window: String?, a11y: Bool) throws -> Tree {
        settleAccessibility()
        let w = try resolveWindow(window)
        let tree = build(w, a11y: a11y)
        if a11y {
            measureContrast(tree.root, pixels: render(w, scale: 2).flatMap { PixelBuffer($0, scale: 2) })
        }
        return tree
    }

    private func build(_ w: NSWindow, a11y: Bool = false) -> Tree {
        let content = w.contentView!
        let contentScreen = w.convertToScreen(content.convert(content.bounds, to: nil))
        var focused: NSView?
        if let tv = w.firstResponder as? NSTextView, tv.isFieldEditor {
            focused = tv.delegate as? NSView
        } else {
            focused = w.firstResponder as? NSView
        }
        var ctx = Context(window: w, content: content, contentScreen: contentScreen, focusedView: focused)
        ctx.a11y = a11y
        let root = Node(role: "window", frame: CGRect(origin: .zero, size: content.bounds.size))
        root.name = w.title.isEmpty ? nil : w.title
        root.element = w
        root.view = content
        if w.firstResponder === w || w.firstResponder == nil {
            // nothing focused
        }
        for k in AXElement(o: content).children {
            visit(k, parent: root, clip: root.frame, host: content, depth: 1, ctx: &ctx)
        }
        let tree = Tree(windowId: windowId(w), root: root)
        markCovered(tree, ctx: ctx)
        return tree
    }

    private func visit(_ obj: Any, parent: Node, clip: CGRect, host: NSView, depth: Int, ctx: inout Context) {
        guard depth < 64, let o = obj as? NSObject else { return }
        if let v = o as? NSView, v.isHiddenOrHasHiddenAncestor || v.alphaValue < 0.01 {
            return
        }
        let ax = AXElement(o: o)
        let axRole = ax.role ?? "AXUnknown"
        if Self.skippedRoles.contains(axRole) { return }
        let subrole = ax.subrole
        let hostView = (o as? NSView) ?? (Dyn.obj(o, "controlView") as? NSView) ?? host
        let kids = ax.children
        let frame = ctx.toWindow(ax.frame)
        guard frame.isUsable else {
            // Zero-size containers still hold visible children.
            for k in kids { visit(k, parent: parent, clip: clip, host: hostView, depth: depth + 1, ctx: &ctx) }
            return
        }
        let visible = frame.intersection(clip)
        guard visible.isUsable else { return }

        let role = Self.mapRole(axRole, subrole)
        let node = Node(role: role, frame: frame)
        node.element = o
        node.view = hostView
        node.identifier = ax.identifier
        describe(node, ax, axRole: axRole, ctx: ctx)
        node.parent = parent
        parent.children.append(node)
        ctx.elements[ObjectIdentifier(o)] = node

        let childClip = (axRole == "AXScrollArea" || role == "list") ? visible : clip
        for k in kids {
            visit(k, parent: node, clip: childClip, host: hostView, depth: depth + 1, ctx: &ctx)
        }
    }

    static func mapRole(_ role: String, _ subrole: String?) -> String {
        switch role {
        case "AXButton", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle":
            return "button"
        case "AXLink": return "link"
        case "AXStaticText", "AXHeading": return "text"
        case "AXTextField", "AXComboBox":
            return subrole == "AXSecureTextField" ? "securefield" : "textfield"
        case "AXTextArea": return "textarea"
        case "AXCheckBox":
            return subrole == "AXSwitch" || subrole == "AXToggle" ? "switch" : "checkbox"
        case "AXRadioButton":
            return subrole == "AXTabButton" ? "tab" : "checkbox"
        case "AXSlider": return "slider"
        case "AXImage": return "image"
        case "AXList", "AXTable", "AXOutline", "AXBrowser", "AXGrid": return "list"
        case "AXRow": return "row"
        case "AXCell": return "cell"
        case "AXMenu", "AXMenuBar": return "menu"
        case "AXMenuItem", "AXMenuBarItem": return "menuitem"
        case "AXScrollArea": return "scrollview"
        case "AXWindow", "AXSheet", "AXDrawer": return "group"
        case "AXGroup", "AXSplitGroup", "AXTabGroup", "AXLayoutArea", "AXLayoutItem", "AXToolbar", "AXRadioGroup", "AXUnknown", "AXSplitter":
            return "group"
        default: return "other"
        }
    }

    private func describe(_ node: Node, _ ax: AXElement, axRole: String, ctx: Context) {
        let label = ax.label
        let title = ax.title
        let raw = ax.value
        var stringValue: String?
        switch raw {
        case let s as String: stringValue = s
        case let a as NSAttributedString: stringValue = a.string
        default: break
        }
        switch node.role {
        case "text":
            node.name = label ?? nonEmpty(stringValue) ?? title
        case "textfield", "securefield", "textarea":
            node.name = label ?? title ?? ax.placeholder
            node.value = stringValue ?? ""
        case "checkbox", "switch":
            node.name = label ?? title
            let on = (raw as? NSNumber)?.intValue ?? 0
            node.value = on != 0
            if on != 0 { node.states["checked"] = true }
        case "slider":
            node.name = label ?? title
            if let n = raw as? NSNumber { node.value = n.doubleValue } else if let s = stringValue { node.value = s }
        default:
            node.name = label ?? title
            if let s = nonEmpty(stringValue), s != node.name {
                if node.name == nil && (node.role == "button" || node.role == "cell" || node.role == "menuitem") {
                    node.name = s
                } else {
                    node.value = s
                }
            } else if let n = raw as? NSNumber, node.role == "tab" {
                node.value = n.intValue != 0
            }
        }
        if Self.actionable.contains(node.role), ax.enabled == false {
            node.states["enabled"] = false
        }
        let isInput = ["textfield", "securefield", "textarea"].contains(node.role)
        if isInput, let f = ctx.focusedView, let v = node.view as? NSView, f === v || f.isDescendant(of: v) {
            node.states["focused"] = true
        } else if !["row", "cell", "group", "list", "window", "scrollview", "text", "other"].contains(node.role),
                  ax.focused == true {
            node.states["focused"] = true
        }
        if ["row", "cell", "tab", "menuitem"].contains(node.role), ax.selected == true {
            node.states["selected"] = true
        }
        if ax.expanded == true {
            node.states["expanded"] = true
        }
        if ctx.a11y {
            node.a11y = a11yFacts(node, ax, axRole: axRole)
        }
    }

    /// What VoiceOver gets for an element, next to what the screen shows.
    private func a11yFacts(_ node: Node, _ ax: AXElement, axRole: String) -> [String: Any] {
        var a: [String: Any] = ["element": true, "role": axRole]
        if let l = ax.label { a["label"] = l }
        if let t = ax.title { a["title"] = t }
        if let h = Dyn.string(ax.o, "accessibilityHelp") { a["hint"] = h }
        if let d = Dyn.string(ax.o, "accessibilityRoleDescription") { a["roleDescription"] = d }
        let control = (node.view as? NSControl) ?? (Dyn.obj(ax.o, "controlView") as? NSControl)
        if let tf = control as? NSTextField, !tf.isEditable, !tf.stringValue.isEmpty {
            a["text"] = tf.stringValue
        } else if let b = control as? NSButton, !b.title.isEmpty {
            a["text"] = b.title
        }
        if let font = control?.font {
            a["font"] = ["size": Double(font.pointSize)]
        }
        return a
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// A node is covered when a click at its center would hit something
    /// that is neither the node, inside it, nor one of its ancestors.
    private func markCovered(_ tree: Tree, ctx: Context) {
        let w = ctx.window
        if w.attachedSheet != nil {
            tree.root.walk { if $0 !== tree.root { $0.covered = true } }
            return
        }
        tree.root.walk { node in
            guard node !== tree.root else { return }
            let visible = node.frame.intersection(tree.root.frame)
            guard visible.isUsable else { return }
            let screen = ctx.toScreen(visible.center)
            guard let hit = Dyn.hitTest(w, screen) else { return }
            var cur: NSObject? = hit
            var hops = 0
            while let c = cur, hops < 40 {
                if let owner = ctx.elements[ObjectIdentifier(c)] {
                    if owner === node || owner.isDescendant(of: node) || node.isDescendant(of: owner) {
                        return
                    }
                    node.covered = true
                    return
                }
                cur = AXElement(o: c).parent
                hops += 1
            }
        }
    }

    // MARK: screenshot

    func screenshot(window: String?, node: String?, scale: CGFloat) throws -> Data {
        let w = try resolveWindow(window)
        guard let content = w.contentView else { throw HarnessError.failed("window has no content view") }
        var crop: CGRect?
        if let node {
            settleAccessibility()
            let tree = build(w)
            crop = try tree.node(node).frame.intersection(tree.root.frame)
            guard crop!.isUsable else { throw HarnessError.failed("element \(node) has no visible area") }
        }
        guard var image = render(w, scale: scale) else { throw HarnessError.failed("rendering produced no image") }
        if let crop {
            let px = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
            guard let cropped = image.cropping(to: px) else { throw HarnessError.failed("crop failed") }
            image = cropped
        }
        let out = NSBitmapImageRep(cgImage: image)
        guard let png = out.representation(using: .png, properties: [:]) else {
            throw HarnessError.failed("PNG encoding failed")
        }
        return png
    }

    /// The window's content rendered in-process (no screen capture).
    private func render(_ w: NSWindow, scale: CGFloat) -> CGImage? {
        guard let content = w.contentView else { return nil }
        let bounds = content.bounds
        let pw = max(1, Int((bounds.width * scale).rounded()))
        let ph = max(1, Int((bounds.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        rep.size = bounds.size
        content.cacheDisplay(in: bounds, to: rep)
        guard let drawn = rep.cgImage else { return nil }
        // The window paints its background outside the content view (SwiftUI
        // leaves it transparent), so composite over it, as on screen.
        var background = NSColor.windowBackgroundColor.cgColor
        w.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = (w.backgroundColor ?? .windowBackgroundColor).usingColorSpace(.deviceRGB)?.cgColor ?? background
        }
        guard let ctx = CGContext(data: nil, width: drawn.width, height: drawn.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return drawn
        }
        let all = CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height)
        ctx.setFillColor(background)
        ctx.fill(all)
        ctx.draw(drawn, in: all)
        drawVibrancy(content, in: ctx, scale: scale, background: background)
        return ctx.makeImage() ?? drawn
    }

    /// cacheDisplay leaves vibrancy out: an NSVisualEffectView's material,
    /// and the vibrant text and icons drawn over it, come out blank, so a
    /// source-list sidebar is an empty rectangle. Redraw each effect view
    /// from its layer tree, which holds that text and those icons, over the
    /// window's background in place of the material behind them.
    private func drawVibrancy(_ content: NSView, in ctx: CGContext, scale: CGFloat, background: CGColor) {
        var effects: [NSVisualEffectView] = []
        func collect(_ v: NSView) {
            if v.isHidden || v.alphaValue < 0.01 { return }
            if let e = v as? NSVisualEffectView {
                effects.append(e)
                return
            }
            for s in v.subviews { collect(s) }
        }
        collect(content)
        for e in effects {
            guard let layer = e.layer else { continue }
            // The effect view's rect in the image, whose origin is at the bottom left.
            let r = e.convert(e.bounds, to: content)
            let y = content.isFlipped ? content.bounds.height - r.maxY : r.minY
            let px = CGRect(x: r.minX * scale, y: y * scale, width: r.width * scale, height: r.height * scale)
            ctx.saveGState()
            ctx.clip(to: px)
            ctx.setFillColor(background)
            ctx.fill(px)
            ctx.translateBy(x: px.minX, y: px.minY)
            ctx.scaleBy(x: scale, y: scale)
            // A layer draws with its origin at the bottom left unless it's
            // flipped; match the y-up image.
            if layer.isGeometryFlipped {
                ctx.translateBy(x: 0, y: r.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            layer.render(in: ctx)
            ctx.restoreGState()
        }
    }

    // MARK: actions

    func act(_ body: [String: Any]) throws -> String {
        let action = try body.required("action")
        let window = body.string("window")
        switch action {
        case "press":
            let id = try body.required("node")
            let (detail, posted) = try onMain { () throws -> (String, Bool) in
                let w = try resolveWindow(window)
                settleAccessibility()
                let tree = build(w)
                return try press(tree.node(id), in: w)
            }
            if posted { settle() }
            return detail
        case "pressAt":
            guard let x = body.number("x"), let y = body.number("y") else {
                throw HarnessError.invalid("pressAt needs numeric x and y")
            }
            try onMain {
                let w = try resolveWindow(window)
                click(CGPoint(x: x, y: y), in: w)
            }
            settle()
            return "clicked at (\(x), \(y))"
        case "fill":
            let id = try body.required("node")
            guard let text = body["text"] as? String else { throw HarnessError.invalid("fill needs \"text\"") }
            return try onMain {
                let w = try resolveWindow(window)
                settleAccessibility()
                let tree = build(w)
                return try fill(tree.node(id), text: text, in: w)
            }
        case "focus":
            let id = try body.required("node")
            return try onMain {
                let w = try resolveWindow(window)
                settleAccessibility()
                let tree = build(w)
                return try focus(tree.node(id), in: w)
            }
        case "key":
            let key = try body.required("key")
            let mods = try Modifiers(body["modifiers"])
            let detail = try onMain { () throws -> String in
                let w = try resolveWindow(window)
                return try sendKey(key, mods, to: w)
            }
            settle()
            return detail
        case "scroll":
            let dx = body.number("dx") ?? 0
            let dy = body.number("dy") ?? 0
            let id = body.string("node")
            return try onMain {
                let w = try resolveWindow(window)
                settleAccessibility()
                let tree = build(w)
                return try scroll(id.map { try tree.node($0) }, dx: dx, dy: dy, in: w)
            }
        default:
            throw HarnessError.invalid("unknown action \"\(action)\"; use press, pressAt, fill, key, focus or scroll")
        }
    }

    /// Let posted events drain before answering.
    private func settle() {
        Thread.sleep(forTimeInterval: 0.05)
        onMain { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func press(_ node: Node, in w: NSWindow) throws -> (String, Bool) {
        guard let o = node.element as? NSObject else { throw HarnessError.failed("element is gone") }
        if node.states["enabled"] == false {
            throw HarnessError.failed("\(node.role) \"\(node.name ?? node.id)\" is disabled")
        }
        // A real control's own action first: its accessibility press can
        // report failure after acting, which would make a fallback act twice.
        if let control = node.view as? NSControl, control === o || Dyn.obj(o, "controlView") as? NSControl === control,
           !(control is NSTextField) {
            control.performClick(nil)
            return ("clicked \(type(of: control))", false)
        }
        if node.role != "window", AXElement(o: o).press() {
            return ("pressed \(node.role) via accessibility", false)
        }
        if node.role == "row" || node.role == "cell" {
            // Select, then also click: SwiftUI list rows run tap handlers on clicks.
            _ = AXElement(o: o).setSelected(true)
        }
        let visible = node.frame.intersection(CGRect(origin: .zero, size: w.contentView!.bounds.size))
        guard visible.isUsable else { throw HarnessError.failed("element is not visible") }
        click(visible.center, in: w)
        return ("clicked at the center of \(node.role)", true)
    }

    private func click(_ p: CGPoint, in w: NSWindow) {
        guard let content = w.contentView else { return }
        let local = NSPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y)
        let wp = content.convert(local, to: nil)
        let ts = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ts,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp?.postEvent(e, atStart: false)
            }
        }
    }

    /// The text view that edits a field node, after making it first responder.
    private func editor(for node: Node, in w: NSWindow) -> NSTextView? {
        if let tv = node.view as? NSTextView {
            w.makeFirstResponder(tv)
            return tv
        }
        if let tf = node.view as? NSTextField {
            if tf.currentEditor() == nil { w.makeFirstResponder(tf) }
            return tf.currentEditor() as? NSTextView
        }
        if let o = node.element as? NSObject {
            _ = AXElement(o: o).setFocused(true)
        }
        if let tv = w.firstResponder as? NSTextView { return tv }
        return nil
    }

    private func fill(_ node: Node, text: String, in w: NSWindow) throws -> String {
        guard ["textfield", "securefield", "textarea"].contains(node.role) || node.view is NSText || node.view is NSTextField else {
            throw HarnessError.unsupported("\(node.role) \"\(node.name ?? node.id)\" is not a text field")
        }
        guard let editor = editor(for: node, in: w) else {
            throw HarnessError.unsupported("could not get a text editor for \(node.role) \"\(node.name ?? node.id)\"")
        }
        editor.selectAll(nil)
        if text.isEmpty {
            if !editor.string.isEmpty { editor.deleteBackward(nil) }
        } else {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        return "typed \(text.count) characters"
    }

    private func focus(_ node: Node, in w: NSWindow) throws -> String {
        if ["textfield", "securefield", "textarea"].contains(node.role), editor(for: node, in: w) != nil {
            return "focused \(node.role)"
        }
        if let v = node.view as? NSView, v.acceptsFirstResponder, v !== w.contentView, w.makeFirstResponder(v) {
            return "focused \(type(of: v))"
        }
        if let o = node.element as? NSObject, AXElement(o: o).setFocused(true) {
            return "focused via accessibility"
        }
        throw HarnessError.unsupported("\(node.role) \"\(node.name ?? node.id)\" can't take focus")
    }

    private static let letterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
    ]

    private func sendKey(_ key: String, _ mods: Modifiers, to w: NSWindow) throws -> String {
        var flags: NSEvent.ModifierFlags = []
        if mods.contains(.cmd) { flags.insert(.command) }
        if mods.contains(.shift) { flags.insert(.shift) }
        if mods.contains(.alt) { flags.insert(.option) }
        if mods.contains(.ctrl) { flags.insert(.control) }
        func fn(_ c: Int) -> String { String(Character(UnicodeScalar(c)!)) }
        let chars: String
        let code: UInt16
        if let named = KeyName(rawValue: key) {
            switch named {
            case .enter: (chars, code) = ("\r", 36)
            case .tab: (chars, code) = ("\t", 48)
            case .escape: (chars, code) = ("\u{1b}", 53)
            case .backspace: (chars, code) = ("\u{7f}", 51)
            case .delete: (chars, code) = (fn(NSDeleteFunctionKey), 117)
            case .space: (chars, code) = (" ", 49)
            case .up: (chars, code) = (fn(NSUpArrowFunctionKey), 126)
            case .down: (chars, code) = (fn(NSDownArrowFunctionKey), 125)
            case .left: (chars, code) = (fn(NSLeftArrowFunctionKey), 123)
            case .right: (chars, code) = (fn(NSRightArrowFunctionKey), 124)
            case .home: (chars, code) = (fn(NSHomeFunctionKey), 115)
            case .end: (chars, code) = (fn(NSEndFunctionKey), 119)
            case .pageUp: (chars, code) = (fn(NSPageUpFunctionKey), 116)
            case .pageDown: (chars, code) = (fn(NSPageDownFunctionKey), 121)
            }
            if [.up, .down, .left, .right].contains(named) { flags.formUnion([.numericPad, .function]) }
            if [.delete, .home, .end, .pageUp, .pageDown].contains(named) { flags.insert(.function) }
        } else if key.count == 1, let c = key.first {
            let lower = Character(c.lowercased())
            chars = mods.contains(.shift) ? c.uppercased() : String(c)
            code = Self.letterCodes[lower] ?? 0
        } else {
            throw HarnessError.invalid("unknown key \"\(key)\"; use Enter, Tab, Escape, Backspace, Delete, Space, arrows, Home, End, PageUp, PageDown, or one character")
        }
        let ignoring = key.count == 1 ? key.lowercased() : chars
        let ts = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ts,
                                          windowNumber: w.windowNumber, context: nil, characters: chars,
                                          charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code),
              let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags, timestamp: ts,
                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) else {
            throw HarnessError.failed("could not create key event")
        }
        // AppKit offers key equivalents to the window before the responder
        // chain: that is how Return reaches the default button and Escape a
        // Cancel button while a field is being edited.
        if flags.contains(.command) || flags.contains(.control) || key == "Enter" || key == "Escape" {
            if w.performKeyEquivalent(with: down) { return "handled as a key equivalent" }
            if NSApp?.mainMenu?.performKeyEquivalent(with: down) == true { return "handled by the menu" }
        }
        w.sendEvent(down)
        w.sendEvent(up)
        let target = w.firstResponder.map { "\(type(of: $0))" } ?? "window"
        return "sent to \(target)"
    }

    private func scrollViews(in v: NSView, into out: inout [NSScrollView]) {
        if v.isHidden { return }
        if let s = v as? NSScrollView { out.append(s) }
        for sub in v.subviews { scrollViews(in: sub, into: &out) }
    }

    private func scroll(_ node: Node?, dx: CGFloat, dy: CGFloat, in w: NSWindow) throws -> String {
        guard let content = w.contentView else { throw HarnessError.failed("window has no content") }
        var target: NSScrollView?
        if let node {
            if let s = node.view as? NSScrollView {
                target = s
            } else if let v = node.view as? NSView, let s = v.enclosingScrollView {
                target = s
            }
            if target == nil || node.role == "scrollview" || node.role == "list" {
                let c = node.frame.intersection(CGRect(origin: .zero, size: content.bounds.size)).center
                let local = NSPoint(x: c.x, y: content.isFlipped ? c.y : content.bounds.height - c.y)
                if let hit = content.hitTest(content.convert(local, to: content.superview)) {
                    target = (hit as? NSScrollView) ?? hit.enclosingScrollView ?? target
                }
            }
        } else {
            var all: [NSScrollView] = []
            scrollViews(in: content, into: &all)
            target = all.filter { !$0.visibleRect.isEmpty }.max { a, b in
                a.visibleRect.width * a.visibleRect.height < b.visibleRect.width * b.visibleRect.height
            }
        }
        guard let sv = target, let doc = sv.documentView else {
            throw HarnessError.unsupported(node == nil ? "no scroll view on screen" : "\(node!.role) \"\(node!.name ?? node!.id)\" is not in a scroll view")
        }
        let clip = sv.contentView
        let before = clip.bounds.origin
        var o = before
        o.x += dx
        o.y += clip.isFlipped ? dy : -dy
        let insets = sv.contentInsets
        let maxX = max(-insets.left, doc.frame.width - clip.bounds.width + insets.right)
        let minY = clip.isFlipped ? -insets.top : -insets.bottom
        let maxY = max(minY, doc.frame.height - clip.bounds.height + (clip.isFlipped ? insets.bottom : insets.top))
        o.x = min(max(o.x, -insets.left), maxX)
        o.y = min(max(o.y, minY), maxY)
        clip.scroll(to: o)
        sv.reflectScrolledClipView(clip)
        let moved = CGPoint(x: clip.bounds.origin.x - before.x, y: (clip.bounds.origin.y - before.y) * (clip.isFlipped ? 1 : -1))
        return "scrolled \(type(of: sv)) by (\(Int(moved.x)), \(Int(moved.y)))"
    }
}

extension Dyn {
    /// `accessibilityHitTest:` takes and returns non-object types on some
    /// classes, so call it through its IMP.
    static func hitTest(_ o: NSObject, _ screenPoint: CGPoint) -> NSObject? {
        let sel = NSSelectorFromString("accessibilityHitTest:")
        guard o.responds(to: sel), let m = class_getInstanceMethod(type(of: o), sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector, CGPoint) -> AnyObject?
        return unsafeBitCast(method_getImplementation(m), to: F.self)(o, sel, screenPoint) as? NSObject
    }
}

/// Reads an accessibility element through the modern selector API when the
/// object implements it (AppKit views, SwiftUI nodes) and the legacy
/// attribute API otherwise (NSTableRow and other old-style elements).
struct AXElement {
    let o: NSObject

    private func modern(_ sel: String) -> Bool { o.responds(to: NSSelectorFromString(sel)) }
    private var legacy: Bool { o.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) }

    private func attr(_ name: String) -> Any? {
        guard legacy else { return nil }
        return o.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: name))
    }

    private func object(_ sel: String, _ legacyName: String) -> Any? {
        if modern(sel) { return Dyn.obj(o, sel) }
        return attr(legacyName)
    }

    private func string(_ sel: String, _ legacyName: String) -> String? {
        switch object(sel, legacyName) {
        case let s as String: return s.isEmpty ? nil : s
        case let a as NSAttributedString: return a.string.isEmpty ? nil : a.string
        default: return nil
        }
    }

    private func flag(_ sel: String, _ legacyName: String) -> Bool? {
        if modern(sel) { return Dyn.bool(o, sel) }
        return (attr(legacyName) as? NSNumber)?.boolValue
    }

    var role: String? { string("accessibilityRole", "AXRole") }
    var subrole: String? { string("accessibilitySubrole", "AXSubrole") }
    /// The element's label, or its control's when it is a cell.
    var label: String? {
        if let l = string("accessibilityLabel", "AXDescription") { return l }
        if let control = Dyn.obj(o, "controlView") as? NSView, Dyn.obj(control, "cell") as AnyObject? === o {
            return Dyn.string(control, "accessibilityLabel")
        }
        return nil
    }
    var title: String? { string("accessibilityTitle", "AXTitle") }
    var placeholder: String? { string("accessibilityPlaceholderValue", "AXPlaceholderValue") }
    var value: Any? { object("accessibilityValue", "AXValue") }
    var parent: NSObject? { object("accessibilityParent", "AXParent") as? NSObject }
    var children: [Any] { (object("accessibilityChildren", "AXChildren") as? [Any]) ?? [] }
    var enabled: Bool? { flag("isAccessibilityEnabled", "AXEnabled") }
    var focused: Bool? { flag("isAccessibilityFocused", "AXFocused") }
    var selected: Bool? { flag("isAccessibilitySelected", "AXSelected") }
    var expanded: Bool? { flag("isAccessibilityExpanded", "AXExpanded") }

    /// The element's own identifier, or its control's when it is a cell.
    var identifier: String? {
        if let id = string("accessibilityIdentifier", "AXIdentifier") { return id }
        if let control = Dyn.obj(o, "controlView") as? NSView, let id = Dyn.string(control, "accessibilityIdentifier") {
            return id
        }
        return nil
    }

    /// Screen frame, bottom-left origin.
    var frame: CGRect {
        if modern("accessibilityFrame") { return Dyn.rect(o, "accessibilityFrame") ?? .zero }
        guard let pos = (attr("AXPosition") as? NSValue)?.pointValue, let size = (attr("AXSize") as? NSValue)?.sizeValue else {
            return .zero
        }
        return CGRect(origin: pos, size: size)
    }

    func press() -> Bool {
        if modern("accessibilityPerformPress") { return Dyn.perform(o, "accessibilityPerformPress") == true }
        guard o.responds(to: NSSelectorFromString("accessibilityPerformAction:")),
              o.responds(to: NSSelectorFromString("accessibilityActionNames")),
              o.accessibilityActionNames().contains(.press) else { return false }
        o.accessibilityPerformAction(.press)
        return true
    }

    func setSelected(_ v: Bool) -> Bool {
        if modern("setAccessibilitySelected:") { return Dyn.setBool(o, "setAccessibilitySelected:", v) }
        guard legacy, o.accessibilityIsAttributeSettable(.selected) else { return false }
        o.accessibilitySetValue(v, forAttribute: .selected)
        return true
    }

    func setFocused(_ v: Bool) -> Bool {
        if modern("setAccessibilityFocused:") { return Dyn.setBool(o, "setAccessibilityFocused:", v) }
        guard legacy, o.accessibilityIsAttributeSettable(.focused) else { return false }
        o.accessibilitySetValue(v, forAttribute: .focused)
        return true
    }
}
#endif
