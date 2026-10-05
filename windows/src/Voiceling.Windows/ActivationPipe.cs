using System.IO.Pipes;
using System.Text;

namespace Voiceling.Windows;

/// Only the same Windows user can forward activation to the running app.
/// The receiver parses a bounded URL and verifies the signed key; no shell commands.
internal sealed class ActivationPipe : IDisposable
{
    private static string Name => "TeamWong.Voiceling.Activation.V1." + System.Diagnostics.Process.GetCurrentProcess().SessionId;
    private readonly CancellationTokenSource cancellation = new();
    private readonly Task listener;
    public ActivationPipe(Action<string> received) => listener = ListenAsync(received, cancellation.Token);
    private static async Task ListenAsync(Action<string> received, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(Name, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(token).ConfigureAwait(false);
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
                deadline.CancelAfter(TimeSpan.FromSeconds(2));
                var lengthBytes = new byte[4]; await pipe.ReadExactlyAsync(lengthBytes, deadline.Token).ConfigureAwait(false);
                var length = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(lengthBytes);
                if (length is < 1 or > 8192) continue;
                var data = new byte[length]; await pipe.ReadExactlyAsync(data, deadline.Token).ConfigureAwait(false);
                var text = Encoding.UTF8.GetString(data);
                if (LicensePolicy.ActivationKey(text) is not null)
                    _ = Application.Current.Dispatcher.BeginInvoke(() => received(text));
            }
            catch (Exception ex) when (ex is IOException or OperationCanceledException or UnauthorizedAccessException)
            {
                if (token.IsCancellationRequested) break;
                try { await Task.Delay(100, token).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }
    }
    public static async Task<bool> SendAsync(string url)
    {
        if (LicensePolicy.ActivationKey(url) is null) return false;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try
        {
            using var pipe = new NamedPipeClientStream(".", Name, PipeDirection.Out,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.ConnectAsync(timeout.Token).ConfigureAwait(false);
            var data = Encoding.UTF8.GetBytes(url);
            if (data.Length > 8192) return false;
            var length = new byte[4]; System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(length, data.Length);
            await pipe.WriteAsync(length, timeout.Token).ConfigureAwait(false);
            await pipe.WriteAsync(data, timeout.Token).ConfigureAwait(false);
            await pipe.FlushAsync(timeout.Token).ConfigureAwait(false); return true;
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or UnauthorizedAccessException) { return false; }
    }
    public void Dispose() { cancellation.Cancel(); _ = listener.ContinueWith(_ => cancellation.Dispose(), TaskScheduler.Default); }
}
