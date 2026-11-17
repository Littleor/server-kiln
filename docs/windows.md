# Windows / Windows 版

The Windows client monitors the same remote **Linux** servers as the Mac app.
It is an independent .NET 10 / WPF tray application; the SwiftUI Mac application,
Apple entitlements, Sparkle feed and Mac release scripts retain their existing behavior.
Windows 11 x64 is the initial target. The app also targets Windows 10 22H2, but
that compatibility and Windows ARM64 need separate device testing.

Windows 客户端用于监控远端 **Linux** 服务器，首要支持 Windows 11 x64。
本机无需 WSL，也不需要在服务器安装常驻服务。Mac 客户端继续使用现有构建与同步流程。

## Install / 安装

Extract `ServerKiln-<version>-win-x64.zip` and run `ServerKiln.exe`. The published
package includes the .NET desktop runtime. Keep the entire extracted directory.
Optionally run its `install.ps1` to copy it into `%LOCALAPPDATA%\Programs\ServerKiln`
and create desktop and Start menu shortcuts. No administrator access is needed
by this installer. Pass `-NoDesktopShortcut` to omit the desktop shortcut.

解压 Windows ZIP 后运行 `ServerKiln.exe`，请保留同目录的依赖文件。
可运行压缩包内的 `install.ps1` 安装到当前用户目录并创建桌面、开始菜单快捷方式。
在设置中可选开启登录启动。关闭窗口后应用仍在托盘运行；右键托盘图标选择「退出」结束监控。
再次双击快捷方式会恢复已在托盘运行的窗口。首次安装新版时，如果旧版仍在运行，
请先从旧版托盘菜单退出一次，再使用新快捷方式打开。

Verify the archive against its `.sha256` file with `Get-FileHash -Algorithm SHA256`.
This initial build has no automatic updater or Authenticode signature. To update,
quit from the tray and replace the application files or run the newer installer.
Settings and history remain in the separate data directory below.
Opening a shortcut again reveals the existing tray instance. When installing over
an older build without this behavior, quit the older tray instance once first.

## SSH setup / SSH 配置

Enable the Windows **OpenSSH Client** optional feature if `ssh.exe` is absent.
The app uses `%WINDIR%\System32\OpenSSH\ssh.exe` by default. An alternative native
OpenSSH executable and configuration path can be selected in Settings.
Windows OpenSSH, Git's SSH and WSL SSH have different config/agent environments;
use the same native executable when preparing your keys and running the app.

Import or add the server, then use **First connection / verify fingerprint** in
the error panel. It opens native OpenSSH with the same config, port, identity and
trust store as monitoring. Compare the displayed SHA256 fingerprint with your
provider or administrator before accepting it. Different ports require separate
confirmation. Afterwards, return to the app and refresh. If the private key is
encrypted, unlock it using the matching Windows `ssh-agent`; entering its
passphrase in a standalone terminal does not unlock background monitoring.

Monitoring uses batch mode and strict host verification. Valid custom
`UserKnownHostsFile` paths are inherited unchanged, including paths with spaces,
multiple files and host CA entries. If the effective store consists entirely of
`/dev/null`, `NUL` or `none`, the app uses `%LOCALAPPDATA%\ServerKiln\known_hosts`
with the standard `%USERPROFILE%\.ssh\known_hosts` as a fallback. The first
connection asks for confirmation; background monitoring only accepts a known key.
If a fingerprint changes, verify the change with the provider before updating
that host's saved entry. The app never accepts or removes host keys automatically.

```powershell
ssh gpu-lab
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes gpu-lab 'uname -s; command -v nvidia-smi'
```

Example `%USERPROFILE%\.ssh\config`:

```sshconfig
Host gpu-lab
    HostName gpu.example.com
    User researcher
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Import that file or add an alias / `user@host` manually. Import previews explicit
hosts before adding them. The selected config file is also passed to OpenSSH
for every connection; changing it in Settings applies to all configured aliases.
OpenSSH itself resolves `IdentityFile`, `ProxyJump`, `ProxyCommand` and `Match`.
The importer lists explicit `Host` aliases and top-level `Include` files, omitting
wildcards, negations and common Git hosts. Conditional includes are not expanded
by the importer; their explicit aliases can be added manually.
Relative `Include` paths are resolved under the user's `.ssh` directory, as in
Windows OpenSSH, including when a custom `-F` configuration file is used.

**Edit → Private key file** can select a PEM / OpenSSH key for an individual
server. Leaving this blank retains `IdentityFile` and agent behavior from your
SSH configuration. A selected file is passed as a separate `-i` argument with
`IdentitiesOnly=yes`; its contents are never copied into the app's settings.

导入后若提示「尚未确认服务器指纹」，点击「首次连接 / 确认指纹」，与云平台或管理员
核对终端显示的 SHA256 指纹后确认，再回到应用刷新。不同端口分别确认。
有效的自定义指纹文件保持沿用；若配置完全丢弃指纹（例如 `/dev/null`），则回退到
`%LOCALAPPDATA%\ServerKiln\known_hosts` 保存确认结果。应用不会修改原 SSH 配置。
「编辑 → 私钥文件」可按服务器选择 key 文件；留空则继续沿用原来的 `IdentityFile`。
服务器指纹用于确认连接对象，私钥用于登录身份认证，两者是不同的检查。
跳板机和代理遵循所选 OpenSSH 配置；Mac 的 `nc -b en0`、Unix 路径或 WSL 内的
命令不能直接当作 Windows 代理程序使用，需要换成 Windows 可执行的对应命令。
路径支持中文和空格。基础监控不修改远端 `authorized_keys`。

## Features and data / 功能与数据

- Persistent SSH sessions; four hosts collected concurrently at most.
- Default polling: 30 seconds in the tray, 3 seconds with the window visible;
  transient failures retry sooner, sustained failures back off to five minutes.
- GPU utilization, VRAM, temperature and power; CPU, RAM, disk, network and processes.
- Default busy rule: utilization at least 10% **or** VRAM at least 1024 MiB.
- Debounced busy/idle and optional connection notifications, with per-host mute.
- 10-minute live history in memory, plus SQLite 24-hour, 7-day and 30-day charts.
- Aggregate / per-GPU history, utilization / VRAM selection and recent grouped jobs.
- English / Chinese switching and a fixed light interface.

The left sidebar keeps fleet totals and the server list visible while the right
pane shows the selected server. The summary follows the Mac app: training
servers / GPU servers, GPUs in use / total GPUs, and online / enabled servers.
CPU-only hosts count in online totals. Busy GPU counts use the policy in Settings;
paused servers and offline GPU capacity are excluded from these totals.

Select a server in the sidebar to see its GPU meters, running tasks and system
resources. Click a task to see its full command, working directory, PID,
sample-based start time and CPU / memory, with separate copy actions. New samples
preserve the selected server, active tab and expanded tasks. The process list
remains available in its own disclosure. **Job history** shows recorded start /
end times; **History** contains resource charts. The sidebar remains visible on
all three tabs so another server can be selected directly.

Terminal, Copy SSH and the **⋯** menu (Edit, First connection, Job history, Remove)
belong to the selected server in the detail header. The copied SSH command is
for PowerShell and preserves the configured SSH executable, config file, port,
identity and resolved host-verification options. Add / import controls remain
in the sidebar; Refresh, Settings and language controls stay in the fixed footer.

左侧固定显示整体概况与服务器列表，右侧显示当前所选服务器的详情。概况统计与
Mac 原版一致：训练中的 GPU 服务器、使用中的 GPU，以及在线服务器。纯 CPU 主机
计入在线数；忙碌统计遵循设置中的利用率 / 显存阈值，暂停的主机和离线的 GPU 容量
不计入对应汇总。

点击左侧服务器，右侧「总览」显示 GPU 横条、运行任务和系统资源；展开任务可查看
完整命令、目录、PID、开始时间、CPU / 内存，并分别复制命令、目录和 PID。自动刷新
保留服务器选择、当前标签页与任务展开状态，进程列表可单独展开。「任务记录」查看
运行记录及起止时间，「历史」查看资源曲线；查看这些页面时仍可直接从左侧切换服务器。

右侧标题栏提供所选服务器的终端、复制 SSH，以及 **⋯** 操作菜单。复制的 SSH 命令
适用于 PowerShell，沿用配置的 SSH 程序、配置文件、端口、私钥和解析后的指纹校验
选项。添加与导入入口位于左栏，底部固定显示刷新状态、立即刷新、设置和语言切换。

Settings are grouped into Monitoring, SSH connection and iPhone notifications.
Interface text uses HarmonyOS Sans SC when installed, with Windows system-font
fallbacks. Commands and paths use Cascadia Mono / Consolas. Body text is 14 px,
section headings are 15 px, and secondary labels are 13 px; resource values use
tabular digits. Fonts are read from the system rather than bundled in the ZIP.
This Windows client always uses the light palette. Older settings containing a
dark-theme preference still load their servers and connection settings; the
obsolete theme field is ignored.
设置按监控、SSH 连接和 iPhone 通知分组。Windows 版固定使用浅色；升级时忽略旧版
保存的深色选项，继续保留服务器、SSH 配置与私钥路径。
界面优先使用本机已安装的 HarmonyOS Sans SC，缺少时自动回退到 Windows 系统字体；
命令与路径使用 Cascadia Mono / Consolas。正文 14 号、分区标题 15 号、辅助说明 13 号，
资源数值使用等宽数字。应用沿用本机字体，压缩包不包含字体文件。

Settings are stored in `%LOCALAPPDATA%\ServerKiln\settings.json`, history and job
metadata in `history.sqlite`. Commands, usernames and working directories are
sensitive; review them before sharing this directory. Normal SSH private keys
stay in the user's existing SSH/agent setup. A Bark device key is stored separately
in `bark-key.dat`, encrypted with DPAPI for the current Windows account.

配置和历史与 Mac 分开保存。卸载程序不会自动删除该数据目录。
如需卸载，先关闭登录启动、从托盘退出，然后删除程序目录和开始菜单快捷方式。

## iPhone notifications / iPhone 通知

This build provides phone notifications, but no mobile resource dashboard or
browser view. Live metrics and history are currently viewed in the Windows app.
当前手机端支持接收通知，尚无手机实时监控面板或网页；指标和历史曲线在 Windows 端查看。

The original ServerKiln iPhone app and widgets are not open source, and their
CloudKit / iCloud Keychain integration requires the official Apple container and
signing permissions. This Windows client does **not** pair with that app or
provide its mobile terminal and widgets.

An optional independent notification route is available through **Bark**:

1. Install Bark on your iPhone and obtain its device key.
2. In Windows Settings, enter the HTTPS Bark server (default `https://api.day.app`)
   and the device key, then use **Test iPhone notification**.
3. Enable iPhone notifications and save. The same debounce, notification choices
   and per-server mute apply to desktop and phone events.

原版 iPhone App 的配对、终端和小组件暂未接入。当前可在 iPhone 安装 Bark，
将设备密钥填入 Windows 设置，测试后启用推送；也可填写自建的 HTTPS Bark 服务。
Windows 电脑需保持唤醒并连接网络。电脑关机、休眠或无法连接服务器期间无法采集与推送。

Pushes send the configured display name and a brief activity change, not process
commands, working directories or SSH keys. Your chosen Bark service processes
that notification data. Push is opt-in, uses HTTPS, and does not follow redirects.
Delivery still depends on the relay, APNs and iPhone notification settings.

## Build and verify / 构建与验证

Install the SDK specified by `global.json`, Python 3 and Windows OpenSSH. No NuGet packages are required
for the source build or the test executable. Publishing self-contained packages
may download Microsoft runtime packs.

```powershell
python scripts/export-windows-collector.py --check
python scripts/check-docs.py
python scripts/check-public-tree.py --history
python -m unittest discover -s Tests/RepositoryTests
scripts/build-windows.ps1
scripts/build-windows.ps1 -Package -Snapshots
```

Build output: `Sources\ServerKiln.Windows\bin\Release\net10.0-windows\ServerKiln.exe`.
Portable package: `dist\ServerKiln-<version>-win-x64.zip`.
Run `ServerKiln.exe --demo --language zh` for synthetic preview data and isolated
temporary storage. Demo mode performs no SSH monitoring or phone pushes.
`--snapshot <directory> --language en` exports synthetic UI images. The build's
`-Snapshots` switch generates both languages under `build/windows/screenshots/`.
See the [feature matrix](windows-compatibility.md) and [validation record](windows-validation.md).

The C# test executable exercises shared Swift/Windows parsing fixtures, real
child-process pipe framing/cancellation with a fake SSH executable, history,
task tracking, notification policy, encrypted storage and a fake Bark handler.
It never uses production SSH credentials or sends a real phone notification.
The build also runs `--smoke-test`, rendering the actual WPF templates, history
and dialogs in both languages using isolated synthetic data and the light palette.
Actual OpenSSH authentication, sleep/resume and iPhone delivery also require
manual acceptance testing against an explicitly selected host/device.

The collector is exported from `Sources/ServerKilnCore/RemoteScript.swift` by
`scripts/export-windows-collector.py`. Update it after changing the Swift
collector; both CI jobs check that it matches. Both language implementations
read `Tests/SharedFixtures/snapshots.json` to detect behavioral differences.
