# VibeStick for Mac：M1 阶段成果清单

> 状态：M1 本地开发检查点，尚未作为正式 Release 发布
>
> 产品版本：0.2.0
>
> 开发分支：`vibestick-for-mac`
>
> 上游项目：[GaryGaryyy/VibeStick](https://github.com/GaryGaryyy/VibeStick)
>
> 独立维护：[HanminYIN/VibeStick](https://github.com/HanminYIN/VibeStick)

> 本文件保留 M1 封存时的完成范围与后续待办；M2 的当前成果见 [M2 阶段成果与版本演进对比](VIBESTICK_FOR_MAC_M2_ACHIEVEMENTS.md)。

## 1. 阶段结论

VibeStick for Mac 已经从“在原项目上修几个问题”发展为一个具备独立产品方向、原生 Mac 应用、质量门禁和后续路线图的 macOS / M5Stack StickS3 衍生项目。

M1 的目标不是重写已经稳定运行的固件与后台，而是在不破坏当前能力的前提下，为它们建立一个原生、可视、可诊断、可继续演进的 Mac 控制中心。这个目标已经完成，并通过本机安装、真实设备语音和后台生命周期人工验收。

当前成果适合作为独立维护项目的第一个开发检查点，但还不是面向全新 Mac 的完整安装器。M2 至 M4 的配对、配置同步、设备新界面和一键烧录仍需继续开发。

## 2. 从上游保留的稳定能力

以下核心能力来自原始 VibeStick，并在 M0/M1 中保持兼容：

- M5Stack StickS3 固件及 135 × 240 设备屏幕基础界面。
- Codex、Claude 等本机 Agent 状态展示。
- Codex 本地额度数据观察和设备端显示。
- StickS3 正面蓝键长按录音、上传、语音识别与文字输入。
- Bridge HTTP 状态与录音接口。
- HUD 录音、识别和粘贴反馈。
- 完成、审批和错误提醒音。
- OpenAI-compatible、Groq 和本地命令 ASR 路径。

M1 没有修改稳定固件。当前实机仍可回退到已经验证的基线。

## 3. M0：稳定基线与运行链路增强

基线提交：`9b3b0fa72e1043c542d83d401f147b1fe82e0a4d`

### 3.1 Codex 状态与额度

- 修复 Codex 动态状态观察，使运行、空闲、完成、审批、错误和离线状态更符合真实会话。
- 保留本地 `rate_limits` 额度观察，不伪装成官方 quota API。
- 对 0%、1% 和缓存更新进行真实链路核对，避免无依据修改固件。

### 3.2 具名后台组件

- 将后台组件统一为 `VibeStick Bridge`、`VibeStick HUD` 和 `VibeStick Paste`。
- 使用稳定的内部可执行文件名与 LaunchAgent 标识。
- 避免在系统后台与权限页面中只出现 `sh`、Python 或其他难以理解的通用名称。

### 3.3 Paste 权限与输入链路

- 新增原生 `VibeStick Paste.app`，把辅助功能权限限定到稳定的 Paste 身份。
- 重复安装时保留未变化的 Paste helper，降低权限失效概率。
- Bridge、doctor 和 Mac 控制中心统一通过 LaunchServices 调用 Paste，避免 TCC 把权限错误归因给主 App。
- 支持粘贴后可选 Return，同时保持默认“只粘贴、不自动发送”。

### 3.4 安全与诊断

- 强化 Bridge token 生成、匹配和安装检查。
- 增加录音体积限制、配置检查和具名服务诊断。
- 敏感配置、日志、录音和本地会话继续留在 Git 之外。

## 4. M1：原生 VibeStick for Mac

### 4.1 SwiftUI 控制中心

- 建立原生 Xcode 工程和 SwiftUI 主应用。
- 最低系统明确为 macOS 15，主 App 使用 Swift 6，兼容 helper 保持 Swift 5 模式。
- 面向 Apple Silicon 输出 thin arm64 构建。
- 主窗口提供首页、设备界面、语音与发送、按键与提醒、连接与后台、更新与恢复和高级设置七个区域。
- 首次默认窗口采用紧凑的 960 × 640 内容尺寸，同时保留标准缩放与窗口恢复。

### 4.2 首页与运行状态

- Codex 固定为首页主状态卡，不受当前活动 Provider 切换影响。
- 显示项目名、运行状态、可用额度窗口和缓存状态。
- 语音能力与 Bridge/HUD/Paste 状态采用独立卡片。
- 首页卡片完成等宽等高、最小窗口和深色界面视觉调整。

### 4.3 后台服务管理

- 分别显示 Bridge、HUD、Paste 的安装、运行、权限、版本和就绪状态。
- 支持显式启动、停止和重启 Bridge/HUD。
- 服务操作前核对 LaunchAgent label、路径和真实运行状态，避免启动意外程序。
- 启停动作等待 Bridge 就绪；失败时不再用“操作已提交”伪装成功。
- 录音、识别或待粘贴期间保护后台，不允许普通停止/重启打断真实会话。
- 主 App 关闭或退出不会停止 Bridge/HUD/Paste。

### 4.4 权限与故障排查

- Paste 权限检查使用与真实文字输入相同的 bundle 启动路径。
- 区分“未授权”“检查失败”“helper 缺失”和“需要修复”，减少权限误报。
- 一键打开辅助功能设置、登录项设置和本地数据文件夹。
- 数据文件夹直接打开目标目录，并明确仅供故障排查，普通用户无需理解内部文件。
- 技术名称和系统标识默认隐藏，仅在用户开启故障排查信息后显示。

### 4.5 设置与本地数据边界

- 支持菜单栏入口开关、登录时启动、故障排查信息和自动刷新间隔。
- 普通偏好写入私有权限的 `config-v1.json`，采用原子保存。
- 菜单栏插入状态使用稳定的 AppStorage 数据源，避免 SwiftUI Scene 发布闭环。
- 为后续 Keychain 密钥迁移建立接口，但 M1 不自动搬迁或改写现有 `.env`。
- 高级设置只显示脱敏摘要，不显示完整 API Key 或 token。

### 4.6 品牌与视觉

- 设计并集成 VibeStick for Mac 彩色 AppIcon。
- 设计与 AppIcon 同源的 18 pt 单色模板状态栏图标，自动适配浅色、深色和选中状态。
- 统一卡片、状态色、圆角、按钮和侧边栏视觉语言。
- 配置摘要区区分字段名与状态值：成功为绿色、信息为品牌蓝、待迁移为橙色。
- 设备页明确标记为 M1 结构草图，不冒充实时镜像或最终固件视觉。

### 4.7 DMG 与构建交付

- 提供 Release App 构建脚本。
- 提供只包含 `VibeStick for Mac.app` 和 Applications 链接的开发版 DMG。
- 当前 DMG 用于已经安装稳定 Bridge/HUD/Paste 的 Mac，不冒充全新机器安装器。
- 构建产物保持 arm64、macOS 15 deployment target 和 ad-hoc 签名。
- App 和挂载后的 DMG 都验证 AppIcon、菜单栏图标、签名、架构和隐私边界。

## 5. Codex 主任务完成识别增强

M1 收尾期间进一步修复了长任务中的“短暂已完成”误报：

- 只把用户主动发起的顶层任务视为可通知主任务。
- 内部 subagent、Guardian、工具步骤和审批审查会话完成不会触发完成音。
- 多个用户主任务并行时，其中一个完成会产生一次完成提醒，但只要仍有主任务运行，设备全局状态继续显示运行中。
- 最后一个主任务完成后才显示已完成。
- 手动停止或 `turn_aborted` 不视为成功完成，也不播放完成音。
- 完成事件 ID 绑定 session 与 turn，避免同一事件重复响铃。

该过滤已部署到当前 Bridge，并用真实内部复核任务完成事件进行现场验证：Bridge 持续返回 `RUNNING / NONE`，未再产生子任务完成误报。

## 6. 测试与验收证据

### 6.1 自动检查

- 81 项 Python 测试通过。
- 14 项 hostless Swift 测试通过。
- Bridge Python 源码编译检查通过。
- Xcode Release 主 App、Bridge、HUD、Paste 兼容 target 全部构建通过。
- App、helper、测试 bundle 的 ad-hoc 签名验证通过。
- 主 App 与 helper 均验证为 thin arm64、macOS 15.0 minimum。
- 构建版和 DMG 版两轮启动 smoke 通过，未出现 SwiftUI 发布闭环、启动退出或内存失控。
- 启动 smoke 前后 Bridge/HUD PID 保持不变。
- AppIcon、状态栏图标和 Assets.car 产物门禁通过。
- App 与 DMG 隐私/开发垃圾扫描通过。
- DMG 校验、只读挂载、根目录内容和挂载后签名验证通过。
- 正常 macOS 会话环境下 `scripts/doctor.sh` 达到 16 PASS、0 WARN、0 FAIL。

### 6.2 使用者人工验收

- 从 DMG 拖入“应用程序”并正常启动。
- 无启动彩虹圈、异常退出或持续内存增长。
- 首页、侧边栏、菜单栏、AppIcon 和状态栏图标显示正常。
- Bridge/HUD/Paste 状态与权限刷新正确。
- Bridge/HUD 重启、停止、恢复正常。
- 主 App 退出后后台服务继续运行。
- StickS3 真实录音、ASR、HUD 和 Paste 链路正常。
- 菜单栏与设置持久化正常。
- 最小窗口布局、首页卡片和高级设置视觉通过人工确认。

## 7. 当前明确未完成

以下内容属于后续里程碑，不能作为 M1 已实现能力宣传：

- 全新 Mac 无终端安装和旧版自动迁移。
- USB 自动识别、设备 ID、安全配对与重新配对。
- Bonjour/mDNS 自动发现与 Mac IP 变化自动恢复。
- 通用固件配置协议与 Mac 到 StickS3 配置同步。
- Codex Focus 高保真设备新首页与实时设备预览。
- 页面模块选择、顺序调整和项目名实机布局。
- 语音全屏覆盖层、蓝键确认发送和完整按键状态机。
- 面向普通用户的 ASR Provider 表单与连通性测试。
- 一键下载烧录组件、固件备份、更新、恢复和回退。
- Codex 智能审批与 StickS3 双击授权。
- Developer ID 签名、Apple 公证、App Store 或 Intel Mac。

详细后续范围见 [VibeStick for Mac Roadmap](VIBESTICK_FOR_MAC_ROADMAP.md)。

## 8. 项目定位与维护方式

建议将 VibeStick for Mac 定位为：

> 基于 Gary Zhang 原始 VibeStick、面向 macOS 与 M5Stack StickS3、由 HanminYIN 独立维护的本地优先衍生项目。

项目原则：

- 保留完整 Git 历史和上游来源，不抹去原作者贡献。
- 保留原始 MIT License 版权与许可文本。
- 在 README、NOTICE 和 Release Notes 中持续标注上游。
- 独立制定 Mac 产品路线，不默认把个人化功能提交给上游。
- 本地保留 `upstream` remote，用于审阅上游变化，不自动合并。
- 不提供中央服务器、账号系统、遥测或云端配置平台。

## 9. 下一检查点

在进入 M2 前，建议完成：

1. 审阅本成果清单和 README 项目定位。
2. 完成秘密、录音、日志、构建缓存、许可证与 NOTICE 审计。
3. 将当前 M1 源码和文档整理成干净提交。
4. 推送 `vibestick-for-mac` 检查点并建立预发布标签。
5. 再决定是否将 GitHub 仓库脱离 Fork network，并酌情改名为 `VibeStick-for-Mac`。

提交、推送、标签、Release、仓库改名和脱离 Fork 均需单独确认，不在本文档整理动作中自动执行。
