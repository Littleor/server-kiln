using System.ComponentModel;
using System.Globalization;

namespace ServerKiln.Windows;

public sealed class Localizer : INotifyPropertyChanged
{
    public static Localizer Current { get; } = new();
    public event PropertyChangedEventHandler? PropertyChanged;
    public bool Chinese { get; private set; } = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh";
    public void SetLanguage(string language)
    {
        Chinese = language == "zh" || language == "system" && CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh";
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
    }
    public string this[string key] => Labels.TryGetValue(key, out var value) ? Chinese ? value.Zh : value.En : key;
    public string Activity(ServerActivity? activity) => activity switch
    {
        ServerActivity.Busy => this["Busy"], ServerActivity.Idle => this["Idle"],
        ServerActivity.Offline => this["Offline"], ServerActivity.CpuOnly => this["CpuOnly"], _ => this["Connecting"]
    };
    private static readonly Dictionary<string, (string En, string Zh)> Labels = new()
    {
        ["Device"] = ("Device", "设备"), ["Utilization"] = ("Utilization", "利用率"),
        ["TrainingServers"] = ("Servers training", "服务器训练中"), ["BusyGpus"] = ("GPUs in use", "GPU 使用中"),
        ["FleetOverview"] = ("Overview", "概况"),
        ["OnlineServers"] = ("Servers online", "服务器在线"), ["System"] = ("System", "系统"), ["Load"] = ("Load", "负载"),
        ["NoRunningTasks"] = ("No running training jobs", "没有运行中的任务"), ["LastJob"] = ("Last job", "上一条任务"),
        ["JobHistory"] = ("Job history", "任务记录"), ["BackToServers"] = ("‹  Servers", "‹  返回服务器"),
        ["CpuRam"] = ("CPU / Memory", "CPU / 内存"), ["CopyPid"] = ("Copy PID", "复制 PID"),
        ["CopyCwd"] = ("Copy directory", "复制目录"), ["CopySsh"] = ("Copy SSH", "复制 SSH"),
        ["PollingFormat"] = ("Refresh every {0}s", "每 {0} 秒刷新"), ["Copied"] = ("Copied", "已复制"),
        ["Temperature"] = ("Temp.", "温度"), ["Power"] = ("Power", "功耗"), ["Details"] = ("Details", "详细信息"),
        ["FleetSummaryFormat"] = ("{0} monitored · {1} busy", "监控 {0} 台 · 忙碌 {1} 台"),
        ["Language"] = ("Switch language", "切换语言"),
        ["Minimize"] = ("Minimize", "最小化"), ["Maximize"] = ("Maximize", "最大化"),
        ["Restore"] = ("Restore", "还原窗口"), ["Close"] = ("Close to tray", "关闭到托盘"),
        ["Terminal"] = ("Terminal", "终端"), ["More"] = ("Server actions", "服务器操作"), ["Cores"] = ("cores", "核"),
        ["Notifications"] = ("Notifications & startup", "通知与启动"), ["SshSettings"] = ("SSH connection", "SSH 连接"),
        ["Fleet"] = ("Servers", "服务器"), ["Add"] = ("Add server", "添加服务器"), ["ImportShort"] = ("Import", "导入"),
        ["Import"] = ("Import SSH config", "导入 SSH 配置"), ["Refresh"] = ("Refresh", "立即刷新"),
        ["Settings"] = ("Settings", "设置"), ["Edit"] = ("Edit", "编辑"), ["Remove"] = ("Remove", "移除"),
        ["Save"] = ("Save", "保存"), ["Cancel"] = ("Cancel", "取消"), ["Name"] = ("Display name", "显示名称"),
        ["Target"] = ("SSH alias or user@host", "SSH 别名或 user@host"), ["Port"] = ("Port (optional)", "端口（可选）"),
        ["IdentityFile"] = ("Private key file (optional)", "私钥文件（可选）"),
        ["IdentityHelp"] = ("Leave blank to use IdentityFile / ssh-agent from your SSH config. Select a PEM or OpenSSH private key to override it for this server. The key stays in its original file.", "留空时沿用 SSH 配置中的 IdentityFile 或 ssh-agent。也可为此服务器选择 PEM / OpenSSH 私钥文件；应用仅保存路径。"),
        ["FirstConnect"] = ("First connection / verify fingerprint", "首次连接 / 确认指纹"),
        ["UnverifiedHost"] = ("Server fingerprint has not been verified", "尚未确认服务器指纹"),
        ["UnverifiedHostHint"] = ("Open the first connection and verify its SHA256 fingerprint with your server provider before accepting it. Host verification happens before private-key authentication. Different ports need separate confirmation.", "点击「首次连接」，先与云平台或管理员提供的 SHA256 指纹核对，再确认保存。服务器指纹校验先于私钥认证；不同端口需要分别确认。"),
        ["ChangedHost"] = ("Server fingerprint changed", "服务器指纹已变化"),
        ["ChangedHostHint"] = ("Verify whether the server was rebuilt or its key rotated with your provider. Update only the verified host entry afterwards.", "请先向云平台或管理员核实服务器是否重建或更换密钥，确认新指纹后再更新对应记录。"),
        ["MissingKey"] = ("Private key file not found", "找不到私钥文件"),
        ["MissingKeyHint"] = ("Edit the server to select its existing private key, or correct IdentityFile in your SSH config.", "请编辑服务器，选择现有私钥文件，或修正 SSH 配置中的 IdentityFile 路径。"),
        ["KeyPermissions"] = ("Private key file permissions need attention", "私钥文件权限需要调整"),
        ["KeyPermissionsHint"] = ("OpenSSH rejected the file permissions. Limit private-key access to your own Windows account, then retry.", "OpenSSH 拒绝了私钥文件的访问权限。请将私钥权限限制为当前 Windows 账户后重试。"),
        ["Authentication"] = ("SSH private-key authentication failed", "SSH 私钥认证失败"),
        ["AuthenticationHint"] = ("Check the SSH username and selected key. For an encrypted private key, unlock it in the matching Windows ssh-agent first; entering a passphrase once in a terminal does not unlock background monitoring.", "请检查 SSH 用户名与所选私钥。带口令的私钥需先加入并解锁对应的 Windows ssh-agent；仅在终端输入一次口令不会解锁后台监控。"),
        ["ConnectionTimeout"] = ("Connection timed out", "连接超时"),
        ["Enabled"] = ("Monitor this server", "启用监控"), ["Muted"] = ("Mute this server", "静音此服务器"),
        ["Busy"] = ("Busy", "忙碌"), ["Idle"] = ("Idle", "空闲"), ["Offline"] = ("Offline", "离线"),
        ["CpuOnly"] = ("CPU only", "纯 CPU"), ["Connecting"] = ("Connecting…", "连接中…"), ["Disabled"] = ("Paused", "已暂停"),
        ["Overview"] = ("Overview", "总览"), ["History"] = ("History", "历史"),
        ["Processes"] = ("Processes", "进程"), ["Jobs"] = ("Jobs", "任务"),
        ["NoServers"] = ("No servers", "暂无服务器"),
        ["Welcome"] = ("Import your SSH configuration or add a server manually.", "从 SSH 配置导入，或手动添加服务器。"),
        ["NoSelection"] = ("Select a server to see its resources.", "选择服务器，查看资源情况。"),
        ["NoData"] = ("Waiting for a successful sample.", "等待首次成功采集。"),
        ["NoHistory"] = ("No history yet.", "暂无历史数据。"),
        ["GpuUse"] = ("GPU usage", "GPU 利用率"), ["Vram"] = ("GPU memory", "显存"),
        ["Cpu"] = ("CPU", "CPU"), ["Ram"] = ("Memory", "内存"), ["Disk"] = ("Root disk", "根磁盘"),
        ["Network"] = ("Network", "网络"), ["Command"] = ("Command", "命令"), ["User"] = ("User", "用户"),
        ["Elapsed"] = ("Elapsed", "运行时间"), ["Started"] = ("Started", "开始时间"), ["Ended"] = ("Ended", "结束时间"),
        ["Running"] = ("Running", "运行中"), ["Gpu"] = ("GPU", "GPU"), ["Cwd"] = ("Working directory", "工作目录"),
        ["Copy"] = ("Copy command", "复制命令"), ["OpenSsh"] = ("Open SSH terminal", "打开 SSH 终端"),
        ["General"] = ("Monitoring", "监控设置"), ["BackgroundInterval"] = ("Background interval (seconds)", "后台刷新间隔（秒）"),
        ["ForegroundInterval"] = ("Window open interval (seconds)", "窗口打开时刷新间隔（秒）"),
        ["UtilThreshold"] = ("Busy utilization threshold (%)", "忙碌利用率阈值（%）"),
        ["MemoryThreshold"] = ("Busy GPU memory threshold (MiB)", "忙碌显存阈值（MiB）"),
        ["Debounce"] = ("Consecutive observations to confirm a change", "状态切换所需连续采样次数"),
        ["Retention"] = ("Keep history (days)", "历史保留天数"), ["NotifyIdle"] = ("Notify when idle", "空闲时通知"),
        ["NotifyBusy"] = ("Notify when busy", "忙碌时通知"), ["NotifyConnection"] = ("Notify on offline / recovery", "离线或恢复连接时通知"),
        ["Login"] = ("Start at sign-in", "登录 Windows 时启动"), ["SshConfig"] = ("SSH config file (blank = default)", "SSH 配置文件（留空使用默认路径）"),
        ["SshExecutable"] = ("ssh.exe (blank = Windows OpenSSH)", "ssh.exe 路径（留空使用系统 OpenSSH）"),
        ["Browse"] = ("Browse…", "浏览…"), ["Phone"] = ("iPhone notifications", "iPhone 通知"),
        ["PhoneHelp"] = ("Install Bark on your iPhone and copy its device key below. This sends status changes through your selected Bark server. Keep this PC awake and connected for notifications.", "在 iPhone 上安装 Bark，将设备密钥填入下方。状态变化将通过所选 Bark 服务推送；电脑需保持唤醒并连接网络。"),
        ["BarkEnabled"] = ("Send notifications to iPhone via Bark", "通过 Bark 向 iPhone 推送"),
        ["BarkServer"] = ("Bark HTTPS server", "Bark HTTPS 服务地址"), ["BarkKey"] = ("Device key (encrypted for this Windows account)", "设备密钥（使用当前 Windows 账户加密保存）"),
        ["BarkTest"] = ("Test iPhone notification", "测试 iPhone 通知"), ["TestSent"] = ("Test notification accepted by Bark.", "Bark 已接受测试通知。"),
        ["PhoneLimit"] = ("The original ServerKiln iPhone app, widgets and iCloud pairing require the official Apple integration. They are not connected by this Windows build.", "原版 ServerKiln iPhone App、小组件和 iCloud 配对依赖官方 Apple 集成，本 Windows 版本尚未接入。"),
        ["Saved"] = ("Settings saved.", "设置已保存。"), ["ImportEmpty"] = ("No new explicit hosts found in this config.", "配置中没有可导入的新主机。"),
        ["RemoveConfirm"] = ("Remove this server and its local history? Your SSH configuration and remote authorization are retained.", "移除此服务器及其本地历史？SSH 配置和远端授权会保留。"),
        ["Error"] = ("ServerKiln needs attention", "ServerKiln 需要处理"), ["Show"] = ("Open ServerKiln", "打开 ServerKiln"),
        ["Quit"] = ("Quit", "退出"), ["TrayHint"] = ("Monitoring continues in the tray", "关闭窗口后继续监控"),
        ["Demo"] = ("Demo data", "示例数据"), ["Local"] = ("Local monitoring", "本地监控"),
        ["RetryHint"] = ("Use First connection to check the connection interactively. Check the key under Edit; ProxyCommand programs must be available on Windows.", "可通过「首次连接」在终端检查连接，在「编辑」中检查私钥；ProxyCommand 使用的程序需能在 Windows 上运行。"),
        ["10m"] = ("10 minutes", "10 分钟"), ["24h"] = ("24 hours", "24 小时"), ["7d"] = ("7 days", "7 天"), ["30d"] = ("30 days", "30 天"),
        ["Overall"] = ("Overall", "整体"), ["PerGpu"] = ("Per GPU", "按卡"),
        ["LiveHistoryHint"] = ("Live samples · at most one point per 5 seconds · last 10 minutes · resets when the app exits", "近期实时采样 · 最短 5 秒一点 · 保留 10 分钟 · 退出应用后重置"),
        ["StoredHistoryHint"] = ("Local history · one sample per minute · gaps represent missing collection", "本地历史 · 每分钟采样一次 · 采集中断处留空"),
        ["LiveHistoryCaption"] = ("Live samples · last 10 minutes", "实时采样 · 最近 10 分钟"),
        ["StoredHistoryCaption"] = ("Local history · gaps indicate missing samples", "本地历史 · 采集中断处留空"),
        ["NoGpuHistory"] = ("No GPU samples in this range.", "此时间范围暂无 GPU 数据。"),
        ["ChartLegend"] = ("GPU use  ·  GPU memory  ·  CPU  ·  RAM", "GPU 利用率  ·  显存  ·  CPU  ·  内存"),
        ["NoGpu"] = ("No NVIDIA GPU detected", "未检测到 NVIDIA GPU"), ["Sampling"] = ("Collecting…", "正在采集…"),
        ["LastSample"] = ("Last sample", "最近采集"), ["Uptime"] = ("Uptime", "运行时长"),
        ["SelectImport"] = ("Select hosts to import", "选择要导入的服务器"), ["SelectAll"] = ("Select all", "全选"),
        ["ImportSelected"] = ("Import selected", "导入所选"), ["NoJobs"] = ("No training jobs recorded yet.", "暂无训练任务记录。")
    };
}
