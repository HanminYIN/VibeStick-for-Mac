# VibeStick for Mac：M3-B 语音与安全发送阶段成果

> 状态：成功与安全失败主流程及收尾源码验证完成；已与 M3-C 封存为本地联合检查点，未 push、tag 或发布
>
> 日期：2026-08-13
>
> M3-A 基线：`e2113ba04a5c4d0f75389ace470392e203ffa452`

## 1. 阶段结论

M3-B 把原有“长按录音、转写并粘贴”扩展为显式且可验证的发送状态机，同时保持旧配置语义：仅粘贴不会悄悄变成发送，自动发送只在明确启用时生效，蓝键确认只有在原目标输入框仍可安全确认时才按一次 Return。

成功发送与目标变化后的拒绝发送均已由真人在真实 Mac、真实 StickS3 和真实输入框中验收。失败路径不是“尽量发送”，而是焦点身份不一致时明确 fail closed，文字仍留在原输入框或剪贴板中，不会误发到新的目标。

## 2. 已完成能力

### 2.1 单次消费的待发送会话

- 每次录音绑定唯一 `session_id`，只有当前会话可确认。
- 待发送先原子消费再调用 Return，重复 HTTP、重复按键和 Bridge 重试不会产生第二次发送。
- 新录音、30 秒过期、Bridge/设备重启或目标变化都会让旧会话失效。
- `confirming` 中断后保守恢复为失效，不猜测 Return 是否执行，也不自动重试。

### 2.2 脱敏目标绑定与安全失败

- Paste Helper 仅返回前台 App bundle ID、PID 和辅助功能焦点摘要的 SHA-256 指纹。
- 不保存窗口标题、输入框内容或辅助功能原始描述。
- 确认时重新检查三个字段；任一缺失或变化都拒绝按 Return。
- 真人真机验收覆盖正常确认发送，以及切换目标后的 `target_inspection_failed` 安全失败。

### 2.3 StickS3 全屏状态与按键所有权

- 录音、识别、待发送、成功和失败使用统一 135 × 240 视觉系统。
- 覆盖层期间由语音状态机持有按键优先级，不触发页面切换、额度刷新或并发录音。
- 失败原因进一步区分“未听清”“识别失败”“发送失败”和过期“未发送”，并给出重新录音或切回原输入框的动作提示。
- 原有 Codex Focus 首页、提示音、配对同步与配置 ACK 不因覆盖层改动而重写。

### 2.4 Mac 语音状态页

- 显示当前 ASR 供应方、实际发送模式、Bridge voice interaction 协议和 Paste 状态。
- 只展示最近一次设备语音的脱敏状态、模式、版本和时间，不读取或显示 transcript。
- 将供应方 API Key 原生配置与测试拆到 M3-C，避免扩大本次已验收状态机的回归面。

### 2.5 本地隐私收尾

- `recording.json` 升级为 schema v2，只持久化状态、时间、来源、是否粘贴、交互版本和发送模式。
- transcript、message 和录音路径只保留在进程内存，不写入状态文件；旧状态读取时也不会重新暴露这些字段。
- 状态文件采用同目录原子替换并设置 0600；支持目录与录音目录设置 0700，生成音频设置 0600。
- 安装脚本对 `.env` 设置 0600，但本轮没有运行安装脚本或替换现有运行时。
- 日志只记录状态、来源、字符数和布尔结果，不记录转写文本或录音路径。

## 3. 完整验证证据

- 147 项 Python `unittest` 全量通过，新增状态持久化脱敏与私有权限回归。
- 27 项 hostless Swift 测试通过，覆盖 voice capability 解码、真实发送模式和脱敏最近状态。
- Shell 安装、诊断、卸载与构建脚本语法检查通过。
- ESP-IDF 5.5 完整构建通过；固件镜像 `0x15a270`，3 MiB app 分区剩余 `0x1a5d90`（55%）。
- Release 主 App、Bridge/HUD/Paste Helper、ad-hoc 签名、thin arm64 和 macOS 15.0 minimum 检查通过。
- 正常 GUI 会话中的构建 App 与 DMG App 启动 smoke 均通过，并确认没有改变现有 Bridge/HUD 进程。
- AppIcon、菜单栏图标、DMG 根目录、Applications 链接、磁盘映像校验和禁止文件扫描均通过。
- 产物统一为 `.build/macos.noindex/VibeStick-for-Mac-M3-B.dmg`，仅作为本地验证产物，未发布。
- `git diff --check` 与 Shell 语法检查通过。

## 4. 当前运行边界

- 这轮收尾没有运行 `scripts/install.sh`，没有替换或重启已安装 Bridge/HUD/Paste。
- 这轮收尾没有执行 `idf.py flash`、串口写入或设备重启。
- 已安装的受控 M3-B 主流程继续服务当前真实设备；本轮新增的隐私、Mac UI 与失败原因文案只存在于本地联合检查点和 `.build` 验证产物。
- 固件、配对关系、Codex Focus、语音输入、Bridge/HUD/Paste 继续作为稳定边界。
- 最终只读复核显示 Bridge 健康、transport protocol v2、voice interaction v2；StickS3 在线，固件 `0.2.0-dev`，配置 revision `1/1` 且未撤销。
- USB 串口仍可见；已安装 runtime 的 recorder 与本地封存版本不同，证明本轮隐私收尾没有被隐式复制进日常运行环境。

## 5. 尚未执行

- 已由使用者授权形成 M3-B + M3-C 本地联合检查点；未 push、tag 或创建 Release。
- 未修改 origin/upstream 或 GitHub Fork 关系。
- 未把当前候选安装到日常运行环境，也未再次刷写真机。
- 本文封口时 M3-C 尚未开始；当前后续进展见 `VIBESTICK_FOR_MAC_M3C_ACHIEVEMENTS.md`。

M3-B 本地检查点已经形成；是否部署本轮收尾以及是否分享 DMG，继续由使用者分别授权。
