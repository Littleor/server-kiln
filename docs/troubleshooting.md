# Troubleshooting / 常见问题

## Cannot connect over SSH

Run `ssh -o BatchMode=yes <alias> true` in Terminal. Fix the SSH error there first:
confirm the host fingerprint, unlock encrypted keys in ssh-agent, check the
configured port and jump host, and ensure that the remote user can log in
without an interactive password prompt. Do not disable host-key verification
to make a warning disappear; verify a changed fingerprint with the server owner.

连接失败时，先在终端确认相同 SSH 别名能免交互登录。检查指纹、密钥、端口与跳板机。
不要通过关闭主机密钥验证来忽略身份变化。

## No GPU information

Run `nvidia-smi` as the same remote user. Check the NVIDIA driver and permissions.
ServerKiln currently supports NVIDIA GPU metrics on Linux. CPU-only servers
are supported; AMD GPU metrics are not. Process details may be limited by
`/proc` permissions or containers.

没有 GPU 信息时，先用相同账号运行 `nvidia-smi`。容器或 `/proc` 权限限制可能影响
任务详情。没有 NVIDIA GPU 的服务器仍可显示 CPU、内存等指标。

## No notifications or delayed changes

Enable notifications for ServerKiln in macOS System Settings, check Focus mode,
the in-app switches and per-server mute. Polling, debounce and sleep affect
when a state change is seen. Running with `swift run` does not provide system
notifications; use an app bundle. A retained allocation can keep a GPU marked
busy after useful computation ends; adjust the VRAM threshold if appropriate.

检查系统通知权限、专注模式、应用内开关和单机静音。采集间隔、防抖、休眠都会影响
提醒时间。任务保留显存时可能继续显示忙碌，按需调整显存阈值。

## iCloud is unavailable

Ad-hoc builds intentionally cannot access the official iCloud container. Use
the official signed release, sign in to iCloud and enable iCloud Keychain for
direct companion access. Check the account message in Mac Settings. Direct
access needs the iPhone to reach the endpoint independently; a Mac-only VPN or
SSH proxy does not automatically become available on the phone.

ad-hoc 自编译版无法访问官方 iCloud 容器。请使用官方签名版并检查同一 iCloud 账号及
钥匙串设置。手机直连仍需自己的网络可达性，Mac 上的 VPN／代理不会自动共享。

## macOS refuses to open the download

Download again from the official GitHub Release and compare its checksum.
Official artifacts are signed and notarized. Do not disable Gatekeeper globally.
Local source builds are signed ad hoc and are distinct from official downloads.
If a verified official download still fails, report the macOS version and exact
message without including private logs.

## History has gaps

History records observations, not continuous server telemetry. Sleep, disconnection,
quitting the app and retention expiry can leave gaps. No server-side history
daemon is installed to fill those gaps later.

历史记录来自实际采样。休眠、断连、退出应用和保留期到期会造成空缺，服务器没有
额外历史守护进程来补齐缺失区间。
