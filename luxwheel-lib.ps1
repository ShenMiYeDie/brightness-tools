#Requires -Version 7.0
# luxwheel 公共函数（被 start / stop / install-autostart / uninstall-autostart /
# luxwheel-build 等脚本点源引入）：查找守护进程、生成无窗口启动器、组件指纹与编译引用

$script:MainScript = Join-Path $PSScriptRoot 'luxwheel.ps1'
$script:VbsPath    = Join-Path $PSScriptRoot 'luxwheel-launch.vbs'
$script:StartupDir = [Environment]::GetFolderPath('Startup')
$script:StartupVbs = Join-Path $script:StartupDir 'luxwheel.vbs'

# 找到正在运行的守护进程（排除自身）
function Get-BrightnessDaemon {
    $escaped = [regex]::Escape($script:MainScript)
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -match $escaped -and
            $_.CommandLine -match '\s-File\s'
        }
}

# 把参数拼成传给主程序的命令行参数
function Get-DaemonArgumentString {
    param(
        [int]$Step = 3,
        [int]$FineStep = 1,
        [int]$Min = 0,
        [int]$Max = 100,
        [double]$OsdSeconds = 1.3,
        [switch]$NoOsd,
        [switch]$NoTray,
        [switch]$NoCtrl,
        [switch]$NoAlt
    )
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $parts = @(
        '-Step', $Step
        '-FineStep', $FineStep
        '-Min', $Min
        '-Max', $Max
        '-OsdSeconds', $OsdSeconds.ToString($inv)
    )
    if ($NoOsd)  { $parts += '-NoOsd' }
    if ($NoTray) { $parts += '-NoTray' }
    if ($NoCtrl) { $parts += '-NoCtrl' }
    if ($NoAlt)  { $parts += '-NoAlt' }
    return ($parts -join ' ')
}

# 生成隐藏窗口启动器（写入当前 pwsh 的完整路径，不依赖 PATH）
function New-LauncherVbs {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$DaemonArgs = ''
    )
    $pwsh = (Get-Process -Id $PID).Path
    $cmd = "`"$pwsh`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($script:MainScript)`" $DaemonArgs".TrimEnd()
    $escaped = $cmd -replace '"', '""'
    $lines = @(
        "' auto-generated launcher for luxwheel (runs with no window)"
        'Set sh = CreateObject("WScript.Shell")'
        "sh.Run ""$escaped"", 0, False"
    )
    Set-Content -Path $Path -Value ($lines -join "`r`n") -Encoding ASCII
}

# C# 组件的编译指纹 = 源码哈希 + PowerShell 版本 + PSHOME + DLL 自身哈希
# 带 DLL 哈希是为了发现文件损坏/被截断的情况，此时会自动重编
function Get-ComponentSourceHash {
    param([Parameter(Mandatory)][string]$SourceFile)
    return (Get-FileHash -Path $SourceFile -Algorithm SHA256).Hash
}

function New-ComponentStamp {
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$DllPath
    )
    $dllHash = (Get-FileHash -Path $DllPath -Algorithm SHA256).Hash
    return "$(Get-ComponentSourceHash -SourceFile $SourceFile)|$($PSVersionTable.PSVersion)|$PSHOME|$dllHash"
}

function Test-ComponentFresh {
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$DllPath
    )
    $stampPath = "$DllPath.stamp"
    if (-not (Test-Path $DllPath) -or -not (Test-Path $stampPath)) { return $false }
    $parts = (Get-Content $stampPath -Raw).Trim() -split '\|'
    if ($parts.Count -ne 4) { return $false }
    if ($parts[0] -ne (Get-ComponentSourceHash -SourceFile $SourceFile)) { return $false }
    if ($parts[1] -ne "$($PSVersionTable.PSVersion)") { return $false }
    if ($parts[2] -ne $PSHOME) { return $false }
    if ($parts[3] -ne (Get-FileHash -Path $DllPath -Algorithm SHA256).Hash) { return $false }
    return $true
}

# 编译 C# 组件所需的引用程序集
function Get-ComponentReferences {
    $refDir = Join-Path $PSHOME 'ref'
    $refNames = @(Get-ChildItem $refDir -Filter *.dll -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $list = @(Get-ChildItem $refDir -Filter *.dll -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $list += Get-ChildItem $PSHOME -Filter *.dll | Where-Object {
        if ($refNames -contains $_.Name -or $_.Name -eq 'System.Private.CoreLib.dll') { return $false }
        # 排除 native dll
        try { [void][System.Reflection.AssemblyName]::GetAssemblyName($_.FullName); return $true } catch { return $false }
    } | ForEach-Object { $_.FullName }
    return $list
}
