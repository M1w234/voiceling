import Foundation

/// Voiceling is $5.99 once, free with a Deskling, after a 7-day trial.
/// Pure rules only (no storage, network or UI) so they can be tested on their own;
/// `LicenseManager` applies them.
enum LicenseConfig {
    /// Lemon Squeezy store and product that issue Voiceling keys. 0 until the store exists,
    /// which keeps activation off and the Buy button disabled.
    static let storeID = 0
    static let productID = 0
    static let checkoutURL: URL? = nil
    static let price = "$5.99"
    static let trialDays = 7
    /// A license is re-checked at most this often, and only when online. Being offline never
    /// locks out a paid license: only an explicit "not valid" answer does.
    static let revalidateAfterDays = 7
}

struct LicenseRecord: Codable, Equatable {
    var trialStarted: Date
    var licenseKey: String?
    var instanceID: String?
    var lastValidated: Date?
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

/// The subset of Lemon Squeezy's license API response that Voiceling reads
/// (`/v1/licenses/activate`, `/validate`, `/deactivate`).
struct LicenseAPIResponse: Decodable {
    struct Key: Decodable { let status: String? }
    struct Instance: Decodable { let id: String? }
    struct Meta: Decodable {
        let storeId: Int?
        let productId: Int?
    }
    let activated: Bool?
    let valid: Bool?
    let deactivated: Bool?
    let error: String?
    let licenseKey: Key?
    let instance: Instance?
    let meta: Meta?

    static func decode(_ data: Data) throws -> LicenseAPIResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LicenseAPIResponse.self, from: data)
    }
}

enum LicenseCheck: Equatable {
    case accepted(instanceID: String?)
    /// A key from another Lemon Squeezy store or product.
    case wrongProduct
    case rejected(message: String)
}

enum LicensePolicy {
    static func status(_ record: LicenseRecord, now: Date, trialDays: Int = LicenseConfig.trialDays) -> LicenseStatus {
        if record.desklingSeen != nil { return .includedWithDeskling }
        if record.licenseKey != nil, record.instanceID != nil { return .licensed }
        // A clock set backwards counts as day zero rather than extending the trial.
        let elapsed = max(0, now.timeIntervalSince(record.trialStarted))
        let daysUsed = Int(elapsed / 86_400)
        let daysLeft = trialDays - daysUsed
        return daysLeft > 0 ? .trial(daysLeft: daysLeft) : .expired
    }

    static func needsRevalidation(_ record: LicenseRecord, now: Date,
                                  after days: Int = LicenseConfig.revalidateAfterDays) -> Bool {
        guard record.licenseKey != nil, record.instanceID != nil else { return false }
        guard let last = record.lastValidated else { return true }
        return now.timeIntervalSince(last) >= Double(days) * 86_400
    }

    /// Judges an activate or validate answer. The store and product must match, so a key
    /// sold for some other Lemon Squeezy product can't unlock Voiceling.
    static func check(_ response: LicenseAPIResponse, storeID: Int = LicenseConfig.storeID,
                      productID: Int = LicenseConfig.productID) -> LicenseCheck {
        let ok = response.activated ?? response.valid ?? false
        guard ok else {
            return .rejected(message: response.error ?? "That license key isn't valid.")
        }
        guard response.meta?.storeId == storeID, response.meta?.productId == productID else {
            return .wrongProduct
        }
        return .accepted(instanceID: response.instance?.id)
    }
}
