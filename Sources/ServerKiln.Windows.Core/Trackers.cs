namespace ServerKiln.Windows.Core;

public sealed class TransitionTracker(int requiredStreak = 2)
{
    private readonly Dictionary<Guid, ServerActivity> confirmed = [];
    private readonly Dictionary<Guid, (ServerActivity Activity, int Count)> pending = [];
    public int RequiredStreak { get; set; } = Math.Max(1, requiredStreak);

    public ActivityTransition? Observe(Guid id, ServerActivity activity)
    {
        if (!confirmed.TryGetValue(id, out var current)) { confirmed[id] = activity; return null; }
        if (activity == current) { pending.Remove(id); return null; }
        var count = pending.TryGetValue(id, out var p) && p.Activity == activity ? p.Count + 1 : 1;
        if (count < Math.Max(1, RequiredStreak)) { pending[id] = (activity, count); return null; }
        confirmed[id] = activity;
        pending.Remove(id);
        return new ActivityTransition(id, current, activity);
    }

    public void Forget(Guid id) { confirmed.Remove(id); pending.Remove(id); }
}

public sealed record TaskRecord(string Command, string User, string? Cwd, int[] GpuIndices,
    DateTimeOffset StartedAt, DateTimeOffset? EndedAt = null);

public sealed class TaskTracker
{
    public Dictionary<string, TaskRecord> Running { get; set; } = [];
    public List<TaskRecord> Finished { get; set; } = [];
    public Dictionary<string, DateTimeOffset> LastSeen { get; set; } = [];
    public const int GraceSeconds = 90;
    private static string JobKey(RemoteTask task) => task.Command.Contains("multiprocessing.spawn", StringComparison.Ordinal)
        || task.Command.Contains("multiprocessing.forkserver", StringComparison.Ordinal) ? "spawn|" + (task.Cwd ?? task.User)
        : string.Join(' ', task.Command.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Where(w => !w.StartsWith("--local-rank", StringComparison.Ordinal) && !w.StartsWith("--local_rank", StringComparison.Ordinal)
                && !w.StartsWith("--rank", StringComparison.Ordinal)));

    public TaskRecord[] Observe(IEnumerable<RemoteTask> tasks, DateTimeOffset now)
    {
        var groups = tasks.GroupBy(JobKey).ToDictionary(g => g.Key, g => g.ToArray());
        foreach (var (key, members) in groups)
        {
            LastSeen[key] = now;
            var started = now.AddSeconds(-members.Max(m => m.ElapsedSeconds ?? 0));
            var gpus = members.SelectMany(m => m.GpuIndices).Distinct().Order().ToArray();
            if (Running.TryGetValue(key, out var record))
                Running[key] = record with { StartedAt = started < record.StartedAt ? started : record.StartedAt,
                    GpuIndices = record.GpuIndices.Concat(gpus).Distinct().Order().ToArray() };
            else
            {
                var display = members.MinBy(m => m.Command.Length)!;
                Running[key] = new TaskRecord(display.Command, display.User, display.Cwd, gpus, started);
            }
        }
        List<TaskRecord> ended = [];
        foreach (var (key, record) in Running.ToArray())
        {
            if (groups.ContainsKey(key) || !LastSeen.TryGetValue(key, out var seen) || (now - seen).TotalSeconds < GraceSeconds) continue;
            Running.Remove(key);
            LastSeen.Remove(key);
            if ((seen - record.StartedAt).TotalSeconds >= 60) ended.Add(record with { EndedAt = seen });
        }
        Finished = ended.Concat(Finished).OrderByDescending(r => r.EndedAt).Take(10).ToList();
        return ended.ToArray();
    }
}
