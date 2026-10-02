# Selling Voiceling

$5.99 once. Free with a Deskling. 7-day free trial.

## How it fits together

| Piece | Where |
|---|---|
| Trial, Deskling inclusion, key check | `Voiceling/LicensePolicy.swift` (tests: `scripts/test-license-policy.sh`), applied by `Voiceling/Licensing.swift` |
| Checkout | A Stripe Payment Link, opened by the Buy button (`LicenseConfig.checkoutURL`) and the Deskling site |
| Key issuing | Deskling site: `api/voiceling-key.js` + `lib/voiceling-license.js`, page `voiceling-thanks.html` |
| Signing key | Ed25519. Private half: Keychain item `com.teamwong.voiceling.license-signing-key` (JWK) and the Vercel env var `VOICELING_SIGNING_KEY`. Public half: `LicenseConfig.publicKey` |

1. The buyer pays through the Payment Link. Stripe redirects to
   `/voiceling-thanks?session_id={CHECKOUT_SESSION_ID}`.
2. The page asks `/api/voiceling-key`, which reads the Checkout Session from Stripe and checks
   it came from the Voiceling Payment Link and is paid. It then signs a key derived from the
   session ID. The same purchase always gets the same key.
3. The buyer clicks **Activate in Voiceling** (`voiceling://activate?key=…`) or pastes the key into
   **License…**. Voiceling verifies the signature on the Mac. Licensing never goes online.

A Mac that has ever connected to a Deskling service is "Included with your Deskling" and never
sees the trial or a price.

## Vercel environment variables (Deskling site)

| Name | Value |
|---|---|
| `STRIPE_SECRET_KEY` | Restricted key: **Checkout Sessions: Read**, everything else None |
| `VOICELING_PAYMENT_LINK` | The Payment Link ID (`plink_…`) |
| `VOICELING_SIGNING_KEY` | `security find-generic-password -s com.teamwong.voiceling.license-signing-key -w` |

Use test-mode values first (test key, test Payment Link, card 4242 4242 4242 4242), then swap to live.

## Support

- **Lost key:** find the payment in Stripe, copy its Checkout Session ID (`cs_live_…`) and send
  `https://<site>/voiceling-thanks?session_id=<id>`. It shows the same key again.
- **Refunds:** a refunded key keeps working. At $5.99 that's accepted. If it ever matters, ship a
  short revoke list in an app update.

## If the signing key leaks

Anyone with it can mint keys. Generate a new pair, put the new private key in Keychain and
Vercel, and ship an app update that accepts the new public key. Keep the old public key in a
small accepted list so existing buyers' keys keep working, and stop signing with the old key.

## Tax

You are the seller. Stripe Tax calculates and collects tax only where a registration is added in
Stripe (Settings → Tax → Registrations). Hawaii GET applies to these sales. EU/UK buyers owe VAT
on digital goods from the first sale, which means registering (the EU has a one-stop
registration). Confirm with whoever does the taxes.
