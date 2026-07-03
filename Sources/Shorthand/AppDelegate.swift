import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = SnippetStore()
    private lazy var monitor = KeyMonitor(store: store)
    private let expander = Expander()
    private var permissionTimer: Timer?
    private var editor: EditorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Shorthand")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.onTrigger = { [weak self] snippet in
            self?.expander.expand(snippet)
        }
        store.onChange = { [weak self] in
            self?.editor?.storeDidChange()
        }

        setupMainMenu()
        ensurePermissionAndStart()

        // First-run experience: open the command center until access is granted
        if !isTrusted {
            commandCenter().show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        commandCenter().show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        editor?.flushPendingSave()
    }

    private func commandCenter() -> EditorWindowController {
        if let editor { return editor }
        let controller = EditorWindowController(store: store, monitor: monitor)
        editor = controller
        return controller
    }

    /// Menu bar apps get no main menu by default, which silently kills
    /// Cmd+C/V/Z and the formatting shortcuts inside our window.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Shorthand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(pastePlain)
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = 1  // NSFindPanelAction.showFindPanel
        edit.addItem(find)
        editItem.submenu = edit
        main.addItem(editItem)

        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        let format = NSMenu(title: "Format")
        format.addItem(withTitle: "Bold", action: #selector(EditorWindowController.formatBold(_:)), keyEquivalent: "b")
        format.addItem(withTitle: "Italic", action: #selector(EditorWindowController.formatItalic(_:)), keyEquivalent: "i")
        format.addItem(withTitle: "Underline", action: #selector(EditorWindowController.formatUnderline(_:)), keyEquivalent: "u")
        format.addItem(withTitle: "Add Link…", action: #selector(EditorWindowController.addLink), keyEquivalent: "k")
        formatItem.submenu = format
        main.addItem(formatItem)

        NSApp.mainMenu = main
    }

    // MARK: - Accessibility permission

    private var isTrusted: Bool { AXIsProcessTrusted() }

    private func ensurePermissionAndStart() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            monitor.start()
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self, self.isTrusted else { return }
                timer.invalidate()
                self.permissionTimer = nil
                self.monitor.start()
            }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let center = NSMenuItem(title: "Open Command Center", action: #selector(openCommandCenter), keyEquivalent: "o")
        center.target = self
        menu.addItem(center)
        menu.addItem(.separator())

        if !isTrusted {
            let warn = NSMenuItem(
                title: "Grant Accessibility Access…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        } else {
            let toggle = NSMenuItem(
                title: monitor.isEnabled ? "Pause Expansion" : "Resume Expansion",
                action: #selector(toggleEnabled),
                keyEquivalent: ""
            )
            toggle.target = self
            menu.addItem(toggle)
            menu.addItem(.separator())
        }

        if let error = store.lastError {
            let item = NSMenuItem(title: "snippets.json error: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if store.snippets.isEmpty {
            let item = NSMenuItem(title: "No snippets yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: "Snippets (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for snippet in store.snippets.sorted(by: { $0.trigger < $1.trigger }) {
                let item = NSMenuItem(
                    title: "\(snippet.trigger)   \(snippet.displayName)",
                    action: #selector(copySnippet(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = snippet
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let edit = NSMenuItem(title: "Edit snippets.json…", action: #selector(editSnippets), keyEquivalent: "e")
        edit.target = self
        menu.addItem(edit)

        let reload = NSMenuItem(title: "Reload Snippets", action: #selector(reloadSnippets), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())

        if Bundle.main.bundleURL.pathExtension == "app" {
            let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: "Quit Shorthand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func openCommandCenter() {
        commandCenter().show()
    }

    @objc private func toggleEnabled() {
        monitor.isEnabled.toggle()
    }

    @objc private func copySnippet(_ sender: NSMenuItem) {
        guard let snippet = sender.representedObject as? Snippet else { return }
        expander.copyToPasteboard(snippet)
    }

    @objc private func editSnippets() {
        NSWorkspace.shared.open(SnippetStore.fileURL)
    }

    @objc private func reloadSnippets() {
        store.load()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Login item toggle failed: \(error)")
        }
    }
}
