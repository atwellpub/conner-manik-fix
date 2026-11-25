#Requires -Version 5.1
<#
    Tests the MSI on this Windows account: install, upgrade, uninstall.

        powershell -ExecutionPolicy Bypass -File tests\msi-test.ps1

    Build first (build.ps1). No administrator rights are needed, because the
    MSI installs per user.

    What it does:
      1. Installs dist\MANIK-Keyboard-Fix.msi with the small progress window,
         as a double-click would, and checks the files, shortcuts and the entry
         in Installed apps. The app opens by itself at the end of this step.
      2. Adds a settings file and a Startup shortcut, as the app would once its
         boxes are ticked.
      3. Installs a newer version over it (built on the spot) and checks that
         the running app was closed, and that the settings and the Startup
         shortcut survived.
      4. Uninstalls, and checks that nothing at all is left behind.

    It refuses to run if MANIK Keyboard Fix is already installed or has settings
    on this account, so it can never remove a real install.

    The MSIs are copied to the Windows temp folder and installed from there.
    Windows Installer cannot always read a package from a network location,
    and a WSL folder seen from Windows is one.

    Results: tests\out\msi-results.txt
#>

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$resultsFile = Join-Path $outDir 'msi-results.txt'
Set-Content -LiteralPath $resultsFile -Value 'MANIK Keyboard Fix MSI test' -Encoding UTF8

$msi          = Join-Path $root 'dist\MANIK-Keyboard-Fix.msi'
$distExe      = Join-Path $root 'dist\MANIK-Keyboard-Fix.exe'
$installDir   = Join-Path $env:LOCALAPPDATA 'Programs\MANIK Keyboard Fix'
$installedExe = Join-Path $installDir 'MANIK-Keyboard-Fix.exe'
$startMenu    = Join-Path ([Environment]::GetFolderPath('Programs')) 'MANIK Keyboard Fix.lnk'
$desktop      = Join-Path ([Environment]::GetFolderPath('Desktop')) 'MANIK Keyboard Fix.lnk'
$startup      = Join-Path ([Environment]::GetFolderPath('Startup')) 'MANIK Keyboard Fix.lnk'
$settingsDir  = Join-Path $env:APPDATA 'MANIK Keyboard Fix'
$settings     = Join-Path $settingsDir 'settings.ini'
$marker       = 'HKCU:\Software\MANIK Keyboard Fix'

$script:passed = 0
$script:failed = 0

function Write-Result([string]$text) {
    Add-Content -LiteralPath $resultsFile -Value $text -Encoding UTF8
    Write-Host $text
}

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:passed++; Write-Result "  ok    $name" }
    else     { $script:failed++; Write-Result ("  FAIL  $name" + $(if ($detail) { ": $detail" })) }
}

# Asks Windows Installer itself which copies of the product are registered, for
# this user or for the whole PC. AssignmentType 0 means "this user only".
function Get-InstalledEntries {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $found = @()
    foreach ($product in $installer.ProductsEx('', '', 7)) {
        if ($product.InstallProperty('ProductName') -eq 'MANIK Keyboard Fix') {
            $found += [pscustomobject]@{
                ProductCode = $product.ProductCode
                Version     = $product.InstallProperty('VersionString')
                PerUser     = ($product.InstallProperty('AssignmentType') -eq '0')
            }
        }
    }
    return $found
}

function Get-AppProcesses {
    @(Get-Process -Name 'MANIK-Keyboard-Fix' -ErrorAction SilentlyContinue)
}

function Invoke-Msi([string[]]$arguments) {
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    return $process.ExitCode
}

function Wait-Until([scriptblock]$condition, [int]$seconds = 8) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $condition) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return [bool](& $condition)
}

# --- Preconditions -----------------------------------------------------------

if (-not (Test-Path -LiteralPath $msi)) { throw "$msi was not found. Run build.ps1 first." }

$existing = @()
if (Test-Path -LiteralPath $installDir) { $existing += $installDir }
if (Test-Path -LiteralPath $settings)   { $existing += $settings }
if (Test-Path -LiteralPath $startup)    { $existing += $startup }
if (Test-Path -LiteralPath $marker)     { $existing += $marker }
if (Get-InstalledEntries)               { $existing += 'an entry in Installed apps' }
if (Get-AppProcesses)                   { $existing += 'a running copy of the app' }
if ($existing.Count -gt 0) {
    Write-Result 'SKIPPED  MANIK Keyboard Fix is already present on this account, so the MSI test will not touch it:'
    $existing | ForEach-Object { Write-Result "  $_" }
    exit 3
}

# --- Build a newer MSI to upgrade to -----------------------------------------

$sourceText = Get-Content -LiteralPath (Join-Path $root 'src\MANIK-Keyboard-Fix.ahk') -Raw
if ($sourceText -notmatch '(?m)^APP_VERSION\s*:=\s*"(\d+)\.(\d+)\.(\d+)"') { throw 'APP_VERSION was not found in the source.' }
$version    = '{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3]
$newVersion = '{0}.{1}.{2}' -f $Matches[1], $Matches[2], ([int]$Matches[3] + 1)

# Everything Windows Installer touches lives in a local working folder.
$work   = Join-Path ([System.IO.Path]::GetTempPath()) ('manik-keyboard-fix-msitest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$oldMsi = Join-Path $work 'MANIK-Keyboard-Fix.msi'
$newMsi = Join-Path $work "MANIK-Keyboard-Fix-$newVersion.msi"
Copy-Item -LiteralPath $msi -Destination $oldMsi
& (Join-Path $root 'tools\build-msi.ps1') -Version $newVersion -Output $newMsi

try {
    # --- 1. Install ----------------------------------------------------------
    Write-Result ''
    Write-Result "1. Install version $version (progress window only, as a double-click does)"
    $code = Invoke-Msi @('/i', "`"$oldMsi`"", '/qb', '/l*v', "`"$(Join-Path $work 'msi-install.log')`"")
    Check 'the installer finishes without error and without asking for an administrator' ($code -eq 0) "exit code $code"
    Check 'the exe is installed under the user profile' (Test-Path -LiteralPath $installedExe) $installedExe
    if (Test-Path -LiteralPath $installedExe) {
        Check 'the installed exe is identical to dist\MANIK-Keyboard-Fix.exe' ((Get-FileHash $installedExe).Hash -eq (Get-FileHash $distExe).Hash)
    }
    Check 'a Start menu shortcut is created' (Test-Path -LiteralPath $startMenu) $startMenu
    Check 'a Desktop shortcut is created' (Test-Path -LiteralPath $desktop) $desktop
    $entries = @(Get-InstalledEntries)
    Check 'it is listed once in Installed apps' ($entries.Count -eq 1) "$($entries.Count) entries"
    if ($entries.Count -ge 1) {
        Check "the listed version is $version" ($entries[0].Version -eq $version) $entries[0].Version
        Check 'it is installed for this user only, not for the whole PC' $entries[0].PerUser
    }
    $opened = Wait-Until { (Get-AppProcesses | Where-Object { $_.Path -eq $installedExe }).Count -eq 1 }
    Check 'the app opens by itself after a normal install' $opened

    # --- 2. Simulate use -----------------------------------------------------
    New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
    Set-Content -LiteralPath $settings -Value "[Settings]`r`nFixWasdArrows=1`r`nFixWinAlt=0`r`nEnableOnLaunch=0" -Encoding ASCII
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($startup)
    $link.TargetPath = $installedExe
    $link.Arguments = '/tray'
    $link.Save()

    # --- 3. Upgrade ----------------------------------------------------------
    Write-Result ''
    Write-Result "2. Upgrade to version $newVersion while the app is running"
    $code = Invoke-Msi @('/i', "`"$newMsi`"", '/qn', '/l*v', "`"$(Join-Path $work 'msi-upgrade.log')`"")
    Check 'the upgrade finishes without error and without needing a restart' ($code -eq 0) "exit code $code"
    Check 'the running app was asked to exit first' ((Get-AppProcesses).Count -eq 0) "$((Get-AppProcesses).Count) still running"
    $entries = @(Get-InstalledEntries)
    Check 'there is still exactly one entry in Installed apps' ($entries.Count -eq 1) "$($entries.Count) entries"
    if ($entries.Count -ge 1) {
        Check "the listed version is now $newVersion" ($entries[0].Version -eq $newVersion) $entries[0].Version
    }
    Check 'the exe is still installed' (Test-Path -LiteralPath $installedExe)
    Check 'the settings file survived the upgrade' (Test-Path -LiteralPath $settings)
    Check 'the Start with Windows shortcut survived the upgrade' (Test-Path -LiteralPath $startup)
    Check 'the Start menu and Desktop shortcuts are still there' ((Test-Path -LiteralPath $startMenu) -and (Test-Path -LiteralPath $desktop))

    # --- 4. Uninstall --------------------------------------------------------
    Write-Result ''
    Write-Result '3. Uninstall while the app is running'
    Start-Process -FilePath $installedExe -ArgumentList '/tray'
    [void](Wait-Until { (Get-AppProcesses).Count -eq 1 })
    $code = Invoke-Msi @('/x', "`"$newMsi`"", '/qn', '/l*v', "`"$(Join-Path $work 'msi-uninstall.log')`"")
    Check 'the uninstall finishes without error and without needing a restart' ($code -eq 0) "exit code $code"
    Check 'the running app was asked to exit first' ((Get-AppProcesses).Count -eq 0) "$((Get-AppProcesses).Count) still running"
    Check 'the install folder is gone' (-not (Test-Path -LiteralPath $installDir))
    Check 'the Start menu shortcut is gone' (-not (Test-Path -LiteralPath $startMenu))
    Check 'the Desktop shortcut is gone' (-not (Test-Path -LiteralPath $desktop))
    Check 'the Start with Windows shortcut is gone' (-not (Test-Path -LiteralPath $startup))
    Check 'the settings file and its folder are gone' (-not (Test-Path -LiteralPath $settingsDir))
    Check 'the registry marker is gone' (-not (Test-Path -LiteralPath $marker))
    Check 'it is no longer listed in Installed apps' (@(Get-InstalledEntries).Count -eq 0)
}
finally {
    # Whatever happened above, leave this account as it was found.
    Get-AppProcesses | ForEach-Object { try { $_.Kill() } catch {} }
    foreach ($entry in @(Get-InstalledEntries)) {
        [void](Invoke-Msi @('/x', $entry.ProductCode, '/qn'))
    }
    foreach ($path in @($startup, $settings)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if ((Test-Path -LiteralPath $settingsDir) -and -not (Get-ChildItem -LiteralPath $settingsDir -Force)) {
        Remove-Item -LiteralPath $settingsDir -Force
    }
    Get-ChildItem -LiteralPath $work -Filter '*.log' -ErrorAction SilentlyContinue | Copy-Item -Destination $outDir -Force
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Result ''
Write-Result ("RESULT: {0} passed, {1} failed" -f $script:passed, $script:failed)
exit $(if ($script:failed) { 1 } else { 0 })
