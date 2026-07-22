#Requires AutoHotkey v2
#Warn All, Off
#SingleInstance Force
DetectHiddenWindows true
SetWinDelay(0)

;               ScreenSnip.ahk
;
; Github https://github.com/kunkel321/ScreenSnip
; AHK Forum https://www.autohotkey.com/boards/viewtopic.php?f=83&t=140802
;
; Based on Snipper by FanaticGuru 
; https://www.autohotkey.com/boards/viewtopic.php?f=83&t=115622
;
; Adapted and simplified by kunkel321 / Claude
; Version date: 7-22-2026
; Drag to capture a screen region; the snip floats as a borderless
; always-on-top window.  Multiple snips can be open at once.
; Each snip also keeps a frozen "master" snapshot of a slightly larger
; area (see CaptureAdjustMargin), so AFTER capturing you can pan or resize
; the captured region — and nudge the floating window — via hotkeys or the
; right-click menu, without re-grabbing (and re-occluding) the screen.
; The post-capture adjust-region idea was suggested by forum user alnz123.
; Known issue:  Can't snip elevated windows unless ScreenSnip is also
; running in elevated (admin) mode.  Top of SysTray Menu shows
; "ScreenSnip (admin)" when running in admin mode.  See also help dialog.
; OCR functionality uses Descolada's OCR.ahk and Paddle OCR.  Please see 
; companion SnipOCR.ahk comments for details.
;
; Hotkey cheat sheet — shown via F1 or right-click menu > Help.
HelpText := "ScreenSnip " (A_IsAdmin? "is":"is NOT") " currently running as admin.`n"
. "
(
  ------------------------------------------------
  CAPTURING
  Ctrl + RButton drag          Capture region
  Ctrl + Shift + RButton drag  Capture + copy to clipboard
  Shift + PrintScreen          Toggle show / hide all snips

  SNIP CONTROLS  (snip window must be focused)
  Left-click drag              Move
  Right-click                  Context menu
  Esc                          Close this snip

  OCR  (right-click menu > OCR)
  Copy Text (Windows)          Fast text grab, no setup
  Copy Text (PaddleOCR)        Slower, more accurate
  Copy Table (PaddleOCR)       Rebuilds a grid; paste into Excel

  TRANSPARENCY
  Alt + Up / Down              Adjust ±25
  Alt + Wheel                  Adjust ±10

  ROTATION
  Alt + Left / Right           Rotate ±1°
  Shift + Alt + Left / Right   Snap to next 30° (CW / CCW)

  FLIP
  Shift + Left / Right         Flip horizontal
  Shift + Up / Down            Flip vertical

  NUDGE POSITION  (moves the floating window)
  Ctrl + Arrow                 Move ±1 px
  Ctrl + Shift + Arrow         Move ±10 px

  ADJUST CAPTURE REGION  (re-crops the frozen snapshot)
  Ctrl + Alt + Arrow           Pan region ±1 px
  Ctrl + Shift + Alt + Arrow   Pan region ±10 px
  Win + Alt + Arrow            Resize ±1 px  (grow = Right / Down)
  Win + Shift + Alt + Arrow    Resize ±10 px
  (Range is limited by CaptureAdjustMargin, set near top of script.)
)"

; ── Globals ────────────────────────────────────────────────────────────────────
global guiSnips    := Map()   ; hwnd → { GuiObj, Area }
global SnipVisible := true

; ══════════════════════════════════════════════════════════════════════════════
; USER SETTINGS — adjust these to taste
; ══════════════════════════════════════════════════════════════════════════════

; Color of the semi-transparent selection overlay while dragging.
; Any AHK color name or hex value (e.g. 'Lime', 'Teal', '0xFF8800').
SelectionColor := 'b58500'

; Extra pixels captured AROUND your selection into a frozen "master"
; snapshot, so the capture region can be nudged/resized after the fact
; (see the ADJUST CAPTURE REGION hotkeys). This is the maximum you can
; pan or grow in any direction before hitting the edge of the snapshot.
; Larger = more adjustment headroom, but more memory per snip (a 32-bit
; bitmap is width * height * 4 bytes).
;   0      = no headroom; region is fixed at the exact selection.
;   150    = a comfortable default for fixing small clipped edges.
;   99999  = effectively snapshots the WHOLE desktop into every snip.
; The value is always clamped to the virtual desktop bounds, so oversized
; numbers are safe (they just capture everything and use more RAM — they
; won't crash or read off-screen).
CaptureAdjustMargin := 150

; Show a colored border around each floating snip?
; true = show border,  false = no border (image only, fully borderless)
ShowSnipBorder := true
; Note: Border is not shown during rotations other than 90, 180, or 90 CCW. 

; Border color for floating snips. Any AHK color name or hex value
; (e.g. 'Lime', '0x2d2d55'). Automatically matches SelectionColor by
; default so the UI feels cohesive — override to any color you like.
BorderColor := SelectionColor

; Border thickness in pixels (applied as Gui margin on each side).
BorderThickness := 2

; Give the snip border a 3D "floating" bevel look — top/left edges lighter,
; bottom/right edges darker, both derived from the same border color.
; Looks best with thin borders (1-2px); automatically disabled above
; Bevel3DMaxThickness since thick beveled frames tend to look chunky/odd.
Bevel3D           := true
Bevel3DMaxThickness := 3
; How much lighter/darker the bevel edges are, 0.0-1.0 (fraction blended
; toward white for the light edges, toward black for the dark edges).
; Active and inactive snips use the same bevel strength/contrast — the
; difference between them comes from Bevel3DInactiveDarknessFactor below.
Bevel3DStrength         := 0.55
Bevel3DInactiveStrength := 0.55
; How much darker BOTH bevel edges (light and dark) get on an inactive
; (unfocused) snip, 0.0-1.0. E.g. 0.2 = both edges are 20% darker than
; they'd be on the active snip — same contrast/shape, just dimmed overall,
; which gives a focus cue without needing a second border color.
Bevel3DInactiveDarknessFactor := 0.5

; Position of the W and H labels during selection.
; InfoWHOffsetRight  — inset from the right edge for the H (height) label.
; InfoWHOffsetBottom — inset from the bottom edge for the W (width) label.
InfoWHOffsetRight  := 38
InfoWHOffsetBottom := 25

; Font size (points) for the W and H dimension labels during selection.
InfoFontSize := 10

; Minimum selection size (pixels) before each label appears.
; InfoWMinWidth  — selection must be at least this wide to show the W label.
; InfoHMinHeight — selection must be at least this tall to show the H label.
InfoWMinWidth  := 75
InfoHMinHeight := 55

; Transparent color key used to hide the corners of rotated snips.
; Always magenta — chosen because it almost never appears naturally in
; screen captures, avoiding accidental transparency within the image.
TransColor := 0xFF00FF
; Known issue: During rotation, at points other than 90, 180, or 90 CCW, 
; an annoying magenta halo of pixels will appear around the edge of the snip.  

; ══════════════════════════════════════════════════════════════════════════════

; ── DPI awareness (helps on scaled displays) ───────────────────────────────────
Try DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr")

; ── GDI+ stays alive for the entire session ────────────────────────────────────
GDIp.Startup()
OnExit(CleanupOnExit)

; Diagnostic: capture any unhandled error to a log file. Error dialogs raised
; during exit vanish before they can be read, so this preserves the message.
; Returns 0 so AHK's normal handling still proceeds. Safe to delete once the
; exit-time error is resolved.
OnError(LogUnhandledError) ;  <---- Temporary for debugging.
LogUnhandledError(err, mode) {
    try FileAppend(FormatTime(A_Now, 'yyyy-MM-dd HH:mm:ss') '  '
        (IsObject(err) ? err.Message ' (' err.File ':' err.Line ')' : String(err))
        '`n', A_ScriptDir '\ScreenSnip_error.log')
    return 0
}

; Ordered teardown: unhook the bevel paint/activate handlers FIRST so they
; can't fire against half-destroyed windows during shutdown, then dispose all
; snip bitmaps + windows, then shut GDI+ down last (so no image object outlives
; the GDI+ session). Each step is guarded so one failure can't abort the rest.
CleanupOnExit(*) {
    try OnMessage(0x000F, WM_PAINT_BEVEL, 0)     ; deregister (MaxThreads 0)
    try OnMessage(0x0006, WM_ACTIVATE_BEVEL, 0)
    try CloseAllSnips()
    try GDIp.Shutdown()
}

; ── Tray icon & menu ──────────────────────────────────────────────────────────
TraySetIcon(A_WinDir '\system32\shell32.dll', 260)   ; scissors

appName := StrReplace(A_ScriptName, '.ahk')
; Show elevation state in the (disabled) title item so it's obvious at a glance
; whether this instance can snip elevated windows. A_IsAdmin is fixed at launch.
; Kept separate from appName, which the startup-shortcut logic still needs bare.
trayTitle := appName (A_IsAdmin ? '  (admin)' : '')
trayMenu := A_TrayMenu
trayMenu.Delete()
trayMenu.Add(trayTitle, (*) => False)
trayMenu.Disable(trayTitle)
trayMenu.Add()
trayMenu.AddStandard()
trayMenu.Add()
trayMenu.Add('Start with Windows', TrayStartup)
if FileExist(A_Startup '\' appName '.lnk')
    trayMenu.Check('Start with Windows')
trayMenu.Add()
trayMenu.Add('ScreenSnip Help', (*) => ShowHelp())
trayMenu.Default := trayTitle

TrayStartup(*) {
    global appName
    lnk := A_Startup '\' appName '.lnk'
    if FileExist(lnk) {
        FileDelete(lnk)
        MsgBox(appName ' will NO LONGER auto-start with Windows.', appName, 4096)
    } else {
        FileCreateShortcut(A_ScriptFullPath, lnk, A_WorkingDir, '', '',
            A_WinDir '\system32\shell32.dll', '', '260')
        MsgBox(appName ' will now auto-start with Windows.', appName, 4096)
    }
    Reload()
}

; ── Context menu for snip windows ─────────────────────────────────────────────
; Most snip manipulation is meant to be done with hotkeys (see the F1 help),
; but the actions are mirrored here so they're discoverable, and each item that
; has a hotkey shows it right-aligned as a reminder.  Directional items act on
; the snip that was right-clicked (SnipMenu._targetHwnd) and use a 1px step;
; hold Shift with the equivalent hotkey for a 10px step.
noop := (*) => 0
SnipMenu := Menu()
SnipMenu.Add('Copy to Clipboard', SnipMenu_Handler)

; OCR submenu — see SnipOCR.ahk (included at the bottom of this file) for setup.
OcrMenu := Menu()
OcrMenu.Add('Copy Text (Windows)',    SnipMenu_Handler)  ; fast, no engine to install
OcrMenu.Add('Copy Text (PaddleOCR)',  SnipMenu_Handler)  ; slower, more accurate
OcrMenu.Add('Copy Table (PaddleOCR)', SnipMenu_Handler)  ; rebuilds a grid as TSV
SnipMenu.Add('OCR', OcrMenu)

SnipMenu.Add('')

RotateMenu := Menu()
RotateMenu.Add('Rotate 90° CW',  SnipMenu_Handler)
RotateMenu.Add('Rotate 180°',    SnipMenu_Handler)
RotateMenu.Add('Rotate 90° CCW', SnipMenu_Handler)
RotateMenu.Add('')
RotateMenu.Add('Alt+←/→ = ±1°  ·  +Shift = snap 30°', noop)   ; hotkey reminder
RotateMenu.Disable('Alt+←/→ = ±1°  ·  +Shift = snap 30°')
SnipMenu.Add('Rotate', RotateMenu)

FlipMenu := Menu()
FlipMenu.Add('Flip Horizontal (L/R)`tShift+←/→', SnipMenu_Handler)
FlipMenu.Add('Flip Vertical (U/D)`tShift+↑/↓',   SnipMenu_Handler)
SnipMenu.Add('Flip', FlipMenu)

; Move the floating window (does NOT change what was captured).
NudgeMenu := Menu()
NudgeMenu.Add('Move Up`tCtrl+↑',    SnipAdjustFromMenu.Bind(NudgeSnip,  0, -1))
NudgeMenu.Add('Move Down`tCtrl+↓',  SnipAdjustFromMenu.Bind(NudgeSnip,  0, +1))
NudgeMenu.Add('Move Left`tCtrl+←',  SnipAdjustFromMenu.Bind(NudgeSnip, -1,  0))
NudgeMenu.Add('Move Right`tCtrl+→', SnipAdjustFromMenu.Bind(NudgeSnip, +1,  0))
NudgeMenu.Add('')
NudgeMenu.Add('Hold Shift → ±10 px', noop)
NudgeMenu.Disable('Hold Shift → ±10 px')
SnipMenu.Add('Nudge Position', NudgeMenu)

; Pan the capture region over the frozen snapshot (changes which pixels show).
PanMenu := Menu()
PanMenu.Add('Pan Up`tCtrl+Alt+↑',    SnipAdjustFromMenu.Bind(PanSnipRegion,  0, -1))
PanMenu.Add('Pan Down`tCtrl+Alt+↓',  SnipAdjustFromMenu.Bind(PanSnipRegion,  0, +1))
PanMenu.Add('Pan Left`tCtrl+Alt+←',  SnipAdjustFromMenu.Bind(PanSnipRegion, -1,  0))
PanMenu.Add('Pan Right`tCtrl+Alt+→', SnipAdjustFromMenu.Bind(PanSnipRegion, +1,  0))
PanMenu.Add('')
PanMenu.Add('Hold Shift → ±10 px', noop)
PanMenu.Disable('Hold Shift → ±10 px')
SnipMenu.Add('Pan Region', PanMenu)

; Resize the capture region (grow/shrink what was captured).
ResizeMenu := Menu()
ResizeMenu.Add('Grow Width`tWin+Alt+→',    SnipAdjustFromMenu.Bind(ResizeSnipRegion, +1,  0))
ResizeMenu.Add('Shrink Width`tWin+Alt+←',  SnipAdjustFromMenu.Bind(ResizeSnipRegion, -1,  0))
ResizeMenu.Add('Grow Height`tWin+Alt+↓',   SnipAdjustFromMenu.Bind(ResizeSnipRegion,  0, +1))
ResizeMenu.Add('Shrink Height`tWin+Alt+↑', SnipAdjustFromMenu.Bind(ResizeSnipRegion,  0, -1))
ResizeMenu.Add('')
ResizeMenu.Add('Hold Shift → ±10 px', noop)
ResizeMenu.Disable('Hold Shift → ±10 px')
SnipMenu.Add('Resize Region', ResizeMenu)

SnipMenu.Add('')
SnipMenu.Add('Border',          SnipMenu_Handler)   ; checkable toggle

SnipMenu.Add('')
SnipMenu.Add('Close This Snip`tEsc', SnipMenu_Handler)
SnipMenu.Add('Close All Snips',      SnipMenu_Handler)
SnipMenu.Add('')
SnipMenu.Add('Help`tF1',        SnipMenu_Handler)

; Initialise the Border menu item to reflect the default ShowSnipBorder setting
if ShowSnipBorder
    SnipMenu.Check('Border')

; ── WM handlers (must be registered before hotkeys fire) ──────────────────────
OnMessage(0x200, WM_MOUSEMOVE)    ; keep selection overlay from stealing focus
OnMessage(0x201, WM_LBUTTONDOWN)  ; allow dragging snip windows
OnMessage(0x000F, WM_PAINT_BEVEL) ; re-paint the 3D bevel after any repaint
OnMessage(0x0006, WM_ACTIVATE_BEVEL) ; refresh bevel strength on focus change

; ==============================================================================
; HOTKEYS
; ==============================================================================

^+RButton::  ; hide
^RButton:: {  ; Ctrl + RButton drag — snip (+ clipboard if Shift held) ; hide
    global guiSnips, SelectionColor
    Area := SelectScreenRegion('RButton', SelectionColor)
    if (Area.W > 8 && Area.H > 8)
        SnipArea(Area, GetKeyState('Shift'), &guiSnips)
}

+PrintScreen:: {  ; Shift + PrintScreen — toggle all snips ; hide
    global SnipVisible, guiSnips
    SnipVisible := !SnipVisible
    for Hwnd, snip in guiSnips
        SnipVisible ? snip.GuiObj.Show('NA') : snip.GuiObj.Hide()
}

#HotIf WinActive('SnipperWindow ahk_class AutoHotkeyGUI')
Esc::           CloseSnip() ; hide
F1::            ShowHelp() ; hide
!Up::           AdjustSnipAlpha(+25) ; hide
!Down::         AdjustSnipAlpha(-25) ; hide
!WheelUp::      AdjustSnipAlpha(+10) ; hide
!WheelDown::    AdjustSnipAlpha(-10) ; hide
!Left::         AdjustSnipAngle(-1) ; hide
!Right::        AdjustSnipAngle(+1) ; hide
!+Left::        SnapSnipAngle(-1) ; hide
!+Right::       SnapSnipAngle(+1) ; hide
+Left::         FlipSnip(WinGetID('A'), 'FlipH') ; hide
+Right::        FlipSnip(WinGetID('A'), 'FlipH') ; hide
+Up::           FlipSnip(WinGetID('A'), 'FlipV') ; hide
+Down::         FlipSnip(WinGetID('A'), 'FlipV') ; hide
^Left::         NudgeSnip(-1,  0) ; hide
^Right::        NudgeSnip(+1,  0) ; hide
^Up::           NudgeSnip( 0, -1) ; hide
^Down::         NudgeSnip( 0, +1) ; hide
^+Left::        NudgeSnip(-10,  0) ; hide
^+Right::       NudgeSnip(+10,  0) ; hide
^+Up::          NudgeSnip(  0, -10) ; hide
^+Down::        NudgeSnip(  0, +10) ; hide
; ── Adjust the CAPTURE REGION over the frozen master snapshot ──────────────
; A coherent family, all "Arrow + modifiers, add Shift for a 10px step":
;   Ctrl        = move the floating window   (NudgeSnip, above)
;   Ctrl+Alt    = pan the region             (which pixels show)
;   Win+Alt     = resize the region          (grow: Right/Down, shrink: Left/Up)
; Plain arrows are deliberately left UNBOUND so a reflexive "arrow to move it"
; can't silently resize the capture. All are clamped to CaptureAdjustMargin.
^!Left::        PanSnipRegion(-1,  0) ; hide
^!Right::       PanSnipRegion(+1,  0) ; hide
^!Up::          PanSnipRegion( 0, -1) ; hide
^!Down::        PanSnipRegion( 0, +1) ; hide
^!+Left::       PanSnipRegion(-10,  0) ; hide
^!+Right::      PanSnipRegion(+10,  0) ; hide
^!+Up::         PanSnipRegion( 0, -10) ; hide
^!+Down::       PanSnipRegion( 0, +10) ; hide
#!Left::        ResizeSnipRegion(-1,  0) ; hide
#!Right::       ResizeSnipRegion(+1,  0) ; hide
#!Up::          ResizeSnipRegion( 0, -1) ; hide
#!Down::        ResizeSnipRegion( 0, +1) ; hide
#!+Left::       ResizeSnipRegion(-10,  0) ; hide
#!+Right::      ResizeSnipRegion(+10,  0) ; hide
#!+Up::         ResizeSnipRegion( 0, -10) ; hide
#!+Down::       ResizeSnipRegion( 0, +10) ; hide
#HotIf

; ==============================================================================
; SNIP MANAGEMENT
; ==============================================================================

; Create a floating snip from a screen area.
; SetClipboard=true also puts the image on the clipboard.
SnipArea(Area, SetClipboard, &ObjMap) {
    global ShowSnipBorder, BorderThickness, BorderColor, TransColor, CaptureAdjustMargin
    dpi := A_ScreenDPI + 0.0

    ; ── Frozen master snapshot ────────────────────────────────────────────────
    ; Grab the selection PLUS a margin on every side into a bitmap we keep for
    ; the snip's lifetime. Post-capture "adjust region" simply crops a different
    ; sub-rectangle out of THIS frozen copy — so we never re-BitBlt the live
    ; screen (which would re-capture the snip's own always-on-top window and any
    ; overlapping windows). The margin is clamped to the virtual desktop, so a
    ; huge CaptureAdjustMargin just snapshots everything on-screen and can't read
    ; off-screen or produce negative dimensions.
    GetVirtualScreen(&vx, &vy, &vw, &vh)
    m      := Max(0, CaptureAdjustMargin)
    mLeft  := Max(Area.X - m,            vx)
    mTop   := Max(Area.Y - m,            vy)
    mRight := Min(Area.X + Area.W + m,   vx + vw)
    mBot   := Min(Area.Y + Area.H + m,   vy + vh)
    masterX := mLeft,                 masterY := mTop
    masterW := Max(1, mRight - mLeft), masterH := Max(1, mBot - mTop)

    SrcBitmap := GDIp.BitmapFromScreen({ X: masterX, Y: masterY, W: masterW, H: masterH })
    DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', SrcBitmap, 'Float', dpi, 'Float', dpi)

    ; Crop rectangle in master-local coords, initially the exact selection.
    ; Defensive clamp keeps it inside the snapshot even in odd edge cases.
    crop := { X: Area.X - masterX, Y: Area.Y - masterY, W: Area.W, H: Area.H }
    crop.X := Max(0, Min(crop.X, masterW - 1))
    crop.Y := Max(0, Min(crop.Y, masterH - 1))
    crop.W := Max(1, Min(crop.W, masterW - crop.X))
    crop.H := Max(1, Min(crop.H, masterH - crop.Y))

    ; Displayed bitmap starts as the upright crop — identical to a direct grab.
    pBitmap := GDIp.CloneBitmapArea(SrcBitmap, crop.X, crop.Y, crop.W, crop.H)
    DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', pBitmap, 'Float', dpi, 'Float', dpi)

    if SetClipboard
        GDIp.SetBitmapToClipboard(pBitmap)

    ; Transparent color key for the corners — always the fixed TransColor.
    snipTransColor := Integer(TransColor)

    g := Gui('-Caption +AlwaysOnTop +OwnDialogs +E0x80000', 'SnipperWindow')

    if ShowSnipBorder {
        g.MarginX := BorderThickness, g.MarginY := BorderThickness
        g.BackColor := BorderColor
    } else {
        g.MarginX := 0, g.MarginY := 0
        g.BackColor := Format('0x{:06X}', snipTransColor)
    }
    SetLayeredWinAttribs(g.Hwnd, snipTransColor, 255)

    hBitmap := GDIp.CreateHBITMAPFromBitmap(pBitmap)
    picOffset := ShowSnipBorder ? BorderThickness : 0
    g.Pic := g.Add('Picture', 'x' picOffset ' y' picOffset, 'HBITMAP:' hBitmap)

    ; Right-click context menu via the GUI's own ContextMenu event. This fires
    ; on button-UP (so the menu opens with a normal click instead of needing
    ; the button held) and runs in the context of the clicked window (so the
    ; activation below isn't fighting the foreground lock the way the old
    ; global ~RButton hotkey was). The event covers the Picture child too.
    g.OnEvent('ContextMenu', ShowSnipMenu)

    g.Show('NA x' Area.X - picOffset ' y' Area.Y - picOffset)
    global Bevel3D, Bevel3DMaxThickness
    if (ShowSnipBorder && Bevel3D && BorderThickness <= Bevel3DMaxThickness)
        DrawSnipBevel(g, BorderColor, BorderThickness, BevelStrengthFor(g.Hwnd), BevelDarknessFor(g.Hwnd))

    ; State model: SrcBitmap (frozen master) + Crop (which sub-rect shows) are
    ; the source of truth for CONTENT; Angle/FlipH/FlipV are a display transform
    ; layered on top. pBitmap always holds the current UPRIGHT crop (handy for
    ; OCR and re-rendering). Everything routes through RenderSnip().
    ObjMap[g.Hwnd] := { GuiObj: g, Area: Area, Alpha: 255, pBitmap: pBitmap
                      , Angle: 0, FlipH: false, FlipV: false
                      , HasBorder: ShowSnipBorder, TransColor: snipTransColor
                      , SrcBitmap: SrcBitmap, SrcX: masterX, SrcY: masterY
                      , MasterW: masterW, MasterH: masterH, Crop: crop }

    ; Do NOT DisposeImage here — pBitmap and SrcBitmap are kept for the snip's life.
    return g.Hwnd
}

; Close one snip (defaults to active window).
CloseSnip(Hwnd?) {
    global guiSnips
    if !IsSet(Hwnd)
        Hwnd := WinGetID('A')
    if guiSnips.Has(Hwnd) {
        snip := guiSnips[Hwnd]
        guiSnips.Delete(Hwnd)   ; remove first so in-flight handlers/timers bail out
        GDIp.DisposeImage(snip.pBitmap)
        if (snip.HasProp('SrcBitmap') && snip.SrcBitmap)
            GDIp.DisposeImage(snip.SrcBitmap)
        snip.GuiObj.Destroy()
    }
}

; Close every open snip.
CloseAllSnips() {
    global guiSnips
    snipsToClose := guiSnips
    guiSnips := Map()   ; clear first so in-flight handlers/timers bail out
    for Hwnd, snip in snipsToClose {
        GDIp.DisposeImage(snip.pBitmap)
        if (snip.HasProp('SrcBitmap') && snip.SrcBitmap)
            GDIp.DisposeImage(snip.SrcBitmap)
        snip.GuiObj.Destroy()
    }
}

; Copy the image from a snip to the clipboard (no border).
SnipToClipboard(Hwnd?) {
    global guiSnips
    if !IsSet(Hwnd)
        Hwnd := WinGetID('A')
    if !guiSnips.Has(Hwnd)
        return
    hBitmap := SendMessage(0x173, 0, 0, guiSnips[Hwnd].GuiObj.Pic)
    GDIp.SetHBITMAPToClipboard(hBitmap)
}

; Apply both a color key (for transparent corners) and overall alpha to a
; layered window simultaneously.  colorKey is an RGB integer (e.g. 0xFF00FF).
; alpha is 0 (invisible) – 255 (opaque).  Flags: 0x1=LWA_COLORKEY, 0x2=LWA_ALPHA.
SetLayeredWinAttribs(hwnd, colorKey, alpha) {
    DllCall('SetLayeredWindowAttributes', 'Ptr', hwnd,
            'UInt', colorKey, 'UChar', alpha, 'UInt', 0x3)
}

; Adjust transparency of the active snip.
; Delta is +/- step; alpha 255 = fully opaque, 20 = nearly invisible.
AdjustSnipAlpha(delta) {
    global guiSnips
    hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    snip.Alpha := Max(20, Min(255, snip.Alpha + delta))
    SetLayeredWinAttribs(hwnd, snip.TransColor, snip.Alpha)
}

; Rotate the active snip by delta degrees (cumulative, arbitrary angle).
; Just updates the tracked Angle; RenderSnip rebuilds from the frozen master.
AdjustSnipAngle(delta) {
    global guiSnips
    hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    snip.Angle := Mod(snip.Angle + delta + 360, 360)
    RenderSnip(snip)
}

; ==============================================================================
; RENDER PIPELINE  (single source of truth for what a snip displays)
; ==============================================================================
; Every content or transform change — recrop (pan/resize), rotate, flip —
; mutates the snip's state (Crop / Angle / FlipH / FlipV) and then calls
; RenderSnip(). The pipeline is always:
;
;     SrcBitmap ──crop(Crop)──► pBitmap (upright) ──flips──►──rotate──► display
;
; Because rotation and flips are re-derived from the upright crop every time
; (never baked in), "do X then Y" combinations — e.g. flip, then adjust the
; region, then rotate — stay well-defined and can't corrupt each other.

; Build the on-screen (transformed) bitmap from a snip's upright crop.
; Returns a NEW bitmap that the caller must dispose; never mutates pBitmap.
BuildDisplayBitmap(snip) {
    ; Work on a clone so the stored upright crop (pBitmap) is left intact.
    DllCall('gdiplus\GdipCloneImage', 'UPtr', snip.pBitmap, 'UPtr*', &work := 0)
    if !work
        return 0

    ; Flips first — lossless, exact.
    if snip.FlipH
        DllCall('gdiplus\GdipImageRotateFlip', 'UPtr', work, 'Int', 4)   ; FlipX (horizontal)
    if snip.FlipV
        DllCall('gdiplus\GdipImageRotateFlip', 'UPtr', work, 'Int', 6)   ; FlipY (vertical)

    angle := Mod(snip.Angle + 360, 360)
    if (angle = 0) {
        result := work                                   ; nothing more to do
    } else if (Mod(angle, 90) = 0) {
        ; Exact 90/180/270 — lossless, no transparent-corner halo.
        DllCall('gdiplus\GdipImageRotateFlip', 'UPtr', work, 'Int', angle // 90)
        result := work
    } else {
        ; Arbitrary angle — padded bounding box with trans-color corners.
        result := GDIp.RotateBitmap(work, angle, snip.TransColor)
        GDIp.DisposeImage(work)
    }

    dpi := A_ScreenDPI + 0.0
    DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', result, 'Float', dpi, 'Float', dpi)
    return result
}

; Rebuild a snip's picture + window from its frozen master and current state.
RenderSnip(snip) {
    global BorderThickness, BorderColor, Bevel3D, Bevel3DMaxThickness
    g    := snip.GuiObj
    hwnd := g.Hwnd
    dpi  := A_ScreenDPI + 0.0

    ; 1) Fresh upright crop from the master. Clone into a temp first so a rare
    ;    failure can't leave the snip with a disposed pBitmap and no image.
    newCrop := GDIp.CloneBitmapArea(snip.SrcBitmap, snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H)
    if !newCrop
        return
    DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', newCrop, 'Float', dpi, 'Float', dpi)
    if snip.pBitmap
        GDIp.DisposeImage(snip.pBitmap)
    snip.pBitmap := newCrop

    ; Keep Area (screen coords of the current capture rect) in sync for any
    ; consumer that reads it (e.g. OCR helpers).
    snip.Area := { X: snip.SrcX + snip.Crop.X, Y: snip.SrcY + snip.Crop.Y
                 , W: snip.Crop.W, H: snip.Crop.H }

    ; 2) Apply the display transform (flips + rotation).
    display := BuildDisplayBitmap(snip)
    if !display
        return

    ; Border only shows at cardinal angles; otherwise it's just a bg flash.
    isCardinal := (Mod(snip.Angle, 90) = 0)
    showBorder := snip.HasBorder && isCardinal

    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', display, 'UInt*', &newW := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', display, 'UInt*', &newH := 0)

    scale      := A_ScreenDPI / 96
    physBorder := showBorder ? Round(BorderThickness * scale) : 0
    totalW     := newW + physBorder * 2
    totalH     := newH + physBorder * 2

    ; Keep the window centered on its current physical position. For a pan
    ; (size unchanged) this is a no-op move; for resize/rotate it grows or
    ; shrinks symmetrically around the current center.
    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', hwnd, 'Ptr', rect)
    curL := NumGet(rect, 0, 'Int'), curT := NumGet(rect,  4, 'Int')
    curR := NumGet(rect, 8, 'Int'), curB := NumGet(rect, 12, 'Int')
    centerX := (curL + curR) // 2,  centerY := (curT + curB) // 2
    newX := centerX - totalW // 2,  newY := centerY - totalH // 2

    if showBorder {
        g.BackColor := BorderColor
        g.MarginX := BorderThickness, g.MarginY := BorderThickness
    } else {
        g.BackColor := Format('0x{:06X}', snip.TransColor)
        g.MarginX := 0, g.MarginY := 0
    }

    ; Suppress redraws during the swap to prevent flicker.
    DllCall('SendMessage', 'Ptr', hwnd, 'UInt', 0x000B, 'Ptr', 0, 'Ptr', 0)

    ; Swap the Picture control, freeing the old HBITMAP we own (prevents a
    ; GDI handle leak that would otherwise grow fast under rapid recrops).
    oldHbm := SendMessage(0x0173, 0, 0, g.Pic.Hwnd)   ; STM_GETIMAGE
    DllCall('DestroyWindow', 'Ptr', g.Pic.Hwnd)
    hBitmap   := GDIp.CreateHBITMAPFromBitmap(display)
    picOffset := showBorder ? BorderThickness : 0
    g.Pic     := g.Add('Picture', 'x' picOffset ' y' picOffset, 'HBITMAP:' hBitmap)
    GDIp.DisposeImage(display)
    if oldHbm
        DllCall('DeleteObject', 'Ptr', oldHbm)

    DllCall('SetWindowPos', 'Ptr', hwnd, 'Ptr', 0,
            'Int', newX, 'Int', newY, 'Int', totalW, 'Int', totalH,
            'UInt', 0x0014)   ; SWP_NOZORDER | SWP_NOACTIVATE

    DllCall('SendMessage', 'Ptr', hwnd, 'UInt', 0x000B, 'Ptr', 1, 'Ptr', 0)
    DllCall('RedrawWindow', 'Ptr', hwnd, 'Ptr', 0, 'Ptr', 0,
            'UInt', 0x0085)   ; RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN

    if (showBorder && Bevel3D && BorderThickness <= Bevel3DMaxThickness)
        DrawSnipBevel(g, BorderColor, BorderThickness, BevelStrengthFor(hwnd), BevelDarknessFor(hwnd))

    if snip.Alpha < 255
        SetLayeredWinAttribs(hwnd, snip.TransColor, snip.Alpha)
}

; ==============================================================================
; ADJUST CAPTURE REGION  (re-crop the frozen master snapshot)
; ==============================================================================

; Pan the capture region over the frozen master (changes WHICH pixels show;
; size is unchanged). Clamped so the crop stays fully inside the snapshot.
PanSnipRegion(dx, dy, hwnd := 0) {
    global guiSnips
    if !hwnd
        hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !(snip.HasProp('SrcBitmap') && snip.SrcBitmap)
        return
    c  := snip.Crop
    nx := Max(0, Min(c.X + dx, snip.MasterW - c.W))
    ny := Max(0, Min(c.Y + dy, snip.MasterH - c.H))
    if (nx = c.X && ny = c.Y)                 ; hit the snapshot edge — nothing to do
        return
    c.X := nx, c.Y := ny
    RenderSnip(snip)
}

; Resize the capture region, anchored at its top-left corner (Right/Down grow,
; Left/Up shrink). Clamped to an 8px minimum and to the snapshot's far edges.
ResizeSnipRegion(dw, dh, hwnd := 0) {
    global guiSnips
    static MINSZ := 8
    if !hwnd
        hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !(snip.HasProp('SrcBitmap') && snip.SrcBitmap)
        return
    c  := snip.Crop
    nw := Max(MINSZ, Min(c.W + dw, snip.MasterW - c.X))
    nh := Max(MINSZ, Min(c.H + dh, snip.MasterH - c.Y))
    if (nw = c.W && nh = c.H)                 ; clamped — nothing changed
        return
    c.W := nw, c.H := nh
    RenderSnip(snip)
}

; Virtual-desktop bounds (all monitors), in physical pixels. Used to clamp the
; master snapshot so an oversized CaptureAdjustMargin can't read off-screen.
GetVirtualScreen(&vx, &vy, &vw, &vh) {
    vx := DllCall('GetSystemMetrics', 'Int', 76, 'Int')   ; SM_XVIRTUALSCREEN
    vy := DllCall('GetSystemMetrics', 'Int', 77, 'Int')   ; SM_YVIRTUALSCREEN
    vw := DllCall('GetSystemMetrics', 'Int', 78, 'Int')   ; SM_CXVIRTUALSCREEN
    vh := DllCall('GetSystemMetrics', 'Int', 79, 'Int')   ; SM_CYVIRTUALSCREEN
}

; Toggle a snip's horizontal or vertical flip, then re-render. Flips are now
; tracked state (not baked into the bitmap), so they compose cleanly with
; rotation and region adjustments in any order.
FlipSnip(Hwnd, axis) {
    global guiSnips
    if !guiSnips.Has(Hwnd)
        return
    snip := guiSnips[Hwnd]
    if (axis = 'FlipV')
        snip.FlipV := !snip.FlipV
    else
        snip.FlipH := !snip.FlipH
    RenderSnip(snip)
}

; Rotate a snip by a signed number of degrees (cumulative). Menu 90/180/270
; items route here; they now ADD to the tracked angle instead of baking, so a
; menu rotate after a fine (Alt+arrow) rotate keeps the fine angle.
RotateSnip(Hwnd, deltaDeg) {
    global guiSnips
    if !guiSnips.Has(Hwnd)
        return
    snip := guiSnips[Hwnd]
    snip.Angle := Mod(snip.Angle + deltaDeg + 360, 360)
    RenderSnip(snip)
}

; Snap the active snip to the next multiple of 30° in the given direction.
; dir=+1 for CW, dir=-1 for CCW.  Always jumps to the next increment
; regardless of current angle, so e.g. 3°→CW snaps to 30°, 87°→CW to 90°.
SnapSnipAngle(dir) {
    global guiSnips
    hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    cur := guiSnips[hwnd].Angle
    if (dir > 0)
        target := Mod(Floor(cur / 30) * 30 + 30, 360)
    else
        target := Mod(Ceil(cur / 30) * 30 - 30 + 360, 360)
    ; Compute delta and route through AdjustSnipAngle so all the
    ; bitmap/window logic lives in one place.
    delta := target - cur
    if (delta > 180)
        delta -= 360
    else if (delta < -180)
        delta += 360
    AdjustSnipAngle(delta)
}

; Move the active snip by dx/dy physical pixels.
NudgeSnip(dx, dy, hwnd := 0) {
    if !hwnd
        hwnd := WinGetID('A')
    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', hwnd, 'Ptr', rect)
    x := NumGet(rect, 0, 'Int') + dx
    y := NumGet(rect, 4, 'Int') + dy
    DllCall('SetWindowPos', 'Ptr', hwnd, 'Ptr', 0,
            'Int', x, 'Int', y, 'Int', 0, 'Int', 0,
            'UInt', 0x0015)   ; SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
}

; Display the hotkey cheat sheet.  Closes on Escape or clicking OK.
ShowHelp() {
    global HelpText
    static hGui := 0
    if hGui && WinExist('ahk_id ' hGui) {
        WinActivate('ahk_id ' hGui)
        return
    }
    g := Gui('+AlwaysOnTop +ToolWindow', 'ScreenSnip — Help')
    g.SetFont('s10', 'Courier New')
    g.Add('Edit', 'r39 w550 ReadOnly -E0x200 -VScroll', HelpText)
    g.SetFont('s9', 'Segoe UI')
    btn := g.Add('Button', 'xm w80 Default', 'OK')
    btn.OnEvent('Click', (*) => g.Destroy())
    g.OnEvent('Escape', (*) => g.Destroy())
    g.OnEvent('Close',  (*) => hGui := 0)
    g.Show('AutoSize')
    btn.Focus()
    hGui := g.Hwnd
}

; ==============================================================================
; CONTEXT MENU
; ==============================================================================

; Bridge for the directional context-menu items. Bound with a function ref
; (NudgeSnip / PanSnipRegion / ResizeSnipRegion) and a dx/dy; supplies the
; right-clicked snip from SnipMenu._targetHwnd. Declared global here because
; SnipMenu is a plain global (not super-global), so a lambda couldn't see it.
SnipAdjustFromMenu(fn, dx, dy, *) {
    global SnipMenu
    fn(dx, dy, SnipMenu._targetHwnd)
}

SnipMenu_Handler(ItemName, ItemPos, *) {
    global SnipMenu
    TargetHwnd := SnipMenu._targetHwnd
    ; Menu labels may carry a right-aligned "`taccelerator" hint — match on the
    ; base label only so those items still dispatch correctly.
    base := StrSplit(ItemName, "`t")[1]
    switch base {
        case 'Copy to Clipboard':       SnipToClipboard(TargetHwnd)
        case 'Copy Text (Windows)':     SnipOcrWindowsText(TargetHwnd)
        case 'Copy Text (PaddleOCR)':   SnipOcrPaddleText(TargetHwnd)
        case 'Copy Table (PaddleOCR)':  SnipOcrPaddleTable(TargetHwnd)
        case 'Rotate 90° CW':           RotateSnip(TargetHwnd, +90)
        case 'Rotate 180°':             RotateSnip(TargetHwnd, 180)
        case 'Rotate 90° CCW':          RotateSnip(TargetHwnd, -90)
        case 'Flip Horizontal (L/R)':   FlipSnip(TargetHwnd, 'FlipH')
        case 'Flip Vertical (U/D)':     FlipSnip(TargetHwnd, 'FlipV')
        case 'Border':                  ToggleSnipBorder(TargetHwnd)
        case 'Help':                    ShowHelp()
        case 'Close This Snip':         CloseSnip(TargetHwnd)
        case 'Close All Snips':         CloseAllSnips()
    }
}

; ==============================================================================
; WM MESSAGE HANDLERS
; ==============================================================================

WM_MOUSEMOVE(wParam, lParam, msg, hwnd) {
    ; Keep the selection overlay from stealing keyboard focus
    if WinGetTitle('ahk_id ' hwnd) = 'SnipperSelect'
        WinActivate('ahk_id ' A_ScriptHwnd)
}

WM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    global guiSnips
    ; Allow dragging any snip window by its client area
    if guiSnips.Has(hwnd)
        PostMessage(0xA1, 2, , hwnd)
    ; Also allow dragging by clicking a child control (Picture, border Text)
    else {
        parent := DllCall("GetParent", "Ptr", hwnd, "Ptr")
        if guiSnips.Has(parent)
            PostMessage(0xA1, 2, , parent)
    }
}

; Whenever a snip window repaints (focus change, drag, restore-from-minimize,
; another window overlapping it, etc.) Windows redraws BackColor as a flat
; fill, which would erase the 3D bevel. OnMessage callbacks run BEFORE the
; default paint handling, not after — so drawing the bevel directly in this
; callback gets immediately overwritten by the paint that follows. Instead,
; queue the bevel redraw on a one-shot timer so it runs once the current
; paint cycle has actually finished.
WM_PAINT_BEVEL(wParam, lParam, msg, hwnd) {
    global guiSnips, Bevel3D, Bevel3DMaxThickness, BorderThickness, BorderColor
    static lastFire := Map()
    if !Bevel3D || BorderThickness > Bevel3DMaxThickness
        return
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !snip.HasBorder
        return
    ; Only at cardinal angles — non-cardinal suppresses the border entirely.
    isCardinal := (snip.Angle = 0 || snip.Angle = 90 || snip.Angle = 180 || snip.Angle = 270)
    if !isCardinal
        return
    ; Throttle: skip if we already queued a redraw for this window very recently
    ; (rapid repaints during drags would otherwise stack up redundant timers).
    now := A_TickCount
    if (lastFire.Has(hwnd) && now - lastFire[hwnd] < 50)
        return
    lastFire[hwnd] := now
    SetTimer(() => DrawSnipBevel(snip.GuiObj, BorderColor, BorderThickness, BevelStrengthFor(hwnd), BevelDarknessFor(hwnd)), -1)
}

; WM_ACTIVATE fires on both the window gaining focus AND the one losing it.
; WM_PAINT isn't reliably sent to the window that just lost focus, so without
; this hook a snip could keep its "active" bevel strength after focus moves
; away. wParam low word: 0 = deactivated, nonzero = activated — either way
; we just need to repaint with whatever strength is now correct for hwnd.
WM_ACTIVATE_BEVEL(wParam, lParam, msg, hwnd) {
    global guiSnips, Bevel3D, Bevel3DMaxThickness, BorderThickness, BorderColor
    if !Bevel3D || BorderThickness > Bevel3DMaxThickness
        return
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !snip.HasBorder
        return
    isCardinal := (snip.Angle = 0 || snip.Angle = 90 || snip.Angle = 180 || snip.Angle = 270)
    if !isCardinal
        return
    SetTimer(() => DrawSnipBevel(snip.GuiObj, BorderColor, BorderThickness, BevelStrengthFor(hwnd), BevelDarknessFor(hwnd)), -1)
}

; Pick the bevel strength to use for a given window — full strength when
; it's the foreground (active/focused) window, weaker otherwise. This is
; how we visually distinguish the focused snip without a second color.
BevelStrengthFor(hwnd) {
    global Bevel3DStrength, Bevel3DInactiveStrength
    return (DllCall('GetForegroundWindow', 'Ptr') = hwnd)
        ? Bevel3DStrength : Bevel3DInactiveStrength
}

; Pick the darkness factor to use for a given window — 0 (no dimming) when
; active/focused, Bevel3DInactiveDarknessFactor otherwise.
BevelDarknessFor(hwnd) {
    global Bevel3DInactiveDarknessFactor
    return (DllCall('GetForegroundWindow', 'Ptr') = hwnd)
        ? 0 : Bevel3DInactiveDarknessFactor
}

; Set the border color of a snip (its Gui BackColor, visible around the
; Picture). If Bevel3D is on and the border is thin enough, also paints a
; light top/left + dark bottom/right bevel directly onto the window for a
; pseudo-3D "floating" look. No extra gui/window is created — this draws
; straight onto the snip's own client area using GDI.
SnipWinBorderColor(g, Color) {
    global Bevel3D, Bevel3DMaxThickness, BorderThickness
    g.BackColor := Color
    if (Bevel3D && BorderThickness <= Bevel3DMaxThickness)
        DrawSnipBevel(g, Color, BorderThickness, BevelStrengthFor(g.Hwnd), BevelDarknessFor(g.Hwnd))
    WinRedraw(g.Hwnd)
}

; Resolve an AHK color value (named color, bare hex, or 0x-prefixed hex)
; to a plain 0xRRGGBB integer. Covers the standard AHK GUI color names;
; falls back to treating the string as hex either way.
ColorToHex(colorVal) {
    static names := Map(
        'black', 0x000000, 'silver', 0xC0C0C0, 'gray', 0x808080, 'white', 0xFFFFFF,
        'maroon', 0x800000, 'red', 0xFF0000, 'purple', 0x800080, 'fuchsia', 0xFF00FF,
        'green', 0x008000, 'lime', 0x00FF00, 'olive', 0x808000, 'yellow', 0xFFFF00,
        'navy', 0x000080, 'blue', 0x0000FF, 'teal', 0x008080, 'aqua', 0x00FFFF)
    if (Type(colorVal) = 'Integer')
        return colorVal
    key := StrLower(Trim(colorVal))
    if names.Has(key)
        return names[key]
    ; Bare hex (no 0x prefix) or already-prefixed — Integer() handles '0x..',
    ; so prepend the prefix only when it's missing.
    return Integer(InStr(key, '0x') = 1 ? key : '0x' key)
}

; Blend a color (named, bare hex, or 0x-hex) toward white (factor > 0) or
; black (factor < 0). factor is -1.0..1.0 — e.g. 0.35 lightens 35% toward white.
BlendColor(colorVal, factor) {
    c := ColorToHex(colorVal)
    r := (c >> 16) & 0xFF,  g := (c >> 8) & 0xFF,  b := c & 0xFF
    target := (factor >= 0) ? 255 : 0
    f := Abs(factor)
    r := Round(r + (target - r) * f)
    g := Round(g + (target - g) * f)
    b := Round(b + (target - b) * f)
    return (r << 16) | (g << 8) | b
}

; Draw a light top/left + dark bottom/right bevel frame directly onto the
; snip window's client area, on top of the flat BackColor fill that's
; already there. thickness is in logical px (BorderThickness); this scales
; to physical px the same way the rest of the snip geometry does.
; darknessFactor (0.0-1.0, default 0) additionally darkens BOTH the light
; and dark edge colors by that fraction — used to dim an inactive snip's
; bevel without changing its contrast/shape (see Bevel3DInactiveDarknessFactor).
DrawSnipBevel(g, baseColorVal, thickness, strength, darknessFactor := 0) {
    ; Defensive guard: the gui may have been destroyed between when this
    ; call was queued (e.g. via SetTimer) and when it actually runs — most
    ; commonly during "Close All Snips". g.Hwnd throws if the window is gone.
    try
        hwnd := g.Hwnd
    catch
        return
    if !DllCall('IsWindow', 'Ptr', hwnd, 'Int')
        return
    scale := A_ScreenDPI / 96
    t := Max(1, Round(thickness * scale))

    rect := Buffer(16, 0)
    DllCall('GetClientRect', 'Ptr', hwnd, 'Ptr', rect)
    w := NumGet(rect, 8, 'Int'),  h := NumGet(rect, 12, 'Int')

    lightColor := BlendColor(baseColorVal,  strength)
    darkColor  := BlendColor(baseColorVal, -strength)
    if (darknessFactor > 0) {
        lightColor := BlendColor(lightColor, -darknessFactor)
        darkColor  := BlendColor(darkColor,  -darknessFactor)
    }

    hdc := DllCall('GetDC', 'Ptr', hwnd, 'Ptr')

    ; Top + left edges, lightened
    hBrushLight := DllCall('CreateSolidBrush', 'UInt', _RGBSwap(lightColor), 'Ptr')
    rcTop  := Buffer(16, 0)
    NumPut('Int', 0, 'Int', 0, 'Int', w, 'Int', t, rcTop)
    DllCall('FillRect', 'Ptr', hdc, 'Ptr', rcTop, 'Ptr', hBrushLight)
    rcLeft := Buffer(16, 0)
    NumPut('Int', 0, 'Int', 0, 'Int', t, 'Int', h, rcLeft)
    DllCall('FillRect', 'Ptr', hdc, 'Ptr', rcLeft, 'Ptr', hBrushLight)
    DllCall('DeleteObject', 'Ptr', hBrushLight)

    ; Bottom + right edges, darkened
    hBrushDark := DllCall('CreateSolidBrush', 'UInt', _RGBSwap(darkColor), 'Ptr')
    rcBottom := Buffer(16, 0)
    NumPut('Int', 0, 'Int', h - t, 'Int', w, 'Int', h, rcBottom)
    DllCall('FillRect', 'Ptr', hdc, 'Ptr', rcBottom, 'Ptr', hBrushDark)
    rcRight := Buffer(16, 0)
    NumPut('Int', w - t, 'Int', 0, 'Int', w, 'Int', h, rcRight)
    DllCall('FillRect', 'Ptr', hdc, 'Ptr', rcRight, 'Ptr', hBrushDark)
    DllCall('DeleteObject', 'Ptr', hBrushDark)

    DllCall('ReleaseDC', 'Ptr', hwnd, 'Ptr', hdc)
}

; Win32 GDI color refs are 0xBBGGRR, not 0xRRGGBB — swap byte order.
_RGBSwap(colorHex) {
    c := Integer(colorHex)
    r := (c >> 16) & 0xFF,  g := (c >> 8) & 0xFF,  b := c & 0xFF
    return (b << 16) | (g << 8) | r
}

; Toggle border on/off for a single snip at runtime.
; Resizes the window in physical pixels to add/remove the border margin.
ToggleSnipBorder(Hwnd) {
    global guiSnips, SnipMenu, BorderThickness, BorderColor
    if !guiSnips.Has(Hwnd)
        return
    snip := guiSnips[Hwnd]
    g    := snip.GuiObj

    scale      := A_ScreenDPI / 96
    physBorder := Round(BorderThickness * scale)

    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', Hwnd, 'Ptr', rect)
    curL := NumGet(rect,  0, 'Int'), curT := NumGet(rect,  4, 'Int')
    curR := NumGet(rect,  8, 'Int'), curB := NumGet(rect, 12, 'Int')
    curW := curR - curL,  curH := curB - curT

    if snip.HasBorder {
        ; Turn border OFF — shrink window, move picture to 0,0, go transparent
        snip.HasBorder := false
        SnipMenu.UnCheck('Border')
        g.BackColor := Format('0x{:06X}', snip.TransColor)
        g.Pic.Move(0, 0)
        newW := curW - physBorder * 2
        newH := curH - physBorder * 2
        newX := curL + physBorder
        newY := curT + physBorder
    } else {
        ; Turn border ON — expand window, inset picture, set border color
        snip.HasBorder := true
        SnipMenu.Check('Border')
        g.BackColor := BorderColor
        g.Pic.Move(BorderThickness, BorderThickness)
        newW := curW + physBorder * 2
        newH := curH + physBorder * 2
        newX := curL - physBorder
        newY := curT - physBorder
    }

    DllCall('SetWindowPos', 'Ptr', Hwnd, 'Ptr', 0,
            'Int', newX, 'Int', newY, 'Int', newW, 'Int', newH,
            'UInt', 0x0014)   ; SWP_NOZORDER | SWP_NOACTIVATE
    SetLayeredWinAttribs(Hwnd, snip.TransColor, snip.Alpha)
    global Bevel3D, Bevel3DMaxThickness
    if (snip.HasBorder && Bevel3D && BorderThickness <= Bevel3DMaxThickness)
        DrawSnipBevel(g, BorderColor, BorderThickness, BevelStrengthFor(Hwnd), BevelDarknessFor(Hwnd))
    WinRedraw(Hwnd)
}

; Context-menu handler, wired to each snip's GUI via OnEvent('ContextMenu')
; in SnipArea. Fires on right-button-UP within the snip window (or any of its
; child controls), so the menu opens on a normal click without needing the
; button held, and the WinActivate runs with foreground rights granted by the
; click itself — both the reasons the old global ~RButton hotkey was flaky.
; Signature: (GuiObj, Ctrl, Item, IsRightClick, X, Y) — we only need the Gui.
ShowSnipMenu(GuiObj, *) {
    global guiSnips, SnipMenu
    Hwnd := GuiObj.Hwnd
    if !guiSnips.Has(Hwnd)
        return
    SnipMenu._targetHwnd := Hwnd
    ; Sync Border checkmark to this snip's individual state
    guiSnips[Hwnd].HasBorder
        ? SnipMenu.Check('Border')
        : SnipMenu.UnCheck('Border')
    WinActivate('ahk_id ' Hwnd)
    SnipMenu.Show()
}

; ==============================================================================
; SelectScreenRegion  (from Fanatic Guru — lightly trimmed)
; ==============================================================================

SelectScreenRegion(Key, Color := 'Lime', Transparent := 80) {
    static guiSSR
    if !IsSet(guiSSR) {
        guiSSR := Gui('+AlwaysOnTop -Caption +ToolWindow +LastFound -DPIScale', 'SnipperSelect')
        guiSSR.MarginX := 0, guiSSR.MarginY := 0
        guiSSR.BackColor := 1
        WinSetTransColor(1, guiSSR)
        guiSSR.Background := guiSSR.Add('Text', 'w' A_ScreenWidth ' h' A_ScreenHeight ' Background' Color)
        global InfoFontSize
        guiSSR.InfoW := guiSSR.Add('Text', 'Background0xDDDDDD w55 h22 Center', '')
        guiSSR.InfoW.SetFont('s' InfoFontSize ' bold c101010', 'Courier New')
        guiSSR.InfoH := guiSSR.Add('Text', 'Background0xDDDDDD w55 h22 Right', '')
        guiSSR.InfoH.SetFont('s' InfoFontSize ' bold c101010', 'Courier New')
    }

    CoordMode('Mouse', 'Screen')
    MouseGetPos(&sX, &sY)
    guiSSR.Show('NA x' sX ' y' sY ' w10 h10')

    ; Re-apply the overlay's alpha transparency every time, AFTER Show().
    ; Showing/hiding a layered parent window (guiSSR itself is layered via
    ; WinSetTransColor) can reset a layered CHILD control's own alpha
    ; attributes — so setting this before Show() risks having it cleared
    ; by the Show() call itself. Setting it after is cheap and harmless if
    ; it was already correct, and self-heals the rare case where the
    ; child's layered state didn't survive the show/hide cycle.
    if InStr(A_OSVersion, '6.1')   ; Windows 7
        WinSetTransparent(Transparent, guiSSR)
    else
        WinSetTransparent(Transparent, guiSSR.Background)

    Wprev := Hprev := 0
    aborted := false
    Loop {
        ; Safety valve: Esc cancels the capture cleanly, so a snip can never
        ; get stuck on screen even if every button-release path fails.
        if GetKeyState('Escape', 'p') {
            aborted := true
            break
        }
        MouseGetPos(&eX, &eY)
        W := Abs(sX - eX), H := Abs(sY - eY)
        X := Min(sX, eX),  Y := Min(sY, eY)
        guiSSR.Move(X, Y, W, H)
        ; NOTE: previously called guiSSR.Background.Redraw() here every
        ; iteration "to keep the overlay painted consistently". Removed —
        ; Move() already triggers the necessary repaint, and forcing an
        ; extra redraw ~100x/sec on a layered/alpha-blended control is a
        ; likely cause of the rare "rectangle turns invisible" glitch
        ; (repeatedly hammering a layered window's compositing can
        ; occasionally desync its alpha state). If the overlay ever stops
        ; visually tracking the drag correctly, this is the first thing
        ; to revisit.

        ; Self-healing check: read back the Background control's actual
        ; current layered alpha and re-apply WinSetTransparent only if it
        ; has drifted from what it should be. WinSetTransparent's value
        ; parameter IS the raw 0-255 alpha already (not a percentage), so
        ; the expected value is just Transparent itself. This is a read
        ; (cheap) rather than a forced re-set every frame, so it shouldn't
        ; reintroduce the high-frequency-call problem the Redraw() removal
        ; was meant to fix, while still catching a mid-drag desync if one
        ; occurs.
        if DllCall('GetLayeredWindowAttributes', 'Ptr', guiSSR.Background.Hwnd
                   , 'Ptr', 0, 'UChar*', &curAlpha := 0, 'UInt*', 0)
        {
            if (curAlpha != Transparent)
                WinSetTransparent(Transparent, guiSSR.Background)
        }

        ; Show width on bottom edge (centered) and height on right edge (centered).
        ; Each control is shown/hidden independently based on its own threshold.
        if (W != Wprev || H != Hprev) {
            global InfoWHOffsetRight, InfoWHOffsetBottom, InfoFontSize, InfoWMinWidth, InfoHMinHeight
            ; Dynamic control width: font-scaled px per digit + 12px padding.
            ; Courier New bold: ~0.72px per pt per digit is a reliable approximation.
            pxPerDigit := Round(InfoFontSize * 0.72)
            wDigits  := StrLen(String(W))
            hDigits  := StrLen(String(H))
            ctrlWofW := Max(30, wDigits * pxPerDigit + 12)   ; width of the InfoW control
            ctrlWofH := Max(30, hDigits * pxPerDigit + 12)   ; width of the InfoH control
            if (W > InfoWMinWidth) {
                guiSSR.InfoW.Text := W
                guiSSR.InfoW.Move(W // 2 - ctrlWofW // 2, H - InfoWHOffsetBottom, ctrlWofW, 22)
                guiSSR.InfoW.Visible := true
            } else {
                guiSSR.InfoW.Visible := false
            }
            if (H > InfoHMinHeight) {
                guiSSR.InfoH.Text := H
                guiSSR.InfoH.Move(W - InfoWHOffsetRight, H // 2 - 11, ctrlWofH, 22)
                guiSSR.InfoH.Visible := true
            } else {
                guiSSR.InfoH.Visible := false
            }
            Wprev := W, Hprev := H
        }
        Sleep 10
    ; Exit when the button is released. This reads AHK's hooked physical state.
    ; If the release happens over an ELEVATED window while ScreenSnip is not
    ; elevated, Windows UIPI hides that event from the hook and this test can get
    ; stuck "down" — the Esc check at the top of the loop is the clean escape
    ; hatch for that case. Running ScreenSnip elevated avoids the stuck state.
    ; (GetAsyncKeyState is NOT a usable fallback here: this hotkey suppresses the
    ; RButton-down, so the OS async state reads "up" the whole time.)
    } Until !GetKeyState(Key, 'p')

    guiSSR.GetPos(&X, &Y, &W, &H)
    guiSSR.Hide()
    guiSSR.InfoW.Visible := false
    guiSSR.InfoH.Visible := false
    ; On Esc-abort, return a zero-size area so the caller's (W>8 && H>8) guard
    ; skips snip creation.
    if aborted
        return { X: X, Y: Y, W: 0, H: 0, X2: X, Y2: Y }
    return { X: X, Y: Y, W: W, H: H, X2: X+W, Y2: Y+H }
}

; ==============================================================================
; GDIp CLASS  (from Fanatic Guru — unchanged)
; ==============================================================================

#DllLoad 'GdiPlus'
Class GDIp {

    Static Startup() {
        if this.HasProp("Token")
            return
        input := Buffer((A_PtrSize = 8) ? 24 : 16, 0)
        NumPut("UInt", 1, input)
        DllCall("gdiplus\GdiplusStartup", "UPtr*", &pToken := 0, "UPtr", input.ptr, "UPtr", 0)
        this.Token := pToken
    }

    Static Shutdown() {
        if this.HasProp("Token")
            DllCall("Gdiplus\GdiplusShutdown", "UPtr", this.DeleteProp("Token"))
    }

    Static BitmapFromScreen(Area) {
        chdc := this.CreateCompatibleDC()
        hbm  := this.CreateDIBSection(Area.W, Area.H, chdc)
        obm  := this.SelectObject(chdc, hbm)
        hhdc := this.GetDC()
        this.BitBlt(chdc, 0, 0, Area.W, Area.H, hhdc, Area.X, Area.Y)
        this.ReleaseDC(hhdc)
        pBitmap := this.CreateBitmapFromHBITMAP(hbm)
        this.SelectObject(chdc, obm)
        this.DeleteObject(hbm)
        this.DeleteDC(hhdc)
        this.DeleteDC(chdc)
        return pBitmap
    }

    Static CreateCompatibleDC(hdc := 0) => DllCall("CreateCompatibleDC", "UPtr", hdc)

    Static CreateDIBSection(w, h, hdc := "", bpp := 32, &ppvBits := 0, Usage := 0, hSection := 0, Offset := 0) {
        hdc2 := hdc ? hdc : this.GetDC()
        bi := Buffer(40, 0)
        NumPut("UInt", 40, bi, 0)
        NumPut("UInt", w,  bi, 4)
        NumPut("UInt", h,  bi, 8)
        NumPut("UShort", 1,   bi, 12)
        NumPut("UShort", bpp, bi, 14)
        NumPut("UInt", 0, bi, 16)
        hbm := DllCall("CreateDIBSection", "UPtr", hdc2, "UPtr", bi.ptr,
                        "uint", Usage, "UPtr*", &ppvBits, "UPtr", hSection, "uint", Offset, "UPtr")
        if !hdc
            this.ReleaseDC(hdc2)
        return hbm
    }

    Static SelectObject(hdc, hgdiobj)         => DllCall("SelectObject", "UPtr", hdc, "UPtr", hgdiobj)
    Static DeleteObject(hObject)              => DllCall("DeleteObject", "UPtr", hObject)
    Static DeleteDC(hdc)                      => DllCall("DeleteDC", "UPtr", hdc)
    Static GetDC(hwnd := 0)                   => DllCall("GetDC", "UPtr", hwnd)
    Static ReleaseDC(hdc, hwnd := 0)          => DllCall("ReleaseDC", "UPtr", hwnd, "UPtr", hdc)

    Static BitBlt(ddc, dx, dy, dw, dh, sdc, sx, sy, raster := "") {
        return DllCall("gdi32\BitBlt", "UPtr", ddc,
                       "int", dx, "int", dy, "int", dw, "int", dh,
                       "UPtr", sdc, "int", sx, "int", sy,
                       "uint", raster ? raster : 0x00CC0020)
    }

    Static CreateBitmapFromHBITMAP(hBitmap, hPalette := 0) {
        DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "UPtr", hBitmap, "UPtr", hPalette, "UPtr*", &pBitmap := 0)
        return pBitmap
    }

    Static CreateHBITMAPFromBitmap(pBitmap, Background := 0xffffffff) {
        DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "UPtr", pBitmap, "UPtr*", &hBitmap := 0, "int", Background)
        return hBitmap
    }

    Static DisposeImage(pBitmap) => DllCall("gdiplus\GdipDisposeImage", "UPtr", pBitmap)

    ; Clone a rectangular sub-area of a bitmap into a new 32bppARGB bitmap.
    ; Used to crop the frozen master snapshot down to the current capture rect.
    ; Returns 0 on failure (e.g. rect out of bounds) so callers can bail safely.
    Static CloneBitmapArea(pBitmap, x, y, w, h) {
        pClone := 0
        ; 0x21808 = PixelFormat32bppARGB (matches the master's format).
        DllCall("gdiplus\GdipCloneBitmapAreaI",
                "Int", x, "Int", y, "Int", w, "Int", h,
                "Int", 0x21808,
                "UPtr", pBitmap, "UPtr*", &pClone)
        return pClone
    }

    Static SetBitmapToClipboard(pBitmap) {
        off1 := A_PtrSize = 8 ? 52 : 44
        off2 := A_PtrSize = 8 ? 32 : 24
        pid  := DllCall("GetCurrentProcessId", "uint")
        hwnd := WinExist("ahk_pid " pid)
        if !DllCall("OpenClipboard", "UPtr", hwnd)
            return -1
        hBitmap := this.CreateHBITMAPFromBitmap(pBitmap, 0)
        if !hBitmap {
            DllCall("CloseClipboard")
            return -3
        }
        if !DllCall("EmptyClipboard") {
            this.DeleteObject(hBitmap)
            DllCall("CloseClipboard")
            return -2
        }
        oi := Buffer((A_PtrSize = 8) ? 104 : 84, 0)
        DllCall("GetObject", "UPtr", hBitmap, "int", oi.size, "UPtr", oi.ptr)
        hdib := DllCall("GlobalAlloc", "uint", 2, "UPtr", 40 + NumGet(oi, off1, "UInt"), "UPtr")
        pdib := DllCall("GlobalLock", "UPtr", hdib, "UPtr")
        DllCall("RtlMoveMemory", "UPtr", pdib,      "UPtr", oi.ptr + off2,                     "UPtr", 40)
        DllCall("RtlMoveMemory", "UPtr", pdib + 40, "UPtr", NumGet(oi, off2 - A_PtrSize, "UPtr"), "UPtr", NumGet(oi, off1, "UInt"))
        DllCall("GlobalUnlock", "UPtr", hdib)
        this.DeleteObject(hBitmap)
        r3 := DllCall("SetClipboardData", "uint", 8, "UPtr", hdib)
        DllCall("CloseClipboard")
        DllCall("GlobalFree", "UPtr", hdib)
        return r3 ? 0 : -4
    }

    Static SetHBITMAPToClipboard(hBitmap) {
        off1 := A_PtrSize = 8 ? 52 : 44
        off2 := A_PtrSize = 8 ? 32 : 24
        pid  := DllCall("GetCurrentProcessId", "uint")
        hwnd := WinExist("ahk_pid " pid)
        if !DllCall("OpenClipboard", "UPtr", hwnd)
            return -1
        if !DllCall("EmptyClipboard") {
            this.DeleteObject(hBitmap)
            DllCall("CloseClipboard")
            return -2
        }
        oi := Buffer((A_PtrSize = 8) ? 104 : 84, 0)
        DllCall("GetObject", "UPtr", hBitmap, "int", oi.size, "UPtr", oi.ptr)
        hdib := DllCall("GlobalAlloc", "uint", 2, "UPtr", 40 + NumGet(oi, off1, "UInt"), "UPtr")
        pdib := DllCall("GlobalLock", "UPtr", hdib, "UPtr")
        DllCall("RtlMoveMemory", "UPtr", pdib,      "UPtr", oi.ptr + off2,                     "UPtr", 40)
        DllCall("RtlMoveMemory", "UPtr", pdib + 40, "UPtr", NumGet(oi, off2 - A_PtrSize, "UPtr"), "UPtr", NumGet(oi, off1, "UInt"))
        DllCall("GlobalUnlock", "UPtr", hdib)
        r3 := DllCall("SetClipboardData", "uint", 8, "UPtr", hdib)
        DllCall("CloseClipboard")
        DllCall("GlobalFree", "UPtr", hdib)
        return r3 ? 0 : -4
    }

    ; Rotate pBitmap by angleDeg degrees, returning a new bounding-box sized
    ; bitmap with the transparent color key filled into the corners so they
    ; disappear via SetLayeredWinAttribs on the snip window.
    ; The canvas is padded by 1px on each side so antialiased edge pixels
    ; blend inward into the image rather than outward into the trans color,
    ; preventing a 1px color fringe that would otherwise appear.
    Static RotateBitmap(pBitmap, angleDeg, transColor := 0xFF00FF) {
        ; Get original dimensions
        DllCall('gdiplus\GdipGetImageWidth',  'UPtr', pBitmap, 'UInt*', &origW := 0)
        DllCall('gdiplus\GdipGetImageHeight', 'UPtr', pBitmap, 'UInt*', &origH := 0)

        ; Bounding box of the rotated rectangle
        rad  := angleDeg * 3.14159265358979 / 180
        sinA := Abs(Sin(rad)), cosA := Abs(Cos(rad))
        newW := Round(origW * cosA + origH * sinA)
        newH := Round(origW * sinA + origH * cosA)

        ; Create a new blank bitmap — use RGB (no alpha) so the fill color
        ; is preserved exactly when converted to HBITMAP for display.
        DllCall('gdiplus\GdipCreateBitmapFromScan0',
            'Int', newW, 'Int', newH, 'Int', 0, 'Int', 0x21808, 'Ptr', 0, 'UPtr*', &pNew := 0)

        ; Get graphics context for the new bitmap
        DllCall('gdiplus\GdipGetImageGraphicsContext', 'UPtr', pNew, 'UPtr*', &pGfx := 0)

        ; Fill background with the trans color so antialiased edge pixels
        ; blend toward it rather than leaving a hard, mismatched edge.
        fillColor := 0xFF000000 | transColor   ; GDI+ ARGB: full opacity + RGB
        DllCall('gdiplus\GdipCreateSolidFill', 'UInt', fillColor, 'UPtr*', &pBrush := 0)
        DllCall('gdiplus\GdipFillRectangleI', 'UPtr', pGfx, 'UPtr', pBrush,
            'Int', 0, 'Int', 0, 'Int', newW, 'Int', newH)
        DllCall('gdiplus\GdipDeleteBrush', 'UPtr', pBrush)

        ; Set interpolation to high quality
        DllCall('gdiplus\GdipSetInterpolationMode', 'UPtr', pGfx, 'Int', 7)
        DllCall('gdiplus\GdipSetSmoothingMode',     'UPtr', pGfx, 'Int', 4)
        DllCall('gdiplus\GdipSetPixelOffsetMode',   'UPtr', pGfx, 'Int', 2)

        ; Translate to center, rotate, translate back so image is centered
        DllCall('gdiplus\GdipTranslateWorldTransform', 'UPtr', pGfx,
            'Float', newW / 2, 'Float', newH / 2, 'Int', 0)
        DllCall('gdiplus\GdipRotateWorldTransform', 'UPtr', pGfx, 'Float', angleDeg + 0.0, 'Int', 0)
        DllCall('gdiplus\GdipTranslateWorldTransform', 'UPtr', pGfx,
            'Float', -origW / 2, 'Float', -origH / 2, 'Int', 0)

        ; Draw the original bitmap onto the rotated canvas
        DllCall('gdiplus\GdipDrawImageI', 'UPtr', pGfx, 'UPtr', pBitmap, 'Int', 0, 'Int', 0)

        ; Set DPI to match screen so display is 1:1
        dpi := A_ScreenDPI + 0.0
        DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', pNew, 'Float', dpi, 'Float', dpi)

        DllCall('gdiplus\GdipDeleteGraphics', 'UPtr', pGfx)
        return pNew
    }

    ; Apply a rotate/flip transform and return a new pBitmap.
    ; GDI+ RotateFlipType enum:
    ;   0=None 1=90CW 2=180 3=270CW(=90CCW) 4=FlipH 5=FlipH+90CW 6=FlipH+180(=FlipV) 7=FlipH+270CW
    Static TransformBitmap(pBitmap, Transform) {
        DllCall('gdiplus\GdipCloneImage', 'UPtr', pBitmap, 'UPtr*', &pNew := 0)
        rotateFlipType := 0
        switch Transform {
            case 'Rotate90CW':  rotateFlipType := 1
            case 'Rotate180':   rotateFlipType := 2
            case 'Rotate90CCW': rotateFlipType := 3
            case 'FlipH':       rotateFlipType := 4
            case 'FlipV':       rotateFlipType := 6
        }
        DllCall('gdiplus\GdipImageRotateFlip', 'UPtr', pNew, 'Int', rotateFlipType)
        dpi := A_ScreenDPI + 0.0
        DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', pNew, 'Float', dpi, 'Float', dpi)
        return pNew
    }
}

; ── OCR add-on ────────────────────────────────────────────────────────────────
; Provides SnipOcrWindowsText / SnipOcrPaddleText / SnipOcrPaddleTable, called
; from SnipMenu_Handler above.  Contains no top-level executable code, so it is
; safe to include here at the end of the file.
#Include SnipOCR.ahk
