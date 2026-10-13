#Requires -Version 7.0
<#
    停止屏幕亮度滚轮调节器
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$found = Get-BrightnessDaemon
if (-not $found) {
    '亮度调节器当前没有运行。'
    return
}
foreach ($p in $found) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    "已停止 pid=$($p.ProcessId)"
}
