import SwiftUI
import AppKit

/// One block of an answer, from Foundation's full Markdown parse. Inline styling (bold,
/// italic, code, links) stays on each block's AttributedString, which Text renders.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        /// `ordinal` is nil for a bullet; `marker` is false for a list item's later paragraphs.
        case listItem(ordinal: Int?, depth: Int, marker: Bool)
        case quote
        case code(language: String?)
        case table(header: [AttributedString], rows: [[AttributedString]])
        case rule
        case image(URL, alt: String)
        case video(URL, alt: String)
        /// A local HTML file, or a claude.ai artifact, rendered live in the reply.
        case page(URL, alt: String)
    }
    let id: Int
    let kind: Kind
    var text: AttributedString = AttributedString()

    var plain: String { String(text.characters) }
}

enum MarkdownBlocks {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source))]
        }
        var blocks: [MarkdownBlock] = []
        var tableID: Int?, header: [AttributedString] = [], rows: [[AttributedString]] = [], rowIndex: Int?
        var listItemsSeen = Set<Int>()

        func flushTable() {
            guard tableID != nil else { return }
            blocks.append(MarkdownBlock(id: blocks.count, kind: .table(header: header, rows: rows)))
            tableID = nil; header = []; rows = []; rowIndex = nil
        }

        for (intent, range) in document.runs[\.presentationIntent] {
            var text = AttributedString(document[range])
            text.presentationIntent = nil
            let components = intent?.components ?? []
            let kinds = components.map(\.kind)

            // Table cells gather into one table block.
            if let table = components.first(where: { if case .table = $0.kind { return true }; return false }) {
                if tableID != table.identity { flushTable(); tableID = table.identity }
                let isHeader = kinds.contains { if case .tableHeaderRow = $0 { return true }; return false }
                var row: Int? = nil, column: Int? = nil
                for kind in kinds {
                    if case .tableRow(let index) = kind { row = index }
                    if case .tableCell(let index) = kind { column = index }
                }
                // An empty cell has no text run, so each cell goes to its own column, not the next free one.
                func place(_ cells: inout [AttributedString]) {
                    let at = column ?? cells.count
                    while cells.count < at { cells.append(AttributedString()) }
                    if at < cells.count { cells[at] = text } else { cells.append(text) }
                }
                if isHeader { place(&header) }
                else {
                    if row != rowIndex || rows.isEmpty { rows.append([]); rowIndex = row }
                    place(&rows[rows.count - 1])
                }
                continue
            }
            flushTable()

            let kind: MarkdownBlock.Kind
            if kinds.contains(where: { if case .thematicBreak = $0 { return true }; return false }) {
                kind = .rule
            } else if let language = kinds.lazy.compactMap({ kind -> String?? in if case .codeBlock(let hint) = kind { return .some(hint) }; return nil }).first {
                // The parser keeps the fence's last newline; the block's own padding replaces it.
                while text.characters.last == "\n" { text.characters.removeLast() }
                kind = .code(language: language?.isEmpty == false ? language : nil)
            } else if let level = kinds.lazy.compactMap({ kind -> Int? in if case .header(let level) = kind { return level }; return nil }).first {
                kind = .heading(level)
            } else if let item = components.first(where: { if case .listItem = $0.kind { return true }; return false }),
                      case .listItem(let ordinal) = item.kind {
                let depth = kinds.filter { if case .orderedList = $0 { return true }; if case .unorderedList = $0 { return true }; return false }.count
                // The nearest list decides bullet or number.
                let ordered = kinds.first { if case .orderedList = $0 { return true }; if case .unorderedList = $0 { return true }; return false }
                    .map { if case .orderedList = $0 { return true }; return false } ?? false
                kind = .listItem(ordinal: ordered ? ordinal : nil, depth: max(1, depth), marker: listItemsSeen.insert(item.identity).inserted)
            } else if kinds.contains(where: { if case .blockQuote = $0 { return true }; return false }) {
                kind = .quote
            } else {
                kind = .paragraph
            }

            // Images become their own blocks after the text they sat in; a paragraph that was
            // only an image (or only a path to a local image) leaves nothing else behind.
            // Videos and pages work the same way: a Markdown image whose target is one, or its path alone.
            var images: [MarkdownBlock] = []
            if case .rule = kind {} else if case .code = kind {} else {
                let found = text.runs[\.imageURL].compactMap { url, range in url.map { ($0, range) } }
                images = found.map { MarkdownBlock(id: 0, kind: media($0.0, alt: String(text[$0.1].characters))) }
                for (_, range) in found.reversed() { text.removeSubrange(range) }
                if images.isEmpty, case .paragraph = kind, let shown = standalone(text) {
                    images.append(MarkdownBlock(id: 0, kind: shown))
                    text = AttributedString()
                }
            }
            if !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind == .rule {
                blocks.append(MarkdownBlock(id: blocks.count, kind: kind, text: text))
            }
            for image in images { blocks.append(MarkdownBlock(id: blocks.count, kind: image.kind)) }
        }
        flushTable()
        return blocks
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
    static let pageExtensions: Set<String> = ["html", "htm"]

    /// What a Markdown image's target shows as: a local video or page by its extension, a
    /// claude.ai artifact as a page, anything else as an image.
    static func media(_ url: URL, alt: String) -> MarkdownBlock.Kind {
        if let file = fileURL(url) {
            let ext = file.pathExtension.lowercased()
            if videoExtensions.contains(ext) { return .video(file, alt: alt) }
            if pageExtensions.contains(ext) { return .page(file, alt: alt) }
        }
        if let artifact = artifactURL(url.absoluteString) { return .page(artifact, alt: alt) }
        return .image(url, alt: alt)
    }

    /// A paragraph that is only a local media path, an artifact URL, or a link to an artifact.
    static func standalone(_ text: AttributedString) -> MarkdownBlock.Kind? {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if let file = localMedia(plain) {
            let ext = file.pathExtension.lowercased()
            return videoExtensions.contains(ext) ? .video(file, alt: file.lastPathComponent)
                : pageExtensions.contains(ext) ? .page(file, alt: file.lastPathComponent) : .image(file, alt: file.lastPathComponent)
        }
        if let artifact = artifactURL(plain) { return .page(artifact, alt: "") }
        // [Title](https://claude.ai/artifact/…) with nothing else in the paragraph.
        let links = text.runs[\.link].compactMap { link, range in link.map { ($0, range) } }
        if links.count == 1, let (link, range) = links.first, let artifact = artifactURL(link.absoluteString),
           String(text[range].characters).trimmingCharacters(in: .whitespacesAndNewlines) == plain {
            return .page(artifact, alt: plain == link.absoluteString ? "" : plain)
        }
        return nil
    }

    /// A claude.ai artifact link (claude.ai/artifact/{id} or claude.ai/code/artifact/{uuid}).
    static func artifactURL(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`<>")))
        guard value.range(of: "^https://claude\\.ai/(?:code/)?artifact/[A-Za-z0-9-]+/?(?:[?#][^\\s]*)?$", options: .regularExpression) != nil else { return nil }
        return URL(string: value)
    }

    /// A bare absolute path (or ~ path, or file URL) to an image file that exists.
    static func localImage(_ text: String) -> URL? {
        localMedia(text).flatMap { imageExtensions.contains($0.pathExtension.lowercased()) ? $0 : nil }
    }

    /// A bare absolute path (or ~ path, or file URL) to an image, video or HTML file that exists.
    static func localMedia(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        guard !value.contains("\n"), value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("file://") else { return nil }
        let url = value.hasPrefix("file://") ? URL(string: value) : URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        let known = imageExtensions.union(videoExtensions).union(pageExtensions)
        guard let url, known.contains(url.pathExtension.lowercased()), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The newest local page an answer in this chat shows: the one a follow-up most likely means.
    static func latestPage(in texts: [String]) -> URL? {
        for text in texts.reversed() {
            for block in parse(text).reversed() { if case .page(let url, _) = block.kind, url.isFileURL { return url } }
        }
        return nil
    }

    /// A Markdown image's target as a local file, when it is one: file URLs and absolute or ~ paths.
    static func fileURL(_ url: URL) -> URL? {
        if url.isFileURL { return url }
        guard url.scheme == nil else { return nil }
        let path = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

/// An assistant answer rendered as Markdown: headings, lists, quotes, code, tables, rules,
/// links and images. Consecutive prose blocks share one text view, so a selection runs
/// across paragraphs, lists, quotes and code.
/// Whether the whole popup uses the Obsidian vault's font (JetBrains Mono)
/// instead of the system font. GlassAppearance keeps it in sync with its setting.
var vaultFontEnabled = false

private func vaultFont(size: CGFloat) -> NSFont? {
    vaultFontEnabled ? NSFont(name: "JetBrainsMono-Regular", size: size - 1) : nil
}

/// The popup's font: the system font, or the vault font a point smaller since it
/// runs wider. Falls back to the system font when JetBrains Mono isn't installed.
func appFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
    vaultFont(size: size) != nil ? .custom("JetBrains Mono", size: size - 1).weight(weight) : .system(size: size, weight: weight, design: design)
}

func appNSFont(size: CGFloat) -> NSFont { vaultFont(size: size) ?? .systemFont(ofSize: size) }

struct MarkdownView: View, Equatable {
    let text: String
    var color: Color = .white.opacity(0.92)
    var accent: Color = .white
    /// Part of equality, so replies redraw when the font setting changes.
    var vaultFont = false

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MarkdownProse.segments(blocks)) { segment in
                Group {
                    if segment.blocks.count > 1 || MarkdownProse.flows(segment.blocks[0]) {
                        ProseText(blocks: segment.blocks, color: NSColor(color), accent: NSColor(accent), vaultFont: vaultFont)
                    } else {
                        view(for: segment.blocks[0])
                    }
                }
                .padding(.top, segment.id == 0 ? 0 : MarkdownProse.spacing(before: segment.blocks[0], after: blocks[segment.id - 1]))
            }
        }
        .textSelection(.enabled)
        .tint(accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tables, rules and media: everything the prose view can't flow as text.
    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .table(let header, let rows):
            // Cells wrap to the window instead of scrolling sideways: the layout shares the
            // width out between columns and each row grows to its tallest cell.
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            let grid = (header.isEmpty ? [] : [header]) + rows
            TableLayout(columns: columns) {
                ForEach(grid.indices, id: \.self) { row in
                    ForEach(0..<columns, id: \.self) { column in
                        cell(column < grid[row].count ? grid[row][column] : AttributedString(), bold: row == 0 && !header.isEmpty,
                             topRule: row > 0, leadingRule: column > 0)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .rule:
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 4)
        case .image(let url, let alt):
            MarkdownImage(url: url, alt: alt)
        case .video(let url, let alt):
            InlineVideo(url: url, alt: alt)
        case .page(let url, let alt):
            InlinePage(url: url, alt: alt)
        default:
            EmptyView()
        }
    }

    private func cell(_ text: AttributedString, bold: Bool, topRule: Bool, leadingRule: Bool) -> some View {
        Text(text).font(appFont(size: 13, weight: bold ? .semibold : .regular)).foregroundStyle(color)
            .lineSpacing(3)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .fixedSize(horizontal: false, vertical: true)
            // Each cell fills its slot, so shading and rules run unbroken across the row.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(bold ? Color.white.opacity(0.06) : .clear)
            .overlay(alignment: .top) { if topRule { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) } }
            .overlay(alignment: .leading) { if leadingRule { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) } }
    }
}

/// A Markdown table's cells, row by row. Columns take their natural width when the table
/// fits; otherwise the width is shared out so short columns keep theirs and long ones wrap.
struct TableLayout: Layout {
    let columns: Int
    static let minColumn: CGFloat = 72

    /// Water-filling: every column gets an even share, a column that needs less gives the
    /// rest back, and the rest is shared again among the columns still wanting more.
    static func widths(natural: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !natural.isEmpty else { return [] }
        if natural.reduce(0, +) <= available { return natural }
        var widths = natural.map { _ in CGFloat(0) }
        var open = Set(natural.indices), left = available
        while !open.isEmpty {
            let share = left / CGFloat(open.count)
            let settled = open.filter { natural[$0] <= share }
            if settled.isEmpty {
                for i in open { widths[i] = max(share, min(natural[i], minColumn)) }
                break
            }
            for i in settled { widths[i] = natural[i]; left -= natural[i] }
            open.subtract(settled)
        }
        return widths
    }

    private func measure(_ subviews: Subviews, width: CGFloat?) -> (widths: [CGFloat], heights: [CGFloat]) {
        guard columns > 0 else { return ([], []) }
        var natural = Array(repeating: CGFloat(0), count: columns)
        for (i, view) in subviews.enumerated() { natural[i % columns] = max(natural[i % columns], ceil(view.sizeThatFits(.unspecified).width)) }
        let widths = width.map { Self.widths(natural: natural, available: $0) } ?? natural
        var heights: [CGFloat] = []
        for (i, view) in subviews.enumerated() {
            let h = ceil(view.sizeThatFits(ProposedViewSize(width: widths[i % columns], height: nil)).height)
            if i % columns == 0 { heights.append(h) } else { heights[heights.count - 1] = max(heights[heights.count - 1], h) }
        }
        return (widths, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (widths, heights) = measure(subviews, width: proposal.width)
        return CGSize(width: max(proposal.width ?? 0, widths.reduce(0, +)), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var (widths, heights) = measure(subviews, width: bounds.width)
        // A table narrower than the window stretches its last column, so the frame stays full width.
        if let last = widths.indices.last { widths[last] += max(0, bounds.width - widths.reduce(0, +)) }
        var y = bounds.minY, x = bounds.minX
        for (i, view) in subviews.enumerated() {
            let column = i % columns, row = i / columns
            if column == 0 { x = bounds.minX; if row > 0 { y += heights[row - 1] } }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: widths[column], height: heights[row]))
            x += widths[column]
        }
    }
}

/// Local images show at once. A remote one waits for a click: an answer can be steered by
/// screen content, and an image that loads by itself would send its URL (and anything put in
/// it) to that server unasked.
struct MarkdownImage: View {
    let url: URL
    let alt: String
    @State private var load = false

    var body: some View {
        if let file = MarkdownBlocks.fileURL(url) {
            if let image = NSImage(contentsOf: file) { frame(Image(nsImage: image).resizable().aspectRatio(contentMode: .fit), size: image.size) }
            else { caption("Image not found: \(file.path)", symbol: "photo") }
        } else if url.scheme == "https" || url.scheme == "http" {
            if load {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): frame(image.resizable().aspectRatio(contentMode: .fit), size: nil)
                    case .failure: caption("Couldn’t load \(url.host ?? "image")", symbol: "exclamationmark.triangle")
                    default: ProgressView().controlSize(.small).padding(8)
                    }
                }
            } else {
                Button { load = true } label: {
                    caption("\(alt.isEmpty ? "Image" : alt) · load from \(url.host ?? "web")", symbol: "photo")
                }.buttonStyle(.plain).help(url.absoluteString)
            }
        } else {
            caption(alt.isEmpty ? url.absoluteString : alt, symbol: "photo")
        }
    }

    private func frame(_ image: some View, size: NSSize?) -> some View {
        image.frame(maxWidth: min(size?.width ?? 520, 520), maxHeight: 360, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)))
            .accessibilityLabel(alt.isEmpty ? "Image" : alt)
    }

    private func caption(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(appFont(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
    }
}

/// The prose side of an answer as one attributed string. SwiftUI's text selection stops at
/// the edge of each Text, so paragraphs, headings, lists, quotes and code flow together into
/// a single NSTextView instead, and one drag selects across all of them.
enum MarkdownProse {
    struct Segment: Identifiable {
        /// The id of the segment's first block, so spacing can look up the block before it.
        let id: Int
        var blocks: [MarkdownBlock]
    }

    static let code = NSAttributedString.Key("QuickAskCodeBlock")
    static let quote = NSAttributedString.Key("QuickAskQuote")
    static let lineSpacing: CGFloat = 5
    /// Inside a code block's box, matching the padding the old SwiftUI box had.
    static let codePadding: CGFloat = 12

    static func flows(_ block: MarkdownBlock) -> Bool {
        switch block.kind {
        case .paragraph, .heading, .listItem, .quote, .code: return true
        default: return false
        }
    }

    /// Runs of prose blocks become one segment; every other block stands alone.
    static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
        var segments: [Segment] = []
        for block in blocks {
            if flows(block), let last = segments.last, let previous = last.blocks.last, flows(previous) {
                segments[segments.count - 1].blocks.append(block)
            } else {
                segments.append(Segment(id: block.id, blocks: [block]))
            }
        }
        return segments
    }

    static func spacing(before block: MarkdownBlock, after previous: MarkdownBlock) -> CGFloat {
        switch (block.kind, previous.kind) {
        case (.heading, _): return 18
        case (.listItem, .listItem): return 5
        case (_, .heading): return 8
        default: return 12
        }
    }

    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> NSFont {
        var font: NSFont
        if vaultFontEnabled, let vault = NSFont(name: "JetBrainsMono-Regular", size: size - 1) {
            font = vault
        } else if mono {
            font = .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        } else {
            font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        }
        if bold && (vaultFontEnabled || !mono) && !font.fontDescriptor.symbolicTraits.contains(.bold) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static func attributed(_ blocks: [MarkdownBlock], color: NSColor, accent: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            var gap: CGFloat = 0
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
                gap = spacing(before: block, after: blocks[index - 1])
                // Code sits in a padded box, so the space outside it grows by the padding.
                if case .code = block.kind { gap += codePadding }
                if case .code = blocks[index - 1].kind { gap += codePadding }
            }
            let start = result.length
            result.append(render(block, color: color, accent: accent))
            let range = NSRange(location: start, length: result.length - start)
            // Only the block's first line takes the gap; its later lines keep their own style.
            let first = (result.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
            if let style = result.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle,
               let spaced = style.mutableCopy() as? NSMutableParagraphStyle {
                spaced.paragraphSpacingBefore = gap
                result.addAttribute(.paragraphStyle, value: spaced, range: NSIntersectionRange(first, range))
            }
        }
        return result
    }

    private static func render(_ block: MarkdownBlock, color: NSColor, accent: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        switch block.kind {
        case .heading(let level):
            style.lineSpacing = 2
            return inline(block.text, size: level == 1 ? 20 : level == 2 ? 17 : 15, bold: true, color: .white, accent: accent, style: style)
        case .listItem(let ordinal, let depth, let marker):
            let indent = CGFloat(depth - 1) * 20
            // The marker sits right-aligned in a 14 pt column, as before, with the text 8 pt after it.
            style.tabStops = [NSTextTab(textAlignment: .right, location: indent + 14), NSTextTab(textAlignment: .left, location: indent + 22)]
            style.headIndent = indent + 22
            let text = NSMutableAttributedString()
            let bullet = marker ? (ordinal.map { "\($0)." } ?? (depth > 1 ? "◦" : "•")) : ""
            text.append(NSAttributedString(string: "\t\(bullet)\t", attributes: [
                .font: font(size: 14), .foregroundColor: NSColor.white.withAlphaComponent(0.55), .paragraphStyle: style]))
            text.append(inline(block.text, size: 14, color: color, accent: accent, style: style))
            return text
        case .quote:
            style.firstLineHeadIndent = 13; style.headIndent = 13
            let text = NSMutableAttributedString(attributedString: inline(block.text, size: 14, color: NSColor.white.withAlphaComponent(0.7), accent: accent, style: style))
            text.addAttribute(quote, value: true, range: NSRange(location: 0, length: text.length))
            return text
        case .code(let language):
            style.lineSpacing = 2
            style.firstLineHeadIndent = codePadding; style.headIndent = codePadding; style.tailIndent = -codePadding
            let text = NSMutableAttributedString()
            if let language {
                let label = style.mutableCopy() as! NSMutableParagraphStyle
                label.paragraphSpacing = 6
                text.append(NSAttributedString(string: language + "\n", attributes: [
                    .font: font(size: 10, bold: true, mono: true), .foregroundColor: NSColor.white.withAlphaComponent(0.4), .paragraphStyle: label]))
            }
            text.append(NSAttributedString(string: block.plain, attributes: [
                .font: font(size: 12.5, mono: true), .foregroundColor: NSColor.white.withAlphaComponent(0.88), .paragraphStyle: style]))
            text.addAttribute(code, value: true, range: NSRange(location: 0, length: text.length))
            return text
        default:
            return inline(block.text, size: 14, color: color, accent: accent, style: style)
        }
    }

    /// A block's inline Markdown: bold, italic, code, strikethrough and links.
    private static func inline(_ text: AttributedString, size: CGFloat, bold: Bool = false, color: NSColor, accent: NSColor, style: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            let mono = intent.contains(.code)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: mono ? size - 1 : size, bold: bold || intent.contains(.stronglyEmphasized),
                            italic: intent.contains(.emphasized), mono: mono),
                .foregroundColor: color, .paragraphStyle: style,
            ]
            if mono { attributes[.backgroundColor] = NSColor.white.withAlphaComponent(0.1) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }
}

/// The prose of an answer in one selectable, non-editable text view, sized to its width.
struct ProseText: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    let color: NSColor
    let accent: NSColor
    let vaultFont: Bool

    func makeNSView(context: Context) -> ProseTextView {
        let view = ProseTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: ProseTextView, context: Context) {
        let text = MarkdownProse.attributed(blocks, color: color, accent: accent)
        view.linkTextAttributes = [.foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        view.selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.35)]
        guard view.textStorage?.isEqual(to: text) == false else { return }
        // A streaming answer grows under the reader's selection; keep it where it still fits.
        let kept = view.selectedRanges.filter { NSMaxRange($0.rangeValue) <= text.length }
        view.textStorage?.setAttributedString(text)
        if !kept.isEmpty { view.selectedRanges = kept }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseTextView, context: Context) -> CGSize? {
        let width = proposal.width.map { $0.isFinite ? $0 : 520 } ?? 520
        return CGSize(width: width, height: view.height(for: width))
    }
}

final class ProseTextView: NSTextView {
    func height(for width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        textContainer?.size = NSSize(width: size.width, height: .greatestFiniteMagnitude)
    }

    /// Code boxes and quote bars, drawn behind the text they mark.
    override func draw(_ dirtyRect: NSRect) {
        if let storage = textStorage, let layout = layoutManager, let container = textContainer {
            let all = NSRange(location: 0, length: storage.length)
            func rect(for range: NSRange) -> NSRect {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var union = NSRect.null
                layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in union = union.union(used) }
                return union
            }
            storage.enumerateAttribute(MarkdownProse.code, in: all) { value, range, _ in
                guard value != nil else { return }
                let line = rect(for: range)
                let pad = MarkdownProse.codePadding
                let box = NSRect(x: 0, y: line.minY - pad, width: container.size.width, height: line.height + pad * 2)
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
                NSColor.black.withAlphaComponent(0.28).setFill(); path.fill()
                NSColor.white.withAlphaComponent(0.08).setStroke(); path.stroke()
            }
            storage.enumerateAttribute(MarkdownProse.quote, in: all) { value, range, _ in
                guard value != nil else { return }
                let line = rect(for: range)
                NSColor.white.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: line.minY, width: 3, height: line.height), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        super.draw(dirtyRect)
    }
}
