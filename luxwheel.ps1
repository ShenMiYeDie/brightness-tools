#Requires -Version 7.0
<#
    luxwheel —— 用鼠标滚轮调节显示器亮度（Windows / DDC-CI）
    ==========================================================================
    按住 Ctrl + Alt 滚动鼠标滚轮，即可全局调节外接显示器的背光亮度，不必再去
    按显示器上的按钮。屏幕底部浮出亮度提示条，右下角托盘可查看/退出/重新检测。

    --------------------------------------------------------------------------
    关键词（方便搜索到这个工具 / search keywords）
      中文：屏幕亮度 显示器亮度 调亮度 调光 亮度调节 亮度快捷键 滚轮调光
            鼠标滚轮 护眼 夜间 外接显示器 显示器背光 亮度条 提示条
            开机自启 托盘图标 免按显示器按钮 台式机 多显示器
      英文：monitor brightness, screen brightness, dim screen, dimmer,
            brightness control, brightness slider, mouse wheel brightness,
            scroll wheel brightness, Ctrl+Alt+wheel, DDC/CI, DDC-CI, MCCS,
            VCP 0x10, dxva2, external monitor backlight, Windows brightness
            shortcut, HDR compatible, PowerShell 7, tray icon, OSD, autostart

    实现：低层鼠标钩子 (WH_MOUSE_LL) + DDC/CI (dxva2.dll) + WinForms 提示条
    依赖：仅需 PowerShell 7；首次运行会把 luxwheel.cs 编译为 luxwheel.generated.dll
    文档：同目录 README.md（兼容性、资源占用、故障排查都在里面）
#>
[CmdletBinding()]
param(
    # 每格滚轮改变的亮度百分比
    [ValidateRange(1, 25)][int]$Step = 3,
    # Ctrl+Alt+Shift+滚轮 的精细步进
    [ValidateRange(1, 25)][int]$FineStep = 1,
    # 允许的最低 / 最高亮度百分比
    [ValidateRange(0, 100)][int]$Min = 0,
    [ValidateRange(0, 100)][int]$Max = 100,
    # OSD 停留时间（秒）
    [ValidateRange(0.2, 10)][double]$OsdSeconds = 1.3,
    # 滚轮手势是否需要 Ctrl / Alt
    [switch]$NoCtrl,
    [switch]$NoAlt,
    # 关闭屏幕提示条 / 关闭托盘图标
    [switch]$NoOsd,
    [switch]$NoTray
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Core') {
    throw '请用 PowerShell 7 (pwsh.exe) 运行本脚本，Windows PowerShell 5.1 不受支持。'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ================= 载入 C# 组件 =================
# 组件已预编译为 luxwheel.generated.dll：避免在常驻进程里加载 Roslyn 编译器
# 与 277 个参考程序集（实测那样会多占约 200MB 内存，启动也更慢）。
. (Join-Path $PSScriptRoot 'luxwheel-lib.ps1')

$csPath    = Join-Path $PSScriptRoot 'luxwheel.cs'
$dllPath   = Join-Path $PSScriptRoot 'luxwheel.generated.dll'
$stampPath = "$dllPath.stamp"

$loaded = $false
if (Test-ComponentFresh -SourceFile $csPath -DllPath $dllPath) {
    try { Add-Type -Path $dllPath -ErrorAction Stop; $loaded = $true }
    catch {
        Write-Warning "载入已编译组件失败，将重新编译：$($_.Exception.Message)"
        # 可能是文件损坏或被占用，删掉让下面的流程重编
        Remove-Item $dllPath, $stampPath -ErrorAction SilentlyContinue
    }
}
if (-not $loaded) {
    # 交给短命子进程编译，编译器的内存不进常驻进程
    try {
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'luxwheel-build.ps1') | Out-Null
    } catch { Write-Warning "预编译失败：$($_.Exception.Message)" }
    if (Test-Path $dllPath) {
        try { Add-Type -Path $dllPath -ErrorAction Stop; $loaded = $true } catch { }
    }
}
if (-not $loaded) {
    # 最后兜底：就地编译（多占内存，但保证一定能用）
    Add-Type -TypeDefinition (Get-Content $csPath -Raw) -ReferencedAssemblies (Get-ComponentReferences) -ErrorAction Stop
}

[Luxwheel]::StepPercent     = $Step
[Luxwheel]::FineStepPercent = $FineStep
[Luxwheel]::MinPercent      = $Min
[Luxwheel]::MaxPercent      = $Max
[Luxwheel]::ReqCtrl         = -not $NoCtrl
[Luxwheel]::ReqAlt          = -not $NoAlt
[Luxwheel]::OsdHoldMs       = [int]($OsdSeconds * 1000)
[Luxwheel]::OsdEnabled      = -not $NoOsd
[Luxwheel]::UseTrayIcon     = -not $NoTray
[Luxwheel]::LogPath         = Join-Path $env:TEMP 'luxwheel.log'

[Luxwheel]::Run()
