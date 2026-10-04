# QuiX unified Windows one-click build script
# Usage (normal PowerShell):
#   .\build_windows.ps1           # debug build
#   .\build_windows.ps1 -Release  # release build
param([switch]$Release)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$ServerDir = Join-Path $Root "quix-server"
$ClientDir = Join-Path $Root "quix-client"
$Config = if ($Release) { "Release" } else { "Debug" }
$CargoProfile = if ($Release) { "release" } else { "debug" }

# Locate the CMake shipped with Visual Studio via vswhere (best effort).
# If cmake is already on PATH this step is harmless.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.CMake.Project -property installationPath
    if ($vsPath) {
        $cmakeBin = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
        if (Test-Path $cmakeBin) { $env:PATH = "$cmakeBin;" + $env:PATH }
    }
}

Write-Host "====> [1/3] Building Rust server dynamic library quix_core.dll" -ForegroundColor Cyan
Push-Location $ServerDir
try {
    if ($Release) { cargo build --release } else { cargo build }
    if ($LASTEXITCODE -ne 0) { throw "Rust build failed" }
} finally { Pop-Location }

Write-Host "====> [2/3] Building Flutter client ($Config)" -ForegroundColor Cyan
Push-Location $ClientDir
try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }
    if ($Release) { flutter build windows --release } else { flutter build windows --debug }
    if ($LASTEXITCODE -ne 0) { throw "Flutter build failed" }
} finally { Pop-Location }

Write-Host "====> [3/3] Copying quix_core.dll to client output" -ForegroundColor Cyan
$DllSrc = Join-Path $ServerDir "target\$CargoProfile\quix_core.dll"
$DllDst = Join-Path $ClientDir "build\windows\x64\runner\$Config"
if (-not (Test-Path $DllSrc)) { throw "DLL not found: $DllSrc" }
if (-not (Test-Path $DllDst)) { throw "Client output directory not found: $DllDst" }
Copy-Item $DllSrc $DllDst -Force

Write-Host "====> Build complete! Run: $(Join-Path $DllDst 'quix_client.exe')" -ForegroundColor Green
