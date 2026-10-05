using System.Buffers.Binary;
using System.Text;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Voiceling.Core;

public enum LicenseKind { Trial, Licensed, IncludedWithDeskling, Expired }
public sealed record LicenseRecord(DateTimeOffset TrialStarted, string? Key = null, DateTimeOffset? DesklingSeen = null);
public sealed record LicenseStatus(LicenseKind Kind, int DaysLeft = 0)
{
    public bool CanDictate => Kind != LicenseKind.Expired;
    public string Label => Kind switch
    {
        LicenseKind.Licensed => "Activated · Mac and Windows",
        LicenseKind.IncludedWithDeskling => "Included with your Deskling",
        LicenseKind.Trial => $"Trial · {DaysLeft} day{(DaysLeft == 1 ? "" : "s")} left",
        _ => "Your seven-day trial has ended"
    };
}
public sealed record VerifiedLicense(uint IssuedDay, byte[] PurchaseReference);
public static class LicensePolicy
{
    public const string CheckoutUrl = "https://deskling-site.vercel.app/voiceling#get";
    public const int TrialDays = 7;
    // The same public verifier as Mac. A signing private key never ships in either app.
    private static readonly byte[] PublicKey = Convert.FromBase64String("dO0F70peudpqiHiFKYq3nxt2Ix6VvSIJPGmERLKMzow=");
    private static readonly byte[] Domain = Encoding.UTF8.GetBytes("VOICELING-LICENSE-V1");
    public static string Compact(string text) => string.Concat(text.Where(c => !char.IsWhiteSpace(c)));
    public static VerifiedLicense? Verify(string text, byte[]? publicKey = null)
    {
        if (text.Length > 4096) return null;
        var compact = Compact(text);
        if (!compact.StartsWith("VL1-", StringComparison.Ordinal)) return null;
        var encoded = compact[4..].Replace('-', '+').Replace('_', '/');
        if (encoded.Length > 112) return null;
        encoded = encoded.PadRight((encoded.Length + 3) / 4 * 4, '=');
        try
        {
            var blob = Convert.FromBase64String(encoded);
            if (blob.Length != 81 || blob[0] != 1) return null;
            var verifier = new Ed25519Signer();
            verifier.Init(false, new Ed25519PublicKeyParameters(publicKey ?? PublicKey, 0));
            verifier.BlockUpdate(Domain, 0, Domain.Length);
            verifier.BlockUpdate(blob, 0, 17);
            if (!verifier.VerifySignature(blob[17..])) return null;
            return new(BinaryPrimitives.ReadUInt32BigEndian(blob.AsSpan(1, 4)), blob[5..17]);
        }
        catch (Exception ex) when (ex is FormatException or ArgumentException) { return null; }
    }
    public static LicenseStatus Status(LicenseRecord record, DateTimeOffset now, byte[]? publicKey = null)
    {
        if (record.DesklingSeen is not null) return new(LicenseKind.IncludedWithDeskling);
        if (record.Key is not null && Verify(record.Key, publicKey) is not null) return new(LicenseKind.Licensed);
        var elapsed = Math.Max(0, (now - record.TrialStarted).TotalDays);
        var left = TrialDays - Math.Min(TrialDays, (int)Math.Floor(elapsed));
        return left > 0 ? new(LicenseKind.Trial, left) : new(LicenseKind.Expired);
    }
    public static string? ActivationKey(string url)
    {
        if (url.Length > 8192 || !Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            uri.Scheme != "voiceling" || uri.Host != "activate" || uri.UserInfo.Length != 0 ||
            uri.AbsolutePath is not ("" or "/")) return null;
        var keys = uri.Query.TrimStart('?').Split('&')
            .Select(row => row.Split('=', 2)).Where(parts => parts.Length == 2 && parts[0] == "key").ToArray();
        if (keys.Length != 1) return null;
        try { return Uri.UnescapeDataString(keys[0][1]); }
        catch (UriFormatException) { return null; }
    }
}
