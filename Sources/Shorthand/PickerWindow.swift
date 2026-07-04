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
    private let previewView = NSTextView()
    private var previewScroll = NSScrollView()
    private let previewCaption = NSTextField(labelWithString: "Preview")
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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 580),
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
        panel.minSize = NSSize(width: 300, height: 420)
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

        previewCaption.font = .systemFont(ofSize: 10, weight: .semibold)
        previewCaption.textColor = .tertiaryLabelColor
        previewCaption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(previewCaption)

        // Read-only rich preview so long, formatted macros are actually legible.
        previewView.isEditable = false
        previewView.isSelectable = true
        previewView.drawsBackground = false
        previewView.textContainerInset = NSSize(width: 8, height: 8)
        previewView.minSize = .zero
        previewView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        previewView.isVerticallyResizable = true
        previewView.isHorizontallyResizable = false
        previewView.autoresizingMask = [.width]
        previewView.textContainer?.widthTracksTextView = true

        previewScroll = NSScrollView()
        previewScroll.documentView = previewView
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .noBorder
        previewScroll.drawsBackground = false
        previewScroll.translatesAutoresizingMaskIntoConstraints = false

        // Light card so snippet colors and highlights read true, like the editor.
        let previewFrame = NSView()
        previewFrame.appearance = NSAppearance(named: .aqua)
        previewFrame.wantsLayer = true
        previewFrame.layer?.backgroundColor = NSColor.white.cgColor
        previewFrame.layer?.borderWidth = 1
        previewFrame.layer?.borderColor = NSColor.separatorColor.cgColor
        previewFrame.layer?.cornerRadius = 8
        previewFrame.layer?.masksToBounds = true
        previewFrame.translatesAutoresizingMaskIntoConstraints = false
        previewFrame.addSubview(previewScroll)
        content.addSubview(previewFrame)
        NSLayoutConstraint.activate([
            previewScroll.leadingAnchor.constraint(equalTo: previewFrame.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: previewFrame.trailingAnchor),
            previewScroll.topAnchor.constraint(equalTo: previewFrame.topAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: previewFrame.bottomAnchor)
        ])

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

            previewCaption.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            previewCaption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),

            previewFrame.topAnchor.constraint(equalTo: previewCaption.bottomAnchor, constant: 4),
            previewFrame.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            previewFrame.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            previewFrame.heightAnchor.constraint(equalToConstant: 150),

            separator.topAnchor.constraint(equalTo: previewFrame.bottomAnchor, constant: 8),
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

    private let previewFont = NSFont(name: "Helvetica Neue", size: 13) ?? NSFont.systemFont(ofSize: 13)

    private func updatePreview() {
        guard let snippet = selectedSnippet() else {
            previewView.string = ""
            return
        }
        let rendered = attributedPreview(for: snippet)
        if rendered.length == 0 {
            previewView.textStorage?.setAttributedString(NSAttributedString(
                string: "(empty snippet)",
                attributes: [.font: previewFont, .foregroundColor: NSColor.secondaryLabelColor]
            ))
        } else {
            previewView.textStorage?.setAttributedString(rendered)
        }
        previewView.scroll(NSPoint.zero)
    }

    /// The snippet body rendered with its real formatting and images, tokens
    /// (like {date}) shown as authored so you see exactly what will be inserted.
    private func attributedPreview(for snippet: Snippet) -> NSAttributedString {
        if snippet.isRTFD {
            if let data = Data(base64Encoded: snippet.body),
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.rtfd],
                   documentAttributes: nil
               ) {
                return attributed
            }
            return NSAttributedString(string: "[image snippet]", attributes: [.font: previewFont])
        }
        if snippet.isHTML {
            let html = Expander.defaultFontWrapped(snippet.body)
            if let data = html.data(using: .utf8),
               let attributed = try? NSAttributedString(
                   data: data,
                   options: [
                       .documentType: NSAttributedString.DocumentType.html,
                       .characterEncoding: String.Encoding.utf8.rawValue
                   ],
                   documentAttributes: nil
               ) {
                return attributed
            }
        }
        return NSAttributedString(
            string: snippet.body,
            attributes: [.font: previewFont, .foregroundColor: NSColor.black]
        )
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
