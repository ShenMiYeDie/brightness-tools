#Requires -Version 7.0
<#
    把 luxwheel.cs 预编译成 luxwheel.generated.dll

    为什么要预编译：在常驻进程里用 Add-Type 现场编译，会把 Roslyn 编译器和
    277 个参考程序集一起装进内存（实测多占约 200MB）。预编译成 DLL 后，
    常驻进程只需要加载 DLL，内存和启动时间都大幅下降。

    用法：
      pwsh -File luxwheel-build.ps1           # 需要时编译
      pwsh -File luxwheel-build.ps1 -Force    # 强制重新编译
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'luxwheel-lib.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$csPath    = Join-Path $PSScriptRoot 'luxwheel.cs'
$dllPath   = Join-Path $PSScriptRoot 'luxwheel.generated.dll'
$stampPath = "$dllPath.stamp"

if (-not (Test-Path $csPath)) { throw "找不到源码：$csPath" }

if (-not $Force -and (Test-ComponentFresh -SourceFile $csPath -DllPath $dllPath)) {
    "组件已是最新，无需重编：$dllPath"
    return
}

Remove-Item $dllPath, $stampPath -ErrorAction SilentlyContinue

# 先编译到临时文件：正在运行的守护进程会锁住旧 DLL（.NET 把程序集映射进内存），
# 此时既删不掉也覆盖不了，只能编好之后再尝试替换
$tmpDll = Join-Path $PSScriptRoot "luxwheel.build-$PID.dll"
Remove-Item $tmpDll -ErrorAction SilentlyContinue

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Add-Type -TypeDefinition (Get-Content $csPath -Raw) -ReferencedAssemblies (Get-ComponentReferences) `
        -OutputAssembly $tmpDll -OutputType Library -ErrorAction Stop
}
catch {
    Remove-Item $tmpDll -ErrorAction SilentlyContinue
    Write-Warning "组件编译失败：$($_.Exception.Message)"
    return
}
$sw.Stop()

try {
    Remove-Item $dllPath -Force -ErrorAction SilentlyContinue
    Move-Item -Path $tmpDll -Destination $dllPath -Force -ErrorAction Stop
    Set-Content -Path $stampPath -Value (New-ComponentStamp -SourceFile $csPath -DllPath $dllPath) -Encoding ASCII
    "已编译组件：$dllPath  ($([math]::Round((Get-Item $dllPath).Length/1KB,1)) KB, 用时 $([math]::Round($sw.Elapsed.TotalSeconds,2)) 秒)"
}
catch {
    Remove-Item $tmpDll -ErrorAction SilentlyContinue
    Remove-Item $stampPath -ErrorAction SilentlyContinue      # 让下次启动重新尝试编译
    Write-Warning "旧组件正被运行中的进程占用，本次跳过重编（下次启动会自动重编）。"
}
