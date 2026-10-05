import CryptoKit
import Foundation

/// Voiceling is $5.99 once, free with a Deskling, after a 7-day trial.
/// Pure rules only (no storage or UI) so they can be tested on their own;
/// `LicenseManager` applies them.
enum LicenseConfig {
    /// Ed25519 public key that verifies license keys. The private half signs a key after a
    /// paid Stripe checkout on the Deskling site and never enters this repository.
    static let publicKey = Data(base64Encoded: "dO0F70peudpqiHiFKYq3nxt2Ix6VvSIJPGmERLKMzow=")!
    /// Stable storefront route; checkout availability is controlled server-side.
    static let checkoutURL = URL(string: "https://deskling-site.vercel.app/voiceling#get")
    static let price = "$5.99"
    static let trialDays = 7
}

struct LicenseRecord: Codable, Equatable {
    var trialStarted: Date
    var licenseKey: String?
    /// Set the first time this Mac's Deskling service accepts Voiceling. Kept, so the app
    /// doesn't relock while the desk display is away or the service is restarting.
    var desklingSeen: Date?
}

enum LicenseStatus: Equatable {
    case includedWithDeskling
    case licensed
    case trial(daysLeft: Int)
    case expired

    var canDictate: Bool { self != .expired }
}

/// A license key is `VL1-` + base64url(payload ‖ Ed25519 signature). The 17-byte payload is
/// version (1), the purchase day (UInt32, days since 1970, big-endian) and 12 bytes of
/// SHA-256 over the purchase reference. Keys are checked on this Mac; nothing goes online.
struct LicenseKey: Equatable {
    static let prefix = "VL1-"
    static let signingDomain = Data("VOICELING-LICENSE-V1".utf8)
    static let payloadLength = 17

    let issuedDay: UInt32
    let purchaseRef: Data

    /// Parses and verifies a pasted key; spaces and line breaks are ignored.
    static func verify(_ text: String, publicKey: Data = LicenseConfig.publicKey) -> LicenseKey? {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.hasPrefix(prefix) else { return nil }
        var base64 = String(compact.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let blob = Data(base64Encoded: base64), blob.count == payloadLength + 64 else { return nil }
        let payload = Data(blob.prefix(payloadLength))
        let signature = Data(blob.suffix(64))
        guard payload[0] == 1,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: signingDomain + payload) else { return nil }
        let day = payload[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return LicenseKey(issuedDay: day, purchaseRef: Data(payload[5...]))
    }
}

enum LicensePolicy {
    static func status(_ record: LicenseRecord, now: Date,
                       publicKey: Data = LicenseConfig.publicKey,
                       trialDays: Int = LicenseConfig.trialDays) -> LicenseStatus {
        if record.desklingSeen != nil { return .includedWithDeskling }
        if let key = record.licenseKey, LicenseKey.verify(key, publicKey: publicKey) != nil {
            return .licensed
        }
        // A clock set backwards counts as day zero rather than extending the trial.
        let elapsed = max(0, now.timeIntervalSince(record.trialStarted))
        let daysLeft = trialDays - Int(elapsed / 86_400)
        return daysLeft > 0 ? .trial(daysLeft: daysLeft) : .expired
    }
}
