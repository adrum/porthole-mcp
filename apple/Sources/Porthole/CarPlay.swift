#if os(iOS) && canImport(CarPlay)
import CarPlay

extension Porthole {
    #if DEBUG
    /// Let porthole-mcp see and drive your CarPlay templates. Call it from
    /// `templateApplicationScene(_:didConnect:to:)` (pass the `CPWindow` too
    /// for navigation apps, whose map is a real window).
    ///
    /// CarPlay templates are drawn by the system, so the harness reads the
    /// template objects instead: list items, grid buttons, alerts and so on
    /// appear in window `carplay`, and pressing one calls its handler.
    public static func registerCarPlay(_ interfaceController: CPInterfaceController, window: CPWindow? = nil) {
        CarPlayBridge.shared.controller = interfaceController
        CarPlayBridge.shared.window = window
    }

    /// Call from `templateApplicationScene(_:didDisconnect:from:)`.
    public static func unregisterCarPlay() {
        CarPlayBridge.shared.controller = nil
        CarPlayBridge.shared.window = nil
    }
    #else
    @inlinable public static func registerCarPlay(_ interfaceController: CPInterfaceController, window: CPWindow? = nil) {}
    @inlinable public static func unregisterCarPlay() {}
    #endif
}
#endif

#if DEBUG && os(iOS) && canImport(CarPlay)
/// The CarPlay template tree as protocol nodes. Templates have no geometry
/// the app can see, so frames are a nominal layout on an 800×480 screen:
/// one 44 pt row per item, for ordering and covered-ness only.
final class CarPlayBridge {
    static let shared = CarPlayBridge()
    static let windowId = "carplay"

    weak var controller: CPInterfaceController?
    weak var window: CPWindow?

    private let size = CGSize(width: 800, height: 480)
    private let rowHeight: CGFloat = 44

    /// Marks the implicit back button.
    private final class Back: NSObject {}
    private let back = Back()

    var isConnected: Bool { controller != nil }

    func windowInfo() -> [String: Any]? {
        guard let ic = controller else { return nil }
        return [
            "id": Self.windowId,
            "title": "CarPlay: " + (ic.topTemplate.map(Self.title(of:)) ?? ""),
            "key": false,
            "frame": ["x": 0, "y": 0, "w": size.width, "h": size.height],
        ]
    }

    // MARK: tree

    func tree() throws -> Tree {
        guard let ic = controller else {
            throw HarnessError.notFound("CarPlay isn't connected. Connect it (Simulator: I/O > External Displays > CarPlay) and call Porthole.registerCarPlay(_:) from your CarPlay scene delegate")
        }
        let root = Node(role: "window", frame: CGRect(origin: .zero, size: size))
        root.name = "CarPlay"
        root.element = ic
        let stack = ic.templates
        for (i, t) in stack.enumerated() {
            let node = build(t)
            // Only the top of the stack is visible, and nothing is while an
            // alert or action sheet is up.
            if i < stack.count - 1 || ic.presentedTemplate != nil {
                node.walk { $0.covered = true }
            }
            attach(node, to: root)
        }
        if stack.count > 1 {
            let b = Node(role: "button", frame: CGRect(x: 0, y: 0, width: 88, height: rowHeight))
            b.name = "Back"
            b.identifier = "carplay-back"
            b.element = back
            if ic.presentedTemplate != nil { b.covered = true }
            attach(b, to: root)
        }
        if let presented = ic.presentedTemplate {
            attach(build(presented), to: root)
        }
        return Tree(windowId: Self.windowId, root: root)
    }

    private func attach(_ child: Node, to parent: Node) {
        child.parent = parent
        parent.children.append(child)
    }

    static func title(of t: CPTemplate) -> String {
        switch t {
        case let l as CPListTemplate: return l.title ?? "List"
        case let g as CPGridTemplate: return g.title
        case let i as CPInformationTemplate: return i.title
        case let p as CPPointOfInterestTemplate: return p.title
        case let a as CPAlertTemplate: return a.titleVariants.first ?? "Alert"
        case let s as CPActionSheetTemplate: return s.title ?? "Action Sheet"
        case is CPNowPlayingTemplate: return "Now Playing"
        case is CPMapTemplate: return "Map"
        case is CPSearchTemplate: return "Search"
        case is CPTabBarTemplate: return "Tabs"
        default: return String(describing: type(of: t))
        }
    }

    private func identifier(_ userInfo: Any?) -> String? {
        switch userInfo {
        case let s as String: return s
        case let d as [String: Any]: return d["id"] as? String
        default: return nil
        }
    }

    /// Lays out rows top to bottom inside a template.
    private struct Cursor {
        var y: CGFloat
    }

    private func row(_ role: String, _ name: String?, _ element: AnyObject?, _ cursor: inout Cursor) -> Node {
        let n = Node(role: role, frame: CGRect(x: 0, y: cursor.y, width: size.width, height: rowHeight))
        n.name = name
        n.element = element
        cursor.y += rowHeight
        return n
    }

    private func build(_ t: CPTemplate) -> Node {
        let node = Node(role: "group", frame: CGRect(origin: .zero, size: size))
        node.name = Self.title(of: t)
        node.element = t
        node.identifier = identifier(t.userInfo)
        var cursor = Cursor(y: rowHeight)
        func add(_ n: Node) { attach(n, to: node) }
        func barButtons(_ buttons: [CPBarButton]) {
            for b in buttons {
                let n = row("button", b.title ?? "Button", b, &cursor)
                if !b.isEnabled { n.states["enabled"] = false }
                add(n)
            }
        }
        if let bar = t as? CPBarButtonProviding {
            barButtons(bar.leadingNavigationBarButtons)
            barButtons(bar.trailingNavigationBarButtons)
        }
        switch t {
        case let list as CPListTemplate:
            node.role = "list"
            for section in list.sections {
                if let header = section.header {
                    add(row("text", header, nil, &cursor))
                }
                for item in section.items {
                    let n = row("row", item.text, item, &cursor)
                    n.identifier = identifier(item.userInfo)
                    if let li = item as? CPListItem, let detail = li.detailText { n.value = detail }
                    if #available(iOS 15.0, *), !item.isEnabled { n.states["enabled"] = false }
                    add(n)
                }
            }
        case let grid as CPGridTemplate:
            for b in grid.gridButtons {
                let n = row("button", b.titleVariants.first, b, &cursor)
                if !b.isEnabled { n.states["enabled"] = false }
                add(n)
            }
        case let tabs as CPTabBarTemplate:
            var selected: CPTemplate?
            if #available(iOS 17.0, *) { selected = tabs.selectedTemplate }
            for tab in tabs.templates {
                let n = row("tab", tab.tabTitle ?? Self.title(of: tab), tab, &cursor)
                n.identifier = identifier(tab.userInfo)
                if tab === selected { n.states["selected"] = true }
                add(n)
            }
            if let selected {
                let content = build(selected)
                add(content)
            }
        case let alert as CPAlertTemplate:
            node.role = "group"
            add(row("text", alert.titleVariants.first, nil, &cursor))
            for a in alert.actions { add(row("button", a.title, a, &cursor)) }
        case let sheet as CPActionSheetTemplate:
            if let m = sheet.message { add(row("text", m, nil, &cursor)) }
            for a in sheet.actions { add(row("button", a.title, a, &cursor)) }
        case let info as CPInformationTemplate:
            for item in info.items {
                let n = row("text", item.title, nil, &cursor)
                n.value = item.detail
                add(n)
            }
            for b in info.actions { add(row("button", b.title, b, &cursor)) }
        case let poi as CPPointOfInterestTemplate:
            node.role = "list"
            for p in poi.pointsOfInterest {
                let n = row("row", p.title, p, &cursor)
                n.value = p.subtitle
                add(n)
            }
        case let np as CPNowPlayingTemplate:
            for (i, b) in np.nowPlayingButtons.enumerated() {
                let name = String(describing: type(of: b)).replacingOccurrences(of: "CPNowPlaying", with: "").replacingOccurrences(of: "Button", with: "")
                add(row("button", name.isEmpty ? "Button \(i + 1)" : name, b, &cursor))
            }
        case let map as CPMapTemplate:
            for (i, b) in map.mapButtons.enumerated() {
                let n = row("button", "Map button \(i + 1)", b, &cursor)
                if !b.isEnabled { n.states["enabled"] = false }
                add(n)
            }
        case is CPSearchTemplate:
            let n = row("textfield", "Search", t, &cursor)
            n.value = ""
            add(n)
        default:
            break
        }
        return node
    }

    // MARK: actions

    func act(_ body: [String: Any]) throws -> String {
        let action = try body.required("action")
        return try onMain {
            let tree = try self.tree()
            switch action {
            case "press":
                let node = try tree.node(try body.required("node"))
                return try press(node)
            case "fill":
                let node = try tree.node(try body.required("node"))
                guard let search = node.element as? CPSearchTemplate else {
                    throw HarnessError.unsupported("only a CarPlay search field takes text")
                }
                let text = body.string("text") ?? ""
                guard let delegate = search.delegate else {
                    throw HarnessError.failed("the search template has no delegate")
                }
                delegate.searchTemplate(search, updatedSearchText: text) { _ in }
                return "searched for \"\(text)\""
            default:
                throw HarnessError.unsupported("CarPlay templates support press and fill (search); \(action) needs a real window (pass the CPWindow to registerCarPlay)")
            }
        }
    }

    /// CarPlay classes whose `handler` is a block taking the object itself.
    private static let handlerClasses: [AnyClass] = [
        CPGridButton.self, CPAlertAction.self, CPTextButton.self, CPBarButton.self, CPMapButton.self,
        CPNowPlayingButton.self, CPButton.self,
    ]

    private func press(_ node: Node) throws -> String {
        if node.covered {
            throw HarnessError.failed("\(node.name ?? node.id) is under another template or an alert; dismiss that first")
        }
        if node.states["enabled"] == false {
            throw HarnessError.failed("\(node.name ?? node.id) is disabled")
        }
        guard let ic = controller else { throw HarnessError.failed("CarPlay disconnected") }
        switch node.element {
        case is Back:
            ic.popTemplate(animated: false, completion: nil)
            return "went back"
        case let item as CPSelectableListItem:
            guard let handler = item.handler else { throw HarnessError.unsupported("this list item has no handler") }
            handler(item) {}
            return "selected list item \(item.text ?? "")"
        case let tab as CPTemplate where node.role == "tab":
            guard #available(iOS 17.0, *), let bar = ic.topTemplate as? CPTabBarTemplate ?? ic.rootTemplate as? CPTabBarTemplate else {
                throw HarnessError.unsupported("selecting a CarPlay tab needs iOS 17")
            }
            bar.select(tab)
            return "selected tab \(node.name ?? "")"
        case let poi as CPPointOfInterest:
            guard let template = ic.topTemplate as? CPPointOfInterestTemplate, let delegate = template.pointOfInterestDelegate else {
                throw HarnessError.unsupported("the point-of-interest template has no delegate")
            }
            delegate.pointOfInterestTemplate?(template, didSelectPointOfInterest: poi)
            return "selected \(poi.title)"
        case let obj as NSObject where Self.handlerClasses.contains(where: { obj.isKind(of: $0) }):
            // Buttons and alert actions keep their handler as a block of the
            // form ^(Self) (CPGridButton's isn't public, hence KVC, which is
            // safe only for these classes: an unknown key would raise).
            guard let block = obj.value(forKey: "handler") else {
                throw HarnessError.unsupported("this \(type(of: obj)) has no handler")
            }
            typealias Handler = @convention(block) (AnyObject) -> Void
            unsafeBitCast(block as AnyObject, to: Handler.self)(obj)
            return "pressed \(node.role) \"\(node.name ?? node.id)\""
        default:
            throw HarnessError.unsupported("\(node.role) \"\(node.name ?? node.id)\" can't be pressed")
        }
    }
}
#endif
