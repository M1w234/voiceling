import Foundation

// Tests for LicensePolicy.swift: the 7-day trial, Deskling inclusion and offline key checks.
// The key below was signed by the Deskling site's lib/voiceling-license.js with a throwaway
// test key pair, so this also proves the site and the app agree on the key format.

var failures = 0
func expect(_ condition: Bool, _ label: String, line: Int = #line) {
    if !condition { failures += 1; print("FAIL \(label) (line \(line))") }
}

let testPublicKey = Data(base64Encoded: "xLn+r1sGby2rgc/dhSPVfp9kguD/OYU2AxutGm3Ctv0=")!
let siteKey = "VL1-AQAAUWHJ9MhKTIswdCa2HkKsrG0ZSsDwyA0dpPZkizqZ2Oy_ZH01cNJgQYDvisZTl2SAOBFGv-QlJLcWzGp-nU_-2WN9fpm8KsMD1zmzPK0F"
let start = Date(timeIntervalSince1970: 1_800_000_000)
func at(days: Double) -> Date { start.addingTimeInterval(days * 86_400) }
let fresh = LicenseRecord(trialStarted: start)

@main
struct LicensePolicyTests {
    static func main() {
        // Trial clock
        expect(LicensePolicy.status(fresh, now: start, publicKey: testPublicKey, trialDays: 7) == .trial(daysLeft: 7), "day 0 has 7 days")
        expect(LicensePolicy.status(fresh, now: at(days: 6.9), publicKey: testPublicKey, trialDays: 7) == .trial(daysLeft: 1), "day 6.9 has 1 day")
        expect(LicensePolicy.status(fresh, now: at(days: 7), publicKey: testPublicKey, trialDays: 7) == .expired, "day 7 expires")
        expect(LicensePolicy.status(fresh, now: at(days: -3), publicKey: testPublicKey, trialDays: 7) == .trial(daysLeft: 7), "clock set back doesn't extend")
        expect(!LicenseStatus.expired.canDictate && LicenseStatus.trial(daysLeft: 1).canDictate, "only expired blocks dictation")

        // Deskling owners and buyers
        var deskling = fresh; deskling.desklingSeen = at(days: 2)
        expect(LicensePolicy.status(deskling, now: at(days: 400), publicKey: testPublicKey) == .includedWithDeskling, "Deskling owners stay included")
        var paid = fresh; paid.licenseKey = siteKey
        expect(LicensePolicy.status(paid, now: at(days: 400), publicKey: testPublicKey) == .licensed, "site-signed key licenses after the trial")
        expect(LicensePolicy.status(paid, now: at(days: 400)) == .expired, "a key signed by another key pair is refused")

        // Key verification
        let parsed = LicenseKey.verify(siteKey, publicKey: testPublicKey)
        expect(parsed?.issuedDay == 1_800_000_000 / 86_400, "purchase day decodes")
        expect(parsed?.purchaseRef.count == 12, "purchase reference decodes")
        let spaced = String(siteKey.prefix(30)) + "\n  " + String(siteKey.dropFirst(30)) + " "
        expect(LicenseKey.verify(spaced, publicKey: testPublicKey) != nil, "pasted line breaks and spaces are ignored")
        var chars = Array(siteKey); let i = chars.count - 10
        chars[i] = chars[i] == "A" ? "B" : "A"
        expect(LicenseKey.verify(String(chars), publicKey: testPublicKey) == nil, "a changed character is refused")
        expect(LicenseKey.verify(String(siteKey.dropFirst(4)), publicKey: testPublicKey) == nil, "missing VL1- prefix is refused")
        expect(LicenseKey.verify("VL1-" + String(repeating: "A", count: 108), publicKey: testPublicKey) == nil, "garbage is refused")
        expect(LicenseKey.verify(siteKey, publicKey: Data(repeating: 7, count: 32)) == nil, "wrong public key is refused")

        if failures == 0 { print("License policy tests passed") } else { print("\(failures) license policy test(s) failed"); exit(1) }
    }
}
