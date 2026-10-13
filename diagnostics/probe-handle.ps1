$ErrorActionPreference = 'Stop'

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class HandleProbe {
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

    public static List<IntPtr> GetHandles() {
        List<IntPtr> list = new List<IntPtr>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMon, IntPtr hdc, IntPtr r, IntPtr d) {
            uint n = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n) || n == 0) return true;
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) return true;
            for (int i = 0; i < n; i++) list.Add(arr[i].hPhysicalMonitor);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static string Read(IntPtr h) {
        uint t = 0, cur = 0, max = 0;
        bool ok = GetVCPFeatureAndVCPFeatureReply(h, 0x10, out t, out cur, out max);
        return string.Format("ok={0} cur={1} max={2}", ok, cur, max);
    }
    public static bool Write(IntPtr h, uint v) { return SetVCPFeature(h, 0x10, v); }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

'=== A. 连续 25 次枚举，统计句柄有效性 ==='
$nullCount = 0
$validCount = 0
foreach ($i in 1..25) {
    $hs = [HandleProbe]::GetHandles()
    if ($hs.Count -eq 0) { "  #$i 没有枚举到物理显示器"; continue }
    foreach ($h in $hs) {
        $v = $h.ToInt64()
        $read = [HandleProbe]::Read($h)
        if ($v -eq 0) { $nullCount++; "  #$i handle=NULL  → 读取居然 $read" }
        else { $validCount++; "  #$i handle=0x$($v.ToString('X')) → 读取 $read" }
    }
    Start-Sleep -Milliseconds 250
}
"统计：有效句柄 $validCount 次，NULL 句柄 $nullCount 次"
''

'=== B. NULL 句柄写入是否为「假成功」 ==='
# 取一个有效句柄
$valid = $null
foreach ($i in 1..30) {
    $hs = [HandleProbe]::GetHandles()
    $valid = $hs | Where-Object { $_.ToInt64() -ne 0 } | Select-Object -First 1
    if ($valid) { break }
    Start-Sleep -Milliseconds 400
}
if (-not $valid) { '拿不到有效句柄，B 测试跳过'; return }
"有效句柄 = 0x$($valid.ToInt64().ToString('X'))，用它复位并读取："
[void][HandleProbe]::Write($valid, 100)
Start-Sleep -Milliseconds 800
"  有效句柄读取 = $([HandleProbe]::Read($valid))"

# 取一个 NULL 句柄
$nullH = [IntPtr]::Zero
$sawNull = $false
foreach ($i in 1..30) {
    $hs = [HandleProbe]::GetHandles()
    if ($hs | Where-Object { $_.ToInt64() -eq 0 }) { $sawNull = $true; break }
    Start-Sleep -Milliseconds 400
}
if (-not $sawNull) { '本次没能抓到 NULL 句柄，B 测试无法进行（说明 NULL 是偶发）'; return }
'(抓到 NULL 句柄) 用 NULL 句柄写入 10：'
"  SetVCPFeature(NULL, 10) = $([HandleProbe]::Write($nullH, 10))"
Start-Sleep -Milliseconds 800
"  NULL 句柄自己读取  = $([HandleProbe]::Read($nullH))"
"  有效句柄读取      = $([HandleProbe]::Read($valid))   <-- 若这里仍是 100，说明 NULL 写入是假成功"
''
'复位 100：'
[void][HandleProbe]::Write($valid, 100)
Start-Sleep -Milliseconds 800
"  有效句柄读取 = $([HandleProbe]::Read($valid))"
