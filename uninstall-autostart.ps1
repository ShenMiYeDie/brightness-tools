#Requires -Version 7.0
<#
    取消开机自启（默认同时结束正在运行的实例，加 -KeepRunning 可保留）
#>
[CmdletBinding()]
param(
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

if (Test-Path $StartupVbs) {
    Remove-Item $StartupVbs -Force
    "已删除开机自启：$StartupVbs"
} else {
    "没有找到开机自启项：$StartupVbs"
}

if (-not $KeepRunning) {
    $found = Get-BrightnessDaemon
    foreach ($p in $found) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        "已停止运行中的实例 pid=$($p.ProcessId)"
    }
}
