# M3-B2：固件源码接线门

> 状态：源码门、受控烧录与真人真机主流程验收已完成；当前失败文案精修尚未刷写
>
> 基线：本地 `e2113ba`；依赖 M3-B1 Bridge/Paste 待发送安全内核

## 本阶段结果

M3-B2 把交互版本协商、固件侧语音状态机、蓝键确认和覆盖层优先级接入 StickS3
源码，先用 `VIBE_STICK_ENABLE_M3B_VOICE` 编译开关隔离验证。源码门和受控真机验收通过后，
当前 M3-B 构建默认值改为 `ON`；头文件仍保留 `OFF` 回退值，只有项目 CMake 明确启用时才进入新路径。

## 能力协商

1. 长按开始录音前，显式启用的固件读取 Bridge `/health`。
2. 仅当设备已配对且 Bridge 返回 `voice_interaction_version >= 2` 时，请求携带
   `interaction_version: 2`。
3. start/stop 响应必须继续声明 v2；缺失、降级或 session 不一致时回落或失败关闭。
4. 旧 Bridge 不返回该字段，固件继续原有同步粘贴路径，不进入待发送状态。

## 固件状态与按键所有权

纯 C 状态机覆盖：

```text
idle -> recording -> transcribing
transcribing -> pasted | copied | sent | pending_send | failed
pending_send -> sending -> sent | failed
pending_send -> expired
pending_send -> recording       (长按开始新录音)
terminal -> idle                (自动退出或单击提前退出)
```

- `pending_send` 的正面单击只调用 `/recording/send/confirm`，请求只含 `session_id`。
- `recording`、`transcribing` 和 `sending` 阶段忽略无关按键。
- 覆盖层可见时双击和侧键不再触发额度刷新、静音或页面切换。
- 待发送 30 秒过期；成功保持 1.2 秒，失败/过期保持 1.5 秒。
- 重复单击不会产生第二次确认动作，Bridge 仍保留最终的原子单次消费保护。

## 视觉演进

源码门最初复用现有真机字体和录音覆盖层。随后已接入 M3-B0 高保真稿中的按钮框、成功环、
错误环和提示语，并通过真实 StickS3 校准。当前收尾进一步区分“未听清”“识别失败”“发送失败”
和过期“未发送”，不改变 session、时序、按键所有权或协议。

## 验证

- 纯 C 状态机由 macOS `clang -std=c11 -Wall -Wextra -Werror` 编译并运行。
- Python 全量回归包含上述主机测试。
- ESP-IDF 5.5.1 的 OFF/ON 源码门均通过，证明兼容路径和 M3-B 路径可被 Xtensa 工具链编译。
- 获得独立授权后执行受控烧录；设备重启后保持协议 v2、原配对、配置 `1/1` 与 Codex Focus 首页。
- 成功发送与焦点变化后的安全失败完成真人真机验收；当前失败原因文案精修只在源码中，尚未再次刷写。
- 当前源码以 ESP-IDF 5.5 完整构建通过，镜像为 `0x15a270`，3 MiB app 分区剩余 `0x1a5d90`（55%）；本轮未执行 flash。

## 本地收尾门（已完成）

形成 M3-B 本地检查点前的门禁结果：

1. [x] 完整运行 Python、Swift/App/DMG、固件和源码契约检查；
2. [x] 复核当前源码不会持久化 transcript、窗口标题、API Key 或录音路径；
3. [x] 确认验证过程未替换已安装 Bridge/HUD/Paste，也未刷写设备；
4. [x] 自动流程停在未提交状态，随后由使用者另行授权形成 M3-B + M3-C 本地联合检查点。
