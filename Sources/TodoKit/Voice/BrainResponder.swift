import Fluent
import Vapor

// Answer logic of the brain for spoken requests (ADR 0030 step 5, T1 minimum).
//
// The transcript of a recording is classified with fixed word rules (no model, no network):
//   refused   a class C action (delete, transfer, revoke a share, deploy, ...): never run from speech. The answer sends the
//             person to the app. No confirmation request is created either: speech has no connection (grant), and a
//             mis-heard name must not even prepare a deletion (ADR 0030 risks: wrong transcripts, foreign speakers).
//   status    "wie steht es": answered by the server from the command center and the open questions.
//   forwarded everything else: stays in the channel as `voice_in` with its transcript for the brain session
//             (`list_channel_messages`); the person gets a short receipt.
// Transcripts and reply texts are user data: nothing here logs them.

enum BrainIntent: String, Codable, Sendable {
    case status, refused, forwarded
}

struct BrainReply: Content, Equatable {
    let intent: String
    let replyText: String
}

enum BrainResponder {
    static let maxText = ChannelService.maxText

    static let refusedText = "Das führe ich nicht per Sprache aus. Löschen, Übertragen, Freigaben entziehen und Deployen bestätigst du selbst in der App."
    static let forwardedText = "Verstanden, ich habe es an das Brain weitergegeben. Die Antwort kommt hier im Kanal."

    // MARK: Classification

    /// Lowercase words, umlauts spelled out (`Löschen` and `loeschen` match the same stem).
    static func words(_ text: String) -> [String] {
        var folded = text.lowercased()
        for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] { folded = folded.replacingOccurrences(of: from, with: to) }
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Stems of class C actions (docs/MCP-PARITAET.md): deleting, transferring ownership, revoking shares, deploying.
    private static let classCStems = ["loesch", "entfern", "deploy", "uebertrag", "entzieh", "entzog", "veroeffentlich", "zerstoer",
                                      "vernicht", "delete", "remove", "revoke", "transfer", "ausroll"]

    private static func contains(_ words: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count) where zip(words[start...], phrase).allSatisfy({ $0.0 == $0.1 }) { return true }
        return false
    }

    static func classify(_ text: String) -> BrainIntent {
        let w = words(text)
        // Class C wins over everything else, also in a sentence that starts with a status question.
        if w.contains(where: { word in classCStems.contains { word.hasPrefix($0) } }) { return .refused }
        let phrases = [["wie", "steht"], ["wie", "stehts"], ["was", "steht", "an"], ["was", "ist", "los"], ["was", "gibt", "es", "neues"]]
        if phrases.contains(where: { contains(w, $0) }) { return .status }
        if w.contains(where: { ["lage", "ueberblick", "status", "lagebericht", "zusammenfassung"].contains($0) }) { return .status }
        if zip(w, w.dropFirst()).contains(where: { $0.0.hasPrefix("offen") && $0.1.hasPrefix("frage") }) { return .status }
        return .forwarded
    }

    // MARK: Reply

    static func reply(to transcript: String, user: User, db: any Database) async throws -> BrainReply {
        switch classify(transcript) {
        case .refused: return BrainReply(intent: BrainIntent.refused.rawValue, replyText: refusedText)
        case .forwarded: return BrainReply(intent: BrainIntent.forwarded.rawValue, replyText: forwardedText)
        case .status: return BrainReply(intent: BrainIntent.status.rawValue, replyText: try await statusText(user: user, db: db))
        }
    }

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Plain text without Markdown (it is also spoken). Account scope, the rights of the person: the same services as
    /// the app, nothing is read around the sharing rules. Always at most `maxText` characters.
    static func statusText(user: User, db: any Database) async throws -> String {
        var query = CommandCenterQuery()
        query.updatesLimit = 1
        let center = try await CommandCenterService(user: user, db: db).build(query)
        let s = center.summary
        let workflow = WorkflowService(user: user, db: db)
        let questions = try await workflow.questions(projectID: nil, taskID: nil, state: "open", limit: 10)
        let reviews = try await workflow.reviews(projectID: nil, state: "pending", limit: 10)
        let running = center.lanes?.first { $0.key == "running" }?.cards ?? []

        var head = "Lage: \(plural(s.running, "Aufgabe läuft", "Aufgaben laufen")), \(plural(s.openQuestions, "offene Frage", "offene Fragen")), "
            + "\(plural(s.pendingReviews, "Review wartet", "Reviews warten"))"
        if s.pendingConfirmations > 0 { head += ", \(plural(s.pendingConfirmations, "Bestätigungsanfrage", "Bestätigungsanfragen")) in der App" }
        if s.blocked > 0 { head += ", \(s.blocked) blockiert" }
        if s.overdue > 0 { head += ", \(s.overdue) überfällig" }
        head += "."

        var sections: [[String]] = [[head]]
        func section(_ title: String, total: Int, lines: [String]) {
            guard !lines.isEmpty else { return }
            var block = [title] + lines
            if total > lines.count { block.append("… und \(total - lines.count) weitere") }
            sections.append(block)
        }
        section("Offene Fragen:", total: s.openQuestions, lines: questions.map { q in
            let place = [q.taskTitle, q.projectName].compactMap { $0 }.joined(separator: ", ")
            return "- \(clip(q.prompt, 200))" + (place.isEmpty ? "" : " (\(clip(place, 100)))")
        })
        section("Reviews:", total: s.pendingReviews, lines: reviews.map { r in
            "- \(clip(r.summary, 200))" + (r.taskTitle.map { " (\(clip($0, 100)))" } ?? "")
        })
        section("Läuft gerade:", total: s.running, lines: running.prefix(5).map { "- \(clip($0.task.title, 120)) (\(clip($0.project.name, 80)))" })

        // Whole sections only; the first one (the headline) always fits.
        var text = ""
        for block in sections {
            let part = block.joined(separator: "\n")
            let joined = text.isEmpty ? part : text + "\n\n" + part
            if joined.count > maxText { break }
            text = joined
        }
        return String(text.prefix(maxText))
    }
}
