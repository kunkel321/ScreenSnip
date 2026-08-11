# ScreenSnip — User Manual

- **Project:** ScreenSnip.ahk, an AutoHotkey v2 screen capture tool
- **Repository:** https://github.com/kunkel321/ScreenSnip
- **Forum thread:** https://www.autohotkey.com/boards/viewtopic.php?f=83&t=140802
- **Based on:** *Snipper* by FanaticGuru — https://www.autohotkey.com/boards/viewtopic.php?f=83&t=115622

---

## Table of contents

1. [What ScreenSnip is](#1-what-screensnip-is)
2. [Installation](#2-installation)
3. [Settings](#3-settings)
4. [Quick start](#4-quick-start)
5. [Capturing](#5-capturing)
6. [Freeze Capture](#6-freeze-capture)
7. [Working with a snip](#7-working-with-a-snip)
8. [Adjusting the capture after the fact](#8-adjusting-the-capture-after-the-fact)
9. [Rotate, Straighten, Flip](#9-rotate-straighten-flip)
10. [Exporting](#10-exporting)
11. [Text extraction: the local engines](#11-text-extraction-the-local-engines)
12. [Text extraction: the AI engine](#12-text-extraction-the-ai-engine)
13. [Imgur uploads](#13-imgur-uploads)
14. [Menu reference](#14-menu-reference)
15. [Keyboard and mouse reference](#15-keyboard-and-mouse-reference)
16. [Things that will bite you](#16-things-that-will-bite-you)
17. [Settings reference](#17-settings-reference)
18. [Credits](#18-credits)

---

## 1. What ScreenSnip is

ScreenSnip captures a region of your screen and leaves it floating on the desktop as a borderless, always-on-top window. You can have as many of these snips open at once as you like.

![A captured snip floating above the file manager it was taken from](Images/PostCaptureSnip.png)

That "floating window" part is the whole point. Most capture tools hand you a file or a clipboard blob and get out of the way. ScreenSnip instead gives you a persistent visual reference you can park next to whatever you're working on — a phone number from an email while you fill in a form, a chart from one PDF while you write about it in another, a config value from a webpage that keeps scrolling away.

Four things it does that the built-in Windows tools don't:

**It keeps a frozen snapshot around the edges of your capture.** When you drag a selection, ScreenSnip actually grabs a rectangle several hundred pixels larger than what you asked for and keeps it in memory. So if you clip the bottom of a sentence, you don't re-snip — you drag the snip's bottom edge down and the missing pixels are already there. Nothing on screen has to still be showing.

**It can capture things that vanish when you click.** Context menus, tooltips, and drop-downs all close the moment a mouse button goes down, which makes them impossible to capture with a drag gesture. Freeze Capture solves this with a keyboard trigger that photographs the entire desktop first, then lets you select from that still image.

**It can grab a whole window with one click.** During a Freeze Capture, hovering highlights the window under the cursor and a left-click takes it — no aiming at corners, no trimming afterwards.

**It reads text out of the capture — three different ways.** Two OCR engines run locally: a fast built-in Windows one, and PaddleOCR for harder material. A third path sends the image to an AI vision model, which is the only one of the three that can see a table's *ruling lines*. All of them put their result on the clipboard.

A short animated demo lives beside this manual as [`ScreenSnipDemo.gif`](ScreenSnipDemo.gif).

---

## 2. Installation

### The portable approach

ScreenSnip is distributed as a script, not a compiled executable. The repository convention — shared across all of kunkel321's ahk apps — is a **renamed copy of `AutoHotkey64.exe`** sitting next to the `.ahk` file.

Copy `AutoHotkey64.exe` into the ScreenSnip folder and rename it `ScreenSnip.exe`. When you run it, AutoHotkey looks for a script with its own name in its own folder and runs `ScreenSnip.ahk`. Nothing is compiled, so edits to the `.ahk` take effect on the next launch, and the whole folder stays portable — you can drop it on a flash drive and it works on a machine with no AutoHotkey installed.

You can also just run `ScreenSnip.ahk` directly if you have AutoHotkey v2 installed. The renamed-exe trick is about portability, not necessity.

### Folder layout

The top-level folder holds only the script and its exe. Everything else is in a subfolder, and the split is by **who writes it**:

```
ScreenSnip\
├─ ScreenSnip.ahk               the script
├─ ScreenSnip.exe               renamed copy of AutoHotkey64.exe
│
├─ Resources\                   shipped — ScreenSnip never writes here
│   ├─ SnipOCR.ahk              local OCR module
│   ├─ OCR.ahk                  Descolada's Windows OCR library
│   ├─ PaddleOCR-json\          the offline OCR engine + its models
│   ├─ SnipAI.ahk               AI vision module
│   ├─ SnipImgur.ahk            Imgur upload module
│   ├─ SnipWinDetect.ahk        window highlighting for Freeze Capture
│   ├─ ToolTipOptions.ahk       just me's tooltip styling library
│   ├─ SettingsManager.ahk      the settings editor
│   └─ SettingsManager.exe      renamed copy of AutoHotkey64.exe
│
├─ Data\                        settings and everything written at runtime
│   ├─ snipSettings.ini         every setting — see section 3
│   ├─ snipSettingsMetadata.json  labels, help text, types and ranges
│   ├─ ApiKeys.ini              Imgur Client ID + OpenAI API key — KEEP PRIVATE
│   ├─ ScreenSnip_error.log     written only if something throws
│   └─ (OCR / AI debug dumps)   only when a Debug setting is on
│
├─ Documentation\
│   ├─ ScreenSnip-Manual.md     this file
│   ├─ ScreenSnipDemo.gif
│   └─ Images\
│
└─ SavedImages\                 a handy target for Save Image As…
```

`Resources\` is inert: ScreenSnip reads from it and never writes to it. Everything that ScreenSnip or SettingsManager writes goes in `Data\` instead — your settings, your API keys, the error log, and any debug dumps.

**The one file in there that must stay private is `ApiKeys.ini`.** Neither value in it is a password, but the Imgur Client ID is rate-limited against your account and the OpenAI key spends your prepaid credit. If ScreenSnip lives in a git repository, that is the file to add to `.gitignore`.

`Data\` is created on first use. If the install folder is read-only, ScreenSnip falls back to writing beside the script rather than throwing an error on every OCR run.

Deleting `Data\snipSettings.ini` is a safe factory reset — see [section 3](#3-settings) for why.

`SavedImages\` is purely a convention. The first folder offered by Save Image As… comes from the `SaveDefaultFolder` setting (your Pictures folder as shipped), and after that the last folder you actually saved to wins for the rest of the session.

Paths in this manual are given relative to the ScreenSnip folder. Note that in AHK v2 a relative `#Include` resolves against the folder of the *file containing the directive*, not the working directory — which is why `SnipOCR.ahk`'s own `#Include OCR.ahk` finds Descolada's library sitting beside it in `Resources\` with no path of its own.

### The add-on modules

Every add-on is optional and every one is included the same way, from the bottom of `ScreenSnip.ahk`:

```ahk
#Include *i Resources\SnipOCR.ahk
#Include *i Resources\SnipAI.ahk
#Include *i Resources\SnipImgur.ahk
#Include *i Resources\SnipWinDetect.ahk
#Include *i Resources\ToolTipOptions.ahk
```

The `*i` flag means "include only if the file exists." Delete any module — or comment out its line — and ScreenSnip still runs; the feature's menu items are simply left off.

| Module | Sentinel class | What it adds | What it needs |
|---|---|---|---|
| `SnipOCR.ahk` | `OcrCfg` | OCR → Copy Text (Windows) · Copy Text (PaddleOCR) · Copy Table (PaddleOCR) | `Resources\OCR.ahk` and/or `Resources\PaddleOCR-json\` |
| `SnipAI.ahk` | `SnipAiCfg` | OCR → Copy Text (AI) · Copy Table (AI) · Ask AI About Snip… | An OpenAI API key. **Paid, and the image leaves your machine** |
| `SnipImgur.ahk` | `Imgur` | Imgur submenu + the Uploader dialog | A free Imgur account and Client ID |
| `SnipWinDetect.ahk` | `WinDetectCfg` | Window highlighting during Freeze Capture | Nothing. No setup at all |
| `ToolTipOptions.ahk` | `ToolTipOptions` | Readable tooltips — font, colors, padding | Nothing. No setup at all |

`SettingsManager` is optional on the same terms but isn't `#Include`d — it's a separate program that ScreenSnip launches. Absent from `Resources\`, the two **Settings…** menu items are simply never added. See [section 3](#3-settings).

The mechanism behind the "sentinel class" column is worth one paragraph, because it explains an oddity you'll notice in the source. Each module declares a class, and ScreenSnip tests for it with `IsSet()` before building any menu or calling any function that depends on it. Class objects are created at load time, *before* the auto-execute section runs, regardless of where in the file the class is declared — which is why an `IsSet(OcrCfg)` test near the top of the script can see a class declared in a file that isn't `#Include`d until 3,000 lines further down. Calls into the modules then go through the `%name%()` dynamic form, because a *direct* call to a function that might not exist is a load-time error in v2, which would defeat the whole arrangement.

`ToolTipOptions.ahk` is the one exception to that dynamic-call rule, and it's instructive rather than inconsistent: everything it exposes is a *method on the sentinel class itself*, so `ToolTipOptions.Init()` is a variable dereference followed by a method call. An unset variable is a runtime matter, not a load-time error, so no dance is needed.

If **neither** `SnipOCR.ahk` nor `SnipAI.ahk` is present, the OCR submenu is omitted entirely rather than left on the menu empty.

### Upgrading from an older install

Older versions kept everything in one flat folder and stored the Imgur Client ID in `ImgurClientID.ini` beside the script. On first use, ScreenSnip migrates that ID into `Data\ApiKeys.ini` and renames the original to `ImgurClientID.ini.bak`. Nothing is destroyed, and downgrading to an older ScreenSnip still works.

If the migration fails — read-only folder, file in use — ScreenSnip keeps reading the legacy file so uploads carry on working.

### Starting with Windows

Two options, and which one you want depends on whether you need to capture elevated windows.

**Tray menu → Start with Windows** creates a shortcut in your Startup folder. Simple, works fine, and ScreenSnip will run at normal integrity.

**Task Scheduler with "Run with highest privileges"** is what you need if you want to snip elevated applications. See [section 16](#16-things-that-will-bite-you) for why. A Startup-folder shortcut to an elevation-requesting program is silently skipped by Windows at logon, so the Startup folder is not a route to running elevated — Task Scheduler is.

---

## 3. Settings

Every configurable value in ScreenSnip and its add-on modules lives in one file:

```
Data\snipSettings.ini
```

It's a plain INI, so any text editor will do. But the intended way in is **SettingsManager**, reachable from either menu:

- **Tray menu → Settings…**
- **Right-click a snip → Settings…**

Both items are present only when `Resources\SettingsManager.exe` (or `SettingsManager.ahk`) exists. Delete it and they vanish rather than sitting there dead.

### Why an editor rather than a config block

ScreenSnip used to keep its settings in a long commented block at the top of the script, and each setting's explanation sat in a comment beside it. Those explanations have moved into `Data\snipSettingsMetadata.json`, which supplies SettingsManager's labels, help text, value types, and valid ranges.

That is the entire point of the move: the guidance is now **in front of the person changing the setting**, in a help pane that updates as you select each item, instead of in a source file they may never open. If you want to know what something does, select it in SettingsManager and read the pane. This manual's [settings reference](#17-settings-reference) is a map of the file, not a replacement for that help text.

### Three things to know about how it loads

**Settings are read once, at launch.** Nothing re-reads the file, so a change takes effect on the next start. SettingsManager offers a restart after you save; take it. Note that restarting closes any snips you have open, so finish with them first.

**Deleting `snipSettings.ini` is a safe factory reset.** Every setting is read through a helper that carries a coded fallback, so a missing file, a missing key, or a blank value all quietly produce the built-in default. The script starts normally and behaves as shipped.

**A corrupt or locked file degrades rather than breaks.** The whole load is wrapped so that a malformed INI fails to an empty set of values, which means every setting falls back and ScreenSnip still runs. That matters more than it sounds: the add-on modules ask for their settings during class initialisation, which happens *before* the main script's first line executes, so an exception there would be a load-time failure — ScreenSnip simply wouldn't start.

One consequence of that ordering is worth knowing if you go poking at the source. The settings cache is deliberately lazy, filled by whichever caller asks first, precisely because the modules at the bottom of the file ask before the settings block at the top has run.

### File conventions

| Convention | |
|---|---|
| Booleans | `1` = on, `0` = off |
| Colors | Six hex digits, `RRGGBB`, no `0x` and no `#` |
| Line breaks in text | `` `n `` — the script converts it to a real break |
| Relative paths | Resolved against the ScreenSnip folder |
| `%USERPROFILE%` | Expanded in path settings |

A value's *type* follows its fallback rather than the file: a setting whose default is `250` comes back as an integer, one whose default is `0.55` comes back as a float, and one whose default is text comes back as text. Type something non-numeric where a number belongs and that key falls back rather than producing nonsense. The same is true of colors — anything that isn't six valid hex digits is rejected, which stops a typo'd `TransColor` from punching holes in every snip.

### Tooltip appearance

ScreenSnip reports OCR results, AI progress, upload status, and the Freeze Capture window readout through Windows tooltips. Left plain, those are small, pale yellow, and hard to read against a busy screenshot — which is a poor fit for a message you're meant to glance at and act on.

`Resources\ToolTipOptions.ahk`, by AHK forum member **just me**, fixes that. It is an unmodified copy of his library, dropped in as-is so it can be replaced wholesale whenever he posts an update. The `[Tooltips]` section of the INI feeds it a font, a size and style, foreground and background colors, four margins, and an optional title with an icon.

The clever part is *how* it applies: it subclasses the tooltip window class rather than wrapping the `ToolTip()` function. **No call site anywhere changes.** Every `ToolTip()` in every module, present and future, is styled or not depending only on whether that one file exists. Delete it and they all fall back to the plain Windows tooltip, with nothing else to undo.

Two defaults are worth noticing. `TipBackColor` and `TipTextColor` fall back to the Freeze Capture hint's colors, so the hint pill and the status tooltips read as one visual family unless you deliberately separate them. And `EnhanceToolTips=0` turns the styling off while leaving the file in place, which is the setting to reach for if you'd rather have system-standard tooltips than delete anything.

If a tooltip setting is invalid — a typo'd style word, a size outside 1–255 — ScreenSnip says so once, undoes any half-applied styling, and carries on with plain tooltips for that session. You get consistently plain rather than, say, huge but still pale yellow.

The Freeze Capture hint pill is **not** a tooltip, incidentally. It's a window of its own, configured separately under `[FreezeHint]`.

---

## 4. Quick start

1. Launch ScreenSnip. A scissors icon appears in the system tray.
2. Hold **Ctrl** and **right-click-drag** a rectangle around something on screen.
3. Release. The captured region is now a floating window.
4. **Left-drag** it wherever you want it.
5. Press **Esc** while it's focused to close it, or **F1** for the full hotkey list.

That's the core loop. Everything else in this manual is refinement.

Two shortcuts worth learning immediately: add **Shift** to the capture drag (`Ctrl+Shift+RButton`) to also copy the image to the clipboard, and double-tap **CapsLock** to start a [Freeze Capture](#6-freeze-capture).

---

## 5. Capturing

### The normal drag

Hold `Ctrl` and drag with the **right** mouse button. A translucent overlay follows your drag, with width and height labels in the corner once the selection is big enough to fit them.

![A selection in progress, showing the translucent overlay and its width and height labels](Images/DuringCaptureRec.png)

The labels appear at 75 px wide for the W label and 55 px tall for the H label — below that they'd overlap the selection itself.

Release to create the snip. Selections smaller than 8×8 px are discarded, so a stray Ctrl+right-click won't litter your desktop with tiny snips.

Add `Shift` to also drop the image on the clipboard as you capture.

**Why the right button?** Left-drag is the universal "select things" gesture and is claimed by nearly every application. Right-drag is not, so ScreenSnip can take it without fighting anything.

### Show / hide everything

`Shift+PrintScreen` toggles all open snips at once. This is more useful than it sounds — it's how you take a screenshot *of* your desktop without a dozen snips cluttering it, and how you check what's underneath a snip without moving it.

The snips aren't closed, just hidden. Press it again and they all come back where they were.

---

## 6. Freeze Capture

### The problem

Try to capture a context menu with a normal drag and you can't. Pressing a mouse button dismisses the menu, so by the time the drag starts there's nothing left to capture. The same goes for tooltips, drop-down lists, and anything else that closes on a click elsewhere.

### The solution

Freeze Capture is triggered by a **key**, not a click. The instant you press it, ScreenSnip BitBlts the entire virtual desktop into memory and puts up a full-screen backdrop showing that frozen image. The real menu is then free to close — its pixels are already captured.

You then right-drag a selection on the frozen image exactly as you normally would. The snip is cut from the bitmap, never re-read from the screen.

A pleasant consequence of that design: anything ScreenSnip itself floats over the backdrop — the hint message, the dimension labels, the selection rectangle, the window outline — is invisible to the capture by construction. There's no need for the code to hide its own UI before grabbing, because the grab already happened. The one rule that keeps this true is that nothing is ever re-grabbed from the screen after the initial freeze.

### Window highlighting

With `SnipWinDetect.ahk` present, a freeze does more than hold still. Move the mouse and the window beneath the cursor is outlined in blue, with a small readout beside the cursor giving its title, its window class, and its size. Left-click and you get that window whole.

![A frozen screen with Notepad outlined in blue, its title and size shown beside the cursor, and the hint pill explaining the gesture](Images/FreezeCapWindowSelection.png)

| Gesture | Result |
|---|---|
| Move the mouse | Highlight the window under the cursor |
| **Left-click** | Capture the highlighted window whole |
| **Wheel up / down** | Cycle to a window stacked underneath this one |
| Right-drag | Freehand region selection, exactly as before |
| `Esc` | Cancel |

When more than one candidate sits under the cursor, the readout shows a position — `[1 of 4] — wheel to cycle` — so you know there's something behind the thing you're pointing at. Each monitor is offered as a candidate too, appended to the *end* of the list. That ordering does three jobs at once: a real window under the cursor always wins, a whole screen is always one wheel-step past the last window, and hovering over empty desktop still highlights something.

**This is not image analysis.** The frozen backdrop is only a picture laid over the desktop — the real windows are still sitting underneath it at the same coordinates, so the window tree can simply be queried. SnagIt does the same thing. Freeze mode is in fact the ideal case for it: because the screen is frozen, nothing can move, so the entire top-level window list is snapshotted *once* when the freeze begins and every mouse-move afterwards is just an in-memory rectangle test. No API calls while hovering, so it stays smooth, and no chance of a window shifting between the moment it was highlighted and the moment it was captured.

Two details you may notice:

**The outline hugs the visible window, not the invisible one.** Most windows carry an invisible resize border down the left, right, and bottom that `GetWindowRect` reports as part of the window. Capturing that rect would drag a strip of whatever is behind the window into the snip, so the true visual bounds are used instead.

**The wheel is bound only during a freeze.** A permanently registered `WheelUp` would put ScreenSnip in the mouse-hook chain for every scroll on the machine, so the two wheel hotkeys are registered when the freeze starts and unregistered when it ends. They're also *suppressing* rather than pass-through, on purpose: the screen is frozen, and letting the wheel through would scroll the real window underneath while the backdrop kept showing the old pixels — the snip you finally cut wouldn't match what you saw.

Scope is **top-level windows only**. Child controls — toolbars, list panes, individual buttons — would need per-control enumeration, and modern apps (Chrome, Electron/VSCode, UWP, WPF) draw everything inside a single HWND and would need UI Automation on top of that. Neither is attempted. For anything smaller than a window, right-drag a region.

Delete `SnipWinDetect.ahk` and all of this goes away cleanly: no highlighting, no wheel binding, and the hint pill reverts to wording that doesn't advertise a click that does nothing.

### Using it

| Action | Result |
|---|---|
| Double-tap `CapsLock` (default) | Freeze the screen |
| Left-click a highlighted window | Grab it whole |
| Right-drag on the frozen image | Select a region |
| Hold `Shift` when you release | ...and copy to clipboard |
| `Esc` | Cancel, unfreeze, capture nothing |

The tray menu also has a **Freeze Capture** item. It's a discoverable way in for anyone who never reads the config block, and a fallback when another script has won the race for the trigger key.

### Choosing a trigger key

The trigger is set by `FreezeCaptureKey` in the `[FreezeCapture]` section of the settings. It ships as `CapsLock`, with `FreezeDoublePress` on.

The double-press default exists for a specific reason. The hotkey is registered with `~` (pass-through), so the key keeps doing its normal job. On a toggle key like CapsLock or ScrollLock, two presses turn the lock on and then straight back off — net effect zero, lock state untouched. A single-press trigger on the same key would leave CapsLock stuck on every time you used it.

Candidate keys, with the tradeoffs:

- **`ScrollLock`** — arguably the best choice. Almost nothing uses it, it has a status LED, and no application will fight you for it.
- **`CapsLock`** — fine *if* no other AHK script already claims CapsLock. Each script installs its own keyboard hook, and if a hook earlier in the chain consumes the key, ScreenSnip never sees it.
- **`PrintScreen`** — the conventional choice, but SnagIt and Windows 11's Snipping Tool both grab it. Only viable if nothing else on your machine wants it.

Set `FreezeCaptureKey := ''` to disable the built-in trigger entirely.

### The cross-script trigger

If another script already owns the key you'd like to use, don't fight over it. ScreenSnip listens for a registered window message and will start a Freeze Capture whenever it arrives. `RegisterWindowMessage` returns the same ID in every process for a given string, so no shared file and no hard-coded number is needed.

From the script that owns the key:

```ahk
~CapsLock:: {
    static lastTick := 0, msg := DllCall('RegisterWindowMessage'
                                , 'Str', 'AHK_ScreenSnip_FreezeCapture', 'UInt')
    if (A_TickCount - lastTick <= 400) {
        lastTick := 0
        try PostMessage(msg, 0, 0, , 'ahk_id 0xFFFF')
    } else
        lastTick := A_TickCount
    SetCapsLockState('Off')      ; whatever that script normally does
}
```

This is a harmless no-op when ScreenSnip isn't running, so it can live in a library unconditionally.

### The CapsLock nullify option

`FreezeNullifyCapsLock` (default `true` in the shipped config) switches CapsLock back off after *every* press, single or double, so a stray press can't leave it on. It only takes effect when `FreezeCaptureKey` is actually `CapsLock`, so it can't surprise someone who chose a different key.

The hotkey is non-suppressing either way, so other scripts' CapsLock bindings still fire — only the lock *state* is reset afterwards. If you have another script that reads the caps state rather than just hotkeying on the key, leave this false.

---

## 7. Working with a snip

A snip is an ordinary window as far as your mouse is concerned — click it to focus it, and the hotkeys in this section apply to whichever snip is focused.

### Mouse gestures

| Gesture | Effect |
|---|---|
| Left-drag | Move the window |
| Right-drag | Pan the image within the frame (hand-tool style) |
| `Alt` + drag an edge or corner | Resize the capture region — trim or grow |
| Right-click | Context menu |
| `Alt` + wheel | Transparency ± 10 |

![Right-dragging inside a snip pans the image within its frame](Images/DragPanAnimated.gif)

Right-drag has a small dead zone at the start (`PanClickSlop`, 5 px) so that a plain right-click opens the menu instead of nudging the image a pixel. Drag further than that and it becomes a pan.

Pan sensitivity is set by `PanDragDivisor` (default 3), meaning three pixels of mouse travel move the image one pixel. That sounds sluggish until you try to nudge a single row of text into view, at which point it's exactly right. Set it to 1 for 1:1 tracking. The fractional remainder is carried between frames, so slow drags move smoothly rather than stair-stepping.

### The border and bevel

Each snip gets a colored border (`ShowSnipBorder`, `BorderColor`, `BorderThickness`) with an optional 3D bevel — lighter on the top and left, darker on the bottom and right, both derived from the border color.

![Two snips overlapping, the focused one with a stronger bevel and a deeper shadow](Images/TwoSnipsShowingBorderAndShadows.png)

The **focused** snip's bevel is drawn at full strength; unfocused snips are dimmed by `Bevel3DInactiveDarknessFactor`. Same shape, same contrast, just darker overall. It's a focus cue that doesn't require a second border color.

The bevel is automatically disabled above `Bevel3DMaxThickness` (default 3 px), because thick beveled frames look chunky.

### The drop shadow

Each snip can cast a soft translucent shadow down and to the right. It's a separate click-through window glued to the snip via `WM_WINDOWPOSCHANGED` — the snip window itself is never touched, which is what keeps the geometry code from having to know about shadows at all.

Like the bevel, the shadow participates in the focus cue: `ShadowOffset` for the active snip, `ShadowOffsetInactive` (smaller) for the rest, so the focused snip appears to lift forward off the desktop.

The shadow is suppressed automatically in two cases: at skewed or non-cardinal angles (a rectangular shadow behind a tilted snip looks wrong), and whenever the snip isn't fully opaque (a shadow behind a see-through window is incoherent).

Toggle it per-snip from the right-click menu.

### Transparency

`Alt+Up` / `Alt+Down` steps opacity by 25; `Alt+wheel` steps by 10. Useful for tracing — drop a snip to half opacity over a document and you can see both at once.

![A snip at reduced opacity, with the window beneath it showing through](Images/SemiTransparentSnip.png)

Remember the shadow disappears below full opacity. That's intentional, not a bug.

---

## 8. Adjusting the capture after the fact

This is ScreenSnip's most distinctive feature, and the one most worth understanding properly.

### How it works

When you drag a selection, ScreenSnip doesn't capture just that rectangle. It captures a **frozen master snapshot** extending `CaptureAdjustMargin` pixels (default 250) beyond your selection in every direction, and keeps it in memory for the life of the snip.

What you see in the floating window is a crop of that snapshot. So "adjusting the capture" is really just moving the crop rectangle around inside an image you already have. The screen behind it can have scrolled, closed, or changed entirely — irrelevant. Nothing is ever re-read from the screen.

![Alt-dragging a snip's edge grows the capture region into pixels that were never on screen when the drag began](Images/DragResizeAnimation.gif)

### Panning the region

Moves the crop over the snapshot. The frame stays put; different pixels show through it.

| Keys | Step |
|---|---|
| `Ctrl+Alt+Arrow` | 1 px |
| `Ctrl+Shift+Alt+Arrow` | 10 px |
| Right-drag | Continuous |

### Resizing the region

Grows or shrinks the crop. The frame changes size to match.

| Keys | Step |
|---|---|
| `Win+Alt+Arrow` | 1 px (Right/Down grow) |
| `Win+Shift+Alt+Arrow` | 10 px |
| `Alt` + drag an edge/corner | Continuous, opposite edge stays put |

### The margin tradeoff

`CaptureAdjustMargin` is the maximum you can pan or grow in any direction before you hit the edge of the snapshot. Bigger margin, more headroom — but a 32-bit bitmap costs `width × height × 4` bytes, and that's per snip.

- `0` — no headroom. The region is fixed at exactly what you selected.
- `150` — comfortable for fixing small clipped edges.
- `250` — the shipped default.
- `99999` — effectively snapshots the entire desktop into every snip.

Oversized values are safe: the number is clamped to the virtual desktop bounds, so you get "everything" and higher RAM use rather than a crash.

Note that Straighten also draws on this margin (see below), so if you deskew a lot, a larger margin buys you more clean rotation before the corners run past the snapshot edge.

### Distinguishing the three "move" operations

Easy to conflate, so:

| Operation | What moves | Keys |
|---|---|---|
| **Nudge window** | The floating window, on your desktop | `Ctrl+Arrow` |
| **Pan region** | The crop, over the frozen snapshot | `Ctrl+Alt+Arrow` |
| **Resize region** | The crop's size | `Win+Alt+Arrow` |

Nudging changes nothing about the image. Panning and resizing change what the image *is*.

---

## 9. Rotate, Straighten, Flip

### Rotate

Turns the **whole snip, frame and all**. The window itself becomes a rotated rectangle.

![A snip rotated off-axis, its corners keyed out so the desktop shows through](Images/RotatedSnip.png)

| Keys | Effect |
|---|---|
| `Alt+Left` / `Alt+Right` | ± 1° |
| `Shift+Alt+Left` / `Right` | Snap to the next 30° |
| Menu → Rotate | 90° CW, 180°, 90° CCW |

At angles other than 0/90/180/270 the border is suppressed and the corners are keyed out with magenta (`TransColor`, `0xFF00FF` — chosen because that exact value essentially never occurs in a real screenshot). See [section 16](#16-things-that-will-bite-you) for the known halo artifact.

### Straighten (deskew)

Tilts the **image inside a fixed rectangular frame**. The frame stays axis-aligned; only the content rotates.

![A scanned table straightened inside its frame, the rows now level](Images/SnipWithStraightenedTable.png)

| Keys | Effect |
|---|---|
| `Alt+,` / `Alt+.` | ± 1° (CCW / CW) |
| `Shift+Alt+,` / `.` | ± 0.5°, fine |
| Menu → Straighten → Reset | Back to level |

Clamped to `StraightenMaxAngle` (15°), though in practice the margin runs out first.

**The main use case is squaring up a skewed table before OCR.** A photographed or scanned table that sits a couple of degrees off level confuses the row-and-column clustering badly. Straighten it, then `Alt`-drag an edge to trim the exposed corners, then run Copy Table.

The pivot behaviour is subtle but deliberate: content rotates about the centre of the crop *as it was when you began straightening*, and that pivot is then held fixed until you return to level. This means you can pan around afterwards and the frame slides over one stable rotated image — no swirling — while the tilt itself still turns about what you were actually looking at.

### Flip

![A snip flipped horizontally beside the original text it was taken from](Images/SnipWithSideToSideFlip.png)

| Keys | Effect |
|---|---|
| `Shift+Left` / `Shift+Right` | Flip horizontal |
| `Shift+Up` / `Shift+Down` | Flip vertical |

---

## 10. Exporting

### Clipboard

`Ctrl+C`, or menu → Copy to Clipboard. Copies exactly what you see — current crop, rotation, straighten, and flips all applied.

### Save to file

`Ctrl+S`, or menu → Save Image As…

- Formats: **PNG**, **JPG/JPEG**, **BMP**. Type no extension and you get PNG.
- Default filename is `ScreenSnip_yyyyMMdd_HHmmss.png`.
- Defaults to your Pictures folder the first time, then remembers the last folder you used for the rest of the session. Point it at `SavedImages\` once and it will stay there.
- **PNG saves with real transparency.** JPG and BMP can't carry an alpha channel, so a rotated snip's corners come out filled rather than transparent. If you've rotated something and want clean corners, save as PNG.

Everything goes through the same rendering pipeline (`BuildSaveBitmap`), so saving, clipboard, Imgur upload, and every OCR path all operate on identical pixels.

---

## 11. Text extraction: the local engines

The right-click menu's **OCR** submenu is assembled from whichever text-extraction modules are installed. With both present you get six items, split by a separator.

![The OCR submenu, showing the three local actions above the separator and the three AI actions below it](Images/SnipWithOcrSubMenuShowing.png)

That separator is not decoration. **Below it, the image leaves your computer.** This section covers the three items above the line; [section 12](#12-text-extraction-the-ai-engine) covers the three below.

All six copy their result to the clipboard and report with a brief tooltip. Those tooltips carry real information — a row and column count, a warning about shaky cells — so it's worth making them legible; see [tooltip appearance](#3-settings).

### The three local actions

| Action | Engine | Best for |
|---|---|---|
| Copy Text (Windows) | Windows.Media.Ocr | Quick grabs. Instant, no setup beyond one library file |
| Copy Text (PaddleOCR) | PaddleOCR-json | Harder material — small text, low contrast, unusual fonts |
| Copy Table (PaddleOCR) | PaddleOCR-json | Grids. Reconstructs rows and columns, outputs TSV for Excel |

### Choosing between all three engines

Since the AI path overlaps with these, here is the whole picture in one place:

| | Windows OCR | PaddleOCR | AI vision |
|---|---|---|---|
| Speed | Instant | A second or two | Several seconds |
| Cost | Free | Free | Fractions of a cent per snip |
| Runs offline | Yes | Yes | **No** |
| Reproduces text verbatim | Yes | Yes | Usually — but may silently tidy |
| Understands tables | No | By clustering text boxes | By reading the ruling lines |
| Handles odd layouts | Poorly | Moderately | Well |

The short version: reach for Windows OCR by default, PaddleOCR when it struggles, and the AI when the *layout* is the hard part rather than the characters.

### Setting up Windows OCR

Download `OCR.ahk` from **https://github.com/Descolada/OCR** and drop it in `Resources\`, beside `SnipOCR.ahk`. It is included by that file with a plain `#Include OCR.ahk` — no path needed, and no `*i` flag, which means the file must be there. See [section 16](#16-things-that-will-bite-you) if you'd rather not have it.

If the library is present but Windows OCR itself is unavailable, the menu item reports as much and everything else keeps working.

### Setting up PaddleOCR

1. Download **PaddleOCR-json** (Windows x64) from https://github.com/hiroi-sora/PaddleOCR-json/releases/latest
2. Unzip it into `Resources\`. You want the folder containing `PaddleOCR-json.exe` **and** its `models` subfolder — these must stay together, because the engine is launched with that folder as its working directory and that's how the language config resolves.
3. If you put it elsewhere, point `OcrPaddleExe` at the `.exe`. The default expects `Resources\PaddleOCR-json\PaddleOCR-json.exe`.
4. Leave `OcrLangConfig` at `models\config_en.txt` for English. **The engine defaults to Simplified Chinese if this is blank.** Other configs shipped in the release: `config_chinese_cht.txt`, `config_japan.txt`, `config_korean.txt`.

Requires a CPU with AVX — any modern Core or Ryzen. If yours lacks it, RapidOCR-json is a drop-in substitute with the same JSON output.

### How table reconstruction works

PaddleOCR doesn't return a table. It returns loose text blocks with bounding boxes. ScreenSnip rebuilds the grid by clustering those boxes: blocks whose vertical centres are close become a row, blocks whose left edges are close become a column.

Both tolerances are expressed as a fraction of the **median text-block height**, so they scale automatically with font size and with the upscale factor — you shouldn't need to retune them when you switch between a small screenshot and a large one.

| Setting | Default | Raise it if... | Lower it if... |
|---|---|---|---|
| `RowTol` | 0.60 | One visual row is splitting in two | Two rows are merging |
| `ColTol` | 1.20 | One column is splitting | Two columns are merging |

This clustering approach has one structural limitation worth knowing, because it's the reason the AI table path exists: the engine only ever sees rectangles of *text*, never the drawn borders. A token that happens to land at the same x-coordinate in every row therefore reads as a column, even when it's purely an artifact of line wrapping inside one wide cell.

### Wrapped cells and reflow

A cell whose text wraps onto three lines arrives as three separate blocks, so a 5-row table can come out as 31 rows. Reflow stitches them back together.

The decision is made by measuring the **whitespace between consecutive rows** — not centre-to-centre pitch, which is contaminated by text height. In a table with wrapped cells those gaps are strongly bimodal: small gaps are line spacing inside a cell, large gaps are actual row borders. Split them into two groups, and reflow only if the large group is clearly bigger than the small one (`ReflowRatio`, default 1.8). In a table with no wrapping the gaps are all the same size and nothing gets merged.

But gaps alone aren't enough, and a real document proved it: on a scanned service grid, an 85 px gap sat *inside* a cell because a faint dash was never detected, while a genuine row border was only 39 px. The geometry lied. So there's a second test — the **anchor column** (`ReflowAnchorCol`, default column 1), which holds a label on every logical row and is blank on continuation lines. A new logical row must satisfy **both**: a big gap above it *and* content in the anchor column. Set it to 0 to use gaps alone; it falls back to gaps automatically if the anchor column turns out to be too sparse.

### The "this isn't a table" guard

If more than `NotATableWarn` (default 60%) of the text sits in a single column, the snip is almost certainly prose or a form rather than a grid, and Copy Text will do a far better job. ScreenSnip offers to switch rather than silently producing a mangled TSV.

Measured on real documents: a numeric grid ran 7%, a rubric 27%, a scanned service matrix 40% — but a one-column form with bullets hit 77%. Set to 0 to disable the prompt.

### Confidence

`MinScore` defaults to **0 — keep everything** — and that default is deliberate.

The reasoning: a confidence filter would earn its keep if a junk block could *shift* your data, but it can't. Every block is snapped to a column anchor, so dropping one leaves a hole and moves nothing. Filtering therefore buys no safety and costs real cells. And a hole is worse than a typo — a misread value is visible and fixable, whereas a dropped one just looks like a legitimately empty cell. On a real 21×20 table, `MinScore` 0.5 silently discarded 41% of it.

Raise it only when you're OCRing prose and want to suppress noise.

Instead of dropping cells, Copy Table **counts** the shaky ones (confidence below 0.6) and tells you in the completion tooltip. The table's *shape* is reliable; individual readings may not be. Those are the cells to eyeball against the original.

`MarkBelow` will append `?` to low-confidence cells so you can find them with Ctrl+F in Excel — but note that makes those cells text rather than numbers, so leave it at 0 for tables you'll compute on.

### Upscaling

Screen text is typically 10–14 px tall, right at the edge of what OCR engines handle well. `OcrUpscale` (default 3) bicubically enlarges the image before OCR, which makes a large accuracy difference for almost no cost.

There's a trap here worth knowing about. Paddle downsizes any image whose long edge exceeds `limit_side_len`, which would silently undo the upscaling. A 3× upscale of a modest snip lands around 5000 px, so a fixed limit of 2880 would shrink it straight back to an effective 1.7×. `OcrLimitSideLen = 0` means **auto** — size the limit to the image so no downscaling ever happens. That's what you want. `OcrMaxSideLen` (6144) is the safety ceiling; if you're exceeding it, lower `OcrUpscale` rather than raising the ceiling.

Note that the AI path does *not* upscale, and shouldn't — see the next section.

### Debugging a bad table

Set `OcrDebug` to 1 and three timestamped files appear in the `Data\` folder:

| File | Contents |
|---|---|
| `SnipOCR_<stamp>_image.png` | Exactly what the engine was fed |
| `SnipOCR_<stamp>_raw.json` | Exactly what the engine returned |
| `SnipOCR_<stamp>_blocks.txt` | How ScreenSnip clustered it — **the useful one** |

The blocks dump is the one to read. When a table comes out wrong there are only two suspects — the engine misread the text, or the clustering misplaced it — and you cannot tell which from the TSV alone. The dump shows you the per-block coordinates, scores, column anchors, computed tolerances, and what reflow decided and why.

Files are stamped per run. They used to use fixed names, which meant each OCR clobbered the previous one's evidence — very easy to end up comparing a run against itself without noticing.

---

## 12. Text extraction: the AI engine

`SnipAI.ahk` adds three more items to the OCR submenu, below the separator:

| Action | What it does |
|---|---|
| Copy Text (AI) | Verbatim transcription, straight to the clipboard |
| Copy Table (AI) | The table as TSV, ready to paste into a spreadsheet |
| Ask AI About Snip… | A free-form question; the answer opens in a window |

**Read this part first.** Unlike the two local engines, this one sends the image **off your machine** to OpenAI, and it **costs money** — fractions of a cent per snip, but not zero. It's also slower: expect several seconds. In exchange it handles multi-column layouts, tables, handwriting, math, and low-resolution antialiased text far better than either local engine.  While experimenting with complex tables, Fourteen cents USD were spent doing seven snips, but most single snips sent to OpenAI cost less than one cent. 

### Setup

1. Get an API key at https://platform.openai.com/account/api-keys. The service is not free and requires prepaid credit. **kunkel321 receives no compensation from your transactions with OpenAI.**
2. Put the key in `Data\ApiKeys.ini`:
   ```ini
   [OpenAI]
   ApiKey=sk-...
   ```
   No quotation marks. That's the same file `SnipImgur.ahk` keeps its Client ID in, under an `[Imgur]` section — one credentials file to gitignore, one to back up.
3. Restart ScreenSnip.

Until a key is present, the three menu items are still there and each one puts up a dialog telling you exactly this, with the full path to the ini file. Nothing fails silently.

**Prepaid OpenAI credits expire after one year.** Buy a dollar or two at a time and set a budget alert.

### The caveat that matters most

**A vision model reports what it believes the text says, not what the pixels say.**

It will silently normalize odd spacing, and it can "correct" a genuine typo in the source. The prompts push hard against this — the transcription prompt explicitly instructs it to reproduce misspellings *as misspellings* — but instruction cannot eliminate the tendency.

For anything where an exact character sequence matters — a license key, a hex string, a hash, a password, a serial number — **use the local engines.** They read pixels and have no opinion about what the text ought to say.

### Copy Table (AI), and why it exists

This is the feature that justifies the module.

A vision model can see the table's **ruling lines**. No box-based OCR engine can. PaddleOCR infers columns by clustering the x-coordinates of text boxes, so a token that lands at the same x in every row reads as a column even when it's only an artifact of line wrapping inside one wide cell. The borders settle the question, and the prompt tells the model in as many words that ruling lines *outrank* text alignment.

Two other ideas carry weight in that prompt:

**A declared column count.** The model states the column count up front, and every row it emits must match. This converts the dangerous silent failure — a dropped empty cell shifting an entire row leftward, producing a plausible and wrong table — into something ScreenSnip can detect and warn you about in the completion tooltip.

**Grounding with local OCR.** When `SnipOCR.ahk` is present and `AiGroundWithOcr` is on (the default), PaddleOCR runs first and its text is sent along with the image as a *spelling* reference. The framing is deliberately lopsided: it grants the OCR authority over characters and explicitly strips it of any authority over layout. What gets sent is Paddle's reading-order lines, **not** its reconstructed grid — sending the grid would hand the model the very column mistake this feature exists to correct.

Grounding costs one extra local engine run of a second or two, offline. It's silently skipped if `SnipOCR.ahk` is absent or the engine isn't installed. It is an enhancement, never a prerequisite.

### Ask AI About Snip…

Type a question, get an answer in a resizable window with a **Copy Answer** button. The question comes first and the image is captured second, so cancelling the prompt costs nothing.

Useful for the things transcription can't do: *what does this error message mean*, *summarize this chart*, *what's wrong with this regex*, *what units is this axis in*. The preamble asks for concise, concrete answers and for exact quotation of any text it's reporting from the image, rather than paraphrase.

### Image handling and cost

`AiMaxSide` is 2048. The API scales anything larger down before tiling it, so sending a bigger image is pure upload time with no accuracy gain. **Unlike the local OCR path, there is no reason to upscale** — the model is not helped by it.

`AiDetail` is `high`, which tiles the image and reads fine print. `low` sends a single coarse thumbnail for roughly a tenth the cost, which is fine for "what is this a picture of" and useless for OCR.

`AiModel` ships as `gpt-5.6`. Any vision-capable chat model works. If the configured one isn't enabled on your account you'll get a clear "model not found" back — the error body is shown verbatim, so it's a one-line fix. Cheaper "mini"-tier models are markedly worse at dense small text; it's worth paying for the full model here.

### Debugging

`AiDebug` set to 1 keeps the temp PNG and writes the raw request and response into `Data\`. The request dump does **not** contain your API key — that rides in a header, not the body — but it does contain the base64-encoded image, so it will be large.

---

## 13. Imgur uploads

Entirely optional. Delete `Resources\SnipImgur.ahk` and the feature vanishes cleanly — the `#Include` uses the `*i` flag and every menu is built behind an `IsSet(Imgur)` test.

![The Imgur submenu on a snip's right-click menu](Images/SnipWithImgurSubMenuShowing.png)

### One-time setup

You need a free Imgur account and a Client ID:

1. Create an account at https://imgur.com/register — any email address will do. There's no paid tier involved.
2. Signed in, go to **Settings → Applications** (https://imgur.com/account/settings/apps).
3. Add a new application. Name it anything.
4. Authorization type: **"Anonymous usage without user authorization"**.
5. Leave the callback URL blank and submit.
6. Copy the **Client ID**. Ignore the Client Secret — anonymous uploads never use it.
7. Paste it into ScreenSnip via the Uploader's **Client ID…** button.

It's stored in `Data\ApiKeys.ini` under an `[Imgur]` section — the same file `SnipAI.ahk` uses. **Add the `Data` folder to `.gitignore`.** A Client ID isn't a password, but it's rate-limited against your account and you don't want strangers spending your daily allowance.

### Two ways in

**Right-click a snip → Imgur → Upload → [img] Tag** is the one-click path. It renders the snip, uploads it, and puts a BBCode `[img]` tag on your clipboard ready to paste into a forum post.

**Imgur Uploader…** opens the full dialog. Reachable two ways:

- Right-click a snip → **Imgur → Imgur Uploader…** — opens with that snip pre-loaded
- **Tray menu → Imgur Uploader…** — opens empty, for files already on disk

The tray route is the one to use for an animated GIF or an old screenshot that ScreenSnip never captured. Drag a file onto the dialog, or use **Browse…**.

### The Uploader dialog

![The Imgur Uploader dialog after a successful upload, showing the BBCode link and remaining credits](Images/ImgurUploaderDialog.png)

| Control | Purpose |
|---|---|
| Path box | The file to upload. Drag-and-drop onto the window works |
| Browse… | File picker |
| Upload | Sends it |
| Client ID… | Opens the setup dialog, with clickable links to Imgur |
| Copy as: | Link format — changing it re-copies immediately |
| Copy | Re-copy the current link |
| Open in Browser | Opens the Imgur *page* for the upload |
| Delete This Upload | Removes it from Imgur — read the warning below |

Link formats offered:

- **Direct link** — `https://i.imgur.com/ID.png`, the embeddable file
- **BBCode [img]** — the default, and what the one-click menu item always emits
- **BBCode thumbnail linked** — a 640 px thumbnail that links to the full image, so a big screenshot doesn't blow out a forum thread's layout
- **Markdown**
- **HTML img tag**
- **Page link** — Imgur's viewer page, with its nav bar and buttons
- **Direct MP4** *(animated only)*
- **HTML5 video tag** *(animated only)*

### Page link vs direct link

Imgur's API returns a link to the image's *page* (`imgur.com/7Wqu8C8`). Forum `[img]` tags and HTML `<img>` tags need the *file* (`i.imgur.com/7Wqu8C8.png`).

ScreenSnip derives the direct link from the response's `id` and `type` fields rather than by editing the URL text. `type` is the MIME type of the image **as Imgur stored it**, which matters because Imgur re-encodes BMP and TIFF uploads to PNG. Guessing the extension from the source filename would produce a dead link in those cases.

### Deleting an upload — read this before relying on it

An **anonymous upload isn't owned by your account** and doesn't appear in it. The only handle on it is the "deletehash" that Imgur returns, and ScreenSnip deliberately keeps **no log file** — so the deletehash is remembered for the current session only.

**Once ScreenSnip exits, an anonymous upload is effectively permanent.**

Delete while you still can via *Imgur Uploader… → Delete This Upload*, which acts on the most recent upload of the session.

Because that's a lot of consequence for one menu click on a snip that might be showing an email or a password field, the one-click path asks for confirmation by default. Turn `ImgurConfirmBeforeUpload` off once the flow feels familiar.

### Size limit

**Treat 10 MB on disk as the ceiling**, and note this is the *API's* limit, not Imgur's.

Imgur's website accepts 20 MB for stills and 200 MB for animated files. The JSON API that ScreenSnip posts to caps out around 10 MB, and base64 encoding inflates the payload by roughly a third on top of whatever the file weighs.

Some tools get past this by posting `multipart/form-data` with raw bytes instead of a base64 form field. ScreenSnip deliberately doesn't — it would mean hand-rolling a MIME body and a SafeArray for a case that a smaller GIF solves just as well.

For an oversized GIF the practical fix is to shrink it: drop frames, reduce the dimensions, or run a lossy pass. `gifsicle -O3 --lossy=80` is startlingly effective.

### Animated GIFs

They work, with one caveat you should know about.

Imgur re-encodes any GIF over roughly **2 MB** to GIFV — an MP4 in a wrapper, audio stripped — and then reports the stored type back as `video/mp4`. A naive uploader builds the direct link from that type and produces `i.imgur.com/ID.mp4`, which renders as a **broken image** inside an `[img]` tag on every forum there is. This is why an animated upload can look like it failed when in fact it uploaded perfectly.

ScreenSnip detects the conversion and keeps a `.gif` URL as the primary link, since Imgur goes on serving the GIF alongside the video. The `.mp4` and `.gifv` URLs remain available from the "Copy as:" dropdown for anywhere that can play video.

One consequence: Imgur's thumbnails of an animated image are **still frames**, so "BBCode thumbnail linked" on a GIF gives a motionless preview that links through to the moving version. Usually the polite thing to post in a thread; occasionally not what you wanted.

### Rate limits

Roughly 1,250 uploads and 12,500 requests per day per Client ID. Remaining credits are shown in the Uploader's status line after each upload.

### What actually gets uploaded

Exactly what you see: the snip's current crop, flips, rotation, and straighten, rendered through the same pipeline Save Image As uses. It's written to a temporary PNG in `%TEMP%`, uploaded, and deleted immediately. Orphaned temp files from a crash are swept on the next open of the dialog.

---

## 14. Menu reference

### Right-click menu (on a snip)

| Item | Notes |
|---|---|
| Copy to Clipboard | |
| Save Image As… | `Ctrl+S` |
| **OCR** → | Copy Text (Windows) · Copy Text (PaddleOCR) · Copy Table (PaddleOCR) *(if `SnipOCR.ahk` is present)* — separator — Copy Text (AI) · Copy Table (AI) · Ask AI About Snip… *(if `SnipAI.ahk` is present)* |
| **Imgur** → | Upload → [img] Tag · Imgur Uploader… *(if `SnipImgur.ahk` is present)* |
| **Rotate** → | 90° CW · 180° · 90° CCW |
| **Flip** → | Horizontal · Vertical |
| **Straighten** → | CW · CCW · Reset Straighten |
| **Nudge Position** → | Moves the window |
| **Pan Region** → | Moves the crop |
| **Resize Region** → | Resizes the crop |
| Border | Checkable toggle, per snip |
| Shadow | Checkable toggle, per snip |
| Close This Snip | `Esc` |
| Close All Snips | |
| Settings… | Opens SettingsManager *(only if it's in `Resources\`)* |
| Help | `F1` |

The OCR submenu disappears entirely if neither text-extraction module is installed. Everything below the separator inside it sends your image to a paid online service.

Menu items that have a hotkey display it right-aligned as a reminder. The directional submenus use a 1 px step; hold Shift with the equivalent hotkey for 10 px. Greyed-out lines like "Hold Shift → ±10 px" are hints, not clickable items.

The menu acts on the snip you right-clicked, which is not necessarily the focused one — with two exceptions grouped at the bottom next to Help, because neither Settings… nor Help does anything to a snip at all.

### Tray menu

![The system tray menu, with the (admin) suffix showing an elevated instance](Images/SystrayMenu.png)

| Item | Notes |
|---|---|
| **ScreenSnip** *(or* **ScreenSnip (admin)** *)* | Disabled title. Shows elevation state at a glance |
| *(standard AHK items)* | Open, Help, Window Spy, Reload, Edit, Suspend, Pause, Exit |
| Freeze Capture | Same as the trigger key. A discoverable way in, and a fallback when another script has won the race for the key |
| Start with Windows | Checkable. Creates/removes a Startup folder shortcut |
| Imgur Uploader… | *(only if `SnipImgur.ahk` is present)* |
| Settings… | Opens SettingsManager *(only if it's in `Resources\`)* |
| ScreenSnip Help | |

The `(admin)` suffix on the title is worth glancing at whenever a capture mysteriously doesn't work — see the next section.

---

## 15. Keyboard and mouse reference

Most snip hotkeys are context-sensitive: they only fire when a snip window is focused, so they don't interfere with anything else.

### Capturing

| Keys | Action |
|---|---|
| `Ctrl` + RButton drag | Capture a region |
| `Ctrl+Shift` + RButton drag | Capture and copy to clipboard |
| Double-tap `CapsLock` | Freeze the screen (configurable) |
| `Shift+PrintScreen` | Show / hide all snips |

### During a Freeze Capture

| Keys | Action |
|---|---|
| RButton drag | Select a region from the frozen image |
| Hold `Shift` on release | ...and copy to clipboard |
| LButton click | Capture the highlighted window whole |
| Wheel up / down | Cycle to a window stacked underneath |
| `Esc` | Cancel the freeze |

### On a snip

| Keys | Action |
|---|---|
| `F1` | Help |
| `Esc` | Close this snip |
| `Ctrl+C` | Copy image to clipboard |
| `Ctrl+S` | Save image as… |

### Move the window

| Keys | Action |
|---|---|
| `Ctrl+Arrow` | ± 1 px |
| `Ctrl+Shift+Arrow` | ± 10 px |
| Left-drag | Free |

### Adjust the capture region

| Keys | Action |
|---|---|
| `Ctrl+Alt+Arrow` | Pan ± 1 px |
| `Ctrl+Shift+Alt+Arrow` | Pan ± 10 px |
| Right-drag | Pan, continuous |
| `Win+Alt+Arrow` | Resize ± 1 px |
| `Win+Shift+Alt+Arrow` | Resize ± 10 px |
| `Alt` + drag edge/corner | Resize, continuous |

### Rotate, straighten, flip

| Keys | Action |
|---|---|
| `Alt+Left` / `Alt+Right` | Rotate ± 1° |
| `Shift+Alt+Left` / `Right` | Snap to next 30° |
| `Alt+,` / `Alt+.` | Straighten ± 1° |
| `Shift+Alt+,` / `.` | Straighten ± 0.5° |
| `Shift+Left` / `Shift+Right` | Flip horizontal |
| `Shift+Up` / `Shift+Down` | Flip vertical |

### Transparency

| Keys | Action |
|---|---|
| `Alt+Up` / `Alt+Down` | ± 25 |
| `Alt+wheel` | ± 10 |

---

## 16. Things that will bite you

### You can't snip an elevated window unless ScreenSnip is also elevated

This is the big one, and it isn't a bug — it's Windows UIPI (User Interface Privilege Isolation). A normal-integrity process can't hook input over a higher-integrity window. If you have XYplorer, VSCode, or anything else running as admin, ScreenSnip at normal integrity can't capture over it.

Symptoms are confusing: dragging a selection *onto* such a window can leave the rectangle stuck on screen, because the button-release event never reaches ScreenSnip's hook. Press **Esc** to clear a stuck rectangle — that's the safety valve.

**Check the tray menu title.** It reads `ScreenSnip (admin)` when elevated. `A_IsAdmin` is fixed at launch, so this is reliable.

**The fix is Task Scheduler, not the Startup folder.** An elevation-requesting program in the Startup folder is silently blocked at logon — Windows won't auto-approve a UAC prompt. Create a task with "Run with highest privileges", triggered at logon, and set **Start in** to the script's folder. Also uncheck "Start the task only if the computer is on AC power" on the Conditions tab if you're on a laptop; it's ticked by default and is a classic silent-failure trap.

**A confusing corollary:** launching `ScreenSnip.exe` from within an already-elevated file manager makes it inherit the parent's admin token. So it works that session and mysteriously stops the next time you launch it normally. If elevation seems intermittent, this is usually why.

The same wall shows up during a Freeze Capture window grab: if you release the left button over an elevated window while ScreenSnip isn't elevated, Windows hides that event and the button state reads "down" indefinitely. The wait is bounded at three seconds and checks Esc throughout, so the worst case is a short pause rather than a stranded full-screen backdrop.

### Drag-and-drop into the Imgur Uploader when elevated

Same UIPI wall, opposite direction. Explorer runs at medium integrity; an elevated ScreenSnip runs at high; messages from the former to the latter are silently discarded. Dragging a file from your Desktop onto the Uploader used to do nothing at all — no error, no beep, no cursor change.

This is handled now. `ImgurAllowDropsWhenElevated()` uses `ChangeWindowMessageFilterEx` to whitelist the three drop-related messages (`WM_DROPFILES`, `WM_COPYDATA`, and the undocumented `WM_COPYGLOBALDATA`) on the Uploader's window alone. Per-window scope, three messages — nothing else about the process's isolation changes.

### Deleting `OCR.ahk` while keeping `SnipOCR.ahk`

The four add-on modules are all included with `*i` and can all be deleted freely. **Descolada's `OCR.ahk` is different.** `SnipOCR.ahk` pulls it in with a plain `#Include OCR.ahk` — no `*i` — so if `SnipOCR.ahk` is present and `OCR.ahk` isn't, ScreenSnip won't start.

Two ways out: delete `Resources\SnipOCR.ahk` too (you lose the PaddleOCR items as well), or keep it and comment out its `#Include OCR.ahk` line near the top, which leaves the PaddleOCR items working and drops only the Windows OCR one.

### The AI silently tidies your text

Covered in [section 12](#12-text-extraction-the-ai-engine), and repeated here because it's the kind of thing you discover at the worst moment. A vision model transcribes what it believes the text *says*. It will normalize odd spacing and can quietly fix a typo that was really there. For a license key, a hash, or anything where the exact characters matter, use Copy Text (Windows) or Copy Text (PaddleOCR).

### Freeze Capture can't capture ScreenSnip's own menus

While one of ScreenSnip's own menus is open, the script's thread is inside that menu's modal loop, so the freeze trigger has nothing to run on. The tray menu's own **Freeze Capture** item is fine — selecting it closes the menu *before* the callback runs — but you can't freeze a ScreenSnip context menu in the act of being open. Use another capture tool for that particular screenshot.

### Running `SnipWinDetect.ahk` standalone alongside ScreenSnip

The module has a self-test you can run by executing it on its own: F1 starts detection, the wheel cycles, a click reports the rect it would have captured, Esc stops, F12 exits.

What you can't do is run that self-test *and* trigger a Freeze Capture from a separately running ScreenSnip. Windows belonging to its own process are filtered out of the snapshot, and when the two run as separate processes, ScreenSnip's frozen backdrop isn't "this process" — so it's treated as an ordinary window, and being topmost and screen-sized, it's the only thing the cursor can ever be over. You get one big rectangle around the whole screen. Once the file is `#Include`d into ScreenSnip they share a process, the backdrop is filtered out automatically, and the real windows underneath become visible to the hit test.

### The magenta halo on rotated snips

At angles other than 0/90/180/270, a fringe of magenta pixels can appear around the edge of a snip. This is the transparency color key bleeding through at the anti-aliased boundary.

It's a display artifact only. **Saved PNGs and Imgur uploads are unaffected** — they go through a separate path that produces genuinely transparent corners rather than the color key. Known issue; cosmetic.

### Borders disappear when you rotate

Deliberate. A rectangular border doesn't map onto a tilted snip, so it's suppressed at non-cardinal angles. Same rule applies to the drop shadow and to Alt-edge-drag resizing.

### Two scripts can't share a hotkey

Each AHK script installs its own keyboard hook. Whichever hook sits earlier in the chain and *suppresses* a key wins, and the other script never sees it. If your Freeze Capture trigger does nothing, something else probably owns it.

Don't fight it — use the [cross-script message trigger](#the-cross-script-trigger) and let the script that already owns the key broadcast to ScreenSnip.

### Straighten runs out of room

Tilting the image pulls in pixels from outside the current crop, and those come from the `CaptureAdjustMargin` snapshot. Past a certain angle you run out and the corners go empty. Increase the margin if you deskew a lot.

### Copy Table on something that isn't a table

You'll get a prompt offering plain text instead. Take it. Forms and prose put nearly all their text in one column, and the grid reconstruction has nothing sensible to do with that.

### JPG and BMP lose transparency

Only PNG carries an alpha channel. Rotate a snip and save it as JPG and the corners come out filled, not transparent.

### A setting you changed did nothing

Settings are read once, at launch. Nothing re-reads the file, so a change needs a restart before it means anything. SettingsManager offers one after you save — take it. Restarting closes any snips you have open, so finish with them first.

If a restart doesn't help either, check the value's *form*: a number where text belongs, a color with a `#` or `0x` in front, or six characters that aren't all hex digits will each be rejected in favour of the built-in default rather than applied. That's deliberate — a nonsense `TransColor` would punch holes in every snip — but it does mean an invalid value fails quietly.

### Editing snipSettings.ini while SettingsManager has it open

SettingsManager writes the whole file when you save, so a hand edit made in a text editor in the meantime is overwritten. Pick one or the other for a given sitting.

Relatedly, launching SettingsManager from the menu when it's already running just raises the existing window rather than starting a second copy. It's `#SingleInstance Force`, so a second launch would kill the first and take any unsaved edits with it.

### Something threw and you want to know what

Unhandled errors are appended to `Data\ScreenSnip_error.log` with a timestamp. If the `Data` folder can't be created, that falls back to the script folder.

---

## 17. Settings reference

A map of `Data\snipSettings.ini`, section by section, in file order. Values shown are as shipped.

This is a reference, not a tutorial. The full explanation of any given setting lives in `Data\snipSettingsMetadata.json` and is shown in SettingsManager's help pane while you edit it — see [section 3](#3-settings).

Two things apply throughout: every key falls back to a coded default if it's missing, blank, or invalid, and nothing is re-read after launch.

### `[Capture]`

| Key | Shipped | Purpose |
|---|---|---|
| `SelectionColor` | `B58500` | Selection overlay color while dragging |
| `SelectionOverlayAlpha` | `80` | Opacity of that overlay, 0–255 |
| `CaptureAdjustMargin` | `250` | Snapshot headroom in px, per side |

### `[DimensionLabels]`

| Key | Shipped | Purpose |
|---|---|---|
| `ShowDimensionLabels` | `1` | Master switch for the W×H labels |
| `InfoFontSize` | `10` | Label font size |
| `InfoWHOffsetRight` / `InfoWHOffsetBottom` | `38` / `25` | Label inset from the edges |
| `InfoWMinWidth` / `InfoHMinHeight` | `75` / `55` | Minimum selection size before each label shows |

### `[FreezeCapture]`

| Key | Shipped | Purpose |
|---|---|---|
| `FreezeCaptureKey` | `CapsLock` | Trigger key. Blank disables the built-in trigger; the cross-script message trigger still works |
| `FreezeDoublePress` | `1` | Require a double press |
| `FreezeDoublePressTime` | `400` | Max ms between the two presses |
| `FreezeNullifyCapsLock` | `1` | Force CapsLock off after every press. Ignored unless the trigger key *is* CapsLock |

### `[FreezeHint]`

| Key | Shipped | Purpose |
|---|---|---|
| `ShowFreezeHint` | `1` | Show the hint pill over the frozen backdrop |
| `FreezeHintText` | *(see file)* | Wording when window detection is off. `` `n `` for line breaks |
| `FreezeHintTextWinDetect` | *(see file)* | Wording when `SnipWinDetect.ahk` is loaded and enabled |
| `FreezeHintFontName` / `FreezeHintFontSize` | `Segoe UI` / `15` | |
| `FreezeHintTextColor` / `FreezeHintBackColor` | `FFFFFF` / `1E1E1E` | Hex RRGGBB |
| `FreezeHintAlpha` | `185` | Pill opacity, 0–255 |
| `FreezeHintCornerRadius` | `70` | Corner rounding in px. `0` = square |

The two hint strings are separate on purpose: deleting `SnipWinDetect.ahk` has to leave the hint truthful rather than advertising a click that does nothing.

### `[SnipWindow]`

| Key | Shipped | Purpose |
|---|---|---|
| `ShowSnipBorder` | `1` | |
| `BorderColor` | `B58500` | Falls back to `SelectionColor` if absent, so the selection tint and the finished snip match by default |
| `BorderThickness` | `2` | px |
| `Bevel3D` | `1` | The 3D floating look |
| `Bevel3DMaxThickness` | `3` | Bevel auto-disables above this |
| `Bevel3DStrength` / `Bevel3DInactiveStrength` | `0.55` / `0.55` | Blend toward white/black, 0–1 |
| `Bevel3DInactiveDarknessFactor` | `0.2` | How much both edges dim when unfocused |
| `TransColor` | `FF00FF` | Magenta color key for rotated corners |

### `[SnipShadow]`

| Key | Shipped | Purpose |
|---|---|---|
| `ShowSnipShadow` | `1` | Default for new snips |
| `ShadowColor` | `000000` | |
| `ShadowOffset` / `ShadowOffsetInactive` | `7` / `4` | Down/right offset, logical px |
| `ShadowBlur` | `6` | Edge softness. Keep ≤ `ShadowOffset` for a drop rather than a halo |
| `ShadowAlpha` | `105` | Peak opacity, 0–255 |

### `[Gestures]`

| Key | Shipped | Purpose |
|---|---|---|
| `PanDragDivisor` | `3` | Mouse px per 1 px of pan. `1` = 1:1 |
| `PanClickSlop` | `5` | Drag distance below which it's a plain right-click |
| `EdgeGrabZone` | `6` | Grabbable band inward from each edge |

### `[Straighten]`

| Key | Shipped | Purpose |
|---|---|---|
| `StraightenStep` | `1` | Degrees per `Alt+,` / `Alt+.` |
| `StraightenFineStep` | `0.5` | Degrees per `Shift+Alt+,` / `.` |
| `StraightenMaxAngle` | `15` | Hard clamp |

### `[Saving]`

| Key | Shipped | Purpose |
|---|---|---|
| `SaveDefaultFolder` | `%USERPROFILE%\Pictures` | The *first* folder offered in a session. After that the last folder saved to wins |
| `SaveDefaultExt` | `png` | Extension used when you type a filename without one |

Point `SaveDefaultFolder` at `SavedImages` if you want ScreenSnip's own folder as the starting place. A relative path resolves against the ScreenSnip folder, so `SavedImages` on its own is enough.

### `[Tooltips]`

Fed to `Resources\ToolTipOptions.ahk`. See [section 3](#3-settings) for what these reach and why no call site changes.

| Key | Shipped | Purpose |
|---|---|---|
| `EnhanceToolTips` | `1` | `0` = plain Windows tooltips, with the file left in place |
| `TipFontName` / `TipFontSize` | `Segoe UI` / `12` | |
| `TipFontStyle` | *(blank)* | Style words, e.g. `bold` or `italic` |
| `TipBackColor` / `TipTextColor` | `1E1E1E` / `FFFFFF` | Hex RRGGBB. Fall back to the freeze hint's colors |
| `TipMarginL` / `TipMarginT` / `TipMarginR` / `TipMarginB` | `10` / `8` / `10` / `8` | Padding inside the tooltip — left, top, right, bottom, px |
| `TipTitle` | *(blank)* | A bold heading on every tooltip. Blank = none |
| `TipTitleIcon` | `4` | Icon beside that title: `0` none, `1` info, `2` warning, `3` error, `4`–`6` the same three at large size. Only shows when `TipTitle` is set |

### `[SnipOCR]`

The local engines. Every key is prefixed `Ocr` in the file, so `OcrRowTol` here is `OcrCfg.RowTol` in the source.

| Key | Shipped | Purpose |
|---|---|---|
| `OcrPaddleExe` | `Resources\PaddleOCR-json\PaddleOCR-json.exe` | Engine path, relative to the ScreenSnip folder |
| `OcrLangConfig` | `models\config_en.txt` | Relative to the engine folder. **Blank defaults to Chinese** |
| `OcrUpscale` | `3` | Pre-OCR enlargement |
| `OcrLimitSideLen` | `0` | `0` = auto, never downscale. Recommended |
| `OcrMaxSideLen` | `6144` | Safety ceiling for auto mode |
| `OcrRotateFill` | `FFFFFF` | Corner fill for rotated snips. `000000` for light-on-dark |
| `OcrMinScore` | `0.0` | Confidence filter. Keep at 0 for tables |
| `OcrMarkBelow` | `0.0` | Append `?` below this confidence |
| `OcrRowTol` / `OcrColTol` | `0.60` / `1.20` | Clustering tolerances, × median text height |
| `OcrReflow` | `1` | Stitch wrapped cells back together |
| `OcrReflowRatio` | `1.8` | Gap separation required before reflowing |
| `OcrReflowAnchorCol` | `1` | Key column. `0` = gaps alone |
| `OcrReflowGapFactor` | `1.8` | What counts as a "big" gap |
| `OcrNotATableWarn` | `0.60` | Single-column density that triggers the prose prompt |
| `OcrDebug` | `0` | Write the three diagnostic files to `Data\` |

### `[SnipAI]`

The paid, online engine. Note that the API key itself is **not** here — it lives in `Data\ApiKeys.ini`, which is the file to keep out of a repository.

| Key | Shipped | Purpose |
|---|---|---|
| `AiModel` | `gpt-5.6` | Any vision-capable chat model |
| `AiDetail` | `high` | `low` is ~10× cheaper and useless for OCR |
| `AiMaxSide` | `2048` | Larger is pure upload with no accuracy gain. **Do not upscale** |
| `AiResolveTimeout` / `AiConnectTimeout` | `10000` / `10000` | ms |
| `AiSendTimeout` / `AiReceiveTimeout` | `60000` / `180000` | ms. Receive must be generous — vision calls are slow |
| `AiWaitSecs` | `180` | Overall ceiling |
| `AiGroundWithOcr` | `1` | Run PaddleOCR first and send its text as a spelling reference. Skipped silently if unavailable |
| `AiNormalizeTablePunct` | `1` | Tidy punctuation in returned table cells |
| `AiDashCellToEmpty` | `0` | Treat a lone dash in a cell as an empty cell |
| `AiShowTokenUsage` | `0` | Report tokens spent in the completion tooltip |
| `AiDebug` | `0` | Keep the temp PNG and dump request/response to `Data\` |

The prompts are not in the INI — they're long, multi-paragraph, and every clause in them is load-bearing. They stay in `Resources\SnipAI.ahk` where they can be read in full alongside the reasoning for each rule.

### `[SnipImgur]`

| Key | Shipped | Purpose |
|---|---|---|
| `ImgurConfirmBeforeUpload` | `1` | Ask before the one-click upload. Read [section 13](#13-imgur-uploads) before turning this off |
| `ImgurDefaultFormat` | `BBCode [img]` | Which "Copy as:" format the Uploader opens on |
| `ImgurProgressDelayMs` | `500` | Delay before the progress window appears |
| `ImgurResolveTimeout` | `8000` | DNS, ms |
| `ImgurConnectTimeout` | `10000` | ms |
| `ImgurSendTimeout` | `30000` | ms |
| `ImgurReceiveTimeout` | `60000` | The real ceiling on a wedged upload |

The Client ID is not here either — same file, `Data\ApiKeys.ini`, under `[Imgur]`.

### `[SnipWinDetect]`

| Key | Shipped | Purpose |
|---|---|---|
| `WinDetectEnabled` | `1` | `0` keeps the module loaded but never highlights anything |
| `WinDetectColor` | `1E90FF` | Outline color. A saturated blue reads against arbitrary window chrome better than red or green |
| `WinDetectThickness` | `5` | Outline px, auto-thinned for windows too small to fit it |
| `WinDetectPollMs` | `40` | Cursor poll interval, ~25 fps. Below 10 is clamped |
| `WinDetectMinSize` | `16` | Ignore windows smaller than this, filtering the 1×1 message-only oddities apps leave lying around |
| `WinDetectShowInfo` | `1` | The title / class / size readout beside the cursor |
| `WinDetectTipIndex` | `18` | Which tooltip slot that readout uses |
| `WinDetectIncludeDesktop` | `0` | Treat Progman/WorkerW as a target. Off because it's screen-sized, and having it match means the highlight never goes away over empty desktop |
| `WinDetectIncludeMonitors` | `1` | Offer each monitor as a target, appended after the windows |

---

## 18. Credits

**ScreenSnip** is adapted by **kunkel321** with **Claude**, from **Snipper** by **FanaticGuru**.

The post-capture adjust-region idea — the frozen master snapshot that lets you pan and resize after the fact — was suggested by AutoHotkey forum user **alnz123**.

**OCR.ahk** for Windows.Media.Ocr is by **Descolada** — https://github.com/Descolada/OCR

**PaddleOCR-json** is by **hiroi-sora** — https://github.com/hiroi-sora/PaddleOCR-json

The idea of sending a screen snip to an AI vision model comes from one of **Joe Glines'** apps. Joe's site — https://www.the-automator.com — is where a lot of us first saw AHK and LLM APIs wired together.  Specifically, he showcased his snip tool durrin an AHK Hero zoom meeting. `SnipAI.ahk` is an independent implementation of that idea, fitted to ScreenSnip's snip objects.

**ToolTipOptions.ahk** is by AHK forum member **just me** — https://www.autohotkey.com/boards/viewtopic.php?t=113308 — and ships unmodified, so it can be swapped for a newer copy whenever he posts one.

**SettingsManager** in `Resources\` began life as a tool in kunkel321's AutoCorrect2 suite, but the copy here is a separate build with its own metadata and no connection to that project. Nothing in the ScreenSnip package is part of AutoCorrect2 or depends on it.

The window-highlighting behaviour in Freeze Capture is modelled on **SnagIt**'s.

Bug reports and feature suggestions are welcome on the [AutoHotkey forum thread](https://www.autohotkey.com/boards/viewtopic.php?f=83&t=140802) or the [GitHub repository](https://github.com/kunkel321/ScreenSnip).

User Manual **version date**: Aug 11, 2026.