$ErrorActionPreference = 'Stop'

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class DdcInfo {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left; public int top; public int right; public int bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfoW(IntPtr hMonitor, ref MONITORINFOEX info);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint size, [Out] PHYSICAL_MONITOR[] arr);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint cur, out uint max);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool SetMonitorBrightness(IntPtr h, uint value);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool DestroyPhysicalMonitors(uint size, [In] PHYSICAL_MONITOR[] arr);

    public static List<string> Lines = new List<string>();
    public static List<IntPtr> Handles = new List<IntPtr>();
    public static List<string> Descs = new List<string>();
    public static bool KeepHandles = false;

    public static void Enumerate() {
        Lines.Clear(); Handles.Clear(); Descs.Clear();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero);
    }

    static bool Callback(IntPtr hMonitor, IntPtr hdc, IntPtr lprcMonitor, IntPtr dwData) {
        MONITORINFOEX mi = new MONITORINFOEX();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
        string dev = "?";
        string rect = "?";
        if (GetMonitorInfoW(hMonitor, ref mi)) {
            dev = mi.szDevice;
            rect = string.Format("{0},{1} {2}x{3} flags=0x{4:X}", mi.rcMonitor.left, mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, mi.dwFlags);
        }
        uint n = 0;
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMonitor, out n)) {
            Lines.Add(string.Format("{0} [{1}] physical-monitor query failed err={2}", dev, rect, Marshal.GetLastWin32Error()));
            return true;
        }
        PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
        if (!GetPhysicalMonitorsFromHMONITOR(hMonitor, n, arr)) {
            Lines.Add(string.Format("{0} [{1}] GetPhysicalMonitors failed err={2}", dev, rect, Marshal.GetLastWin32Error()));
            return true;
        }
        for (int i = 0; i < n; i++) {
            uint min = 0, cur = 0, max = 0;
            bool ok = GetMonitorBrightness(arr[i].hPhysicalMonitor, out min, out cur, out max);
            Lines.Add(string.Format("{0} [{1}] #{2} desc='{3}' brightnessOk={4} min={5} cur={6} max={7}",
                dev, rect, i, arr[i].szPhysicalMonitorDescription, ok, min, cur, max));
            if (ok) { Handles.Add(arr[i].hPhysicalMonitor); Descs.Add(arr[i].szPhysicalMonitorDescription); }
        }
        if (!KeepHandles) DestroyPhysicalMonitors(n, arr);
        return true;
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

[DdcInfo]::KeepHandles = $true
[DdcInfo]::Enumerate()
"=== displays with brightness support ==="
[DdcInfo]::Lines | ForEach-Object { $_ }
"handle count: $([DdcInfo]::Handles.Count)"

if ([DdcInfo]::Handles.Count -gt 0) {
    $h = [DdcInfo]::Handles[0]
    $min = 0; $cur = 0; $max = 0
    [void][DdcInfo]::GetMonitorBrightness($h, [ref]$min, [ref]$cur, [ref]$max)
    "before: $cur"
    $target = 82
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $setOk = [DdcInfo]::SetMonitorBrightness($h, $target)
    $sw.Stop()
    Start-Sleep -Milliseconds 400
    $a = 0; $b = 0; $c = 0
    [void][DdcInfo]::GetMonitorBrightness($h, [ref]$a, [ref]$b, [ref]$c)
    "setOk=$setOk elapsedMs=$($sw.ElapsedMilliseconds) readback=$b"
    [void][DdcInfo]::SetMonitorBrightness($h, $cur)
    Start-Sleep -Milliseconds 400
    $x = 0; $y = 0; $z = 0
    [void][DdcInfo]::GetMonitorBrightness($h, [ref]$x, [ref]$y, [ref]$z)
    "restored to: $y"
}
