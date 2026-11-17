using System.Collections.Concurrent;

namespace ServerKiln.Windows.Core;

public sealed class FleetMonitor : IAsyncDisposable
{
    private AppPreferences preferences;
    private readonly HistoryStore history;
    private readonly Func<ServerConfig, AppPreferences, ICollectorSession> createSession;
    private readonly SemaphoreSlim tickGate = new(1, 1);
    private readonly ConcurrentDictionary<Guid, ServerReading> readings = new();
    private readonly ConcurrentDictionary<Guid, (ServerConfig Config, string Executable, string ConfigPath, ICollectorSession Session)> sessions = new();
    private readonly ConcurrentDictionary<Guid, TaskTracker> tasks = new();
    private readonly ConcurrentDictionary<Guid, TransitionTracker> transitions = new();
    private DateTimeOffset lastPrune = DateTimeOffset.MinValue;
    private bool disposed;
    public event Action<ServerReading>? ReadingChanged;
    public event Action<ServerConfig, ActivityTransition>? TransitionDetected;
    public RecentSamples Recent { get; } = new();

    public FleetMonitor(AppPreferences preferences, HistoryStore history,
        Func<ServerConfig, AppPreferences, ICollectorSession>? createSession = null)
    {
        preferences.Validate();
        this.preferences = preferences;
        this.history = history;
        this.createSession = createSession ?? ((s, p) => new SshSession(s, p.SshExecutable, p.SshConfigPath));
    }

    public void UpdatePreferences(AppPreferences value) { value.Validate(); Volatile.Write(ref preferences, value); }
    public ServerReading[] Readings => readings.Values.ToArray();

    public static TimeSpan PollInterval(ServerReading reading, AppPreferences preferences, bool foreground)
    {
        var normal = foreground ? preferences.ForegroundIntervalSeconds : preferences.BackgroundIntervalSeconds;
        var seconds = reading.Failures switch
        {
            0 => normal,
            < 3 => Math.Min(normal, 3),
            _ => Math.Max(normal, Math.Min(300, 15 * (1 << Math.Min(reading.Failures - 3, 5))))
        };
        return TimeSpan.FromSeconds(seconds);
    }

    public async Task TickAsync(bool foreground, bool force = false, CancellationToken cancellationToken = default)
    {
        if (!await tickGate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return;
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            var settings = Volatile.Read(ref preferences);
            foreach (var (id, entry) in sessions.ToArray())
                if (!settings.Servers.Any(s => s.Id == id && s.Enabled && s.Target == entry.Config.Target && s.Port == entry.Config.Port
                        && s.IdentityFile == entry.Config.IdentityFile)
                    || settings.SshExecutable != entry.Executable || settings.SshConfigPath != entry.ConfigPath)
                {
                    sessions.TryRemove(id, out _);
                    await entry.Session.DisposeAsync().ConfigureAwait(false);
                    transitions.TryRemove(id, out _);
                    if (settings.Servers.FirstOrDefault(s => s.Id == id) is { } changed)
                        readings[id] = new ServerReading(changed);
                }
            foreach (var id in readings.Keys.Where(id => !settings.Servers.Any(s => s.Id == id)).ToArray())
            { readings.TryRemove(id, out _); tasks.TryRemove(id, out _); transitions.TryRemove(id, out _); Recent.Forget(id); }
            using var concurrency = new SemaphoreSlim(4, 4);
            await Task.WhenAll(settings.Servers.Where(s => s.Enabled).Select(async server =>
            {
                var reading = readings.GetOrAdd(server.Id, _ => new ServerReading(server));
                if (!force && reading.LastAttempt is { } attempted && DateTimeOffset.UtcNow - attempted < PollInterval(reading, settings, foreground)) return;
                await concurrency.WaitAsync(cancellationToken).ConfigureAwait(false);
                try { await RefreshAsync(server, settings, cancellationToken).ConfigureAwait(false); }
                finally { concurrency.Release(); }
            })).ConfigureAwait(false);
            if (DateTimeOffset.UtcNow - lastPrune > TimeSpan.FromHours(1))
            {
                history.Prune(DateTimeOffset.UtcNow, settings.HistoryRetentionDays);
                lastPrune = DateTimeOffset.UtcNow;
            }
        }
        finally { tickGate.Release(); }
    }

    private async Task RefreshAsync(ServerConfig server, AppPreferences settings, CancellationToken token)
    {
        var reading = readings.GetOrAdd(server.Id, _ => new ServerReading(server));
        ServerActivity? activity = null;
        try
        {
            var entry = sessions.GetOrAdd(server.Id, _ => (server, settings.SshExecutable, settings.SshConfigPath, createSession(server, settings)));
            var snapshot = await entry.Session.FetchAsync(token).ConfigureAwait(false);
            if (!Volatile.Read(ref preferences).Servers.Any(s => s == server && s.Enabled)) return;
            snapshot = snapshot with { System = snapshot.System.WithRates(reading.Snapshot?.System) };
            // Persistence failures are not SSH failures; propagate them to the application error handler.
            reading = reading with { Server = server, Snapshot = snapshot, Error = null, Failures = 0,
                LastAttempt = DateTimeOffset.UtcNow, LastSuccess = snapshot.FetchedAt };
            activity = snapshot.IsGpuServer ? settings.Policy.BusyCount(snapshot) > 0 ? ServerActivity.Busy : ServerActivity.Idle : ServerActivity.CpuOnly;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch (Exception ex) when (ex is IOException or TimeoutException or ArgumentException or System.ComponentModel.Win32Exception)
        {
            if (sessions.TryRemove(server.Id, out var entry)) await entry.Session.DisposeAsync().ConfigureAwait(false);
            var failures = reading.Failures + 1;
            reading = reading with { Server = server, Failures = failures, LastAttempt = DateTimeOffset.UtcNow,
                Error = ex.Message, Activity = failures >= 3 ? ServerActivity.Offline : reading.Activity };
            if (failures >= 3) activity = ServerActivity.Offline;
        }
        if (!Volatile.Read(ref preferences).Servers.Any(s => s == server && s.Enabled)) return;
        if (reading.Failures == 0 && reading.Snapshot is { } current)
        {
            history.Record(server.Id, current, current.FetchedAt);
            Recent.Record(server.Id, current, current.FetchedAt);
            var tracker = tasks.GetOrAdd(server.Id, id => history.LoadTasks(id));
            tracker.Observe(current.Tasks, current.FetchedAt);
            history.SaveTasks(server.Id, tracker);
            reading = reading with { Jobs = tracker.Running.Values.Concat(tracker.Finished).OrderByDescending(j => j.StartedAt).ToArray() };
        }
        reading = reading with { Activity = activity ?? reading.Activity };
        readings[server.Id] = reading;
        ReadingChanged?.Invoke(reading);
        if (activity is { } observed)
        {
            var tracker = transitions.GetOrAdd(server.Id, _ => new TransitionTracker(settings.DebounceCount));
            tracker.RequiredStreak = settings.DebounceCount;
            var transition = tracker.Observe(server.Id, observed);
            var latest = Volatile.Read(ref preferences);
            var currentServer = latest.Servers.FirstOrDefault(s => s.Id == server.Id);
            if (transition is not null && currentServer is { Enabled: true, Muted: false } && latest.ShouldNotify(transition))
                TransitionDetected?.Invoke(currentServer, transition);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await tickGate.WaitAsync().ConfigureAwait(false);
        try
        {
            disposed = true;
            foreach (var entry in sessions.Values) await entry.Session.DisposeAsync().ConfigureAwait(false);
            sessions.Clear();
        }
        finally { tickGate.Release(); }
    }
}
