# Testing MANIK Keyboard Fix

There are two layers of testing:

1. **Automated tests** that drive the real compiled exe and the real MSI on a Windows PC. They use
   synthetic key presses in place of the keyboard.
2. **A manual checklist** for what only a person with the real MANIK keyboard, real games and a real
   Windows sign-in can confirm.

The automated tests passing means the app's logic is right. They cannot tell you that a particular
game accepts the corrected keys, or that the physical keyboard sends what this document assumes it
sends. Section 2 exists for that.

## 1. Automated tests

Build first, then run either test from the project folder.

```
powershell -ExecutionPolicy Bypass -File build.ps1
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
powershell -ExecutionPolicy Bypass -File tests\msi-test.ps1
```

### `tests\run-tests.ps1`: the app

A small window opens and receives synthetic key presses. The test records what Windows actually
delivers to that window, which is what a game would receive. Results are written to
`tests\out\e2e-results.txt`.

It is safe to run on a PC that is in use:

- It waits until the keyboard and mouse have been idle for five seconds before it starts.
- It runs for well under a minute, and holds back real key presses while it runs. It checks at the
  start and at the end that the hold-back is working.
- If another window comes to the front mid-run (a click, a program opening), it stops at once,
  releases the keyboard, and starts over at the next quiet moment. An interrupted run concludes
  nothing and is never counted as a pass or a fail.

| Area | What is checked |
|---|---|
| Fix off | All ten keys pass through unchanged |
| Every correction | Each of the ten mappings, with exactly one output per input, so no mapping feeds another |
| Numeric keypad | Its arrows are left alone |
| Several keys at once | Two and three keys held together, released in a different order |
| Key repeat | Repeats of a held key arrive as repeats, followed by one release |
| Fast key rolls | Overlapping keys with no gap between events, and a 400-event burst: all corrected, none missed, in order |
| Modifiers | Shift, Ctrl, Ctrl + Shift and the corrected Alt, each held with a corrected key |
| Emergency switch | Ctrl + Shift + F12 turns the fix on and off |
| Toggling mid-press | Turning the fix off, or on, while a key is held leaves nothing stuck |
| Exit | Exiting while a key is held releases it, and all keys are normal afterwards |
| Force-close | Killing the process returns the keyboard to normal at once |
| Separate switches | W A S D only, Windows/Alt only, and neither |
| Settings | Choices are saved and loaded, and the settings file holds nothing but the three switches |
| Turn on at launch | The app starts with the fix on when asked to |
| Window | The button, the checkboxes, the status banner, and the keyboard test area |
| Stray keys | Keyboard focus does not start on a button, and Space or Enter cannot flip the switch |
| Start with Windows | Ticking the box creates the Startup shortcut, unticking removes it |
| Tray and single instance | Hide to Tray, minimize and the X all hide without exiting; a second launch reopens the first; `/exit` closes it |
| Resources | Memory in use, and no CPU used while idle with the fix on |
| Build | Version number and both tray icons are present in the exe |

### `tests\msi-test.ps1`: the installer

Installs, upgrades and uninstalls the MSI for the current Windows account, with no administrator
rights. It refuses to run if the app is already installed or has settings on that account, so it
cannot remove a real install. Results are written to `tests\out\msi-results.txt`.

| Step | What is checked |
|---|---|
| Install | No error and no administrator prompt; exe, Start menu and Desktop shortcuts present; listed once in Installed apps with the right version; the app opens by itself |
| Upgrade | A newer version installs over a running copy: the copy is closed first, there is still one entry, and the settings file and the Startup shortcut survive |
| Uninstall | A running copy is closed first; the program, both shortcuts, the Startup shortcut, the settings file and the registry marker are all gone |

### Results on record

Both tests were last run on 2026-11-25 against the exe and MSI in `dist\`, on Windows 11 Pro
(build 26200), built with AutoHotkey 2.0.32.

| Test | Result |
|---|---|
| `tests\run-tests.ps1` | 130 passed, 0 failed |
| `tests\msi-test.ps1` | 26 passed, 0 failed |

Measured during the run: about 14.5 MB of memory in use (3.2 MB private), and no CPU time used over
1.5 seconds of sitting idle with the fix on.

Two things were also checked by hand on that day, outside the committed tests:

- No keyboard hook exists while the fix is off. AutoHotkey holds a named marker for as long as its
  hook is installed. It was absent with the fix off, present with it on, and absent again after
  turning it off and after exit.
- The build's own guards work. A 901-line file, a deliberate script warning, and mismatched version
  numbers each stopped the build with an error.

One defect was found and fixed by these tests before release. AutoHotkey's default way of sending
keys removes the app's keyboard hook for the length of each send, and a key arriving in that gap
slipped through uncorrected and left a key held. The app now sends keys in a way that leaves the
hook in place, and the fast key roll tests cover it.

### What the automated tests do not cover

- The physical keyboard. Synthetic keys stand in for it.
- Any real game, including full-screen games, games run as administrator and games with anti-cheat.
- The tray icon's appearance and its right-click menu.
- The sounds of the emergency switch.
- The lock screen, permission prompts, sleep and sign-out.
- Starting with Windows after a real restart.
- Win + letter shortcuts. Sending those to a live desktop would trigger them.

All of these are in the checklist below.

## 2. Manual checklist

Do this once on the PC that will be used, with the MANIK keyboard plugged in. Tick each box as it
passes.

### A. Before the fix: confirm the fault

Open the app and leave the fix **off**. Use the **Keyboard test** area.

- [ ] Pressing the key labelled **W** lights the **up arrow** box (the fault, as expected)
- [ ] Pressing the key labelled **Up arrow** lights the **W** box
- [ ] Pressing the key labelled **Windows** lights the **Alt** box
- [ ] Pressing the key labelled **Alt** lights the **Win** box

If the boxes already match the labels, the keyboard is not in the swapped state and the fix is not
needed. If only one pair is swapped, untick the other under **Keys to fix**.

### B. All ten corrections

Click **Enable Keyboard Fix**. The banner turns green. In the **Keyboard test** area, each key should
now light the box that matches its own label.

- [ ] Key labelled **W** lights **W**
- [ ] Key labelled **A** lights **A**
- [ ] Key labelled **S** lights **S**
- [ ] Key labelled **D** lights **D**
- [ ] Key labelled **Up arrow** lights the up arrow
- [ ] Key labelled **Left arrow** lights the left arrow
- [ ] Key labelled **Down arrow** lights the down arrow
- [ ] Key labelled **Right arrow** lights the right arrow
- [ ] Key labelled **Alt** (left) lights **Alt**
- [ ] Key labelled **Windows** (left) lights **Win**, and the Start menu opens when it is released

Then, in Notepad:

- [ ] Typing `wasd` types the letters `wasd`
- [ ] The four arrow keys move the cursor in the right directions
- [ ] Holding a letter repeats it, and it stops the moment the key is released

### C. Several keys at once

In the **Keyboard test** area:

- [ ] Holding **W** and **D** together lights both boxes
- [ ] Holding **W**, **A** and **D** lights all three
- [ ] Letting go of one key turns off only its box
- [ ] Holding **W** and the **Up arrow** together lights both
- [ ] Rolling quickly across **A S D** and back never leaves a box lit

In a game:

- [ ] Diagonal movement (W + D, W + A) works
- [ ] Changing direction without lifting all fingers works
- [ ] The character stops when every key is released

### D. Modifier combinations

In Notepad, with some text typed:

- [ ] **Shift + W** types a capital `W`
- [ ] **Shift + arrow** selects text
- [ ] **Ctrl + arrow** jumps a word at a time
- [ ] **Ctrl + Shift + arrow** selects a word at a time
- [ ] **Ctrl + A**, **Ctrl + S** and **Ctrl + D** behave as they do in Notepad normally
- [ ] **Alt + Tab** (the key labelled Alt) switches windows
- [ ] **Alt + F4** closes a window
- [ ] **Windows + D** (the key labelled Windows) shows the desktop
- [ ] **Windows + E** opens File Explorer
- [ ] **Windows + arrow** snaps a window to that side

### E. Emergency switch

- [ ] **Ctrl + Shift + F12** with the fix on: two falling notes, banner turns gray, keys go back to swapped
- [ ] **Ctrl + Shift + F12** again: two rising notes, banner turns green, keys are corrected
- [ ] Holding the combination down toggles only once
- [ ] It works while the window is hidden in the tray
- [ ] It works inside a full-screen game
- [ ] Holding **W** in a game and pressing the switch does not leave the character moving

### F. Tray

- [ ] The tray icon is a **gray keycap with a bar** while the fix is off
- [ ] The tray icon is a **green keycap with a tick** while the fix is on
- [ ] Hovering over it shows `MANIK Keyboard Fix: ON` or `MANIK Keyboard Fix: OFF`
- [ ] Clicking the icon opens the window
- [ ] Right-click shows **Enable Keyboard Fix** or **Disable Keyboard Fix**, **Open Settings** and **Exit**
- [ ] The first menu item toggles the fix and its wording changes to match
- [ ] Minimizing the window hides it to the tray and the fix stays on
- [ ] The X hides it to the tray and the fix stays on
- [ ] Starting the app again while it is hidden reopens the same window

### G. Exiting and force-closing

- [ ] **Exit** (button or tray menu) closes the app, and the keys go back to swapped at once
- [ ] Exiting while holding **W** in Notepad leaves nothing repeating
- [ ] With the fix on, ending `MANIK Keyboard Fix` in Task Manager returns the keys to swapped at once
- [ ] After a force-close, one tap of any key that was held clears it

### H. Starting up

- [ ] With **Start automatically with Windows** ticked, restart the PC: the tray icon is there after sign-in
- [ ] With **Turn the fix on as soon as this app starts** also ticked, the icon is green and the keys are corrected with nothing clicked
- [ ] With both unticked, restart the PC: the app does not start
- [ ] The ticks are still as you left them after the app is closed and reopened

### I. Lock screen, permission prompts and sleep

- [ ] **Windows + L** locks the PC. After unlocking, the Windows key is not stuck (typing `e` types an `e` and does not open File Explorer)
- [ ] Holding **W** while a permission prompt (the dimmed "Do you want to allow" screen) appears, then answering it, leaves nothing stuck
- [ ] After sleep and wake, the fix is still working
- [ ] After signing out and back in, the keyboard is normal until the app starts again

### J. Games

Repeat for each game that matters.

- [ ] Movement with W A S D works
- [ ] Menus work with the arrow keys
- [ ] It still works when the game is full-screen
- [ ] The Windows key and Alt behave as labelled
- [ ] If nothing is corrected in one game only, see **Troubleshooting** in the README (administrator games and anti-cheat)

### K. Installer

- [ ] Double-clicking the MSI installs with no administrator prompt, and the app opens
- [ ] If a blue "Windows protected your PC" box appears, **More info** then **Run anyway** gets past it
- [ ] There is a **MANIK Keyboard Fix** shortcut on the Desktop and in the Start menu
- [ ] **Settings > Apps > Installed apps** lists it, and **Uninstall** removes it and both shortcuts
- [ ] After uninstalling, the app no longer starts with Windows

### L. Privacy and footprint

- [ ] `%APPDATA%\MANIK Keyboard Fix\` contains only `settings.ini`, and that file contains only three on/off lines
- [ ] Task Manager shows the app using almost no CPU while idle, and a few megabytes of memory
