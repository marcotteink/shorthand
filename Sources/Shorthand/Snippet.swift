import Foundation

struct Snippet: Codable, Equatable {
    var trigger: String
    var name: String?
    var format: String?  // "html" or "plain" (default: plain)
    var body: String

    var isHTML: Bool { (format ?? "plain").lowercased() == "html" }
    var isRTFD: Bool { (format ?? "plain").lowercased() == "rtfd" }  // rich text with images, base64 flat RTFD
    var displayName: String { name ?? trigger }
}

final class SnippetStore {
    static let dirURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Shorthand", isDirectory: true)
    }()
    static let fileURL = dirURL.appendingPathComponent("snippets.json")

    private(set) var snippets: [Snippet] = []
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var reloadPending = false

    init() {
        seedIfNeeded()
        load()
        watch()
    }

    private func seedIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dirURL, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: Self.fileURL.path) else { return }
        let seed = """
        [
          {
            "trigger": "/sig",
            "name": "Email signature",
            "format": "html",
            "body": "<p>Best,<br><b>Matt Marcotte</b><br><a href=\\"https://marcotte.ink\\">marcotte.ink</a> &middot; <a href=\\"mailto:matt@marcotte.ink\\">matt@marcotte.ink</a></p>"
          },
          {
            "trigger": "/date",
            "name": "Today's date",
            "body": "{date:MMMM d, yyyy}"
          },
          {
            "trigger": "/time",
            "name": "Current time",
            "body": "{time}"
          },
          {
            "trigger": "/ty",
            "name": "Thank you reply",
            "format": "html",
            "body": "<p>Thanks for reaching out! I'll take a look and get back to you within one business day.</p><p>Best,<br><b>Matt</b></p>"
          },
          {
            "trigger": "/hi",
            "name": "Greeting, cursor placed after name",
            "body": "Hi {cursor},\\n\\n"
          }
        ]
        """
        try? seed.data(using: .utf8)?.write(to: Self.fileURL)
    }

    // Kept in file order for the editor; matching uses a longest-trigger-first copy
    private var matchOrder: [Snippet] = []

    func load() {
        defer { onChange?() }
        guard let data = try? Data(contentsOf: Self.fileURL) else {
            snippets = []
            matchOrder = []
            lastError = "snippets.json not found"
            return
        }
        do {
            var loaded = try JSONDecoder().decode([Snippet].self, from: data)
            loaded.removeAll { $0.trigger.isEmpty }
            snippets = loaded
            matchOrder = loaded.sorted { $0.trigger.count > $1.trigger.count }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func save(_ newSnippets: [Snippet]) {
        var cleaned = newSnippets
        cleaned.removeAll { $0.trigger.isEmpty }
        snippets = cleaned
        matchOrder = cleaned.sorted { $0.trigger.count > $1.trigger.count }
        lastError = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(cleaned) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        onChange?()
    }

    func match(bufferEndingWith buffer: String) -> Snippet? {
        for s in matchOrder where buffer.hasSuffix(s.trigger) { return s }
        return nil
    }

    private func watch() {
        let fd = open(Self.dirURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, !self.reloadPending else { return }
            self.reloadPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.reloadPending = false
                self.load()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }
}
