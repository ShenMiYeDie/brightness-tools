#Requires -Version 7.0
# 测量常驻守护进程的资源占用、空闲 CPU、鼠标钩子开销、自启就绪耗时
$ErrorActionPreference = 'Stop'
$base = Split-Path $PSScriptRoot -Parent

function Get-Daemon {
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'luxwheel\.ps1' -and $_.CommandLine -match '\s-File\s' } |
        Select-Object -First 1
}

$d = Get-Daemon
if (-not $d) { throw '守护进程没在运行，先跑 start.ps1' }
$p = Get-Process -Id $d.ProcessId

function MB([double]$b) { '{0:N1} MB' -f ($b / 1MB) }

'=== 1. 常驻进程资源 ==='
"PID              : $($p.Id)"
"工作集(物理内存) : $(MB $p.WorkingSet64)"
"私有内存         : $(MB $p.PrivateMemorySize64)"
"虚拟内存         : $(MB $p.VirtualMemorySize64)"
"线程数           : $($p.Threads.Count)"
"句柄数           : $($p.HandleCount)"
"已运行           : $([math]::Round(((Get-Date) - $p.StartTime).TotalMinutes, 1)) 分钟"
"累计 CPU 时间    : $([math]::Round($p.TotalProcessorTime.TotalSeconds, 2)) 秒"
''

'=== 2. 空闲 20 秒的 CPU 消耗（含一次 15 秒健康检查）==='
$p.Refresh()
$t0 = $p.TotalProcessorTime.TotalMilliseconds
Start-Sleep -Seconds 20
$p.Refresh()
$t1 = $p.TotalProcessorTime.TotalMilliseconds
$delta = $t1 - $t0
"20 秒内消耗 CPU : $([math]::Round($delta,1)) 毫秒  (约 $([math]::Round($delta / 20000 * 100, 3))% 单核)"
''

'=== 3. 鼠标钩子开销：注入 6000 个鼠标移动事件 ==='
$code = @'
using System;
using System.Runtime.InteropServices;
public class MouseStub {
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, UIntPtr extra);
    public static void Nudge(int count) {
        const uint MOVE = 0x0001;
        for (int i = 0; i < count; i++) {
            mouse_event(MOVE, 1, 0, 0, UIntPtr.Zero);
            mouse_event(MOVE, -1, 0, 0, UIntPtr.Zero);
        }
    }
}
'@
Add-Type -TypeDefinition $code -Language CSharp
$p.Refresh()
$h0 = $p.TotalProcessorTime.TotalMilliseconds
[MouseStub]::Nudge(3000)     # 3000 对 = 6000 个事件
Start-Sleep -Milliseconds 500
$p.Refresh()
$h1 = $p.TotalProcessorTime.TotalMilliseconds
$hookDelta = $h1 - $h0
"6000 个鼠标事件消耗 CPU : $([math]::Round($hookDelta,1)) 毫秒"
"平均每个事件           : $([math]::Round($hookDelta / 6000 * 1000, 1)) 微秒"
''

'=== 4. 对照：一个什么都不做的 pwsh 进程 ==='
$idle = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 20' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
$idle.Refresh()
"空 pwsh 工作集   : $(MB $idle.WorkingSet64)"
"空 pwsh 私有内存 : $(MB $idle.PrivateMemorySize64)"
"本工具工作集     : $(MB $p.WorkingSet64)"
"差值(=工具自身)  : $(MB ($p.WorkingSet64 - $idle.WorkingSet64))"
Stop-Process -Id $idle.Id -Force -ErrorAction SilentlyContinue
''

'=== 5. 模拟开机自启的就绪耗时 ==='
$vbs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\luxwheel.vbs'
"自启文件：$vbs"
"存在：$(Test-Path $vbs)"
foreach ($x in (Get-Daemon)) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Remove-Item "$env:TEMP\luxwheel.log" -ErrorAction SilentlyContinue
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`""
$log = "$env:TEMP\luxwheel.log"
while ($sw.Elapsed.TotalSeconds -lt 30) {
    if ((Test-Path $log) -and ((Get-Content $log -Raw) -match 'hook installed')) { break }
    Start-Sleep -Milliseconds 100
}
$sw.Stop()
"从登录启动项被拉起 → 钩子就绪：$([math]::Round($sw.Elapsed.TotalSeconds, 2)) 秒"
$p2 = Get-Process -Id (Get-Daemon).ProcessId
"就绪后工作集：$(MB $p2.WorkingSet64)"
