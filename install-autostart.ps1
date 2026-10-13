#Requires -Version 7.0
<#
    luxwheel —— 安装开机自启（往「启动」文件夹写一个无窗口的 VBS）

    示例：
      pwsh -File install-autostart.ps1
      pwsh -File install-autostart.ps1 -Step 5 -NoTray
      pwsh -File install-autostart.ps1 -NoStart      # 只写自启，不立即启动
#>
[CmdletBinding()]
param(
    [int]$Step = 3,
    [int]$FineStep = 1,
    [int]$Min = 0,
    [int]$Max = 100,
    [double]$OsdSeconds = 1.3,
    [switch]$NoOsd,
    [switch]$NoTray,
    [switch]$NoCtrl,
    [switch]$NoAlt,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'luxwheel-lib.ps1')

$arguments = Get-DaemonArgumentString -Step $Step -FineStep $FineStep -Min $Min -Max $Max `
    -OsdSeconds $OsdSeconds -NoOsd:$NoOsd -NoTray:$NoTray -NoCtrl:$NoCtrl -NoAlt:$NoAlt

# 启动器同时写两份：一份在工具目录（供手动启动），一份在启动文件夹（开机自启）
New-LauncherVbs -Path $VbsPath -DaemonArgs $arguments
New-LauncherVbs -Path $StartupVbs -DaemonArgs $arguments

"已写入开机自启：$StartupVbs"
"启动参数：$arguments"

if (-not $NoStart) {
    $running = Get-BrightnessDaemon
    foreach ($p in $running) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($running) { Start-Sleep -Milliseconds 600 }
}

# 先把 C# 组件编译好（此时进程已停，DLL 不会被占用），这样登录自启时不必现场编译
& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'luxwheel-build.ps1') | Out-Null

if (-not $NoStart) {
    Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$VbsPath`""
    Start-Sleep -Seconds 2
    $p = Get-BrightnessDaemon
    if ($p) { "已在后台启动：pid=$(($p.ProcessId) -join ',')" }
    else { "启动失败，请手动运行 start.ps1 查看报错。" }
}

"卸载方法：pwsh -File uninstall-autostart.ps1"
