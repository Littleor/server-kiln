using System.ComponentModel;
using System.Diagnostics;
using Microsoft.Win32;
using System.Windows.Media.Imaging;

namespace ServerKiln.Windows;

public partial class MainWindow : Window
{
    private App AppState => App.Instance;
    private HistoryRange historyRange = HistoryRange.Day;
    private bool historyPerGpu;
    private GpuHistoryMetric historyMetric;
    private DateTimeOffset historyUpdated;
    private Guid? historyServer;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = AppState.ViewModel;
        Width = Math.Min(Width, SystemParameters.WorkArea.Width);
        Height = Math.Min(Height, SystemParameters.WorkArea.Height);
        AppState.ViewModel.SelectionChanged += () => { historyServer = null; DetailScroll.ScrollToTop(); RefreshHistoryIfVisible(force: true); };
        StateChanged += (_, _) => UpdateCaption();
        Localizer.Current.PropertyChanged += (_, _) => { UpdateCaption(); RefreshHistoryIfVisible(force: true); };
        UpdateCaption();
    }

    private void MinimizeWindow(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void MaximizeWindow(object sender, RoutedEventArgs e) => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    private void HideWindow(object sender, RoutedEventArgs e) => Close();
    private void UpdateCaption()
    {
        MaximizeButton.Content = WindowState == WindowState.Maximized ? "\uE923" : "\uE922";
        MaximizeButton.ToolTip = Localizer.Current[WindowState == WindowState.Maximized ? "Restore" : "Maximize"];
        System.Windows.Automation.AutomationProperties.SetName(MaximizeButton, (string)MaximizeButton.ToolTip);
    }
    private void OpenServerMenu(object sender, RoutedEventArgs e)
    {
        var button = (Button)sender;
        button.ContextMenu.DataContext = button.DataContext;
        button.ContextMenu.PlacementTarget = button;
        button.ContextMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        button.ContextMenu.IsOpen = true;
    }

    private void WindowClosing(object? sender, CancelEventArgs e)
    {
        if (!AppState.Exiting) { e.Cancel = true; Hide(); }
    }
    private void VisibilityChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (IsVisible && IsInitialized) RefreshHistoryIfVisible();
    }
    private void OpenSettings(object sender, RoutedEventArgs e) => new SettingsWindow { Owner = this }.ShowDialog();
    private void AddServer(object sender, RoutedEventArgs e) => Edit(null);
    private static ServerViewModel? ServerFor(object sender) => (sender as FrameworkElement)?.DataContext as ServerViewModel;
    private void EditServer(object sender, RoutedEventArgs e) { if (ServerFor(sender) is { } server) Edit(server.Config); }
    private void Edit(ServerConfig? config)
    {
        var editor = new ServerEditor(config) { Owner = this };
        if (editor.ShowDialog() != true || editor.Result is not { } result) return;
        try
        {
            var servers = AppState.Preferences.Servers.ToList();
            var index = servers.FindIndex(s => s.Id == result.Id);
            if (index < 0) servers.Add(result); else servers[index] = result;
            AppState.SavePreferences(AppState.Preferences with { Servers = servers.ToArray() });
            AppState.ViewModel.SelectedServer = AppState.ViewModel.Servers.First(s => s.Config.Id == result.Id);
            ShowOverview();
            ServerList.ScrollIntoView(AppState.ViewModel.SelectedServer);
        }
        catch (Exception ex) { AppState.ShowError(ex); }
    }

    private void RemoveServer(object sender, RoutedEventArgs e)
    {
        if (ServerFor(sender) is not { } selected) return;
        if (MessageBox.Show(this, Localizer.Current["RemoveConfirm"], selected.Name, MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        try
        {
            AppState.SavePreferences(AppState.Preferences with { Servers = AppState.Preferences.Servers.Where(s => s.Id != selected.Config.Id).ToArray() });
            AppState.History.Delete(selected.Config.Id);
            ShowOverview();
        }
        catch (Exception ex) { AppState.ShowError(ex); }
    }

    private void ImportServers(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = Localizer.Current["Import"], CheckFileExists = true,
            Filter = "SSH configuration|*|All files|*.*", FileName = string.IsNullOrWhiteSpace(AppState.Preferences.SshConfigPath)
                ? SshConfigParser.DefaultPath : AppState.Preferences.SshConfigPath };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            var entries = SshConfigParser.Load(dialog.FileName).Where(h => !AppState.Preferences.Servers.Any(s => s.Target == h.Alias)).ToArray();
            if (entries.Length == 0) { MessageBox.Show(this, Localizer.Current["ImportEmpty"], "ServerKiln"); return; }
            var picker = new ImportWindow(entries) { Owner = this };
            if (picker.ShowDialog() != true) return;
            var servers = AppState.Preferences.Servers.Concat(picker.Selected.Select(h => new ServerConfig { Name = h.Alias, Target = h.Alias })).ToArray();
            // Import and connect through the same config, including nondefault paths.
            AppState.SavePreferences(AppState.Preferences with { Servers = servers, SshConfigPath = dialog.FileName });
        }
        catch (Exception ex) { AppState.ShowError(ex); }
    }

    private async void Refresh(object sender, RoutedEventArgs e)
    {
        try { await AppState.RefreshAsync(); RefreshHistoryIfVisible(force: true); }
        catch (Exception ex) { AppState.ShowError(ex); }
    }
    private void ToggleLanguage(object sender, RoutedEventArgs e)
    {
        try { AppState.SavePreferences(AppState.Preferences with { Language = Localizer.Current.Chinese ? "en" : "zh" }); }
        catch (Exception ex) { AppState.ShowError(ex); }
    }
    private void CopyCommand(object sender, RoutedEventArgs e)
        => CopyText((sender as FrameworkElement)?.DataContext is ProcessViewModel process ? process.Command : null);
    private void CopyPid(object sender, RoutedEventArgs e)
        => CopyText((sender as FrameworkElement)?.DataContext is ProcessViewModel process ? process.Pid.ToString(System.Globalization.CultureInfo.InvariantCulture) : null);
    private void CopyCwd(object sender, RoutedEventArgs e)
        => CopyText((sender as FrameworkElement)?.DataContext is ProcessViewModel process ? process.Task.Cwd : null);
    private void CopyText(string? text)
    {
        try { if (!string.IsNullOrEmpty(text)) { Clipboard.SetText(text); AppState.ViewModel.StatusMessage = Localizer.Current["Copied"]; } }
        catch (Exception ex) { AppState.ShowError(ex); }
    }
    private async void CopySsh(object sender, RoutedEventArgs e)
    {
        if (ServerFor(sender)?.Config is not { } server) return;
        try
        {
            var info = AppState.Demo ? SshSession.CreateInteractiveStartInfo(server)
                : await SshSession.CreatePreparedStartInfoAsync(server, AppState.Preferences.SshExecutable,
                    AppState.Preferences.SshConfigPath, interactive: true);
            CopyText(PowerShellCommand(info));
        }
        catch (Exception ex) { AppState.ShowError(ex); }
    }
    private static string PowerShellCommand(ProcessStartInfo info)
    {
        static string Quote(string value) => "'" + value.Replace("'", "''") + "'";
        return "& " + Quote(info.FileName) + " " + string.Join(" ", info.ArgumentList.Select(Quote));
    }
    private async void OpenTerminal(object sender, RoutedEventArgs e)
    {
        if (AppState.Demo) return;
        if (ServerFor(sender)?.Config is not { } server) return;
        try
        {
            var info = await SshSession.CreatePreparedStartInfoAsync(server, AppState.Preferences.SshExecutable,
                AppState.Preferences.SshConfigPath, interactive: true);
            Process.Start(info)?.Dispose();
        }
        catch (Exception ex) { AppState.ShowError(ex); }
    }

    private void OpenJobs(object sender, RoutedEventArgs e) { if (ServerFor(sender) is { } server) ShowDetails(server, jobs: true); }
    private void ShowDetails(ServerViewModel server, bool jobs)
    {
        AppState.ViewModel.SelectedServer = server;
        DetailTabs.SelectedItem = jobs ? JobsTab : HistoryTab;
        RefreshHistoryIfVisible(force: true);
    }
    private void ShowOverview() => DetailTabs.SelectedItem = OverviewTab;

    private void ChangeHistoryRange(object sender, RoutedEventArgs e)
    { historyRange = Enum.Parse<HistoryRange>((string)((Button)sender).Tag); RefreshHistoryIfVisible(force: true); }
    private void ChangeHistoryMode(object sender, RoutedEventArgs e)
    { historyPerGpu = bool.Parse((string)((Button)sender).Tag); RefreshHistoryIfVisible(force: true); }
    private void ChangeHistoryMetric(object sender, RoutedEventArgs e)
    { historyMetric = Enum.Parse<GpuHistoryMetric>((string)((Button)sender).Tag); RefreshHistoryIfVisible(force: true); }
    private void TabChanged(object sender, SelectionChangedEventArgs e)
    { if (e.Source == DetailTabs && IsInitialized) RefreshHistoryIfVisible(force: true); }
    public void RefreshHistoryIfVisible(bool force = false)
    {
        if (Chart is null || DetailView.Visibility != Visibility.Visible || HistoryTab is null || !HistoryTab.IsSelected || AppState.ViewModel.SelectedServer is not { } selected) return;
        var now = DateTimeOffset.UtcNow;
        var refreshSeconds = historyRange == HistoryRange.TenMinutes ? 3 : 30;
        UpdateHistoryControls();
        if (!force && historyServer == selected.Config.Id && now - historyUpdated < TimeSpan.FromSeconds(refreshSeconds)) { Chart.InvalidateVisual(); return; }
        try
        {
            var since = now - historyRange.Duration();
            var points = historyRange == HistoryRange.TenMinutes
                ? AppState.Recent.Query(selected.Config.Id, since, historyPerGpu)
                : AppState.History.Query(selected.Config.Id, since, historyRange.BucketSeconds(), historyPerGpu);
            Chart.SetPoints(points, since, now, historyRange.BucketSeconds(), historyPerGpu, historyMetric);
            historyUpdated = now; historyServer = selected.Config.Id;
        }
        catch (Exception ex) { AppState.ViewModel.StatusMessage = ex.Message; }
    }

    private void UpdateHistoryControls()
    {
        void Select(Button button, bool selected)
        {
            button.SetResourceReference(Control.BackgroundProperty, selected ? "SurfaceBrush" : "TransparentBrush");
            button.SetResourceReference(Control.ForegroundProperty, selected ? "AccentBrush" : "MutedBrush");
            button.FontWeight = selected ? FontWeights.Medium : FontWeights.Normal;
        }
        foreach (var button in new[] { RangeLive, RangeDay, RangeWeek, RangeMonth })
            Select(button, (string)button.Tag == historyRange.ToString());
        Select(ModeOverall, !historyPerGpu); Select(ModePerGpu, historyPerGpu);
        Select(MetricUtilization, historyMetric == GpuHistoryMetric.Utilization); Select(MetricMemory, historyMetric == GpuHistoryMetric.Memory);
        GpuMetricPicker.Visibility = historyPerGpu ? Visibility.Visible : Visibility.Collapsed;
        HistoryHint.Text = Localizer.Current[historyRange == HistoryRange.TenMinutes ? "LiveHistoryCaption" : "StoredHistoryCaption"];
        HistoryHint.ToolTip = Localizer.Current[historyRange == HistoryRange.TenMinutes ? "LiveHistoryHint" : "StoredHistoryHint"];
    }

    public async Task CaptureSnapshotsAsync(string directory)
    {
        if (!AppState.Demo) throw new InvalidOperationException("Snapshots require isolated demo data.");
        Directory.CreateDirectory(directory);
        foreach (var legacy in new[] { "overview-dark.png", "history-per-gpu-dark.png" })
            File.Delete(Path.Combine(directory, legacy));
        Width = 1220; Height = 830; WindowState = WindowState.Normal;
        var first = AppState.ViewModel.Servers.First();
        AppState.ViewModel.SelectedServer = first;
        ShowOverview();
        DetailScroll.ScrollToTop();
        await SaveSnapshotAsync(Path.Combine(directory, "overview-light.png"));
        AppState.ViewModel.SelectedServer = AppState.ViewModel.Servers.Skip(1).FirstOrDefault() ?? first;
        await SaveSnapshotAsync(Path.Combine(directory, "idle-light.png"));
        AppState.ViewModel.SelectedServer = AppState.ViewModel.Servers.Last();
        await SaveSnapshotAsync(Path.Combine(directory, "server-detail-light.png"));
        AppState.ViewModel.SelectedServer = first;
        if (first.Tasks.FirstOrDefault() is { } firstTask) firstTask.IsExpanded = true;
        await SaveSnapshotAsync(Path.Combine(directory, "task-detail-light.png"));
        foreach (var task in first.Tasks) task.IsExpanded = false;
        ShowDetails(first, jobs: true);
        await SaveSnapshotAsync(Path.Combine(directory, "jobs-light.png"));
        ShowDetails(first, jobs: false);
        historyRange = HistoryRange.Day; historyPerGpu = true; historyMetric = GpuHistoryMetric.Utilization;
        RefreshHistoryIfVisible(force: true);
        await SaveSnapshotAsync(Path.Combine(directory, "history-per-gpu-light.png"));
        historyRange = HistoryRange.TenMinutes; historyMetric = GpuHistoryMetric.Memory;
        RefreshHistoryIfVisible(force: true);
        await SaveSnapshotAsync(Path.Combine(directory, "history-live-light.png"));
        Width = MinWidth; Height = MinHeight;
        ShowOverview();
        await SaveSnapshotAsync(Path.Combine(directory, "overview-compact-light.png"));
        var settings = new SettingsWindow { Owner = this };
        settings.Show();
        await SaveSnapshotAsync(Path.Combine(directory, "settings-light.png"), settings);
        settings.Close();
    }

    private async Task SaveSnapshotAsync(string path, Window? window = null)
    {
        window ??= this;
        window.UpdateLayout();
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        var root = (FrameworkElement)window.Content;
        var bounds = new Rect(0, 0, root.ActualWidth + root.Margin.Left + root.Margin.Right, root.ActualHeight + root.Margin.Top + root.Margin.Bottom);
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            context.DrawRectangle(window.Background, null, bounds);
        }
        var image = new RenderTargetBitmap((int)Math.Ceiling(bounds.Width), (int)Math.Ceiling(bounds.Height), 96, 96, PixelFormats.Pbgra32);
        image.Render(visual);
        image.Render(root);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
        using var file = File.Create(path); encoder.Save(file);
    }

    public async Task RunSmokeChecksAsync()
    {
        using var bindingTrace = new BindingTrace();
        VerifyFleetModels();
        // Render real templates, chart and dialogs with synthetic data. No external I/O.
        foreach (var language in new[] { "en", "zh" })
        {
            AppState.SavePreferences(AppState.Preferences with { Language = language });
            foreach (var server in AppState.ViewModel.Servers)
            {
                ServerList.SelectedItem = server;
                ShowOverview();
                foreach (var task in server.Tasks.Concat(server.Processes)) task.IsExpanded = true;
                await VerifyServerSelectionAsync(server);
                ShowDetails(server, jobs: false);
                foreach (var range in Enum.GetValues<HistoryRange>())
                    foreach (var perGpu in new[] { false, true })
                        foreach (var metric in Enum.GetValues<GpuHistoryMetric>())
                        {
                            historyRange = range; historyPerGpu = perGpu; historyMetric = metric;
                            RefreshHistoryIfVisible(force: true); UpdateLayout();
                        }
            }
            DetailTabs.SelectedItem = JobsTab; UpdateLayout();
            var settings = new SettingsWindow { Owner = this }; settings.Show(); settings.RenderPagesForSmokeTest(); settings.Close();
            var editor = new ServerEditor(null) { Owner = this }; editor.Show(); editor.UpdateLayout(); editor.Close();
            var importer = new ImportWindow([new SshHostEntry("fixture", "gpu.example.com", "researcher", 22, "synthetic")]) { Owner = this };
            importer.Show(); importer.UpdateLayout(); importer.Close();
            ShowOverview(); UpdateLayout();
            await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        }
        Width = MinWidth; Height = MinHeight;
        AppState.SavePreferences(AppState.Preferences with { Servers = [] });
        UpdateLayout();
        if (AppState.ViewModel.EmptyVisibility != Visibility.Visible) throw new InvalidOperationException("Empty fleet is not visible.");
        var waiting = new ServerConfig { Name = "Fixture", Target = "gpu.example.com" };
        AppState.SavePreferences(AppState.Preferences with { Servers = [waiting] });
        ShowOverview(); UpdateLayout();
        AppState.ViewModel.Apply(new ServerReading(waiting, Error: "Synthetic SSH failure", Failures: 3, Activity: ServerActivity.Offline));
        UpdateLayout();
        AppState.ViewModel.Apply(new ServerReading(waiting,
            Error: "No RSA host key is known for [gpu.example.com]:2222 and you have requested strict checking.\nHost key verification failed.",
            Failures: 3, Activity: ServerActivity.Offline));
        UpdateLayout();
        ShowDetails(AppState.ViewModel.SelectedServer!, jobs: false); UpdateLayout();
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        MaximizeWindow(this, new RoutedEventArgs());
        if (WindowState != WindowState.Maximized) throw new InvalidOperationException("Window did not maximize.");
        MaximizeWindow(this, new RoutedEventArgs());
        if (WindowState != WindowState.Normal) throw new InvalidOperationException("Window did not restore.");
        MinimizeWindow(this, new RoutedEventArgs());
        if (!await AppState.ReactivateForSmokeTestAsync()) throw new InvalidOperationException("Minimized window could not be activated.");
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        if (WindowState != WindowState.Normal) throw new InvalidOperationException("Minimized window did not restore.");
        HideWindow(this, new RoutedEventArgs());
        if (IsVisible) throw new InvalidOperationException("Close did not hide the window to the tray.");
        if (!await AppState.ReactivateForSmokeTestAsync()) throw new InvalidOperationException("Shortcut activation failed.");
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        if (!IsVisible || WindowState != WindowState.Normal) throw new InvalidOperationException("Shortcut did not restore the main window.");
        bindingTrace.Check();
    }

    private sealed class BindingTrace : TraceListener
    {
        private readonly List<string> errors = [];
        private readonly SourceLevels previousLevel = PresentationTraceSources.DataBindingSource.Switch.Level;
        public BindingTrace()
        {
            PresentationTraceSources.DataBindingSource.Switch.Level = SourceLevels.Error;
            PresentationTraceSources.DataBindingSource.Listeners.Add(this);
        }
        public override void Write(string? message) { if (!string.IsNullOrEmpty(message)) errors.Add(message); }
        public override void WriteLine(string? message) => Write(message);
        public void Check() { if (errors.Count > 0) throw new InvalidOperationException("WPF binding errors: " + string.Join("\n", errors)); }
        protected override void Dispose(bool disposing)
        {
            PresentationTraceSources.DataBindingSource.Listeners.Remove(this);
            PresentationTraceSources.DataBindingSource.Switch.Level = previousLevel;
            base.Dispose(disposing);
        }
    }

    private async Task VerifyServerSelectionAsync(ServerViewModel server)
    {
        UpdateLayout();
        if (!ReferenceEquals(AppState.ViewModel.SelectedServer, server) || !ReferenceEquals(DetailsHeader.DataContext, server)
            || !ReferenceEquals(OverviewBody.DataContext, server)) throw new InvalidOperationException("Sidebar selection did not update the detail pane.");
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        OpenServerMenu(ServerMenuButton, new RoutedEventArgs());
        if (!ServerMenuButton.ContextMenu.IsOpen) throw new InvalidOperationException("Server actions menu did not open.");
        foreach (var item in ServerMenuButton.ContextMenu.Items.OfType<MenuItem>())
            if (ServerFor(item) != server) throw new InvalidOperationException("Server action targets a previously selected host.");
        ServerMenuButton.ContextMenu.IsOpen = false;
        // The same popup is reused after switching hosts; let its native close finish.
        await Dispatcher.InvokeAsync(() => { }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        var selectedTab = DetailTabs.SelectedItem;
        AppState.ViewModel.Apply(server.Reading);
        UpdateLayout();
        if (!ReferenceEquals(ServerList.SelectedItem, server) || DetailTabs.SelectedItem != selectedTab
            || server.Tasks.Any(task => !task.IsExpanded)) throw new InvalidOperationException("A sample changed selection, tab or open task details.");
        ShowDetails(server, jobs: true); UpdateLayout();
        if (!ServerList.IsVisible || !JobsTab.IsSelected) throw new InvalidOperationException("Sidebar disappeared while viewing job history.");
        ShowOverview();
    }

    private void VerifyFleetModels()
    {
        static void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        var fleet = new FleetViewModel();
        fleet.Sync(AppState.Preferences);
        foreach (var server in AppState.ViewModel.Servers) fleet.Apply(server.Reading);
        Check(fleet.TrainingCount == 1 && fleet.TrainingTotal == "/ 2" && fleet.BusyGpuCount == 2 && fleet.GpuTotal == "/ 3"
            && fleet.OnlineCount == 3 && fleet.OnlineTotal == "/ 3", "Fleet totals differ from Mac GPU-server semantics.");
        var first = fleet.Servers.First();
        var tasks = first.Tasks;
        var task = tasks.First();
        var reading = first.Reading;
        var snapshot = reading.Snapshot!;
        task.IsExpanded = true;
        var started = task.Started;
        first.Apply(reading with { Snapshot = snapshot with { FetchedAt = snapshot.FetchedAt.AddSeconds(3),
            Tasks = snapshot.Tasks.Select(t => t with { ElapsedSeconds = t.ElapsedSeconds + 3 }).ToArray() } });
        Check(ReferenceEquals(tasks, first.Tasks) && ReferenceEquals(task, first.Tasks.First()) && task.IsExpanded && ReferenceEquals(fleet.SelectedServer, first),
            "A sample reset server selection or task expansion.");
        Check(task.Started == started && task.Command == snapshot.Tasks.First().Command, "Task start time or full command changed unexpectedly.");
        first.Apply(reading with { Snapshot = snapshot with { Tasks = snapshot.Tasks.Select(t => t with { Command = "python replacement.py" }).ToArray() } });
        Check(!task.IsExpanded, "PID reuse retained another task's expanded state.");
        first.Apply(reading);
        Check(first.LastJob?.Record.EndedAt is not null, "Last job must be a finished job.");
        fleet.Sync(AppState.Preferences with { Policy = new BusyPolicy(100, 1000000) });
        Check(fleet.BusyGpuCount == 0 && fleet.TrainingCount == 0, "Summary ignored the configured busy policy.");
        fleet.Apply(reading with { Error = "synthetic failure", Failures = 1 });
        Check(fleet.OnlineCount == 2 && fleet.TrainingTotal == "/ 1" && fleet.GpuTotal == "/ 1", "Offline stale samples counted as active GPU capacity.");
        fleet.Sync(AppState.Preferences with { Servers = AppState.Preferences.Servers.Select(s => s with { Enabled = false }).ToArray() });
        Check(fleet.OnlineTotal == "/ 0" && fleet.GpuTotal == "/ 0" && fleet.TrainingFraction == 0, "Paused servers counted in fleet totals.");
        var info = new ProcessStartInfo(@"C:\SSH tools\ssh.exe");
        info.ArgumentList.Add("-i"); info.ArgumentList.Add(@"C:\keys\researcher's $key.pem"); info.ArgumentList.Add("gpu.example.com");
        Check(PowerShellCommand(info) == "& 'C:\\SSH tools\\ssh.exe' '-i' 'C:\\keys\\researcher''s $key.pem' 'gpu.example.com'",
            "Copied SSH command did not preserve literal PowerShell arguments.");
    }
}
