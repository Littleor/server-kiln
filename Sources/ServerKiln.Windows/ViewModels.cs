using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace ServerKiln.Windows;

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Changed([CallerMemberName] string? property = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));
    protected void AllChanged() => Changed("");
}

public sealed class FleetViewModel : ObservableObject
{
    private AppPreferences preferences = new();
    public ObservableCollection<ServerViewModel> Servers { get; } = [];
    private ServerViewModel? selected;
    public ServerViewModel? SelectedServer
    {
        get => selected;
        set
        {
            if (ReferenceEquals(selected, value)) return;
            selected = value; Changed(); Changed(nameof(DetailVisibility)); SelectionChanged?.Invoke();
        }
    }
    public event Action? SelectionChanged;
    private string message = "";
    public string StatusMessage { get => message; set { message = value; Changed(); } }
    public Visibility EmptyVisibility => Servers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DetailVisibility => SelectedServer is null ? Visibility.Collapsed : Visibility.Visible;
    public string FleetSummary => string.Format(Localizer.Current["FleetSummaryFormat"],
        Servers.Count(s => s.Config.Enabled), TrainingCount);
    private IEnumerable<ServerViewModel> Enabled => Servers.Where(s => s.Config.Enabled);
    private IEnumerable<ServerViewModel> GpuServers => Enabled.Where(s => s.IsOnline && s.Reading.Snapshot?.IsGpuServer == true);
    public int TrainingCount => GpuServers.Count(s => s.BusyCount > 0);
    public string TrainingTotal => "/ " + GpuServers.Count();
    public double TrainingFraction => GpuServers.Any() ? 100.0 * TrainingCount / GpuServers.Count() : 0;
    public int BusyGpuCount => GpuServers.Sum(s => s.BusyCount);
    public string GpuTotal => "/ " + GpuServers.Sum(s => s.Gpus.Count);
    public double GpuFraction => GpuServers.Sum(s => s.Gpus.Count) is > 0 and var total ? 100.0 * BusyGpuCount / total : 0;
    public int OnlineCount => Enabled.Count(s => s.IsOnline);
    public string OnlineTotal => "/ " + Enabled.Count();
    public double OnlineFraction => Enabled.Any() ? 100.0 * OnlineCount / Enabled.Count() : 0;
    public Brush TrainingBrush => LoadColors.Strong(TrainingFraction);
    public Brush GpuBrush => LoadColors.Strong(GpuFraction);
    public string PollingLabel => string.Format(Localizer.Current["PollingFormat"], preferences.ForegroundIntervalSeconds);

    public void Sync(AppPreferences preferences)
    {
        this.preferences = preferences;
        var selectedId = selected?.Config.Id;
        foreach (var item in Servers.Where(s => !preferences.Servers.Any(c => c.Id == s.Config.Id)).ToArray()) Servers.Remove(item);
        foreach (var config in preferences.Servers)
        {
            var item = Servers.FirstOrDefault(s => s.Config.Id == config.Id);
            if (item is null) Servers.Add(new ServerViewModel(config, preferences.Policy)); else item.SetConfig(config, preferences.Policy);
        }
        SelectedServer = Servers.FirstOrDefault(s => s.Config.Id == selectedId) ?? Servers.FirstOrDefault();
        AllChanged();
    }

    public void Apply(ServerReading reading)
    {
        var server = Servers.FirstOrDefault(s => s.Config.Id == reading.Server.Id);
        server?.Apply(reading);
        AllChanged();
    }
    public void RefreshLanguage() { foreach (var server in Servers) server.Refresh(); AllChanged(); }
}

public sealed class ServerViewModel(ServerConfig config, BusyPolicy? policy = null) : ObservableObject
{
    private BusyPolicy policy = policy ?? new();
    public ObservableCollection<GpuViewModel> Gpus { get; } = [];
    public ObservableCollection<ProcessViewModel> Tasks { get; } = [];
    public ObservableCollection<ProcessViewModel> Processes { get; } = [];
    public ServerConfig Config { get; private set; } = config;
    public ServerReading Reading { get; private set; } = new(config);
    public string Name => Config.Name;
    public string Target => Config.Target;
    public bool IsOnline => Config.Enabled && Snapshot is not null && string.IsNullOrEmpty(Error);
    public int BusyCount => Snapshot is { } snapshot ? policy.BusyCount(snapshot) : 0;
    public string Occupancy => $"{BusyCount}/{Gpus.Count}";
    public Brush OccupancyBrush => LoadColors.Strong(Gpus.Count > 0 ? 100.0 * BusyCount / Gpus.Count : 0);
    public Brush OccupancyFill => LoadColors.Soft(Gpus.Count > 0 ? 100.0 * BusyCount / Gpus.Count : 0);
    public Brush ConnectionBrush => (Brush)Application.Current.FindResource(!Config.Enabled || Snapshot is null && Error is null ? "MutedBrush" : IsOnline ? "GreenBrush" : "DangerBrush");
    public string HeaderHint => Error is not null ? ErrorTitle : Status;
    public Visibility HeaderMetricsVisibility => Snapshot is not null && Error is null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility HeaderMessageVisibility => HeaderMetricsVisibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
    public string GpuModel => string.Join(" · ", Gpus.GroupBy(g => g.Model).Select(g => $"{g.Key} × {g.Count()}"));
    public string TaskHeading => $"{Localizer.Current["Jobs"]}  {Tasks.Count}";
    public Visibility NoTasksVisibility => Tasks.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public string ProcessHeading => $"{Localizer.Current["Processes"]}  {Processes.Count}";
    public string Status => !Config.Enabled ? Localizer.Current["Disabled"] : Localizer.Current.Activity(
        !string.IsNullOrEmpty(Error) ? ServerActivity.Offline : Snapshot is null ? null
        : !Snapshot.IsGpuServer ? ServerActivity.CpuOnly : BusyCount > 0 ? ServerActivity.Busy : ServerActivity.Idle);
    public Brush StatusBrush => (Brush)System.Windows.Application.Current.FindResource(!Config.Enabled ? "MutedBrush" : Reading.Activity switch
    { ServerActivity.Busy => "BusyBrush", ServerActivity.Idle or ServerActivity.CpuOnly => "GreenBrush",
        ServerActivity.Offline => "DangerBrush", _ => "MutedBrush" });
    private ServerSnapshot? Snapshot => Reading.Snapshot;
    public string Summary => Snapshot is null ? "—" : Snapshot.IsGpuServer
        ? $"{Snapshot.Gpus.Length} GPU · {DisplayFormat.Mib(Snapshot.Gpus.Sum(g => g.MemoryUsedMiB))}"
        : $"CPU {Cpu} · RAM {Ram}";
    public string Subtitle => Snapshot is null ? Target + " · " + Status
        : $"{Snapshot.System.Hostname} · {Snapshot.System.Os}";
    public string Cpu => DisplayFormat.Percent(Snapshot?.System.CpuUsage);
    public string Cores => Snapshot?.System.CpuCores is { } cores ? $"{cores} {Localizer.Current["Cores"]}" : "—";
    public string Ram => DisplayFormat.Percent(Snapshot?.System.MemFraction);
    public string RamSize => DisplayFormat.Mib(Snapshot?.System.MemTotalKB / 1024);
    public string Disk => DisplayFormat.Percent(Snapshot?.System.DiskFraction);
    public string DiskSize => DisplayFormat.Mib(Snapshot?.System.DiskTotalKB / 1024);
    public double CpuValue => (Snapshot?.System.CpuUsage ?? 0) * 100;
    public double RamValue => (Snapshot?.System.MemFraction ?? 0) * 100;
    public double DiskValue => (Snapshot?.System.DiskFraction ?? 0) * 100;
    public Brush CpuBrush => LoadColors.Strong(CpuValue);
    public Brush RamBrush => LoadColors.Strong(RamValue);
    public Brush DiskBrush => LoadColors.Strong(DiskValue);
    public string CpuDetail => $"{Cpu} · {Cores}";
    public string RamDetail => $"{DisplayFormat.Mib((Snapshot?.System.MemTotalKB - Snapshot?.System.MemAvailableKB) / 1024)} / {RamSize}";
    public string DiskDetail => $"{DisplayFormat.Mib(Snapshot?.System.DiskUsedKB / 1024)} / {DiskSize}";
    public string Network => Rx + "   " + Tx;
    public string Load => Snapshot?.System.Load is { Length: > 0 } load ? string.Join("  ", load.Select(n => n.ToString("0.00"))) : "—";
    public string Uptime => Localizer.Current["Uptime"] + " " + DisplayFormat.Duration(Snapshot?.System.UptimeSeconds);
    public string Rx => "↓ " + DisplayFormat.Rate(Snapshot?.System.NetRxRate);
    public string Tx => "↑ " + DisplayFormat.Rate(Snapshot?.System.NetTxRate);
    public string? Error => Reading.Error;
    public string ErrorTitle => Localizer.Current[SshDiagnostics.Classify(Error) switch
    {
        SshFailureKind.UnverifiedHost => "UnverifiedHost", SshFailureKind.ChangedHost => "ChangedHost",
        SshFailureKind.MissingKey => "MissingKey", SshFailureKind.KeyPermissions => "KeyPermissions",
        SshFailureKind.Authentication => "Authentication", SshFailureKind.Timeout => "ConnectionTimeout", _ => "Error"
    }];
    public string ErrorHint => Localizer.Current[SshDiagnostics.Classify(Error) switch
    {
        SshFailureKind.UnverifiedHost => "UnverifiedHostHint", SshFailureKind.ChangedHost => "ChangedHostHint",
        SshFailureKind.MissingKey => "MissingKeyHint", SshFailureKind.KeyPermissions => "KeyPermissionsHint",
        SshFailureKind.Authentication => "AuthenticationHint", _ => "RetryHint"
    }];
    public Visibility ErrorVisibility => string.IsNullOrEmpty(Error) ? Visibility.Collapsed : Visibility.Visible;
    public string GpuMessage => Snapshot is null ? Localizer.Current["NoData"] : Snapshot.GpuError
        ?? (Snapshot.IsGpuServer ? "" : Localizer.Current["NoGpu"]);
    public Visibility GpuVisibility => Snapshot?.IsGpuServer == true ? Visibility.Visible : Visibility.Collapsed;
    public Visibility GpuMessageVisibility => string.IsNullOrEmpty(GpuMessage) ? Visibility.Collapsed : Visibility.Visible;
    public JobViewModel[] Jobs => Reading.Jobs?.Select(j => new JobViewModel(j)).ToArray() ?? [];
    public JobViewModel? LastJob => Reading.Jobs?.Where(j => j.EndedAt is not null).OrderByDescending(j => j.EndedAt).Select(j => new JobViewModel(j)).FirstOrDefault();
    public Visibility LastJobVisibility => LastJob is null ? Visibility.Collapsed : Visibility.Visible;
    public string JobMessage => Jobs.Length == 0 ? Localizer.Current["NoJobs"] : "";
    public void Apply(ServerReading reading)
    {
        Reading = reading;
        var stats = Snapshot?.Gpus ?? [];
        foreach (var old in Gpus.Where(g => !stats.Any(s => s.Index == g.Stat.Index)).ToArray()) Gpus.Remove(old);
        foreach (var stat in stats)
        {
            var gpu = Gpus.FirstOrDefault(g => g.Stat.Index == stat.Index);
            if (gpu is null) Gpus.Add(new GpuViewModel(stat)); else gpu.Apply(stat);
        }
        SyncTasks(Tasks, Snapshot?.Tasks ?? []);
        SyncTasks(Processes, Snapshot?.Processes ?? []);
        AllChanged();
    }
    private void SyncTasks(ObservableCollection<ProcessViewModel> items, RemoteTask[] tasks)
    {
        foreach (var old in items.Where(p => !tasks.Any(t => t.Pid == p.Pid)).ToArray()) items.Remove(old);
        foreach (var task in tasks.DistinctBy(t => t.Pid))
        {
            var item = items.FirstOrDefault(p => p.Pid == task.Pid);
            if (item is null) items.Add(new ProcessViewModel(task, Snapshot!.FetchedAt));
            else item.Apply(task, Snapshot!.FetchedAt);
        }
    }
    public void SetConfig(ServerConfig config, BusyPolicy policy) { Config = config; this.policy = policy; AllChanged(); }
    public void Refresh() { foreach (var task in Tasks.Concat(Processes)) task.Refresh(); AllChanged(); }
}

internal static class LoadColors
{
    private static readonly Brush[] strong = [Make("#28764D"), Make("#786414"), Make("#99521D"), Make("#AD382D")];
    private static readonly Brush[] soft = [Make("#C9E7D4"), Make("#EEE2AE"), Make("#F0D2B0"), Make("#EEC7C1")];
    private static int Band(double value) => value < 40 ? 0 : value < 65 ? 1 : value < 85 ? 2 : 3;
    public static Brush Strong(double value) => strong[Band(value)];
    public static Brush Soft(double value) => soft[Band(value)];
    private static Brush Make(string color) { var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color)); brush.Freeze(); return brush; }
}

public sealed class GpuViewModel(GpuStat stat) : ObservableObject
{
    public GpuStat Stat { get; private set; } = stat;
    public void Apply(GpuStat stat) { Stat = stat; AllChanged(); }
    public string Name => $"GPU {Stat.Index}  ·  {Stat.Name}";
    public string Model => Stat.Name;
    public string Index => "GPU " + Stat.Index;
    public int Number => Stat.Index;
    public string Temperature => Stat.Temperature is { } value ? $"{value:0} °C" : "—";
    public string Power => Stat.PowerDraw is { } value ? $"{value:0} W" : "—";
    public string Telemetry => $"{(Stat.Temperature is { } t ? $"{t:0} °C" : "—")}  ·  {(Stat.PowerDraw is { } p ? $"{p:0} W" : "—")}";
    public string Utilization => $"{Stat.Utilization:0}%";
    public double UtilizationValue => Math.Clamp(Stat.Utilization, 0, 100);
    public string Memory => $"{DisplayFormat.Mib(Stat.MemoryUsedMiB)} / {DisplayFormat.Mib(Stat.MemoryTotalMiB)}";
    public double MemoryValue => Stat.MemoryFraction * 100;
    public Brush UtilizationBrush => LoadColors.Strong(UtilizationValue);
    public Brush MemoryBrush => LoadColors.Strong(MemoryValue);
    public Brush UtilizationFill => LoadColors.Soft(UtilizationValue);
    public Brush MemoryFill => LoadColors.Soft(MemoryValue);
}
public sealed class ProcessViewModel(RemoteTask task, DateTimeOffset sampledAt) : ObservableObject
{
    public RemoteTask Task { get; private set; } = task;
    private DateTimeOffset sampledAt = sampledAt;
    private bool expanded;
    public bool IsExpanded { get => expanded; set { expanded = value; Changed(); } }
    public void Apply(RemoteTask task, DateTimeOffset sampledAt)
    {
        // PID reuse must not keep the previous process's open detail panel.
        if (task.Command != Task.Command || task.User != Task.User || task.ElapsedSeconds < Task.ElapsedSeconds) expanded = false;
        Task = task; this.sampledAt = sampledAt; AllChanged();
    }
    public void Refresh() => AllChanged();
    public int Pid => Task.Pid;
    public string User => Task.User;
    public string Cpu => Task.CpuPercent is { } n ? $"{n:0}%" : "—";
    public string Ram => DisplayFormat.Mib(Task.RssKB / 1024);
    public string Command => Task.Command;
    public string ShortCommand
    {
        get
        {
            var space = Command.IndexOf(' ');
            var executable = space < 0 ? Command : Command[..space];
            return executable[(executable.LastIndexOf('/') + 1)..] + (space < 0 ? "" : Command[space..]);
        }
    }
    public string Cwd => Task.Cwd ?? "—";
    public bool HasCwd => !string.IsNullOrEmpty(Task.Cwd);
    public string Started => Task.ElapsedSeconds is { } seconds ? sampledAt.AddSeconds(-seconds).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss") : "—";
    public string CpuRam => Cpu + " · " + Ram;
    public string Metadata => $"{User}    ·    {DisplayFormat.Duration(Task.ElapsedSeconds)}"
        + (Task.GpuIndices.Length == 0 ? "" : $"    ·    GPU {string.Join(", ", Task.GpuIndices)}")
        + (Task.MemoryMiB is { } memory ? "    ·    " + DisplayFormat.Mib(memory) : "");
    public string Detail => $"{Task.Command}\n{Localizer.Current["Cwd"]}: {Task.Cwd ?? "—"}\n{Localizer.Current["Elapsed"]}: {DisplayFormat.Duration(Task.ElapsedSeconds)}\nGPU: {string.Join(", ", Task.GpuIndices)}";
}
public sealed record JobViewModel(TaskRecord Record)
{
    public string Command => Record.Command;
    public string User => Record.User;
    public string Gpus => Record.GpuIndices.Length == 0 ? "—" : string.Join(", ", Record.GpuIndices);
    public string Started => Record.StartedAt.LocalDateTime.ToString("MM-dd HH:mm");
    public string Ended => Record.EndedAt is { } ended ? ended.LocalDateTime.ToString("MM-dd HH:mm") : Localizer.Current["Running"];
    public string Detail => $"{Record.User} · GPU {string.Join(",", Record.GpuIndices)} · {Record.StartedAt.LocalDateTime:g} → "
        + (Record.EndedAt is { } ended ? ended.LocalDateTime.ToString("g") : Localizer.Current["Running"]);
}
