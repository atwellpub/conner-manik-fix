#Requires -Version 5.1
<#
    Builds one MSI from installer\MANIK-Keyboard-Fix.wxs and dist\MANIK-Keyboard-Fix.exe.

        tools\build-msi.ps1 -Version 1.0.0 -Output dist\MANIK-Keyboard-Fix.msi

    Called by build.ps1, and by tests\msi-test.ps1, which builds a second MSI
    with a higher version number so it can test upgrading.

    The WiX tools do not work on a network location: writing the cabinet file
    fails, and so does the validation pass that Windows Installer runs on the
    result. This project may well live on one, because a WSL folder seen from
    Windows is a network drive. So the WiX programs and the inputs are copied
    to a folder under the Windows temp directory, the MSI is built there, and
    only the finished file is copied back.
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Output
)

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$wix    = Join-Path $root '.build-tools\wix'
$exe    = Join-Path $root 'dist\MANIK-Keyboard-Fix.exe'
$Output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)

if (-not (Test-Path -LiteralPath (Join-Path $wix 'candle.exe'))) { throw 'WiX was not found in .build-tools. Run build.ps1 first.' }
if (-not (Test-Path -LiteralPath $exe))    { throw 'dist\MANIK-Keyboard-Fix.exe was not found. Run build.ps1 first.' }

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('manik-keyboard-fix-msi-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    Copy-Item -LiteralPath $exe -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'assets\icon-on.ico') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'installer\MANIK-Keyboard-Fix.wxs') -Destination $stage

    # The programs themselves, without the SDK and documentation subfolders.
    $localWix = Join-Path $stage 'wix'
    New-Item -ItemType Directory -Force -Path $localWix | Out-Null
    Get-ChildItem -LiteralPath $wix -File | Copy-Item -Destination $localWix
    $candle = Join-Path $localWix 'candle.exe'
    $light  = Join-Path $localWix 'light.exe'

    Push-Location -LiteralPath $stage
    try {
        $log = & $candle -nologo -arch x64 "-dVersion=$Version" "-dDistDir=$stage" "-dAssetsDir=$stage" -out 'installer.wixobj' 'MANIK-Keyboard-Fix.wxs' 2>&1
        if ($LASTEXITCODE -ne 0) { throw "candle.exe failed with exit code $LASTEXITCODE.`n$($log -join "`n")" }

        # ICE91 only notes that this is a per-user install, which is the intent.
        # Warning 1076 (ICE61) only notes that a same-version rebuild may replace itself.
        $log = & $light -nologo -spdb -sw1076 -sice:ICE91 -out 'installer.msi' 'installer.wixobj' 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath 'installer.msi')) {
            throw "light.exe failed with exit code $LASTEXITCODE.`n$($log -join "`n")"
        }
    }
    finally {
        Pop-Location
    }

    $outDir = Split-Path -Parent $Output
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    Copy-Item -LiteralPath (Join-Path $stage 'installer.msi') -Destination $Output -Force
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
