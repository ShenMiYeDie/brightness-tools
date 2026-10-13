#Requires -Version 7.0
<#
    luxwheel —— 停止正在运行的实例
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'luxwheel-lib.ps1')

$found = Get-BrightnessDaemon
if (-not $found) {
    '亮度调节器当前没有运行。'
    return
}
foreach ($p in $found) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    "已停止 pid=$($p.ProcessId)"
}
