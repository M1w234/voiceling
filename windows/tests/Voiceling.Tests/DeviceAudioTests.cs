using System.Text.Json;
using Voiceling.Core;
using Xunit;
namespace Voiceling.Tests;
public class DeviceAudioTests
{
    private const string Key = "22f6e174dd16fb21dd94f7156838e89a9474f87957f171e83a83785b56bc696c";
    private const string Vector = "eyJvayI6IHRydWUsICJ2IjogMSwgInNlc3Npb24iOiAiMDAwMTAyMDMwNDA1MDYwNzA4MDkwYTBiMGMwZDBlMGYiLCAicGFja2V0cyI6IFsiUkUxQk1RQUFBUUlEQkFVR0J3Z0pDZ3NNRFE0UEFBQUFBT2dEQUFBQUFBQUFBQUVDQXdRRkJnY0FBQUFBTGZjcHdpdHRYd0VNbmsvQU9rdmkycjhGWkFzcWxQY2ttOUZpbXpscTNxWWFaKzhpcmRaL012aFl0ZlV5MHdsYyIsICJSRTFCTVFFQUFRSURCQVVHQndnSkNnc01EUTRQQVFBQUFPZ0RBQUFBQUFBQUFBRUNBd1FGQmdjQkFBQUFsNmZGNlp1Uk9oc1p2cUF4VUNxbVc1RHRydW5EVzFEVGRuVGM1cEFEQ3dyakFOZEI0NE0xR3pucENLWEQwd3d3RGN2MmIvR2hjNmM9IiwgIlJFMUJNUUlBQVFJREJBVUdCd2dKQ2dzTURRNFBBZ0FBQU9nREFBQUFBQUFBQUFFQ0F3UUZCZ2NDQUFBQWJRbjlUeHhFaHdoRXk5c0ZtSDJ3S251ZEEzU1E0bXBuMk1CZks1cFV4UEp3OWNFTElJeFd0VEJEUEJUSmVwNlAiXX0=";
    private const string Id = "000102030405060708090a0b0c0d0e0f";
    [Fact] public void DecryptsCrossPlatformPcmVector()
    {
        using var data = JsonDocument.Parse(Convert.FromBase64String(Vector));
        Assert.Equal(new[] {0f,32767f/32768,-1f,1000f/32768}, DeviceAudio.Decode(data.RootElement,Id,Convert.FromHexString(Key)));
    }
    [Fact] public void WrongKeyCannotProduceSamples()
    {
        using var data = JsonDocument.Parse(Convert.FromBase64String(Vector));
        Assert.ThrowsAny<System.Security.Cryptography.CryptographicException>(() => DeviceAudio.Decode(data.RootElement,Id,new byte[32]));
    }
    [Fact] public void TruncatedOrReorderedRecordingIsRejected()
    {
        using var data = JsonDocument.Parse(Convert.FromBase64String(Vector));
        var rows=data.RootElement.GetProperty("packets").EnumerateArray().Select(x=>x.GetString()).ToArray();
        using var bad=JsonDocument.Parse(JsonSerializer.Serialize(new {session=Id,packets=new[]{rows[0],rows[2],rows[1]}}));
        Assert.Throws<InvalidDataException>(()=>DeviceAudio.Decode(bad.RootElement,Id,Convert.FromHexString(Key)));
    }
    private sealed class Recorder : IAudioRecorder {
        public int Starts; public Task StartAsync(CancellationToken t) {Starts++;throw new Exception("PC mic must remain closed");}
        public Task<float[]> StopAsync()=>throw new Exception("PC mic must remain closed");
    }
    private sealed class Speech : ISpeechRecognizer {
        public TaskCompletionSource? Gate, DecodeGate; public float[]? Heard;
        public Task PrepareAsync(CancellationToken t)=>Gate?.Task ?? Task.CompletedTask;
        public async Task<string> TranscribeAsync(float[] s,CancellationToken t) {Heard=s;if(DecodeGate is not null) await DecodeGate.Task.WaitAsync(t);return "From Deskling.";}
    }
    private sealed class Delivery : ITextDelivery {
        public int Captures,Deliveries; public readonly object Target=new();
        public Task<object?> CaptureTargetAsync(){Captures++;return Task.FromResult<object?>(Target);}
        public Task<string> DeliverAsync(string s,object? target,CancellationToken t){Assert.Same(Target,target);Deliveries++;return Task.FromResult("Text sent");}
    }
    [Fact] public async Task ExternalAudioUsesOriginalTargetWithoutOpeningComputerMic()
    {
        var mic=new Recorder();var speech=new Speech();var delivery=new Delivery();
        var s=new DictationSession(mic,speech,delivery,()=>new Settings(),()=>[]);
        await s.StartExternalAsync();Assert.Equal(SessionPhase.Listening,s.Phase);
        await s.CompleteExternalAsync(Enumerable.Repeat(.2f,3200).ToArray());
        Assert.Equal(0,mic.Starts);Assert.Equal(1,delivery.Captures);Assert.Equal(1,delivery.Deliveries);Assert.Equal(3200,speech.Heard!.Length);
    }
    [Fact] public async Task ReleaseDuringModelLoadKeepsCompleteDeviceClip()
    {
        var mic=new Recorder();var speech=new Speech{Gate=new()};var delivery=new Delivery();
        var s=new DictationSession(mic,speech,delivery,()=>new Settings(),()=>[]);
        var start=s.StartExternalAsync();var end=s.CompleteExternalAsync(Enumerable.Repeat(.2f,3200).ToArray());
        speech.Gate.SetResult();await start;await end;Assert.Equal(1,delivery.Deliveries);
    }
    [Fact] public async Task CancelNeverDeliversLateDeviceClip()
    {
        var mic=new Recorder();var speech=new Speech();var delivery=new Delivery();
        var s=new DictationSession(mic,speech,delivery,()=>new Settings(),()=>[]);
        await s.StartExternalAsync();await s.CancelAsync();await s.CompleteExternalAsync(Enumerable.Repeat(.2f,3200).ToArray());
        Assert.Equal(0,delivery.Deliveries);Assert.Equal(SessionPhase.Idle,s.Phase);
    }
    [Fact] public async Task RepeatedFinishDoesNotCancelRecognition()
    {
        var speech=new Speech{DecodeGate=new()};var delivery=new Delivery();
        var s=new DictationSession(new Recorder(),speech,delivery,()=>new Settings(),()=>[]);
        await s.StartExternalAsync();var end=s.CompleteExternalAsync(Enumerable.Repeat(.2f,3200).ToArray());
        var repeated=s.FinishAsync();Assert.Equal(SessionPhase.Transcribing,s.Phase);
        speech.DecodeGate.SetResult();await end;await repeated;
        Assert.Equal(1,delivery.Deliveries);
    }

}
