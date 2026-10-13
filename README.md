# luxwheel

**按住 `Ctrl + Alt` 滚动鼠标滚轮，就能调节屏幕亮度。**

Windows 桌面小工具：用滚轮代替伸手去按显示器上的按钮，通过 **DDC/CI** 直接控制外接显示器的
**背光亮度**，屏幕底部浮出亮度提示条，右下角带托盘图标。纯 PowerShell 7 + 内嵌 C# 实现，
**不需要安装任何第三方软件**。

常驻占用：工作集约 **115–135 MB**（随使用浮动，其中约 81 MB 是 PowerShell 运行时本身）、
私有内存约 **37 MB**、空闲 CPU **0%**、登录后就绪 **0.67 秒**。

> **关键词**：屏幕亮度 · 显示器亮度 · 调亮度 · 调光 · 滚轮调光 · 鼠标滚轮 · 亮度快捷键 ·
> 护眼 · 夜间 · 外接显示器背光 · 亮度提示条 · 托盘 · 开机自启 · 免按显示器按钮 · 多显示器
> **keywords**: monitor brightness, screen brightness, dim screen, dimmer, brightness control,
> brightness slider, mouse wheel brightness, scroll wheel, DDC/CI, DDC-CI, MCCS, VCP 0x10,
> dxva2, external monitor backlight, Windows brightness shortcut, HDR, PowerShell 7, tray, OSD

实测环境：ASUS 台式机 · RTX 4070 Ti SUPER · KTC P27A6V-PRO（3840×2160@160Hz，150% 缩放，**HDR 开启**）
· Windows 11 25H2 (build 26200) · PowerShell 7.6

![亮度提示条](osd-shot.png)

---

## 用法

| 操作 | 效果 |
| --- | --- |
| `Ctrl + Alt` + 滚轮上/下 | 亮度 ±3% |
| `Ctrl + Alt + Shift` + 滚轮 | 精细调节，±1% |
| 屏幕底部提示条 | 显示当前亮度百分比与进度条（约 1.3 秒后淡出）|
| 托盘图标右键 | 显示当前亮度 / 重新检测显示器 / 退出 |

鼠标在屏幕任意位置滚动都生效；这个组合的滚轮事件会被本工具吞掉，不会同时传给前台程序。

## 快速开始

```powershell
$t = 'D:\Projects\computer-work\luxwheel'      # 换成你的实际目录

pwsh -File $t\install-autostart.ps1            # 安装开机自启（并立即启动）
pwsh -File $t\start.ps1                        # 或只启动：后台常驻、无窗口
pwsh -File $t\start.ps1 -Step 5 -Force         # 每格 5%，并重启已有实例
pwsh -File $t\stop.ps1                         # 停止
pwsh -File $t\uninstall-autostart.ps1          # 取消开机自启并停止
```

辅助命令：

```powershell
pwsh -File $t\set-brightness.ps1 -Get                   # 读当前亮度（独立于守护进程）
pwsh -File $t\set-brightness.ps1 -Percent 60            # 直接设成 60%
pwsh -File $t\test-wheel.ps1 -Notches 3 -Direction down # 自检：注入滚轮 → 读回 → 截图
```

## 参数

> 参数只影响本次启动；要让改动在开机自启后依然生效，请用 `install-autostart.ps1`
> 带同样的参数重新安装一次。

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-Step` | 3 | 每格滚轮改变多少个百分点 |
| `-FineStep` | 1 | 加 Shift 后的精细步进 |
| `-Min` / `-Max` | 0 / 100 | 允许的亮度范围（如 `-Min 20` 防止调太黑）|
| `-OsdSeconds` | 1.3 | 提示条停留秒数 |
| `-NoOsd` | — | 关闭屏幕提示条 |
| `-NoTray` | — | 不显示托盘图标 |
| `-NoCtrl` / `-NoAlt` | — | 去掉 Ctrl / Alt 修饰键要求 |

## 开机自启与卸载

登录时由「启动」文件夹里的一个 VBS 拉起（普通用户权限，**不是**系统服务、不是计划任务、
不需要管理员）：

```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\luxwheel.vbs
```

只在**当前用户登录后**启动；从被拉起到滚轮生效实测 **0.67 秒**。
卸载：`pwsh -File uninstall-autostart.ps1`（顺带停止进程；也会清理改名前的旧自启项）。

## 可靠性设计（DDC/CI 的坑都处理了）

`dxva2.dll` 有几个反直觉行为：

1. **假成功**：句柄失效后 `SetMonitorBrightness` 仍返回 `TRUE`，读回值也跟着变，
   显示器实际却没动 —— 表现为"提示条显示 0% 而屏幕依旧很亮"。
   → 每次写入后都**读回校验**；不一致就**重建 DDC 句柄并重试**；仍不成功时提示条直接
   显示橙色「调光未生效」，绝不假装成功。
2. **句柄会失效**：显示器睡眠唤醒、切换分辨率/刷新率/HDR、切输入源之后，旧句柄会失效。
   → 后台每 15 秒做一次空闲健康检查：读不通就重建句柄；读到设备值与本工具内部值不一致
   就自动同步（例如你用显示器菜单改过亮度，下一次滚轮会从真实值继续）。
3. **首次枚举拿到 NULL 句柄是常态**（实测 10/10 个新进程如此），但该句柄可用，
   因此不做 NULL 过滤，只以"能否读回"为准。

## 兼容性

**能用**：支持 DDC/CI 的外接显示器（DisplayPort / HDMI / DVI / VGA），绝大多数台式显示器都支持。
本项目在 KTC P27A6V-PRO（DP 接口，4K@160Hz，**HDR 开启**）实测有效。

**可能需要先手动打开**：部分显示器的 OSD 菜单里有 `DDC/CI` 开关，出厂关闭时本工具无效。

**用不了或需注意**：

| 设备 | 情况 |
| --- | --- |
| 笔记本内屏（eDP） | 内屏不走 DDC/CI，需要 WMI 的 `WmiSetBrightness` 通道，本项目**尚未实现** |
| 虚拟显示器 / DisplayLink USB 扩展坞 | 没有 DDC 通道，会被自动过滤，不会报错 |
| 电视 / 投影仪 | 部分机型不实现 MCCS 亮度指令（VCP 0x10），能被识别但写入无效，此时提示条显示「调光未生效」|
| macOS / Linux | `dxva2.dll` 是 Windows 专有接口，不可移植 |
| Windows PowerShell 5.1 | 脚本会明确拒绝运行（需要 PowerShell 7）|

**多显示器**：同时调节所有支持 DDC/CI 的显示器（各自按量程换算百分比），不支持只调其中一块。

**控制通道**：优先用传统 `SetMonitorBrightness`，不可用时自动退回 MCCS 标准的 `VCP 0x10`
（实测 legacy 通道出现过瞬时失败，只认 legacy 会导致一个显示器都识别不到）。可强制指定：

```powershell
$env:LUXWHEEL_CHANNEL = 'vcp'      # 或 'legacy'；不设 = 自动
pwsh -File start.ps1 -Force
```

启动日志里会打印每台显示器实际使用的通道，方便在别的机器上排查：

```
start: monitors=1 initialPct=100 step=3 osd=True tray=True
  monitor: Generic PnP Monitor channel=legacy min=0 max=100 cur=100
```

## 改动代码后怎么生效

`luxwheel.cs` 改完直接 `start.ps1 -Force` 即可：它会**先停掉旧进程、再重编组件、然后启动**。
顺序很重要 —— 运行中的进程会把 DLL 映射进内存并锁住它，此时既删不掉也覆盖不了；
若在守护进程运行时单独执行 `luxwheel-build.ps1`，它会跳过重编并提示"下次启动会自动重编"。

组件在以下情况都会自动重编：源码改动、PowerShell 升级、DLL 丢失或损坏（指纹里含 DLL 自身哈希）。

## 日志与排查

`%TEMP%\luxwheel.log`：启动、每次调光、写入未生效、句柄重建、空闲同步都有记录。
排查顺序建议：

1. 看日志尾部有没有 `写入未生效` / `空闲检查：句柄已失效，重建`；
2. 提示条是否显示橙色「调光未生效」（说明 DDC 通道没响应，多半是显示器关了 DDC/CI，
   或睡眠唤醒后句柄失效）；
3. 用 `set-brightness.ps1 -Get` 独立读一次，确认显示器本身是否响应。

## 文件

| 文件 | 作用 |
| --- | --- |
| `luxwheel.ps1` | 主程序入口：加载组件、注入参数、启动守护进程 |
| `luxwheel.cs` | 全部实现（鼠标钩子 + DDC/CI + 校验自愈 + 提示条 + 托盘）|
| `luxwheel.generated.dll` | 上面那个源文件预编译出的组件（自动生成，可随时删除）|
| `luxwheel-build.ps1` | 编译组件（已是最新则瞬间跳过）|
| `luxwheel-lib.ps1` | 公共函数（查找进程、生成启动器、组件指纹与编译引用）|
| `start.ps1` / `stop.ps1` | 启动 / 停止 |
| `install-autostart.ps1` / `uninstall-autostart.ps1` | 开机自启的安装与卸载 |
| `set-brightness.ps1` | 命令行读写亮度（脚本可用）|
| `test-wheel.ps1` | 端到端自检：注入滚轮手势、读回亮度、截图 |
| `luxwheel-launch.vbs` | 自动生成的无窗口启动器（自启用）|
| `diagnostics/` | 排查用探测脚本（DDC 能力、HDR 状态、句柄行为、资源测量等）|
| `LICENSE` | MIT 许可 |

## 原理与限制

- 亮度走显示器自带的 DDC/CI 通道，等同显示器 OSD 菜单里的亮度，**不改变画面内容**，
  与 HDR / 全屏游戏无冲突。
- 因为调的是背光，**截图和录屏里看不到实际变暗**，这是正常现象。
- 需要显示器在 OSD 里开启 DDC/CI。若失效，先在显示器菜单确认该选项，或右键托盘图标
  「重新检测显示器」。
- 笔记本内屏走的是另一套 WMI 接口，本项目只实现 DDC/CI 路径。
- 常驻一个隐藏的 pwsh 进程与一个托盘图标；鼠标钩子对每个鼠标事件的平均处理耗时为
  **15.6 微秒**（1000Hz 鼠标持续狂甩约合单核 1.5%）。

## 许可

[MIT](LICENSE) —— 随便用、随便改、随便分发、可商用，保留版权声明即可。
