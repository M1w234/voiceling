using Voiceling.Core;
using Xunit;

namespace Voiceling.Tests;

public class LicenseTests
{
    // This is the throwaway site-signed fixture also checked by the Mac CryptoKit tests.
    private static readonly byte[] TestPublicKey = Convert.FromBase64String("xLn+r1sGby2rgc/dhSPVfp9kguD/OYU2AxutGm3Ctv0=");
    private const string SiteKey = "VL1-AQAAUWHJ9MhKTIswdCa2HkKsrG0ZSsDwyA0dpPZkizqZ2Oy_ZH01cNJgQYDvisZTl2SAOBFGv-QlJLcWzGp-nU_-2WN9fpm8KsMD1zmzPK0F";
    private static readonly DateTimeOffset Start = DateTimeOffset.FromUnixTimeSeconds(1800000000);
    [Fact]
    public void MacAndWebsiteFixtureVerifiesOfflineOnWindows()
    {
        var verified = LicensePolicy.Verify(SiteKey, TestPublicKey);
        Assert.NotNull(verified); Assert.Equal((uint)(1800000000 / 86400), verified.IssuedDay);
        Assert.Equal(12, verified.PurchaseReference.Length);
        Assert.NotNull(LicensePolicy.Verify(SiteKey[..30] + "\n  " + SiteKey[30..], TestPublicKey));
        Assert.Null(LicensePolicy.Verify(SiteKey));
        Assert.Null(LicensePolicy.Verify(SiteKey[..^10] + "A" + SiteKey[^9..], TestPublicKey));
        Assert.Null(LicensePolicy.Verify(new string('A', 4097), TestPublicKey));
    }
    [Theory]
    [InlineData(0, LicenseKind.Trial, 7)]
    [InlineData(6.9, LicenseKind.Trial, 1)]
    [InlineData(7, LicenseKind.Expired, 0)]
    [InlineData(-3, LicenseKind.Trial, 7)]
    public void TrialBoundaryMatchesMac(double days, LicenseKind kind, int left)
    {
        var status = LicensePolicy.Status(new(Start), Start.AddDays(days));
        Assert.Equal(kind, status.Kind); Assert.Equal(left, status.DaysLeft);
        Assert.Equal(kind != LicenseKind.Expired, status.CanDictate);
    }
    [Fact]
    public void PurchaseAndDesklingRemainValidAfterTrial()
    {
        Assert.Equal(LicenseKind.Licensed, LicensePolicy.Status(new(Start, SiteKey), Start.AddDays(400), TestPublicKey).Kind);
        Assert.Equal(LicenseKind.Expired, LicensePolicy.Status(new(Start, SiteKey), Start.AddDays(400)).Kind);
        Assert.Equal(LicenseKind.IncludedWithDeskling, LicensePolicy.Status(new(Start, null, Start), Start.AddDays(400)).Kind);
    }
    [Fact]
    public void ActivationOnlyAcceptsOneKeyOnTheExpectedRoute()
    {
        Assert.Equal(SiteKey, LicensePolicy.ActivationKey("voiceling://activate?key=" + Uri.EscapeDataString(SiteKey)));
        Assert.Null(LicensePolicy.ActivationKey("https://activate?key=" + SiteKey));
        Assert.Null(LicensePolicy.ActivationKey("voiceling://activate?key=a&key=b"));
        Assert.Null(LicensePolicy.ActivationKey("voiceling://activate/other?key=" + SiteKey));
        Assert.Null(LicensePolicy.ActivationKey("voiceling://user@activate?key=" + SiteKey));
    }
    private sealed class NeverAudio : IAudioRecorder
    { public Task StartAsync(CancellationToken token) => throw new Exception("Microphone opened"); public Task<float[]> StopAsync() => throw new Exception("Audio stopped"); }
    private sealed class NeverSpeech : ISpeechRecognizer
    { public Task PrepareAsync(CancellationToken token) => throw new Exception("Model prepared"); public Task<string> TranscribeAsync(float[] samples, CancellationToken token) => throw new Exception("Decoded"); }
    private sealed class NeverDelivery : ITextDelivery
    { public Task<object?> CaptureTargetAsync() => throw new Exception("Target read"); public Task<string> DeliverAsync(string text, object? target, CancellationToken token) => throw new Exception("Text delivered"); }
    [Fact]
    public async Task ExpiredLicenseBlocksBothSourcesBeforeAnyCaptureOrTargetRead()
    {
        var session = new DictationSession(new NeverAudio(), new NeverSpeech(), new NeverDelivery(), () => new(), () => [], canStart: () => false);
        await session.StartAsync(); await session.StartExternalAsync(); await session.CompleteExternalAsync([.1f]);
        Assert.False(session.IsBusy); Assert.Contains("Activate", session.Status);
    }
}
