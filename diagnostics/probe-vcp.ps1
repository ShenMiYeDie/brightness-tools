$ErrorActionPreference = 'Stop'

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class Vcp {
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
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint cur, out uint max);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetCapabilitiesStringLength(IntPtr h, out uint len);
    [DllImport("dxva2.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, [Out] StringBuilder buf, uint len);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool DestroyPhysicalMonitors(uint n, [In] PHYSICAL_MONITOR[] a);

    public static List<IntPtr> Handles = new List<IntPtr>();
    public static List<string> Descs = new List<string>();

    public static void Enumerate() {
        Handles.Clear(); Descs.Clear();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMon, IntPtr hdc, IntPtr r, IntPtr d) {
            uint n = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n) || n == 0) return true;
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) return true;
            for (int i = 0; i < n; i++) {
                uint min = 0, cur = 0, max = 0;
                bool ok = GetMonitorBrightness(arr[i].hPhysicalMonitor, out min, out cur, out max);
                int err = Marshal.GetLastWin32Error();
                Handles.Add(arr[i].hPhysicalMonitor);
                Descs.Add(arr[i].szPhysicalMonitorDescription + " | GetMonitorBrightness ok=" + ok + " min=" + min + " cur=" + cur + " max=" + max + " err=" + err);
            }
            return true;
        }, IntPtr.Zero);
    }

    public static string Capabilities(IntPtr h) {
        uint len = 0;
        if (!GetCapabilitiesStringLength(h, out len) || len == 0) return "(能力字符串读取失败 err=" + Marshal.GetLastWin32Error() + ")";
        StringBuilder sb = new StringBuilder((int)len + 2);
        if (!CapabilitiesRequestAndCapabilitiesReply(h, sb, len + 2)) return "(能力字符串请求失败 err=" + Marshal.GetLastWin32Error() + ")";
        return sb.ToString();
    }

    public static string VcpValue(IntPtr h, byte code) {
        uint type = 0, cur = 0, max = 0;
        bool ok = GetVCPFeatureAndVCPFeatureReply(h, code, out type, out cur, out max);
        return string.Format("VCP 0x{0:X2}: ok={1} type={2} cur={3} max={4} err={5}", code, ok, type, cur, max, Marshal.GetLastWin32Error());
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

[Vcp]::Enumerate()
"physical monitors with brightness: $([Vcp]::Handles.Count)"
$i = 0
foreach ($h in [Vcp]::Handles) {
    ""
    "=== monitor #$i  desc='$([Vcp]::Descs[$i])' ==="
    "--- MCCS capability string ---"
    [Console]::Out.WriteLine([Vcp]::Capabilities($h))
    "--- VCP values ---"
    foreach ($c in 0x10, 0x12, 0x60, 0x6C, 0xD6, 0xDF, 0xAC, 0x0B) {
        [Console]::Out.WriteLine([Vcp]::VcpValue($h, [byte]$c))
    }
    $i++
}
