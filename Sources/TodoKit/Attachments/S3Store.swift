import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
import Vapor

/// Small path-style S3 transport. No redirects, public URLs, or process-local object state.
struct S3Store: Sendable {
    let endpoint: URL
    let bucket: String
    let accessKey: String?
    let secretKey: String?
    let region: String

    static func fromEnvironment() throws -> Self {
        guard let raw = Environment.get("S3_ENDPOINT"), let url = URL(string: raw),
              ["http", "https"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let bucket = Environment.get("S3_BUCKET"), !bucket.isEmpty,
              bucket.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { throw Abort(.serviceUnavailable, reason: "attachment_storage_unconfigured") }
        // Keys may come from Swarm secrets via S3_ACCESS_KEY_FILE / S3_SECRET_KEY_FILE.
        let access = try RuntimeEnvironment.value("S3_ACCESS_KEY", get: Environment.get)
        let secret = try RuntimeEnvironment.value("S3_SECRET_KEY", get: Environment.get)
        guard (access == nil) == (secret == nil), access?.isEmpty != true, secret?.isEmpty != true else {
            throw Abort(.serviceUnavailable, reason: "attachment_storage_credentials_invalid")
        }
        return Self(endpoint: url, bucket: bucket, accessKey: access, secretKey: secret,
                    region: Environment.get("S3_REGION") ?? "us-east-1")
    }

    static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func signedRequest(_ method: String, key: String, data: Data = Data(), now: Date = Date()) -> URLRequest {
        let url = endpoint.appendingPathComponent(bucket).appendingPathComponent(key)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        if method == "PUT" { request.httpBody = data }
        let hash = Self.checksum(data)
        request.setValue(hash, forHTTPHeaderField: "x-amz-content-sha256")
        guard let accessKey, let secretKey else { return request }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = format.string(from: now), day = String(format.string(from: now).prefix(8))
        let host = url.host! + (url.port.map { ":\($0)" } ?? "")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        let headers = "host;x-amz-content-sha256;x-amz-date"
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedPath
        let canonical = "\(method)\n\(path)\n\nhost:\(host)\nx-amz-content-sha256:\(hash)\nx-amz-date:\(timestamp)\n\n\(headers)\n\(hash)"
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(Self.checksum(Data(canonical.utf8)))"
        func hmac(_ key: Data, _ value: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
        }
        let signing = hmac(hmac(hmac(hmac(Data("AWS4\(secretKey)".utf8), day), region), "s3"), "aws4_request")
        let signature = hmac(signing, toSign).map { String(format: "%02x", $0) }.joined()
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(headers), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    func send(_ method: String, key: String, data: Data = Data()) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let delegate = BoundedS3Response(method: method, continuation: continuation)
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                session.dataTask(with: signedRequest(method, key: key, data: data)).resume()
            }
        } catch { throw Abort(.badGateway, reason: "attachment_storage_failed") }
    }
}

/// URLSession invokes delegate callbacks serially on its delegate queue.
private final class BoundedS3Response: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let method: String
    let continuation: CheckedContinuation<Data, any Error>
    private var body = Data()
    private var accepted = false
    private var exceeded = false

    init(method: String, continuation: CheckedContinuation<Data, any Error>) {
        self.method = method
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            accepted = (200..<300).contains(http.statusCode) || (method == "DELETE" && http.statusCode == 404)
        }
        exceeded = response.expectedContentLength > Int64(AttachmentService.maxSize)
        completionHandler(accepted && !exceeded ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= AttachmentService.maxSize else {
            exceeded = true
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { session.finishTasksAndInvalidate() }
        if accepted, !exceeded, error == nil {
            continuation.resume(returning: body)
        } else {
            continuation.resume(throwing: Abort(.badGateway, reason: "attachment_storage_failed"))
        }
    }
}
