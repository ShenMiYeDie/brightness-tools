#Requires -Version 7.0
<#
    luxwheel —— 取消开机自启（默认同时结束正在运行的实例，加 -KeepRunning 保留）
#>
[CmdletBinding()]
param(
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'luxwheel-lib.ps1')

if (Test-Path $StartupVbs) {
    Remove-Item $StartupVbs -Force
    "已删除开机自启：$StartupVbs"
} else {
    "没有找到开机自启项：$StartupVbs"
}

# 旧版本（改名之前叫 brightness-wheel）留下的自启项也顺手清掉
$legacyVbs = Join-Path $StartupDir 'brightness-wheel.vbs'
if (Test-Path $legacyVbs) {
    Remove-Item $legacyVbs -Force
    "已删除旧版自启项：$legacyVbs"
}

if (-not $KeepRunning) {
    $found = Get-BrightnessDaemon
    foreach ($p in $found) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        "已停止运行中的实例 pid=$($p.ProcessId)"
    }
}
