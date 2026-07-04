import AppKit
import ApplicationServices
import UniformTypeIdentifiers

// MARK: - Sidebar row with trigger pill

final class SnippetCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let pill = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pill.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        pill.textColor = .secondaryLabelColor
        pill.alignment = .center
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
        pill.layer?.cornerRadius = 9
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(nameLabel)
        addSubview(pill)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 6),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(with snippet: Snippet) {
        let kind = (snippet.isHTML || snippet.isRTFD) ? "Rich text snippet" : "Plain text snippet"
        nameLabel.stringValue = snippet.name ?? kind
        pill.stringValue = " \(snippet.trigger) "
    }
}

final class RoundedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 2)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - Dynamic command row (right panel)

final class CommandRowView: NSView {
    private let action: () -> Void

    init(symbol: String, title: String, subtitle: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        let iconWell = NSView()
        iconWell.wantsLayer = true
        iconWell.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        iconWell.layer?.cornerRadius = 8
        iconWell.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconWell.addSubview(icon)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconWell)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            iconWell.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconWell.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWell.widthAnchor.constraint(equalToConstant: 30),
            iconWell.heightAnchor.constraint(equalToConstant: 30),
            icon.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: iconWell.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func clicked() { action() }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.07).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }
}

// MARK: - Command center window

final class EditorWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate,
    NSTextViewDelegate, NSTextFieldDelegate {

    private let store: SnippetStore
    private let monitor: KeyMonitor

    private var items: [Snippet] = []
    private var filtered: [Int] = []
    private var selected: Int?
    private var dirty = false
    private var saveTimer: Timer?
    private var statusTimer: Timer?
    private var suppressStoreRefresh = false
    private var isProgrammaticSelection = false

    // Sidebar
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let conflictBox = NSView()
    private let conflictLabel = NSTextField(wrappingLabelWithString: "")

    // Status row
    private let statusDot = NSTextField(labelWithString: "\u{25CF}")
    private let statusLabel = NSTextField(labelWithString: "")
    private let grantButton = NSButton(title: "Grant Access…", target: nil, action: nil)
    private let enableSwitch = NSSwitch()

    // Header
    private let editorContent = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Select a snippet, or click + to create one.")
    private let triggerField = NSTextField()
    private let nameField = NSTextField()
    private let formatPopup = NSPopUpButton()
    private let modeControl = NSSegmentedControl(labels: ["Edit", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
    private let duplicateWarning = NSTextField(labelWithString: "Another snippet already uses this shortcut.")

    // Toolbar
    private var formattingControls: [NSControl] = []
    private let stylePopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()

    // Editor + preview
    private let textView = NSTextView()
    private let previewView = NSTextView()
    private var editorScroll = NSScrollView()
    private var previewScroll = NSScrollView()
    private let tryView = NSTextView()

    private let defaultFont = NSFont(name: "Helvetica Neue", size: 13) ?? NSFont.systemFont(ofSize: 13)

    private let textPalette: [(String, NSColor?)] = [
        ("Automatic", nil), ("Gray", .darkGray), ("Red", .systemRed), ("Orange", .systemOrange),
        ("Brown", .systemBrown), ("Green", .systemGreen), ("Teal", .systemTeal), ("Blue", .systemBlue),
        ("Purple", .systemPurple), ("Pink", .systemPink)
    ]
    private let highlightPalette: [(String, NSColor?)] = [
        ("None", nil), ("Yellow", .systemYellow), ("Green", NSColor.systemGreen.withAlphaComponent(0.4)),
        ("Cyan", NSColor.systemTeal.withAlphaComponent(0.4)), ("Pink", NSColor.systemPink.withAlphaComponent(0.4)),
        ("Orange", NSColor.systemOrange.withAlphaComponent(0.4)), ("Purple", NSColor.systemPurple.withAlphaComponent(0.35))
    ]

    // MARK: Init

    init(store: SnippetStore, monitor: KeyMonitor) {
        self.store = store
        self.monitor = monitor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1150, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shorthand"
        window.minSize = NSSize(width: 1000, height: 640)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ShorthandCommandCenter")
        super.init(window: window)
        window.delegate = self
        buildUI()
        reloadFromStore(preservingTrigger: nil)
        selectRow(filtered.isEmpty ? nil : 0)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func show() {
        refreshStatus()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: UI construction

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.autosaveName = "ShorthandSplit"
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        split.addArrangedSubview(buildSidebar())
        split.addArrangedSubview(buildEditorPane())
        DispatchQueue.main.async { split.setPosition(250, ofDividerAt: 0) }
    }

    private func buildSidebar() -> NSView {
        let sidebar = NSView()

        searchField.placeholderString = "Search snippets"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("snippet"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.menu = buildContextMenu()

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(scroll)

        // Conflict warning (like TextBlaze's "You have conflicting shortcuts")
        conflictBox.wantsLayer = true
        conflictBox.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
        conflictBox.layer?.cornerRadius = 8
        conflictBox.isHidden = true
        conflictBox.translatesAutoresizingMaskIntoConstraints = false
        conflictLabel.font = .systemFont(ofSize: 11)
        conflictLabel.textColor = .labelColor
        conflictLabel.translatesAutoresizingMaskIntoConstraints = false
        conflictBox.addSubview(conflictLabel)
        sidebar.addSubview(conflictBox)

        let addButton = NSButton(
            image: NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "Add snippet")!,
            target: self, action: #selector(addSnippet)
        )
        addButton.contentTintColor = .controlAccentColor
        let removeButton = NSButton(
            image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Delete snippet")!,
            target: self, action: #selector(deleteSnippet)
        )
        for button in [addButton, removeButton] {
            button.isBordered = false
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(separator)
        sidebar.addSubview(addButton)
        sidebar.addSubview(removeButton)
        sidebar.addSubview(countLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),

            conflictBox.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            conflictBox.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            conflictBox.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            conflictLabel.leadingAnchor.constraint(equalTo: conflictBox.leadingAnchor, constant: 8),
            conflictLabel.trailingAnchor.constraint(equalTo: conflictBox.trailingAnchor, constant: -8),
            conflictLabel.topAnchor.constraint(equalTo: conflictBox.topAnchor, constant: 6),
            conflictLabel.bottomAnchor.constraint(equalTo: conflictBox.bottomAnchor, constant: -6),

            separator.topAnchor.constraint(equalTo: conflictBox.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),

            addButton.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            addButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            addButton.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),

            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 10),

            countLabel.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12)
        ])
        return sidebar
    }

    private func buildEditorPane() -> NSView {
        let pane = NSView()

        // Status row
        statusDot.font = .systemFont(ofSize: 12)
        statusLabel.font = .systemFont(ofSize: 12)
        grantButton.target = self
        grantButton.action = #selector(openAccessibilitySettings)
        grantButton.bezelStyle = .rounded
        grantButton.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(toggleEnabled)

        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let statusRow = NSStackView(views: [statusDot, statusLabel, statusSpacer, grantButton, enableSwitch])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let statusSeparator = NSBox()
        statusSeparator.boxType = .separator

        // Header: boxed Label + Shortcut fields, mode toggle
        nameField.placeholderString = "Customer notes"
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.font = .systemFont(ofSize: 14)
        nameField.delegate = self
        let labelBox = fieldBox(
            caption: "Label (describes the snippet)",
            symbol: "tag",
            field: nameField
        )

        triggerField.placeholderString = "/cn"
        triggerField.isBordered = false
        triggerField.drawsBackground = false
        triggerField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        triggerField.delegate = self
        let shortcutBox = fieldBox(
            caption: "Shortcut (typed to insert)",
            symbol: "keyboard",
            field: triggerField
        )
        shortcutBox.widthAnchor.constraint(equalToConstant: 220).isActive = true

        formatPopup.addItems(withTitles: ["Rich Text", "Plain Text"])
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let headerRow = NSStackView(views: [labelBox, shortcutBox, headerSpacer, formatPopup, modeControl])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10

        duplicateWarning.font = .systemFont(ofSize: 11)
        duplicateWarning.textColor = .systemRed
        duplicateWarning.isHidden = true

        // Formatting toolbar
        let toolbar = buildToolbar()

        // Editor and preview
        configureBodyTextView(textView, editable: true)
        textView.delegate = self
        editorScroll = wrapInScroll(textView)

        configureBodyTextView(previewView, editable: false)
        previewScroll = wrapInScroll(previewView)
        previewScroll.isHidden = true

        let editorFrame = NSView()
        editorFrame.appearance = NSAppearance(named: .aqua)
        editorFrame.wantsLayer = true
        editorFrame.layer?.borderWidth = 1
        editorFrame.layer?.borderColor = NSColor.separatorColor.cgColor
        editorFrame.layer?.cornerRadius = 8
        editorFrame.layer?.masksToBounds = true
        for scroll in [editorScroll, previewScroll] {
            scroll.translatesAutoresizingMaskIntoConstraints = false
            editorFrame.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: editorFrame.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: editorFrame.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: editorFrame.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: editorFrame.bottomAnchor)
            ])
        }

        // Dynamic commands panel
        let commands = buildCommandsPanel()
        commands.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let bodyRow = NSStackView(views: [editorFrame, commands])
        bodyRow.orientation = .horizontal
        bodyRow.alignment = .top
        bodyRow.spacing = 12
        editorFrame.heightAnchor.constraint(equalTo: bodyRow.heightAnchor).isActive = true
        commands.heightAnchor.constraint(lessThanOrEqualTo: bodyRow.heightAnchor).isActive = true

        // Try it out strip
        let tryStrip = buildTryStrip()

        editorContent.orientation = .vertical
        editorContent.alignment = .leading
        editorContent.spacing = 10
        for view in [headerRow, duplicateWarning, toolbar, bodyRow, tryStrip] {
            editorContent.addArrangedSubview(view)
        }
        for view in [headerRow, toolbar, bodyRow, tryStrip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: editorContent.widthAnchor).isActive = true
        }

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [statusRow, statusSeparator, editorContent])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false
        for view in [statusRow, statusSeparator, editorContent] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        }

        pane.addSubview(outer)
        pane.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            outer.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
            outer.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
            outer.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -14),
            editorContent.bottomAnchor.constraint(equalTo: outer.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: pane.centerYAnchor)
        ])
        return pane
    }

    /// A bordered box with a small caption, an icon, and a borderless field inside.
    private func fieldBox(caption: String, symbol: String, field: NSTextField) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.cornerRadius = 8

        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 10)
        captionLabel.textColor = .secondaryLabelColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: caption)
        icon.contentTintColor = .tertiaryLabelColor

        for view in [captionLabel, icon, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
        }
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 52),
            captionLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            captionLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 2)
        ])
        return box
    }

    private func toolButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button: NSButton
        if let image {
            button = NSButton(image: image, target: self, action: action)
        } else {
            button = NSButton(title: tooltip, target: self, action: action)
        }
        button.isBordered = false
        button.toolTip = tooltip
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func toolbarDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return divider
    }

    private func buildToolbar() -> NSView {
        stylePopup.addItems(withTitles: ["Normal", "Heading 1", "Heading 2", "Heading 3"])
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        stylePopup.toolTip = "Paragraph style"

        sizePopup.addItems(withTitles: ["11", "12", "13", "14", "16", "18", "22", "26", "32"])
        sizePopup.selectItem(withTitle: "13")
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged)
        sizePopup.toolTip = "Font size"

        let bold = toolButton("bold", tooltip: "Bold (Cmd B)", action: #selector(formatBold(_:)))
        let italic = toolButton("italic", tooltip: "Italic (Cmd I)", action: #selector(formatItalic(_:)))
        let underline = toolButton("underline", tooltip: "Underline (Cmd U)", action: #selector(formatUnderline(_:)))
        let strike = toolButton("strikethrough", tooltip: "Strikethrough", action: #selector(formatStrikethrough(_:)))
        let link = toolButton("link", tooltip: "Add or edit link", action: #selector(addLink))
        let picture = toolButton("photo", tooltip: "Insert image", action: #selector(insertImage))
        let color = toolButton("textformat", tooltip: "Text color", action: #selector(showTextColors(_:)))
        let highlight = toolButton("highlighter", tooltip: "Highlight", action: #selector(showHighlights(_:)))
        let bullets = toolButton("list.bullet", tooltip: "Bulleted list", action: #selector(toggleBullets))
        let numbers = toolButton("list.number", tooltip: "Numbered list", action: #selector(toggleNumbers))
        let clear = toolButton("eraser", tooltip: "Clear formatting", action: #selector(clearFormatting))
        let emoji = toolButton("face.smiling", tooltip: "Emoji", action: #selector(showEmoji))

        let align = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Align left")!,
                NSImage(systemSymbolName: "text.aligncenter", accessibilityDescription: "Align center")!,
                NSImage(systemSymbolName: "text.alignright", accessibilityDescription: "Align right")!
            ],
            trackingMode: .momentary, target: self, action: #selector(alignChanged(_:))
        )
        align.toolTip = "Alignment"

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [
            stylePopup, sizePopup, toolbarDivider(),
            bold, italic, underline, strike, toolbarDivider(),
            link, picture, color, highlight, toolbarDivider(),
            bullets, numbers, align, toolbarDivider(),
            clear, emoji, spacer
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        formattingControls = [stylePopup, sizePopup, bold, italic, underline, strike, link, picture, color, highlight, bullets, numbers, align, clear, emoji]
        return row
    }

    private func buildCommandsPanel() -> NSView {
        let title = NSTextField(labelWithString: "DYNAMIC COMMANDS")
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .tertiaryLabelColor

        let rows: [(String, String, String, String)] = [
            ("calendar", "Date", "Insert today's date", "{date}"),
            ("calendar.badge.clock", "Formatted date", "Date with custom format", "{date:MM/dd/yyyy}"),
            ("clock", "Time", "Insert the current time", "{time}"),
            ("doc.on.clipboard", "Clipboard", "Insert clipboard contents", "{clipboard}"),
            ("text.cursor", "Place cursor", "Cursor lands here after inserting", "{cursor}")
        ]
        var views: [NSView] = [title]
        for (symbol, name, subtitle, token) in rows {
            views.append(CommandRowView(symbol: symbol, title: name, subtitle: subtitle) { [weak self] in
                self?.insertToken(token)
            })
        }

        let hint = NSTextField(wrappingLabelWithString: "Click a command to drop it into your snippet. It fills in automatically every time the snippet expands.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        views.append(hint)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for view in views where view is CommandRowView {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func buildTryStrip() -> NSView {
        let caption = NSTextField(labelWithString: "Try it out")
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        let sub = NSTextField(labelWithString: "Click in the box and type a shortcut, like /date")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .tertiaryLabelColor

        tryView.isRichText = true
        tryView.font = defaultFont
        tryView.textContainerInset = NSSize(width: 8, height: 6)
        tryView.isAutomaticDashSubstitutionEnabled = false
        tryView.isAutomaticQuoteSubstitutionEnabled = false

        let tryScroll = wrapInScroll(tryView)
        let tryFrame = NSView()
        tryFrame.appearance = NSAppearance(named: .aqua)
        tryFrame.wantsLayer = true
        tryFrame.layer?.borderWidth = 1
        tryFrame.layer?.borderColor = NSColor.separatorColor.cgColor
        tryFrame.layer?.cornerRadius = 8
        tryFrame.layer?.masksToBounds = true
        tryScroll.translatesAutoresizingMaskIntoConstraints = false
        tryFrame.addSubview(tryScroll)
        NSLayoutConstraint.activate([
            tryScroll.leadingAnchor.constraint(equalTo: tryFrame.leadingAnchor),
            tryScroll.trailingAnchor.constraint(equalTo: tryFrame.trailingAnchor),
            tryScroll.topAnchor.constraint(equalTo: tryFrame.topAnchor),
            tryScroll.bottomAnchor.constraint(equalTo: tryFrame.bottomAnchor),
            tryFrame.heightAnchor.constraint(equalToConstant: 130)
        ])

        let labels = NSStackView(views: [caption, sub])
        labels.orientation = .horizontal
        labels.spacing = 8

        let strip = NSStackView(views: [labels, tryFrame])
        strip.orientation = .vertical
        strip.alignment = .leading
        strip.spacing = 4
        tryFrame.translatesAutoresizingMaskIntoConstraints = false
        tryFrame.widthAnchor.constraint(equalTo: strip.widthAnchor).isActive = true
        return strip
    }

    private func configureBodyTextView(_ view: NSTextView, editable: Bool) {
        view.isRichText = true
        view.isEditable = editable
        view.usesFindBar = true
        view.allowsUndo = true
        view.importsGraphics = true  // paste and drag images into snippets
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.font = defaultFont
        view.textContainerInset = NSSize(width: 12, height: 12)
    }

    private func wrapInScroll(_ view: NSTextView) -> NSScrollView {
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        return scroll
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let duplicate = NSMenuItem(title: "Duplicate Snippet", action: #selector(duplicateClicked), keyEquivalent: "")
        duplicate.target = self
        let delete = NSMenuItem(title: "Delete Snippet", action: #selector(deleteClicked), keyEquivalent: "")
        delete.target = self
        menu.addItem(duplicate)
        menu.addItem(delete)
        return menu
    }

    // MARK: Split view

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 210 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 380 }
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        splitView.arrangedSubviews.first != view
    }

    // MARK: Status + conflicts

    private func refreshStatus() {
        let trusted = AXIsProcessTrusted()
        grantButton.isHidden = trusted
        enableSwitch.isEnabled = trusted
        if !trusted {
            statusDot.textColor = .systemRed
            statusLabel.stringValue = "Accessibility access needed before expansion can work"
            enableSwitch.state = .off
        } else if monitor.isEnabled {
            statusDot.textColor = .systemGreen
            statusLabel.stringValue = "Expanding. Type a shortcut in any app."
            enableSwitch.state = .on
        } else {
            statusDot.textColor = .systemOrange
            statusLabel.stringValue = "Expansion paused"
            enableSwitch.state = .off
        }
        countLabel.stringValue = items.count == 1 ? "1 snippet" : "\(items.count) snippets"
        updateConflicts()
    }

    private func updateConflicts() {
        var message: String?
        outer: for a in items {
            for b in items where a.trigger != b.trigger {
                if !a.trigger.isEmpty, b.trigger.hasPrefix(a.trigger) {
                    message = "Conflicting shortcuts: \(a.trigger) fires before \(b.trigger) can be typed."
                    break outer
                }
            }
        }
        let dupes = Dictionary(grouping: items, by: { $0.trigger }).filter { $1.count > 1 }
        if message == nil, let dupe = dupes.keys.first {
            message = "Duplicate shortcut: \(dupe) is used by more than one snippet."
        }
        conflictLabel.stringValue = "\u{26A0}\u{FE0E} " + (message ?? "")
        conflictBox.isHidden = message == nil
    }

    @objc private func toggleEnabled() {
        monitor.isEnabled = enableSwitch.state == .on
        refreshStatus()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Data flow

    func storeDidChange() {
        if suppressStoreRefresh || dirty { return }
        if items == store.snippets { refreshStatus(); return }
        let trigger = selected.flatMap { items.indices.contains($0) ? items[$0].trigger : nil }
        reloadFromStore(preservingTrigger: trigger)
    }

    private func reloadFromStore(preservingTrigger trigger: String?) {
        items = store.snippets
        applyFilter()
        tableView.reloadData()
        refreshStatus()
        if let trigger, let index = items.firstIndex(where: { $0.trigger == trigger }),
           let row = filtered.firstIndex(of: index) {
            selectRow(row)
        } else {
            selectRow(filtered.isEmpty ? nil : 0)
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue.lowercased()
        filtered = items.indices.filter { i in
            query.isEmpty
                || items[i].trigger.lowercased().contains(query)
                || (items[i].name ?? "").lowercased().contains(query)
        }
    }

    private func selectRow(_ row: Int?) {
        isProgrammaticSelection = true
        if let row, row >= 0, row < filtered.count {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            selected = filtered[row]
        } else {
            tableView.deselectAll(nil)
            selected = nil
        }
        isProgrammaticSelection = false
        loadSelection()
    }

    private func loadSelection() {
        let hasSelection = selected != nil && items.indices.contains(selected ?? -1)
        editorContent.isHidden = !hasSelection
        emptyLabel.isHidden = hasSelection
        guard hasSelection, let i = selected else { return }
        let snippet = items[i]
        let rich = snippet.isHTML || snippet.isRTFD
        triggerField.stringValue = snippet.trigger
        nameField.stringValue = snippet.name ?? ""
        formatPopup.selectItem(at: rich ? 0 : 1)
        modeControl.selectedSegment = 0
        setPreviewVisible(false)
        applyFormatUI(rich: rich)
        textView.textStorage?.setAttributedString(attributedBody(for: snippet))
        textView.typingAttributes = [.font: defaultFont, .foregroundColor: NSColor.black]
        textView.undoManager?.removeAllActions()
        validateTrigger()
    }

    private func applyFormatUI(rich: Bool) {
        textView.isRichText = rich
        for control in formattingControls {
            control.isEnabled = rich && modeControl.selectedSegment == 0
        }
    }

    // MARK: Edit / Preview

    @objc private func modeChanged() {
        let preview = modeControl.selectedSegment == 1
        if preview { renderPreview() }
        setPreviewVisible(preview)
        applyFormatUI(rich: formatPopup.indexOfSelectedItem == 0)
    }

    private func setPreviewVisible(_ visible: Bool) {
        previewScroll.isHidden = !visible
        editorScroll.isHidden = visible
    }

    private func renderPreview() {
        guard let snapshot = snapshotFromUI() else { return }
        if snapshot.isRTFD {
            let attributed = NSMutableAttributedString(attributedString: attributedBody(for: snapshot))
            let cursorRange = (attributed.string as NSString).range(of: "{cursor}")
            if cursorRange.location != NSNotFound {
                attributed.replaceCharacters(in: cursorRange, with: NSAttributedString(string: "\u{2336}"))
            }
            Expander.renderDynamicContent(in: attributed)
            previewView.textStorage?.setAttributedString(attributed)
            return
        }
        var body = snapshot.body.replacingOccurrences(of: "{cursor}", with: "\u{2336}")
        body = Expander.substitutePlaceholders(in: body, escapeHTML: snapshot.isHTML)
        var rendered: NSAttributedString
        if snapshot.isHTML, let data = Expander.defaultFontWrapped(body).data(using: .utf8),
           let imported = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ],
               documentAttributes: nil
           ) {
            rendered = imported
        } else {
            rendered = NSAttributedString(string: body, attributes: [.font: defaultFont, .foregroundColor: NSColor.black])
        }
        previewView.textStorage?.setAttributedString(rendered)
    }

    // MARK: Editing and saving

    private func snapshotFromUI() -> Snippet? {
        guard let i = selected, items.indices.contains(i) else { return nil }
        var snippet = items[i]
        snippet.trigger = triggerField.stringValue.trimmingCharacters(in: .whitespaces)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        snippet.name = name.isEmpty ? nil : name
        let rich = formatPopup.indexOfSelectedItem == 0
        if rich {
            let attributed = textView.attributedString()
            if attributed.string.contains("\u{FFFC}"),
               let rtfd = try? attributed.data(
                   from: NSRange(location: 0, length: attributed.length),
                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
               ) {
                snippet.format = "rtfd"
                snippet.body = rtfd.base64EncodedString()
            } else {
                snippet.format = "html"
                snippet.body = exportHTML(attributed)
            }
        } else {
            snippet.format = "plain"
            snippet.body = textView.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        }
        return snippet
    }

    @discardableResult
    private func commitEdits() -> Bool {
        guard let i = selected, let snapshot = snapshotFromUI(), snapshot != items[i] else { return false }
        items[i] = snapshot
        dirty = true
        if let row = filtered.firstIndex(of: i) {
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
        return true
    }

    private func scheduleAutosave() {
        dirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.commitEdits()
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard dirty else { return }
        dirty = false
        suppressStoreRefresh = true
        store.save(items)
        items = store.snippets
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.suppressStoreRefresh = false
        }
    }

    func flushPendingSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        commitEdits()
        saveNow()
    }

    private func validateTrigger() {
        guard let i = selected else { return }
        let trigger = triggerField.stringValue.trimmingCharacters(in: .whitespaces)
        let clash = items.indices.contains { $0 != i && items[$0].trigger == trigger && !trigger.isEmpty }
        duplicateWarning.isHidden = !clash
    }

    // MARK: Body conversion

    private func attributedBody(for snippet: Snippet) -> NSAttributedString {
        if snippet.isRTFD {
            if let data = Data(base64Encoded: snippet.body),
               let imported = try? NSAttributedString(
                   data: data,
                   options: [.documentType: NSAttributedString.DocumentType.rtfd],
                   documentAttributes: nil
               ) {
                return imported
            }
            return NSAttributedString(string: "", attributes: [.font: defaultFont])
        }
        if snippet.isHTML {
            let html = Expander.defaultFontWrapped(snippet.body)
            if let data = html.data(using: .utf8),
               let imported = try? NSAttributedString(
                   data: data,
                   options: [
                       .documentType: NSAttributedString.DocumentType.html,
                       .characterEncoding: String.Encoding.utf8.rawValue
                   ],
                   documentAttributes: nil
               ) {
                let mutable = NSMutableAttributedString(attributedString: imported)
                while mutable.string.hasSuffix("\n") {
                    mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
                }
                return mutable
            }
        }
        return NSAttributedString(
            string: snippet.body,
            attributes: [.font: defaultFont, .foregroundColor: NSColor.black]
        )
    }

    private func exportHTML(_ attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }
        let range = NSRange(location: 0, length: attributed.length)
        if let data = try? attributed.data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
        ), let html = String(data: data, encoding: .utf8) {
            return html
        }
        return attributed.string
    }

    // MARK: Formatting actions

    private func selectionOrTypingRange() -> NSRange { textView.selectedRange() }

    private func withTextChange(in range: NSRange, _ mutate: () -> Void) {
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        mutate()
        textView.didChangeText()
        scheduleAutosave()
    }

    @objc func formatBold(_ sender: Any?) { toggleFontTrait(.boldFontMask) }
    @objc func formatItalic(_ sender: Any?) { toggleFontTrait(.italicFontMask) }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        let range = selectionOrTypingRange()
        let manager = NSFontManager.shared
        if range.length == 0 {
            let font = (textView.typingAttributes[.font] as? NSFont) ?? defaultFont
            let has = manager.traits(of: font).contains(trait)
            var attrs = textView.typingAttributes
            attrs[.font] = has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            textView.typingAttributes = attrs
            return
        }
        guard let storage = textView.textStorage else { return }
        let firstFont = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? defaultFont
        let adding = !manager.traits(of: firstFont).contains(trait)
        withTextChange(in: range) {
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? NSFont) ?? defaultFont
                let converted = adding ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
                storage.addAttribute(.font, value: converted, range: subrange)
            }
        }
    }

    @objc func formatUnderline(_ sender: Any?) { toggleStyleAttribute(.underlineStyle) }
    @objc func formatStrikethrough(_ sender: Any?) { toggleStyleAttribute(.strikethroughStyle) }

    private func toggleStyleAttribute(_ key: NSAttributedString.Key) {
        let range = selectionOrTypingRange()
        if range.length == 0 {
            var attrs = textView.typingAttributes
            let on = (attrs[key] as? Int ?? 0) != 0
            attrs[key] = on ? nil : NSUnderlineStyle.single.rawValue
            textView.typingAttributes = attrs
            return
        }
        guard let storage = textView.textStorage else { return }
        let current = storage.attribute(key, at: range.location, effectiveRange: nil) as? Int ?? 0
        withTextChange(in: range) {
            if current != 0 {
                storage.removeAttribute(key, range: range)
            } else {
                storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }

    @objc private func showTextColors(_ sender: NSButton) {
        showSwatches(palette: textPalette, relativeTo: sender) { [weak self] color in
            self?.applyColorAttribute(.foregroundColor, color: color, fallback: .black)
        }
    }

    @objc private func showHighlights(_ sender: NSButton) {
        showSwatches(palette: highlightPalette, relativeTo: sender) { [weak self] color in
            self?.applyColorAttribute(.backgroundColor, color: color, fallback: nil)
        }
    }

    private var swatchPopover: NSPopover?
    private var swatchHandler: ((NSColor?) -> Void)?

    private func showSwatches(palette: [(String, NSColor?)], relativeTo view: NSView, apply: @escaping (NSColor?) -> Void) {
        swatchPopover?.close()
        swatchHandler = apply

        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for (index, entry) in palette.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(swatchPicked(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.toolTip = entry.0
            button.layer?.cornerRadius = 10
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.separatorColor.cgColor
            button.layer?.backgroundColor = (entry.1 ?? .white).cgColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            if entry.1 == nil {
                button.title = "/"
                button.font = .systemFont(ofSize: 10)
            }
            container.addArrangedSubview(button)
        }
        swatchPalette = palette

        let controller = NSViewController()
        controller.view = container
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        swatchPopover = popover
    }

    private var swatchPalette: [(String, NSColor?)] = []

    @objc private func swatchPicked(_ sender: NSButton) {
        swatchPopover?.close()
        guard sender.tag < swatchPalette.count else { return }
        swatchHandler?(swatchPalette[sender.tag].1)
    }

    private func applyColorAttribute(_ key: NSAttributedString.Key, color: NSColor?, fallback: NSColor?) {
        let range = selectionOrTypingRange()
        if range.length == 0 {
            var attrs = textView.typingAttributes
            attrs[key] = color ?? fallback
            textView.typingAttributes = attrs
            return
        }
        guard let storage = textView.textStorage else { return }
        withTextChange(in: range) {
            if let color {
                storage.addAttribute(key, value: color, range: range)
            } else if let fallback {
                storage.addAttribute(key, value: fallback, range: range)
            } else {
                storage.removeAttribute(key, range: range)
            }
        }
    }

    @objc private func styleChanged() {
        let styles: [(CGFloat, NSFontTraitMask?)] = [(13, nil), (22, .boldFontMask), (17, .boldFontMask), (15, .boldFontMask)]
        let (size, trait) = styles[max(0, stylePopup.indexOfSelectedItem)]
        applyFontTransform { font in
            var newFont = NSFontManager.shared.convert(font, toSize: size)
            newFont = NSFontManager.shared.convert(newFont, toNotHaveTrait: .boldFontMask)
            if let trait { newFont = NSFontManager.shared.convert(newFont, toHaveTrait: trait) }
            return newFont
        }
    }

    @objc private func sizeChanged() {
        guard let title = sizePopup.titleOfSelectedItem, let size = Int(title) else { return }
        applyFontTransform { NSFontManager.shared.convert($0, toSize: CGFloat(size)) }
    }

    private func applyFontTransform(_ transform: (NSFont) -> NSFont) {
        var range = selectionOrTypingRange()
        guard let storage = textView.textStorage else { return }
        // Style changes with no selection apply to the whole paragraph
        if range.length == 0 {
            range = (storage.string as NSString).paragraphRange(for: range)
        }
        if range.length == 0 {
            var attrs = textView.typingAttributes
            attrs[.font] = transform((attrs[.font] as? NSFont) ?? defaultFont)
            textView.typingAttributes = attrs
            return
        }
        withTextChange(in: range) {
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? NSFont) ?? self.defaultFont
                storage.addAttribute(.font, value: transform(font), range: subrange)
            }
        }
    }

    @objc private func alignChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: textView.alignLeft(nil)
        case 1: textView.alignCenter(nil)
        default: textView.alignRight(nil)
        }
        scheduleAutosave()
    }

    // MARK: Lists

    @objc private func toggleBullets() { toggleList(ordered: false) }
    @objc private func toggleNumbers() { toggleList(ordered: true) }

    private func toggleList(ordered: Bool) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let pRange = ns.paragraphRange(for: textView.selectedRange())

        var hasList = false
        if storage.length > 0 {
            let checkLocation = min(pRange.location, storage.length - 1)
            if let style = storage.attribute(.paragraphStyle, at: checkLocation, effectiveRange: nil) as? NSParagraphStyle {
                hasList = !style.textLists.isEmpty
            }
        }

        let original = storage.attributedSubstring(from: pRange)
        let replacement = NSMutableAttributedString(attributedString: original)

        if hasList {
            stripList(from: replacement)
        } else {
            applyList(to: replacement, ordered: ordered)
        }

        guard textView.shouldChangeText(in: pRange, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: pRange, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: pRange.location + replacement.length, length: 0))
        // Keep typing in list mode so Enter continues the list
        if !hasList, replacement.length > 0 {
            var attrs = textView.typingAttributes
            attrs[.paragraphStyle] = replacement.attribute(.paragraphStyle, at: replacement.length - 1, effectiveRange: nil)
            textView.typingAttributes = attrs
        }
        scheduleAutosave()
    }

    private func paragraphRanges(of text: NSMutableAttributedString) -> [NSRange] {
        let ns = text.string as NSString
        var ranges: [NSRange] = []
        var location = 0
        if ns.length == 0 { return [NSRange(location: 0, length: 0)] }
        while location < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(r)
            location = NSMaxRange(r)
            if r.length == 0 { break }
        }
        return ranges
    }

    private func applyList(to text: NSMutableAttributedString, ordered: Bool) {
        let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
        let ranges = paragraphRanges(of: text)
        var number = ranges.count
        for range in ranges.reversed() {
            let marker = ordered ? "\t\(number).\t" : "\t\u{2022}\t"
            number -= 1
            let baseStyle = (range.length > 0
                ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : nil) ?? NSParagraphStyle.default
            let style = (baseStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.textLists = [list]
            style.headIndent = 28
            style.firstLineHeadIndent = 0
            style.tabStops = [
                NSTextTab(textAlignment: .left, location: 11, options: [:]),
                NSTextTab(textAlignment: .left, location: 28, options: [:])
            ]
            let markerFont = (range.length > 0
                ? text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                : nil) ?? defaultFont
            text.addAttribute(.paragraphStyle, value: style, range: range)
            text.insert(NSAttributedString(string: marker, attributes: [
                .font: markerFont,
                .foregroundColor: NSColor.black,
                .paragraphStyle: style
            ]), at: range.location)
        }
    }

    private func stripList(from text: NSMutableAttributedString) {
        let markerPattern = try? NSRegularExpression(pattern: "^\\t?(\u{2022}|\\d+\\.)\\t")
        for range in paragraphRanges(of: text).reversed() {
            let baseStyle = (range.length > 0
                ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : nil) ?? NSParagraphStyle.default
            let style = (baseStyle.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.textLists = []
            style.headIndent = 0
            style.firstLineHeadIndent = 0
            style.tabStops = NSParagraphStyle.default.tabStops
            text.addAttribute(.paragraphStyle, value: style, range: range)
            let paragraph = (text.string as NSString).substring(with: range)
            if let match = markerPattern?.firstMatch(
                in: paragraph, range: NSRange(location: 0, length: (paragraph as NSString).length)
            ) {
                text.deleteCharacters(in: NSRange(location: range.location + match.range.location, length: match.range.length))
            }
        }
    }

    @objc private func clearFormatting() {
        let range = selectionOrTypingRange()
        guard range.length > 0, let storage = textView.textStorage else { return }
        let plain = (storage.string as NSString).substring(with: range)
        withTextChange(in: range) {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: plain, attributes: [
                .font: defaultFont,
                .foregroundColor: NSColor.black
            ]))
        }
    }

    @objc private func showEmoji() {
        window?.makeFirstResponder(textView)
        NSApp.orderFrontCharacterPalette(nil)
    }

    @objc private func insertImage() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = url.lastPathComponent
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            // Scale oversized images down to fit the editor and paste target
            if let image = NSImage(data: data), image.size.width > 440 {
                let scale = 440 / image.size.width
                attachment.bounds = CGRect(x: 0, y: 0, width: 440, height: image.size.height * scale)
            }
            self.window?.makeFirstResponder(self.textView)
            self.textView.insertText(
                NSAttributedString(attachment: attachment),
                replacementRange: self.textView.selectedRange()
            )
        }
    }

    private func insertToken(_ token: String) {
        guard modeControl.selectedSegment == 0 else { return }
        window?.makeFirstResponder(textView)
        textView.insertText(token, replacementRange: textView.selectedRange())
    }

    // MARK: Links

    @objc func addLink() {
        guard let window else { return }
        let selection = textView.selectedRange()
        var existingURL: String?
        if selection.location < textView.attributedString().length,
           let existing = textView.attributedString().attribute(.link, at: selection.location, effectiveRange: nil) {
            existingURL = (existing as? URL)?.absoluteString ?? (existing as? String)
        }

        let alert = NSAlert()
        alert.messageText = existingURL == nil ? "Add Link" : "Edit Link"
        alert.informativeText = selection.length > 0
            ? "The selected text will become a clickable link."
            : "The address will be inserted as a clickable link."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com or name@email.com"
        field.stringValue = existingURL ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if existingURL != nil { alert.addButton(withTitle: "Remove Link") }
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertThirdButtonReturn {
                self.removeLink()
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            var address = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { return }
            if address.contains("@"), !address.contains("://"), !address.hasPrefix("mailto:") {
                address = "mailto:" + address
            } else if !address.contains("://"), !address.hasPrefix("mailto:") {
                address = "https://" + address
            }
            guard let url = URL(string: address) else { return }
            self.window?.makeFirstResponder(self.textView)
            if selection.length > 0 {
                self.withTextChange(in: selection) {
                    self.textView.textStorage?.addAttribute(.link, value: url, range: selection)
                }
            } else {
                let display = address.replacingOccurrences(of: "mailto:", with: "")
                let linked = NSAttributedString(string: display, attributes: [
                    .link: url,
                    .font: self.textView.typingAttributes[.font] ?? self.defaultFont
                ])
                self.textView.insertText(linked, replacementRange: selection)
            }
        }
    }

    private func removeLink() {
        let storage = textView.textStorage
        var range = textView.selectedRange()
        if range.length == 0 {
            guard let storage, range.location < storage.length else { return }
            var effective = NSRange()
            let has = storage.attribute(
                .link, at: range.location,
                longestEffectiveRange: &effective,
                in: NSRange(location: 0, length: storage.length)
            )
            guard has != nil else { return }
            range = effective
        }
        withTextChange(in: range) {
            storage?.removeAttribute(.link, range: range)
            storage?.removeAttribute(.underlineStyle, range: range)
        }
    }

    // MARK: Snippet actions

    @objc private func addSnippet() {
        flushPendingSave()
        var n = 1
        while items.contains(where: { $0.trigger == "/snip\(n)" }) { n += 1 }
        items.append(Snippet(trigger: "/snip\(n)", name: "New Snippet", format: "html", body: ""))
        dirty = true
        searchField.stringValue = ""
        applyFilter()
        tableView.reloadData()
        if let row = filtered.firstIndex(of: items.count - 1) {
            selectRow(row)
        }
        saveNow()
        window?.makeFirstResponder(triggerField)
        triggerField.selectText(nil)
    }

    @objc private func deleteSnippet() {
        guard let i = selected, items.indices.contains(i) else { return }
        confirmDelete(index: i)
    }

    @objc private func deleteClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < filtered.count else { return }
        confirmDelete(index: filtered[row])
    }

    @objc private func duplicateClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < filtered.count else { return }
        flushPendingSave()
        var copy = items[filtered[row]]
        copy.trigger += "-copy"
        while items.contains(where: { $0.trigger == copy.trigger }) { copy.trigger += "-copy" }
        items.append(copy)
        dirty = true
        applyFilter()
        tableView.reloadData()
        if let newRow = filtered.firstIndex(of: items.count - 1) {
            selectRow(newRow)
        }
        saveNow()
    }

    private func confirmDelete(index: Int) {
        guard let window else { return }
        let snippet = items[index]
        let alert = NSAlert()
        alert.messageText = "Delete \(snippet.trigger)?"
        alert.informativeText = "This removes the snippet permanently."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.saveTimer?.invalidate()
            self.items.remove(at: index)
            self.selected = nil
            self.dirty = true
            self.applyFilter()
            self.tableView.reloadData()
            self.selectRow(self.filtered.isEmpty ? nil : min(index, self.filtered.count - 1))
            self.saveNow()
        }
    }

    @objc private func formatChanged() {
        let rich = formatPopup.indexOfSelectedItem == 0
        if !rich {
            let plain = textView.string.replacingOccurrences(of: "\u{FFFC}", with: "")
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: plain, attributes: [.font: defaultFont, .foregroundColor: NSColor.black])
            )
        }
        applyFormatUI(rich: rich)
        scheduleAutosave()
    }

    @objc private func searchChanged() {
        let trigger = selected.flatMap { items.indices.contains($0) ? items[$0].trigger : nil }
        applyFilter()
        tableView.reloadData()
        if let trigger, let index = items.firstIndex(where: { $0.trigger == trigger }),
           let row = filtered.firstIndex(of: index) {
            selectRow(row)
        } else {
            selectRow(filtered.isEmpty ? nil : 0)
        }
    }

    // MARK: Table view

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RoundedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("SnippetCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SnippetCellView
            ?? SnippetCellView(identifier: id)
        cell.configure(with: items[filtered[row]])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        saveTimer?.invalidate()
        if commitEdits() { saveNow() }
        let row = tableView.selectedRow
        selected = (row >= 0 && row < filtered.count) ? filtered[row] : nil
        loadSelection()
    }

    // MARK: Change notifications

    func textDidChange(_ notification: Notification) {
        if (notification.object as? NSTextView) === textView {
            scheduleAutosave()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === triggerField { validateTrigger() }
        scheduleAutosave()
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        flushPendingSave()
        return true
    }
}
