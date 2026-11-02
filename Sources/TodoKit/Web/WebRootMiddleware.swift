import Foundation
import NIOCore
import Vapor

/// Serves the statically built PWA (SvelteKit adapter-static output) from the same origin as the API, which passkeys
/// (RP_ID / RP_ORIGIN) need. Real routes always win: the request is first routed normally and only a "not found"
/// from the router falls through to the static files. Reserved API prefixes are never served from disk and never
/// get the SPA fallback, so unknown API paths keep their JSON 404.
struct WebRootMiddleware: AsyncMiddleware {
    /// Canonical (symlink-resolved) root directory without trailing slash.
    let root: String

    /// First path segments owned by the backend.
    static let reservedPrefixes: Set<String> = [
        "v1", "mcp", "oauth", ".well-known", "health", "apple-app-site-association", "docs", "openapi",
    ]

    /// Returns nil (API-only behaviour) unless `path` is an existing directory.
    static func make(path: String?, logger: Logger) -> WebRootMiddleware? {
        guard let path, !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            logger.info("WEB_ROOT \(path) not found: serving the API only")
            return nil
        }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let middleware = WebRootMiddleware(root: canonical)
        guard middleware.indexFile != nil else {
            logger.warning("WEB_ROOT \(path) has no index.html inside the directory: serving the API only")
            return nil
        }
        return middleware
    }

    /// The start page: index.html resolved like any other file, so a symlink pointing outside the root is not served.
    var indexFile: String? { Self.contained(root + "/index.html", in: root) }

    private static func contained(_ path: String, in root: String) -> String? {
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard candidate.hasPrefix(root + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return candidate
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.method == .GET || request.method == .HEAD else { return try await next.respond(to: request) }
        let rawFirst = request.url.path.split(separator: "/").first.map(String.init)
        if let rawFirst, Self.reservedPrefixes.contains(rawFirst) { return try await next.respond(to: request) }
        let segments: [String]
        switch Self.decode(request.url.path) {
        case .invalid: throw Abort(.badRequest, reason: "invalid path")
        case .segments(let s): segments = s
        }
        if let first = segments.first, Self.reservedPrefixes.contains(first) {
            return try await next.respond(to: request)
        }
        do {
            return try await next.respond(to: request)
        } catch let abort as any AbortError where abort.status == .notFound {
            if let file = resolve(segments), let response = try await serve(file, immutable: Self.isImmutable(segments), request) {
                return response
            }
            let wantsHTML = request.headers[.accept].contains { $0.contains("text/html") }
            if wantsHTML, segments.first != "_app" {
                guard let index = indexFile else { throw abort }
                return try await serve(index, immutable: false, request) ?? Response(status: .notFound)
            }
            throw abort
        }
    }

    enum Decoded { case invalid; case segments([String]) }

    /// Percent-decodes every segment and rejects traversal, separators, NUL and dot files.
    static func decode(_ path: String) -> Decoded {
        var out: [String] = []
        for raw in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard let s = String(raw).removingPercentEncoding,
                  !s.isEmpty, !s.contains("/"), !s.contains("\\"), !s.contains("\0"), s != ".", s != ".." else { return .invalid }
            out.append(s)
        }
        return .segments(out)
    }

    static func isImmutable(_ segments: [String]) -> Bool {
        segments.count > 2 && segments[0] == "_app" && segments[1] == "immutable"
    }

    /// Maps URL segments to an existing regular file inside the root (no dot files, no symlink escape).
    private func resolve(_ segments: [String]) -> String? {
        if segments.isEmpty { return indexFile }
        if segments.contains(where: { $0.hasPrefix(".") }) { return nil }
        return Self.contained(root + "/" + segments.joined(separator: "/"), in: root)
    }

    private func serve(_ file: String, immutable: Bool, _ request: Request) async throws -> Response? {
        guard FileManager.default.isReadableFile(atPath: file) else { return nil }
        let response = try await request.fileio.asyncStreamFile(at: file)
        if let type = Self.contentType(for: file) { response.headers.replaceOrAdd(name: .contentType, value: type) }
        response.headers.replaceOrAdd(
            name: .cacheControl, value: immutable ? "public, max-age=31536000, immutable" : "no-cache")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "same-origin")
        // The app (including the OAuth consent route) must never be embedded in another site (clickjacking).
        // Only frame-ancestors is set: a full script/style CSP would break SvelteKit's inline bootstrap script.
        if (file as NSString).pathExtension.lowercased() == "html" {
            response.headers.replaceOrAdd(name: "Content-Security-Policy", value: "frame-ancestors 'none'")
            response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        }
        return response
    }

    static func contentType(for file: String) -> String? {
        switch (file as NSString).pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json", "map": "application/json; charset=utf-8"
        case "webmanifest": "application/manifest+json; charset=utf-8"
        case "txt": "text/plain; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "ico": "image/x-icon"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "wasm": "application/wasm"
        default: nil
        }
    }
}

extension Application {
    /// Registers the PWA middleware if the web root exists. Call after all routes are registered.
    func registerWebRoot() {
        if let middleware = WebRootMiddleware.make(path: settings.webRoot, logger: logger) {
            self.middleware.use(middleware)
        }
    }
}
