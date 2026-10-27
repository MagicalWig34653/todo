import Crypto
import Foundation

func b64url(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func unb64url(_ s: String) -> [UInt8] {
    var r = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while r.count % 4 != 0 { r += "=" }
    return [UInt8](Data(base64Encoded: r)!)
}

/// Software passkey (ES256, "none" attestation) producing browser-shaped JSON for the WebAuthn endpoints.
final class VirtualAuthenticator {
    let key = P256.Signing.PrivateKey()
    let credentialID: [UInt8] = (0..<16).map { _ in UInt8.random(in: 0...255) }
    var counter: UInt32 = 0
    let rpID: String
    let origin: String

    init(rpID: String = "localhost", origin: String = "http://localhost:25173") {
        self.rpID = rpID
        self.origin = origin
    }

    private var rpIDHash: [UInt8] { Array(SHA256.hash(data: Data(rpID.utf8))) }

    private func clientData(type: String, challenge: String) -> [UInt8] {
        Array(#"{"type":"\#(type)","challenge":"\#(challenge)","origin":"\#(origin)","crossOrigin":false}"#.utf8)
    }

    private func coseKey() -> [UInt8] {
        let raw = [UInt8](key.publicKey.x963Representation) // 0x04 | x | y
        let x = Array(raw[1..<33]), y = Array(raw[33..<65])
        return [0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20] + x + [0x22, 0x58, 0x20] + y
    }

    func registrationResponse(challenge: String) -> [String: Any] {
        counter = 0
        var authData: [UInt8] = []
        authData += rpIDHash
        authData += [0x45]
        authData += counterBytes()
        authData += [UInt8](repeating: 0, count: 16)
        authData += [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xff)]
        authData += credentialID
        authData += coseKey()
        // {"fmt":"none","attStmt":{},"authData":h'…'}
        var cbor: [UInt8] = [0xA3, 0x63]
        cbor += Array("fmt".utf8)
        cbor += [0x64]
        cbor += Array("none".utf8)
        cbor += [0x67]
        cbor += Array("attStmt".utf8)
        cbor += [0xA0, 0x68]
        cbor += Array("authData".utf8)
        cbor += [0x59, UInt8(authData.count >> 8), UInt8(authData.count & 0xff)]
        cbor += authData
        return [
            "id": b64url(credentialID), "rawId": b64url(credentialID), "type": "public-key",
            "response": [
                "clientDataJSON": b64url(clientData(type: "webauthn.create", challenge: challenge)),
                "attestationObject": b64url(cbor),
            ],
        ]
    }

    func assertion(challenge: String, tamper: Bool = false) throws -> [String: Any] {
        counter += 1
        let authData = rpIDHash + [0x05] + counterBytes()
        let cd = clientData(type: "webauthn.get", challenge: challenge)
        var message = authData + Array(SHA256.hash(data: Data(cd)))
        if tamper { message[0] ^= 0xFF }
        let signature = try key.signature(for: Data(message)).derRepresentation
        return [
            "id": b64url(credentialID), "rawId": b64url(credentialID), "type": "public-key",
            "response": [
                "clientDataJSON": b64url(cd), "authenticatorData": b64url(authData),
                "signature": b64url([UInt8](signature)),
            ],
        ]
    }

    private func counterBytes() -> [UInt8] {
        [UInt8(counter >> 24), UInt8((counter >> 16) & 0xff), UInt8((counter >> 8) & 0xff), UInt8(counter & 0xff)]
    }
}
