using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ServerKiln.Windows.Core;

public sealed record ServerConfig
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; init; } = "";
    public string Target { get; init; } = "";
    public int? Port { get; init; }
    /// Optional per-server override. Existing IdentityFile directives remain active when blank.
    public string IdentityFile { get; init; } = "";
    public bool Enabled { get; init; } = true;
    public bool Muted { get; init; }

    public void Validate()
    {
        if (Id == Guid.Empty || string.IsNullOrWhiteSpace(Name))
            throw new ArgumentException("A server name is required. / 请填写服务器名称。");
        // A target is one OpenSSH destination, never a shell fragment or option.
        if (string.IsNullOrWhiteSpace(Target) || Target.StartsWith('-') || Target.Any(char.IsWhiteSpace)
            || Target.Any(c => char.IsControl(c) || c is '"' or '\'' or '`'))
            throw new ArgumentException("Use an SSH alias or user@host. / 请填写 SSH 别名或 user@host。");
        if (Port is < 1 or > 65535) throw new ArgumentException("Port must be 1–65535. / 端口范围为 1–65535。");
    }
}

public sealed record BusyPolicy(double UtilizationThreshold = 10, double MemoryThresholdMiB = 1024)
{
    public bool IsBusy(GpuStat gpu) => gpu.Utilization >= UtilizationThreshold || gpu.MemoryUsedMiB >= MemoryThresholdMiB;
    public int BusyCount(ServerSnapshot snapshot) => snapshot.Gpus.Count(IsBusy);
}

public sealed record GpuStat(int Index, string Uuid, string Name, double Utilization,
    double MemoryUsedMiB, double MemoryTotalMiB, double? Temperature = null,
    double? PowerDraw = null, double? PowerLimit = null)
{
    public double MemoryFraction => MemoryTotalMiB > 0 ? Math.Clamp(MemoryUsedMiB / MemoryTotalMiB, 0, 1) : 0;
}

public sealed record RemoteTask(int Pid, string User, int? ElapsedSeconds, string Command,
    int[] GpuIndices, double? MemoryMiB = null, double? CpuPercent = null, double? RssKB = null, string? Cwd = null);

public sealed record SystemStat
{
    public string Hostname { get; init; } = "";
    public string Os { get; init; } = "";
    public double? UptimeSeconds { get; init; }
    public int? CpuCores { get; init; }
    public double? CpuUsage { get; init; }
    public double[] Load { get; init; } = [];
    public double? MemTotalKB { get; init; }
    public double? MemAvailableKB { get; init; }
    public double? DiskTotalKB { get; init; }
    public double? DiskUsedKB { get; init; }
    public double? NetSampleUptime { get; init; }
    public double? NetRxBytes { get; init; }
    public double? NetTxBytes { get; init; }
    public double? NetRxRate { get; init; }
    public double? NetTxRate { get; init; }
    public double? MemFraction => MemTotalKB > 0 && MemAvailableKB is not null
        ? Math.Clamp((MemTotalKB.Value - MemAvailableKB.Value) / MemTotalKB.Value, 0, 1) : null;
    public double? DiskFraction => DiskTotalKB > 0 && DiskUsedKB is not null
        ? Math.Clamp(DiskUsedKB.Value / DiskTotalKB.Value, 0, 1) : null;

    public SystemStat WithRates(SystemStat? previous)
    {
        if (previous is not null && NetSampleUptime > previous.NetSampleUptime
            && NetRxBytes >= previous.NetRxBytes && NetTxBytes >= previous.NetTxBytes)
            return this with
            {
                NetRxRate = (NetRxBytes - previous.NetRxBytes) / (NetSampleUptime - previous.NetSampleUptime),
                NetTxRate = (NetTxBytes - previous.NetTxBytes) / (NetSampleUptime - previous.NetSampleUptime)
            };
        return this with { NetRxRate = previous?.NetRxRate, NetTxRate = previous?.NetTxRate };
    }
}

public sealed record ServerSnapshot(SystemStat System, bool HasNvidiaSmi, GpuStat[] Gpus,
    string? GpuError, RemoteTask[] Tasks, DateTimeOffset FetchedAt, RemoteTask[] Processes)
{
    public bool IsGpuServer => HasNvidiaSmi && Gpus.Length > 0;
}

public enum ServerActivity { Busy, Idle, CpuOnly, Offline }
public sealed record ActivityTransition(Guid ServerId, ServerActivity From, ServerActivity To);
public sealed record ServerReading(ServerConfig Server, ServerSnapshot? Snapshot = null,
    string? Error = null, int Failures = 0, DateTimeOffset? LastAttempt = null,
    DateTimeOffset? LastSuccess = null, ServerActivity? Activity = null, TaskRecord[]? Jobs = null);

public sealed record AppPreferences
{
    public int SchemaVersion { get; init; } = 1;
    public ServerConfig[] Servers { get; init; } = [];
    public string SshExecutable { get; init; } = "";
    public string SshConfigPath { get; init; } = "";
    public string Language { get; init; } = "system";
    public int BackgroundIntervalSeconds { get; init; } = 30;
    public int ForegroundIntervalSeconds { get; init; } = 3;
    public BusyPolicy Policy { get; init; } = new();
    public int DebounceCount { get; init; } = 2;
    public int HistoryRetentionDays { get; init; } = 30;
    public bool NotifyOnIdle { get; init; } = true;
    public bool NotifyOnBusy { get; init; } = true;
    public bool NotifyOnConnection { get; init; }
    public bool BarkEnabled { get; init; }
    public string BarkServer { get; init; } = "https://api.day.app";

    public void Validate()
    {
        if (SchemaVersion != 1) throw new ArgumentException("Unsupported settings version.");
        if (Servers.Select(s => s.Id).Distinct().Count() != Servers.Length) throw new ArgumentException("Duplicate server IDs.");
        foreach (var server in Servers) server.Validate();
        if (BackgroundIntervalSeconds is < 3 or > 3600 || ForegroundIntervalSeconds is < 1 or > 300
            || DebounceCount is < 1 or > 20 || HistoryRetentionDays is < 1 or > 365
            || !double.IsFinite(Policy.UtilizationThreshold) || Policy.UtilizationThreshold is < 0 or > 100
            || !double.IsFinite(Policy.MemoryThresholdMiB) || Policy.MemoryThresholdMiB < 0)
            throw new ArgumentException("Invalid polling interval, threshold or retention. / 刷新间隔、阈值或保留天数无效。");
        if (BarkEnabled) BarkClient.ValidateServer(BarkServer);
    }

    public bool ShouldNotify(ActivityTransition transition) => transition.To switch
    {
        ServerActivity.Offline => NotifyOnConnection,
        _ when transition.From == ServerActivity.Offline => NotifyOnConnection,
        ServerActivity.Idle => NotifyOnIdle,
        ServerActivity.Busy => NotifyOnBusy,
        _ => false
    };
}

public static class JsonDefaults
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };
}

public static class DisplayFormat
{
    public static string Percent(double? fraction) => fraction is { } n ? $"{n * 100:0}%" : "—";
    public static string Mib(double? value) => value is not { } n ? "—" : n >= 1024 ? $"{n / 1024:0.0} GiB" : $"{n:0} MiB";
    public static string Duration(double? seconds) => seconds is not { } n ? "—"
        : n >= 86400 ? $"{(int)n / 86400}d {(int)n % 86400 / 3600}h"
        : n >= 3600 ? $"{(int)n / 3600}h {(int)n % 3600 / 60}m"
        : n >= 60 ? $"{(int)n / 60}m {(int)n % 60}s" : $"{(int)n}s";
    public static string Rate(double? value) => value is not { } n ? "—" : n >= 1048576 ? $"{n / 1048576:0.0} MiB/s" : $"{n / 1024:0.0} KiB/s";
    public static double? Number(string? text) => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var n)
        && double.IsFinite(n) ? n : null;
}
