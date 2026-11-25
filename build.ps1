#Requires -Version 5.1
<#
    Builds both deliverables from source:

        dist\MANIK-Keyboard-Fix.exe   the standalone app
        dist\MANIK-Keyboard-Fix.msi   the installer for it

    Run it from this folder on Windows 10 or 11:

        powershell -ExecutionPolicy Bypass -File build.ps1

    or double-click build.cmd.

    Nothing needs to be installed first. The script downloads the official
    portable AutoHotkey v2, its Ahk2Exe compiler and the WiX v3 installer tools
    into .build-tools\, checks each download against a pinned SHA-256, then
    builds. Later runs reuse the downloaded tools. Delete .build-tools\ to
    start clean.

        -SkipMsi   build only the exe (skips the 40 MB WiX download)
#>
param(
    [switch]$SkipMsi,
    [switch]$SkipLineCap    # only for testing the line-cap check itself
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root    = $PSScriptRoot
$tools   = Join-Path $root '.build-tools'
$source  = Join-Path $root 'src\MANIK-Keyboard-Fix.ahk'
$wxs     = Join-Path $root 'installer\MANIK-Keyboard-Fix.wxs'
$distDir = Join-Path $root 'dist'
$exeOut  = Join-Path $distDir 'MANIK-Keyboard-Fix.exe'
$msiOut  = Join-Path $distDir 'MANIK-Keyboard-Fix.msi'

# Pinned toolchain. To upgrade a tool, change its URL and its hash together.
$downloads = @(
    @{
        Name   = 'ahk'
        Url    = 'https://github.com/AutoHotkey/AutoHotkey/releases/download/v2.0.32/AutoHotkey_2.0.32.zip'
        Sha256 = '384A4C125E8D7B5B77DDBD5A593EC761D3E9E96E97A95931CF56E9A077FDA114'
        Need   = 'AutoHotkey64.exe'
    },
    @{
        Name   = 'ahk2exe'
        Url    = 'https://github.com/AutoHotkey/Ahk2Exe/releases/download/Ahk2Exe1.1.37.02a2/Ahk2Exe1.1.37.02a2.zip'
        Sha256 = 'C29B8C3A5124850D79FC9E66E2CA79677C377D7F31631AD3022BA159C5D9E3BE'
        Need   = 'Ahk2Exe.exe'
    },
    @{
        Name   = 'wix'
        Url    = 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip'
        Sha256 = '6AC824E1642D6F7277D0ED7EA09411A508F6116BA6FAE0AA5F2C7DAA2FF43D31'
        Need   = 'candle.exe'
        MsiOnly = $true
    }
)

function Format-Argument([string]$value) {
    if ($value -match '[\s"]') { return '"' + ($value -replace '"', '\"') + '"' }
    return $value
}

# Runs a tool with its output captured and a time limit. A build tool that
# opens a dialog would otherwise sit there forever waiting for a click.
function Invoke-Tool([string]$exe, [string[]]$arguments, [int]$timeoutSeconds = 120) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = ($arguments | ForEach-Object { Format-Argument $_ }) -join ' '
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
        & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
        throw ("{0} did not finish within {1} seconds and was stopped. It may have been showing a dialog." -f (Split-Path -Leaf $exe), $timeoutSeconds)
    }
    $process.WaitForExit()
    return @{
        ExitCode = $process.ExitCode
        Output   = (($stdout.Result, $stderr.Result) -join "`n").Trim()
    }
}

function Write-Step([string]$text) { Write-Host "`n== $text" -ForegroundColor Cyan }

# --- 1. Source checks --------------------------------------------------------

Write-Step 'Checking sources'

# No hand-written file may pass 900 lines. Split a file along its natural seams
# before it gets there.
$lineCap = 900
if (-not $SkipLineCap) {
    $checked = Get-ChildItem -Path $root -Recurse -File -Include *.ahk, *.ps1, *.cmd, *.md, *.wxs |
        Where-Object { $_.FullName -notmatch '\\(\.build-tools|\.git|\.wt|dist|tests\\out)\\' }
    $tooLong = @()
    foreach ($file in $checked) {
        $lines = @(Get-Content -LiteralPath $file.FullName).Count
        if ($lines -gt $lineCap) { $tooLong += ('{0} has {1} lines' -f $file.FullName.Substring($root.Length + 1), $lines) }
    }
    if ($tooLong.Count -gt 0) {
        $tooLong | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "Line cap exceeded: no source file may be longer than $lineCap lines."
    }
    Write-Host ("Line cap OK ({0} files, limit {1} lines)" -f $checked.Count, $lineCap)
}

# One version number, three places: the app, the exe's file properties and the
# MSI. The MSI only replaces an installed exe when its file version goes up, so
# these must move together.
$sourceText = Get-Content -LiteralPath $source -Raw
if ($sourceText -notmatch '(?m)^APP_VERSION\s*:=\s*"(\d+\.\d+\.\d+)"') { throw 'APP_VERSION was not found in the source.' }
$version = $Matches[1]
if ($sourceText -notmatch '(?m)^;@Ahk2Exe-SetVersion\s+(\S+)') { throw ';@Ahk2Exe-SetVersion was not found in the source.' }
if ($Matches[1] -ne $version) {
    throw "Version mismatch: APP_VERSION is $version but ;@Ahk2Exe-SetVersion is $($Matches[1])."
}
Write-Host "Version $version"

# --- 2. Toolchain ------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

foreach ($item in $downloads) {
    if ($SkipMsi -and $item.MsiOnly) { continue }
    $dir = Join-Path $tools $item.Name
    if (Test-Path -LiteralPath (Join-Path $dir $item.Need)) { continue }

    Write-Step "Downloading $($item.Name)"
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    $zip = Join-Path $tools ($item.Name + '.zip')
    Write-Host $item.Url
    Invoke-WebRequest -Uri $item.Url -OutFile $zip -UseBasicParsing

    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if ($actual -ne $item.Sha256) {
        Remove-Item -LiteralPath $zip -Force
        throw "Checksum mismatch for $($item.Url)`n  expected $($item.Sha256)`n  actual   $actual"
    }

    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $dir
    Remove-Item -LiteralPath $zip -Force
    if (-not (Test-Path -LiteralPath (Join-Path $dir $item.Need))) {
        throw "$($item.Need) was not found inside $($item.Url)"
    }
}

$ahk     = Join-Path $tools 'ahk\AutoHotkey64.exe'
$ahk2exe = Join-Path $tools 'ahk2exe\Ahk2Exe.exe'

# --- 3. Lint -----------------------------------------------------------------

# AutoHotkey loads the script without running it. Any error or warning it
# prints fails the build here, as text, before the compiler is involved.
Write-Step 'Validating the script'
$lint = Invoke-Tool $ahk @('/ErrorStdOut', '/validate', $source) 60
if ($lint.ExitCode -ne 0 -or $lint.Output) {
    Write-Host $lint.Output -ForegroundColor Red
    throw 'The script has errors or warnings (see above).'
}
Write-Host 'No errors, no warnings'

# --- 4. Compile the exe ------------------------------------------------------

Write-Step 'Compiling the exe'

# The compiler cannot replace an exe that is running.
$running = Get-Process -Name 'MANIK-Keyboard-Fix' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $exeOut }
if ($running) {
    throw 'dist\MANIK-Keyboard-Fix.exe is running. Exit it (tray icon > Exit), then build again.'
}

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
if (Test-Path -LiteralPath $exeOut) { Remove-Item -LiteralPath $exeOut -Force }

# /compress 0 leaves the exe unpacked. Packed executables are a common cause of
# antivirus false alarms, and the size saved is not worth that.
$compile = Invoke-Tool $ahk2exe @('/in', $source, '/out', $exeOut, '/base', $ahk, '/compress', '0', '/silent', 'verbose') 120
if ($compile.Output) { Write-Host $compile.Output }
if ($compile.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $exeOut)) {
    throw "Ahk2Exe failed with exit code $($compile.ExitCode)."
}

$fileVersion = (Get-Item -LiteralPath $exeOut).VersionInfo.FileVersion
if ($fileVersion -notlike "$version*") {
    throw "The compiled exe reports version '$fileVersion', expected $version."
}

# --- 5. Build the MSI --------------------------------------------------------

if (-not $SkipMsi) {
    Write-Step 'Building the MSI'
    $candle = Join-Path $tools 'wix\candle.exe'
    $light  = Join-Path $tools 'wix\light.exe'
    $objDir = Join-Path $tools 'obj'
    New-Item -ItemType Directory -Force -Path $objDir | Out-Null
    $wixobj = Join-Path $objDir 'MANIK-Keyboard-Fix.wixobj'
    if (Test-Path -LiteralPath $msiOut) { Remove-Item -LiteralPath $msiOut -Force }

    $step = Invoke-Tool $candle @('-nologo', '-arch', 'x64', "-dVersion=$version", "-dDistDir=$distDir",
        "-dAssetsDir=$(Join-Path $root 'assets')", '-out', $wixobj, $wxs) 120
    if ($step.Output) { Write-Host $step.Output }
    if ($step.ExitCode -ne 0) { throw "candle.exe failed with exit code $($step.ExitCode)." }

    # ICE91 only notes that this is a per-user install, which is the intent.
    # ICE61 only notes that a same-version rebuild is allowed to replace itself.
    $step = Invoke-Tool $light @('-nologo', '-spdb', '-sw1076', '-sice:ICE91', '-out', $msiOut, $wixobj) 300
    if ($step.Output) { Write-Host $step.Output }
    if ($step.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $msiOut)) {
        throw "light.exe failed with exit code $($step.ExitCode)."
    }
}

# --- Done --------------------------------------------------------------------

Write-Host ''
$results = @($exeOut)
if (-not $SkipMsi) { $results += $msiOut }
foreach ($path in $results) {
    $item = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host ("Built {0}" -f $item.FullName) -ForegroundColor Green
    Write-Host ("  size    {0:N0} bytes" -f $item.Length)
    Write-Host ("  sha256  {0}" -f $hash)
}
