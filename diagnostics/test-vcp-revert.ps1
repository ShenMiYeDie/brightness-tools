$ErrorActionPreference = 'Stop'

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class Sweep {
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
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n) || n == 0) {
                Trace.Add("HMONITOR: GetNumberOfPhysicalMonitors failed n=" + n + " err=" + Marshal.GetLastWin32Error());
                return true;
            }
            Trace.Add("HMONITOR: physical monitors = " + n);
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) {
                Trace.Add("GetPhysicalMonitorsFromHMONITOR failed err=" + Marshal.GetLastWin32Error());
                return true;
            }
            if (Handle == IntPtr.Zero) Handle = arr[0].hPhysicalMonitor;
            Trace.Add("handle acquired = " + (Handle != IntPtr.Zero));
            return true;
        }, IntPtr.Zero);
        return Handle != IntPtr.Zero;
    }

    public static string Read(byte code) {
        uint type = 0, cur = 0, max = 0;
        bool ok = GetVCPFeatureAndVCPFeatureReply(Handle, code, out type, out cur, out max);
        return string.Format("ok={0} cur={1} max={2}", ok, cur, max);
    }

    public static bool Write(byte code, uint value) { return SetVCPFeature(Handle, code, value); }

    public static bool LegacyWrite(uint value) {
        return SetVCPBrightness(Handle, value);
    }
    [DllImport("dxva2.dll", SetLastError = true, EntryPoint = "SetMonitorBrightness")]
    static extern bool SetVCPBrightness(IntPtr h, uint value);

    public static bool LegacyRead(out uint min, out uint cur, out uint max) {
        return GetMonitorBrightness(Handle, out min, out cur, out max);
    }
    [DllImport("dxva2.dll", SetLastError = true, EntryPoint = "GetMonitorBrightness")]
    static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint cur, out uint max);
}
'@

Add-Type -TypeDefinition $code -Language CSharp

if (-not [Sweep]::Enumerate()) {
    '枚举轨迹：'
    [Sweep]::Trace | ForEach-Object { "  $_" }
    throw '没有找到支持 DDC/CI 的显示器'
}

function Show([string]$label, [byte]$code) {
    "{0,-42} {1}" -f $label, [Sweep]::Read($code)
}

'=== 1. 初始状态 ==='
Show 'VCP 0x10 (亮度)' 0x10
Show 'VCP 0x12 (对比度)' 0x12
''
'=== 2. 写入 亮度 = 10 (VCP 0x10) ==='
"SetVCPFeature(0x10, 10) -> $([Sweep]::Write(0x10, 10))"
Start-Sleep -Milliseconds 300
Show '写入后 +0.3s' 0x10
Start-Sleep -Seconds 2
Show '写入后 +2.3s' 0x10
Start-Sleep -Seconds 5
Show '写入后 +7.3s' 0x10
''
'=== 3. 再用传统 API SetMonitorBrightness(10) ==='
"SetMonitorBrightness(10) -> $([Sweep]::LegacyWrite(10))"
Start-Sleep -Milliseconds 300
Show '写入后 +0.3s' 0x10
Start-Sleep -Seconds 3
Show '写入后 +3.3s' 0x10
''
'=== 4. 复位为 100 ==='
"SetVCPFeature(0x10, 100) -> $([Sweep]::Write(0x10, 100))"
Start-Sleep -Milliseconds 500
Show '复位后' 0x10
