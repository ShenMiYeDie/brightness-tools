$ErrorActionPreference = 'Stop'

$code = @'
using System;
using System.Runtime.InteropServices;

public class DdcProbe {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint size, [Out] PHYSICAL_MONITOR[] arr);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint cur, out uint max);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetMonitorCapabilities(IntPtr h, out uint caps, out uint colorTemps);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool DestroyPhysicalMonitors(uint size, [In] PHYSICAL_MONITOR[] arr);
}
'@

Add-Type -TypeDefinition $code -Language CSharp

$results = New-Object System.Collections.ArrayList
$index = 0

$callback = [DdcProbe+MonitorEnumProc]{
    param([IntPtr]$hMonitor, [IntPtr]$hdc, [ref]$rect, [IntPtr]$data)

    $script:index++
    $n = 0
    $out = New-Object System.Collections.ArrayList
    [void][System.Collections.ArrayList]
    if ([DdcProbe]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$n)) {
        $arr = New-Object 'DdcProbe+PHYSICAL_MONITOR[]' $n
        if ([DdcProbe]::GetPhysicalMonitorsFromHMONITOR($hMonitor, $n, $arr)) {
            for ($i = 0; $i -lt $n; $i++) {
                $h = $arr[$i].hPhysicalMonitor
                $desc = $arr[$i].szPhysicalMonitorDescription
                $min = 0; $cur = 0; $max = 0
                $caps = 0; $ct = 0
                $capOk = [DdcProbe]::GetMonitorCapabilities($h, [ref]$caps, [ref]$ct)
                $bOk = [DdcProbe]::GetMonitorBrightness($h, [ref]$min, [ref]$cur, [ref]$max)
                $line = "HMONITOR#$($script:index) desc='$desc' caps=0x$('{0:X}' -f $caps) capOk=$capOk brightnessOk=$bOk min=$min cur=$cur max=$max rect=$($rect.left),$($rect.top),$($rect.right),$($rect.bottom)"
                [void]$script:results.Add($line)
            }
            [void][DdcProbe]::DestroyPhysicalMonitors($n, $arr)
        } else {
            [void]$script:results.Add("HMONITOR#$($script:index) GetPhysicalMonitorsFromHMONITOR failed err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())")
        }
    } else {
        [void]$script:results.Add("HMONITOR#$($script:index) GetNumberOfPhysicalMonitors failed err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())")
    }
    return $true
}

[void][DdcProbe]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $callback, [IntPtr]::Zero)

"=== DDC/CI probe ==="
$results | ForEach-Object { $_ }
"total HMONITORs: $index"
