# Getting started / 快速开始

## Install / 安装

Download the universal DMG from [Releases](https://github.com/Littleor/server-kiln/releases/latest),
drag ServerKiln to Applications, and launch it. The app lives in the menu bar,
so it does not show a persistent Dock icon. macOS 14 or newer is required.

下载通用 DMG，拖到「应用程序」并启动。应用常驻菜单栏，不显示常驻 Dock 图标。
同一安装包兼容 Apple Silicon 与 Intel，需要 macOS 14 或更新版本。

To verify a download, put the DMG, ZIP and `SHA256SUMS` from the same release in
one folder and run `shasum -a 256 -c SHA256SUMS`. If you downloaded only the DMG,
run `shasum -a 256 ServerKiln-<version>-universal.dmg` and compare that line.

## Connect a server / 连接服务器

First verify noninteractive SSH access in Terminal:

```bash
ssh gpu-lab
ssh -o BatchMode=yes gpu-lab 'uname -s; command -v nvidia-smi'
```

Review the host fingerprint during the first interactive connection. A typical
entry in `~/.ssh/config` looks like this (replace the example values):

```sshconfig
Host gpu-lab
    HostName gpu.example.com
    User researcher
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Open ServerKiln and import hosts from `~/.ssh/config`, or add a target manually
in Settings. For encrypted private keys, unlock the key in your SSH agent first.
The Mac uses the system OpenSSH client, so its jump-host and proxy configuration
applies. Wildcard-only host entries are not individual import candidates.

先在终端完成首次主机指纹确认和免交互登录，再从应用导入 SSH 配置。
带口令的密钥需先加入并解锁 ssh-agent。Mac 使用系统 SSH，因此可沿用跳板机配置。

## Read the panel / 查看状态

The menu bar shows a configurable summary. Open the panel for fleet status,
then expand a server to inspect cards and processes. Green-to-red load colors
show increasing GPU activity. CPU-only machines display CPU and memory instead.
The default busy policy considers utilization at least 10% or VRAM at least 1024 MiB;
adjust thresholds in Settings for workloads that reserve memory while idle.

Default polling is 30 seconds in the background and 3 seconds while the panel is
open. Notifications are debounced across consecutive observations, so they are
not a process scheduler or a guarantee that every short task will be observed.
The Mac must remain awake and connected for monitoring and relay updates.

默认后台 30 秒采集一次，打开面板时 3 秒一次。通知经过连续采样防抖，极短任务可能
不会被捕获。Mac 需要保持唤醒及网络连接。忙碌阈值和单服务器静音可在设置中调整。

## Optional iPhone connection / 可选 iPhone 配套

Use the official signed Mac build and the separately available iPhone app,
signed in to the same iCloud account. In the Mac's iPhone settings, choose
whether to relay status, enable notifications and deploy dedicated keys.
Relay uses the Mac's existing connection; direct iPhone access additionally
requires the phone to reach the server itself.

Deploying keys explicitly writes a collector script under
`~/.config/serverkiln/` and tagged entries to the remote `~/.ssh/authorized_keys`.
The monitor key is forced to run only that collector. Optional terminal access
uses a separate key and grants shell access as the configured SSH user.
Revoke access in Settings when it is no longer needed.

基础 Mac 监控无需部署。只有启用手机独立访问时，才会安装采集脚本并写入专属公钥。
终端权限使用单独密钥，拥有对应 SSH 用户的 shell 权限；仅在需要时开启。
自行编译的 ad-hoc 版本不具备官方 iCloud 容器权限。

## Update or remove / 更新与卸载

Quit the app before replacing it with a newer release. Settings and history
are retained. To uninstall, disable launch at login in Settings, revoke optional
companion keys if configured, quit the app, and remove it from Applications.
Removing the app does not erase local history or revoke remote keys automatically.

更新前退出应用，再替换安装。卸载前可先关闭登录启动，并撤销已配置的手机密钥。
删除应用本身不会自动清理历史记录或远端授权。
