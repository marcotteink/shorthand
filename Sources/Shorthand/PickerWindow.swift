import AppKit

/// A compact floating panel that lists every snippet. Summon it with the global
/// hotkey (or leave it pinned open), pick a snippet, and it drops at your text
/// cursor in whatever app you were just typing in.
final class PickerWindowController: NSObject, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    private let store: SnippetStore
    private let expander: Expander
    var onEditRequested: (() -> Void)?

    private var panel: NSPanel!
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let insertButton = NSButton(title: "Insert", target: nil, action: nil)
    private let keepOpenCheck = NSButton(checkboxWithTitle: "Keep open", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No snippets match.")

    private var items: [Snippet] = []
    private var filtered: [Int] = []

    /// The app the user was working in before reaching for the picker.
    private var lastExternalApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?

    init(store: SnippetStore, expander: Expander) {
        self.store = store
        self.expander = expander
        super.init()
        buildPanel()
        trackFrontmostApp()
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    // MARK: - Frontmost-app tracking

    private func trackFrontmostApp() {
        let current = NSWorkspace.shared.frontmostApplication
        if current?.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = current
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.lastExternalApp = app
            }
        }
    }

    // MARK: - Panel construction

    private func buildPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 440),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Snippets"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 250, height: 320)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("ShorthandPicker")
        panel.delegate = self

        guard let content = panel.contentView else { return }

        searchField.placeholderString = "Search snippets"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("snippet"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.target = self
        tableView.doubleAction = #selector(insertSelected)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.maximumNumberOfLines = 3
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(previewLabel)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)

        keepOpenCheck.font = .systemFont(ofSize: 11)
        keepOpenCheck.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(keepOpenCheck)

        let editButton = NSButton(title: "Edit…", target: self, action: #selector(openEditor))
        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(editButton)

        insertButton.target = self
        insertButton.action = #selector(insertSelected)
        insertButton.bezelStyle = .rounded
        insertButton.controlSize = .regular
        insertButton.keyEquivalent = "\r"
        insertButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(insertButton)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            previewLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            previewLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            previewLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            previewLabel.heightAnchor.constraint(equalToConstant: 44),

            separator.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

            keepOpenCheck.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            keepOpenCheck.centerYAnchor.constraint(equalTo: insertButton.centerYAnchor),

            editButton.trailingAnchor.constraint(equalTo: insertButton.leadingAnchor, constant: -8),
            editButton.centerYAnchor.constraint(equalTo: insertButton.centerYAnchor),

            insertButton.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
            insertButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            insertButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    // MARK: - Show / hide / toggle

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        reload()
        if panel.frame.origin == .zero { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: searchField.stringValue.count)
        }
        if !filtered.isEmpty {
            selectRow(0)
        }
        updateInsertState()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func storeDidChange() {
        guard panel.isVisible else { return }
        reload()
    }

    // MARK: - Data

    private func reload() {
        items = store.snippets.sorted { $0.trigger.lowercased() < $1.trigger.lowercased() }
        applyFilter(preserveSelection: true)
    }

    private func applyFilter(preserveSelection: Bool) {
        let previouslySelected = selectedSnippet()?.trigger
        let query = searchField.stringValue.lowercased()
        filtered = items.indices.filter { i in
            query.isEmpty
                || items[i].trigger.lowercased().contains(query)
                || (items[i].name ?? "").lowercased().contains(query)
        }
        tableView.reloadData()
        emptyLabel.isHidden = !filtered.isEmpty

        if preserveSelection, let trigger = previouslySelected,
           let idx = items.firstIndex(where: { $0.trigger == trigger }),
           let row = filtered.firstIndex(of: idx) {
            selectRow(row)
        } else if !filtered.isEmpty {
            selectRow(0)
        } else {
            updatePreview()
        }
        updateInsertState()
    }

    private func selectRow(_ row: Int) {
        guard row >= 0, row < filtered.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updatePreview()
    }

    private func selectedSnippet() -> Snippet? {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return nil }
        return items[filtered[row]]
    }

    private func updateInsertState() {
        insertButton.isEnabled = selectedSnippet() != nil
    }

    private func updatePreview() {
        guard let snippet = selectedSnippet() else { previewLabel.stringValue = ""; return }
        let body = Self.plainPreview(for: snippet)
        previewLabel.stringValue = body.isEmpty ? "(empty snippet)" : body
    }

    static func plainPreview(for snippet: Snippet) -> String {
        var text: String
        if snippet.isRTFD {
            if let data = Data(base64Encoded: snippet.body),
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.rtfd],
                   documentAttributes: nil
               ) {
                text = attributed.string.replacingOccurrences(of: "\u{FFFC}", with: " [image] ")
            } else {
                text = "[image snippet]"
            }
        } else if snippet.isHTML {
            if let data = snippet.body.data(using: .utf8),
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [
                       .documentType: NSAttributedString.DocumentType.html,
                       .characterEncoding: String.Encoding.utf8.rawValue
                   ],
                   documentAttributes: nil
               ) {
                text = attributed.string
            } else {
                text = snippet.body
            }
        } else {
            text = snippet.body
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > 160 { text = String(text.prefix(160)) + "…" }
        return text
    }

    // MARK: - Insert

    @objc private func insertSelected() {
        guard let snippet = selectedSnippet() else { NSSound.beep(); return }

        if !keepOpenCheck.state.isOn {
            hide()
        }

        // Return focus to the app the user was typing in, then paste there.
        let target = lastExternalApp
        if let target, target.bundleIdentifier != Bundle.main.bundleIdentifier {
            target.activate(options: [])
        }
        let delay: TimeInterval = target != nil ? 0.16 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.expander.insert(snippet)
        }
    }

    @objc private func openEditor() {
        hide()
        onEditRequested?()
    }

    // MARK: - Table view

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("PickerCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SnippetCellView
            ?? SnippetCellView(identifier: id)
        cell.configure(with: items[filtered[row]])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
        updateInsertState()
    }

    // MARK: - Search field key handling

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            insertSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        applyFilter(preserveSelection: false)
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), filtered.count - 1)
        selectRow(next)
    }

    // MARK: - Window delegate

    func windowDidResignKey(_ notification: Notification) {
        // Auto-dismiss when the user clicks away, unless they pinned it open.
        if !keepOpenCheck.state.isOn {
            panel.orderOut(nil)
        }
    }
}

private extension NSControl.StateValue {
    var isOn: Bool { self == .on }
}
