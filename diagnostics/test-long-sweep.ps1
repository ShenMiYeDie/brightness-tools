$ErrorActionPreference = 'Stop'

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class LongSweep {
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
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint cur, out uint max);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

    public static IntPtr Handle = IntPtr.Zero;
    public static List<string> Trace = new List<string>();

    public static bool Enumerate() {
        Handle = IntPtr.Zero;
        Trace.Clear();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMon, IntPtr hdc, IntPtr r, IntPtr d) {
            uint n = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n) || n == 0) return true;
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) return true;
            for (int i = 0; i < n; i++) {
                Trace.Add(string.Format("monitor[{0}] handle=0x{1:X} desc='{2}'", i,
                    arr[i].hPhysicalMonitor.ToInt64(), arr[i].szPhysicalMonitorDescription));
                if (arr[i].hPhysicalMonitor != IntPtr.Zero && Handle == IntPtr.Zero)
                    Handle = arr[i].hPhysicalMonitor;
            }
            return true;
        }, IntPtr.Zero);
        return Handle != IntPtr.Zero;
    }

    public static string Read() {
        uint t = 0, cur = 0, max = 0;
        bool ok = GetVCPFeatureAndVCPFeatureReply(Handle, 0x10, out t, out cur, out max);
        return string.Format("ok={0} cur={1}", ok, cur);
    }
    public static bool Write(uint v) { return SetVCPFeature(Handle, 0x10, v); }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

$log = Join-Path $env:TEMP 'luxwheel-sweep.log'
function W([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m
    $line
    Add-Content -Path $log -Value $line
}

Set-Content -Path $log -Value "=== 长扫描开始 $(Get-Date -Format 'HH:mm:ss') ==="

$ok = $false
foreach ($i in 1..10) {
    if ([LongSweep]::Enumerate()) { $ok = $true; W "拿到有效句柄（第 $i 次尝试）"; break }
    Start-Sleep -Milliseconds 800
}
if (-not $ok) {
    W "拿不到有效句柄，轨迹：$([LongSweep]::Trace -join ' | ')"
    W "（注意：句柄为 0x0 时 dxva2 仍会返回成功，此时写入可能根本没到这台显示器）"
    return
}

W "初始：$([LongSweep]::Read())"
foreach ($round in 1..5) {
    [void][LongSweep]::Write(15)
    W "第 $round 轮 -> 写入 15，回读 $([LongSweep]::Read())"
    Start-Sleep -Seconds 4
    [void][LongSweep]::Write(100)
    W "第 $round 轮 -> 写入 100，回读 $([LongSweep]::Read())"
    Start-Sleep -Seconds 3
}
[void][LongSweep]::Write(100)
Start-Sleep -Milliseconds 500
W "结束，复位 100：$([LongSweep]::Read())"
