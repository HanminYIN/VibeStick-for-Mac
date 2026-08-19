# M3-B1：待发送会话安全内核

> 状态：安全内核已完成受控部署和真人真机主流程验收；联合检查点后的 HUD 与运行时收尾已另行授权部署并完成复核
>
> 前置：M3-B0 视觉和交互规格、Mac 实时预览校准

## 本阶段范围

M3-B1 先实现待发送状态机、脱敏目标识别和源码态 Bridge 接口。该隔离门通过后，能力已按
受控顺序接入现有 Bridge/Paste 与 StickS3，并完成成功和焦点变化安全失败验收。

隔离阶段先固定最容易产生误发的规则，再分别接入 Mac 目标识别、Bridge HTTP 接口和
StickS3 按键状态机；当前工作树继续以同一规则作为不可回退的安全边界。

## 不变边界

- 未声明 M3-B 交互版本的现有固件继续走 M3-A 同步录音和粘贴路径。
- `VIBE_STICK_AUTO_ENTER` 的既有语义在兼容路径中不变。
- 后续源码收尾不得隐式替换 Bridge、HUD、Paste、配对状态、配置 revision/ACK 或设备固件。
- 状态文件不保存 transcript、窗口标题、剪贴板内容或 API Key。

## 状态

```text
idle
  -> pending
  -> confirming
  -> sent | failed

pending -> expired
pending -> invalidated       (新录音或目标变化)
confirming -> invalidated    (Bridge 在确认过程中重启，保守恢复)
```

`pending -> confirming` 是单次消费点。状态必须在真正调用 Return 之前原子持久化；重复确认、
Bridge 重试或重复 HTTP 请求都不能再次产生 Return。

## 目标身份

待发送会话只保存：

- 前台 App bundle ID；
- 进程 PID；
- 辅助功能焦点摘要的 SHA-256 指纹。

不保存窗口标题、输入框文字或辅助功能原始描述。确认时三个字段必须全部相等；任何缺失或
变化都使会话失效。

## 时间与恢复

- 默认有效期 30 秒，可接受范围为 5–300 秒。
- 过期检查在读取状态和确认前执行。
- `confirming` 表示 Return 动作已经被消费；Bridge 若在这个阶段重启，恢复为
  `invalidated`，不得猜测或重试。
- 新录音会使 `pending` 失效；`confirming` 期间则拒绝开始新录音。

## 后续接线顺序

1. [x] Paste Helper 返回脱敏目标身份，并提供“仅在目标仍匹配时按一次 Return”的操作。
2. [x] Bridge 在显式 M3-B 能力协商后开放确认接口；旧固件不会进入待发送状态。
3. [x] 固件源码接入待发送、成功、失败覆盖层和按键优先级；默认编译关闭。
4. [x] 完成隔离部署、真人真机成功发送与目标变化安全失败回归。

## 验证演进

- 隔离源码门曾以 133 项 Python 全量回归、Paste Helper Release arm64/macOS 构建和固件纯 C 状态机主机测试通过。
- 受控部署后，Bridge 健康响应报告 transport protocol v2 与 voice interaction v2；成功发送和焦点变化后的拒绝发送均由真人真机确认。
- 当前设备 config revision/ACK 保持 `1/1`，配对关系、Codex Focus、语音输入、HUD 与 Paste 保持可用。
- 本地联合检查点增加状态持久化脱敏、0600/0700 权限和 Mac 脱敏状态页；检查点形成时的完整验证没有重新部署这些收尾改动。
- 本地封存版本已通过 147 项 Python、27 项 Swift、Release App/Helper、正常 GUI 启动与 DMG 完整验证；验证脚本确认未改变 Bridge/HUD 进程。
- 检查点后的最终候选进一步通过 159 项 Python、33 项 Swift、Release App/Helper、正常 GUI、DMG、ESP-IDF 5.5.1 和 Doctor `16/16`；已安装 recorder、transcriber 与 HUD 已逐字匹配候选源码。当前结论以 `VIBESTICK_FOR_MAC_M3B_ACHIEVEMENTS.md` 为准。
