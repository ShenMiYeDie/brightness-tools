#Requires -Version 7.0
<#
    命令行直接设置屏幕亮度（不改动后台守护进程的开关状态，仅用于测试/脚本调用）

    用法：
      pwsh -File set-brightness.ps1 -Percent 60
      pwsh -File set-brightness.ps1 -Get
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 100)][int]$Percent = -1,
    [switch]$Get
)

$ErrorActionPreference = 'Stop'

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class SetB {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprc, MonitorEnumProc cb, IntPtr data);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] a);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint cur, out uint max);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool SetMonitorBrightness(IntPtr h, uint v);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool DestroyPhysicalMonitors(uint n, [In] PHYSICAL_MONITOR[] a);

    public class Item { public IntPtr H; public uint Min; public uint Max; public uint Cur; public string Name; }

    public static List<Item> Enum() {
        List<Item> list = new List<Item>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMon, IntPtr hdc, IntPtr r, IntPtr d) {
            uint n = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n) || n == 0) return true;
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) return true;
            for (int i = 0; i < n; i++) {
                uint min = 0, cur = 0, max = 0;
                if (GetMonitorBrightness(arr[i].hPhysicalMonitor, out min, out cur, out max) && max > min) {
                    Item it = new Item();
                    it.H = arr[i].hPhysicalMonitor; it.Min = min; it.Max = max; it.Cur = cur;
                    it.Name = arr[i].szPhysicalMonitorDescription;
                    list.Add(it);
                }
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

$items = [SetB]::Enum()
if ($items.Count -eq 0) { throw '没有找到支持 DDC/CI 的显示器' }

foreach ($it in $items) {
    if (-not $Get -and $Percent -ge 0) {
        $raw = [uint32][Math]::Round($it.Min + ($it.Max - $it.Min) * $Percent / 100.0)
        $ok = [SetB]::SetMonitorBrightness($it.H, $raw)
    } else {
        $raw = $null; $ok = $null
    }
    Start-Sleep -Milliseconds 250
    $min = 0; $cur = 0; $max = 0
    [void][SetB]::GetMonitorBrightness($it.H, [ref]$min, [ref]$cur, [ref]$max)
    $pct = [Math]::Round(($cur - $min) * 100.0 / ($max - $min))
    if ($Get -or $Percent -lt 0) {
        "亮度 = $cur/$max  (约 $pct%)"
    } else {
        "请求 $Percent% -> 原始值 $raw，写入 $ok，读回 $cur/$max (约 $pct%)"
    }
}
