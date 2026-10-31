import Crypto
import Foundation
import Vapor

// MARK: - Transport

struct APNsRequest: Sendable {
    let environment: APNsEnvironment
    let deviceToken: String
    let topic: String
    let jwt: String
    let priority: Int
    let collapseID: String?
    /// Absolute unix time; 0 = deliver once and do not store.
    let expiration: Int
    let body: Data
}

struct APNsResponse: Sendable, Equatable {
    var status: Int
    /// `reason` of the JSON error body (e.g. `BadDeviceToken`); nil on success.
    var reason: String?
}

/// Everything that touches the network. Tests replace it; the production implementation is `VaporAPNsTransport`.
protocol APNsTransport: Sendable {
    func send(_ request: APNsRequest) async throws -> APNsResponse
}

struct APNsTransportError: Error, CustomStringConvertible {
    let description: String
}

/// HTTP/2 against `api.push.apple.com` / `api.sandbox.push.apple.com` through AsyncHTTPClient (ALPN selects h2).
/// Errors are reduced to a fixed text: the request URL contains the device token and must not reach any log.
struct VaporAPNsTransport: APNsTransport {
    let client: any Client
    var timeout: TimeInterval = 20

    func send(_ r: APNsRequest) async throws -> APNsResponse {
        var headers = HTTPHeaders()
        headers.add(name: "authorization", value: "bearer \(r.jwt)")
        headers.add(name: "apns-topic", value: r.topic)
        headers.add(name: "apns-push-type", value: "alert")
        headers.add(name: "apns-priority", value: String(r.priority))
        headers.add(name: "apns-expiration", value: String(r.expiration))
        if let c = r.collapseID { headers.add(name: "apns-collapse-id", value: c) }
        headers.add(name: "content-type", value: "application/json")
        let uri = URI(string: "https://\(r.environment.host)/3/device/\(r.deviceToken)")
        do {
            let request = ClientRequest(method: .POST, url: uri, headers: headers, body: ByteBuffer(data: r.body),
                                        timeout: .milliseconds(Int64(timeout * 1000)))
            let response = try await client.send(request)
            var reason: String?
            if response.status != .ok, var body = response.body,
               let data = body.readData(length: min(body.readableBytes, 2048)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                reason = json["reason"] as? String
            }
            return APNsResponse(status: Int(response.status.code), reason: reason)
        } catch let e as APNsTransportError { throw e } catch {
            throw APNsTransportError(description: "network error")
        }
    }
}

// MARK: - Provider token (ES256 JWT)

/// Provider authentication token. Apple rejects tokens older than 60 minutes (`ExpiredProviderToken`) and tokens
/// renewed more often than every 20 minutes (`TooManyProviderTokenUpdates`): the token is cached for 50 minutes
/// and only replaced earlier on explicit invalidation once it is at least 20 minutes old.
actor APNsAuthProvider {
    static let lifetime: TimeInterval = 50 * 60
    static let minimumAge: TimeInterval = 20 * 60

    private let key: P256.Signing.PrivateKey
    private let keyID: String
    private let teamID: String
    private let clock: @Sendable () -> Date
    private var cached: (token: String, issuedAt: Date)?

    init(keyPEM: String, keyID: String, teamID: String, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        key = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
        self.keyID = keyID; self.teamID = teamID; self.clock = clock
    }

    func token() throws -> String {
        let now = clock()
        if let c = cached, now.timeIntervalSince(c.issuedAt) < Self.lifetime { return c.token }
        let token = try Self.makeJWT(key: key, keyID: keyID, teamID: teamID, issuedAt: now)
        cached = (token, now)
        return token
    }

    /// After `ExpiredProviderToken`: drop the cache if the token is old enough to be replaced legitimately.
    func invalidate() {
        if let c = cached, clock().timeIntervalSince(c.issuedAt) >= Self.minimumAge { cached = nil }
    }

    static func makeJWT(key: P256.Signing.PrivateKey, keyID: String, teamID: String, issuedAt: Date) throws -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: [.sortedKeys])
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(issuedAt.timeIntervalSince1970)], options: [.sortedKeys])
        let input = b64url(header) + "." + b64url(claims)
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + b64url(signature.rawRepresentation)
    }
}

// MARK: - Sender

enum APNsOutcome: Equatable, Sendable {
    case delivered
    /// The token is dead (410 / BadDeviceToken / wrong topic): revoke the device.
    case revoke(String)
    /// 429, 5xx, network error, expired provider token: try again later.
    case retry(String)
    /// Will not succeed by retrying (configuration or payload problem).
    case permanent(String)
}

struct APNsSender: Sendable {
    let config: APNsConfig
    let transport: any APNsTransport
    let auth: APNsAuthProvider
    let clock: @Sendable () -> Date

    init(config: APNsConfig, transport: any APNsTransport, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let pem = config.keyPEM, let keyID = config.keyID, let teamID = config.teamID else {
            throw SettingsError.invalid("APNs is not configured")
        }
        self.config = config; self.transport = transport; self.clock = clock
        auth = try APNsAuthProvider(keyPEM: pem, keyID: keyID, teamID: teamID, clock: clock)
    }

    func send(to device: PushDevice, payload: Data, priority: Int, ttl: TimeInterval, collapseKey: String?) async -> APNsOutcome {
        let topic = config.topics.contains(device.bundleID) ? device.bundleID : (config.topics.first ?? device.bundleID)
        let env = APNsEnvironment(rawValue: device.environment) ?? config.environment
        let jwt: String
        do { jwt = try await auth.token() } catch { return .permanent("jwt_signing_failed") }
        let request = APNsRequest(
            environment: env, deviceToken: device.token, topic: topic, jwt: jwt, priority: priority,
            collapseID: collapseKey.map(Self.collapseID), expiration: Int(clock().addingTimeInterval(ttl).timeIntervalSince1970),
            body: payload)
        let response: APNsResponse
        do { response = try await transport.send(request) } catch { return .retry("network") }
        return await Self.classify(response, invalidate: { await auth.invalidate() })
    }

    /// apns-collapse-id is limited to 64 bytes: a hash keeps every dedupe key valid and opaque.
    static func collapseID(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func classify(_ r: APNsResponse, invalidate: () async -> Void) async -> APNsOutcome {
        let reason = r.reason ?? "http_\(r.status)"
        switch r.status {
        case 200: return .delivered
        case 410: return .revoke(reason)
        case 400 where ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].contains(reason): return .revoke(reason)
        case 403 where reason == "ExpiredProviderToken":
            await invalidate()
            return .retry(reason)
        case 429, 500, 502, 503, 504: return .retry(reason)
        default: return .permanent(reason)
        }
    }
}

extension Application {
    private struct SenderKey: StorageKey { typealias Value = APNsSender }
    /// nil while push is disabled. Tests assign a sender with a fake transport.
    var apnsSender: APNsSender? {
        get { storage[SenderKey.self] }
        set { storage[SenderKey.self] = newValue }
    }
}
