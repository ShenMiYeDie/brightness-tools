#Requires -Version 7.0
# 验证：新进程的首次枚举是否容易拿到 NULL 句柄；NULL 句柄写入是否为「假成功」
param([switch]$Once)

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class NP {
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
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool SetMonitorBrightness(IntPtr h, uint value);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint cur, out uint max);

    public static List<IntPtr> Enum() {
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
        return string.Format("ok={0} cur={1}", ok, cur);
    }
    public static string LegacyRead(IntPtr h) {
        uint min = 0, cur = 0, max = 0;
        bool ok = GetMonitorBrightness(h, out min, out cur, out max);
        return string.Format("ok={0} min={1} cur={2} max={3}", ok, min, cur, max);
    }
    public static bool Write(IntPtr h, uint v) { return SetVCPFeature(h, 0x10, v); }
    public static bool LegacyWrite(IntPtr h, uint v) { return SetMonitorBrightness(h, v); }
}
'@

Add-Type -TypeDefinition $code -Language CSharp

if ($Once) {
    # 单次：只做第一次枚举，若为 NULL 则做假成功测试
    $hs = [NP]::Enum()
    $first = if ($hs.Count -gt 0) { $hs[0] } else { [IntPtr]::Zero }
    $tag = if ($first.ToInt64() -eq 0) { 'NULL' } else { "0x$($first.ToInt64().ToString('X'))" }
    "first=$tag count=$($hs.Count)"

    if ($first.ToInt64() -eq 0 -and $hs.Count -gt 0) {
        # 再枚举一次拿有效句柄
        $valid = $null
        foreach ($i in 1..10) {
            $h2 = [NP]::Enum() | Where-Object { $_.ToInt64() -ne 0 } | Select-Object -First 1
            if ($h2) { $valid = $h2; break }
            Start-Sleep -Milliseconds 300
        }
        if ($valid) {
            $before = [NP]::Read($valid)
            $w1 = [NP]::Write($first, 7)
            $w2 = [NP]::LegacyWrite($first, 7)
            Start-Sleep -Milliseconds 700
            $nullRead = [NP]::Read($first)
            $validRead = [NP]::Read($valid)
            "  NULL写SetVCPFeature=$w1  NULL写SetMonitorBrightness=$w2"
            "  有效句柄写入前=$before"
            "  NULL句柄自读=$nullRead"
            "  有效句柄读=$validRead   <-- 若仍为原值，证明 NULL 写入是假成功"
            [void][NP]::Write($valid, [uint32]100)
        } else {
            "  拿不到有效句柄做对照"
        }
    }
    return
}

# 默认：跑 10 个全新进程，各做一次首次枚举
$script = $PSCommandPath
$nullFirst = 0
$validFirst = 0
$proof = @()
foreach ($i in 1..10) {
    $out = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $script -Once 2>&1
    $out | ForEach-Object { "  [进程 $i] $_" }
    $firstLine = ($out | Where-Object { $_ -like 'first=*' }) -join ''
    if ($firstLine -like '*first=NULL*') { $nullFirst++ } else { $validFirst++ }
    $proofLine = ($out | Where-Object { $_ -like '*有效句柄读=*' }) -join ''
    if ($proofLine) { $proof += "[进程 $i] $proofLine" }
}
''
"首次枚举统计：NULL=$nullFirst  有效=$validFirst  （共 10 个新进程）"
if ($proof) { '假成功证据：'; $proof | ForEach-Object { "  $_" } } else { '本轮没抓到 NULL 首次枚举，无法给出假成功证据' }
