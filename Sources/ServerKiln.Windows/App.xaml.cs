using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using Forms = System.Windows.Forms;

namespace ServerKiln.Windows;

public partial class App : System.Windows.Application
{
    public static App Instance => (App)Current;
    public AppPreferences Preferences { get; private set; } = new();
    public FleetViewModel ViewModel { get; } = new();
    public HistoryStore History { get; private set; } = null!;
    public RecentSamples Recent => monitor.Recent;
    public bool Demo { get; private set; }
    public bool Exiting { get; private set; }
    private PreferencesStore store = null!;
    private SecretVault vault = null!;
    private FleetMonitor monitor = null!;
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim pushGate = new(1, 1);
    private readonly HttpClient http = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(12) };
    private Forms.NotifyIcon? tray;
    private Mutex? singleton;
    private InstanceActivation? activation;
    private string activationPipe = "";
    private bool ownsMutex;
    private Task? loop;
    private Task? pushes;
    private string storageDirectory = "";
    private string deviceKey = "";

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--probe"))
        {
            Dispatcher.BeginInvoke(new Action(async () =>
            {
                try { Shutdown(await Probe.RunAsync(e.Args)); }
                catch (Exception) { Console.Error.WriteLine("Probe setup failed; check local settings."); Shutdown(2); }
            }));
            return;
        }
        try
        {
            Demo = e.Args.Contains("--demo") || e.Args.Contains("--smoke-test") || e.Args.Contains("--snapshot");
            storageDirectory = Demo ? Path.Combine(Path.GetTempPath(), "ServerKiln-demo-" + Guid.NewGuid().ToString("N")) : PreferencesStore.DefaultDirectory;
            var mutexId = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(storageDirectory)))[..16];
            activationPipe = "ServerKiln.Windows." + mutexId + "." + System.Diagnostics.Process.GetCurrentProcess().SessionId;
            singleton = new Mutex(true, @"Local\ServerKiln.Windows." + mutexId, out ownsMutex);
            if (!ownsMutex)
            {
                if (!InstanceActivation.TryActivateAsync(activationPipe).GetAwaiter().GetResult())
                    MessageBox.Show("ServerKiln is already running in the system tray. Quit the older version there once, then open this shortcut again. / ServerKiln 已在系统托盘运行，请先从托盘退出旧版一次，再重新打开快捷方式。", "ServerKiln");
                Shutdown(); return;
            }
            store = new PreferencesStore(storageDirectory);
            vault = new SecretVault(storageDirectory);
            Preferences = Demo ? DemoData.Preferences : store.Load();
            if (e.Args.Contains("--language"))
            {
                var index = Array.IndexOf(e.Args, "--language");
                if (index + 1 < e.Args.Length) Preferences = Preferences with { Language = e.Args[index + 1] };
            }
            Localizer.Current.SetLanguage(Preferences.Language);
            deviceKey = Demo ? "" : vault.Load();
            History = new HistoryStore(Path.Combine(storageDirectory, "history.sqlite"));
            monitor = new FleetMonitor(Preferences, History);
            ViewModel.Sync(Preferences);
            ViewModel.StatusMessage = Localizer.Current[Demo ? "Demo" : "Local"];
            MainWindow = new MainWindow();
            SetupTray();
            activation = new InstanceActivation(activationPipe, () => Dispatcher.BeginInvoke(() =>
            {
                if (!Exiting) ShowWindow();
            }));
            if (!e.Args.Contains("--start-in-tray")) MainWindow.Show();
            if (Demo)
            {
                DemoData.Populate(this);
                if (e.Args.Contains("--smoke-test") || e.Args.Contains("--snapshot"))
                    Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, new Action(async () =>
                    {
                        try
                        {
                            var snapshotIndex = Array.IndexOf(e.Args, "--snapshot");
                            if (snapshotIndex >= 0)
                            {
                                if (snapshotIndex + 1 >= e.Args.Length) throw new ArgumentException("--snapshot needs an output directory.");
                                await ((MainWindow)MainWindow).CaptureSnapshotsAsync(e.Args[snapshotIndex + 1]);
                            }
                            else await ((MainWindow)MainWindow).RunSmokeChecksAsync();
                            await RequestExitAsync();
                        }
                        catch (Exception ex) { Console.Error.WriteLine(ex); Exiting = true; Shutdown(1); }
                    }));
            }
            else
            {
                monitor.ReadingChanged += reading => Dispatcher.BeginInvoke(() =>
                {
                    ViewModel.Apply(reading);
                    var time = reading.LastSuccess?.LocalDateTime.ToString("T") ?? "—";
                    ViewModel.StatusMessage = Localizer.Current["LastSample"] + ": " + time;
                    UpdateTray();
                    ((MainWindow)MainWindow).RefreshHistoryIfVisible();
                });
                monitor.TransitionDetected += (server, transition) => Dispatcher.BeginInvoke(() =>
                {
                    // Serialize phone sends so application shutdown can await all pending work.
                    pushes = SendTransitionAsync(server, transition);
                });
                loop = RunLoopAsync();
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message + "\n\n" + storageDirectory, "ServerKiln", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    private async Task RunLoopAsync()
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                await monitor.TickAsync(IsForeground, cancellationToken: lifetime.Token);
                await Task.Delay(1000, lifetime.Token);
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { break; }
            catch (Exception ex)
            {
                ViewModel.StatusMessage = Localizer.Current["Error"] + ": " + ex.Message;
                try { await Task.Delay(3000, lifetime.Token); } catch (OperationCanceledException) { break; }
            }
        }
    }
    private bool IsForeground => MainWindow is { IsVisible: true, WindowState: not WindowState.Minimized };

    public async Task RefreshAsync()
    {
        if (Demo) return;
        ViewModel.StatusMessage = Localizer.Current["Sampling"];
        await monitor.TickAsync(IsForeground, force: true, lifetime.Token);
    }

    public void SavePreferences(AppPreferences preferences)
    {
        preferences.Validate();
        if (!Demo) store.Save(preferences);
        Preferences = preferences;
        monitor.UpdatePreferences(preferences);
        Localizer.Current.SetLanguage(preferences.Language);
        ViewModel.Sync(preferences);
        ViewModel.RefreshLanguage();
        SetupTrayMenu();
        UpdateTray();
    }

    public string DeviceKey => deviceKey;
    public void SaveDeviceKey(string key) { if (!Demo) vault.Save(key); deviceKey = key; }

    public async Task TestPushAsync(string server, string key)
    {
        if (Demo) throw new InvalidOperationException("Push is disabled in demo mode. / 演示模式不发送推送。");
        await new BarkClient(http).SendAsync(server, key, "ServerKiln", "iPhone notifications are ready. / iPhone 通知已就绪。", lifetime.Token);
    }

    private async Task SendTransitionAsync(ServerConfig server, ActivityTransition transition)
    {
        try
        {
            await pushGate.WaitAsync(lifetime.Token);
            try
            {
                var current = Preferences.Servers.FirstOrDefault(s => s.Id == server.Id);
                if (current is not { Enabled: true, Muted: false } || !Preferences.ShouldNotify(transition)) return;
                var title = current.Name + " · " + Localizer.Current.Activity(transition.To);
                var body = transition.From == ServerActivity.Offline ? "Connection restored. / 连接已恢复。"
                    : "Server activity changed. / 服务器状态已变化。";
                tray?.ShowBalloonTip(5000, title, body, Forms.ToolTipIcon.Info);
                if (Preferences.BarkEnabled)
                    await new BarkClient(http).SendAsync(Preferences.BarkServer, deviceKey, title, body, lifetime.Token);
            }
            finally { pushGate.Release(); }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception)
        {
            // A network exception can contain a relay URL; keep credential-bearing details out of the UI/logs.
            ViewModel.StatusMessage = "iPhone push failed; check Bark settings. / iPhone 推送失败，请检查 Bark 设置。";
        }
    }

    private void SetupTray()
    {
        var resource = GetResourceStream(new Uri("pack://application:,,,/AppIcon.ico"));
        using var stream = resource!.Stream;
        using var icon = new System.Drawing.Icon(stream);
        tray = new Forms.NotifyIcon { Icon = (System.Drawing.Icon)icon.Clone(), Text = "ServerKiln", Visible = true };
        tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) ShowWindow(); };
        tray.BalloonTipClicked += (_, _) => ShowWindow();
        SetupTrayMenu();
    }

    private void SetupTrayMenu()
    {
        if (tray is null) return;
        var old = tray.ContextMenuStrip;
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(Localizer.Current["Show"], null, (_, _) => ShowWindow());
        menu.Items.Add(Localizer.Current["Refresh"], null, async (_, _) =>
        { try { await RefreshAsync(); } catch (Exception ex) { ShowError(ex); } });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Localizer.Current["Quit"], null, async (_, _) => await RequestExitAsync());
        tray.ContextMenuStrip = menu;
        old?.Dispose();
    }
    private void UpdateTray()
    {
        if (tray is not null) tray.Text = ("ServerKiln · " + ViewModel.FleetSummary)[..Math.Min(63, ("ServerKiln · " + ViewModel.FleetSummary).Length)];
    }
    private void ShowWindow()
    {
        MainWindow.Show(); MainWindow.WindowState = WindowState.Normal; MainWindow.Activate();
    }
    public void ShowError(Exception ex) => MessageBox.Show(MainWindow, ex.Message, Localizer.Current["Error"], MessageBoxButton.OK, MessageBoxImage.Warning);
    internal Task<bool> ReactivateForSmokeTestAsync() => InstanceActivation.TryActivateAsync(activationPipe);

    public async Task RequestExitAsync()
    {
        if (Exiting) return;
        Exiting = true;
        lifetime.Cancel();
        if (activation is not null) await activation.DisposeAsync();
        if (loop is not null) await loop;
        if (pushes is not null) await pushes;
        await monitor.DisposeAsync();
        History.Dispose();
        Shutdown();
    }
    protected override void OnExit(ExitEventArgs e)
    {
        lifetime.Cancel();
        if (tray is not null) { tray.Visible = false; tray.Icon?.Dispose(); tray.Dispose(); }
        http.Dispose();
        if (ownsMutex) singleton?.ReleaseMutex();
        singleton?.Dispose();
        base.OnExit(e);
    }
}
