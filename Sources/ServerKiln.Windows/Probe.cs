using System.Diagnostics;
using System.Text.Json;

namespace ServerKiln.Windows;

internal static class Probe
{
    public static async Task<int> RunAsync(string[] args)
    {
        var position = Array.IndexOf(args, "--probe");
        if (position + 1 >= args.Length) { Console.Error.WriteLine("--probe requires a configured SSH alias."); return 2; }
        var preferences = new PreferencesStore(PreferencesStore.DefaultDirectory).Load();
        var server = preferences.Servers.FirstOrDefault(s => s.Target.Equals(args[position + 1], StringComparison.OrdinalIgnoreCase)
            || s.Name.Equals(args[position + 1], StringComparison.OrdinalIgnoreCase));
        if (server is null) { Console.Error.WriteLine("Probe target is not configured in ServerKiln."); return 2; }
        var count = 3;
        var samplePosition = Array.IndexOf(args, "--samples");
        if (samplePosition >= 0 && (samplePosition + 1 >= args.Length || !int.TryParse(args[samplePosition + 1], out count) || count is < 1 or > 10))
        { Console.Error.WriteLine("--samples must be 1–10."); return 2; }
        var watch = Stopwatch.StartNew();
        try
        {
            await using var session = new SshSession(server, preferences.SshExecutable, preferences.SshConfigPath);
            var gpuCount = 0;
            for (var sample = 0; sample < count; sample++)
            {
                var snapshot = await session.FetchAsync();
                gpuCount = snapshot.Gpus.Length;
                if (sample + 1 < count) await Task.Delay(1000);
            }
            // Suitable for a validation record: no hostnames, commands, usernames or key paths.
            Console.WriteLine(JsonSerializer.Serialize(new { connected = true, samples = count, gpuCount, durationMs = watch.ElapsedMilliseconds }));
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { connected = false, failure = SshDiagnostics.Classify(ex.Message).ToString(), durationMs = watch.ElapsedMilliseconds }));
            return 1;
        }
    }
}
