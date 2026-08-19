# VibeStick for Mac：M3-C 原生 ASR 配置阶段成果

> 状态：已与 M3-B 封存为本地联合检查点 `45e7dd2`；验收后钥匙串兼容修复已部署、通过连续 SiliconFlow 真人真机复核并封存为本地功能检查点 `13083f6`，未 push、tag 或发布
>
> 日期：2026-08-13
>
> M3-A 基线：`e2113ba04a5c4d0f75389ace470392e203ffa452`
>
> M3-B + M3-C 联合检查点：`45e7dd254c54fc207281997192e2242317d47e29`
>
> M3-B + M3-C 验收后功能检查点：`13083f68276a0f15104a9b51f4135b2b8cf11501`

## 1. 阶段结论

M3-C 已把 SiliconFlow、Groq、OpenAI-compatible 和本地命令 ASR 放进 Mac 原生“语音与发送”页面。非敏感配置进入私有应用数据，API Key 只进入 macOS 钥匙串；保存操作不会安装或重启后台服务。

测试由 Mac 本地生成固定的 16 kHz 单声道 WAV，提交给所选供应方后把转写与“语音测试成功”比对。它不访问 Mac 麦克风，不调用 M3-B 录音/发送接口，不访问 Paste Helper 或剪贴板，也不会向当前输入框注入内容或按 Return。M5StickS3 自带麦克风仍是正式语音链的唯一录音入口。

## 2. 已完成能力

### 2.1 原生供应方配置

- 四种供应方带有可编辑预设、模型、语言和端点。
- 云端只允许 HTTPS；本机 loopback 可用 HTTP 且可无 Key。
- 配置校验在写入前完成，旧 schema v1 配置仍可读取。
- 当前 M3-C Bridge 支持原生 JSON + Keychain，同时保留环境变量、旧 Groq 变量和 TOML 兼容路径。只有用户明确保存原生 `asr` 字段后它才覆盖旧 ASR 环境变量；没有该字段时旧部署行为不变。

### 2.2 钥匙串与失败回滚

- API Key 使用项目既有 KeychainStore，界面只显示“存在/不存在”。
- Key 不进入 `config-v1.json`、Bridge 状态、日志或测试结果。
- 空 Key 保存只做不返回 secret data 的存在性查询，不解密已有 Key，也不重复改写 ACL。
- 新建 ASR Key 时只额外信任当前 VibeStick App 与 Apple `/usr/bin/security`；更新已有 Key 只替换数据并保留既有访问控制和 `apple-tool:` 分区，不影响 Bridge 配对或其他钥匙串条目。
- 保存新 Key 失败时把非敏感供应方配置回滚到保存前状态；可单独移除 Key 而保留供应方设置。
- Bridge 使用系统 `security` 工具读取 Key，交互授权窗口为 60 秒；授权超时、取消或其他读取失败继续 fail closed，不回显错误输出或密钥内容。

### 2.3 不注入的独立测试

- 通过 macOS 系统语音合成本地生成 16 kHz 单声道固定 WAV，期望文字为“语音测试成功”。临时文件权限为 0600，测试结束后删除。
- 云端测试直接调用所选转写端点；本地测试命令收到显式 `test_only` 与 `inject_text=false`。
- 对转写做标点、宽度、大小写和变音符号无关的归一化比对；匹配成功或文字不一致都会同时显示期望文字与实际转写。
- 成功时只显示 240 字符以内的内存预览；失败时区分本地样本生成、鉴权、模型/地址、网络、超时、限流、5xx、响应格式与转写不匹配。
- 测试不链接 AVFoundation，Info.plist 不再声明 Mac 麦克风权限，源码也不保留 Mac 输入设备枚举或录音器。
- Keychain 状态摘要只做不返回 secret data 的存在性查询；启动和普通刷新不读取 Key 内容，实际保存替换或供应方请求才访问密钥。
- 构建门直接拒绝在 M3-C 独立测试实现中引用 Mac 录音 API、Paste、剪贴板、Return 或 M3-B 录音/确认接口。

## 3. 最终验证证据

- 159 项 Python `unittest` 全量通过；覆盖 ASR 配置、Keychain 接线、60 秒交互授权与超时 fail closed、显式原生配置优先级、兼容端点和 loopback 无 Key 请求。
- 33 项 hostless Swift 测试通过；除四种预设、URL 安全规则、旧配置解码和固定文字比对外，验证 ASR 只额外信任 Apple `security` 工具且已有条目更新不会替换 ACL。
- Release App、Bridge/HUD/Paste Helper、thin arm64、macOS 15.0 minimum 与 ad-hoc 签名检查通过。
- 构建 App 和 DMG App 均在正常 GUI 会话中响应，并确认没有改变现有 Bridge/HUD 进程。
- DMG 校验和、AppIcon、菜单栏图标、根目录结构与禁止文件扫描通过；本地产物为 `.build/macos.noindex/VibeStick-for-Mac-M3-C.dmg`，SHA-256 为 `daae42135b5d786b232574ec15f32dac8bd943c4b76bdf105514924802c2127f`。
- `git diff --check`、Info.plist、Shell 与 M3-C 源码隔离门通过。
- 使用者在构建 App 中亲自保存 SiliconFlow Key；只读复核确认 `config-v1.json` 为 0600、只含非敏感字段，Keychain 只报告条目存在。
- 在 AirPods 断开且不使用任何 Mac 输入设备的情况下，真人点击一次“提交固定音频测试”；SiliconFlow `FunAudioLLM/SenseVoiceSmall` 返回“语音测试成功。”，页面给出“测试通过：转写匹配”。
- 本次测试未弹出麦克风或钥匙串许可，也未启动或触碰 TextEdit；临时 WAV 数量回到 0，应用支持目录中未发现转写落盘，`recording.json` 与 `pending-send-v1.json` 时间戳均保持 `2026-08-13 03:09:52`。
- 早期验收曾尝试 AirPods、USB 名义输入和 CoreAudio 可用性探测；这些都不属于以 M5StickS3 自带麦克风为正式入口的产品需求，相关 Mac 麦克风适配已从最终实现中完整移除。
- 旧 ASR 条目首次迁移时，普通“允许”只能临时放行；使用者选择一次“始终允许”后，只读 ACL 复核确认 `/usr/bin/security` 与 `apple-tool:` 分区持久存在。随后新构建 App 空 Key 保存与连续 StickS3 SiliconFlow 识别均无弹窗。
- 使用隔离临时钥匙串按当前 `SecAccess` 创建全新 ASR 测试条目，Apple `security` 工具第一次实际读取即直接成功且无弹窗；测试值、临时钥匙串和探针随后全部删除，未接触登录钥匙串中的真实 Key。
- 最终真人 StickS3 会话使用自带麦克风、`source=siliconflow` 完成 `pending_send -> sent`，没有钥匙串弹窗，也没有重现错误 HUD。

## 4. 运行与安全边界

- 没有修改 M3-B 的发送会话、Paste 身份绑定、确认 Return 或固件按键状态机。
- 使用者已明确授权安装并重启包含钥匙串超时与 HUD 修复的日常运行态；已安装 recorder、transcriber 与 HUD 与当前候选源码逐字一致。
- 使用者已明确选择 SiliconFlow 并亲自把真实 Key 保存到 macOS 钥匙串；本轮没有读取、回显或写入文档，非敏感供应方配置已保存。
- 独立供应方测试只向明确显示的 `api.siliconflow.cn` 发送固定测试音频，不进入 M3-B 录音/发送状态或改变当前输入框；正式语音验收另由 StickS3 自带麦克风进入既有 M3-B 链路。
- M3-C 钥匙串修复没有要求刷机；本阶段发生的固件写入只用于使用者另行授权的 M3-B UI 光学校正。配对、Codex Focus、语音协议和配置 revision `1/1` 保持原状。
- 最终正常 GUI Doctor 为 `16 PASS / 0 WARN / 0 FAIL`；Bridge 协议 v2、语音 v2，StickS3 在线且未撤销。
- 联合检查点后的候选已封存为本地功能检查点 `13083f6`；没有 push、tag、Release、remote 或 Fork 关系变更。

## 5. 下一阶段

M3-C 供应方测试已收敛为“本地固定音频 -> SiliconFlow -> 转写比对 -> 页面反馈”，与 Mac 录音设备完全解耦；正式语音链的 Keychain 读取也已完成旧条目迁移和全新条目验证。验收后候选已完成本地封存，下一步进入 M4 的 DMG 首次安装、后台组件安装/修复和回退，不在 M3-C 继续扩张录音设备或发送状态机。

详细契约见 `design/m3c/M3C_ASR_CONFIGURATION_CONTRACT.md`。
