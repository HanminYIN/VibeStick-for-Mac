# VibeStick for Mac M3-C：ASR 原生配置与独立测试契约

> 开发基线：本地提交 `e2113ba`（M3-A）之上的 M3-B 候选；现已与 M3-C 形成本地联合检查点
>
> 日期：2026-08-13

## 1. 范围

M3-C 只增加 Mac 侧语音识别供应方配置、密钥保存和独立测试，不修改 StickS3 固件、配对协议、Codex Focus、M3-B 发送会话、Paste Helper 或 Return 确认规则。

支持四种供应方：

- SiliconFlow：`https://api.siliconflow.cn/v1`，默认模型 `FunAudioLLM/SenseVoiceSmall`。
- Groq：`https://api.groq.com/openai/v1`，默认模型 `whisper-large-v3-turbo`。
- OpenAI-compatible：默认使用 OpenAI 地址和 `gpt-4o-mini-transcribe`，Base URL 与模型可编辑。
- 本地命令：音频不离开 Mac；命令从 stdin 接收 JSON，并从 `VIBE_STICK_TEST_AUDIO` 获得测试音频路径。

远程端点必须使用 HTTPS。只有 `localhost`、`127.0.0.1` 和 `::1` 可使用 HTTP，并可不配置 API Key。

## 2. 配置与密钥边界

- 供应方、Base URL、模型、语言和本地命令写入现有私有 `config-v1.json` 的可选 `asr` 字段；旧配置可继续解码。
- API Key 不进入 JSON、日志、状态文件或 UI 摘要，只进入 macOS 钥匙串。
- 钥匙串 service 为 `io.github.hanminyin.vibestick`，account 为 `asr-api-key`。
- 保存配置不会安装、替换或重启 Bridge/HUD/Paste；工作树版 Bridge 在下一次录音时动态读取配置与钥匙串。
- 只有在用户明确保存 `config-v1.json.asr` 后，原生配置才优先于旧 ASR 环境变量；该字段不存在时完全沿用旧环境变量与 TOML，避免改变稳定部署。测试文字与本地命令开发覆盖仍保持最高优先级。
- 配置写入失败时，刚刚替换的 Key 会恢复为原值；从钥匙串移除 Key 不删除非敏感配置。

## 3. 独立测试边界

测试链路为：

`macOS 固定语音合成 -> 0600 临时 16 kHz 单声道 WAV -> 供应方或本地命令 -> 转写比对 -> 当前页面内存反馈 -> 删除临时文件`

固定音频内容和期望文字均为“语音测试成功”。比对忽略标点、宽度、大小写和变音符号，页面同时显示期望文字与供应方返回的实际转写。

测试不得调用：

- Mac 麦克风、AVFoundation 录音器或 CoreAudio 输入设备枚举；
- Bridge 的 `/recording/start`、`/recording/stop` 或 `/recording/send/confirm`；
- Paste Helper 或系统剪贴板；
- 按键注入、Return 确认或 M3-B 待发送会话。

测试转写最多显示前 240 个字符，只保留在当前 App 会话内存，不写入配置或录音状态。页面明确显示音频目标；本地命令额外收到 `VIBE_STICK_ASR_TEST_ONLY=1` 和 `inject_text=false`。M5StickS3 自带麦克风的正式语音仍全部由 M3-B 处理。

## 4. 错误反馈

原生测试区分以下错误，而不把原始响应正文或密钥写入界面：

- 固定测试音频生成失败、为空或临时文件不可读；
- 缺少或无效 API Key（401/403）；
- 模型或地址不存在（404）；
- 请求超时、网络不可达、限流（429）或供应方 5xx；
- 成功响应缺少 `text`；
- 供应方返回文字，但与固定期望文字不匹配；
- 本地命令启动失败、非零退出或 stdout 无文字。

## 5. 验收门

- Swift 模型测试覆盖四种预设、HTTPS/loopback 校验和旧配置兼容。
- Python 测试覆盖原生配置、钥匙串读取、显式原生配置优先级、完整/拼接转写地址及无 Key loopback。
- 源码门确认独立测试文件不引用 Mac 录音 API、Paste、剪贴板、Return 或录音/确认 HTTP 接口。
- Release App/Helper、签名、正常 GUI smoke 与 DMG 验证不得改变已运行的 Bridge/HUD。
- [x] 使用者明确选择 SiliconFlow 并亲自保存 Key；AirPods 断开时点击一次固定音频测试，`FunAudioLLM/SenseVoiceSmall` 返回“语音测试成功。”，归一化比对通过。
- [x] 测试不申请 Mac 麦克风权限，不创建录音会话；输入框不变、临时 WAV 删除、转写不落盘，M3-B `recording.json` 与 `pending-send-v1.json` 均不变。
