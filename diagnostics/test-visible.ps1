$ErrorActionPreference = 'Stop'

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class Visible {
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
    public static string Desc = "";
    public static List<string> Trace = new List<string>();

    public static bool Enumerate() {
        Handle = IntPtr.Zero;
        Trace.Clear();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMon, IntPtr hdc, IntPtr r, IntPtr d) {
            uint n = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n) || n == 0) {
                Trace.Add("GetNumberOfPhysicalMonitors failed err=" + Marshal.GetLastWin32Error());
                return true;
            }
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) {
                Trace.Add("GetPhysicalMonitorsFromHMONITOR failed err=" + Marshal.GetLastWin32Error());
                return true;
            }
            for (int i = 0; i < n; i++) {
                uint t = 0, cur = 0, max = 0;
                bool ok = GetVCPFeatureAndVCPFeatureReply(arr[i].hPhysicalMonitor, 0x10, out t, out cur, out max);
                Trace.Add(string.Format("monitor[{0}] handle=0x{1:X} desc='{2}' vcp10 ok={3} cur={4} max={5}",
                    i, arr[i].hPhysicalMonitor.ToInt64(), arr[i].szPhysicalMonitorDescription, ok, cur, max));
                if (ok && Handle == IntPtr.Zero) { Handle = arr[i].hPhysicalMonitor; Desc = arr[i].szPhysicalMonitorDescription; }
            }
            return true;
        }, IntPtr.Zero);
        return Handle != IntPtr.Zero;
    }

    public static string Read() {
        uint t = 0, cur = 0, max = 0;
        bool ok = GetVCPFeatureAndVCPFeatureReply(Handle, 0x10, out t, out cur, out max);
        return string.Format("ok={0} cur={1} max={2}", ok, cur, max);
    }
    public static bool Write(uint v) { return SetVCPFeature(Handle, 0x10, v); }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

'=== 建立 DDC 连接（最多重试 8 次）==='
$connected = $false
foreach ($i in 1..8) {
    if ([Visible]::Enumerate()) { $connected = $true; "第 $i 次尝试：成功 desc='$([Visible]::Desc)'"; break }
    "第 $i 次尝试：失败 -> $([Visible]::Trace -join ' | ')"
    Start-Sleep -Seconds 1
}
if (-not $connected) { throw 'DDC/CI 链路一直不可用' }

"初始读数：$([Visible]::Read())"
''
'=== 可见测试：100 <-> 0 来回 3 轮，每档停 1.5 秒（共约 9 秒）==='
foreach ($round in 1..3) {
    foreach ($v in 100, 0) {
        $ok = [Visible]::Write([uint32]$v)
        Start-Sleep -Milliseconds 1500
        "第 $round 轮 写入 $v : setOk=$ok 回读 $([Visible]::Read())"
    }
}
''
'=== 复位为 100 ==='
[void][Visible]::Write(100)
Start-Sleep -Milliseconds 500
"最终读数：$([Visible]::Read())"
'测试结束'
