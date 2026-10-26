import Vapor

/// Consent responses contain a one-time token; never let a browser or proxy cache them.
struct OAuthResponseMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.headers.replaceOrAdd(name: .pragma, value: "no-cache")
        return response
    }
}
