import AppKit

final class Expander {

    private struct Rendered {
        let attributed: NSAttributedString?
        let plain: String
        let cursorBack: Int
    }

    private static let cursorToken = "[[SHCURSOR]]"

    // MARK: - Public

    /// Replace the just-typed trigger with the rendered snippet in the frontmost app.
    func expand(_ snippet: Snippet) {
        let triggerLength = snippet.trigger.count
        // Let the final trigger character land in the app before we start deleting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.deleteChars(triggerLength)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                self.pasteRendered(snippet)
            }
        }
    }

    /// Render a snippet straight onto the clipboard (used from the menu).
    func copyToPasteboard(_ snippet: Snippet) {
        let rendered = render(snippet)
        writePasteboard(rendered)
    }

    // MARK: - Key synthesis

    private func post(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: KeyMonitor.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private func deleteChars(_ count: Int) {
        for _ in 0..<count {
            post(keyCode: 51)
            usleep(8000)
        }
    }

    // MARK: - Paste pipeline

    private func pasteRendered(_ snippet: Snippet) {
        let rendered = render(snippet)
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        writePasteboard(rendered)
        post(keyCode: 9, flags: .maskCommand)  // Cmd+V

        if rendered.cursorBack > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                for _ in 0..<rendered.cursorBack {
                    self.post(keyCode: 123)  // left arrow
                    usleep(4000)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.restore(pasteboard, items: saved)
        }
    }

    private func writePasteboard(_ rendered: Rendered) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let attributed = rendered.attributed {
            let fullRange = NSRange(location: 0, length: attributed.length)
            let hasImages = attributed.string.contains("\u{FFFC}")
            if hasImages {
                // Native apps take flat RTFD (full fidelity), browsers take HTML with embedded images
                if let rtfd = try? attributed.data(
                    from: fullRange,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
                ) {
                    item.setData(rtfd, forType: .rtfd)
                }
                item.setString(Self.htmlWithEmbeddedImages(attributed), forType: .html)
                // Image-only snippet: offer the raw image so chat apps and upload fields accept it
                if let (data, type) = Self.soleImage(in: attributed) {
                    item.setData(data, forType: type)
                    if type.rawValue != "public.tiff", let image = NSImage(data: data),
                       let tiff = image.tiffRepresentation {
                        item.setData(tiff, forType: .tiff)
                    }
                }
            } else if let htmlData = try? attributed.data(
                from: fullRange,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
            ), let html = String(data: htmlData, encoding: .utf8) {
                item.setString(html, forType: .html)
            }
            if let rtf = try? attributed.data(
                from: fullRange,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ) {
                item.setData(rtf, forType: .rtf)
            }
        }
        if !rendered.plain.isEmpty || rendered.attributed == nil {
            item.setString(rendered.plain, forType: .string)
        }
        pasteboard.writeObjects([item])
    }

    // MARK: - Clipboard save / restore

    private func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var byType = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) { byType[type] = data }
            }
            return byType
        }
    }

    private func restore(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { byType -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in byType { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    // MARK: - Rendering

    private func render(_ snippet: Snippet) -> Rendered {
        if snippet.isRTFD {
            guard let data = Data(base64Encoded: snippet.body),
                  let imported = try? NSAttributedString(
                      data: data,
                      options: [.documentType: NSAttributedString.DocumentType.rtfd],
                      documentAttributes: nil
                  )
            else { return Rendered(attributed: nil, plain: "", cursorBack: 0) }
            let attributed = NSMutableAttributedString(attributedString: imported)
            let cursorBack = Self.renderDynamicContent(in: attributed)
            let plain = attributed.string.replacingOccurrences(of: "\u{FFFC}", with: "")
            return Rendered(attributed: attributed, plain: plain, cursorBack: cursorBack)
        }

        var body = snippet.body.replacingOccurrences(of: "{cursor}", with: Self.cursorToken)
        body = Self.substitutePlaceholders(in: body, escapeHTML: snippet.isHTML)

        if snippet.isHTML {
            guard let data = Self.defaultFontWrapped(body).data(using: .utf8),
                  let imported = try? NSAttributedString(
                      data: data,
                      options: [
                          .documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue
                      ],
                      documentAttributes: nil
                  )
            else {
                let fallback = body.replacingOccurrences(of: Self.cursorToken, with: "")
                return Rendered(attributed: nil, plain: fallback, cursorBack: 0)
            }
            let attributed = NSMutableAttributedString(attributedString: imported)
            // HTML import appends a trailing newline
            while attributed.string.hasSuffix("\n") {
                attributed.deleteCharacters(in: NSRange(location: attributed.length - 1, length: 1))
            }
            var cursorBack = 0
            let range = (attributed.string as NSString).range(of: Self.cursorToken)
            if range.location != NSNotFound {
                let tail = (attributed.string as NSString).substring(from: range.location + range.length)
                cursorBack = tail.count
                attributed.deleteCharacters(in: range)
            }
            return Rendered(attributed: attributed, plain: attributed.string, cursorBack: cursorBack)
        } else {
            var plain = body
            var cursorBack = 0
            if let range = plain.range(of: Self.cursorToken) {
                cursorBack = plain.distance(from: range.upperBound, to: plain.endIndex)
                plain.removeSubrange(range)
            }
            return Rendered(attributed: nil, plain: plain, cursorBack: cursorBack)
        }
    }

    /// Give HTML snippets a sane default font unless they set their own.
    static func defaultFontWrapped(_ body: String) -> String {
        if body.range(of: "font-family", options: .caseInsensitive) != nil { return body }
        return "<div style=\"font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 13px;\">\(body)</div>"
    }

    // MARK: - Placeholders

    static func substitutePlaceholders(in text: String, escapeHTML: Bool) -> String {
        var out = text
        let now = Date()

        if let regex = try? NSRegularExpression(pattern: "\\{(date|time)(?::([^}]+))?\\}") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let kind = ns.substring(with: match.range(at: 1))
                let formatter = DateFormatter()
                if match.range(at: 2).location != NSNotFound {
                    formatter.dateFormat = ns.substring(with: match.range(at: 2))
                } else if kind == "date" {
                    formatter.dateStyle = .long
                    formatter.timeStyle = .none
                } else {
                    formatter.dateStyle = .none
                    formatter.timeStyle = .short
                }
                var value = formatter.string(from: now)
                if escapeHTML { value = htmlEscaped(value) }
                result += value
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            out = result
        }

        if out.contains("{clipboard}") {
            var value = NSPasteboard.general.string(forType: .string) ?? ""
            if escapeHTML {
                value = htmlEscaped(value).replacingOccurrences(of: "\n", with: "<br>")
            }
            out = out.replacingOccurrences(of: "{clipboard}", with: value)
        }

        return out
    }

    private static func htmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Attributed (image-capable) rendering

    /// Substitute {date}/{time}/{clipboard} in place, preserving formatting and
    /// images, then remove {cursor} and return how many characters the cursor
    /// should step back after pasting.
    @discardableResult
    static func renderDynamicContent(in attributed: NSMutableAttributedString) -> Int {
        func attributesNear(_ location: Int) -> [NSAttributedString.Key: Any] {
            guard attributed.length > 0 else { return [:] }
            return attributed.attributes(at: min(location, attributed.length - 1), effectiveRange: nil)
        }

        if let regex = try? NSRegularExpression(pattern: "\\{(date|time)(?::([^}]+))?\\}") {
            let matches = regex.matches(
                in: attributed.string,
                range: NSRange(location: 0, length: (attributed.string as NSString).length)
            )
            let now = Date()
            for match in matches.reversed() {
                let ns = attributed.string as NSString
                let kind = ns.substring(with: match.range(at: 1))
                let formatter = DateFormatter()
                if match.range(at: 2).location != NSNotFound {
                    formatter.dateFormat = ns.substring(with: match.range(at: 2))
                } else if kind == "date" {
                    formatter.dateStyle = .long
                    formatter.timeStyle = .none
                } else {
                    formatter.dateStyle = .none
                    formatter.timeStyle = .short
                }
                attributed.replaceCharacters(in: match.range, with: NSAttributedString(
                    string: formatter.string(from: now),
                    attributes: attributesNear(match.range.location)
                ))
            }
        }

        while true {
            let range = (attributed.string as NSString).range(of: "{clipboard}")
            guard range.location != NSNotFound else { break }
            let value = NSPasteboard.general.string(forType: .string) ?? ""
            attributed.replaceCharacters(in: range, with: NSAttributedString(
                string: value,
                attributes: attributesNear(range.location)
            ))
        }

        var cursorBack = 0
        let cursorRange = (attributed.string as NSString).range(of: "{cursor}")
        if cursorRange.location != NSNotFound {
            let tail = (attributed.string as NSString).substring(from: cursorRange.location + cursorRange.length)
            cursorBack = tail.count
            attributed.deleteCharacters(in: cursorRange)
        }
        return cursorBack
    }

    /// HTML where every attachment becomes a data: URI image, for pasting into browsers.
    static func htmlWithEmbeddedImages(_ attributed: NSAttributedString) -> String {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        var tags: [(token: String, tag: String)] = []
        var index = 0
        mutable.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: mutable.length),
            options: [.reverse]
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            index += 1
            let token = "SHIMG\(index)TOKEN"
            guard let (data, mime) = Self.webImageData(from: attachment) else {
                mutable.replaceCharacters(in: range, with: NSAttributedString(string: ""))
                return
            }
            var sizeAttr = ""
            if attachment.bounds.width > 0 {
                sizeAttr = " width=\"\(Int(attachment.bounds.width))\""
            }
            tags.append((token, "<img src=\"data:\(mime);base64,\(data.base64EncodedString())\"\(sizeAttr)>"))
            mutable.replaceCharacters(in: range, with: NSAttributedString(string: token))
        }

        var html: String
        if mutable.length > 0, let data = try? mutable.data(
            from: NSRange(location: 0, length: mutable.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
        ), let exported = String(data: data, encoding: .utf8) {
            html = exported
        } else {
            html = mutable.string
        }
        for (token, tag) in tags {
            html = html.replacingOccurrences(of: token, with: tag)
        }
        return html
    }

    /// Original bytes and a browser-friendly mime type for an attachment.
    /// TIFF/HEIC/unknown formats are converted to PNG.
    private static func webImageData(from attachment: NSTextAttachment) -> (Data, String)? {
        if let wrapper = attachment.fileWrapper, let data = wrapper.regularFileContents {
            let ext = ((wrapper.preferredFilename ?? "") as NSString).pathExtension.lowercased()
            let webMimes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                            "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp"]
            if let mime = webMimes[ext] { return (data, mime) }
            if let image = NSImage(data: data), let png = pngData(image) { return (png, "image/png") }
            return nil
        }
        if let image = attachment.image, let png = pngData(image) { return (png, "image/png") }
        return nil
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// If the content is exactly one image and no text, return its raw data and
    /// pasteboard type so image-only snippets paste into chat apps and uploaders.
    static func soleImage(in attributed: NSAttributedString) -> (Data, NSPasteboard.PasteboardType)? {
        var images: [(Data, String)] = []
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let wrapper = attachment.fileWrapper, let data = wrapper.regularFileContents {
                images.append((data, ((wrapper.preferredFilename ?? "") as NSString).pathExtension.lowercased()))
            } else if let image = attachment.image, let png = pngData(image) {
                images.append((png, "png"))
            }
        }
        guard images.count == 1 else { return nil }
        let leftoverText = attributed.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard leftoverText.isEmpty else { return nil }

        let (data, ext) = images[0]
        let types = ["png": "public.png", "gif": "com.compuserve.gif",
                     "jpg": "public.jpeg", "jpeg": "public.jpeg",
                     "tiff": "public.tiff", "tif": "public.tiff"]
        if let uti = types[ext] {
            return (data, NSPasteboard.PasteboardType(uti))
        }
        if let image = NSImage(data: data), let png = pngData(image) {
            return (png, NSPasteboard.PasteboardType("public.png"))
        }
        return nil
    }
}
