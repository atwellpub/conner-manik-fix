#Requires -Version 5.1
<#
    Runs the automated end-to-end test against the compiled exe.

        powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1

    Build first (build.ps1), since the test drives dist\MANIK-Keyboard-Fix.exe
    and uses the AutoHotkey copy that the build downloads.

    The test waits until the keyboard and mouse have been idle for five
    seconds, then runs for well under a minute. While it runs, a small window
    stays in front and receives synthetic key presses, the app beeps a few
    times, and real key presses are held back so they cannot disturb it. The
    keyboard is released as soon as the window closes.

    If someone clicks another window mid-run, the test stops at once instead of
    fighting for the screen, releases the keyboard, and starts over at the next
    quiet moment.

        -MaxWaitSeconds   how long to wait for the PC to go idle (default 180)
        -MaxAttempts      how many interrupted runs to retry (default 5)

    Exit code: 0 all passed, 1 failures, 3 skipped because the PC stayed busy,
    4 interrupted on every attempt.
    Results: tests\out\e2e-results.txt
#>
param(
    [string]$Exe,
    [int]$MaxWaitSeconds = 180,
    [int]$MaxAttempts = 5
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $root 'dist\MANIK-Keyboard-Fix.exe' }
$ahk     = Join-Path $root '.build-tools\ahk\AutoHotkey64.exe'
$script  = Join-Path $PSScriptRoot 'e2e.ahk'
$results = Join-Path $PSScriptRoot 'out\e2e-results.txt'

if (-not (Test-Path -LiteralPath $ahk)) { throw 'AutoHotkey was not found in .build-tools. Run build.ps1 first.' }
if (-not (Test-Path -LiteralPath $Exe)) { throw "$Exe was not found. Run build.ps1 first." }

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    # Started directly rather than through the Windows shell. The shell can stop
    # to ask "do you want to run this file?" when the project is on a network
    # drive, which a WSL folder is, and nobody would be there to answer.
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $ahk
    $info.Arguments = "/ErrorStdOut `"$script`" `"$Exe`" $MaxWaitSeconds"
    $info.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($info)
    if (-not $process.WaitForExit(($MaxWaitSeconds + 180) * 1000)) {
        & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
        Get-Process -Name 'MANIK-Keyboard-Fix' -ErrorAction SilentlyContinue | Stop-Process -Force
        if (Test-Path -LiteralPath $results) { Get-Content -LiteralPath $results }
        throw 'The test did not finish in time and was stopped.'
    }
    if ($process.ExitCode -ne 4) { break }
    Write-Host "Attempt $attempt of $MaxAttempts was interrupted by another window coming to the front."
    if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 3 }
}

if (Test-Path -LiteralPath $results) { Get-Content -LiteralPath $results }
exit $process.ExitCode
