# VibeStick for Mac：M2 阶段成果与版本演进对比

> 状态：M2 本地开发检查点已完成自动回归与真机验收，尚未提交或发布
>
> 日期：2026-08-12
>
> M1 封存基线：`92f8a0b03a2246eecb20ba49b2491c0efd9f137c`
>
> 上游比较基线：本地记录的 `GaryGaryyy/VibeStick` `f368d0b`
>
> 上游项目：[GaryGaryyy/VibeStick](https://github.com/GaryGaryyy/VibeStick)
>
> 独立维护：[HanminYIN/VibeStick](https://github.com/HanminYIN/VibeStick)

## 1. 阶段结论

M2 把 VibeStick for Mac 从“原生 Mac 控制中心管理一套固定安装”，推进成了一套能够识别真实设备、通过 USB 建立信任、在局域网地址变化后自动重连，并把普通设备设置同步到 StickS3 的双端系统。

相较 M1，用户现在不只能够查看 Bridge、HUD 和 Paste 是否运行，还能看到具体 StickS3 是否通过 USB 接入、是否已配对、是否在局域网在线，以及设备配置是否已经 ACK。相较原作者版本，连接关系不再只依赖固件中写死的 Mac IP 和全局共享 token，而是增加了设备 ID、设备专属凭据、Bridge 身份、Bonjour 自动发现和带 revision 的配置同步。

这不是对原始 VibeStick 的替代叙事。Gary Zhang 的版本完成了最关键的产品发明：让 StickS3 显示 coding agent 状态与额度，并通过实体按键完成录音、转写和 Mac 文字输入。VibeStick for Mac 在完整保留署名、历史和 MIT 许可的前提下，沿着 macOS 产品化、安全连接和长期可维护性继续演进。

M2 已通过当前 Mac 与真实 StickS3 的验收，适合作为第二个独立开发检查点；它尚未 commit、push、打标签或发布 Release，也不是面向全新 Mac 的一键安装器。

## 2. 从原作者版本继承的核心价值

以下能力由原始 VibeStick 奠定，并在 M0、M1、M2 中持续保持：

- M5Stack StickS3 作为 coding agent 桌面状态终端的产品形态。
- Codex、Claude 等 provider 的运行、空闲、完成、审批、错误和离线状态。
- 额度窗口显示、项目状态和设备端提醒。
- 正面蓝键长按录音、松开上传、ASR 转写和 Mac 输入。
- StickS3 扬声器的完成、审批和错误提示音。
- Bridge HTTP 服务、Mac HUD 和 Paste 使用链路。
- OpenAI-compatible、Groq 和本地命令 ASR 路径。
- 2.4 GHz Wi-Fi、ESP-IDF 构建、安装脚本和诊断脚本基础。

M2 的所有新增能力都以不破坏这条稳定使用路径为前提。真机回归再次确认了录音、转写、HUD、Paste、TextEdit 插入、Codex 状态、提示音和动态 `7D` 额度仍然可用。

## 3. 项目每个阶段完成了什么升级

| 阶段 | 产品升级 | 对用户的直接价值 | 可提炼的宣传点 |
| --- | --- | --- | --- |
| 原作者版本 | 建立 StickS3 + Bridge + HUD + 语音输入的完整创意原型 | coding agent 状态、额度和语音输入第一次进入实体桌面设备 | “把 Coding Agent 装进一根可说话的 StickS3” |
| M0 稳定基线 | 修正 Codex 状态观察、具名后台、Paste 权限身份、安装诊断与敏感配置边界 | 状态更可信，后台和权限更容易理解，语音输入更稳定 | “从能运行的原型，变成可长期使用的本地工作流” |
| M1 原生控制中心 | 新增 SwiftUI App、菜单栏、结构化健康状态、显式服务管理、品牌图标与开发 DMG | 日常管理不再依赖记忆终端命令，Mac 端具备完整产品入口 | “从脚本工具，升级为原生 Mac 应用” |
| M2 配对与同步 | 新增设备 ID、USB 安全配对、设备专属密钥、Bonjour、配置 revision/ACK 和事务恢复 | 换 IP 能自动恢复，设备信任关系可见、可轮换，普通配置不再依赖重新烧录 | “从固定 IP 外设，升级为可安全配对、会自动重连的 Mac 伴侣” |

这条演进线可以概括为：

> 原作者完成了产品创意与核心闭环；M0 让闭环稳定可信，M1 让它成为 Mac 产品，M2 让 Mac 与 StickS3 建立可管理、可恢复、可演进的设备关系。

## 4. M2：设备发现与安全配对

### 4.1 可识别的设备与 Bridge

- StickS3 从 Wi-Fi STA MAC 派生稳定设备 ID。
- Bridge 首次运行生成并持久化随机 Bridge UUID。
- Mac App 只接受 Espressif USB Serial/JTAG VID/PID 与对应串口候选，避免把普通串口设备误认为 StickS3。
- “连接与后台”同时展示 Bridge ID、USB 接入、配对状态、局域网在线状态、固件版本和配置同步 revision。

原作者版本解决了“设备如何访问 Bridge”；M2 进一步解决了“这是哪台设备、它信任哪一个 Bridge、当前是否真的同步完成”。

### 4.2 必须有物理连接的安全配对

- 配对不会因为 App 启动或检测到 USB 自动发生，必须由用户点击“安全配对”或“重新配对”。
- 新增和轮换设备凭据只允许通过 USB 行协议写入，不提供局域网配对接口。
- Mac 生成 256-bit 随机设备 token 和 128-bit 随机盐。
- Bridge 注册表只保存盐和 SHA-256 哈希，使用常量时间比较，不保存明文 token。
- 明文 token 保存在 macOS Keychain；StickS3 只保存运行所需的最小配对材料。
- App 必须先确认运行中的 Bridge 明确支持协议 2 并具有有效 Bridge ID，才允许改写设备凭据。

这使 M2 的配对不只是“连接成功”，而是具备物理在场、最小暴露和显式授权边界的本地信任建立过程。

### 4.3 可安全失败的凭据轮换

- 每次重新配对使用独立的新 Keychain 账户暂存密钥，不覆盖仍在工作的旧条目。
- 设备写入成功前，Bridge 注册表与旧凭据均可恢复。
- USB 写入失败会恢复旧注册表并删除新暂存密钥。
- 配对事务具有幂等 transaction ID；如果最终 USB ACK 丢失，Mac 可以重发同一事务并通过 identify 判断设备是否已经写入。
- 固件 NVS 持久化失败会恢复旧的内存配置，避免设备处于半更新状态。
- 新凭据确认可用后，旧 token 才失效并进入尽力清理。

真实设备已经完成一次凭据轮换；注入式 USB 写入失败测试也验证了回滚。这一设计避免了最危险的结果：Mac 和 StickS3 各自保存不同密钥，双方永久失联。

## 5. M2：Bonjour 自动发现与网络恢复

### 5.1 从写死地址到 Bridge 身份发现

原作者版本把 `VIBE_STICK_BRIDGE_HOST` 编译进固件。这个方式简单可靠，但 Mac 的 DHCP 地址变化后通常需要修改配置并重新烧录。

M2 增加了：

- Bridge 通过 `_vibestick._tcp` 广播协议版本、Bridge ID 和配对鉴权能力。
- StickS3 按已配对 Bridge ID 精确选择服务，而不是连接局域网中任意同名服务。
- 设备解析 Bridge 当前 IPv4 和端口后继续使用设备专属身份访问。
- Bonjour 暂时不可用时仍保留手动地址回退，并在失败后重新尝试发现。
- M1 固件原有的编译时 host/token 路径继续兼容。

### 5.2 真实地址变化验收

验收期间，Mac 的原 DHCP 地址被完整移除并切换为另一局域网地址，约 95 秒后恢复 DHCP。具体接口名和地址不写入公开仓库。

在 Mac 仅持有新地址的窗口内，StickS3 继续完成 63 次已认证请求：

- 45 次状态请求。
- 9 次配置拉取。
- 9 次配置 ACK。

由于旧地址已经从接口移除，这组请求证明设备确实通过 Bonjour 找到了新地址，而不是偶然继续使用旧 IP。测试结束后 Mac 完整恢复到 DHCP `.173`，设备继续在线。

对用户而言，这项升级的直观含义是：Mac 的局域网地址发生变化时，普通情况下不再需要重新编辑固件 host 并重新烧录。

## 6. M2：通用配置同步底座

### 6.1 带 revision 的配置协议

- Bridge 保存 schema version 1 的设备配置，并对输入做 allow-list 规范化。
- 配置只包含模块、默认页、项目显示字段和按键动作，不包含 Wi-Fi 密码、ASR key、Bridge token 或配对 token。
- 每次保存单调递增 revision。
- 已配对设备每 10 秒检查配置，只接受更高 revision。
- StickS3 先持久化到独立 NVS namespace，再向 Bridge ACK。
- Mac App 显示目标 revision 与设备最后 ACK revision，不把“已保存”误报为“设备已同步”。

### 6.2 当前已接通的设置与 M3 预留字段

- Codex 与连接模块保持必选；Claude 模块开关已经影响设备端可切换的 provider。
- 正面蓝键双击的刷新额度和提示音静音已经有固件行为。
- 侧键单击的切换页面或禁用已经有固件行为。
- 项目名称与显示开关可以保存、下发并在设备 NVS 中持久化，但尚未进入最终设备画面。
- 默认页面已经进入 Mac/Bridge 配置 schema；“显示状态”和“回到首页”也已有协议枚举，但其最终页面语义和设备视觉仍待 M3 实装。

因此，项目名、默认页、页面结构和模块布局的最终 135 × 240 视觉呈现仍属于 M3。M2 完成的是可信的保存、传输、校验、持久化和 ACK 底座，以及其中一部分已经生效的模块和按键行为；不把尚未完成的高保真设备界面作为现成功能宣传。

### 6.3 为什么这是长期宣传点

在原作者版本中，多数固件侧变化需要修改头文件、重新构建和烧录。M2 建立配置协议后，后续 M3 的普通界面选项和按键策略可以复用同一条 Mac → Bridge → StickS3 同步通道。

因此真正的升级不只是“多了几个设置”，而是：

> VibeStick 第一次拥有了不依赖重新烧录的设备配置基础设施。

## 7. 协议、兼容与运行稳定性

### 7.1 协议 v2

- 所有已配对设备请求携带设备 ID 和设备专属 token。
- 配置获取与 ACK 只接受已配对设备鉴权。
- `/v1/devices` 只允许本机访问，且不返回 token、盐或哈希材料。
- `/health` 只公开非秘密的 Bridge 名称、版本、协议版本和 Bridge ID。
- Bridge 在没有有效设备注册或非占位 legacy token 时拒绝绑定非 loopback 地址。

### 7.2 动态额度窗口

- Provider 状态新增 `quota_windows`，不再把协议能力永久限制在固定的 5H/7D 两个字段。
- StickS3 根据真实数据动态渲染最多两个额度窗口。
- Bridge 继续输出旧字段，旧固件和旧消费者无需同时升级。

### 7.3 向后兼容与稳定能力保护

- M2 Bridge 上线后，未刷写的 M1 固件仍能读取 Codex 状态和额度。
- 未配对固件仍可使用 M1 编译时 host/token 路径。
- App 不会因插入 USB 自动修改设备。
- M2 保留 M1 的 135 × 240 设备视觉，不把 M3 视觉重构混入连接协议里。
- Bridge/HUD/Paste 的后台生命周期和 Paste 辅助功能权限身份保持稳定。
- Bridge 响应时设备提前断开不再产生无意义的 `BrokenPipeError` 日志噪声。

## 8. 相对原作者版本的改进对比

本表比较的是本地保存的上游基线 `f368d0b` 与当前完成 M2 的 VibeStick for Mac 工作区。它用于说明衍生项目的增量，不否定原作者版本作为完整创意与核心运行闭环的价值。

| 能力 | 原作者版本 `f368d0b` | VibeStick for Mac M2 |
| --- | --- | --- |
| 产品形态 | StickS3 固件、Python Bridge、Swift HUD 与 shell 安装流程 | 保留原链路，并增加原生 SwiftUI 控制中心、菜单栏、品牌 App 和开发 DMG |
| Mac 管理 | 主要依赖终端脚本与 `doctor.sh` | 可视化 Bridge/HUD/Paste、USB 设备、配对、在线和配置 ACK 状态 |
| Bridge 地址 | 固件中配置固定 Mac host | 按已配对 Bridge ID 进行 Bonjour 发现，固定地址作为回退 |
| 鉴权模型 | 固件与 Bridge 共享一个全局 token | 每台设备独立 token；USB 建立信任；Bridge 只存加盐哈希；明文进入 Keychain |
| 设备身份 | 没有面向用户的设备注册关系 | 稳定设备 ID、Bridge UUID、配对时间、在线状态、固件版本和撤销状态 |
| 重新配对 | 修改共享配置并重新部署 | 用户显式 USB 轮换；分阶段 Keychain；事务幂等；失败自动回滚 |
| 网络变化 | Mac IP 变化后可能需要改 host 并重新烧录 | 真实地址变化中自动恢复，95 秒窗口完成 63 次请求 |
| 设备设置 | 主要依赖编译时配置与重新烧录 | schema + revision + allow-list + NVS + ACK 的运行时同步底座 |
| 按键设置 | 固件内固定行为 | Mac 端配置正面双击和侧键单击动作并同步到设备 |
| 额度协议 | 固定 5H/7D 字段 | 动态 `quota_windows`，同时保留旧字段兼容 |
| Paste 权限 | 辅助功能可能显示为 Python/启动进程身份 | 稳定具名 `VibeStick Paste.app`，安装时尽量保留已授权 helper |
| Codex 完成判断 | 从本地会话推断状态 | 过滤内部 subagent/Guardian，区分完成、终止与仍有主任务运行 |
| 构建交付 | README 明确为 cleaned prototype，没有打包 Mac App/DMG | thin arm64、macOS 15、ad-hoc 签名、Release App、DMG 和挂载后验证 |
| 自动验证 | Python 单元测试、脚本和固件构建检查 | 97 项 Python + 23 项 Swift，并加入签名、架构、启动、DMG、隐私和真机门禁 |

## 9. 可直接使用的宣传表达

### 9.1 一句话版本

> VibeStick for Mac M2 让 StickS3 从依赖固定 IP 的状态小屏，升级为可通过 USB 安全配对、随 Mac 地址变化自动重连，并能接收运行时配置的本地 AI 桌面伴侣。

### 9.2 短版产品介绍

> 基于 Gary Zhang 原始 VibeStick，VibeStick for Mac 先在 M1 加入原生 SwiftUI 控制中心，再在 M2 完成设备 ID、USB 安全配对、每设备密钥、Bonjour 自动发现与 revision/ACK 配置同步。原有 Codex 状态、额度、语音转写、HUD、Paste 和提示音链路保持兼容，同时设备连接变得可见、可轮换、可恢复。

### 9.3 M2 功能卖点

- **USB 物理在场配对：** 新密钥不通过局域网下发，只有插线并由用户确认才会建立或轮换信任。
- **每台设备独立身份：** 不再只依赖一个所有设备共用的 token。
- **Mac 换 IP 自动恢复：** Bonjour 按 Bridge 身份发现当前地址，真实地址变化已通过真机验收。
- **设置同步无需普通重刷：** 模块、项目字段和按键策略使用 revision/ACK 通道同步。
- **失败也不会把设备配坏：** Keychain 暂存、注册表回滚、事务 ID 和 NVS 恢复共同避免半配对状态。
- **升级不牺牲稳定功能：** 原有录音、ASR、HUD、Paste、Codex 状态、额度和提醒音均完成回归。
- **本地优先：** 没有中央账号、遥测或云端配置平台；配对材料留在 Mac 与设备之间。

### 9.4 对外表达边界

可以宣传：

- M2 已完成当前 Mac 与真实 StickS3 的本地验收。
- 支持 USB 安全配对、重新配对、Bonjour 地址恢复和运行时配置同步。
- 项目名等配置字段已经能够保存、下发、持久化和 ACK。

暂不应宣传：

- 面向所有新 Mac 的一键安装或无需终端部署。
- 最终版 Codex Focus 固件界面、完整页面重排或项目名最终设备视觉。
- App 内一键下载工具、烧录、备份和恢复。
- Developer ID、公证、正式签名 Release、Intel Mac 或 App Store 支持。

## 10. 测试与真机验收证据

### 10.1 自动回归

- 97 项 Python `unittest` 通过。
- 23 项 hostless Swift 测试通过。
- ESP-IDF 5.5.1 完整 firmware 构建通过。
- 当前 firmware 镜像为 `0x157da0`，最小 app 分区剩余 `0x1f260`（8%）。
- Release App、测试 bundle 和 helper 签名检查通过。
- 主 App 与 DMG App 均为 thin arm64、macOS 15.0 minimum。
- 构建版和 DMG 版启动 smoke 通过，且未改变 Bridge/HUD 进程。
- AppIcon、菜单栏图标、DMG 内容、隐私边界和 `git diff --check` 通过。
- `scripts/doctor.sh` 为 16 PASS、0 WARN、0 FAIL。

### 10.2 真实设备

- 保存并校验 M1 Mac 回滚材料与完整 8 MB StickS3 flash 镜像。
- M2 Bridge 对未刷写 M1 firmware 保持兼容。
- M2 firmware 刷写、复位和 NVS 恢复通过。
- USB 首次安全配对通过。
- 配置 revision 1 自动拉取和 ACK 通过。
- 设备复位后的 Bonjour 解析与轮询恢复通过。
- 真实凭据轮换和新凭据重新上线通过。
- USB 写入失败的注册表与 Keychain 回滚通过。
- Mac 真实地址变化后的 63 次已认证请求通过。
- 正面蓝键录音、上传、ASR、HUD、Paste、TextEdit 插入和提示音通过。
- Codex 状态与动态 `7D` 额度通过。

完整实现与逐项验收记录见 [M2 实现与验收边界](VIBESTICK_FOR_MAC_M2_IMPLEMENTATION.md)。

## 11. 当前边界与下一阶段

M2 完成了“设备如何被识别、如何信任 Mac、如何找到 Mac、如何接收设置”。M3 将在这套基础设施上完成“用户每天实际看到和操作什么”：

- Codex Focus 新首页与原生 135 × 240 高保真稿。
- 模块选择、页面顺序和项目名的最终设备布局。
- 语音全屏覆盖层、自动发送与蓝键确认发送。
- 更完整的按键状态机、提醒设置和 ASR Provider 表单。

在修改稳定固件视觉之前，仍需先提供高保真稿并由使用者确认。M4 才负责全新 Mac 安装、工具下载、烧录、备份、恢复和迁移。

## 12. 检查点建议

M2 当前工作区已经完成源码、自动回归、安装版和真机验收。后续动作建议按独立授权边界进行：

1. 审阅本成果总结与宣传口径。
2. 进行提交前秘密、日志、构建缓存、许可证与变更范围审计。
3. 决定是否整理为 M2 本地提交。
4. 再分别决定是否 push、打标签、制作开发 DMG 或发布 Release。
5. M2 封存后再进入 M3 的高保真界面设计。

提交、推送、标签、Release 和仓库关系调整均不由本文档整理动作自动执行。
