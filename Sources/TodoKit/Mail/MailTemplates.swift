import Foundation

/// German mail texts (plain text + simple HTML, no external images, no tracking pixels, no task titles).
struct RenderedMail: Equatable, Sendable {
    var subject: String
    var text: String
    var html: String
}

enum MailTemplates {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func germanDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE"); f.timeZone = TimeZone(identifier: "Europe/Berlin")
        f.dateFormat = "dd.MM.yyyy, HH:mm 'Uhr'"
        return f.string(from: date)
    }

    private static func html(title: String, paragraphs: [String], link: String?, linkLabel: String?, notes: [String]) -> String {
        var body = "<h1 style=\"font-size:18px;margin:0 0 12px\">\(escape(title))</h1>"
        for p in paragraphs { body += "<p style=\"margin:0 0 12px\">\(escape(p))</p>" }
        if let link, let linkLabel {
            body += "<p style=\"margin:16px 0\"><a href=\"\(escape(link))\" style=\"background:#2563eb;color:#ffffff;padding:10px 16px;border-radius:6px;text-decoration:none;display:inline-block\">\(escape(linkLabel))</a></p>"
            body += "<p style=\"margin:0 0 12px;font-size:13px;color:#555555\">Funktioniert der Knopf nicht, kopiere diese Adresse in den Browser:<br><span style=\"word-break:break-all\">\(escape(link))</span></p>"
        }
        for n in notes { body += "<p style=\"margin:0 0 8px;font-size:13px;color:#555555\">\(escape(n))</p>" }
        return "<!doctype html><html lang=\"de\"><head><meta charset=\"utf-8\"><title>\(escape(title))</title></head><body style=\"font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#111111;line-height:1.5;max-width:560px;margin:0 auto;padding:16px\">\(body)</body></html>"
    }

    private static func text(title: String, paragraphs: [String], link: String?, notes: [String]) -> String {
        var parts = [title, ""] + paragraphs.flatMap { [$0, ""] }
        if let link { parts += [link, ""] }
        parts += notes
        return parts.joined(separator: "\n")
    }

    static func verifyEmail(link: String, expiresAt: Date) -> RenderedMail {
        let title = "E-Mail-Adresse bestätigen"
        let paragraphs = ["Bitte bestätige, dass diese Adresse zu deinem Todolino-Konto gehört. Erst danach verwendet Todolino sie für Nachrichten."]
        let notes = ["Der Link gilt bis \(germanDate(expiresAt)) und kann nur einmal verwendet werden.",
                     "Wenn du das nicht angefordert hast, ignoriere diese Nachricht. Ohne Bestätigung wird nichts gespeichert."]
        return RenderedMail(subject: "Todolino: E-Mail-Adresse bestätigen",
                            text: text(title: title, paragraphs: paragraphs + ["Bestätigungslink:"], link: link, notes: notes),
                            html: html(title: title, paragraphs: paragraphs, link: link, linkLabel: "Adresse bestätigen", notes: notes))
    }

    static func recoveryCode(link: String, code: String, expiresAt: Date) -> RenderedMail {
        let title = "Recovery-Code für dein Todolino-Konto"
        let paragraphs = ["Eine Administratorin oder ein Administrator hat für dein Konto einen Recovery-Code ausgestellt, damit du einen neuen Passkey einrichten kannst."]
        let notes = ["Gültig bis \(germanDate(expiresAt)), einmal einlösbar. Ein früherer Code dieses Kontos ist damit ungültig.",
                     "Wichtig: E-Mail ist kein sicherer Kanal. Jeder, der diese Nachricht lesen kann, kann das Konto übernehmen. Löse den Code sofort ein und lösche danach diese Nachricht.",
                     "Hast du keine Wiederherstellung erwartet, melde dich bei deiner Administration und nutze den Link nicht."]
        return RenderedMail(subject: "Todolino: Recovery-Code",
                            text: text(title: title, paragraphs: paragraphs + ["Link zum Einlösen (enthält den Code):"], link: link, notes: ["Code im Klartext: \(code)", ""] + notes),
                            html: html(title: title, paragraphs: paragraphs + ["Code im Klartext: \(code)"], link: link, linkLabel: "Code einlösen", notes: notes))
    }

    static func test() -> RenderedMail {
        let title = "Test-Mail von Todolino"
        let paragraphs = ["Wenn du diese Nachricht liest, funktioniert der E-Mail-Versand deines Todolino-Servers."]
        return RenderedMail(subject: "Todolino: Test-Mail",
                            text: text(title: title, paragraphs: paragraphs, link: nil, notes: ["Du musst nichts weiter tun."]),
                            html: html(title: title, paragraphs: paragraphs, link: nil, linkLabel: nil, notes: ["Du musst nichts weiter tun."]))
    }
}
