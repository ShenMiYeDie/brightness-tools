#Requires -Version 7.0
<#
    luxwheel —— 启动（后台常驻、无窗口）

    示例：
      pwsh -File start.ps1                    # 默认每格 3%
      pwsh -File start.ps1 -Step 5 -Force     # 每格 5%，并重启已有实例
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
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'luxwheel-lib.ps1')

$arguments = Get-DaemonArgumentString -Step $Step -FineStep $FineStep -Min $Min -Max $Max `
    -OsdSeconds $OsdSeconds -NoOsd:$NoOsd -NoTray:$NoTray -NoCtrl:$NoCtrl -NoAlt:$NoAlt

$running = Get-BrightnessDaemon
if ($running -and -not $Force) {
    "亮度调节器已经在运行：pid=$(($running.ProcessId) -join ',')"
    "如需按新参数重启，请加 -Force。"
    return
}
if ($running -and $Force) {
    foreach ($p in $running) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
    "已停止旧实例"
}

# 组件编译放在停掉旧实例之后：运行中的进程会锁住 DLL，那时无法替换
& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'luxwheel-build.ps1') | Out-Null

New-LauncherVbs -Path $VbsPath -DaemonArgs $arguments
Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$VbsPath`""
Start-Sleep -Seconds 2

$p = Get-BrightnessDaemon
if ($p) {
    "亮度调节器已启动：pid=$(($p.ProcessId) -join ',')"
    "参数：$arguments"
    "手势：Ctrl + Alt + 滚轮（再加 Shift = 精细调节）"
} else {
    "启动失败。可前台运行以查看报错："
    "  pwsh -NoProfile -ExecutionPolicy Bypass -File `"$MainScript`" $arguments"
}
