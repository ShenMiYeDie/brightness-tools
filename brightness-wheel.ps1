#Requires -Version 7.0
<#
    屏幕亮度滚轮调节器 (brightness-wheel)
    ---------------------------------------------------------------
    手势：按住 Ctrl + Alt 滚动鼠标滚轮 -> 全局调整显示器亮度（DDC/CI）
          按住 Ctrl + Alt + Shift 滚动 = 精细调节（默认 1%）
    实现：低层鼠标钩子 (WH_MOUSE_LL) + DDC/CI (dxva2.dll) + WinForms OSD
    依赖：仅需 PowerShell 7，无需安装任何第三方软件
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
# 组件已预编译为 brightness-wheel.generated.dll：避免在常驻进程里加载 Roslyn 编译器
# 与 277 个参考程序集（实测那样会多占约 200MB 内存，启动也更慢）。
. (Join-Path $PSScriptRoot 'lib.ps1')

$csPath    = Join-Path $PSScriptRoot 'brightness-wheel.cs'
$dllPath   = Join-Path $PSScriptRoot 'brightness-wheel.generated.dll'
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
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-dll.ps1') | Out-Null
    } catch { Write-Warning "预编译失败：$($_.Exception.Message)" }
    if (Test-Path $dllPath) {
        try { Add-Type -Path $dllPath -ErrorAction Stop; $loaded = $true } catch { }
    }
}
if (-not $loaded) {
    # 最后兜底：就地编译（多占内存，但保证一定能用）
    Add-Type -TypeDefinition (Get-Content $csPath -Raw) -ReferencedAssemblies (Get-ComponentReferences) -ErrorAction Stop
}

[BrightnessWheel]::StepPercent     = $Step
[BrightnessWheel]::FineStepPercent = $FineStep
[BrightnessWheel]::MinPercent      = $Min
[BrightnessWheel]::MaxPercent      = $Max
[BrightnessWheel]::ReqCtrl         = -not $NoCtrl
[BrightnessWheel]::ReqAlt          = -not $NoAlt
[BrightnessWheel]::OsdHoldMs       = [int]($OsdSeconds * 1000)
[BrightnessWheel]::OsdEnabled      = -not $NoOsd
[BrightnessWheel]::UseTrayIcon     = -not $NoTray
[BrightnessWheel]::LogPath         = Join-Path $env:TEMP 'brightness-wheel.log'

[BrightnessWheel]::Run()
