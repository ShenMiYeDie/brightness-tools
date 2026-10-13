$ErrorActionPreference = 'Stop'

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class DispCfg {
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RATIONAL { public uint Numerator; public uint Denominator; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_SOURCE {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_TARGET {
        public LUID adapterId; public uint id; public uint modeInfoIdx;
        public uint outputTechnology; public uint rotation; public uint scaling;
        public RATIONAL refreshRate; public uint scanLineOrdering;
        public int targetAvailable; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_INFO {
        public PATH_SOURCE sourceInfo;
        public PATH_TARGET targetInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DEVICE_INFO_HEADER {
        public uint type; public uint size; public LUID adapterId; public uint id;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct TARGET_DEVICE_NAME {
        public DEVICE_INFO_HEADER header;
        public uint flags;
        public uint outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string monitorDevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ADVANCED_COLOR_INFO {
        public DEVICE_INFO_HEADER header;
        public uint value;
        public uint colorEncoding;
        public uint bitsPerColorChannel;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SDR_WHITE_LEVEL {
        public DEVICE_INFO_HEADER header;
        public uint SDRWhiteLevel;
    }

    [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPath, out uint numMode);
    [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint flags, ref uint numPath,
        [Out] PATH_INFO[] paths, ref uint numMode, IntPtr modes, IntPtr topoId);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")]
    public static extern int GetTargetName(ref TARGET_DEVICE_NAME info);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")]
    public static extern int GetAdvColor(ref ADVANCED_COLOR_INFO info);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")]
    public static extern int GetSdrWhite(ref SDR_WHITE_LEVEL info);

    public static string[] Report() {
        List<string> lines = new List<string>();
        lines.Add("sizeof(PATH_INFO) = " + Marshal.SizeOf(typeof(PATH_INFO)));
        uint numPath = 0, numMode = 0;
        int rc = GetDisplayConfigBufferSizes(2 /*QDC_ONLY_ACTIVE_PATHS*/, out numPath, out numMode);
        lines.Add("GetDisplayConfigBufferSizes rc=" + rc + " paths=" + numPath + " modes=" + numMode);
        if (rc != 0) return lines.ToArray();

        PATH_INFO[] paths = new PATH_INFO[numPath];
        IntPtr modeBuf = Marshal.AllocHGlobal((int)numMode * 64);
        try {
            rc = QueryDisplayConfig(2, ref numPath, paths, ref numMode, modeBuf, IntPtr.Zero);
            lines.Add("QueryDisplayConfig rc=" + rc + " paths=" + numPath);
            if (rc != 0) return lines.ToArray();

            for (int i = 0; i < numPath; i++) {
                PATH_TARGET t = paths[i].targetInfo;

                TARGET_DEVICE_NAME tn = new TARGET_DEVICE_NAME();
                tn.header.type = 2;
                tn.header.size = (uint)Marshal.SizeOf(typeof(TARGET_DEVICE_NAME));
                tn.header.adapterId = t.adapterId;
                tn.header.id = t.id;
                int r1 = GetTargetName(ref tn);

                ADVANCED_COLOR_INFO ac = new ADVANCED_COLOR_INFO();
                ac.header.type = 9;
                ac.header.size = (uint)Marshal.SizeOf(typeof(ADVANCED_COLOR_INFO));
                ac.header.adapterId = t.adapterId;
                ac.header.id = t.id;
                int r2 = GetAdvColor(ref ac);

                SDR_WHITE_LEVEL sw = new SDR_WHITE_LEVEL();
                sw.header.type = 11;
                sw.header.size = (uint)Marshal.SizeOf(typeof(SDR_WHITE_LEVEL));
                sw.header.adapterId = t.adapterId;
                sw.header.id = t.id;
                int r3 = GetSdrWhite(ref sw);

                lines.Add("");
                lines.Add("--- path " + i + " ---");
                lines.Add(string.Format("  显示器名称      : {0} (rc={1})", tn.monitorFriendlyDeviceName, r1));
                lines.Add(string.Format("  输出接口        : {0}", t.outputTechnology));
                lines.Add(string.Format("  分辨率刷新率    : {0}x{1}? refresh={2}/{3}", 0, 0, t.refreshRate.Numerator, t.refreshRate.Denominator));
                lines.Add(string.Format("  HDR 支持/启用   : supported={0} enabled={1} wideColor={2} forceDisabled={3} (rc={4})",
                    (ac.value & 1) != 0, (ac.value & 2) != 0, (ac.value & 4) != 0, (ac.value & 8) != 0, r2));
                lines.Add(string.Format("  色彩编码/位深   : encoding={0} bitsPerChannel={1}", ac.colorEncoding, ac.bitsPerColorChannel));
                lines.Add(string.Format("  SDR 内容亮度    : {0} (rc={1})  => {2:F1} nits", sw.SDRWhiteLevel, r3, sw.SDRWhiteLevel / 1000.0 * 80.0));
            }
        } finally { Marshal.FreeHGlobal(modeBuf); }
        return lines.ToArray();
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp
[DispCfg]::Report() | ForEach-Object { $_ }
