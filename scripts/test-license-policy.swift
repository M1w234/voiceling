import Foundation

// Tests for LicensePolicy.swift: the 7-day trial, Deskling inclusion, stored keys,
// revalidation timing, and judging Lemon Squeezy answers.

var failures = 0
func expect(_ condition: Bool, _ label: String, file: String = #file, line: Int = #line) {
    if !condition { failures += 1; print("FAIL \(label) (line \(line))") }
}

let start = Date(timeIntervalSince1970: 1_800_000_000)
func at(days: Double) -> Date { start.addingTimeInterval(days * 86_400) }
let fresh = LicenseRecord(trialStarted: start)

@main
struct LicensePolicyTests {
    static func main() {
        // Trial clock
        expect(LicensePolicy.status(fresh, now: start, trialDays: 7) == .trial(daysLeft: 7), "day 0 has 7 days")
        expect(LicensePolicy.status(fresh, now: at(days: 6.9), trialDays: 7) == .trial(daysLeft: 1), "day 6.9 has 1 day")
        expect(LicensePolicy.status(fresh, now: at(days: 7), trialDays: 7) == .expired, "day 7 expires")
        expect(LicensePolicy.status(fresh, now: at(days: -3), trialDays: 7) == .trial(daysLeft: 7), "clock set back doesn't extend")
        expect(!LicenseStatus.expired.canDictate && LicenseStatus.trial(daysLeft: 1).canDictate, "only expired blocks dictation")

        // Deskling and keys outrank the trial
        var deskling = fresh; deskling.desklingSeen = at(days: 2)
        expect(LicensePolicy.status(deskling, now: at(days: 400), trialDays: 7) == .includedWithDeskling, "Deskling owners stay included")
        var paid = fresh; paid.licenseKey = "KEY"; paid.instanceID = "inst"
        expect(LicensePolicy.status(paid, now: at(days: 400), trialDays: 7) == .licensed, "licensed after trial")
        var half = fresh; half.licenseKey = "KEY"
        expect(LicensePolicy.status(half, now: at(days: 8), trialDays: 7) == .expired, "key without activation isn't a license")

        // Revalidation timing
        expect(!LicensePolicy.needsRevalidation(fresh, now: start, after: 7), "nothing to validate on a trial")
        expect(LicensePolicy.needsRevalidation(paid, now: start, after: 7), "never validated -> due")
        var checked = paid; checked.lastValidated = at(days: 1)
        expect(!LicensePolicy.needsRevalidation(checked, now: at(days: 4), after: 7), "3 days -> not due")
        expect(LicensePolicy.needsRevalidation(checked, now: at(days: 8.5), after: 7), "7.5 days -> due")

        // Lemon Squeezy answers (shape from docs.lemonsqueezy.com)
        let activateJSON = """
        {"activated":true,"error":null,"license_key":{"id":1,"status":"active","key":"k","activation_limit":3,"activation_usage":1},
         "instance":{"id":"47596ad9","name":"Voiceling for Mac"},
         "meta":{"store_id":11,"order_id":2,"product_id":22,"product_name":"Voiceling","variant_id":5}}
        """
        let ok = try! LicenseAPIResponse.decode(Data(activateJSON.utf8))
        expect(ok.meta?.storeId == 11 && ok.meta?.productId == 22 && ok.instance?.id == "47596ad9", "decodes snake_case fields")
        expect(LicensePolicy.check(ok, storeID: 11, productID: 22) == .accepted(instanceID: "47596ad9"), "matching key accepted")
        expect(LicensePolicy.check(ok, storeID: 11, productID: 99) == .wrongProduct, "other product rejected")
        expect(LicensePolicy.check(ok, storeID: 98, productID: 22) == .wrongProduct, "other store rejected")

        let validJSON = """
        {"valid":true,"error":null,"license_key":{"status":"active"},"instance":{"id":"abc"},"meta":{"store_id":11,"product_id":22}}
        """
        let valid = try! LicenseAPIResponse.decode(Data(validJSON.utf8))
        expect(LicensePolicy.check(valid, storeID: 11, productID: 22) == .accepted(instanceID: "abc"), "validate answer accepted")

        let refused = try! LicenseAPIResponse.decode(Data(#"{"activated":false,"error":"This license key has reached the activation limit.","meta":null}"#.utf8))
        expect(LicensePolicy.check(refused, storeID: 11, productID: 22) == .rejected(message: "This license key has reached the activation limit."), "server message passed through")
        let empty = try! LicenseAPIResponse.decode(Data(#"{"error":null}"#.utf8))
        expect(LicensePolicy.check(empty, storeID: 11, productID: 22) == .rejected(message: "That license key isn't valid."), "unknown answer rejected")

        if failures == 0 { print("License policy tests passed") } else { print("\(failures) license policy test(s) failed"); exit(1) }
    }
}
