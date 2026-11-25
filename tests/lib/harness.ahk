; =============================================================================
; Test machinery for tests\e2e.ahk: driving the app, sending keys, recording
; what Windows delivers, reporting, and cleaning up. The tests themselves are
; in e2e.ahk, which includes this file.
; =============================================================================

; =============================================================================
; Driving the app
; =============================================================================

StartApp(wasd, winalt, enableOnLaunch, hidden := true, refocus := true) {
    IniWrite(wasd, T.ini, "Settings", "FixWasdArrows")
    IniWrite(winalt, T.ini, "Settings", "FixWinAlt")
    IniWrite(enableOnLaunch, T.ini, "Settings", "EnableOnLaunch")
    Run('"' T.exe '"' (hidden ? " /tray" : "") ' /settings "' T.ini '"', , , &pid)
    T.pid := pid
    T.app := WinWait("ahk_class AutoHotkeyGUI ahk_pid " pid, , 8)
    if !T.app
        throw Error("The app did not start.")
    deadline := A_TickCount + 3000
    while (AppBanner() = "" && A_TickCount < deadline)
        Sleep(20)
    Sleep(150)
    if !hidden
        WaitVisible(true)
    KeepHookInFront()
    if refocus {
        Focus()
        Settle()
    }
}

StopAppGracefully() {
    try PostMessage(0x10, 0, 0, , "ahk_class AutoHotkey ahk_pid " T.pid)
    ProcessWaitClose(T.pid, 5)
}

KillApp() {
    ProcessClose(T.pid)
    ProcessWaitClose(T.pid, 5)
}

AppBanner() {
    try
        return ControlGetText("Static1", "ahk_id " T.app)
    return ""
}

WaitBanner(text, timeoutMs := 3000) {
    deadline := A_TickCount + timeoutMs
    found := false
    while (!found && A_TickCount < deadline) {
        found := (AppBanner() = text)
        if !found
            Sleep(20)
    }
    KeepHookInFront()
    return found
}

FindControl(text) {
    for hwnd in WinGetControlsHwnd("ahk_id " T.app) {
        if (ControlGetText(hwnd) = text)
            return hwnd
    }
    return 0
}

HasControl(text) => FindControl(text) != 0

Click(text) {
    hwnd := FindControl(text)
    if !hwnd
        throw Error("The app has no control labelled: " text)
    ControlClick(hwnd, "ahk_id " T.app, , , , "NA")
    Sleep(200)
    KeepHookInFront()
}

TestLabel() {
    for hwnd in WinGetControlsHwnd("ahk_id " T.app) {
        text := ControlGetText(hwnd)
        if (SubStr(text, 1, 17) = "Windows received:")
            return text
    }
    return ""
}

WaitLabel(text, timeoutMs := 1500) {
    deadline := A_TickCount + timeoutMs
    while (A_TickCount < deadline) {
        if (TestLabel() = text)
            return true
        Sleep(20)
    }
    return false
}

IsVisible(hwnd) => DllCall("IsWindowVisible", "Ptr", hwnd, "Int") != 0

WaitVisible(wanted, timeoutMs := 3000) {
    deadline := A_TickCount + timeoutMs
    while (A_TickCount < deadline) {
        if (IsVisible(T.app) = wanted)
            return true
        Sleep(20)
    }
    return false
}

InstanceCount() => WinGetList("ahk_class AutoHotkey ahk_exe " T.exeName).Length

CpuSeconds() {
    for process in ComObjGet("winmgmts:").ExecQuery("SELECT KernelModeTime, UserModeTime FROM Win32_Process WHERE ProcessId=" T.pid)
        return (process.KernelModeTime + process.UserModeTime) / 10000000
    return 0
}

LogResources() {
    for process in ComObjGet("winmgmts:").ExecQuery("SELECT WorkingSetSize, PrivatePageCount, KernelModeTime, UserModeTime FROM Win32_Process WHERE ProcessId=" T.pid) {
        Log(Format("  info  memory in use {:.1f} MB (private {:.1f} MB), total CPU time so far {:.2f} s"
            , process.WorkingSetSize / 1048576, process.PrivatePageCount / 1048576
            , (process.KernelModeTime + process.UserModeTime) / 10000000))
    }
}

SettingsFileIsClean() {
    for line in StrSplit(FileRead(T.ini), "`n", "`r") {
        line := Trim(line)
        if (line = "" || line = "[Settings]")
            continue
        if !RegExMatch(line, "^(FixWasdArrows|FixWinAlt|EnableOnLaunch)=[01]$")
            return false
    }
    return true
}

; =============================================================================
; Sending keys and recording what arrives
; =============================================================================

BuildWindow() {
    win := Gui("+AlwaysOnTop -MinimizeBox -MaximizeBox", "Keyboard Fix automated test")
    win.SetFont("s11", "Segoe UI")
    win.AddText("w460", "Automated keyboard test for MANIK Keyboard Fix.`n`nIt runs for well under a minute and closes by itself.`nYour keyboard is paused while it runs.")
    T.status := win.AddText("w460 y+14 c444444", "Starting")
    win.Show("NoActivate xCenter y60")
    T.win := win
    T.hwnd := win.Hwnd
    for msg in [0x100, 0x101, 0x104, 0x105]
        OnMessage(msg, OnKeyMessage)
}

; Starts only once nobody has touched the keyboard or mouse for five seconds.
WaitForQuietPc(maxWaitSeconds) {
    deadline := A_TickCount + maxWaitSeconds * 1000
    while (A_TimeIdle < 5000) {
        if (A_TickCount > deadline)
            return false
        T.status.Text := "Waiting for a quiet moment. Please let go of the keyboard and mouse."
        Sleep(200)
    }
    return true
}

; Real key presses are stopped here for the length of the run. Keys sent by
; AutoHotkey scripts (this test's keys and the app's corrections) carry a send
; level below 101 and are let through untouched.
HoldBackRealKeys() {
    blocker := InputHook("L0")
    blocker.MinSendLevel := 101
    blocker.VisibleText := false
    blocker.VisibleNonText := false
    blocker.NotifyNonText := true
    blocker.KeyOpt("{All}", "N")
    blocker.OnKeyDown := CountBlockedKey
    blocker.Start()
    T.blocker := blocker
}

CountBlockedKey(hook, vk, sc) {
    T.blockedKeys += 1
}

; Proves the hold-back is live by pressing F24 the way a real keyboard or
; another program would (not through AutoHotkey's Send). It must be caught and
; counted, and must not reach any window.
HoldBackWorks() {
    before := T.blockedKeys
    DllCall("keybd_event", "UChar", 0x87, "UChar", 0, "UInt", 0, "UPtr", 0)
    DllCall("keybd_event", "UChar", 0x87, "UChar", 0, "UInt", 2, "UPtr", 0)
    deadline := A_TickCount + 500
    while (T.blockedKeys = before && A_TickCount < deadline)
        Sleep(10)
    caught := T.blockedKeys - before
    T.probeKeys += caught
    return caught > 0
}

; When the fix turns on, the app installs its keyboard hook, which puts it
; ahead of this test's hook. Reinstalling ours moves it back in front, so a
; real key press is stopped before the app can turn it into a correction.
KeepHookInFront() {
    InstallKeybdHook(true, true)
}

class FocusLostError extends Error {
}

; Brings the test window to the front. Called only at points where the test
; itself has just let another window take over (the app opening its window).
Focus() {
    target := "ahk_id " T.hwnd
    if WinActive(target)
        return
    Loop 6 {
        try WinActivate(target)
        if WinWaitActive(target, , 0.4)
            return
    }
    throw FocusLostError("The test window could not be brought to the front, so no keys were sent.")
}

; Every key goes through here, and only while the test window is in front. If
; someone clicks another window mid-run, the test stops here rather than fight
; for the screen or type into their work. The wrapper then tries again later.
Press(keys) {
    if !WinActive("ahk_id " T.hwnd)
        throw FocusLostError("Another window came to the front (a click, or a program opening), so the run stopped.")
    SendEvent("{Blind}" keys)
}

Tap(key) {
    Press("{" key " down}{" key " up}")
}

Toggle() {
    Press("{Ctrl down}{Shift down}{F12 down}{F12 up}{Shift up}{Ctrl up}")
}

; Releases the Windows key behind a filler key. If a correction that should be
; active is not, this is a real Windows key going up, and without the filler
; that would open the Start menu and take the focus away from the test.
ReleaseWin() {
    Press("{vkE8}{LWin up}")
}

IsDown(key) => GetKeyState(key) != 0

NothingHeld() {
    for key in ["w", "a", "s", "d", "Up", "Left", "Down", "Right", "LWin", "LAlt"] {
        if IsDown(key)
            return false
    }
    return true
}

OnKeyMessage(wParam, lParam, msg, hwnd) {
    if (wParam = 0xE8)                 ; the filler key carries no meaning
        return 0
    extended := (lParam >> 24) & 1
    up := (msg = 0x101 || msg = 0x105)
    name := KeyName(wParam, extended)
    token := (up ? "u:" : "d:") name
    if !up
        T.downMessages += 1
    if !up {
        if ((lParam >> 30) & 1)        ; the key was already down: this is a repeat
            token .= "*"
        if !IsModifierName(name) {
            mods := (GetKeyState("Ctrl") ? "C" : "") (GetKeyState("Shift") ? "S" : "")
                . (GetKeyState("Alt") ? "A" : "") (GetKeyState("LWin") ? "W" : "")
            if (mods != "")
                token .= "+" mods
        }
    }
    ; When repeats of a held key arrive faster than a window reads them, Windows
    ; merges them into one message that carries a repeat count. Count each one.
    Loop (up ? 1 : Max(1, lParam & 0xFFFF)) {
        T.events.Push({ name: name, token: token })
        if !up && !InStr(token, "*")
            token := StrReplace(token, "d:" name, "d:" name "*")
    }
    return 0
}

KeyName(vk, extended) {
    static plain := Map(0x57, "W", 0x41, "A", 0x53, "S", 0x44, "D", 0x5B, "LWin", 0x10, "Shift", 0x11, "Ctrl", 0x7B, "F12")
    static arrows := Map(0x26, "Up", 0x25, "Left", 0x28, "Down", 0x27, "Right")
    if plain.Has(vk)
        return plain[vk]
    if arrows.Has(vk)
        return (extended ? "" : "Numpad") arrows[vk]
    if (vk = 0x12)
        return extended ? "RAlt" : "LAlt"
    return Format("vk{:02X}", vk)
}

IsModifierName(name) => (name = "Ctrl" || name = "Shift" || name = "LAlt" || name = "RAlt" || name = "LWin")

Tokens(ignore := "") {
    list := []
    for event in T.events {
        if (ignore != "" && InStr(" " ignore " ", " " event.name " "))
            continue
        list.Push(event.token)
    }
    return list
}

; Waits for the expected keys, then a little longer so that anything extra (a
; remap feeding itself, a stray repeat) is caught as a failure too.
Expect(name, expected, ignore := "") {
    wanted := expected = "" ? 0 : StrSplit(expected, " ").Length
    deadline := A_TickCount + 1500 + wanted * 10
    while (Tokens(ignore).Length < wanted && A_TickCount < deadline)
        Sleep(10)
    Sleep(70)
    got := ""
    for token in Tokens(ignore)
        got .= (got = "" ? "" : " ") token
    Check(name, got = expected, "expected [" expected "] but got [" got "]")
    T.events := []
}

Settle() {
    Sleep(120)
    T.events := []
}

; =============================================================================
; Reporting and cleanup
; =============================================================================

Section(title) {
    try T.status.Text := title
    Log("")
    Log(title)
}

Check(name, ok, detail := "") {
    if ok {
        T.passed += 1
        Log("  ok    " name)
    } else {
        T.failed += 1
        T.failures.Push(name)
        Log("  FAIL  " name (detail != "" ? ": " detail : ""))
    }
}

Log(text) {
    FileAppend(text "`n", T.resultsFile, "UTF-8")
}

FullPath(path) {
    Loop Files, path, "F"
        return A_LoopFileFullPath
    return path
}

Cleanup() {
    try T.blocker.Stop()
    if (T.pid && ProcessExist(T.pid)) {
        StopAppGracefully()
        if ProcessExist(T.pid)
            ProcessClose(T.pid)
    }
    ; Let go of anything this test may still be holding. These are key releases
    ; only (plus a filler key that means nothing), so they are harmless whichever
    ; window is in front, and they are sent even after an interrupted run.
    SendLevel(0)
    SendEvent("{Blind}{sc011 up}{sc01E up}{sc01F up}{sc020 up}{sc148 up}{sc14B up}{sc150 up}{sc14D up}"
        . "{Shift up}{Ctrl up}{vkE8}{LAlt up}{vkE8}{LWin up}")
    Sleep(100)
    link := A_Startup "\MANIK Keyboard Fix.lnk"
    if (T.madeStartupLink && FileExist(link))
        FileDelete(link)
    try FileDelete(T.ini)
    try T.win.Destroy()
}
