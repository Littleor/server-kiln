# Mac GitHub Release 更新

Mac 使用 Sparkle 2.10.1 完成下载、Ed25519 验签、应用替换和重启。更新清单来自：

`https://github.com/Littleor/server-kiln/releases/latest/download/appcast.xml`

设置 → 通用 → 软件更新中可以手动检查，或关闭默认每天一次的自动检查。后台检查发现新版本时，若应用刚启动或用户空闲，Sparkle 直接弹出更新窗口；否则不在其他应用后面弹窗，改为在菜单栏面板底部显示更新图标并发送一条系统通知，点按任一处再打开 Sparkle 更新窗口（[gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/)）。`SUAllowsAutomaticUpdates=false` 和 `SUAutomaticallyUpdate=false` 禁止静默下载/安装；每次更新都需要用户在 Sparkle 弹窗选择安装。用户取消、下载失败或验签失败时，不会替换当前应用。首次需要手动安装包含更新器的版本，旧版没有更新入口。

## 发布流程

1. 每个 Mac 版本使用递增的 `CFBundleVersion`，即 BUILD_NUMBER 的构建号（project.yml 同步更新）；Sparkle 只比较构建号，不比较版本号。准备 VERSION 对应的 GitHub tag（如 v1.0.3）。`scripts/check-mac-update-version.sh` 会读取当前 Latest Release 的 appcast，构建号不高于已发布构建号或版本号更旧时，在归档前就终止。
2. 运行 `APPLE_TEAM_ID=<team> ASC_ENV=<凭据文件> scripts/release-mac.sh`。可通过 `MAC_RELEASE_NOTES=/绝对路径/notes.md` 提供更新说明。
3. 脚本完成 Developer ID 签名，分别公证 .app 和 DMG 并都附加票据，然后生成 `build/release/v<VERSION>/` 下的版本 DMG、签名 `appcast.xml` 和 `SHA256SUMS`。
4. 在同一个 GitHub Release 上传DMG、ZIP、appcast.xml 和 SHA256SUMS，核对 tag 与 appcast 下载 URL 一致，再发布为正式 Latest Release。脚本只准备本地产物，不自动创建或发布 GitHub Release。
5. 用已安装的上一版点击检查更新，核对版本、说明及安装确认。完成真实升级测试后再广泛发布。

当前 GitHub v1.0.2 尚无 appcast。手动检查兼容这种旧 Release：已安装该版本时显示最新；若发现更新但缺少清单，提供打开 GitHub 的入口。GitHub API 不可用（断网、匿名请求超过每小时 60 次限制）时，手动检查直接交给 Sparkle 读取 appcast。后台检查不会自行下载安装。后续 Release 必须同时带上 appcast 才能应用内更新。

## 签名密钥

Ed25519 私钥保存在本机登录钥匙串，Sparkle account 为 `cn.littleor.serverkiln.updates`；仓库只有 `project.yml` 中的 `SUPublicEDKey` 公钥。请妥善备份钥匙串，不要随意重新生成密钥或将私钥加入 Git。准备更新脚本会检查钥匙串公钥与应用公钥一致。

发布工具固定为 Sparkle 2.10.1，首次下载时核对 SHA-256；可通过 `SPARKLE_TOOLS_DIR` 指定已安装的工具目录。Sparkle 在下载包验签失败时拒绝安装。新的 macOS 最低版本和架构要求由 generate_appcast 从应用中提取。
