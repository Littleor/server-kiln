using System.Buffers.Binary;
using System.IO.Pipes;
using System.Runtime.InteropServices;

namespace ServerKiln.Windows.Core;

/// <summary>Lets a shortcut reveal the existing instance without starting another monitor.</summary>
public sealed class InstanceActivation : IAsyncDisposable
{
    private readonly CancellationTokenSource stop = new();
    private readonly Task listener;

    public InstanceActivation(string pipeName, Action showWindow)
    {
        listener = ListenAsync(pipeName, showWindow, stop.Token);
    }

    private static async Task ListenAsync(string pipeName, Action showWindow, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            using var server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            try
            {
                await server.WaitForConnectionAsync(token).ConfigureAwait(false);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                timeout.CancelAfter(TimeSpan.FromSeconds(3));
                var pid = new byte[4];
                BinaryPrimitives.WriteInt32LittleEndian(pid, Environment.ProcessId);
                await server.WriteAsync(pid, timeout.Token).ConfigureAwait(false);
                var command = new byte[1];
                await server.ReadExactlyAsync(command, timeout.Token).ConfigureAwait(false);
                if (command[0] == 1)
                {
                    showWindow();
                    await server.WriteAsync(command, timeout.Token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
            catch (OperationCanceledException) { } // An abandoned shortcut must not block later requests.
            catch (IOException) { }
        }
    }

    public static async Task<bool> TryActivateAsync(string pipeName, int timeoutMilliseconds = 3000)
    {
        using var timeout = new CancellationTokenSource(timeoutMilliseconds);
        using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try
        {
            await client.ConnectAsync(timeout.Token).ConfigureAwait(false);
            var pid = new byte[4];
            await client.ReadExactlyAsync(pid, timeout.Token).ConfigureAwait(false);
            // The newly launched process owns foreground permission; transfer it to the app.
            if (OperatingSystem.IsWindows()) AllowSetForegroundWindow(BinaryPrimitives.ReadInt32LittleEndian(pid));
            await client.WriteAsync(new byte[] { 1 }, timeout.Token).ConfigureAwait(false);
            var acknowledgement = new byte[1];
            await client.ReadExactlyAsync(acknowledgement, timeout.Token).ConfigureAwait(false);
            return acknowledgement[0] == 1;
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or UnauthorizedAccessException) { return false; }
    }

    public async ValueTask DisposeAsync()
    {
        await stop.CancelAsync().ConfigureAwait(false);
        try { await listener.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        finally { stop.Dispose(); }
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AllowSetForegroundWindow(int processId);
}
