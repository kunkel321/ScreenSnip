#Requires AutoHotkey v2
; ==============================================================================
;                 SnipWinDetect.ahk   —  add-on module for ScreenSnip.ahk
; Version Date: 8-11-2026 
; ==============================================================================
; Hover-to-highlight window detection for FREEZE CAPTURE, in the style of
; SnagIt: move the mouse over the frozen screen and the window beneath the
; cursor is outlined; left-click captures it whole.  Right-drag still does the
; normal freehand region selection, unchanged.
;
; Opt-out on the same contract as the other add-ons: delete this file (or
; comment out its #Include at the bottom of ScreenSnip.ahk) and the
; `WinDetectCfg` class never comes into existence, so FreezeCapture() skips
; every detection call and behaves exactly as it did before.
;
; ------------------------------------------------------------------------------
; HOW IT WORKS  (and why it isn't image analysis)
;
; The frozen backdrop is only a PICTURE laid over the desktop.  The real windows
; are still sitting underneath it at the same coordinates, so the window tree can
; simply be queried — no edge detection on the bitmap required.  SnagIt does the
; same thing.
;
; Freeze mode is in fact the ideal case for this.  Because the screen is frozen,
; nothing can move, so the whole top-level window list is snapshotted ONCE when
; the freeze begins and every mouse-move is then just an in-memory rectangle
; test.  No API calls while hovering, so it stays smooth, and there is no chance
; of a window shifting between the moment it was highlighted and the moment it
; was captured.
;
; Scope is TOP-LEVEL WINDOWS only, plus each monitor as a whole-screen target.
; Child controls (toolbars, list panes, individual buttons) would need
; per-control enumeration, and modern apps — Chrome, Electron/VSCode, UWP, WPF —
; draw everything inside a single HWND and would need UI Automation on top of
; that.  Neither is done here.
;
; ------------------------------------------------------------------------------
; RUNNING THIS FILE ON ITS OWN
;
; Double-click SnipWinDetect.exe to try the detection standalone: F1 starts,
; the wheel cycles through stacked windows, a click reports the rect it would
; have captured, Esc stops, F12 exits.
;
; NOTE: standalone mode cannot be combined with a Freeze Capture from a
; SEPARATELY RUNNING ScreenSnip.  Windows belonging to THIS process are filtered
; out of the snapshot, and when the two run as separate processes ScreenSnip's
; full-screen frozen backdrop is not "this process" — so it is treated as a
; perfectly ordinary window and, being topmost and screen-sized, it is the only
; thing the cursor can ever be over.  That is why you get one big rectangle
; around the whole screen.  Once this file is #Include'd into ScreenSnip they
; share a process, the backdrop is filtered out automatically, and the real
; windows underneath become visible to the hit test.
; ==============================================================================


; ==============================================================================
; SETTINGS
; ==============================================================================
; This class doubles as the presence sentinel — ScreenSnip tests IsSet(WinDetectCfg)
; to decide whether the feature exists at all.  Class objects are created before
; the auto-execute section runs, which is why IsSet() can see it from a file
; #Include'd at the very bottom of ScreenSnip.ahk.
class WinDetectCfg {

    ; Master switch.  false = the module stays loaded but never highlights
    ; anything, and freeze capture behaves exactly as it did before.
    static Enabled := SnipCfg('SnipWinDetect', 'WinDetectEnabled', true)

    ; Outline colour, hex RRGGBB.  Wants to read clearly against an arbitrary
    ; screenshot; a saturated blue does that better than red or green, both of
    ; which disappear into common window chrome.
    static Color := SnipCfg('SnipWinDetect', 'WinDetectColor', '1E90FF')

    ; Outline thickness in px.  Automatically thinned for windows too small to
    ; fit it, so a tiny tooltip still shows an outline rather than a solid block.
    static Thickness := SnipCfg('SnipWinDetect', 'WinDetectThickness', 3)

    ; Cursor poll interval in ms.  The hit test itself is a memory scan, so this
    ; is cheap; 40 is about 25 fps and feels immediate.  Below 10 is clamped.
    static PollMs := SnipCfg('SnipWinDetect', 'WinDetectPollMs', 40)

    ; Ignore windows smaller than this in either dimension, px.  Filters the
    ; 1x1 and 0x0 message-only oddities that a lot of apps leave lying around.
    static MinSize := SnipCfg('SnipWinDetect', 'WinDetectMinSize', 16)

    ; Show the floating title / class / size readout beside the cursor?
    static ShowInfo := SnipCfg('SnipWinDetect', 'WinDetectShowInfo', true)

    ; ToolTip slot for that readout.  ScreenSnip itself uses no ToolTips, so
    ; this only matters if another add-on starts to.
    static TipIndex := SnipCfg('SnipWinDetect', 'WinDetectTipIndex', 18)

    ; Treat the desktop itself (Progman / WorkerW) as a capture target?  Off by
    ; default — it is screen-sized, sits under everything, and having it match
    ; means the highlight never goes away over empty desktop.
    static IncludeDesktop := SnipCfg('SnipWinDetect', 'WinDetectIncludeDesktop', false)

    ; Offer each MONITOR as a capture target as well?  These are appended AFTER
    ; the windows, so they sit at the bottom of the Z-ordered candidate list: a
    ; real window under the cursor always wins, a whole screen is always one
    ; wheel-step past the last window, and empty desktop still has something to
    ; highlight — all without switching IncludeDesktop on and letting Progman
    ; swallow every hit test.  Full monitor bounds, taskbar included.
    static IncludeMonitors := SnipCfg('SnipWinDetect', 'WinDetectIncludeMonitors', true)
}


; ==============================================================================
; MODULE STATE
; ==============================================================================
; Held as class statics rather than plain globals for a load-order reason that
; is easy to get wrong: this file is #Include'd at the very BOTTOM of
; ScreenSnip.ahk, which is past the end of its auto-execute section, so any
; top-level assignment here would never execute.  Class static initialisers run
; before the auto-execute section regardless of where the class is declared —
; the same property that lets IsSet(WinDetectCfg) work from 3,000 lines away.
class WinDetectState {
    static Active     := false
    static Suspended  := false
    static Snapshot   := []          ; every eligible window, topmost first
    static Candidates := []          ; the subset under the cursor, topmost first
    static CandIndex  := 1
    static Bars       := []
    static LastX      := -99999
    static LastY      := -99999
    static LastTop    := 0
    static ShownRect  := ''
    static Thick      := 3
}

; The one piece of top-level code in this file, and it is deliberately
; unreachable when #Include'd: sitting past ScreenSnip's auto-execute section
; means it only ever runs when this file IS the script.  That is exactly the
; guard we want — nothing in the self-test can fire inside ScreenSnip.
if (A_LineFile = A_ScriptFullPath)
    WinDetect_RunSelfTest()


; ==============================================================================
; PUBLIC API   (ScreenSnip calls all of these through the %name%() dynamic form,
;               because a direct call to a function that might not exist is a
;               LOAD-TIME error in v2 — the same reason ImgurBuildMenu is called
;               that way.)
; ==============================================================================

; Build the snapshot and start hover highlighting.  Returns true if detection
; actually started.
;
; extraExcludes: optional array of HWNDs to leave out of the snapshot.  Windows
; owned by THIS process are excluded automatically, so ScreenSnip's frozen
; backdrop, its hint pill and its selection overlay all need no special
; handling.  This parameter is for cross-PROCESS cases only — e.g. an
; onscreenkeybrd.ahk overlay running as its own script.
WinDetect_Begin(extraExcludes := '') {
    if WinDetectState.Active
        return true
    if !WinDetectCfg.Enabled
        return false

    WinDetectState.Thick := Max(1, WinDetectCfg.Thickness)

    ; Bars are created FIRST so their own HWNDs can go into the exclude map
    ; before the scan runs — otherwise the outline highlights itself.
    exclude := Map()
    if IsObject(extraExcludes) {
        for h in extraExcludes
            exclude[h] := true
    }
    WinDetect_CreateBars(exclude)

    WinDetectState.Snapshot  := WinDetect_BuildSnapshot(exclude)
    WinDetectState.LastX     := -99999
    WinDetectState.LastY     := -99999
    WinDetectState.LastTop   := 0
    WinDetectState.ShownRect := ''
    WinDetectState.Suspended := false
    WinDetectState.Active    := true

    SetTimer(WinDetect_Tick, Max(10, WinDetectCfg.PollMs))
    WinDetect_Tick()                ; draw at once rather than waiting a tick
    return true
}

; Stop detection, destroy the bars, release the snapshot.  Safe to call when
; not running, so it can go in a finally-block unguarded.
WinDetect_End() {
    if !WinDetectState.Active
        return

    SetTimer(WinDetect_Tick, 0)
    WinDetectState.Active    := false
    WinDetectState.Suspended := false

    if WinDetectCfg.ShowInfo
        ToolTip(, , , WinDetectCfg.TipIndex)

    for g in WinDetectState.Bars {
        try g.Destroy()
    }
    WinDetectState.Bars       := []
    WinDetectState.Snapshot   := []
    WinDetectState.Candidates := []
}

; Hide the highlight but keep the snapshot — for when a drag takes over.
WinDetect_Suspend() {
    if !WinDetectState.Active
        return
    WinDetectState.Suspended := true
    WinDetect_HideBars()
    if WinDetectCfg.ShowInfo
        ToolTip(, , , WinDetectCfg.TipIndex)
}

WinDetect_Resume() {
    if !WinDetectState.Active
        return
    WinDetectState.Suspended := false
    WinDetectState.LastX := -99999          ; force a redraw on the next tick
    WinDetectState.LastY := -99999
    WinDetect_Tick()
}

; Fetch the highlighted rectangle.  false when nothing is highlighted (cursor
; over no eligible window, detection suspended, or not running).
WinDetect_GetRect(&x, &y, &w, &h) {
    if (!WinDetectState.Active || WinDetectState.Suspended || WinDetectState.Candidates.Length = 0)
        return false

    item := WinDetectState.Candidates[WinDetect_ClampIndex()]
    x := item.x, y := item.y, w := item.w, h := item.h
    return true
}

; HWND of the highlighted window, or 0.
WinDetect_GetHwnd() {
    if (!WinDetectState.Active || WinDetectState.Suspended || WinDetectState.Candidates.Length = 0)
        return 0
    return WinDetectState.Candidates[WinDetect_ClampIndex()].hwnd
}

; Step deeper (+1) or shallower (-1) through the windows stacked under the
; cursor, wrapping at both ends.  Lets you reach a window that is completely
; covered by another at that point.
WinDetect_Cycle(delta) {
    if (!WinDetectState.Active || WinDetectState.Suspended || WinDetectState.Candidates.Length < 2)
        return
    n := WinDetectState.CandIndex + delta
    if (n < 1)
        n := WinDetectState.Candidates.Length
    else if (n > WinDetectState.Candidates.Length)
        n := 1
    WinDetectState.CandIndex := n
    WinDetect_Refresh()
}

WinDetect_IsActive() {
    return WinDetectState.Active
}


; ==============================================================================
; GEOMETRY
; ==============================================================================

; The TRUE visual bounds of a window.
;
; WinGetPos returns the DWM ghost frame, which on Win10 includes roughly 7px of
; INVISIBLE resize border down the left, right and bottom of most windows.  Use
; it and the outline sits visibly off the window on three sides, and the capture
; drags a strip of whatever is behind it into the snip.  DWMWA_EXTENDED_FRAME_BOUNDS
; is the one that matches what the eye sees.
;
; Values come back in real (physical) pixels, which is the same space ScreenSnip
; already works in — every one of its Guis is -DPIScale and the freeze backdrop
; is placed with raw virtual-screen coordinates.  So nothing needs converting at
; 125%, but that is WHY it doesn't, and it would break if that ever changed.
WinDetect_GetRectDwm(hwnd, &x, &y, &w, &h) {
    static DWMWA_EXTENDED_FRAME_BOUNDS := 9
    rect := Buffer(16, 0)

    if (DllCall('dwmapi\DwmGetWindowAttribute', 'Ptr', hwnd
              , 'UInt', DWMWA_EXTENDED_FRAME_BOUNDS
              , 'Ptr', rect, 'UInt', 16, 'Int') != 0) {      ; non-zero = failed
        try WinGetPos(&x, &y, &w, &h, 'ahk_id ' hwnd)        ; fall back
        catch
            return false
        return (w > 0 && h > 0)
    }

    l := NumGet(rect,  0, 'Int'), t := NumGet(rect,  4, 'Int')
    r := NumGet(rect,  8, 'Int'), b := NumGet(rect, 12, 'Int')
    x := l, y := t, w := r - l, h := b - t
    return (w > 0 && h > 0)
}

; UWP shells, and every window parked on ANOTHER virtual desktop, report as
; visible but are cloaked by DWM.  Skipping this check is what produces the
; classic phantom: a full-screen highlight over an invisible "Windows Shell
; Experience Host" that swallows every hit test on the desktop.
WinDetect_IsCloaked(hwnd) {
    static DWMWA_CLOAKED := 14
    val := Buffer(4, 0)
    if (DllCall('dwmapi\DwmGetWindowAttribute', 'Ptr', hwnd, 'UInt', DWMWA_CLOAKED
              , 'Ptr', val, 'UInt', 4, 'Int') != 0)
        return false
    return NumGet(val, 0, 'UInt') != 0
}

WinDetect_BuildSnapshot(excludeMap) {
    static skipClass := Map('SysShadow', 1, 'tooltips_class32', 1, 'Button', 1)

    snap  := []
    myPid := DllCall('GetCurrentProcessId', 'UInt')

    ; ScreenSnip sets DetectHiddenWindows true globally (line 4).  Left on, this
    ; scan would pull in every hidden window in the session, so it is turned off
    ; for the duration and restored afterwards — this runs on the same thread as
    ; the capture, and leaving it flipped would break WinGetPos elsewhere.
    prevDHW := A_DetectHiddenWindows
    DetectHiddenWindows(false)

    ; WinGetList is EnumWindows underneath, which walks top-level windows in
    ; Z-order starting at the topmost.  That ordering is the whole basis of
    ; "first hit wins" in the hit test below.
    for hwnd in WinGetList() {
        if excludeMap.Has(hwnd)
            continue
        if !DllCall('IsWindowVisible', 'Ptr', hwnd)
            continue
        if WinDetect_IsCloaked(hwnd)
            continue

        try {
            if (WinGetPID('ahk_id ' hwnd) = myPid)       ; our own Guis, incl. the
                continue                                 ; frozen backdrop + hint
            cls := WinGetClass('ahk_id ' hwnd)
        } catch
            continue                                     ; window died mid-scan

        if skipClass.Has(cls)
            continue
        if (!WinDetectCfg.IncludeDesktop && (cls = 'Progman' || cls = 'WorkerW'))
            continue
        if !WinDetect_GetRectDwm(hwnd, &x, &y, &w, &h)
            continue
        if (w < WinDetectCfg.MinSize || h < WinDetectCfg.MinSize)
            continue

        snap.Push({ hwnd: hwnd, x: x, y: y, w: w, h: h, cls: cls })
    }

    DetectHiddenWindows(prevDHW)

    ; Monitors go on the END of the list on purpose.  The hit test takes the
    ; FIRST match and the list is Z-ordered, so anything appended here can never
    ; pre-empt a real window — it is simply the last thing the wheel reaches.
    ; hwnd is 0 for these; nothing in the module dereferences it, and the label
    ; field is what the readout uses instead of a window title.
    if WinDetectCfg.IncludeMonitors {
        primary := MonitorGetPrimary()
        Loop MonitorGetCount() {
            try MonitorGet(A_Index, &mL, &mT, &mR, &mB)
            catch
                continue                                 ; display vanished mid-scan
            snap.Push({ hwnd: 0
                      , x: mL, y: mT, w: mR - mL, h: mB - mT
                      , cls: 'Screen'
                      , label: 'Monitor ' A_Index (A_Index = primary ? ' (primary)' : '') })
        }
    }

    return snap
}

WinDetect_HitTest(mx, my) {
    hits := []
    for item in WinDetectState.Snapshot {
        if (mx >= item.x && mx < item.x + item.w && my >= item.y && my < item.y + item.h)
            hits.Push(item)
    }
    return hits
}

WinDetect_ClampIndex() {
    i := WinDetectState.CandIndex
    if (i < 1)
        i := 1
    if (i > WinDetectState.Candidates.Length)
        i := WinDetectState.Candidates.Length
    return i
}


; ==============================================================================
; HIGHLIGHT  (four thin edge bars, so the window's own content stays visible —
;             a filled translucent overlay would tint the very pixels you are
;             about to capture and make it hard to confirm you have the right
;             window)
; ==============================================================================

WinDetect_CreateBars(excludeMap) {
    WinDetectState.Bars := []
    Loop 4 {
        ; -DPIScale is load-bearing at 125%: without it Move()'s coordinates get
        ; DPI-scaled while the DWM rects do not, and the outline drifts further
        ; off-window the further right you go across a multi-monitor desktop.
        ; E0x08000000 = WS_EX_NOACTIVATE  — never steals focus.
        ; E0x00000020 = WS_EX_TRANSPARENT — clicks fall straight through, so the
        ;               outline can't swallow the left-click that selects it.
        g := Gui('+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000020')
        g.BackColor := WinDetectCfg.Color
        g.MarginX := 0
        g.MarginY := 0
        g.Show('x-30000 y-30000 w1 h1 NoActivate')
        excludeMap[g.Hwnd] := true
        WinDetectState.Bars.Push(g)
    }
}

WinDetect_DrawRect(x, y, w, h) {
    t := WinDetectState.Thick
    if (t * 2 > w)
        t := Max(1, w // 2)
    if (t * 2 > h)
        t := Max(1, h // 2)

    b := WinDetectState.Bars
    if (b.Length < 4)
        return

    ; Move(), never Show().  A repeated Show() re-raises the window every tick,
    ; which flickers hard over a full-screen layered backdrop.
    b[1].Move(x,         y,         w, t)          ; top
    b[2].Move(x,         y + h - t, w, t)          ; bottom
    b[3].Move(x,         y,         t, h)          ; left
    b[4].Move(x + w - t, y,         t, h)          ; right
}

; "Hidden" means parked off-screen rather than Hide()d — toggling visibility on
; four topmost windows at poll rate flickers; moving them does not.
WinDetect_HideBars() {
    for g in WinDetectState.Bars {
        try g.Move(-30000, -30000, 1, 1)
    }
    WinDetectState.ShownRect := ''
}

; Among topmost windows the most recently raised one wins, so the bars must be
; created AFTER the frozen backdrop is shown.  ScreenSnip does that already; this
; is here for the case where some future overlay gets shown later still.
WinDetect_RaiseBars() {
    for g in WinDetectState.Bars {
        try WinMoveTop('ahk_id ' g.Hwnd)
    }
}


; ==============================================================================
; POLLING
; ==============================================================================

WinDetect_Tick() {
    if (!WinDetectState.Active || WinDetectState.Suspended)
        return

    ; CoordMode is per-thread and this runs on a timer thread, so it must be set
    ; here explicitly and restored — ScreenSnip's other code assumes its own.
    prevCM := A_CoordModeMouse
    CoordMode('Mouse', 'Screen')
    MouseGetPos(&mx, &my)
    CoordMode('Mouse', prevCM)

    if (mx = WinDetectState.LastX && my = WinDetectState.LastY)
        return
    WinDetectState.LastX := mx
    WinDetectState.LastY := my

    WinDetectState.Candidates := WinDetect_HitTest(mx, my)

    ; Hold the user's cycle depth while the cursor stays over the same window,
    ; and reset it only when the topmost window underneath actually changes.
    ; Resetting on every move would snap the highlight back to the top layer on
    ; the slightest hand tremor, making the wheel useless.
    newTop := WinDetectState.Candidates.Length ? WinDetectState.Candidates[1].hwnd : 0
    if (newTop != WinDetectState.LastTop) {
        WinDetectState.CandIndex := 1
        WinDetectState.LastTop   := newTop
    }

    WinDetect_Refresh()
}

WinDetect_Refresh() {
    if (WinDetectState.Candidates.Length = 0) {
        WinDetect_HideBars()
        if WinDetectCfg.ShowInfo
            ToolTip(, , , WinDetectCfg.TipIndex)
        return
    }

    item := WinDetectState.Candidates[WinDetect_ClampIndex()]

    ; Only touch the bars when the rectangle actually changes.  Moving within one
    ; window fires the tick but does no window work at all.
    key := item.x ',' item.y ',' item.w ',' item.h
    if (key != WinDetectState.ShownRect) {
        WinDetect_DrawRect(item.x, item.y, item.w, item.h)
        WinDetectState.ShownRect := key
    }

    if WinDetectCfg.ShowInfo
        WinDetect_ShowInfo(item)
}

WinDetect_ShowInfo(item) {
    ; Monitor entries carry a label and no window; everything else is titled.
    if item.HasOwnProp('label')
        title := item.label
    else {
        title := ''
        try title := WinGetTitle('ahk_id ' item.hwnd)
        if (StrLen(title) > 44)
            title := SubStr(title, 1, 41) '...'
        if (title = '')
            title := '(untitled)'
    }

    txt := title '`n' item.cls '  —  ' item.w ' x ' item.h
    if (WinDetectState.Candidates.Length > 1)
        txt .= '`n[' WinDetect_ClampIndex() ' of ' WinDetectState.Candidates.Length '] — wheel to cycle'

    prevCM := A_CoordModeMouse
    CoordMode('Mouse', 'Screen')
    MouseGetPos(&mx, &my)
    CoordMode('Mouse', prevCM)

    prevTT := A_CoordModeToolTip
    CoordMode('ToolTip', 'Screen')
    ToolTip(txt, mx + 18, my + 24, WinDetectCfg.TipIndex)
    CoordMode('ToolTip', prevTT)
}


; ==============================================================================
; SELF-TEST   (reached only when this file is run as its own script — see the
;              note in the header about why it can't be combined with a Freeze
;              Capture from a separately running ScreenSnip)
;
; Every hotkey here is created at RUNTIME via Hotkey(), so #Include'ing this file
; registers nothing.  A statically defined LButton hotkey would install a mouse
; hook in ScreenSnip permanently, which is exactly what we don't want.
; ==============================================================================

WinDetect_RunSelfTest() {
    Hotkey('F1',  WinDetect_TestStart, 'On')
    Hotkey('F12', WinDetect_TestQuit,  'On')
    ToolTip('SnipWinDetect self-test`n`nF1  = start detection`nF12 = exit script', 20, 20, 20)
    SetTimer(() => ToolTip(, , , 20), -6000)
}

WinDetect_TestStart(*) {
    if WinDetect_IsActive()
        return
    if !WinDetect_Begin() {
        MsgBox('Detection is switched off — see WinDetectCfg.Enabled at the top of '
             . 'SnipWinDetect.ahk.', 'SnipWinDetect self-test')
        return
    }
    Hotkey('LButton',   WinDetect_TestPick,      'On')
    Hotkey('WheelUp',   WinDetect_TestWheelUp,   'On')
    Hotkey('WheelDown', WinDetect_TestWheelDown, 'On')
    Hotkey('Escape',    WinDetect_TestStop,      'On')
}

WinDetect_TestPick(*) {
    if !WinDetect_GetRect(&x, &y, &w, &h) {
        WinDetect_TestStop()
        return
    }
    hwnd  := WinDetect_GetHwnd()
    title := ''
    try title := WinGetTitle('ahk_id ' hwnd)
    WinDetect_TestStop()
    MsgBox('Would capture:`n`n' title
         . '`nhwnd: ' hwnd
         . '`nx' x '  y' y '  w' w '  h' h, 'SnipWinDetect self-test')
}

WinDetect_TestStop(*) {
    WinDetect_End()
    Hotkey('LButton',   'Off')
    Hotkey('WheelUp',   'Off')
    Hotkey('WheelDown', 'Off')
    Hotkey('Escape',    'Off')
}

WinDetect_TestWheelUp(*)   => WinDetect_Cycle(1)
WinDetect_TestWheelDown(*) => WinDetect_Cycle(-1)
WinDetect_TestQuit(*)      => ExitApp()
