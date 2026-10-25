#if os(macOS)
import CryptoKit
import Foundation
import Security

/// The Mac's identity for HTTPS on the local network (protocol v2): a P-256 key and a self-signed certificate, made once
/// and kept in the keychain. Devices do not check it against any authority: they pin its fingerprint after asking the
/// Mac to prove, with the key from pairing, that it is the one serving it (`WirelessProtocol.certificateProof`).
public enum TLSIdentity {
    public enum IdentityError: LocalizedError {
        case keychain(String, OSStatus)

        public var errorDescription: String? {
            switch self {
            case .keychain(let step, let status): "Could not \(step) for wireless sync (keychain error \(status))."
            }
        }
    }

    /// The identity saved under `label` in the login keychain, made now if there is none. Returns it with the
    /// certificate's fingerprint (SHA-256 of the DER bytes, lowercase hex).
    ///
    /// Only the app that made a login keychain key can use it without asking (a release keeps its signature across
    /// updates; each unsandboxed debug build should use its own label). Check `canSign` before serving with it.
    public static func load(label: String, now: Date = .now) throws -> (identity: SecIdentity, fingerprint: String) {
        if let identity = existingIdentity(label: label), let certificate = certificate(of: identity) {
            return (identity, fingerprint(of: certificate))
        }
        // A certificate without its key (or the other way around) cannot be used: start over.
        remove(label: label)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrLabel: label] as [CFString: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw IdentityError.keychain("create the key", OSStatus(CFErrorGetCode(error!.takeRetainedValue())))
        }
        let der = try makeCertificate(privateKey: privateKey, commonName: "Groovelight", now: now)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.keychain("make the certificate", errSecDecode)
        }
        // Found again through the key (certificates take their label from their subject, not from the one given).
        let status = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: certificate] as [CFString: Any] as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.keychain("save the certificate", status) }
        guard let identity = existingIdentity(label: label) else { throw IdentityError.keychain("find the identity", errSecItemNotFound) }
        return (identity, fingerprint(of: certificate))
    }

    /// Removes the key and certificate saved under `label` (a new pair is made on the next load; devices pin it again).
    public static func remove(label: String) {
        if let hash = keyHash(label: label) {
            SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrPublicKeyHash: hash] as [CFString: Any] as CFDictionary)
        }
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrLabel: label] as [CFString: Any] as CFDictionary)
    }

    /// Whether the identity's key signs without macOS asking the user (it asks when another build of the app made the
    /// key). Tried on another thread: a TLS handshake waiting for that question would hold up every connection of the
    /// process, so a key that does not answer within `seconds` is not served with.
    public static func canSign(_ identity: SecIdentity, within seconds: TimeInterval = 3) -> Bool {
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else { return false }
        let done = DispatchSemaphore(value: 0)
        final class Outcome: @unchecked Sendable { var signed = false }
        let outcome = Outcome()
        nonisolated(unsafe) let privateKey = key
        // Same QoS as the caller: it blocks on the semaphore, which does not lend its priority to the signing thread.
        DispatchQueue.global(qos: DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .userInitiated).async {
            outcome.signed = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, Data("groovelight".utf8) as CFData, nil) != nil
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success && outcome.signed
    }

    public static func fingerprint(of certificate: SecCertificate) -> String {
        fingerprint(der: SecCertificateCopyData(certificate) as Data)
    }

    public static func fingerprint(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// The key's hash (SHA-1 of its public key), which its certificate carries too.
    private static func keyHash(label: String) -> Data? {
        let query: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrLabel: label, kSecReturnAttributes: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return (result as? [CFString: Any])?[kSecAttrApplicationLabel] as? Data
    }

    /// The identity of the key labeled `label` and its certificate.
    private static func existingIdentity(label: String) -> SecIdentity? {
        guard let hash = keyHash(label: label) else { return nil }
        let query: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecAttrPublicKeyHash: hash, kSecReturnRef: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let result else { return nil }
        var identity: SecIdentity?
        return SecIdentityCreateWithCertificate(nil, (result as! SecCertificate), &identity) == errSecSuccess ? identity : nil
    }

    private static func certificate(of identity: SecIdentity) -> SecCertificate? {
        var certificate: SecCertificate?
        return SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess ? certificate : nil
    }

    // MARK: - Certificate

    /// A self-signed X.509 v3 certificate for the key, valid from a day ago for 30 years, signed with ECDSA-SHA256.
    static func makeCertificate(privateKey: SecKey, commonName: String, now: Date) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw IdentityError.keychain("read the public key", errSecDecode)
        }
        let ecdsaWithSHA256 = DER.sequence(DER.oid("1.2.840.10045.4.3.2"))
        let name = DER.sequence(DER.set(DER.sequence(DER.oid("2.5.4.3"), DER.utf8(commonName))))
        var serial = Data(count: 16)
        _ = serial.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let tbs = DER.sequence(
            DER.explicit(0, DER.integer(Data([2]))),
            DER.integer(serial),
            ecdsaWithSHA256,
            name,
            DER.sequence(DER.time(now.addingTimeInterval(-86_400)), DER.time(now.addingTimeInterval(30 * 365 * 86_400))),
            name,
            DER.sequence(DER.sequence(DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")), DER.bitString(point)))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw IdentityError.keychain("sign the certificate", OSStatus(CFErrorGetCode(error!.takeRetainedValue())))
        }
        return DER.sequence(tbs, ecdsaWithSHA256, DER.bitString(signature))
    }
}

/// The few DER encodings a certificate needs.
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var data = Data([tag])
        if content.count < 128 {
            data.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 {
                bytes.insert(UInt8(length & 0xFF), at: 0)
                length >>= 8
            }
            data.append(0x80 | UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data + content
    }

    static func sequence(_ parts: Data...) -> Data { tlv(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: Data...) -> Data { tlv(0x31, parts.reduce(Data(), +)) }
    static func explicit(_ number: UInt8, _ content: Data) -> Data { tlv(0xA0 | number, content) }
    static func utf8(_ text: String) -> Data { tlv(0x0C, Data(text.utf8)) }
    static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }

    /// A positive integer from big-endian bytes.
    static func integer(_ bytes: Data) -> Data {
        var bytes = Data(bytes.drop { $0 == 0 })
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    static func oid(_ dotted: String) -> Data {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var value = arc
            var chunk: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    /// UTCTime until 2049, GeneralizedTime after (as X.509 requires).
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Data(formatter.string(from: date).utf8))
    }
}
#endif
