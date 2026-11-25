; =============================================================================
; End-to-end test for MANIK Keyboard Fix
;
; Drives the real compiled exe. It opens a small window, sends that window
; synthetic key presses, and records what Windows actually delivers, which is
; what a game would receive. Results go to tests\out\e2e-results.txt.
;
; Run it through tests\run-tests.ps1 rather than directly.
;
; Safety: keys are only ever sent while this test's own window is in front, so
; nothing is typed into another program. If the window cannot be brought to
; the front, the run stops without sending anything.
;
; It is safe to run on a PC that is in use. The test waits for a quiet moment
; before it starts, and then holds back real key presses until it finishes
; (well under a minute), so typing cannot disturb the test and the test cannot
; disturb the typing. Ctrl + Alt + Del still works throughout.
;
; Synthetic keys stand in for the keyboard here. They are sent at SendLevel 1,
; which is what lets them trigger the app's remapping the way real keys do.
; =============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn All, StdOut

SendMode("Event")
SetKeyDelay(-1, -1)
SendLevel(1)
DetectHiddenWindows(true)
SetTitleMatchMode(2)
SetControlDelay(-1)

T := {
    exe: "", exeName: "", outDir: A_ScriptDir "\out", ini: "", resultsFile: "",
    events: [], passed: 0, failed: 0, failures: [],
    pid: 0, app: 0, win: 0, hwnd: 0, status: 0, madeStartupLink: false,
    blocker: 0, blockedKeys: 0, probeKeys: 0, downMessages: 0
}

; [key to send, what it is without the fix, what it becomes with the fix]
KEYS := [
    ["sc011", "W", "Up"], ["sc01E", "A", "Left"], ["sc01F", "S", "Down"], ["sc020", "D", "Right"],
    ["sc148", "Up", "W"], ["sc14B", "Left", "A"], ["sc150", "Down", "S"], ["sc14D", "Right", "D"]
]

Main()

Main() {
    T.exe := FullPath(A_Args.Length ? A_Args[1] : A_ScriptDir "\..\dist\MANIK-Keyboard-Fix.exe")
    SplitPath(T.exe, &name)
    T.exeName := name
    DirCreate(T.outDir)
    ; The scratch settings file goes in the Windows temp folder. Windows' .ini
    ; functions do not work on a network drive, and this project may be on one
    ; (a WSL folder seen from Windows is a network drive).
    T.ini := A_Temp "\manik-keyboard-fix-e2e-" A_TickCount ".ini"
    T.resultsFile := T.outDir "\e2e-results.txt"
    try FileDelete(T.resultsFile)

    Log("MANIK Keyboard Fix end-to-end test")
    Log("exe: " T.exe)
    if !FileExist(T.exe) {
        Log("FAIL  the exe was not found. Run build.ps1 first.")
        ExitApp(1)
    }
    if WinExist("ahk_class AutoHotkey ahk_exe " T.exeName) {
        Log("FAIL  MANIK Keyboard Fix is already running. Exit it first (tray icon > Exit).")
        ExitApp(1)
    }

    BuildWindow()
    maxWaitSeconds := A_Args.Length >= 2 ? Integer(A_Args[2]) : 180
    if !WaitForQuietPc(maxWaitSeconds) {
        Log("SKIPPED  the PC was in use for " maxWaitSeconds " seconds, so the test did not start.")
        T.win.Destroy()
        ExitApp(3)
    }
    HoldBackRealKeys()
    interrupted := false
    try {
        Focus()
        if !HoldBackWorks()
            throw Error("Real key presses could not be held back, so the test did not start.")
        Settle()
        RunAllTests()
        Check("real key presses were held back for the whole run", HoldBackWorks())
    } catch FocusLostError as err {
        interrupted := true
        Log("")
        Log("INTERRUPTED  " err.Message)
    } catch as err {
        Check("test run completed", false, err.Message " (line " err.Line ")")
    }
    Cleanup()

    Log("")
    Log("real key presses held back during the run: " (T.blockedKeys - T.probeKeys))
    if interrupted {
        Log(Format("RESULT: interrupted after {} checks, so nothing is concluded. Run it again.", T.passed + T.failed))
        ExitApp(4)
    }
    Log(Format("RESULT: {} passed, {} failed", T.passed, T.failed))
    for failure in T.failures
        Log("  failed: " failure)
    ExitApp(T.failed ? 1 : 0)
}

; =============================================================================
; The tests
; =============================================================================

RunAllTests() {
    Section("1. Fix OFF: every key passes through unchanged")
    StartApp(1, 1, 0)
    Check("app starts with the fix OFF", AppBanner() = "Keyboard Fix is OFF", AppBanner())
    for k in KEYS {
        Tap(k[1])
        Expect(k[2] " stays " k[2], "d:" k[2] " u:" k[2])
    }
    Press("{LAlt down}{LAlt up}")
    Expect("Left Alt stays Left Alt", "d:LAlt u:LAlt")
    Press("{LWin down}{vkE8}{LWin up}")
    Expect("Left Windows stays Left Windows", "d:LWin u:LWin")

    Section("2. Emergency hotkey Ctrl + Shift + F12 turns the fix ON")
    Toggle()
    Check("banner shows ON", WaitBanner("Keyboard Fix is ON"), AppBanner())
    Settle()

    Section("3. Fix ON: all ten corrections, exactly one output per input")
    for k in KEYS {
        Tap(k[1])
        Expect(k[2] " becomes " k[3], "d:" k[3] " u:" k[3])
    }
    Press("{LWin down}")
    Expect("Left Windows becomes Left Alt (press)", "d:LAlt")
    Check("Windows sees Alt held, and Win not held", IsDown("LAlt") && !IsDown("LWin"))
    ReleaseWin()
    Expect("Left Windows becomes Left Alt (release)", "u:LAlt")
    Press("{LAlt down}")
    Expect("Left Alt becomes Left Windows (press)", "d:LWin")
    Check("Windows sees Win held, and Alt not held", IsDown("LWin") && !IsDown("LAlt"))
    Press("{vkE8}")                    ; filler key, so releasing Win does not open the Start menu
    Press("{LAlt up}")
    Expect("Left Alt becomes Left Windows (release)", "u:LWin")
    Press("{NumpadUp down}{NumpadUp up}")
    Expect("the numeric keypad's arrow is left alone", "d:NumpadUp u:NumpadUp")

    Section("4. Several keys held at once")
    Press("{sc011 down}")
    Expect("first key goes down", "d:Up")
    Press("{sc020 down}")
    Expect("second key goes down while the first is held", "d:Right")
    Check("both arrows are held together", IsDown("Up") && IsDown("Right"))
    Check("the swallowed originals are not held", !IsDown("w") && !IsDown("d"))
    Press("{sc148 down}")
    Expect("a third key from the opposite direction goes down", "d:W")
    Check("three keys are held together", IsDown("Up") && IsDown("Right") && IsDown("w"))
    Press("{sc011 up}")
    Expect("releasing the first key releases only its arrow", "u:Up")
    Check("the other two are still held", !IsDown("Up") && IsDown("Right") && IsDown("w"))
    Press("{sc148 up}")
    Expect("releasing the third key", "u:W")
    Press("{sc020 up}")
    Expect("releasing the second key", "u:Right")
    Check("nothing is left held", !IsDown("Up") && !IsDown("Right") && !IsDown("w"))

    Section("5. Key repeat while held")
    Press("{sc011 down}")
    Press("{sc011 down}")
    Press("{sc011 down}")
    Expect("three repeats arrive as one press and two repeats", "d:Up d:Up* d:Up*")
    Press("{sc011 up}")
    Expect("followed by a single release", "u:Up")
    burst := "", wanted := ""
    Loop 20 {
        burst .= "{sc011 down}{sc011 down}{sc011 down}{sc011 up}"
        wanted .= (wanted = "" ? "" : " ") "d:Up d:Up* d:Up* u:Up"
    }
    T.downMessages := 0
    Press(burst)
    Expect("60 repeats in one burst: every repeat is delivered", wanted)
    Log("  info  those 60 presses arrived as " T.downMessages " key-down messages (Windows merges repeats a window has not read yet)")

    Section("5b. Fast key rolls with no gap between events")
    Press("{sc011 down}{sc020 down}{sc011 up}{sc01E down}{sc020 up}{sc01E up}")
    Expect("three overlapping keys rolled in one burst", "d:Up d:Right u:Up d:Left u:Right u:Left")
    burst := "", wanted := ""
    Loop 25 {
        for k in KEYS {
            burst .= "{" k[1] " down}{" k[1] " up}"
            wanted .= (wanted = "" ? "" : " ") "d:" k[3] " u:" k[3]
        }
    }
    Press(burst)
    Expect("400 key events in one burst: all corrected, none missed, in order", wanted)
    Check("nothing is left held after the burst", NothingHeld())

    Section("6. Modifier combinations")
    Press("{Shift down}{sc011 down}")
    Expect("Shift + W key gives Shift + Up", "d:Shift d:Up+S")
    Press("{sc011 up}")
    Expect("release", "u:Up")
    Press("{Shift up}")
    Expect("Shift release", "u:Shift")

    Press("{Ctrl down}{sc01E down}")
    Expect("Ctrl + A key gives Ctrl + Left", "d:Ctrl d:Left+C")
    Press("{sc01E up}")
    Expect("release", "u:Left")
    Press("{Ctrl up}")
    Expect("Ctrl release", "u:Ctrl")

    Press("{Ctrl down}{Shift down}{sc020 down}")
    Expect("Ctrl + Shift + D key gives Ctrl + Shift + Right", "d:Ctrl d:Shift d:Right+CS")
    Press("{sc020 up}")
    Expect("release", "u:Right")
    Press("{Shift up}{Ctrl up}")
    Expect("Shift and Ctrl release", "u:Shift u:Ctrl")

    Press("{Shift down}{sc148 down}")
    Expect("Shift + Up key gives Shift + W", "d:Shift d:W+S")
    Press("{sc148 up}")
    Expect("release", "u:W")
    Press("{Shift up}")
    Expect("Shift release", "u:Shift")

    Press("{LWin down}")
    Expect("corrected Alt goes down", "d:LAlt")
    Press("{sc011 down}")
    Expect("corrected Alt + W key gives Alt + Up", "d:Up+A")
    Press("{sc011 up}")
    Expect("release", "u:Up")
    ReleaseWin()
    Expect("corrected Alt release", "u:LAlt")

    Section("7. Turning the fix OFF while a key is held")
    Press("{sc011 down}")
    Expect("key is held", "d:Up")
    Toggle()
    Check("banner shows OFF", WaitBanner("Keyboard Fix is OFF"), AppBanner())
    Expect("the held arrow is let go at once", "u:Up", "Ctrl Shift F12")
    Check("Windows no longer sees the arrow held", !IsDown("Up"))
    Press("{sc011 up}")
    Settle()
    Tap("sc011")
    Expect("the key has its original meaning again", "d:W u:W")

    Section("8. Turning the fix ON while a key is held")
    Press("{sc148 down}")
    Expect("key is held with the fix OFF", "d:Up")
    Toggle()
    Check("banner shows ON", WaitBanner("Keyboard Fix is ON"), AppBanner())
    Expect("the original key is let go, so it cannot stick", "u:Up", "Ctrl Shift F12")
    Check("Windows no longer sees the arrow held", !IsDown("Up"))
    Press("{sc148 down}")
    Expect("its next repeat arrives corrected", "d:W")
    Press("{sc148 up}")
    Expect("and so does its release", "u:W")

    Section("9. Resource use")
    before := CpuSeconds()
    Sleep(1500)
    idleMs := Round((CpuSeconds() - before) * 1000)
    Check("no CPU is used while idle with the fix ON", idleMs <= 50, idleMs " ms of CPU in 1.5 s")
    LogResources()

    Section("10. Exiting while a key is held")
    Press("{sc011 down}")
    Expect("key is held", "d:Up")
    StopAppGracefully()
    Expect("the held arrow is let go on exit", "u:Up")
    Check("the app has exited", !ProcessExist(T.pid))
    Check("Windows no longer sees the arrow held", !IsDown("Up"))
    Press("{sc011 up}")
    Settle()
    for k in KEYS {
        Tap(k[1])
        Expect(k[2] " is normal again after exit", "d:" k[2] " u:" k[2])
    }

    Section("11. Separate switches, saved settings, turning on at launch")
    StartApp(1, 0, 1)
    Check("starts ON when the setting asks for it", AppBanner() = "Keyboard Fix is ON", AppBanner())
    Tap("sc011")
    Expect("W A S D fix is active", "d:Up u:Up")
    Press("{LAlt down}{LAlt up}")
    Expect("Windows/Alt fix is not", "d:LAlt u:LAlt")

    Section("12. Force-closing the app (Task Manager > End task)")
    KillApp()
    Tap("sc011")
    Expect("the W key is normal the moment the app is gone", "d:W u:W")
    Tap("sc148")
    Expect("the Up key is normal the moment the app is gone", "d:Up u:Up")

    Section("13. The other switch on its own")
    StartApp(0, 1, 1)
    Tap("sc011")
    Expect("W A S D fix is off", "d:W u:W")
    Press("{LWin down}")
    Expect("Windows/Alt fix is on", "d:LAlt")
    ReleaseWin()
    Expect("release", "u:LAlt")
    StopAppGracefully()

    StartApp(0, 0, 1)
    Check("ON with nothing ticked is reported as such", AppBanner() = "Keyboard Fix is ON (nothing ticked)", AppBanner())
    Tap("sc011")
    Expect("and nothing is changed", "d:W u:W")
    StopAppGracefully()

    Section("14. Window, button and checkboxes")
    StartApp(1, 1, 0, false, false)
    Check("the window is shown on a normal launch", IsVisible(T.app))
    if WinWaitActive("ahk_id " T.app, , 2) {
        focusClass := ""
        try focusClass := WinGetClass(ControlGetFocus("ahk_id " T.app))
        Check("keyboard focus does not start on a button", focusClass = "Static", focusClass)
        SendEvent("{Blind}{Space}{Enter}")
        Sleep(300)
        Check("a stray Space or Enter does not flip the switch", AppBanner() = "Keyboard Fix is OFF", AppBanner())
    } else {
        throw FocusLostError("The app's window did not come to the front, because another window held the screen.")
    }
    Focus()
    Settle()
    Click("Enable Keyboard Fix")
    Check("the button turns the fix ON", WaitBanner("Keyboard Fix is ON"), AppBanner())
    Check("the button now offers to disable", HasControl("Disable Keyboard Fix"))
    Tap("sc011")
    Expect("corrections are live", "d:Up u:Up")
    Click("W A S D and the arrow keys")
    Tap("sc011")
    Expect("unticking W A S D stops only that fix", "d:W u:W")
    Press("{LWin down}")
    Expect("the Windows/Alt fix carries on", "d:LAlt")
    ReleaseWin()
    Expect("release", "u:LAlt")
    Check("the choice is saved to the settings file", IniRead(T.ini, "Settings", "FixWasdArrows", "?") = "0")
    Click("W A S D and the arrow keys")
    Tap("sc011")
    Expect("ticking it again restores the fix", "d:Up u:Up")
    Click("Windows key and Alt key")
    Press("{LWin down}{vkE8}{LWin up}")
    Expect("unticking Windows/Alt stops only that fix", "d:LWin u:LWin")
    Click("Windows key and Alt key")
    Click("Turn the fix on as soon as this app starts")
    Check("turn-on-at-launch is saved", IniRead(T.ini, "Settings", "EnableOnLaunch", "?") = "1")

    Section("15. Keyboard test area inside the app")
    WinActivate("ahk_id " T.app)
    if WinWaitActive("ahk_id " T.app, , 2) {
        SendEvent("{Blind}{sc011 down}")
        Check("with the fix ON the W key reads as Up Arrow", WaitLabel("Windows received:  Up Arrow"), TestLabel())
        SendEvent("{Blind}{sc011 up}")
        SendEvent("{Blind}{sc148 down}")
        Check("and the Up key reads as W", WaitLabel("Windows received:  W"), TestLabel())
        SendEvent("{Blind}{sc148 up}")
        Sleep(100)
    } else {
        throw FocusLostError("The app's window could not be brought to the front, because another window held the screen.")
    }
    Focus()
    Settle()
    Click("Disable Keyboard Fix")
    Check("the button turns the fix OFF", WaitBanner("Keyboard Fix is OFF"), AppBanner())

    Section("16. Start automatically with Windows")
    link := A_Startup "\MANIK Keyboard Fix.lnk"
    if FileExist(link) {
        Log("  skip  a Startup shortcut already exists on this PC and was left untouched")
    } else {
        T.madeStartupLink := true
        Click("Start automatically with Windows")
        Check("ticking the box creates a Startup shortcut", FileExist(link) != "")
        if FileExist(link) {
            FileGetShortcut(link, &target, , &args)
            Check("the shortcut points at this exe", target = T.exe, target)
            Check("the shortcut starts the app hidden in the tray", args = "/tray", args)
        }
        Click("Start automatically with Windows")
        Check("unticking the box removes it", !FileExist(link))
        T.madeStartupLink := FileExist(link) != ""
    }

    Section("17. Tray behaviour and single instance")
    Click("Hide to Tray")
    Check("Hide to Tray hides the window", WaitVisible(false))
    Check("the app keeps running in the tray", ProcessExist(T.pid) != 0)
    RunWait('"' T.exe '" /settings "' T.ini '"')
    Check("a second launch does not start a second copy", InstanceCount() = 1, InstanceCount() " copies")
    Check("it reopens the first copy's window instead", WaitVisible(true))
    Focus()
    PostMessage(0x112, 0xF020, 0, , "ahk_id " T.app)       ; WM_SYSCOMMAND, SC_MINIMIZE
    Check("minimizing hides the window to the tray", WaitVisible(false))
    Check("the app keeps running", ProcessExist(T.pid) != 0)
    RunWait('"' T.exe '" /settings "' T.ini '"')
    Check("launching again brings the window back", WaitVisible(true))
    Focus()
    PostMessage(0x10, 0, 0, , "ahk_id " T.app)             ; WM_CLOSE, the window's X
    Check("the X button hides the window", WaitVisible(false))
    Check("and does not exit the app", ProcessExist(T.pid) != 0)
    RunWait('"' T.exe '" /exit')
    Check("the /exit switch closes the running copy", ProcessWaitClose(T.pid, 3) = 0)

    StartApp(1, 1, 0, false)
    Focus()
    Click("Exit")
    Check("the Exit button exits the app", ProcessWaitClose(T.pid, 5) = 0)

    Section("18. Build details")
    Check("exe version is 1.0.0", FileGetVersion(T.exe) = "1.0.0.0", FileGetVersion(T.exe))
    module := DllCall("LoadLibraryEx", "Str", T.exe, "Ptr", 0, "UInt", 0x22, "Ptr")
    for id, what in Map(159, "ON", 300, "OFF") {
        icon := DllCall("LoadImage", "Ptr", module, "Ptr", id, "UInt", 1, "Int", 16, "Int", 16, "UInt", 0, "Ptr")
        Check("the " what " tray icon is inside the exe", icon != 0)
        if icon
            DllCall("DestroyIcon", "Ptr", icon)
    }
    DllCall("FreeLibrary", "Ptr", module)
    Check("the settings file holds only the three switches", SettingsFileIsClean(), FileRead(T.ini))
}

; Everything that drives the app, sends keys, records what arrives and reports
; results lives in lib\harness.ahk.
#Include "lib\harness.ahk"
