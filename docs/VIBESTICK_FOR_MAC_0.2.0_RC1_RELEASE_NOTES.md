# VibeStick for Mac 0.2.0 RC 1

## 中文

这是首个已经发布到
[GitHub Pre-release](https://github.com/HanminYIN/VibeStick-for-Mac/releases/tag/v0.2.0-rc.1)
的 VibeStick for Mac 候选版，版本为 `0.2.0 (10)`。它只支持 Apple Silicon
和 macOS 15 或更高版本。

### 最重要的变化

后台 Bridge 已从 Python 迁移为原生 Swift。普通用户只需要下载并打开
`VibeStick-for-Mac-0.2.0-rc.1.dmg`；不需要安装 Python、Homebrew、Xcode
或仓库依赖。App 内的 Bridge、HUD 和 Paste 都是 thin arm64 原生组件。

原有功能继续保留：Codex/Claude 状态、Codex 额度、默认关闭的可选 Claude 额度、StickS3 配对与配置同步、
蓝键录音、云端或本地命令 ASR、HUD、Paste/确认发送、脱敏诊断，以及 M4
固件备份和恢复门禁。

### 安装与升级

1. 打开 DMG，把 `VibeStick for Mac` 拖入“应用程序”。
2. 由于 RC 仍是 ad-hoc 签名且未公证，首次打开时可能需要在 Finder 中按住
   Control 点按 App，再选择“打开”。不要从不可信来源移除隔离属性。
3. 首次打开只查看状态，不会自动安装 Helper、访问 USB、配对或写入固件。
4. 只有点击“安装/修复后台组件”并再次确认，才会切换 Bridge/HUD/Paste。
5. 需要文字注入时，在“系统设置 → 隐私与安全性 → 辅助功能”中允许
   `VibeStick Paste`。macOS 可能在 Helper 发生变化后再次询问。

从旧版升级时，安装事务会先保存原 Bridge、HUD、Paste、LaunchAgent 和旧
Python 运行时的回退副本，再切换原生组件。配置文件与 Keychain 凭据不属于
运行时载荷，不会被安装器覆盖。切换或启动验证失败时，事务会尝试恢复旧组件
和原服务状态。

### 隐私与安全边界

- Bridge/ASR 密钥使用固定 Keychain 项；受管配置文件不保存密钥正文。
- 诊断预览与本地导出是两次独立操作；不上传、无遥测。
- 默认诊断不含原始日志。选择日志时只读取四个固定、限长的 Bridge/HUD
  日志尾部并逐行脱敏。
- 固件工具下载、解包验证、USB 检查、完整备份、写入、独立读回和恢复各自
  需要确认；打开 App 或切换页面不会触发这些操作。
- App/DMG 内不包含本机配置、Keychain 内容、录音、日志、设备登记、私有
  备份、迁移事务或 Wi-Fi 凭据。

### RC 已知限制

- 尚未使用 Developer ID 签名或 Apple 公证。
- 因没有第二台全新 Mac 或外置干净启动系统，严格的全新环境首次安装和故障
  回退验收没有执行；它不是失败，但也不能记为通过。
- 当前 RC 只验证 Apple Silicon/macOS 15；不支持 Intel Mac。
- Codex/Claude 状态需要对应本地 App 或 CLI；云 ASR 需要用户自己的供应方
  凭据。离线本地命令 ASR 由用户自行配置。
- 固件恢复能力是高风险维护功能，不应为了试用 RC 而主动触发。

本地候选的测试数量、文件大小、SHA-256、签名、架构、清单和只读挂载证据见
`docs/VIBESTICK_FOR_MAC_0.2.0_RC1_LOCAL_ACCEPTANCE.md`。本地验收已经完成；
公开下载、SHA-256 与当前发布状态以
[GitHub Pre-release v0.2.0-rc.1](https://github.com/HanminYIN/VibeStick-for-Mac/releases/tag/v0.2.0-rc.1)
为准。

## English

This is the first VibeStick for Mac candidate published as a
[GitHub Pre-release](https://github.com/HanminYIN/VibeStick-for-Mac/releases/tag/v0.2.0-rc.1).
Its version is `0.2.0 (10)`, for Apple Silicon on macOS 15 or newer.

### Headline change

The background Bridge has moved from Python to native Swift. Normal users only
need `VibeStick-for-Mac-0.2.0-rc.1.dmg`; Python, Homebrew, Xcode, and repository
dependencies are not required. Bridge, HUD, and Paste are thin arm64 native
components.

Existing behavior remains: Codex/Claude state, Codex quota, opt-in Claude quota, StickS3 pairing and
configuration sync, push-to-talk recording, cloud or local-command ASR, HUD,
Paste/confirm delivery, redacted diagnostics, and the M4 firmware backup and
recovery gates.

### Install and upgrade

1. Open the DMG and drag `VibeStick for Mac` to Applications.
2. This RC is ad-hoc signed and not notarized. On first launch, Finder may
   require Control-click → Open. Do not remove quarantine for an artifact from
   an untrusted source.
3. First launch is inspection-only. It does not install helpers, access USB,
   pair a device, or write firmware.
4. Bridge/HUD/Paste change only after choosing Install/Repair Background
   Components and confirming again.
5. To inject text, allow `VibeStick Paste` in System Settings → Privacy &
   Security → Accessibility. macOS may ask again after a helper change.

An upgrade first retains the old Bridge, HUD, Paste, LaunchAgents, and Python
runtime in a rollback backup, then switches to the native components.
Configuration and Keychain credentials are outside the payload and are not
overwritten. A failed switch or startup verification attempts to restore both
the old files and the prior service state.

### Privacy and safety boundaries

- Bridge and ASR secrets use fixed Keychain items; managed configuration does
  not contain secret values.
- Diagnostic preview and local export remain two separate actions. There is no
  upload or telemetry.
- Diagnostics exclude raw logs by default. If selected, only four fixed,
  bounded Bridge/HUD tails are read and every line is redacted.
- Tool download, offline preparation, USB inspection, full backup, firmware
  write, independent readback, and recovery each retain a confirmation gate.
- The App/DMG excludes local configuration, Keychain data, recordings, logs,
  device registries, private backups, migration transactions, and Wi-Fi
  credentials.

### Known RC limitations

- No Developer ID signature or Apple notarization yet.
- A clean second Mac or external clean boot environment was unavailable, so
  strict clean-machine first-install and fault-rollback acceptance is
  unexecuted—not failed, and not passed.
- Intel Macs and macOS 14 or older are unsupported.
- Codex/Claude status requires the corresponding local App or CLI. Cloud ASR
  requires the user's provider credentials; a local command is user supplied.
- Firmware recovery is a high-risk maintenance feature and should not be
  triggered merely to try the RC.

Local test totals, byte size, SHA-256, signatures, architectures, manifests,
and read-only mount evidence are recorded in
`docs/VIBESTICK_FOR_MAC_0.2.0_RC1_LOCAL_ACCEPTANCE.md`. Local acceptance is
complete. Use
[GitHub Pre-release v0.2.0-rc.1](https://github.com/HanminYIN/VibeStick-for-Mac/releases/tag/v0.2.0-rc.1)
as the authority for the public download, SHA-256, and current publication
state.
