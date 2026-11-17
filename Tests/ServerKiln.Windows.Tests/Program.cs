using System.Diagnostics;
using System.Net;
using System.Text.Json;
using ServerKiln.Windows.Core;

if (args.Contains("-G")) { Console.WriteLine("userknownhostsfile C:/synthetic/known_hosts"); return 0; }
if (args.Contains("-T")) return await FakeSsh.RunAsync(args);
return await TestSuite.RunAsync();

internal static class Check
{
    public static void True(bool condition, string message = "Assertion failed") { if (!condition) throw new Exception(message); }
    public static void Equal<T>(T expected, T actual) => True(EqualityComparer<T>.Default.Equals(expected, actual), $"Expected {expected}, got {actual}");
    public static void Near(double expected, double? actual) => True(actual is { } n && Math.Abs(n - expected) < 0.0001, $"Expected {expected}, got {actual}");
    public static void Throws<T>(Action action) where T : Exception
    { try { action(); } catch (T) { return; } throw new Exception("Expected " + typeof(T).Name); }
    public static async Task ThrowsAsync<T>(Func<Task> action) where T : Exception
    { try { await action(); } catch (T) { return; } throw new Exception("Expected " + typeof(T).Name); }
}

internal sealed class Scratch : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ServerKiln-tests-" + Guid.NewGuid().ToString("N"));
    public Scratch() => Directory.CreateDirectory(Path);
    public string File(string name) => System.IO.Path.Combine(Path, name);
    public void Dispose() => Directory.Delete(Path, recursive: true);
}

internal static class TestSuite
{
    private static ServerConfig Server(string target = "fixture-stream") => new() { Name = "Fixture", Target = target };
    private static ServerSnapshot Snapshot(double utilization = 100) => new(new SystemStat { CpuUsage = 0.5, MemTotalKB = 100, MemAvailableKB = 50 },
        true, [new(0, "a", "x", utilization, 50, 100), new(1, "b", "x", 0, 0, 100)], null, [], DateTimeOffset.UtcNow, []);
    public static async Task<int> RunAsync()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("shared Swift/Windows snapshot fixtures", SharedFixtures),
            ("CPU, RAM, disk and network units", Units),
            ("workload filtering and container attribution", Workloads),
            ("busy/idle debounce and recovery", Transitions),
            ("job grouping, grace period and persistence", Jobs),
            ("OpenSSH import: quotes, includes, CRLF and cycles", Import),
            ("SSH argument boundaries and strict host checking", Arguments),
            ("private-key override and interactive trust-store parity", IdentityArguments),
            ("custom known-hosts paths and discard-only fallback", TrustStoreCompatibility),
            ("live history cadence, GPU grouping and bounded retention", LiveHistory),
            ("host verification and private-key errors are distinguished", Diagnostics),
            ("repeated shortcut activation and absent-instance timeout", ShortcutActivation),
            ("native Windows OpenSSH accepts the generated configuration", NativeOpenSsh),
            ("SSH persistent process, split frames and stderr drain", PersistentSsh),
            ("SSH timeout and cancellation terminate the process", TimeoutAndCancellation),
            ("SSH errors and bounded output", SshErrors),
            ("SQLite aggregate/per-GPU buckets, throttle and prune", History),
            ("settings validation and atomic round trip", Settings),
            ("DPAPI round trip without plaintext storage", Secrets),
            ("Bark HTTPS validation, payload and service errors", Bark),
            ("monitor retries, muted servers and connection transitions", Monitor),
            ("monitor ignores stale results after removal", RemovedDuringCollection)
        };
        var failures = 0;
        foreach (var (name, run) in tests)
        {
            try { await run(); Console.WriteLine("PASS " + name); }
            catch (Exception ex) { failures++; Console.Error.WriteLine("FAIL " + name + "\n" + ex); }
        }
        Console.WriteLine($"{tests.Length - failures}/{tests.Length} checks passed.");
        return failures == 0 ? 0 : 1;
    }

    private static Task SharedFixtures()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(System.IO.Path.Combine(AppContext.BaseDirectory, "snapshots.json")));
        foreach (var fixture in document.RootElement.EnumerateArray())
        {
            var snapshot = SnapshotParser.Parse(fixture.GetProperty("output").GetString()!);
            Check.Equal(fixture.GetProperty("hostname").GetString(), snapshot.System.Hostname);
            Check.Equal(fixture.GetProperty("gpuCount").GetInt32(), snapshot.Gpus.Length);
            Check.Equal(fixture.GetProperty("busyCount").GetInt32(), new BusyPolicy().BusyCount(snapshot));
            Check.True(fixture.GetProperty("taskPids").EnumerateArray().Select(p => p.GetInt32()).SequenceEqual(snapshot.Tasks.Select(t => t.Pid)), fixture.GetProperty("name").GetString()!);
            Check.Equal(fixture.GetProperty("hasGpuError").GetBoolean(), snapshot.GpuError is not null);
            if (fixture.TryGetProperty("cpuUsage", out var cpu)) Check.Near(cpu.GetDouble(), snapshot.System.CpuUsage);
            if (fixture.TryGetProperty("taskMemory", out var memory)) Check.Near(memory.GetDouble(), snapshot.Tasks.First().MemoryMiB);
        }
        return Task.CompletedTask;
    }
    private static Task Units()
    {
        var before = new SystemStat { NetSampleUptime = 100, NetRxBytes = 2000, NetTxBytes = 500 };
        var after = (before with { NetSampleUptime = 102, NetRxBytes = 4096 + 2000, NetTxBytes = 2500 }).WithRates(before);
        Check.Near(2048, after.NetRxRate); Check.Near(1000, after.NetTxRate);
        Check.Near(2048, (after with { NetSampleUptime = 1, NetRxBytes = 0 }).WithRates(after).NetRxRate);
        Check.Near(0.5, new SystemStat { MemTotalKB = 100, MemAvailableKB = 50 }.MemFraction);
        var parsed = SnapshotParser.Parse("@@HOST\nx\n@@NET\n100 1000 2000\n102 3048 6096\n@@GPU\n0, a, NVIDIA A100, 0, 1, 81920, 30, [N/A], [N/A]\n@@END\n");
        Check.Near(1024, parsed.System.NetRxRate); Check.True(parsed.Gpus[0].PowerDraw is null);
        return Task.CompletedTask;
    }
    private static Task Workloads()
    {
        Check.True(SnapshotParser.IsWorkload("/opt/conda/bin/python -u train.py"));
        foreach (var command in new[] { "python -m gpustat", "python /opt/nvitop.py", "python -m ipykernel_launcher", "sshd: user@notty", "python -c from multiprocessing.resource_tracker import main" })
            Check.True(!SnapshotParser.IsWorkload(command), command);
        return Task.CompletedTask;
    }
    private static Task Transitions()
    {
        var id = Guid.NewGuid(); var tracker = new TransitionTracker(2);
        Check.True(tracker.Observe(id, ServerActivity.Busy) is null);
        Check.True(tracker.Observe(id, ServerActivity.Idle) is null);
        Check.True(tracker.Observe(id, ServerActivity.Busy) is null);
        Check.True(tracker.Observe(id, ServerActivity.Idle) is null);
        Check.Equal(new ActivityTransition(id, ServerActivity.Busy, ServerActivity.Idle), tracker.Observe(id, ServerActivity.Idle));
        tracker.Forget(id); Check.True(tracker.Observe(id, ServerActivity.Offline) is null);
        return Task.CompletedTask;
    }
    private static Task Jobs()
    {
        using var scratch = new Scratch();
        var time = DateTimeOffset.UtcNow;
        var tracker = new TaskTracker();
        tracker.Observe([new(1, "researcher", 120, "python train.py --local-rank=0", [0]), new(2, "researcher", 100, "python train.py --local-rank=1", [1])], time);
        Check.Equal(1, tracker.Running.Count); Check.True(tracker.Running.Values.Single().GpuIndices.SequenceEqual([0, 1]));
        using var store = new HistoryStore(scratch.File("history.sqlite"));
        store.SaveTasks(Guid.Empty, tracker); tracker = store.LoadTasks(Guid.Empty);
        Check.Equal(0, tracker.Observe([], time.AddSeconds(89)).Length);
        Check.Equal(1, tracker.Observe([], time.AddSeconds(90)).Length);
        Check.Equal(time, tracker.Finished.Single().EndedAt);
        return Task.CompletedTask;
    }
    private static Task Import()
    {
        using var scratch = new Scratch();
        Directory.CreateDirectory(scratch.File("ssh config"));
        var file = scratch.File("ssh config/config");
        File.WriteAllText(scratch.File("ssh config/extra.conf"), "Include \"" + file + "\"\nHost jump\n HostName jump.example.com\n");
        File.WriteAllText(file, "Include \"" + scratch.File("ssh config/*.conf") + "\"\r\nHost a b\r\n HostName \"gpu.example.com\" # note\r\n User researcher\r\n Port=2222\r\nHost github.com * !excluded\r\n User git\r\nHost = eq\r\n HostName=eq.example.com\r\n");
        var hosts = SshConfigParser.Load(file);
        Check.True(hosts.Select(h => h.Alias).SequenceEqual(["jump", "a", "b", "eq"]));
        Check.Equal(2222, hosts[1].Port); Check.Equal("researcher@gpu.example.com:2222", hosts[1].Summary);
        Check.Equal(0, SshConfigParser.Load(scratch.File("missing")).Length);
        return Task.CompletedTask;
    }
    private static Task Arguments()
    {
        using var scratch = new Scratch();
        var file = scratch.File("配置 with space"); File.WriteAllText(file, "Host fixture-stream");
        var info = SshSession.CreateStartInfo(Server() with { Port = 2222 }, Environment.ProcessPath, file);
        Check.Equal(file, info.ArgumentList[1]); Check.True(!info.UseShellExecute && info.CreateNoWindow);
        Check.True(info.ArgumentList.Contains("StrictHostKeyChecking=yes"));
        Check.Equal("fixture-stream", info.ArgumentList[^2]); Check.Equal(SshSession.CollectorCommand, info.ArgumentList[^1]);
        foreach (var target in new[] { "-oProxyCommand=bad", "host\nother", "host name", "host\"other" }) Check.Throws<ArgumentException>(() => (Server(target)).Validate());
        Check.Throws<ArgumentException>(() => (Server() with { Port = 0 }).Validate());
        return Task.CompletedTask;
    }
    private static async Task PersistentSsh()
    {
        await using var session = new SshSession(Server(), Environment.ProcessPath);
        var first = await session.FetchAsync(); var second = await session.FetchAsync();
        Check.Equal("fixture", first.System.Hostname); Check.Equal(first.System.Os, second.System.Os);
    }
    private static async Task NativeOpenSsh()
    {
        using var scratch = new Scratch();
        var config = scratch.File("配置 with spaces");
        File.WriteAllText(config, "Host fixture-native\n HostName gpu.example.com\n User researcher\n Port 2222\n UserKnownHostsFile /dev/null\n StrictHostKeyChecking no\n");
        var trust = scratch.File("指纹 with spaces/known_hosts");
        var info = SshSession.CreateStartInfo(Server("fixture-native"), configPath: config, knownHostsPath: trust);
        info.ArgumentList.Insert(0, "-G"); // Resolve options only: no network or private-key access.
        using var process = Process.Start(info)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
        Check.True(process.ExitCode == 0, await error);
        var resolved = await output;
        Check.True(resolved.Contains("hostname gpu.example.com", StringComparison.Ordinal));
        Check.True(resolved.Contains("port 2222", StringComparison.Ordinal));
        var store = resolved.Split('\n').Single(l => l.StartsWith("userknownhostsfile ", StringComparison.Ordinal));
        Check.True(store.Contains(trust.Replace('\\', '/'), StringComparison.Ordinal));
        Check.True(!store.Contains("/dev/null", StringComparison.Ordinal));
        Check.True(resolved.Contains("stricthostkeychecking true", StringComparison.Ordinal));
    }
    private static Task IdentityArguments()
    {
        using var scratch = new Scratch();
        var key = scratch.File("私钥 with spaces (1).pem"); File.WriteAllText(key, "synthetic fixture; never used for authentication");
        var trust = scratch.File("host keys/known_hosts");
        var server = Server() with { IdentityFile = key, Port = 2222 };
        var monitor = SshSession.CreateStartInfo(server, Environment.ProcessPath, knownHostsPath: trust);
        var interactive = SshSession.CreateInteractiveStartInfo(server, Environment.ProcessPath, knownHostsPath: trust);
        foreach (var info in new[] { monitor, interactive })
        {
            var keyIndex = info.ArgumentList.IndexOf("-i");
            Check.Equal(key, info.ArgumentList[keyIndex + 1]); Check.True(info.ArgumentList.Contains("IdentitiesOnly=yes"));
            Check.True(info.ArgumentList.Contains("2222"));
        }
        var monitorStore = monitor.ArgumentList.Single(a => a.StartsWith("UserKnownHostsFile=", StringComparison.Ordinal));
        Check.Equal(monitorStore, interactive.ArgumentList.Single(a => a.StartsWith("UserKnownHostsFile=", StringComparison.Ordinal)));
        Check.True(monitorStore.Contains(trust.Replace('\\', '/'), StringComparison.Ordinal));
        Check.True(interactive.UseShellExecute && !interactive.CreateNoWindow && !interactive.RedirectStandardInput);
        Check.True(interactive.ArgumentList.Contains("StrictHostKeyChecking=ask"));
        Check.True(interactive.ArgumentList.Contains("BatchMode=no"));
        Check.True(!interactive.ArgumentList.Contains(SshSession.CollectorCommand));
        Check.Equal(server.Target, interactive.ArgumentList[^1]);
        Check.Throws<FileNotFoundException>(() => SshSession.CreateStartInfo(server with { IdentityFile = scratch.File("missing.pem") }, Environment.ProcessPath));
        return Task.CompletedTask;
    }
    private static async Task TrustStoreCompatibility()
    {
        foreach (var paths in new[] { "/dev/null", "none", "NUL", "/dev/null NUL" })
            Check.True(SshTrustStore.NeedsPersistentFallback("userknownhostsfile " + paths));
        foreach (var paths in new[] { "C:/keys/known_hosts", "C:/with spaces/known_hosts C:/pins/host_ca", "~/.ssh/known_hosts ~/.ssh/known_hosts2", "/dev/null C:/pins/hosts" })
            Check.True(!SshTrustStore.NeedsPersistentFallback("userknownhostsfile " + paths), paths);
        Check.Throws<IOException>(() => SshTrustStore.NeedsPersistentFallback("invalid configuration output"));
        using var scratch = new Scratch();
        var config = scratch.File("config");
        var custom = scratch.File("CA pins with spaces").Replace('\\', '/');
        File.WriteAllText(config, "Host fixture-native\n HostName gpu.example.com\n UserKnownHostsFile \"" + custom + "\"\n");
        var native = await SshSession.CreatePreparedStartInfoAsync(Server("fixture-native"), configPath: config);
        Check.True(!native.ArgumentList.Any(a => a.StartsWith("UserKnownHostsFile=", StringComparison.Ordinal)));
        File.WriteAllText(config, "Host fixture-native\n HostName gpu.example.com\n UserKnownHostsFile /dev/null\n");
        var fallback = scratch.File("persistent/known_hosts");
        native = await SshSession.CreatePreparedStartInfoAsync(Server("fixture-native"), configPath: config, fallbackKnownHostsPath: fallback);
        Check.True(native.ArgumentList.Any(a => a.StartsWith("UserKnownHostsFile=", StringComparison.Ordinal) && a.Contains(fallback.Replace('\\', '/'), StringComparison.Ordinal)));
        var interactive = await SshSession.CreatePreparedStartInfoAsync(Server("fixture-native"), configPath: config, interactive: true, fallbackKnownHostsPath: fallback);
        Check.Equal(native.ArgumentList.Single(a => a.StartsWith("UserKnownHostsFile=", StringComparison.Ordinal)),
            interactive.ArgumentList.Single(a => a.StartsWith("UserKnownHostsFile=", StringComparison.Ordinal)));
    }
    private static Task LiveHistory()
    {
        var samples = new RecentSamples(); var id = Guid.NewGuid(); var now = DateTimeOffset.UtcNow;
        for (var n = 0; n <= 700; n++) samples.Record(id, Snapshot(), now.AddSeconds(n));
        var aggregate = samples.Query(id, now);
        Check.Equal(121, aggregate.Length);
        Check.Equal(now.AddSeconds(100), aggregate.First().Time);
        Check.Near(0.25, aggregate.First().MemoryFraction); Check.Near(50, aggregate.First().Utilization);
        var byGpu = samples.Query(id, now, true);
        Check.Equal(242, byGpu.Length); Check.True(byGpu.Select(p => p.Gpu).Distinct().Order().SequenceEqual(new int?[] { 0, 1 }));
        samples.Record(id, Snapshot(), now.AddSeconds(650));
        Check.Equal(1, samples.Query(id, now).Length);
        samples.Forget(id); Check.Equal(0, samples.Query(id, now).Length);
        samples.Record(id, Snapshot() with { HasNvidiaSmi = false, Gpus = [] }, now);
        Check.Equal(0, samples.Query(id, now, true).Length); Check.Near(0.5, samples.Query(id, now).Single().Cpu);
        Check.Equal(600.0, HistoryRange.TenMinutes.Duration().TotalSeconds);
        Check.True(Enum.GetValues<HistoryRange>().Select(r => r.BucketSeconds()).SequenceEqual([5, 300, 1800, 10800]));
        return Task.CompletedTask;
    }
    private static Task Diagnostics()
    {
        Check.Equal(SshFailureKind.UnverifiedHost, SshDiagnostics.Classify("No RSA host key is known for [gpu.example.com]:2222 and you have requested strict checking.\nHost key verification failed."));
        Check.Equal(SshFailureKind.ChangedHost, SshDiagnostics.Classify("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nHost key verification failed."));
        Check.Equal(SshFailureKind.Authentication, SshDiagnostics.Classify("Permission denied (publickey)."));
        Check.Equal(SshFailureKind.KeyPermissions, SshDiagnostics.Classify("WARNING: UNPROTECTED PRIVATE KEY FILE!\nLoad key: bad permissions"));
        Check.Equal(SshFailureKind.MissingKey, SshDiagnostics.Classify("Warning: Identity file fixture.pem not accessible: No such file or directory."));
        Check.Equal(SshFailureKind.Timeout, SshDiagnostics.Classify("SSH collection timed out."));
        return Task.CompletedTask;
    }
    private static async Task ShortcutActivation()
    {
        var pipe = "ServerKiln-tests-" + Guid.NewGuid().ToString("N");
        var revealed = 0;
        await using (var activation = new InstanceActivation(pipe, () => Interlocked.Increment(ref revealed)))
        {
            for (var n = 0; n < 4; n++) Check.True(await InstanceActivation.TryActivateAsync(pipe));
            Check.Equal(4, revealed);
        }
        Check.True(!await InstanceActivation.TryActivateAsync(pipe, timeoutMilliseconds: 100));
    }
    private static async Task TimeoutAndCancellation()
    {
        await using (var session = new SshSession(Server("fixture-hang"), Environment.ProcessPath, requestTimeout: TimeSpan.FromMilliseconds(300)))
            await Check.ThrowsAsync<TimeoutException>(() => session.FetchAsync());
        await using var cancelSession = new SshSession(Server("fixture-slow"), Environment.ProcessPath);
        using var token = new CancellationTokenSource(100);
        await Check.ThrowsAsync<OperationCanceledException>(() => cancelSession.FetchAsync(token.Token));
        Check.Equal("fixture", (await cancelSession.FetchAsync()).System.Hostname);
    }
    private static async Task SshErrors()
    {
        await using (var session = new SshSession(Server("fixture-fail"), Environment.ProcessPath))
            await Check.ThrowsAsync<IOException>(() => session.FetchAsync());
        await using (var session = new SshSession(Server("fixture-huge"), Environment.ProcessPath))
            await Check.ThrowsAsync<IOException>(() => session.FetchAsync());
        await using (var session = new SshSession(Server("fixture-invalid"), Environment.ProcessPath))
            await Check.ThrowsAsync<IOException>(() => session.FetchAsync());
    }
    private static Task History()
    {
        using var scratch = new Scratch(); var id = Guid.NewGuid();
        var time = DateTimeOffset.FromUnixTimeSeconds(1800000000);
        using (var store = new HistoryStore(scratch.File("历史.sqlite")))
        {
            store.Record(id, Snapshot(), time); store.Record(id, Snapshot(0), time.AddSeconds(10)); store.Record(id, Snapshot(60), time.AddSeconds(120));
            var aggregate = store.Query(id, time.AddSeconds(-1));
            Check.Equal(2, aggregate.Length); Check.Near(50, aggregate[0].Utilization); Check.Near(0.25, aggregate[0].MemoryFraction); Check.Near(0.5, aggregate[0].Cpu);
            var perGpu = store.Query(id, time.AddSeconds(-1), 3600, true);
            Check.Equal(2, perGpu.Length); Check.Near(80, perGpu[0].Utilization);
        }
        using (var store = new HistoryStore(scratch.File("历史.sqlite")))
        {
            Check.Equal(2, store.Query(id, time.AddSeconds(-1)).Length);
            store.Prune(time.AddDays(31), 30); Check.Equal(0, store.Query(id, time.AddSeconds(-1)).Length);
            store.Record(id, Snapshot(), time.AddDays(32)); store.Delete(id); Check.Equal(0, store.Query(id, time).Length);
        }
        return Task.CompletedTask;
    }
    private static Task Settings()
    {
        using var scratch = new Scratch(); var store = new PreferencesStore(scratch.Path);
        Check.Equal(30, store.Load().BackgroundIntervalSeconds);
        var prefs = new AppPreferences { Servers = [Server() with { Name = "训练", IdentityFile = scratch.File("私钥 (1).pem") }], SshConfigPath = "C:\\ssh config\\配置", Language = "zh" };
        store.Save(prefs); var loaded = store.Load(); Check.Equal(prefs.Servers[0], loaded.Servers[0]); Check.Equal(prefs.SshConfigPath, loaded.SshConfigPath);
        Check.Throws<ArgumentException>(() => store.Save(prefs with { BackgroundIntervalSeconds = 0 }));
        Check.Equal(30, store.Load().BackgroundIntervalSeconds);
        var legacy = JsonSerializer.SerializeToNode(prefs, JsonDefaults.Options)!.AsObject();
        legacy["theme"] = "dark";
        File.WriteAllText(store.FilePath, legacy.ToJsonString());
        loaded = store.Load();
        Check.Equal(prefs.Servers[0], loaded.Servers[0]); Check.Equal(prefs.SshConfigPath, loaded.SshConfigPath);
        Check.Equal("zh", loaded.Language); Check.Equal(prefs.BackgroundIntervalSeconds, loaded.BackgroundIntervalSeconds);
        store.Save(loaded);
        using (var saved = JsonDocument.Parse(File.ReadAllText(store.FilePath)))
            Check.True(!saved.RootElement.TryGetProperty("theme", out _));
        File.WriteAllText(store.FilePath, "broken"); Check.Throws<JsonException>(() => store.Load());
        return Task.CompletedTask;
    }
    private static Task Secrets()
    {
        using var scratch = new Scratch(); var vault = new ServerKiln.Windows.SecretVault(scratch.Path);
        Check.Equal("", vault.Load()); vault.Save("synthetic-device-key"); Check.Equal("synthetic-device-key", vault.Load());
        Check.True(!System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(scratch.File("bark-key.dat"))).Contains("synthetic-device-key", StringComparison.Ordinal));
        vault.Save(""); Check.Equal("", vault.Load());
        return Task.CompletedTask;
    }
    private static async Task Bark()
    {
        foreach (var url in new[] { "http://example.com", "https://key@example.com", "https://example.com?key=secret", "https://example.com/#secret", "file:///x" })
            Check.Throws<ArgumentException>(() => BarkClient.ValidateServer(url));
        var handler = new FakeHttp(); using var http = new HttpClient(handler);
        await new BarkClient(http).SendAsync("https://push.example.com/bark", "synthetic-key", "Fixture", "Idle");
        Check.Equal("https://push.example.com/bark/push", handler.Uri!.ToString());
        using var document = JsonDocument.Parse(handler.Body!); Check.Equal("synthetic-key", document.RootElement.GetProperty("device_key").GetString());
        handler.Status = HttpStatusCode.BadRequest;
        await Check.ThrowsAsync<IOException>(() => new BarkClient(http).SendAsync("https://push.example.com", "key", "Fixture", "Idle"));
        handler.Status = HttpStatusCode.OK; handler.Code = 400;
        await Check.ThrowsAsync<IOException>(() => new BarkClient(http).SendAsync("https://push.example.com", "key", "Fixture", "Idle"));
    }
    private static async Task Monitor()
    {
        using var scratch = new Scratch(); using var history = new HistoryStore(scratch.File("history.sqlite"));
        var server = Server(); var settings = new AppPreferences { Servers = [server], DebounceCount = 1, NotifyOnConnection = true };
        var fake = new FakeCollector();
        await using var monitor = new FleetMonitor(settings, history, (_, _) => fake);
        List<ActivityTransition> events = []; monitor.TransitionDetected += (_, transition) => events.Add(transition);
        await monitor.TickAsync(true, true); Check.Equal(0, events.Count);
        fake.Snapshot = Snapshot(0); await monitor.TickAsync(true, true); // memory is below the default threshold
        Check.Equal(ServerActivity.Idle, events.Single().To);
        settings = settings with { Servers = [server with { Muted = true }] }; monitor.UpdatePreferences(settings);
        fake.Snapshot = Snapshot(100); await monitor.TickAsync(true, true); Check.Equal(1, events.Count);
        settings = settings with { Servers = [server] }; monitor.UpdatePreferences(settings);
        fake.Fail = true;
        for (var n = 0; n < 3; n++) await monitor.TickAsync(true, true);
        Check.Equal(3, monitor.Readings.Single().Failures); Check.Equal(ServerActivity.Offline, monitor.Readings.Single().Activity);
        fake.Fail = false; await monitor.TickAsync(true, true); Check.Equal(0, monitor.Readings.Single().Failures);
        Check.True(events.Any(e => e.From == ServerActivity.Offline));
        Check.Equal(TimeSpan.FromSeconds(300), FleetMonitor.PollInterval(new ServerReading(server, Failures: 10), settings, true));
    }
    private static async Task RemovedDuringCollection()
    {
        using var scratch = new Scratch(); using var history = new HistoryStore(scratch.File("history.sqlite"));
        var server = Server(); var settings = new AppPreferences { Servers = [server] };
        var completion = new TaskCompletionSource<ServerSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var monitor = new FleetMonitor(settings, history, (_, _) => new WaitingCollector(completion.Task));
        var changes = 0; monitor.ReadingChanged += _ => changes++;
        var tick = monitor.TickAsync(true, true);
        monitor.UpdatePreferences(settings with { Servers = [] }); completion.SetResult(Snapshot()); await tick;
        Check.Equal(0, changes); Check.Equal(0, history.Query(server.Id, DateTimeOffset.UtcNow.AddDays(-1)).Length);
        await monitor.TickAsync(true, true); Check.Equal(0, monitor.Readings.Length);
    }

    private sealed class FakeCollector : ICollectorSession
    {
        public ServerSnapshot Snapshot { get; set; } = TestSuite.Snapshot();
        public bool Fail { get; set; }
        public Task<ServerSnapshot> FetchAsync(CancellationToken cancellationToken = default) => Fail ? Task.FromException<ServerSnapshot>(new IOException("Fixture offline")) : Task.FromResult(Snapshot);
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class WaitingCollector(Task<ServerSnapshot> result) : ICollectorSession
    {
        public Task<ServerSnapshot> FetchAsync(CancellationToken cancellationToken = default) => result;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    private sealed class FakeHttp : HttpMessageHandler
    {
        public string? Body; public Uri? Uri; public HttpStatusCode Status = HttpStatusCode.OK; public int Code = 200;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Uri = request.RequestUri; Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(Status) { Content = new StringContent("{\"code\":" + Code + "}") };
        }
    }
}

internal static class FakeSsh
{
    public static async Task<int> RunAsync(string[] args)
    {
        var mode = args[^2];
        if (mode == "fixture-fail") { Console.Error.WriteLine("Host key verification failed."); return 255; }
        while (await Console.In.ReadLineAsync() is not null)
        {
            if (mode == "fixture-hang") { await Task.Delay(Timeout.Infinite); continue; }
            if (mode == "fixture-slow") await Task.Delay(400);
            if (mode == "fixture-huge") { await Console.Out.WriteAsync(new string('x', 9 * 1024 * 1024)); await Console.Out.FlushAsync(); continue; }
            if (mode == "fixture-invalid") { Console.Write("bad\n@@END\n"); await Console.Out.FlushAsync(); continue; }
            await Console.Error.WriteAsync(new string('x', 10000)); await Console.Error.FlushAsync();
            Console.Write("@@HOST\r\nfixture\r\n@@OS\r\n" + Environment.ProcessId + "\r\n@@NOGPU\r\n@@E"); await Console.Out.FlushAsync();
            await Task.Delay(20); Console.Write("ND\r\n"); await Console.Out.FlushAsync();
        }
        return 0;
    }
}
