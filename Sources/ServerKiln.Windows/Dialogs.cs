using System.Globalization;
using Microsoft.Win32;

namespace ServerKiln.Windows;

internal static class DialogLayout
{
    public static TextBlock Label(string key, double top = 13) => new()
    { Text = Localizer.Current[key], FontSize = 14, Margin = new Thickness(0, top, 0, 7), TextWrapping = TextWrapping.Wrap };
    public static TextBox Input(StackPanel panel, string key, string value)
    {
        panel.Children.Add(Label(key));
        var input = new TextBox { Text = value };
        System.Windows.Automation.AutomationProperties.SetName(input, Localizer.Current[key]);
        panel.Children.Add(input); return input;
    }
    public static CheckBox Check(StackPanel panel, string key, bool value)
    {
        var check = new CheckBox { Content = Localizer.Current[key], IsChecked = value };
        panel.Children.Add(check); return check;
    }
    public static (TextBox Left, TextBox Right) InputPair(StackPanel panel, string leftKey, string leftValue, string rightKey, string rightValue)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) }); row.ColumnDefinitions.Add(new ColumnDefinition());
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var leftLabel = Label(leftKey); var rightLabel = Label(rightKey);
        leftLabel.MinHeight = rightLabel.MinHeight = 32;
        Grid.SetColumn(rightLabel, 2); row.Children.Add(leftLabel); row.Children.Add(rightLabel);
        var first = new TextBox { Text = leftValue }; var second = new TextBox { Text = rightValue };
        System.Windows.Automation.AutomationProperties.SetName(first, Localizer.Current[leftKey]);
        System.Windows.Automation.AutomationProperties.SetName(second, Localizer.Current[rightKey]);
        Grid.SetRow(first, 1); Grid.SetRow(second, 1); Grid.SetColumn(second, 2);
        row.Children.Add(first); row.Children.Add(second); panel.Children.Add(row);
        return (first, second);
    }
    public static void Section(StackPanel panel, string key)
    {
        var label = Label(key, 26); label.FontSize = 15; label.FontWeight = FontWeights.Medium;
        panel.Children.Add(label);
    }
    public static void Help(StackPanel panel, string key)
    {
        var text = Label(key, 7); text.FontSize = 13; text.LineHeight = 21;
        text.SetResourceReference(TextBlock.ForegroundProperty, "MutedBrush"); panel.Children.Add(text);
    }
    public static (StackPanel Fields, StackPanel Buttons) Build(Window window)
    {
        window.SetResourceReference(FrameworkElement.StyleProperty, typeof(Window));
        window.Icon = System.Windows.Application.Current.MainWindow?.Icon;
        var root = new DockPanel { Margin = new Thickness(28, 16, 28, 24) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        DockPanel.SetDock(buttons, Dock.Bottom); root.Children.Add(buttons);
        var fields = new StackPanel();
        root.Children.Add(new ScrollViewer { Content = fields, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 10, 0) });
        window.Content = root;
        window.WindowStartupLocation = WindowStartupLocation.CenterOwner;
        return (fields, buttons);
    }
    public static Button Button(StackPanel panel, string key, RoutedEventHandler click, bool primary = false)
    {
        var button = new Button { Content = Localizer.Current[key], Margin = new Thickness(8, 0, 0, 0), MinWidth = 90 };
        if (primary) button.SetResourceReference(FrameworkElement.StyleProperty, "PrimaryButton");
        button.Click += click; panel.Children.Add(button); return button;
    }
}

public sealed class ServerEditor : Window
{
    private readonly ServerConfig original;
    public ServerConfig? Result { get; private set; }
    public ServerEditor(ServerConfig? config)
    {
        original = config ?? new();
        Title = Localizer.Current[config is null ? "Add" : "Edit"];
        Width = 580; Height = 655; MinWidth = 520; MinHeight = 550;
        var (fields, buttons) = DialogLayout.Build(this);
        var name = DialogLayout.Input(fields, "Name", original.Name);
        var target = DialogLayout.Input(fields, "Target", original.Target);
        var port = DialogLayout.Input(fields, "Port", original.Port?.ToString() ?? "");
        var identity = DialogLayout.Input(fields, "IdentityFile", original.IdentityFile);
        var browseKey = new Button { Content = Localizer.Current["Browse"], HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 5, 0, 0) };
        browseKey.Click += (_, _) =>
        {
            var picker = new OpenFileDialog { Title = Localizer.Current["IdentityFile"], CheckFileExists = true,
                Filter = "SSH private key|*.pem;*.key;id_*|All files|*.*" };
            if (picker.ShowDialog(this) == true) identity.Text = picker.FileName;
        };
        fields.Children.Add(browseKey);
        DialogLayout.Help(fields, "IdentityHelp");
        var enabled = DialogLayout.Check(fields, "Enabled", original.Enabled);
        var muted = DialogLayout.Check(fields, "Muted", original.Muted);
        DialogLayout.Button(buttons, "Cancel", (_, _) => DialogResult = false).IsCancel = true;
        DialogLayout.Button(buttons, "Save", (_, _) =>
        {
            try
            {
                int? parsedPort = string.IsNullOrWhiteSpace(port.Text) ? null : int.Parse(port.Text, CultureInfo.InvariantCulture);
                Result = original with { Name = name.Text.Trim(), Target = target.Text.Trim(), Port = parsedPort,
                    IdentityFile = identity.Text.Trim(),
                    Enabled = enabled.IsChecked == true, Muted = muted.IsChecked == true };
                if (!string.IsNullOrWhiteSpace(Result.IdentityFile))
                {
                    var path = Path.GetFullPath(Result.IdentityFile);
                    if (!File.Exists(path)) throw new FileNotFoundException(Localizer.Current["MissingKeyHint"], path);
                    Result = Result with { IdentityFile = path };
                }
                Result.Validate(); DialogResult = true;
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, Localizer.Current["Error"], MessageBoxButton.OK, MessageBoxImage.Warning); }
        }, primary: true).IsDefault = true;
        Loaded += (_, _) => name.Focus();
    }
}

public sealed class ImportWindow : Window
{
    public SshHostEntry[] Selected { get; private set; } = [];
    public ImportWindow(SshHostEntry[] entries)
    {
        Title = Localizer.Current["SelectImport"]; Width = 570; Height = 520;
        var (fields, buttons) = DialogLayout.Build(this);
        var all = new CheckBox { Content = Localizer.Current["SelectAll"], IsChecked = true };
        fields.Children.Add(all);
        List<(CheckBox Check, SshHostEntry Host)> choices = [];
        foreach (var entry in entries)
        {
            var check = new CheckBox { Content = entry.Alias + "  ·  " + entry.Summary, IsChecked = true,
                ToolTip = entry.SourceFile, Margin = new Thickness(0, 9, 0, 9) };
            fields.Children.Add(check); choices.Add((check, entry));
        }
        all.Checked += (_, _) => { foreach (var (check, _) in choices) check.IsChecked = true; };
        all.Unchecked += (_, _) => { foreach (var (check, _) in choices) check.IsChecked = false; };
        DialogLayout.Button(buttons, "Cancel", (_, _) => DialogResult = false).IsCancel = true;
        DialogLayout.Button(buttons, "ImportSelected", (_, _) =>
        { Selected = choices.Where(c => c.Check.IsChecked == true).Select(c => c.Host).ToArray(); DialogResult = Selected.Length > 0; }, primary: true);
    }
}

public sealed class SettingsWindow : Window
{
    private readonly TabControl tabs;

    internal void RenderPagesForSmokeTest()
    {
        foreach (TabItem tab in tabs.Items) { tabs.SelectedItem = tab; UpdateLayout(); }
    }

    public SettingsWindow()
    {
        var app = App.Instance;
        var prefs = app.Preferences;
        Title = "ServerKiln · " + Localizer.Current["Settings"];
        Width = 660; Height = 680; MinHeight = 500; MinWidth = 580;
        var (fields, buttons) = DialogLayout.Build(this);
        var root = (DockPanel)Content;
        root.Children.RemoveAt(root.Children.Count - 1);
        tabs = new TabControl(); root.Children.Add(tabs);
        StackPanel Page(string key)
        {
            var page = new StackPanel { Margin = new Thickness(0, 7, 12, 0) };
            tabs.Items.Add(new TabItem { Header = Localizer.Current[key], Content = new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled } });
            return page;
        }
        fields = Page("General");
        var (background, foreground) = DialogLayout.InputPair(fields, "BackgroundInterval", prefs.BackgroundIntervalSeconds.ToString(), "ForegroundInterval", prefs.ForegroundIntervalSeconds.ToString());
        var (utilization, memory) = DialogLayout.InputPair(fields, "UtilThreshold", prefs.Policy.UtilizationThreshold.ToString(CultureInfo.InvariantCulture), "MemoryThreshold", prefs.Policy.MemoryThresholdMiB.ToString(CultureInfo.InvariantCulture));
        var (debounce, retention) = DialogLayout.InputPair(fields, "Debounce", prefs.DebounceCount.ToString(), "Retention", prefs.HistoryRetentionDays.ToString());
        DialogLayout.Section(fields, "Notifications");
        var idle = DialogLayout.Check(fields, "NotifyIdle", prefs.NotifyOnIdle);
        var busy = DialogLayout.Check(fields, "NotifyBusy", prefs.NotifyOnBusy);
        var connection = DialogLayout.Check(fields, "NotifyConnection", prefs.NotifyOnConnection);
        var login = DialogLayout.Check(fields, "Login", !app.Demo && StartupService.Enabled);
        login.IsEnabled = !app.Demo;
        fields = Page("SshSettings");
        var sshConfig = DialogLayout.Input(fields, "SshConfig", prefs.SshConfigPath);
        var browseConfig = new Button { Content = Localizer.Current["Browse"], HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 5, 0, 0) };
        browseConfig.Click += (_, _) => { var picker = new OpenFileDialog { CheckFileExists = true }; if (picker.ShowDialog(this) == true) sshConfig.Text = picker.FileName; };
        fields.Children.Add(browseConfig);
        var sshExe = DialogLayout.Input(fields, "SshExecutable", prefs.SshExecutable);
        var browseExe = new Button { Content = Localizer.Current["Browse"], HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 5, 0, 0) };
        browseExe.Click += (_, _) => { var picker = new OpenFileDialog { CheckFileExists = true, Filter = "OpenSSH client|ssh.exe|Programs|*.exe" }; if (picker.ShowDialog(this) == true) sshExe.Text = picker.FileName; };
        fields.Children.Add(browseExe);
        fields = Page("Phone");
        DialogLayout.Help(fields, "PhoneHelp");
        var barkEnabled = DialogLayout.Check(fields, "BarkEnabled", prefs.BarkEnabled);
        var barkServer = DialogLayout.Input(fields, "BarkServer", prefs.BarkServer);
        fields.Children.Add(DialogLayout.Label("BarkKey"));
        var barkKey = new PasswordBox { Password = app.DeviceKey };
        System.Windows.Automation.AutomationProperties.SetName(barkKey, Localizer.Current["BarkKey"]);
        fields.Children.Add(barkKey);
        var test = new Button { Content = Localizer.Current["BarkTest"], HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 4), IsEnabled = !app.Demo };
        test.Click += async (_, _) =>
        {
            test.IsEnabled = false;
            try { await app.TestPushAsync(barkServer.Text.Trim(), barkKey.Password); MessageBox.Show(this, Localizer.Current["TestSent"], "ServerKiln"); }
            catch (Exception) { MessageBox.Show(this, "Bark test failed. Check the HTTPS server and device key. / 测试失败，请检查 HTTPS 服务地址与设备密钥。", "ServerKiln"); }
            finally { test.IsEnabled = true; }
        };
        fields.Children.Add(test);
        DialogLayout.Help(fields, "PhoneLimit");
        DialogLayout.Button(buttons, "Cancel", (_, _) => DialogResult = false).IsCancel = true;
        DialogLayout.Button(buttons, "Save", (_, _) =>
        {
            try
            {
                var next = app.Preferences with
                {
                    BackgroundIntervalSeconds = int.Parse(background.Text, CultureInfo.InvariantCulture),
                    ForegroundIntervalSeconds = int.Parse(foreground.Text, CultureInfo.InvariantCulture),
                    Policy = new BusyPolicy(double.Parse(utilization.Text, CultureInfo.InvariantCulture), double.Parse(memory.Text, CultureInfo.InvariantCulture)),
                    DebounceCount = int.Parse(debounce.Text, CultureInfo.InvariantCulture), HistoryRetentionDays = int.Parse(retention.Text, CultureInfo.InvariantCulture),
                    NotifyOnIdle = idle.IsChecked == true, NotifyOnBusy = busy.IsChecked == true, NotifyOnConnection = connection.IsChecked == true,
                    SshConfigPath = sshConfig.Text.Trim(), SshExecutable = sshExe.Text.Trim(),
                    BarkEnabled = barkEnabled.IsChecked == true, BarkServer = barkServer.Text.Trim()
                };
                next.Validate();
                if (next.BarkEnabled && string.IsNullOrWhiteSpace(barkKey.Password)) throw new ArgumentException(Localizer.Current["BarkKey"]);
                if (!string.IsNullOrWhiteSpace(next.SshExecutable)) SshSession.ResolveExecutable(next.SshExecutable);
                if (!string.IsNullOrWhiteSpace(next.SshConfigPath) && !File.Exists(next.SshConfigPath)) throw new FileNotFoundException(Localizer.Current["SshConfig"]);
                if (!app.Demo) StartupService.Enabled = login.IsChecked == true;
                app.SaveDeviceKey(barkKey.Password.Trim());
                app.SavePreferences(next);
                app.History.Prune(DateTimeOffset.UtcNow, next.HistoryRetentionDays);
                app.ViewModel.StatusMessage = Localizer.Current["Saved"];
                DialogResult = true;
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, Localizer.Current["Error"], MessageBoxButton.OK, MessageBoxImage.Warning); }
        }, primary: true).IsDefault = true;
    }
}
