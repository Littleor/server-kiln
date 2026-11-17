using System.Text.RegularExpressions;

namespace ServerKiln.Windows.Core;

/// <summary>Consumes the same @@SECTION protocol as the Swift client.</summary>
public static class SnapshotParser
{
    private static readonly Regex ProcessFields = new(@"\s+", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
    private static readonly string[] WorkloadKeywords = ["python", "torchrun", "deepspeed", "accelerate", "vllm", "sglang",
        "llamafactory", "swift", "megatron", "colossalai", "horovodrun", "mpirun", "jupyter"];
    private static readonly string[] ToolKeywords = ["nvitop", "gpustat", "nvtop", "nvidia-smi", "glances", "htop", "btop",
        "py-spy", "tensorboard", "jupyter", "ipykernel", "ipython", "kernelgateway", "debugpy", "pip", "pip3", "conda",
        "mamba", "wandb-service", "wandb_service", "supervisord", "multiprocessing.resource_tracker"];
    private const string Invisible = "(进程不可见)";

    public static ServerSnapshot Parse(string output, DateTimeOffset? now = null)
    {
        var sections = SplitSections(output);
        string[] Lines(string key) => sections.GetValueOrDefault(key, []);
        string First(string key) => Lines(key).FirstOrDefault()?.Trim() ?? "";
        double? Mem(string key) => Lines("MEM").Where(l => l.StartsWith(key + ":", StringComparison.Ordinal))
            .Select(l => DisplayFormat.Number(Words(l.Replace(':', ' ')).ElementAtOrDefault(1))).FirstOrDefault();
        var disk = Words(First("DISK"));
        var system = new SystemStat
        {
            Hostname = First("HOST"), Os = First("OS"), UptimeSeconds = DisplayFormat.Number(First("UPTIME")),
            CpuCores = int.TryParse(First("NCPU"), out var cores) ? cores : null,
            Load = Words(First("LOAD")).Take(3).Select(DisplayFormat.Number).OfType<double>().ToArray(),
            CpuUsage = ParseCpu(Lines("CPU")), MemTotalKB = Mem("MemTotal"), MemAvailableKB = Mem("MemAvailable"),
            DiskTotalKB = DisplayFormat.Number(disk.ElementAtOrDefault(1)), DiskUsedKB = DisplayFormat.Number(disk.ElementAtOrDefault(2))
        };
        var nets = Lines("NET").Select(l => Words(l).Select(DisplayFormat.Number).OfType<double>().ToArray())
            .Where(n => n.Length == 3).ToArray();
        if (nets.LastOrDefault() is { } net)
        {
            system = system with { NetSampleUptime = net[0], NetRxBytes = net[1], NetTxBytes = net[2] };
            if (nets.Length >= 2) system = system.WithRates(new SystemStat
                { NetSampleUptime = nets[0][0], NetRxBytes = nets[0][1], NetTxBytes = nets[0][2] });
        }
        var gpuLines = Lines("GPU").Where(l => !string.IsNullOrWhiteSpace(l)).ToArray();
        var gpus = gpuLines.Select(ParseGpu).OfType<GpuStat>().ToArray();
        var cwd = new Dictionary<int, string>();
        foreach (var line in Lines("CWD"))
        {
            var parts = line.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 2 && int.TryParse(parts[0], out var pid)) cwd[pid] = parts[1];
        }
        var ps = ParseProcesses(Lines("PS"));
        var byPid = new Dictionary<int, RemoteTask>();
        foreach (var line in Lines("APPS"))
        {
            var fields = line.Split(',').Select(f => f.Trim()).ToArray();
            if (fields.Length < 3 || !int.TryParse(fields[1], out var pid)) continue;
            var memory = DisplayFormat.Number(fields[2]);
            var gpu = gpus.FirstOrDefault(g => g.Uuid == fields[0]);
            if (byPid.TryGetValue(pid, out var existing))
                byPid[pid] = existing with
                {
                    GpuIndices = gpu is null ? existing.GpuIndices : existing.GpuIndices.Append(gpu.Index).Distinct().ToArray(),
                    MemoryMiB = (existing.MemoryMiB ?? 0) + (memory ?? 0)
                };
            else
            {
                ps.TryGetValue(pid, out var info);
                byPid[pid] = new RemoteTask(pid, info?.User ?? "?", info?.ElapsedSeconds, info?.Command ?? Invisible,
                    gpu is null ? [] : [gpu.Index], memory, info?.CpuPercent, info?.RssKB, cwd.GetValueOrDefault(pid));
            }
        }
        var tasks = byPid.Values.OrderBy(t => t.GpuIndices.FirstOrDefault(int.MaxValue)).ThenBy(t => t.Pid).ToArray();
        var invisible = tasks.Length > 0 && tasks.All(t => t.Command == Invisible);
        if (tasks.Length == 0 || invisible)
        {
            var fallback = ParseProcesses(Lines("TOP")).Values.Where(t => IsWorkload(t.Command) && t.CpuPercent >= 1)
                .OrderByDescending(t => t.CpuPercent).Take(8).Select(t => t with { Cwd = cwd.GetValueOrDefault(t.Pid) }).ToArray();
            if (invisible && fallback.Length > 0)
                fallback[0] = fallback[0] with
                {
                    GpuIndices = tasks.SelectMany(t => t.GpuIndices).Distinct().Order().ToArray(),
                    MemoryMiB = tasks.Sum(t => t.MemoryMiB ?? 0)
                };
            if (!invisible || fallback.Length > 0) tasks = fallback;
        }
        var candidates = ParseProcesses(Lines("TOP").Concat(Lines("TOPMEM")).Concat(Lines("PS"))).Values
            .Where(t => !IsCollectorNoise(t.Command)).ToArray();
        var processes = candidates.OrderByDescending(t => t.CpuPercent ?? 0).ThenBy(t => t.Pid).Take(6)
            .Concat(candidates.OrderByDescending(t => t.RssKB ?? 0).ThenBy(t => t.Pid).Take(6))
            .DistinctBy(t => t.Pid).Select(t => t with { Cwd = cwd.GetValueOrDefault(t.Pid) }).ToArray();
        return new ServerSnapshot(system, sections.ContainsKey("GPU"), gpus,
            gpus.Length == 0 ? gpuLines.FirstOrDefault(l => ParseGpu(l) is null) : null,
            tasks, now ?? DateTimeOffset.UtcNow, processes);
    }

    public static Dictionary<string, string[]> SplitSections(string output)
    {
        var sections = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        string? current = null;
        foreach (var line in output.Replace("\r", "").Split('\n'))
        {
            if (line.StartsWith("@@", StringComparison.Ordinal))
            {
                current = line[2..].Trim();
                sections.TryAdd(current, []);
            }
            else if (current is not null && line.Length > 0) sections[current].Add(line);
        }
        return sections.ToDictionary(p => p.Key, p => p.Value.ToArray());
    }

    private static string[] Words(string value) => value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
    private static double? ParseCpu(string[] lines)
    {
        if (lines.Length < 2) return null;
        var a = Words(lines[0]).Skip(1).Select(DisplayFormat.Number).OfType<double>().ToArray();
        var b = Words(lines[1]).Skip(1).Select(DisplayFormat.Number).OfType<double>().ToArray();
        if (a.Length < 4 || b.Length < 4) return null;
        var delta = b.Take(8).Sum() - a.Take(8).Sum();
        var idle = b[3] + b.ElementAtOrDefault(4) - a[3] - a.ElementAtOrDefault(4);
        return delta > 0 ? Math.Clamp(1 - idle / delta, 0, 1) : null;
    }

    private static GpuStat? ParseGpu(string line)
    {
        var f = line.Split(',').Select(s => s.Trim()).ToArray();
        if (f.Length < 6 || !int.TryParse(f[0], out var index)) return null;
        double? N(int i) => DisplayFormat.Number(f.ElementAtOrDefault(i));
        return new GpuStat(index, f[1], f[2].Replace("NVIDIA ", ""), N(3) ?? 0, N(4) ?? 0, N(5) ?? 0, N(6), N(7), N(8));
    }

    private static Dictionary<int, RemoteTask> ParseProcesses(IEnumerable<string> lines)
    {
        var result = new Dictionary<int, RemoteTask>();
        foreach (var line in lines)
        {
            var f = ProcessFields.Split(line.Trim(), 6);
            if (f.Length != 6 || !int.TryParse(f[0], out var pid)) continue;
            // Retain every byte of the command after the first five whitespace-delimited fields.
            var command = f[5];
            result[pid] = new RemoteTask(pid, f[1], int.TryParse(f[2], out var elapsed) ? elapsed : null, command,
                [], CpuPercent: DisplayFormat.Number(f[3]), RssKB: DisplayFormat.Number(f[4]));
        }
        return result;
    }

    public static bool IsWorkload(string command)
    {
        var words = Words(command.ToLowerInvariant());
        var executable = words.FirstOrDefault()?.Split('/').Last() ?? "";
        if (executable.StartsWith("ps", StringComparison.Ordinal) || executable.StartsWith("sshd", StringComparison.Ordinal)) return false;
        if (!WorkloadKeywords.Any(k => executable.StartsWith(k, StringComparison.Ordinal))) return false;
        return !words.Take(6).Skip(1).Select(w => w.Split('/').Last()).Select(w => w.EndsWith(".py", StringComparison.Ordinal) ? w[..^3] : w)
            .Any(w => ToolKeywords.Any(t => w == t || w.StartsWith(t + "-", StringComparison.Ordinal) || w.StartsWith(t + "_", StringComparison.Ordinal)))
            && !command.Contains("resource_tracker import", StringComparison.Ordinal);
    }

    private static bool IsCollectorNoise(string command)
    {
        var exe = Words(command).FirstOrDefault()?.Split('/').Last() ?? "";
        return exe == "ps" || exe.StartsWith("sshd", StringComparison.Ordinal) || command.Contains("serverkiln/collect.sh", StringComparison.Ordinal)
            || command.StartsWith("sh -c eval", StringComparison.Ordinal) || command.Contains("base64 -d", StringComparison.Ordinal);
    }
}
