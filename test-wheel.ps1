# 端到端测试：注入 Ctrl+Alt+滚轮，读回亮度，并截图确认 OSD
param(
    [int]$Notches = 3,
    [ValidateSet('down', 'up')][string]$Direction = 'down',
    [string]$Shot = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class WheelTest {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprc, MonitorEnumProc cb, IntPtr data);
    [DllImport("dxva2.dll")] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
    [DllImport("dxva2.dll")] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] a);
    [DllImport("dxva2.dll")] public static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint cur, out uint max);
    [DllImport("dxva2.dll")] public static extern bool DestroyPhysicalMonitors(uint n, [In] PHYSICAL_MONITOR[] a);

    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);

    public static void MakeDpiAware() { try { SetProcessDPIAware(); } catch { } }
    public static int ScreenWidth() { return GetSystemMetrics(0); }
    public static int ScreenHeight() { return GetSystemMetrics(1); }

    public static string ReadBrightness() {
        string result = "none";
        List<PHYSICAL_MONITOR> keep = new List<PHYSICAL_MONITOR>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMon, IntPtr hdc, IntPtr r, IntPtr d) {
            uint n = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n) || n == 0) return true;
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) return true;
            for (int i = 0; i < n; i++) {
                uint min = 0, cur = 0, max = 0;
                if (GetMonitorBrightness(arr[i].hPhysicalMonitor, out min, out cur, out max) && max > min) {
                    result = string.Format("{0}/{1} (min={2} max={3})", cur, max, min, max);
                    keep.Add(arr[i]);
                } else {
                    DestroyPhysicalMonitors(1, new PHYSICAL_MONITOR[] { arr[i] });
                }
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static void Inject(int notches, bool up) {
        const byte VK_CONTROL = 0x11, VK_MENU = 0x12;
        const uint KEYUP = 0x0002;
        const uint MOUSEEVENTF_WHEEL = 0x0800;
        keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(60);
        int data = up ? 120 : -120;
        for (int i = 0; i < notches; i++) {
            mouse_event(MOUSEEVENTF_WHEEL, 0, 0, data, UIntPtr.Zero);
            System.Threading.Thread.Sleep(45);
        }
        System.Threading.Thread.Sleep(60);
        keybd_event(VK_MENU, 0, KEYUP, UIntPtr.Zero);
        keybd_event(VK_CONTROL, 0, KEYUP, UIntPtr.Zero);
    }
}
'@
Add-Type -TypeDefinition $code -Language CSharp

$before = [WheelTest]::ReadBrightness()
"brightness before : $before"

[WheelTest]::Inject($Notches, ($Direction -eq 'up'))
"injected $Notches notch(es) $Direction"

if ($Shot) {
    Start-Sleep -Milliseconds 120
    [WheelTest]::MakeDpiAware() | Out-Null
    $sw = [WheelTest]::ScreenWidth()
    $sh = [WheelTest]::ScreenHeight()
    $w = 1000; $h = 400
    $x = [int](($sw - $w) / 2)
    $y = [int]($sh - $h - 60)
    if ($x -lt 0) { $x = 0 }
    if ($y -lt 0) { $y = 0 }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    "screenshot saved   : $Shot  (physical ${sw}x${sh}, region $x,$y ${w}x${h})"
}

Start-Sleep -Milliseconds 900
$after = [WheelTest]::ReadBrightness()
"brightness after  : $after"
