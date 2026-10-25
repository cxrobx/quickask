import Carbon
import Foundation

/// The selected app's own AppleScript dictionary, and the checks a script passes before it runs.
///
/// A scriptable app does a whole job in one call (resize, crop, export with a quality setting)
/// where the UI route takes a dozen clicks through dialogs. The script runs inside
/// `tell application id "<the selected app>"`; `refusal` rejects every construct that could reach
/// past that app: other apps, shell commands, file reads and writes, the clipboard, raw event codes.
/// It reads only code, not string literals, and fails closed on anything it can't lex.
enum AppScripting {
    static let timeoutSeconds = 30

    /// The app's scripting definition, when it ships one.
    static func definitionURL(bundle: URL) -> URL? {
        guard let info = Bundle(url: bundle)?.infoDictionary else { return nil }
        if let name = info["OSAScriptingDefinition"] as? String, !name.isEmpty {
            let url = bundle.appendingPathComponent("Contents/Resources").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func isScriptable(bundle: URL) -> Bool {
        guard let info = Bundle(url: bundle)?.infoDictionary else { return false }
        let enabled = info["NSAppleScriptEnabled"]
        return definitionURL(bundle: bundle) != nil || enabled as? Bool == true || (enabled as? String)?.lowercased() == "yes"
    }

    /// `tell application id` takes the bundle ID as a string literal; only these characters go in.
    static func safeBundleID(_ id: String?) -> String? {
        guard let id, !id.isEmpty, id.range(of: #"^[A-Za-z0-9.\-]+$"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    static func wrapped(_ body: String, bundleID: String) -> String {
        "with timeout of \(timeoutSeconds - 5) seconds\ntell application id \"\(bundleID)\"\n\(body)\nend tell\nend timeout\n"
    }

    // MARK: Checks

    struct Lexed { var code = ""; var strings: [String] = [] }

    /// Splits a script into code and string literals, dropping comments. Pipe identifiers stay in
    /// the code, so `|application|` is still seen. Nil when a string or comment never closes.
    static func lex(_ source: String) -> Lexed? {
        var out = Lexed()
        let characters = Array(source)
        var index = 0
        while index < characters.count {
            let c = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if c == "\"" {
                var literal = ""
                index += 1
                var closed = false
                while index < characters.count {
                    if characters[index] == "\\", index + 1 < characters.count { literal.append(characters[index + 1]); index += 2; continue }
                    if characters[index] == "\"" { closed = true; break }
                    literal.append(characters[index]); index += 1
                }
                guard closed else { return nil }
                out.strings.append(literal); out.code.append(" \"\" "); index += 1
            } else if c == "-" && next == "-" || c == "#" {
                while index < characters.count, !characters[index].isNewline { index += 1 }
                out.code.append("\n")
            } else if c == "(" && next == "*" {
                var depth = 1
                index += 2
                while index < characters.count, depth > 0 {
                    let pair = index + 1 < characters.count ? String([characters[index], characters[index + 1]]) : ""
                    if pair == "(*" { depth += 1; index += 2 } else if pair == "*)" { depth -= 1; index += 2 } else { index += 1 }
                }
                guard depth == 0 else { return nil }
                out.code.append(" ")
            } else if c == "|" {
                // A pipe identifier: everything up to the closing pipe is a name, read as code.
                index += 1
                var closed = false
                while index < characters.count {
                    if characters[index] == "|" { closed = true; break }
                    out.code.append(characters[index]); index += 1
                }
                guard closed else { return nil }
                out.code.append(" "); index += 1
            } else {
                out.code.append(c); index += 1
            }
        }
        return out
    }

    /// Constructs a script for the selected app never needs, with the reason given to the model.
    private static let forbidden: [(String, String)] = [
        (#"\bapp(lication)?\b"#, "another app (the script already runs inside the selected app; address its objects directly)"),
        (#"«|»"#, "raw event codes"),
        (#"\bdo\s+(shell\s+)?script\b|\b(run|load|store)\s+script\b|\bdo\s+javascript\b|\bosascript\b"#, "running other scripts or shell commands"),
        (#"(^|\n)\s*use\b|\busing\s+terms\s+from\b"#, "use statements and other terminology"),
        (#"\bsystem\s+(attribute|info)\b"#, "reading the environment"),
        (#"\bclipboard\b"#, "the clipboard"),
        (#"\bopen\s+for\s+access\b|\bclose\s+access\b|\b(read|write)\b|\bset\s+eof\b"#, "reading or writing files directly"),
        (#"\bopen\s+location\b|\bmount\s+volume\b"#, "opening URLs or volumes"),
        (#"\bdisplay\s+(dialog|alert|notification)\b|\bchoose\s+(file|folder|from|color|url|remote|application)\b"#, "dialogs that wait for the user"),
        (#"(^|\n)\s*(on|to)\s+\w+"#, "handler definitions (the lines run inside a tell block)"),
    ]

    /// Why this script may not run at all, or nil.
    static func refusal(_ source: String) -> String? {
        guard source.utf8.count <= 20000 else { return "The script is too long. Split the job into smaller scripts." }
        guard let lexed = lex(source) else { return "The script has an unterminated string, comment or |identifier|." }
        let code = lexed.code.lowercased()
        for (pattern, reason) in forbidden where code.range(of: pattern, options: .regularExpression) != nil {
            return "Scripts can't use \(reason). Use only the selected app's own commands."
        }
        return nil
    }

    /// Why this script needs the user's explicit go-ahead first, or nil: it deletes, closes
    /// without saving, quits, or writes over a file that already exists. Edits inside a document
    /// (remove background, clear a selection) are the app's to undo and pass. A destination built
    /// at run time (`path to desktop & "x.jpg"`) can't be checked, so the tool asks for literal paths.
    static func confirmationReason(_ source: String) -> String? {
        guard let lexed = lex(source) else { return nil }
        let code = lexed.code.lowercased()
        if let match = code.range(of: #"\b(delete|erase|quit|close)\b|\bsaving\s+no\b"#, options: .regularExpression) {
            return "It uses “\(code[match])”, which removes or discards content."
        }
        guard code.range(of: #"\b(save|export|duplicate|move|replace)\b"#, options: .regularExpression) != nil else { return nil }
        if let existing = lexed.strings.compactMap(existingPath).first { return "It writes to \(existing), which already exists." }
        if code.range(of: #"\bsave\b"#, options: .regularExpression) != nil, !lexed.strings.contains(where: isPath) {
            return "It saves without a new destination, which writes over the open document's file."
        }
        return nil
    }

    static func isPath(_ literal: String) -> Bool {
        literal.hasPrefix("/") || literal.hasPrefix("~/") || literal.contains(":") && !literal.contains("/") && !literal.hasPrefix(":")
    }

    /// A string literal that names a file already on disk: POSIX (`/…`, `~/…`) or HFS (`Disk:…`).
    static func existingPath(_ literal: String) -> String? {
        guard isPath(literal) else { return nil }
        let path = literal.hasPrefix("/") || literal.hasPrefix("~/") ? (literal as NSString).expandingTildeInPath : hfsToPOSIX(literal)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// `Macintosh HD:Users:me:a.jpg` → `/Users/me/a.jpg`; another disk's name → `/Volumes/<name>/…`.
    static func hfsToPOSIX(_ hfs: String) -> String {
        var parts = hfs.split(separator: ":", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: "/", with: ":") }
        let disk = parts.removeFirst()
        let boot = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        return (disk == boot ? "/" : "/Volumes/\(disk)/") + parts.filter { !$0.isEmpty }.joined(separator: "/")
    }

    // MARK: Dictionary

    struct Item {
        enum Kind: String { case command, `class`, enumeration, record = "record type"
            var plural: String { switch self { case .command: "Commands"; case .class: "Classes"; case .enumeration: "Enumerations"; case .record: "Record types" } }
        }
        let kind: Kind
        let name: String
        let summary: String
        let details: [String]
        let example: String?
    }

    /// The app's commands, objects, records and enumerations; hidden ones left out.
    static func dictionary(bundle: URL) throws -> [Item] {
        // What `sdef` prints, without needing Xcode: the .sdef file, or one built from older formats.
        var raw: Unmanaged<CFData>?
        guard OSACopyScriptingDefinitionFromURL(bundle as CFURL, 0, &raw) == noErr, let data = raw?.takeRetainedValue() as Data?, !data.isEmpty else {
            throw ProviderRunError(message: "The app's dictionary couldn't be read.")
        }
        let document = try XMLDocument(data: data, options: [.documentXInclude])
        func value(_ node: XMLElement, _ name: String) -> String { node.attribute(forName: name)?.stringValue ?? "" }
        func type(_ node: XMLElement) -> String {
            let direct = value(node, "type")
            if !direct.isEmpty { return direct }
            return node.elements(forName: "type").map { value($0, "type") + (value($0, "list") == "yes" ? " list" : "") }.joined(separator: " or ")
        }
        func described(_ node: XMLElement, _ text: String) -> String {
            let description = value(node, "description")
            return description.isEmpty ? text : "\(text) — \(description)"
        }
        func example(_ node: XMLElement) -> String? {
            guard let html = node.elements(forName: "documentation").first?.stringValue else { return nil }
            let plain = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            return plain.isEmpty ? nil : String(plain.prefix(600))
        }
        var items: [Item] = []
        for suite in (try? document.nodes(forXPath: "//suite")) as? [XMLElement] ?? [] where value(suite, "hidden") != "yes" {
            for node in suite.children?.compactMap({ $0 as? XMLElement }) ?? [] where value(node, "hidden") != "yes" {
                let name = value(node, "name")
                guard !name.isEmpty else { continue }
                switch node.name {
                case "command":
                    var details: [String] = []
                    if let direct = node.elements(forName: "direct-parameter").first { details.append(described(direct, "direct: \(type(direct))")) }
                    for parameter in node.elements(forName: "parameter") where value(parameter, "hidden") != "yes" {
                        details.append(described(parameter, "\(value(parameter, "name")) (\(type(parameter))\(value(parameter, "optional") == "yes" ? ", optional" : ""))"))
                    }
                    if let result = node.elements(forName: "result").first { details.append(described(result, "returns \(type(result))")) }
                    items.append(Item(kind: .command, name: name, summary: value(node, "description"), details: details, example: example(node)))
                case "class", "class-extension", "record-type":
                    let className = name.isEmpty ? value(node, "extends") : name
                    var details: [String] = []
                    if node.name != "record-type", !value(node, "inherits").isEmpty { details.append("inherits \(value(node, "inherits"))") }
                    let properties = node.elements(forName: "property").filter { value($0, "hidden") != "yes" }
                        .map { "\(value($0, "name")) (\(type($0))\(value($0, "access") == "r" ? ", read-only" : ""))" }
                    if !properties.isEmpty { details.append("properties: " + properties.joined(separator: ", ")) }
                    let elements = node.elements(forName: "element").filter { value($0, "hidden") != "yes" }.map { value($0, "type") }
                    if !elements.isEmpty { details.append("elements: " + elements.joined(separator: ", ")) }
                    items.append(Item(kind: node.name == "record-type" ? .record : .class, name: className, summary: value(node, "description"), details: details, example: example(node)))
                case "enumeration":
                    let values = node.elements(forName: "enumerator").filter { value($0, "hidden") != "yes" }.map { value($0, "name") }
                    items.append(Item(kind: .enumeration, name: name, summary: value(node, "description"), details: ["values: " + values.joined(separator: ", ")], example: nil))
                default: continue
                }
            }
        }
        return items
    }

    /// Without a query, every name by kind; with one, the full entries that match it.
    static func render(_ items: [Item], query: String?) -> String {
        let words = (query ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else {
            let kinds: [Item.Kind] = [.command, .class, .record, .enumeration]
            let groups = kinds.compactMap { kind -> String? in
                let names = Array(Set(items.filter { $0.kind == kind }.map(\.name))).sorted()
                return names.isEmpty ? nil : "\(kind.plural): \(names.joined(separator: ", "))"
            }
            return (groups + ["Call app_dictionary with a query (a command or object name) for parameters, properties and the app's own example scripts."]).joined(separator: "\n\n")
        }
        // Name matches first, then the most words matched in names and descriptions.
        func score(_ item: Item) -> Int {
            let name = item.name.lowercased(), text = (item.summary + " " + item.details.joined(separator: " ")).lowercased()
            return words.reduce(0) { $0 + (name == $1 ? 10 : name.contains($1) ? 4 : text.contains($1) ? 1 : 0) }
        }
        let matches = items.map { ($0, score($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
        guard !matches.isEmpty else { return "Nothing in the dictionary matches “\(query ?? "")”. Call app_dictionary without a query to list every name." }
        var output = ""
        for item in matches {
            var entry = "\(item.kind.rawValue) \(item.name)\(item.summary.isEmpty ? "" : " — \(item.summary)")"
            for detail in item.details { entry += "\n  " + detail }
            if let example = item.example { entry += "\n  " + example }
            guard output.count + entry.count < 12000 else { output += "\n\n(More matches; narrow the query.)"; break }
            output += (output.isEmpty ? "" : "\n\n") + entry
        }
        return output
    }
}
