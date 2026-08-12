# VibeStick for Mac M2 实现与验收边界

> 日期：2026-08-12
>
> M1 封存基线：`92f8a0b03a2246eecb20ba49b2491c0efd9f137c`
>
> 状态：本机与真机主链路、真实重新配对、失败恢复及真实地址变化验收完成；未提交或发布

## 现在能直观看到什么

- “连接与后台”会显示当前 Bridge 身份、USB StickS3、是否已配对、局域网在线状态和配置 ACK，不再只显示三个后台进程。
- 新设备必须插着 USB 并由使用者点击“安全配对”；完成后设备拥有自己的密钥，不再把新增密钥通过局域网下发。
- 配对后的 StickS3 会记住 Bridge 身份，通过 Bonjour 找到 Mac 当前的地址和端口；旧 IP 只保留为发现失败时的回退。
- “设备界面”可以保存模块、项目显示和按键设置；设备在线时会自动拉取新 revision 并回报已同步，无需为普通设置重新烧录。
- 原来的蓝键录音、转写、HUD、Paste、Codex 状态和额度仍是同一条使用路径。

## 已实现

### Bridge

- 持久化随机 Bridge UUID，并用 `_vibestick._tcp` 广播协议 2、Bridge ID 和 paired auth 能力。
- 读取设备注册表，只保存每台设备 token 的随机盐和 SHA-256 哈希，使用常量时间比较。
- 局域网 `/state`、语音、事件和额度请求支持设备专属鉴权，同时保留 M1 legacy token。
- 提供 paired-only 配置获取/ACK，以及 loopback-only 设备管理状态。
- 配置大小受限并按 allow-list 规范化，不包含 Wi-Fi、ASR 或鉴权秘密。
- Provider/Codex 状态新增动态 `quota_windows`，继续输出旧 5H/7D 字段。

### VibeStick for Mac

- 只识别 Espressif USB Serial/JTAG VID/PID 与 `/dev/cu.usbmodem*` 候选。
- 配对必须由用户点击，且运行中的 Bridge 必须明确报告协议 2 和有效 Bridge ID。
- 生成 256-bit 随机设备 token 和 128-bit 随机盐；token 写入 Keychain，注册表仅写哈希。
- 通过带明确响应标记的 USB 行协议识别设备和写入配对材料。
- 提供模块、项目显示、项目名、正面双击和侧键配置；保存时单调递增 revision。
- 显示 Bonjour、USB、已配对设备在线状态和配置 ACK 状态；保留原有 Bridge/HUD/Paste 生命周期控制。

### StickS3 firmware

- 设备 ID 从 Wi-Fi STA MAC 派生；配对记录和已接受配置写入独立 NVS namespace。
- USB Serial/JTAG 只接受 identify/pair 命令，严格校验设备 ID、token、UUID、回退 host 和端口，日志不输出 token。
- 通过 mDNS 按已配对 Bridge ID 精确选择服务，获取当前 IPv4/端口，失败后退回手动地址并重试发现。
- 所有运行请求携带设备 ID 和设备专属 token；M1 编译时 host/token 仍作为未配对兼容路径。
- 每 10 秒拉取配置，只接受更高 revision，持久化后 ACK；Codex 与连接状态不可关闭，Claude 默认关闭。
- 动态渲染最多两个实际额度窗口并兼容旧字段；现有录音、上传、转写、Paste、提醒声音和 provider 状态路径保留。

## 安全与兼容决定

- 不提供 LAN 配对接口；新增或轮换 token 必须存在 USB 物理连接。
- 不在 Bridge 注册表、配置 JSON、诊断响应或日志中保存/返回明文 token。
- `/health` 只暴露非秘密 Bridge 身份；`/v1/devices` 只允许 loopback。
- 旧固件无需迁移即可继续使用 M1 host/token；Mac app 不会因检测到 USB 就修改设备。
- 未确认 M2 Bridge 就绪时禁止配对，避免把设备切到旧 Bridge 无法识别的新 token。
- 当前 firmware 保持 M1 的 135 × 240 视觉布局；M3 的高保真视觉改造没有混入本里程碑。

## 自动验证

- Python：97 项 `unittest` 通过，覆盖旧协议、pairing hash、注册表、配置规范化、HTTP 鉴权/ACK、鉴权绑定、动态额度与客户端提前断连处理。
- Swift：23 项 hostless 测试通过，并完成 Release app、签名、启动 smoke test 和 DMG 内容验证；覆盖旧 Bridge 解码、M1 生命周期、USB 检测、串口响应、hash 向量、配对事务恢复、钥匙串分阶段轮换及注入式 USB 失败回滚、手动地址、私有配置文件和 M2 Bridge 配对门禁。
- Firmware：ESP-IDF 5.5.1 完整构建通过；当前镜像为 `0x157da0`，最小 app 分区剩余 `0x1f260`（8%）。
- Shell：脚本语法检查通过；源代码扫描未发现新增密钥材料。

具体测试数以本次工作区最后一轮完整验证输出为准。

## 真机验收进度

已完成：

1. 已保存权限受限的 M1 Mac 端回滚材料和完整 8 MB StickS3 flash 镜像，并校验 SHA-256。
2. 已安装 M2 Bridge 与 Mac app；替换 Bridge 后，未刷写的 M1 固件仍能读取 Codex 状态和额度，`doctor.sh` 保持 16/0/0。
3. 已刷写 M2 firmware；配对记录和配置在再次刷写及设备复位后仍从 NVS 正确恢复。
4. 已完成 USB 首次配对；Bridge 注册表为 `0600` 且只含加盐哈希，Mac 钥匙串存在设备 token，设备专属配置请求与 ACK 成功。
5. 已把不改变行为的默认设置从 revision 0 提升到 1，真机自动拉取并显示 `设备已同步 r1`。
6. 已在设备复位后从串口确认按 Bridge ID 完成 Bonjour 解析并恢复轮询。
7. 已完成正面蓝键真实录音、上传、转写、HUD/Paste 和 TextEdit 插入；Codex 状态与动态 `7D` 额度保持可用。
8. 已完成一次真实凭据轮换：注册表加盐哈希和配对时间更新，新 token 写入独立钥匙串账户，设备使用新凭据重新上线并完成配置 `1/1`。
9. 已验证两层失败恢复：真机首次尝试在任何设备写入前被旧钥匙串 ACL 拒绝，注册表和设备保持原状；注入式 USB 写入失败测试确认暂存新密钥后仍会恢复旧注册表并删除暂存条目。
10. 已完成真实 Mac 地址变化测试：验收时完全移除原 DHCP 地址并临时切换到另一局域网地址，保持约 95 秒后恢复 DHCP；仅持有新地址的窗口内，设备继续完成 63 次已认证 Bridge 请求（45 次状态、9 次配置拉取、9 次配置 ACK），证明它已通过 Bonjour 找到新地址而非继续使用旧地址回退。为避免把本地网络拓扑写入公开历史，具体接口名和地址不记录在仓库中。

真机过程中发现并修复了两项只会在硬件上暴露的问题：ESP mDNS 查询名缺少 `_` 前缀；刚复位的 USB Serial/JTAG 偶尔晚于 macOS 枚举，Mac 端现会在首次识别超时后自动重试一次。

配对轮换收尾还加入了幂等事务 ID：丢失最终 USB ACK 时，Mac 会重发同一密钥和事务，并可通过设备 identify 响应确认是否已经写入，避免误回滚成两端密钥不一致；固件 NVS 持久化失败时也会恢复旧的内存配置。

每次凭据轮换会先写入独立的新钥匙串条目，而不覆盖旧条目；失败时只删除新条目并恢复旧注册表。设备确认成功后旧 token 已失效，再尽力清理旧条目。这样开发版 App 的临时签名发生变化时也不需要读取或放宽旧条目的访问控制。真机轮换已验证这条迁移路径。

收尾回归还修复了 Bridge 响应期间设备提前断开所产生的 `BrokenPipeError` 日志噪声；请求处理结果不变，断开的响应 socket 现在会安静结束。

本轮 M2 验收门禁均已完成。地址变化测试会同时中断承载 Codex 会话的 Mac 外网连接，因此观察脚本一度失联；自动恢复钩子已在测试结束时将 Wi-Fi 完整切回 DHCP。验收结论确认后，再决定是否形成 M2 提交或开发 DMG；本阶段不自动 commit、push、Release 或改变 remotes。
