import Foundation
import PDFKit

/// Onyx's page, read the way its ask box reads it. The first prompt carries the highlighted passage
/// and the text around it, or a page excerpt; these tools let the model read more only when the
/// question needs it, in place of the `--add-dir` Onyx gives its own answers. Read-only, scoped to
/// the page Onyx shows and the folder it sits in.
struct OnyxPage {
    static let tools = ["read_page", "search_page", "read_nearby"]
    static let chunkLimit = 20_000
    static let fileLimit = 4_000_000

    let document: URL
    let revision: String
    var folder: URL { document.deletingLastPathComponent() }
    private var cache: [String: String] = [:]

    init?(records: [String: String]) {
        guard let path = records["document_path"], path.hasPrefix("/") else { return nil }
        document = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        revision = records["document_revision"] ?? ""
    }

    static var definitions: [[String: Any]] {
        let integer: [String: Any] = ["type": "integer"], string: [String: Any] = ["type": "string"]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false]]
        }
        return [
            tool("read_page", "Read the page open in Onyx as plain text, in chunks. offset is a character offset (default 0); limit up to \(chunkLimit) (default 12000). The reply says the page's full length.",
                 ["offset": integer, "limit": integer]),
            tool("search_page", "Find a word or phrase in the page open in Onyx. Returns each match with its character offset and the text around it; read_page from that offset for more.",
                 ["query": string, "limit": integer], ["query"]),
            tool("read_nearby", "Read a file in the folder of the page open in Onyx, or that folder's subfolders, as text; a folder path (or empty) lists it. path is relative to the page's folder. offset and limit work as in read_page.",
                 ["path": string, "offset": integer, "limit": integer])
        ]
    }

    mutating func call(_ tool: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let text: String
        switch tool {
        case "read_page":
            text = Self.chunk(try pageText(), offset: arguments["offset"], limit: arguments["limit"], name: document.lastPathComponent)
        case "search_page":
            guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { throw ProviderRunError(message: "Give a word or phrase to find.") }
            text = Self.search(try pageText(), query: query, limit: min(max((arguments["limit"] as? NSNumber)?.intValue ?? 8, 1), 20))
        case "read_nearby":
            text = try nearby(arguments["path"] as? String ?? "", offset: arguments["offset"], limit: arguments["limit"])
        default: throw ProviderRunError(message: "This Onyx tool is unavailable.")
        }
        return ["content": [["type": "text", "text": text]], "isError": false]
    }

    /// The page as Onyx showed it: refused once the file has changed on disk since.
    private mutating func pageText() throws -> String {
        if let text = cache[document.path] { return text }
        if !revision.isEmpty {
            guard Self.revision(document.path) == revision else {
                throw ProviderRunError(message: "The page changed on disk since Onyx showed it. Let Onyx reload it, then ask again.")
            }
        }
        let text = try Self.text(of: document)
        cache[document.path] = text
        return text
    }

    private mutating func nearby(_ requested: String, offset: Any?, limit: Any?) throws -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.hasPrefix("/") ? URL(fileURLWithPath: trimmed) : folder.appendingPathComponent(trimmed)
        let url = candidate.resolvingSymlinksInPath().standardizedFileURL
        // Components, after symlinks: a sibling named like the folder, or a link out of it, is outside.
        let root = folder.pathComponents, parts = url.pathComponents
        guard parts.count >= root.count, Array(parts.prefix(root.count)) == root else { throw ProviderRunError(message: "Only the page's own folder can be read from Quick Ask.") }
        let inside = parts.dropFirst(root.count)
        guard !inside.contains(where: { $0.hasPrefix(".") }), !Self.sensitive(url.lastPathComponent) else { throw ProviderRunError(message: "Hidden files and key files are not readable from Quick Ask.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw ProviderRunError(message: "No such file in the page's folder.") }
        if isDirectory.boolValue {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            let shown = names.filter { !$0.hasPrefix(".") && !Self.sensitive($0) }.sorted().prefix(200).map { name -> String in
                var child: ObjCBool = false
                FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &child)
                return child.boolValue ? name + "/" : name
            }
            let relative = inside.isEmpty ? "." : inside.joined(separator: "/")
            return "Folder \(relative) (\(names.count) entries\(names.count > 200 ? ", first 200 shown" : "")):\n" + shown.joined(separator: "\n")
        }
        if url.path == document.path { return Self.chunk(try pageText(), offset: offset, limit: limit, name: url.lastPathComponent) }
        let text: String
        if let cached = cache[url.path] { text = cached } else { text = try Self.text(of: url); cache[url.path] = text }
        return Self.chunk(text, offset: offset, limit: limit, name: inside.joined(separator: "/"))
    }

    /// Onyx's document signature (`st_mtime_ns:st_size`), as its reader stamps the page.
    static func revision(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return "\(Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)):\(info.st_size)"
    }

    static func sensitive(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix(".env") || [".pem", ".key", ".p12", ".keychain", ".sqlite", ".db"].contains { lower.hasSuffix($0) }
            || lower.hasPrefix("id_rsa") || lower.hasPrefix("id_ed25519") || lower.contains("credential") || lower.contains("secret")
    }

    // MARK: Text

    static func text(of url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= fileLimit else { throw ProviderRunError(message: "\(url.lastPathComponent) is too large to read here (over 4 MB).") }
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw ProviderRunError(message: "\(url.lastPathComponent) couldn't be read as a PDF.") }
            return (0..<pdf.pageCount).compactMap { index in pdf.page(at: index)?.string.map { "[page \(index + 1)]\n\($0)" } }.joined(separator: "\n\n")
        case "html", "htm", "xhtml":
            return htmlText(try readUTF8(url))
        default:
            return try readUTF8(url)
        }
    }

    private static func readUTF8(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard !data.prefix(8_000).contains(0), let text = String(data: data, encoding: .utf8) else { throw ProviderRunError(message: "\(url.lastPathComponent) isn't a text file.") }
        return text
    }

    /// Readable text from HTML, without a web view: scripts, styles and the head dropped, block
    /// elements on their own lines, headings marked so the model can see the page's outline.
    static func htmlText(_ html: String) -> String {
        var text = html
        func replace(_ pattern: String, _ with: String) {
            text = text.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
        }
        replace("<!--[\\s\\S]*?-->", "")
        replace("<(script|style|head|template|noscript|svg)\\b[\\s\\S]*?</\\1\\s*>", "")
        for level in 1...6 { replace("<h\(level)\\b[^>]*>", "\n\n" + String(repeating: "#", count: level) + " ") }
        replace("<li\\b[^>]*>", "\n- ")
        replace("<br\\s*/?>", "\n")
        replace("</?(p|div|section|article|header|footer|main|aside|nav|ul|ol|table|tr|blockquote|pre|figure|figcaption|details|summary|h[1-6])\\b[^>]*>", "\n")
        replace("</t[dh]\\s*>", " | ")
        replace("<[^>]+>", "")
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                        "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&middot;": "·"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        replace("&#(\\d+);", "")
        replace("[ \\t]+", " ")
        replace(" *\\n *", "\n")
        replace("\\n{3,}", "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func chunk(_ text: String, offset: Any?, limit: Any?, name: String) -> String {
        let total = text.count
        let start = min(max((offset as? NSNumber)?.intValue ?? 0, 0), total)
        let count = min(max((limit as? NSNumber)?.intValue ?? 12_000, 1), chunkLimit)
        let from = text.index(text.startIndex, offsetBy: start)
        let to = text.index(from, offsetBy: min(count, total - start))
        let end = start + text.distance(from: from, to: to)
        let more = end < total ? " More follows: read_page with offset \(end)." : " This is the end."
        return "\(name): characters \(start)–\(end) of \(total).\(more)\n\n" + String(text[from..<to])
    }

    static func search(_ text: String, query: String, limit: Int) -> String {
        func matches(_ needle: String) -> [Range<String.Index>] {
            var found: [Range<String.Index>] = [], start = text.startIndex
            while found.count < limit, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                found.append(range); start = range.upperBound
            }
            return found
        }
        var ranges = matches(query), note = ""
        if ranges.isEmpty {
            // No exact phrase: its longer words instead.
            let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 4 }
            ranges = words.flatMap(matches).sorted { $0.lowerBound < $1.lowerBound }
            ranges = Array(ranges.prefix(limit))
            if !ranges.isEmpty { note = " No exact match for the phrase; these match its words." }
        }
        guard !ranges.isEmpty else { return "No match for \"\(query)\" in the page (\(text.count) characters)." }
        let lines = ranges.map { range -> String in
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let before = text.index(range.lowerBound, offsetBy: -min(300, offset))
            let after = text.index(range.upperBound, offsetBy: min(300, text.distance(from: range.upperBound, to: text.endIndex)))
            return "[offset \(offset)] …\(text[before..<after].replacingOccurrences(of: "\n", with: " "))…"
        }
        return "\(ranges.count) match(es) for \"\(query)\".\(note)\n\n" + lines.joined(separator: "\n\n")
    }
}
