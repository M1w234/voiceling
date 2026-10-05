using System.Text;
using System.Text.Json;

namespace Voiceling.Core;

/// Outbound loopback relay client. Device audio arrives encrypted; transcripts stay local.
/// The caller owns the synchronization context; commands must not await recognition.
public sealed class DesklingBridge(HttpClient http, Func<string> state, Action<string> command, Action disconnected,
    Action<string, string>? audioCommand = null, Action<string, float[]>? audioReceived = null, Action? connected = null)
{
    private string routePrefix = "http://127.0.0.1:8737/api/voiceling/";
    private byte[]? audioKey;
    private string client = Guid.NewGuid().ToString();
    private long acknowledged;
    private bool registered;
    public bool Connected { get; private set; }
    public async Task RunAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            await CycleAsync(token);
            try { await Task.Delay(Connected ? 250 : 1000, token); }
            catch (OperationCanceledException) { break; }
        }
    }
    public async Task CycleAsync(CancellationToken token)
    {
        try
        {
            if (!registered)
            {
                using var registration = await RegisterAsync(token);
                audioKey = registration.RootElement.TryGetProperty("audioKey", out var key)
                    ? Convert.FromHexString(key.GetString()!) : null;
                registered = true;
            }
            using var status = await PostAsync("status", new { client, state = state(), canSubmit = false, ackSeq = acknowledged }, token);
            using var response = await http.GetAsync($"{routePrefix}command?client={client}&after={acknowledged}", token);
            response.EnsureSuccessStatusCode();
            using var body = await ReadAsync(response, token);
            var becameConnected = !Connected;
            Connected = true;
            if (becameConnected) connected?.Invoke();
            if (!body.RootElement.TryGetProperty("command", out var row) || row.ValueKind == JsonValueKind.Null) return;
            if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("seq", out var sequence) ||
                !sequence.TryGetInt64(out var seq) || seq <= acknowledged ||
                !row.TryGetProperty("command", out var name) || name.ValueKind != JsonValueKind.String) return;
            // Consume before dispatch. An ACK failure must never repeat a toggle.
            acknowledged = seq;
            var action = name.GetString();
            if (action is "audio_start" or "audio_cancel" or "audio_finish")
            {
                var session = row.GetProperty("session").GetString()!;
                if (audioKey is null || session.Length != 32 || audioCommand is null || audioReceived is null)
                    throw new JsonException("Device audio unavailable");
                if (action == "audio_finish")
                {
                    using var clip = await http.GetAsync($"{routePrefix}audio?client={client}&session={session}", token);
                    clip.EnsureSuccessStatusCode();
                    using var data = await ReadAsync(clip, token, 3000000);
                    var samples = DeviceAudio.Decode(data.RootElement, session, audioKey);
                    token.ThrowIfCancellationRequested();
                    audioReceived(session, samples);
                }
                else audioCommand(action, session);
            }
            if (action is "start" or "stop" or "toggle_lock" or "cancel") command(action);
            // Submit is deliberately unavailable: Windows has no one-shot field receipt.
            using var ack = await PostAsync("status", new { client, state = state(), canSubmit = false, ackSeq = acknowledged }, token);
        }
        catch (Exception ex) when (ex is HttpRequestException or JsonException or OperationCanceledException or InvalidOperationException or FormatException or System.Security.Cryptography.CryptographicException or InvalidDataException or KeyNotFoundException)
        {
            var wasConnected = Connected;
            Connected = false; registered = false;
            // New registration drops pending commands after an outage, including start.
            client = Guid.NewGuid().ToString(); acknowledged = 0;
            if (wasConnected) disconnected();
        }
    }
    private async Task<JsonDocument> RegisterAsync(CancellationToken token)
    {
        routePrefix = "http://127.0.0.1:8737/api/voiceling/";
        var value = new { client, deviceAudio = audioCommand is not null && audioReceived is not null };
        try { return await PostAsync("client", value, token); }
        catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            routePrefix = "http://127.0.0.1:8737/api/yaprflow/";
            return await PostAsync("client", new { client }, token);
        }
    }
    private async Task<JsonDocument> PostAsync(string path, object value, CancellationToken token)
    {
        // The relay deliberately requires Content-Length, not chunked JSON.
        using var content = new StringContent(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json");
        using var response = await http.PostAsync(routePrefix + path, content, token);
        response.EnsureSuccessStatusCode();
        return await ReadAsync(response, token);
    }
    private static async Task<JsonDocument> ReadAsync(HttpResponseMessage response, CancellationToken token, int limit = 4096)
    {
        var bytes = await response.Content.ReadAsByteArrayAsync(token);
        if (bytes.Length > limit) throw new JsonException("Relay response too large");
        var body = JsonDocument.Parse(bytes);
        if (body.RootElement.ValueKind != JsonValueKind.Object ||
            !body.RootElement.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True ||
            !body.RootElement.TryGetProperty("v", out var version) || !version.TryGetInt32(out var v) || v != 1)
        { body.Dispose(); throw new JsonException("Unsupported relay response"); }
        return body;
    }
}
