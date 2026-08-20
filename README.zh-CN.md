# VibeStick for Mac

[English README](README.md)

[![GitHub Pre-release](https://img.shields.io/badge/GitHub_Pre--release-v0.2.0--rc.2-2f81f7?logo=github)](https://github.com/HanminYIN/VibeStick-for-Mac/releases/tag/v0.2.0-rc.2)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple)](https://github.com/HanminYIN/VibeStick-for-Mac/releases/tag/v0.2.0-rc.2)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-0A84FF)](https://github.com/HanminYIN/VibeStick-for-Mac/releases/tag/v0.2.0-rc.2)

> **项目状态：**这是基于
> [Gary Zhang 原始 VibeStick](https://github.com/GaryGaryyy/VibeStick)、面向 macOS
> 独立维护的衍生项目。原作者版权、MIT 许可和项目历史均完整保留。

![VibeStick for Mac 英文产品图，设备区域保留真实 StickS3 首页布局](assets/brand/vibestick-for-mac-hero.png)

[**下载 Apple Silicon 版 RC 2**](https://github.com/HanminYIN/VibeStick-for-Mac/releases/download/v0.2.0-rc.2/VibeStick-for-Mac-0.2.0-rc.2.dmg)
· [发布页面与完整性信息](https://github.com/HanminYIN/VibeStick-for-Mac/releases/tag/v0.2.0-rc.2)

VibeStick for Mac 把 M5Stack StickS3 变成一个桌面 AI agent 小终端：显示状态、可用额度窗口和提醒，并支持长按说话后自动转写粘贴到 Mac。

VibeStick 面向 M5Stack StickS3，不是 M5Stack 官方项目。Codex、Claude 等第三方 agent 名称只用于说明本地兼容工具和集成。

## 为什么做这个项目

- 不再用另一个桌面窗口遮挡工作区，在小屏幕上随时查看 Codex 和 Claude 状态。
- 长按一个实体按键，即可完成录音、转写、粘贴，并选择是否确认发送。
- 普通用户只安装原生 Swift App、Bridge、HUD 和 Paste，不需要 Python、
  Homebrew、Xcode 或 ESP-IDF。
- 配对、钥匙串、诊断、后台安装、USB、固件备份和写入都有清楚且独立的确认边界。

VibeStick for Mac 以 OpenAI Codex 作为主要工程协作者，覆盖产品设计、实现、
测试、发布工程和安全审计。产品本身也接入本地 Codex 工作流，用来显示会话状态与
额度窗口；Bridge API 不会暴露 Codex 凭据。

## 0.2.0 RC 2

RC 2 延续完全原生的 Swift App、Bridge、HUD、Paste 分发，并修复真实 Codex
会话历史较多、provider 观察时间超过设备请求超时时出现的误报离线。状态读取现在
直接使用最新内存快照，刷新在后台异步执行，并受到单飞、最小间隔和缓存约束。
版本为 `0.2.0 (11)`，支持 Apple Silicon 与 macOS 15 及以上；普通用户不需要
Python、Homebrew、Xcode 或 ESP-IDF。

该 RC 使用 ad-hoc 签名，尚未公证，目前已经作为
[GitHub Pre-release v0.2.0-rc.2](https://github.com/HanminYIN/VibeStick-for-Mac/releases/tag/v0.2.0-rc.2)
公开发布；发布页面包含安装步骤、完整性信息、验证证据和已知限制。此前的
[RC 1 本地验收记录](docs/VIBESTICK_FOR_MAC_0.2.0_RC1_LOCAL_ACCEPTANCE.md)
继续作为历史证据保留。

### 安装 RC

1. 从官方 GitHub Pre-release
   [下载 `VibeStick-for-Mac-0.2.0-rc.2.dmg`](https://github.com/HanminYIN/VibeStick-for-Mac/releases/download/v0.2.0-rc.2/VibeStick-for-Mac-0.2.0-rc.2.dmg)。
2. 打开 DMG，把 **VibeStick for Mac** 拖入“应用程序”。
3. RC 2 仍是 ad-hoc 签名且尚未公证，首次启动可能需要在 Finder 中按住 Control
   点按 App，再选择“打开”。
4. 先查看状态。只有选择对应操作并确认后，App 才会安装后台、访问 USB、配对或处理固件。

### 已验证内容

| 范围 | RC 2 证据 |
| --- | --- |
| 原生运行时 | Swift App、Bridge、HUD、Paste；arm64；macOS 15+ |
| 状态刷新 | 10/10 次真实状态读取约 2.3–5.9 ms；刷新有界；20 秒采样内 RSS 稳定 |
| 设备流程 | USB 配对、每设备独立信任、Bonjour 恢复、revision/ACK 配置同步 |
| 语音流程 | StickS3 录音、ASR、HUD、粘贴和确认状态 |
| 安全边界 | Keychain 密钥、脱敏诊断、事务式后台迁移、分别确认的固件操作 |
| 发布验证 | 21 个 suite 共 277 项 Swift 测试、194 项 Python 兼容性测试、隔离 Release 构建、组件签名检查、只读 DMG 验证和绿色 CI |

详细实现过程和真机证据放在里程碑文档中，避免首页变成开发流水账：

- [M1 成果与验收证据](docs/VIBESTICK_FOR_MAC_M1_ACHIEVEMENTS.md)
- [M2 成果与原作者版本对比](docs/VIBESTICK_FOR_MAC_M2_ACHIEVEMENTS.md)
- [M2 实现与验收边界](docs/VIBESTICK_FOR_MAC_M2_IMPLEMENTATION.md)
- [M3-A 成果与原作者版本对比](docs/VIBESTICK_FOR_MAC_M3A_ACHIEVEMENTS.md)
- [M3-B 语音与发送成果](docs/VIBESTICK_FOR_MAC_M3B_ACHIEVEMENTS.md)
- [M3-C 原生 ASR 配置成果](docs/VIBESTICK_FOR_MAC_M3C_ACHIEVEMENTS.md)
- [VibeStick for Mac Roadmap](docs/VIBESTICK_FOR_MAC_ROADMAP.md)
- [原生 macOS 构建说明](app/macos/README.md)

## 从源码构建：开始前的准备

普通 RC 用户不需要这一节。以下内容面向需要重建固件或运行仓库开发流程的贡献者。

- [ ] M5Stack StickS3、一根 USB-C 数据线和一台 Mac。
- [ ] 2.4 GHz Wi-Fi 名称和密码，以及语音识别服务的 API Key、模型名称和
  base URL。SiliconFlow 是可选服务之一：<https://cloud.siliconflow.cn/>。
- [ ] 如要显示 Claude 5H/7D 用量，需要 Claude Code CLI，并在 `.env` 中设置
  `VIBE_STICK_CLAUDE_USAGE=on`；该功能默认关闭。


## 从源码构建并安装

你可以手动执行，也可以交给 AI 编程 agent，例如 Claude Code 和 Codex。

> 说明：标 👤 的步骤是需要人亲自动手的物理操作，例如插线、长按/短按电源键、在系统设置里授权。AI agent 请按顺序执行 shell 步骤，执行到 👤 步骤时暂停，让用户完成后再继续。

1. 克隆仓库并创建本地配置文件：

```sh
git clone https://github.com/HanminYIN/VibeStick-for-Mac.git
cd VibeStick-for-Mac
./scripts/setup.sh
```

2. 填入人类提前准备好的配置：

```sh
open -e firmware/sticks3/include/vibe_stick_secrets.h
open -e .env
```

在 `vibe_stick_secrets.h` 里填写 Wi-Fi 名称、Wi-Fi 密码、Mac bridge host。只要文件里还保留示例占位值，`scripts/setup.sh` 会尝试把 `VIBE_STICK_BRIDGE_HOST` 自动写成检测到的 en0 局域网 IP。

在 `.env` 里填写 ASR key 和需要的 provider 设置。默认推荐 SiliconFlow：

```sh
VIBE_STICK_ASR_PROVIDER=openai-compatible
VIBE_STICK_ASR_BASE_URL=https://api.siliconflow.cn/v1
VIBE_STICK_ASR_API_KEY=your-siliconflow-key
VIBE_STICK_ASR_MODEL=FunAudioLLM/SenseVoiceSmall
```

3. 👤 用 USB-C 数据线把 StickS3 插到 Mac。

4. 👤 让 StickS3 进入下载模式：长按侧面电源键，直到蓝灯双闪、屏幕熄灭。这是 ESP32-S3 烧录必需步骤。

5. 如果本机还没有 ESP-IDF，先安装；然后把它加载到当前 shell。这是一次性工具链安装，下载较大（约 1GB），可能需要几分钟。每开一个新终端，在运行 `idf.py` 前都要先执行加载命令：

```sh
if [ ! -d "$HOME/esp/esp-idf" ]; then
  mkdir -p ~/esp && cd ~/esp
  git clone -b v5.5.1 --recursive https://github.com/espressif/esp-idf.git
  cd esp-idf && ./install.sh esp32s3
fi
. "$HOME/esp/esp-idf/export.sh"
```

也可以按 Espressif [官方指南](https://docs.espressif.com/projects/esp-idf/en/v5.5.1/esp32s3/get-started/index.html)安装。如果 `install.sh` 失败，请确认已安装 `git`、`python3`、`cmake`，或改按官方指南处理。如果 ESP-IDF 安装在其他位置，请调整路径。

6. 构建并烧录固件：

```sh
cd firmware/sticks3
idf.py -p <port> build flash
cd ../..
```

如果不知道端口，运行：

```sh
ls /dev/cu.*
```

等到终端出现 `Hash of data verified`。

7. 👤 短按电源键唤醒屏幕。蓝灯应熄灭、屏幕亮起，此时应看到 VibeStick 首页。联网前可能显示离线。

8. 安装本机 macOS bridge 和 HUD：

```sh
./scripts/install.sh
```

9. 👤 当 macOS 弹出 `VibeStick Paste` 想用辅助功能控制这台电脑时，点击“打开系统设置”并勾选允许。粘贴转写结果需要这个权限。安装后的后台项目会明确显示为 `VibeStick Bridge` 和 `VibeStick HUD`，不再显示成通用的 `sh` 或 Python 进程。

10. 检查安装状态：

```sh
./scripts/doctor.sh
```

尽量让必须项全部 PASS。然后看一眼 StickS3：如果本机 provider 数据可用，Codex / Claude 状态和 5H / 7D 应该出现真实值。

如果 Codex 已经能用、而 Claude 那栏显示 `--%`，这是正常的：Claude 用量默认关闭（更安全）；如需显示，请设置 `VIBE_STICK_CLAUDE_USAGE=on`，并确保 Claude Code 已通过 `claude` 和 `/login` 登录。

11. 👤 打开任意文本框，长按正面蓝键说话，松开后 VibeStick 应自动转写并粘贴。

开发调试时可以用 `./scripts/dev.sh` 替代 `./scripts/install.sh`，它会在当前终端里运行 bridge。

## 常见问题排查

### `command not found: idf.py`

ESP-IDF 没有加载到当前 shell，或者还没有安装。先 source ESP-IDF 的 `export.sh`，再运行 `idf.py`：

```sh
. $HOME/esp/esp-idf/export.sh
```

如果你的 ESP-IDF 在其他位置，请调整路径。每开一个新终端，在使用 `idf.py` 前都要运行一次。

### 烧录报 "Device not configured" 或连不上串口

重新插拔 USB-C 数据线。再次进入下载模式：长按侧面电源键，直到蓝灯双闪、屏幕熄灭。运行 `ls /dev/cu.*` 找端口，然后重试 `idf.py -p <port> build flash`。

### StickS3 连不上 Wi-Fi

请使用 2.4GHz Wi-Fi。StickS3 / ESP32-S3 不支持 5GHz Wi-Fi。

### 录音能转写但没有粘贴

给 `VibeStick Paste` 开辅助功能权限。macOS 路径：系统设置 -> 隐私与安全性 -> 辅助功能，然后允许 `VibeStick Paste`。正式安装和仓库开发模式都使用这个具名原生组件。重复运行安装脚本会保留未变化的辅助程序及其权限；只有辅助程序本身升级后，macOS 才可能要求重新允许一次。

### "No transcription adapter configured"

在 `.env` 里配置 ASR，尤其是 `VIBE_STICK_ASR_PROVIDER`、`VIBE_STICK_ASR_BASE_URL`、`VIBE_STICK_ASR_API_KEY`，然后重新安装：

```sh
./scripts/install.sh
```

### 找不到 `.env`

`.env` 是隐藏文件。用下面命令打开：

```sh
open -e .env
```

### 录音转写失败、SSL 报错或超时

通常是当前网络访问不到所选 ASR 服务。国内用户可以尝试 SiliconFlow：
<https://cloud.siliconflow.cn/>。也可以配置其他可访问的 OpenAI 兼容 ASR，
或配置网络代理。

## 配置说明

不要把真实 API key、本地 token、Wi-Fi 密码、本地日志、录音文件提交到 git。

`.env` 里的空值通常表示“使用内置默认值”。`scripts/dev.sh` 会读取仓库根目录的 `.env`。`scripts/install.sh` 会把 `.env` 复制到 `~/Library/Application Support/VibeStick/.env`，LaunchAgent 运行时读取安装后的文件。

### 核心设置

- `VIBE_STICK_PROJECT_ROOT`：本地 Codex session 观察路径。
- `VIBE_STICK_PROJECT_NAME`：可选显示名称。
- `VIBE_STICK_PROVIDER`：当前 provider，`auto`、`codex` 或 `claude`；默认 `auto`。
- `VIBE_STICK_BRIDGE_TOKEN`：bridge 绑定到非 loopback 地址时必需的共享 token，例如 `0.0.0.0`。
- `VIBE_STICK_MAX_RECORDING_AUDIO_BYTES`：`/recording/audio` 最大请求体大小，默认 `2000000`。
- `VIBE_STICK_RECORDING_USE_MAC_MIC`：设为 `0` 可关闭 Mac 麦克风兜底。
- `VIBE_STICK_AUTO_ENTER`：设为 `1` 会在粘贴后自动按 Return。

### ASR 方案 1：SiliconFlow（默认推荐）

```sh
VIBE_STICK_ASR_PROVIDER=openai-compatible
VIBE_STICK_ASR_BASE_URL=https://api.siliconflow.cn/v1
VIBE_STICK_ASR_API_KEY=your-siliconflow-key
VIBE_STICK_ASR_MODEL=FunAudioLLM/SenseVoiceSmall
VIBE_STICK_ASR_LANGUAGE=zh
VIBE_STICK_ASR_TIMEOUT_SECONDS=15
VIBE_STICK_ASR_ATTEMPTS=2
```

使用云端 ASR 时，音频会离开本机 Mac。

### ASR 方案 2：任意 OpenAI 兼容服务

只要服务支持 `POST {base_url}/audio/transcriptions` 即可。

```sh
VIBE_STICK_ASR_PROVIDER=openai-compatible
VIBE_STICK_ASR_BASE_URL=https://example.com/v1
VIBE_STICK_ASR_API_KEY=your-api-key
VIBE_STICK_ASR_MODEL=provider-model-name
```

Groq 也作为海外可选 preset 保留：

```sh
VIBE_STICK_ASR_PROVIDER=groq
VIBE_STICK_ASR_API_KEY=your-groq-key
```

旧别名 `VIBE_STICK_GROQ_API_KEY`、`VIBE_STICK_GROQ_MODEL`、`VIBE_STICK_GROQ_LANGUAGE` 仍然支持。

### ASR 方案 3：本地命令（离线）

```sh
VIBE_STICK_TRANSCRIBE_CMD=/path/to/transcribe-command
VIBE_STICK_TRANSCRIBE_TIMEOUT_SECONDS=120
```

这个命令会从 stdin 收到录音 session JSON，并应把最终转写文本打印到 stdout。

### Claude 用量

想显示 Claude 5H/7D 用量，请使用 `VIBE_STICK_PROVIDER=claude` 或 `VIBE_STICK_PROVIDER=auto`，设置 `VIBE_STICK_CLAUDE_USAGE=on`，并确保 Claude Code CLI 已在终端通过 `claude` 和 `/login` 登录。

- `VIBE_STICK_CLAUDE_USAGE`：设为 `on` 后获取真实 Claude Code 订阅用量；默认 `off`。
- `CLAUDE_CODE_OAUTH_TOKEN`：可选 Claude Code OAuth access token。未设置时，bridge 会尝试读取本机 Claude Code keychain / 文件凭据。
- `VIBE_STICK_CLAUDE_USAGE_INTERVAL_SECONDS`：Claude 用量轮询间隔，默认 `300`，最小 `30`。

Claude usage 会使用用户本机 Claude Code 订阅凭据和 client headers 调用未公开的 Anthropic endpoint。它是 opt-in，可能随时失效；bridge HTTP API 不会暴露 token 或原始 endpoint 响应。如果从未成功抓取过 Claude usage，StickS3 会显示 `--%`；成功抓取后，临时刷新失败会保留上一次值并标记 stale。

## 项目结构

```text
VibeStick-for-Mac/
  README.md
  README.zh-CN.md
  .env.example
  docs/
  firmware/sticks3/
  bridge/src/vibe_stick/
  app/macos/VibeStick.xcodeproj/
  app/macos/VibeStickApp/
  app/macos/VibeStickAppTests/
  app/macos/VibeStickBridge/
  app/macos/VibeStickHUD/
  app/macos/VibeStickPaste/
  scripts/
  tests/
```

## 检查命令

下面的 Python 测试用于保护保留的参考实现兼容性，属于开发者检查，不是普通
用户运行 App 的依赖。

```sh
python3 -m compileall -q bridge/src tests
PYTHONPATH=bridge/src python3 -m unittest discover -s tests
bash -n scripts/setup.sh scripts/doctor.sh scripts/install.sh
scripts/verify-macos-build.sh
```

普通 RC App/DMG 构建使用 `release/firmware` 中已验收且绑定源码摘要的固定载荷，
不需要 ESP-IDF。只有重新构建固件本身时才需要 ESP-IDF，并须重新验收：

```sh
cd firmware/sticks3
. $HOME/esp/esp-idf/export.sh
idf.py build
```

## 当前限制

- RC 2 已使用原生 Swift 运行时，并完成隔离 App/DMG 验收。最终 RC 2 候选在发布前完成离线验证，但没有安装或启动。由于没有第二台全新 Mac 或可用的外置干净启动环境，严格的全新环境首次安装与故障回退验收仍未执行；这既不是通过，也不是失败。
- 固件只面向 M5Stack StickS3。
- Mac App 只支持 Apple Silicon 和 macOS 15 或更高版本；当前为 ad-hoc 签名且未经 Apple 公证。
- Codex 额度平时跟随本地任务 `rate_limits` 事件，不额外启动进程；手动刷新时才单次调用与当前版本绑定的本机 Codex app-server 协议，获取更新的账户级读数。两者都不是公开额度 API。
- Claude usage 来自未公开的 Claude Code OAuth endpoint，默认关闭。
- ASR 可靠性取决于麦克风采集、上传 PCM 质量、provider 可达性和模型配置。

## 贡献与安全

欢迎贡献,详见 [CONTRIBUTING.md](CONTRIBUTING.md)。报告安全漏洞请见
[SECURITY.md](SECURITY.md)(请私下报告)。

## 许可证

原始 VibeStick 与 VibeStick for Mac 修改均使用 MIT License 发布，并保留原作者版权
声明。详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
固件和字体等随包许可见[第三方许可证清单](docs/THIRD_PARTY_LICENSES.md)。
