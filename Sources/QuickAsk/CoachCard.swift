import SwiftUI

/// A Studio Coach answer drawn in the chat, the way a ChatGPT app draws its widget: the coach's tool
/// returns `structuredContent.card`, the gateway hands it over (`GatewayConfiguration.cardsPath`), and
/// the reply shows it under the model's words. Outcomes are recorded from the card's buttons.
struct CoachCard: Codable, Equatable, Identifiable {
    struct Source: Codable, Equatable {
        let kind: String
        var seconds: Int?
        var file: String?
        var heard: Bool?
        var fallback: String?
    }
    struct Finding: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let measured: String
        let mightMean: String
        let tryThis: String
        let checked: Bool
        var outcome: String?
        enum CodingKeys: String, CodingKey { case id, title, measured, mightMean, tryThis = "try", checked, outcome }
    }
    var localID = UUID()
    let kind: String
    let song: String
    var entryId: String?
    let label: String
    var question: String?
    let source: Source
    var summary: String?
    var findings: [Finding]?
    var leftAlone: String?
    var askChris: String?
    var lines: [String]?
    var id: UUID { localID }
    enum CodingKeys: String, CodingKey { case kind, song, entryId, label, question, source, summary, findings, leftAlone, askChris, lines }

    static let outcomes: [(value: String, title: String)] = [("helped", "Helped"), ("didnt", "Didn't"), ("on_purpose", "On purpose")]

    static func decode(_ line: Data) -> CoachCard? {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(CoachCard.self, from: line)
    }

    /// Which audio the answer used: "live 1:15", or the bounce's file name.
    var sourceLabel: String {
        if source.kind == "live clip" {
            let seconds = source.seconds ?? 0
            return "live \(seconds / 60):\(String(format: "%02d", seconds % 60))"
        }
        return source.file.map { "bounce · \($0)" } ?? "bounce"
    }

    /// What the next request's history says about this card, so a follow-up ("the second one helped")
    /// can name a finding by id. The words the user saw, never the measurements' claims.
    var historyNote: String {
        var parts = ["[Studio Coach card: \(label) on \(song), \(sourceLabel)"]
        for (index, finding) in (findings ?? []).enumerated() {
            parts.append("\(index + 1). \(finding.title) (finding \(finding.id)\(finding.outcome.map { ", marked \($0)" } ?? ""))")
        }
        if let summary, !summary.isEmpty, findings == nil { parts.append(summary) }
        return parts.joined(separator: "; ") + "]"
    }
}

/// Follows the gateway's card file while a request runs. Only complete lines are read.
final class CardTail {
    private let path: String
    private var offset: UInt64 = 0
    private var framer = JSONLineFramer()
    private let lock = NSLock()
    init(path: String) { self.path = path }
    func poll() -> [CoachCard] {
        lock.lock(); defer { lock.unlock() }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        return framer.append(data).compactMap(CoachCard.decode)
    }
}

enum StudioCoachOutcome {
    /// Records one outcome through the coach's own MCP tool. The click is the approval, so this
    /// runs outside any model request and its lease.
    static func record(song: String, finding: String, outcome: String, launch: MCPLaunch) throws {
        let client = try AppMCPClient(launch: launch, valid: { true })
        defer { client.close() }
        let result = try client.rpc("tools/call", ["name": "record_outcome", "arguments": ["song": song, "finding": finding, "result": outcome]])
        guard result["isError"] as? Bool != true else {
            let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ")
            throw ProviderRunError(message: text?.isEmpty == false ? text! : "Studio Coach didn't record that.")
        }
    }
}

struct CoachCardView: View {
    let card: CoachCard
    let recording: Set<String>
    let onOutcome: (CoachCard.Finding, String) -> Void
    private let muted = Color.white.opacity(0.56)
    private let accent = Color(red: 0.99, green: 0.80, blue: 0.48)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Studio Coach · \(card.label)", systemImage: "waveform").font(appFont(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 8)
                Text(card.sourceLabel).font(appFont(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(card.source.kind == "live clip" ? accent : muted)
            }
            if let fallback = card.source.fallback {
                Text(fallback).font(appFont(size: 11)).foregroundStyle(muted)
            }
            if let summary = card.summary, !summary.isEmpty {
                Text(summary).font(appFont(size: 13)).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
            }
            ForEach(card.findings ?? []) { finding in findingRow(finding) }
            if let lines = card.lines, !lines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(appFont(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                    }
                }.textSelection(.enabled)
            }
            if let leftAlone = card.leftAlone, !leftAlone.isEmpty {
                Text("Leaving alone: \(leftAlone)").font(appFont(size: 12)).foregroundStyle(muted)
            }
            if let ask = card.askChris, !ask.isEmpty {
                Text("Coach asks: \(ask)").font(appFont(size: 12).italic()).foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12)))
    }

    private func findingRow(_ finding: CoachCard.Finding) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(accent)
                Text(finding.title).font(appFont(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                if !finding.checked {
                    Text("unverified").font(appFont(size: 10)).foregroundStyle(muted)
                        .help("A number in this finding didn't match the measurements on the second try.")
                }
            }
            Group {
                Text(finding.measured).foregroundStyle(.white.opacity(0.78))
                if !finding.mightMean.isEmpty { Text(finding.mightMean).foregroundStyle(muted) }
                if !finding.tryThis.isEmpty { Text("Try: \(finding.tryThis)").foregroundStyle(.white.opacity(0.85)) }
            }.font(appFont(size: 12)).textSelection(.enabled).padding(.leading, 13)
            if card.entryId != nil {
                HStack(spacing: 6) {
                    ForEach(CoachCard.outcomes, id: \.value) { outcome in
                        let chosen = finding.outcome == outcome.value
                        Button(outcome.title) { onOutcome(finding, outcome.value) }
                            .buttonStyle(.plain).font(appFont(size: 11, weight: chosen ? .semibold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(chosen ? accent.opacity(0.22) : Color.white.opacity(0.07), in: Capsule())
                            .foregroundStyle(chosen ? accent : .white.opacity(0.75))
                            .disabled(recording.contains(finding.id))
                            .accessibilityLabel("\(outcome.title): \(finding.title)")
                    }
                    if recording.contains(finding.id) { ProgressView().controlSize(.mini) }
                }.padding(.leading, 13).padding(.top, 2)
            }
        }
    }
}
