namespace ServerKiln.Windows.Core;

public enum HistoryRange { TenMinutes, Day, Week, Month }
public enum GpuHistoryMetric { Utilization, Memory }

public static class HistoryRanges
{
    public static TimeSpan Duration(this HistoryRange range) => TimeSpan.FromSeconds(range switch
    { HistoryRange.TenMinutes => 600, HistoryRange.Day => 86400, HistoryRange.Week => 7 * 86400, _ => 30 * 86400 });
    // Match HistoryRange.bucket in the Mac client.
    public static int BucketSeconds(this HistoryRange range) => range switch
    { HistoryRange.TenMinutes => 5, HistoryRange.Day => 300, HistoryRange.Week => 1800, _ => 10800 };
}

/// <summary>High-resolution live history stays in memory; disk history remains one sample per minute.</summary>
public sealed class RecentSamples
{
    private readonly object gate = new();
    private readonly Dictionary<Guid, List<HistoryPoint>> samples = [];
    private readonly Dictionary<Guid, DateTimeOffset> last = [];
    public const int WindowSeconds = 600;
    public const int MinimumIntervalSeconds = 5;

    public void Record(Guid server, ServerSnapshot snapshot, DateTimeOffset now)
    {
        lock (gate)
        {
            if (last.TryGetValue(server, out var previous))
            {
                if (now >= previous && (now - previous).TotalSeconds < MinimumIntervalSeconds) return;
                if (now < previous) samples.Remove(server); // Recover from a wall-clock correction.
            }
            last[server] = now;
            if (!samples.TryGetValue(server, out var points)) samples[server] = points = [];
            var gpus = snapshot.Gpus;
            var total = gpus.Sum(g => g.MemoryTotalMiB);
            var used = gpus.Sum(g => g.MemoryUsedMiB);
            points.Add(new HistoryPoint(now, null, gpus.Length == 0 ? null : gpus.Average(g => g.Utilization),
                total > 0 ? used / total : null, gpus.Length == 0 ? null : used, snapshot.System.CpuUsage, snapshot.System.MemFraction));
            points.AddRange(gpus.Select(g => new HistoryPoint(now, g.Index, g.Utilization, g.MemoryFraction, g.MemoryUsedMiB, null, null)));
            var cutoff = now.AddSeconds(-WindowSeconds);
            points.RemoveAll(p => p.Time < cutoff);
        }
    }

    public HistoryPoint[] Query(Guid server, DateTimeOffset since, bool perGpu = false)
    {
        lock (gate) return samples.TryGetValue(server, out var points)
            ? points.Where(p => p.Time >= since && (p.Gpu is not null) == perGpu).ToArray() : [];
    }

    public void Forget(Guid server) { lock (gate) { samples.Remove(server); last.Remove(server); } }
}
