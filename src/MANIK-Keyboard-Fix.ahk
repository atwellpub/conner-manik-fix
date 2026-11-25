; =============================================================================
; MANIK Keyboard Fix
;
; Corrects a MANIK gaming keyboard whose onboard configuration has swapped
; W A S D with the arrow keys, and Left Windows with Left Alt.
;
; How it works: while the fix is ON, a standard low-level keyboard hook (the
; same mechanism every AutoHotkey remap uses) swallows each swapped key and
; sends the key it should have been. No driver is installed, the app writes
; nothing to the registry, and the keyboard's firmware is never touched. When
; the fix is OFF, or the app is closed, the keyboard behaves exactly as before.
;
; Requires AutoHotkey v2 to run from source. build.ps1 compiles this file into
; a standalone dist\MANIK-Keyboard-Fix.exe that needs nothing installed.
; =============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Off        ; handled by hand below, so a second launch reopens the window
#NoTrayIcon                ; shown once the correct ON/OFF icon has been chosen
#Warn All, StdOut         ; never a dialog; build.ps1 fails the build on any warning

;@Ahk2Exe-SetName MANIK Keyboard Fix
;@Ahk2Exe-SetDescription MANIK Keyboard Fix
;@Ahk2Exe-SetVersion 1.0.0
;@Ahk2Exe-SetMainIcon ..\assets\icon-on.ico
;@Ahk2Exe-AddResource ..\assets\icon-off.ico, 300

APP_TITLE   := "MANIK Keyboard Fix"
APP_VERSION := "1.0.0"

; Icon resource IDs inside the compiled exe (159 is the main icon).
ICON_ON_RES  := 159
ICON_OFF_RES := 300

COLOR_ON   := "16A34A"     ; green: corrections are being applied
COLOR_OFF  := "6B7280"     ; gray: the keyboard is untouched
COLOR_TILE := "FFFFFF"

; -----------------------------------------------------------------------------
; Remap table
;
; Keys are named by scan code (physical key position), because a position swap
; is what the keyboard did. This also keeps the numeric keypad's arrows out of
; it: they have different scan codes from the dedicated arrow keys.
;
; Each pair is [key Windows receives, key to send instead].
; -----------------------------------------------------------------------------
SC_W  := "sc011", SC_A    := "sc01E", SC_S    := "sc01F", SC_D     := "sc020"
SC_UP := "sc148", SC_LEFT := "sc14B", SC_DOWN := "sc150", SC_RIGHT := "sc14D"

REMAP_GROUPS := Map(
    "wasd", [
        [SC_W,  SC_UP], [SC_A,    SC_LEFT], [SC_S,    SC_DOWN], [SC_D,     SC_RIGHT],
        [SC_UP, SC_W],  [SC_LEFT, SC_A],    [SC_DOWN, SC_S],    [SC_RIGHT, SC_D]
    ],
    "winalt", [
        ["LWin", "LAlt"], ["LAlt", "LWin"]
    ]
)

; -----------------------------------------------------------------------------
; Runtime state
; -----------------------------------------------------------------------------
State := {
    masterOn: false,                                  ; the big Enable/Disable switch
    groupOn: Map("wasd", false, "winalt", false),     ; which groups are remapping right now
    held: Map(),                                      ; keys this app is holding down synthetically
    settingsFile: A_AppData "\" APP_TITLE "\settings.ini",
    startHidden: false,
    exitRunningCopy: false,
    hideTipShown: false
}
Cfg := { wasd: true, winalt: true, enableOnLaunch: false }
Ui  := { tiles: Map() }

; -----------------------------------------------------------------------------
; Startup
; -----------------------------------------------------------------------------
Persistent
ListLines(false)
KeyHistory(0)                          ; keep no key history, not even in memory
SendMode("Event")                      ; see Emit() for why this is not the default SendInput
SetKeyDelay(-1, -1)
A_MaxHotkeysPerInterval := 1000000     ; held keys repeat quickly; never show the "too many hotkeys" prompt
ProcessSetPriority("High")             ; stay responsive while a game is using the CPU

ParseCommandLine()
EnsureSingleInstance()
LoadSettings()
RegisterRemapHotkeys()
Hotkey("^+F12", EmergencyToggle)       ; Ctrl + Shift + F12, always active
BuildGui()
BuildTrayMenu()
RepairStartupShortcut()
WatchDesktopSwitches()
OnExit(OnAppExit)

State.masterOn := Cfg.enableOnLaunch
ApplyState()
A_IconHidden := false
if !State.startHidden
    ShowMain()

; =============================================================================
; Command line and single instance
; =============================================================================

; /tray             start hidden in the system tray (used by the Startup shortcut)
; /exit             ask the copy that is already running to exit, wait for it, then exit
;                   (used by the installer before it replaces or removes the exe)
; /settings <file>  use a different settings file (used by the automated tests)
ParseCommandLine() {
    for index, arg in A_Args {
        if (arg = "/tray")
            State.startHidden := true
        else if (arg = "/exit")
            State.exitRunningCopy := true
        else if (arg = "/settings" && A_Args.Has(index + 1))
            State.settingsFile := A_Args[index + 1]
    }
}

; Only one copy may run. A second launch asks the first to show its window, then exits.
EnsureSingleInstance() {
    static mutex := 0
    mutexName := "Local\MANIK_Keyboard_Fix_Instance"
    showMsg := DllCall("RegisterWindowMessage", "Str", "MANIK_Keyboard_Fix_Show", "UInt")
    exitMsg := DllCall("RegisterWindowMessage", "Str", "MANIK_Keyboard_Fix_Exit", "UInt")
    mutex := DllCall("CreateMutex", "Ptr", 0, "Int", false, "Str", mutexName, "Ptr")
    alreadyRunning := (A_LastError = 183)      ; ERROR_ALREADY_EXISTS

    if State.exitRunningCopy {
        DllCall("CloseHandle", "Ptr", mutex)
        if alreadyRunning {
            DllCall("PostMessage", "Ptr", 0xFFFF, "UInt", exitMsg, "Ptr", 0, "Ptr", 0)
            Loop 50 {                          ; up to 5 seconds for the other copy to go
                Sleep(100)
                other := DllCall("OpenMutex", "UInt", 0x100000, "Int", false, "Str", mutexName, "Ptr")
                if !other
                    break
                DllCall("CloseHandle", "Ptr", other)
            }
        }
        ExitApp
    }
    if alreadyRunning {
        if !State.startHidden {
            DllCall("AllowSetForegroundWindow", "UInt", 0xFFFFFFFF)
            DllCall("PostMessage", "Ptr", 0xFFFF, "UInt", showMsg, "Ptr", 0, "Ptr", 0)
        }
        ExitApp
    }
    OnMessage(showMsg, OnShowRequest)
    OnMessage(exitMsg, OnExitRequest)
}

OnShowRequest(wParam, lParam, msg, hwnd) {
    ShowMain()
}

OnExitRequest(wParam, lParam, msg, hwnd) {
    ExitApp()
}

; =============================================================================
; Settings (a small .ini file under %APPDATA%; no keystrokes are ever stored)
; =============================================================================

LoadSettings() {
    Cfg.wasd           := ReadFlag("FixWasdArrows", true)
    Cfg.winalt         := ReadFlag("FixWinAlt", true)
    Cfg.enableOnLaunch := ReadFlag("EnableOnLaunch", false)
}

ReadFlag(key, default) {
    try
        return IniRead(State.settingsFile, "Settings", key, default ? "1" : "0") = "1"
    catch
        return default
}

SaveFlag(key, value) {
    try {
        SplitPath(State.settingsFile, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)
        IniWrite(value ? "1" : "0", State.settingsFile, "Settings", key)
    }
}

; =============================================================================
; Remapping
; =============================================================================

; Every remap hotkey is created once, switched off. Turning a group on or off
; later just enables or disables its hotkeys. While none are enabled the
; keyboard hook is not installed at all.
RegisterRemapHotkeys() {
    for group, pairs in REMAP_GROUPS {
        for pair in pairs {
            Hotkey("*" pair[1], RemapDown.Bind(pair[2]), "Off")
            Hotkey("*" pair[1] " up", RemapUp.Bind(pair[2]), "Off")
        }
    }
}

; Sends one synthetic key event.
;
; {Blind} leaves Shift, Ctrl and the other modifiers exactly as the player has
; them. The keys sent here are marked as synthetic, and the hook ignores its
; own synthetic keys, so W -> Up can never loop back into Up -> W.
;
; SendEvent is deliberate. AutoHotkey's default, SendInput, takes this app's
; keyboard hook away for the length of every send. A key that arrives in that
; gap slips through uncorrected, and its release then strands a held key. That
; is exactly what a fast roll across two keys does. SendEvent leaves the hook
; in place, so no key is ever missed.
Emit(keys) {
    SetKeyDelay(-1, -1)
    SendEvent("{Blind}" keys)
}

RemapDown(outKey, *) {
    Critical
    Emit("{" outKey " DownR}")
    State.held[outKey] := true
}

RemapUp(outKey, *) {
    Critical
    Emit("{" outKey " Up}")
    if State.held.Has(outKey)
        State.held.Delete(outKey)
}

SetGroup(group, on) {
    if (State.groupOn[group] = on)
        return
    wasCritical := Critical("On")
    pairs := REMAP_GROUPS[group]
    for pair in pairs {
        Hotkey("*" pair[1], on ? "On" : "Off")
        Hotkey("*" pair[1] " up", on ? "On" : "Off")
    }
    if on {
        ; A key that is already down was pressed before the fix came on. Its
        ; release is about to be remapped, so let go of the original now or the
        ; game would see it as held forever.
        for pair in pairs {
            if GetKeyState(Format("vk{:X}", GetKeyVK(pair[1])))
                Emit("{" pair[1] " Up}")
        }
    } else {
        for pair in pairs
            ReleaseHeld(pair[2])
    }
    State.groupOn[group] := on
    Critical(wasCritical)
}

; Lets go of one key this app is holding down. Win and Alt get a harmless
; filler key first, so letting go does not pop open the Start menu or a menu bar.
ReleaseHeld(outKey) {
    if !State.held.Has(outKey)
        return
    if (outKey = "LWin" || outKey = "LAlt")
        Emit("{vkE8}")
    Emit("{" outKey " Up}")
    State.held.Delete(outKey)
}

ReleaseAllHeld() {
    wasCritical := Critical("On")
    heldNow := []
    for outKey in State.held
        heldNow.Push(outKey)
    for outKey in heldNow
        ReleaseHeld(outKey)
    Critical(wasCritical)
}

; Applies the master switch and the two per-group ticks, then refreshes every indicator.
ApplyState() {
    SetGroup("wasd", State.masterOn && Cfg.wasd)
    SetGroup("winalt", State.masterOn && Cfg.winalt)
    RefreshUi()
}

SetMaster(on) {
    State.masterOn := !!on
    ApplyState()
}

IsCorrecting() => State.groupOn["wasd"] || State.groupOn["winalt"]

; Ctrl + Shift + F12 from anywhere. There is no window to look at inside a
; game, so the answer is a sound: rising for ON, falling for OFF.
EmergencyToggle(*) {
    SetMaster(!State.masterOn)
    if State.masterOn {
        SoundBeep(660, 70)
        SoundBeep(990, 90)
    } else {
        SoundBeep(990, 70)
        SoundBeep(660, 90)
    }
    KeyWait("F12", "T3")               ; one toggle per press, however long it is held
}

; Key releases that happen on the lock screen or a permission prompt never
; reach this app. Whenever Windows switches back to the normal desktop, let go
; of anything still held so no key comes back stuck.
WatchDesktopSwitches() {
    static callback := CallbackCreate(OnDesktopSwitch, , 7)
    DllCall("SetWinEventHook", "UInt", 0x20, "UInt", 0x20, "Ptr", 0, "Ptr", callback
        , "UInt", 0, "UInt", 0, "UInt", 0, "Ptr")      ; EVENT_SYSTEM_DESKTOPSWITCH
}

OnDesktopSwitch(hook, event, hwnd, idObject, idChild, idThread, time) {
    SetTimer(ReleaseIfOnNormalDesktop, -100)
}

ReleaseIfOnNormalDesktop() {
    desktop := DllCall("OpenInputDesktop", "UInt", 0, "Int", false, "UInt", 0x100, "Ptr")
    if !desktop
        return                         ; still on the secure desktop; another switch will follow
    DllCall("CloseDesktop", "Ptr", desktop)
    ReleaseAllHeld()
}

OnAppExit(reason, code) {
    State.masterOn := false
    SetGroup("wasd", false)
    SetGroup("winalt", false)
    ReleaseAllHeld()
}

; =============================================================================
; Start with Windows (a shortcut in the user's Startup folder, no registry)
; =============================================================================

StartupShortcut() => A_Startup "\" APP_TITLE ".lnk"

IsAutostartOn() => FileExist(StartupShortcut()) != ""

SetAutostart(on) {
    link := StartupShortcut()
    if !on {
        if FileExist(link)
            FileDelete(link)
        return
    }
    if A_IsCompiled
        FileCreateShortcut(A_ScriptFullPath, link, A_ScriptDir, "/tray", APP_TITLE)
    else
        FileCreateShortcut(A_AhkPath, link, A_ScriptDir, '"' A_ScriptFullPath '" /tray', APP_TITLE)
}

; If the exe was moved after the Startup shortcut was made, point the shortcut at the new place.
RepairStartupShortcut() {
    if !A_IsCompiled || !IsAutostartOn()
        return
    try {
        FileGetShortcut(StartupShortcut(), &target)
        if !FileExist(target)
            SetAutostart(true)
    }
}

; =============================================================================
; Window
; =============================================================================

BuildGui() {
    g := Gui("-MaximizeBox", APP_TITLE)
    g.MarginX := 16
    g.MarginY := 14
    g.SetFont("s10", "Segoe UI")
    Ui.gui := g

    ; Status banner: green when keys are being corrected, gray when not.
    g.SetFont("s15 bold")
    Ui.banner := g.AddText("xm ym w400 h48 Center 0x200 cFFFFFF Background" COLOR_OFF)
    g.SetFont("s9 norm")
    Ui.detail := g.AddText("xm y+6 w400 Center c444444")

    g.SetFont("s13 bold")
    Ui.toggle := g.AddButton("xm y+10 w400 h54")
    Ui.toggle.OnEvent("Click", OnToggleClick)
    g.SetFont("s9 norm")
    g.AddText("xm y+6 w400 Center c444444", "Quick switch from anywhere, even inside a game:  Ctrl + Shift + F12")

    g.SetFont("s10 norm")
    g.AddGroupBox("xm y+12 w400 h78 Section", "Keys to fix")
    Ui.wasd := g.AddCheckbox("xs+14 ys+24 w370", "W A S D and the arrow keys")
    Ui.wasd.OnEvent("Click", OnOptionClick)
    Ui.winalt := g.AddCheckbox("xs+14 y+8 w370", "Windows key and Alt key")
    Ui.winalt.OnEvent("Click", OnOptionClick)

    g.AddGroupBox("xm ys+88 w400 h78 Section", "Starting up")
    Ui.autostart := g.AddCheckbox("xs+14 ys+24 w370", "Start automatically with Windows")
    Ui.autostart.OnEvent("Click", OnAutostartClick)
    Ui.enableOnLaunch := g.AddCheckbox("xs+14 y+8 w370", "Turn the fix on as soon as this app starts")
    Ui.enableOnLaunch.OnEvent("Click", OnOptionClick)

    g.AddGroupBox("xm ys+88 w400 h172 Section", "Keyboard test")
    g.SetFont("s9")
    g.AddText("xs+14 ys+24 w372 c444444"
        , "Press a key. The box that lights up should match the label printed on that key.")
    g.SetFont("s11 bold")
    AddTile("W",     "W",          58, 62)
    AddTile("A",     "A",          14, 100)
    AddTile("S",     "S",          58, 100)
    AddTile("D",     "D",         102, 100)
    AddTile("Up",    Chr(0x2191), 208, 62)
    AddTile("Left",  Chr(0x2190), 164, 100)
    AddTile("Down",  Chr(0x2193), 208, 100)
    AddTile("Right", Chr(0x2192), 252, 100)
    g.SetFont("s9 bold")
    AddTile("Win",   "Win",       304, 100)
    AddTile("Alt",   "Alt",       346, 100)
    g.SetFont("s9 norm")
    Ui.lastKey := g.AddText("xs+14 ys+144 w372 c444444", "Windows received:  (press a key)")

    g.SetFont("s10 norm")
    hideButton := g.AddButton("xm ys+186 w150 h32", "Hide to Tray")
    hideButton.OnEvent("Click", OnHideClick)
    exitButton := g.AddButton("x266 yp w150 h32", "Exit")
    exitButton.OnEvent("Click", OnExitClick)

    Ui.wasd.Value           := Cfg.wasd
    Ui.winalt.Value         := Cfg.winalt
    Ui.enableOnLaunch.Value := Cfg.enableOnLaunch
    Ui.autostart.Value      := IsAutostartOn()

    g.OnEvent("Close", OnGuiClose)
    g.OnEvent("Size", OnGuiSize)

    for msg in [0x100, 0x101, 0x104, 0x105]    ; WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP
        OnMessage(msg, OnTestKey)
    OnMessage(0x0006, OnActivate)              ; WM_ACTIVATE
}

AddTile(id, label, dx, dy) {
    Ui.tiles[id] := Ui.gui.AddText(Format("xs+{} ys+{} w40 h34 Center 0x200 Border Background{}", dx, dy, COLOR_TILE), label)
}

ShowMain(*) {
    Ui.gui.Show()
    try WinActivate(Ui.gui)
    FocusTestArea()
}

; Keyboard focus rests on the test area, never on a button. Someone typing as
; the window appears would otherwise press the big switch with a stray Space
; or Enter. Parked here, those keys do nothing, and test keys work at once.
FocusTestArea() {
    try DllCall("SetFocus", "Ptr", Ui.lastKey.Hwnd, "Ptr")
}

HideToTray() {
    ClearTiles()
    Ui.gui.Hide()
    if !State.hideTipShown {
        State.hideTipShown := true
        TrayTip("Still running in the system tray. Click its icon to open it again.", APP_TITLE, "Iconi Mute")
    }
}

; Updates the banner, the button, the tray icon and the tray menu together.
RefreshUi() {
    correcting := IsCorrecting()

    if !State.masterOn {
        banner := "Keyboard Fix is OFF"
        detail := "Your keyboard is not being changed."
    } else if !correcting {
        banner := "Keyboard Fix is ON (nothing ticked)"
        detail := "Tick a box under Keys to fix to start correcting keys."
    } else {
        banner := "Keyboard Fix is ON"
        parts := []
        if State.groupOn["wasd"]
            parts.Push("W A S D + arrow keys")
        if State.groupOn["winalt"]
            parts.Push("Windows + Alt")
        detail := "Correcting:  " parts[1] (parts.Length > 1 ? "  and  " parts[2] : "")
    }

    Ui.banner.Text := banner
    Ui.banner.Opt("Background" (correcting ? COLOR_ON : COLOR_OFF))
    Ui.banner.Redraw()
    Ui.detail.Text := detail
    Ui.toggle.Text := State.masterOn ? "Disable Keyboard Fix" : "Enable Keyboard Fix"

    SetTrayIcon(correcting)
    A_IconTip := APP_TITLE ": " (correcting ? "ON" : "OFF")
    try A_TrayMenu.Rename("1&", State.masterOn ? "Disable Keyboard Fix" : "Enable Keyboard Fix")
}

OnToggleClick(*) {
    SetMaster(!State.masterOn)
    FocusTestArea()
}

OnOptionClick(*) {
    Cfg.wasd           := !!Ui.wasd.Value
    Cfg.winalt         := !!Ui.winalt.Value
    Cfg.enableOnLaunch := !!Ui.enableOnLaunch.Value
    SaveFlag("FixWasdArrows", Cfg.wasd)
    SaveFlag("FixWinAlt", Cfg.winalt)
    SaveFlag("EnableOnLaunch", Cfg.enableOnLaunch)
    ApplyState()
}

OnAutostartClick(*) {
    try {
        SetAutostart(!!Ui.autostart.Value)
    } catch as err {
        MsgBox("Windows would not change the Startup shortcut.`n`n" err.Message, APP_TITLE, "Icon!")
    }
    Ui.autostart.Value := IsAutostartOn()
}

OnHideClick(*) {
    HideToTray()
}

OnExitClick(*) {
    ExitApp()
}

; The window's X hides to the tray, so closing the window by accident never
; switches the fix off in the middle of a game. The Exit button really exits.
OnGuiClose(*) {
    HideToTray()
    return true
}

OnGuiSize(guiObj, minMax, *) {
    if (minMax = -1)                   ; minimized
        HideToTray()
}

; =============================================================================
; Keyboard test area
;
; Shows what Windows delivers to an ordinary window, which is what a game sees.
; It only looks at keys pressed while this window is in front, and it keeps
; nothing: one label on screen, replaced by the next key.
; =============================================================================

OnTestKey(wParam, lParam, msg, hwnd) {
    isUp := (msg = 0x101 || msg = 0x105)
    sc := (lParam >> 16) & 0xFF
    extended := (lParam >> 24) & 1
    id := TileFor(wParam, sc, extended)

    if !isUp
        Ui.lastKey.Text := "Windows received:  " DescribeKey(id, wParam, sc, extended)
    if (id = "")
        return                         ; every other key keeps its normal behaviour

    LightTile(id, !isUp)
    return 0                           ; test keys stop here: no focus jumps, no menu bar
}

TileFor(vk, sc, extended) {
    static plain := Map(0x11, "W", 0x1E, "A", 0x1F, "S", 0x20, "D")
    static arrows := Map(0x48, "Up", 0x4B, "Left", 0x50, "Down", 0x4D, "Right")
    if (vk = 0x5B)
        return "Win"
    if (vk = 0x12 || vk = 0xA4)
        return extended ? "" : "Alt"
    if extended
        return arrows.Has(sc) ? arrows[sc] : ""
    return plain.Has(sc) ? plain[sc] : ""
}

DescribeKey(id, vk, sc, extended) {
    static names := Map("W", "W", "A", "A", "S", "S", "D", "D"
        , "Up", "Up Arrow", "Left", "Left Arrow", "Down", "Down Arrow", "Right", "Right Arrow"
        , "Win", "Left Windows", "Alt", "Left Alt")
    if (id != "")
        return names[id]
    name := GetKeyName(Format("vk{:X}sc{:X}", vk, sc | (extended ? 0x100 : 0)))
    return name != "" ? name : Format("key code {}", vk)
}

LightTile(id, lit) {
    tile := Ui.tiles[id]
    tile.Opt("Background" (lit ? COLOR_ON : COLOR_TILE))
    tile.Opt(lit ? "cFFFFFF" : "cDefault")
    tile.Redraw()
}

ClearTiles() {
    for id in Ui.tiles
        LightTile(id, false)
}

OnActivate(wParam, lParam, msg, hwnd) {
    if ((wParam & 0xFFFF) = 0)         ; the window lost focus, so key releases may be missed
        ClearTiles()
}

; =============================================================================
; System tray
; =============================================================================

BuildTrayMenu() {
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Enable Keyboard Fix", OnTrayToggle)
    tray.Add("Open Settings", ShowMain)
    tray.Add()
    tray.Add("Exit", OnExitClick)
    tray.Default := "Open Settings"
    tray.ClickCount := 1               ; a single click on the icon opens the window
}

OnTrayToggle(*) {
    SetMaster(!State.masterOn)
}

SetTrayIcon(correcting) {
    try {
        if A_IsCompiled
            TraySetIcon(A_ScriptFullPath, -(correcting ? ICON_ON_RES : ICON_OFF_RES))
        else
            TraySetIcon(A_ScriptDir "\..\assets\" (correcting ? "icon-on.ico" : "icon-off.ico"))
    }
}
