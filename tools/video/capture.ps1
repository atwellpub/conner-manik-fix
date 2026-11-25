#Requires -Version 5.1
<#
    Captures the real screenshots that the install video is built from.

        powershell -ExecutionPolicy Bypass -File tools\video\capture.ps1

    It runs a real install of dist\MANIK-Keyboard-Fix.msi exactly as a
    double-click would, photographs the installer's progress window and then
    the app window at each step of the setup, and uninstalls again. Output goes
    to tools\video\shots\ along with layout.json, which records where each
    button and checkbox sits in the pictures.

    A plain sheet is shown behind the windows for the few seconds this takes,
    so nothing else on the desktop ends up in the pictures. Like the tests, it
    waits for the keyboard and mouse to be idle first, and it refuses to run if
    the app is already installed on this account.

    The fix is genuinely switched on for a moment while the "on" pictures are
    taken, then the app is closed and uninstalled.
#>

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$shots = Join-Path $PSScriptRoot 'shots'
New-Item -ItemType Directory -Force -Path $shots | Out-Null
$msi   = Join-Path $root 'dist\MANIK-Keyboard-Fix.msi'
if (-not (Test-Path -LiteralPath $msi)) { throw 'dist\MANIK-Keyboard-Fix.msi was not found. Run build.ps1 first.' }

$installDir   = Join-Path $env:LOCALAPPDATA 'Programs\MANIK Keyboard Fix'
$installedExe = Join-Path $installDir 'MANIK-Keyboard-Fix.exe'
$settingsDir  = Join-Path $env:APPDATA 'MANIK Keyboard Fix'
$startup      = Join-Path ([Environment]::GetFolderPath('Startup')) 'MANIK Keyboard Fix.lnk'
foreach ($path in $installDir, $settingsDir, $startup) {
    if (Test-Path -LiteralPath $path) { throw "MANIK Keyboard Fix is already present on this account ($path). Nothing was captured." }
}
if (Get-Process -Name 'MANIK-Keyboard-Fix' -ErrorAction SilentlyContinue) { throw 'MANIK Keyboard Fix is running. Exit it first.' }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Drawing @"
using System; using System.Text; using System.Collections.Generic; using System.Drawing; using System.Runtime.InteropServices;
public static class Cap {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO i);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);

    public static uint IdleMs() { var i = new LASTINPUTINFO(); i.cbSize = 8; GetLastInputInfo(ref i); return (uint)Environment.TickCount - i.dwTime; }
    public static string Text(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
    public static string Class(IntPtr h) { var s = new StringBuilder(128); GetClassName(h, s, 128); return s.ToString(); }
    public static RECT Frame(IntPtr h) { RECT r; DwmGetWindowAttribute(h, 9, out r, 16); return r; }
    public static void OnTop(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x13); }

    // Visible top-level windows that belong to any of the given processes.
    public static List<IntPtr> WindowsOf(uint[] pids) {
        var found = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (IsWindowVisible(h) && Array.IndexOf(pids, p) >= 0) {
                RECT r; GetWindowRect(h, out r);
                if (r.R - r.L > 150 && r.B - r.T > 60) found.Add(h);
            }
            return true; }, IntPtr.Zero);
        return found;
    }

    public static IntPtr AppWindow(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && Class(h) == "AutoHotkeyGUI") { found = h; return false; } return true; }, IntPtr.Zero);
        return found;
    }

    public static IntPtr Child(IntPtr parent, string prefix) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, (h, l) => { if (Text(h).StartsWith(prefix)) { found = h; return false; } return true; }, IntPtr.Zero);
        return found;
    }

    // Copies the window from the screen with a margin around it, shadow included.
    public static void Save(IntPtr h, string path, int pad) {
        RECT r = Frame(h);
        using (var bmp = new Bitmap(r.R - r.L + pad * 2, r.B - r.T + pad * 2)) {
            using (var g = Graphics.FromImage(bmp)) { g.CopyFromScreen(r.L - pad, r.T - pad, 0, 0, bmp.Size); }
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }

    // Where each child control sits inside a picture taken by Save().
    public static string Layout(IntPtr h, int pad) {
        RECT f = Frame(h);
        var parts = new List<string>();
        EnumChildWindows(h, (c, l) => {
            RECT r; GetWindowRect(c, out r);
            string text = Text(c).Replace("\\", "\\\\").Replace("\"", "\\\"");
            parts.Add(String.Format("    {{ \"text\": \"{0}\", \"class\": \"{1}\", \"x\": {2}, \"y\": {3}, \"w\": {4}, \"h\": {5} }}",
                text, Class(c), r.L - f.L + pad, r.T - f.T + pad, r.R - r.L, r.B - r.T));
            return true; }, IntPtr.Zero);
        return String.Format("{{\n  \"width\": {0},\n  \"height\": {1},\n  \"controls\": [\n{2}\n  ]\n}}\n",
            f.R - f.L + pad * 2, f.B - f.T + pad * 2, String.Join(",\n", parts.ToArray()));
    }
}
"@
[void][Cap]::SetProcessDPIAware()

$pad = 24
function Pump([int]$ms) {
    $until = (Get-Date).AddMilliseconds($ms)
    do { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 15 } while ((Get-Date) -lt $until)
}
function Snap([IntPtr]$window, [string]$name) { [Cap]::Save($window, (Join-Path $shots "$name.png"), $pad); Write-Host "captured $name" }
function Tick([IntPtr]$app, [string]$label) {
    $box = [Cap]::Child($app, $label)
    [void][Cap]::SendMessage($box, 0xF1, [IntPtr]1, [IntPtr]::Zero)                    # BM_SETCHECK
    [void][Cap]::PostMessage($app, 0x111, [IntPtr][Cap]::GetDlgCtrlID($box), $box)     # WM_COMMAND, BN_CLICKED
}

# Wait for a quiet moment, as the tests do.
$deadline = (Get-Date).AddSeconds(180)
while ([Cap]::IdleMs() -lt 4000) {
    if ((Get-Date) -gt $deadline) { throw 'The PC was in use for three minutes, so nothing was captured.' }
    Start-Sleep -Milliseconds 200
}

# The installer is run from the Windows temp folder, as the MSI test does.
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('manik-keyboard-fix-video-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$localMsi = Join-Path $work 'MANIK-Keyboard-Fix.msi'
Copy-Item -LiteralPath $msi -Destination $localMsi

# The plain sheet, in the same colour as the video's background.
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$sheet = New-Object System.Windows.Forms.Form
$sheet.FormBorderStyle = 'None'; $sheet.ShowInTaskbar = $false; $sheet.StartPosition = 'Manual'; $sheet.TopMost = $true
$sheet.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 248)
$width = [Math]::Min(1100, $screen.Width); $height = [Math]::Min(900, $screen.Height)
$sheet.Bounds = New-Object System.Drawing.Rectangle ($screen.X + ($screen.Width - $width) / 2), ($screen.Y + ($screen.Height - $height) / 2), $width, $height
$sheet.Show()
Pump 300

try {
    # --- The installer's progress window -------------------------------------
    $before = @(Get-Process -Name msiexec -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
    $installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$localMsi`"") -PassThru
    $seen = @{}
    $frame = 0
    $until = (Get-Date).AddSeconds(60)
    while (-not $installer.HasExited -and (Get-Date) -lt $until) {
        $pids = @(Get-Process -Name msiexec -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id } | Where-Object { $before -notcontains $_ })
        foreach ($window in [Cap]::WindowsOf([uint32[]]$pids)) {
            $key = $window.ToInt64()
            if (-not $seen.ContainsKey($key)) { $seen[$key] = 0; [Cap]::OnTop($window); Pump 40 }
            if ($seen[$key] -lt 12) {
                $seen[$key]++; $frame++
                Snap $window ('installer-{0:d2}' -f $frame)
            }
        }
        Pump 25
    }
    if (-not $installer.HasExited) { throw 'The installer did not finish within a minute.' }
    Write-Host "installer exit code $($installer.ExitCode), progress frames captured: $frame"
    if ($installer.ExitCode -ne 0) { throw 'The installer reported an error.' }

    # --- The app, which the installer opens by itself ------------------------
    $app = [IntPtr]::Zero
    $appProcess = $null
    for ($i = 0; $i -lt 100 -and $app -eq [IntPtr]::Zero; $i++) {
        Pump 100
        $appProcess = Get-Process -Name 'MANIK-Keyboard-Fix' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($appProcess) { $app = [Cap]::AppWindow([uint32]$appProcess.Id) }
    }
    if ($app -eq [IntPtr]::Zero) { throw 'The app did not open after the install.' }
    [Cap]::OnTop($app)
    Pump 900

    Set-Content -LiteralPath (Join-Path $shots 'layout.json') -Value ([Cap]::Layout($app, $pad)) -Encoding UTF8
    Snap $app 'app-off'

    Tick $app 'Start automatically with Windows'
    Pump 450
    Snap $app 'app-tick1'

    Tick $app 'Turn the fix on as soon as this app starts'
    Pump 450
    Snap $app 'app-tick2'

    $button = [Cap]::Child($app, 'Enable Keyboard Fix')
    [void][Cap]::PostMessage($app, 0x111, [IntPtr][Cap]::GetDlgCtrlID($button), $button)
    Pump 450
    Snap $app 'app-on'

    # Light two boxes in the test area by posting key messages straight to the
    # window. Nothing is typed system-wide.
    $testArea = [Cap]::Child($app, 'Windows received')
    [void][Cap]::PostMessage($testArea, 0x100, [IntPtr]0x57, [IntPtr]0x00110001)       # W down
    Pump 250
    Snap $app 'app-test-w'
    [void][Cap]::PostMessage($testArea, 0x101, [IntPtr]0x57, [IntPtr]0xC0110001)       # W up
    [void][Cap]::PostMessage($testArea, 0x100, [IntPtr]0x26, [IntPtr]0x01480001)       # Up arrow down
    Pump 250
    Snap $app 'app-test-up'
    [void][Cap]::PostMessage($testArea, 0x101, [IntPtr]0x26, [IntPtr]0xC1480001)       # Up arrow up
    Pump 150
}
finally {
    # Switch the fix off and leave this account exactly as it was found.
    if (Test-Path -LiteralPath $installedExe) { Start-Process -FilePath $installedExe -ArgumentList '/exit' -Wait }
    Get-Process -Name 'MANIK-Keyboard-Fix' -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch {} }
    $sheet.Close()
    $uninstall = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', "`"$localMsi`"", '/qn') -Wait -PassThru
    Write-Host "uninstall exit code $($uninstall.ExitCode)"
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($path in $installDir, $settingsDir, $startup) {
        if (Test-Path -LiteralPath $path) { Write-Host "LEFT BEHIND: $path" -ForegroundColor Red }
    }
}
