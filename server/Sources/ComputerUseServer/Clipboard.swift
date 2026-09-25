import AppKit

@MainActor
enum Clipboard {
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    static func save() -> Snapshot {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    static func restore(_ snapshot: Snapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Puts text on the pasteboard as plain text, Markdown (rendered to rich text) or HTML.
    static func put(_ text: String, format: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        switch format.lowercased() {
        case "text", "plain", "":
            item.setString(text, forType: .string)
        case "html", "md", "markdown":
            let html = format.lowercased() == "html" ? text : Markdown.toHTML(text)
            let wrapped = "<meta charset=\"utf-8\">" + html
            item.setString(html, forType: .html)
            if let attributed = NSAttributedString(html: Data(wrapped.utf8), documentAttributes: nil) {
                let range = NSRange(location: 0, length: attributed.length)
                if let rtf = try? attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    item.setData(rtf, forType: .rtf)
                }
                item.setString(format.lowercased() == "html" ? attributed.string : text, forType: .string)
            } else {
                item.setString(text, forType: .string)
            }
        default:
            throw ToolError("format must be text, md or html")
        }
        pasteboard.writeObjects([item])
    }
}

/// Minimal Markdown -> HTML (headings, lists, quotes, code, bold, italic, links).
enum Markdown {
    static func toHTML(_ markdown: String) -> String {
        var html = ""
        var paragraph: [String] = []
        var list: String?
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                html += "<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>\n"
                paragraph = []
            }
        }
        func closeList() {
            if let open = list {
                html += "</\(open)>\n"
                list = nil
            }
        }
        func openList(_ kind: String) {
            if list != kind {
                closeList()
                html += "<\(kind)>\n"
                list = kind
            }
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                closeList()
                html += inCode ? "</code></pre>\n" : "<pre><code>"
                inCode.toggle()
                continue
            }
            if inCode {
                html += escape(line) + "\n"
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                closeList()
                continue
            }
            if let hashes = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushParagraph()
                closeList()
                let level = trimmed[hashes].filter { $0 == "#" }.count
                html += "<h\(level)>\(inline(String(trimmed[hashes.upperBound...])))</h\(level)>\n"
                continue
            }
            if let bullet = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flushParagraph()
                openList("ul")
                html += "<li>\(inline(String(trimmed[bullet.upperBound...])))</li>\n"
                continue
            }
            if let number = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                openList("ol")
                html += "<li>\(inline(String(trimmed[number.upperBound...])))</li>\n"
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                closeList()
                html += "<blockquote>\(inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>\n"
                continue
            }
            closeList()
            paragraph.append(trimmed)
        }
        flushParagraph()
        closeList()
        if inCode { html += "</code></pre>\n" }
        return html
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ s: String) -> String {
        var r = escape(s)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"__([^_]+)__"#, "<b>$1</b>"),
            (#"(?<![\w*])\*([^*]+)\*(?![\w*])"#, "<i>$1</i>"),
            (#"(?<![\w_])_([^_]+)_(?![\w_])"#, "<i>$1</i>"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            r = r.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return r
    }
}
