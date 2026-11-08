import AppKit
#if DEBUG
import Porthole
#endif

/// A small AppKit form the end-to-end tests drive: text fields, buttons, a
/// checkbox, a slider, a table in a scroll view, a sheet and a second window.
final class FormController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 560),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let email = NSTextField()
    let password = NSSecureTextField()
    let subscribe = NSButton(checkboxWithTitle: "Subscribe", target: nil, action: nil)
    let volume = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    let status = NSTextField(labelWithString: "Not saved")
    let typed = NSTextField(labelWithString: "Typed: 0")
    let disabled = NSButton(title: "Disabled", target: nil, action: nil)
    let table = NSTableView()
    var changes = 0
    var preferences: NSWindow?
    var sheet: NSWindow?

    func build() {
        window.title = "AppKit Demo"
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.setAccessibilityIdentifier("save")
        save.keyEquivalent = "\r"
        email.placeholderString = "Email"
        email.setAccessibilityIdentifier("email")
        email.delegate = self
        password.placeholderString = "Password"
        password.setAccessibilityIdentifier("password")
        subscribe.setAccessibilityIdentifier("subscribe")
        volume.setAccessibilityIdentifier("volume")
        volume.setAccessibilityLabel("Volume")
        status.setAccessibilityIdentifier("status")
        typed.setAccessibilityIdentifier("typed")
        disabled.isEnabled = false
        disabled.setAccessibilityIdentifier("disabled")
        let sheetButton = NSButton(title: "Open Sheet", target: self, action: #selector(openSheet))
        sheetButton.setAccessibilityIdentifier("open-sheet")
        let prefsButton = NSButton(title: "Preferences", target: self, action: #selector(openPreferences))
        prefsButton.setAccessibilityIdentifier("open-preferences")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Item"
        column.width = 360
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("items")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.setAccessibilityIdentifier("items-scroll")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        let buttons = NSStackView(views: [save, sheetButton, prefsButton, disabled])
        let stack = NSStackView(views: [email, password, subscribe, volume, buttons, status, typed, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [email, password, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }
        window.contentView = stack
        window.makeKeyAndOrderFront(nil)
    }

    func reset() {
        email.stringValue = ""
        password.stringValue = ""
        subscribe.state = .off
        volume.doubleValue = 50
        status.stringValue = "Not saved"
        changes = 0
        typed.stringValue = "Typed: 0"
        table.scrollRowToVisible(0)
        if let sheet { window.endSheet(sheet) }
        preferences?.close()
    }

    @objc func saveClicked() {
        let sub = subscribe.state == .on ? " (subscribed)" : ""
        status.stringValue = "Saved \(email.stringValue)\(sub)"
        print("save tapped: \(email.stringValue)")
    }

    func controlTextDidChange(_ obj: Notification) {
        changes += 1
        typed.stringValue = "Typed: \(changes)"
    }

    @objc func openSheet() {
        let s = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "Are you sure?")
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.setAccessibilityIdentifier("close-sheet")
        let stack = NSStackView(views: [label, close])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        s.contentView = stack
        sheet = s
        window.beginSheet(s)
    }

    @objc func closeSheet() {
        if let sheet { window.endSheet(sheet) }
        sheet = nil
    }

    @objc func openPreferences() {
        let p = preferences ?? NSWindow(contentRect: NSRect(x: 660, y: 300, width: 260, height: 140), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Preferences"
        p.isReleasedWhenClosed = false
        let dark = NSButton(checkboxWithTitle: "Dark mode", target: nil, action: nil)
        dark.setAccessibilityIdentifier("dark-mode")
        let stack = NSStackView(views: [dark])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        p.contentView = stack
        preferences = p
        p.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 40 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "Item \(row + 1)")
        cell.setAccessibilityIdentifier("item-\(row + 1)")
        return cell
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let form = FormController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        Porthole.start()
        Porthole.registerHook("reset") { [form] in form.reset() }
        #endif
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = edit
        NSApp.mainMenu = menu
        form.build()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
