#Requires AutoHotkey v2
#Warn All, Off
#SingleInstance Force
DetectHiddenWindows true
SetWinDelay(0)
;
;               ScreenSnip.ahk
;
; Github https://github.com/kunkel321/ScreenSnip
; AHK Forum https://www.autohotkey.com/boards/viewtopic.php?f=83&t=140802
;
; Based on Snipper by FanaticGuru 
; https://www.autohotkey.com/boards/viewtopic.php?f=83&t=115622
;
; Adapted by kunkel321 / Claude
; Version date: 7-27-2026
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
  --------------------------------------------------
  CAPTURING
  Ctrl + RButton drag          Capture a region
  Ctrl + Shift + RButton drag  Capture + copy to clipboard
  Shift + PrintScreen          Show / hide all snips

  ON A SNIP  (mouse — click a snip first)
  Left-drag                    Move the window
  Right-drag                   Pan the image within the frame
  Alt + drag edge / corner     Resize (trim / grow the capture)
  Right-click                  Context menu
  Esc                          Close this snip

  EXPORT
  Ctrl + C                     Copy image to clipboard
  Ctrl + S                     Save image  (PNG / JPG / BMP)
  Menu > OCR > Text (Windows)  Fast text grab, no setup
  Menu > OCR > Text (Paddle)   Slower, more accurate
  Menu > OCR > Table (Paddle)  Rebuilds a grid for Excel

  ADJUST CAPTURE REGION  (re-crops the frozen snapshot)
  Ctrl + Alt + Arrow           Pan  ± 1 px    (or right-drag)
  Ctrl + Shift + Alt + Arrow   Pan  ± 10 px
  Win + Alt + Arrow            Resize ± 1 px  (or Alt-drag an edge)
  Win + Shift + Alt + Arrow    Resize ± 10 px (grow = Right / Down)
  Range is limited by CaptureAdjustMargin (top of script).

  ROTATE  (turns the whole snip, frame and all)
  Alt + Left / Right           Rotate ± 1°
  Shift + Alt + Left / Right   Snap to next 30° (CW / CCW)

  STRAIGHTEN  (deskew — tilts the image inside a fixed frame)
  Alt + , / .                  Straighten ± 1°  (CCW / CW)
  Shift + Alt + , / .          Straighten ± 0.5°  (fine)
  Squares up a skewed table before OCR: straighten,
  then Alt-drag an edge to trim the exposed corners.

  FLIP
  Shift + Left / Right         Flip horizontal
  Shift + Up / Down            Flip vertical

  MOVE WINDOW  (the floating window, not the capture)
  Ctrl + Arrow                 Move ± 1 px
  Ctrl + Shift + Arrow         Move ± 10 px

  TRANSPARENCY
  Alt + Up / Down              Adjust ± 25
  Alt + Wheel                  Adjust ± 10
  --------------------------------------------------
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

; Right-drag pan sensitivity: how many pixels of right-mouse drag map to ONE
; pixel of region pan (hand-tool style — the image follows the cursor). Higher
; = finer/slower, which suits nudging an edge into place; 1 = 1:1 tracking.
; The fractional remainder is carried between frames, so even a slow drag moves
; smoothly instead of stair-stepping. (The first few px of any drag are a dead
; zone that distinguishes a pan from a plain right-click; see PanClickSlop.)
PanDragDivisor := 3
; Total right-drag travel (screen px) below which the gesture is treated as a
; right-CLICK and opens the context menu instead of panning.
PanClickSlop := 5

; Edge-drag resize: hold Alt and drag a snip's edge/corner to grow or shrink the
; capture region (the opposite edge stays put). EdgeGrabZone is how far inward,
; in px, the grabbable band reaches from each edge; it's automatically widened to
; at least the border thickness so a thick border is still fully grabbable. Only
; active on upright snips (Angle 0) — a rotated snip's edges don't map cleanly to
; the capture rectangle, so it's suppressed there (same rule as the border).
EdgeGrabZone := 6

; Straighten (deskew) — rotate the IMAGE inside a fixed rectangular frame,
; e.g. to square up a skewed table before OCR. Unlike Rotation (which turns
; the whole snip, frame and all), Straighten leaves the frame axis-aligned
; and only tilts the content within it; you then trim the exposed corners
; with a Resize. The content pivots about the frozen snapshot's CENTER, so
; panning slides the frame over one stable rotated image (no swirl). The
; surrounding CaptureAdjustMargin supplies the extra pixels the tilt pulls
; in — a larger margin allows a larger clean straighten before the corners
; run past the snapshot edge.
StraightenStep     := 1      ; degrees per Alt+, / Alt+.
StraightenFineStep := 0.5    ; degrees per Shift+Alt+, / Shift+Alt+.
StraightenMaxAngle := 15     ; hard clamp (the practical limit is the margin)

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

; Drop shadow: cast a soft translucent shadow to the bottom/right of each snip.
; This is a separate, click-through window that sits just behind the snip and is
; kept glued to it via WM_WINDOWPOSCHANGED — the snip window itself is never
; touched. It's painted per-pixel with UpdateLayeredWindow (real feathered
; alpha); ShadowBlur softens the edges via a downscale/upscale pass. Suppressed
; (hidden) at non-cardinal / skewed angles (a rectangle wouldn't match a tilted
; snip), and whenever the snip isn't 100% opaque (a shadow behind a see-through
; snip looks wrong). true = show shadow (default for new snips), false = none.
; Toggle per-snip at runtime via the right-click "Shadow" menu item.
ShowSnipShadow := true
; Shadow color as a hex value, 0xRRGGBB (e.g. 0x000000 black, 0x203040 slate).
; Hex only here — the GDI+ fill needs a numeric RGB, not an AHK colour name.
ShadowColor := "0x000000"
; How far, in logical px, the shadow is offset down/right (DPI-scaled like the
; rest of the snip geometry). Keep this >= ShadowBlur for a clean bottom/right
; drop; if blur exceeds offset you get a soft all-around halo/glow instead.
ShadowOffset := 7
; Offset used when the snip ISN'T the focused window. Making it smaller than
; ShadowOffset lets an inactive snip cast a shorter shadow (reads as sitting
; closer to the desktop), so the focused snip visually lifts forward — the same
; trick the Bevel3D active/inactive strengths use. Set equal to ShadowOffset for
; no active/inactive difference.
ShadowOffsetInactive := 4
; Edge softness in logical px. 0 = crisp rectangle; 5-8 = a gentle feathered
; drop shadow; larger = softer/wider. Softening is done with plain GDI+ bilinear
; scaling (no effects API, no machine code), so it works everywhere.
ShadowBlur := 6
; Peak shadow opacity at the core, 0 (invisible) - 255 (solid). The feather fades
; below this. ~90-120 ≈ 35-47%, which reads as a shadow over most backdrops.
ShadowAlpha := 105


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

; Master switch for the on-screen dimension (W × H) labels. Set to false to
; disable BOTH the capture-time labels (shown while Ctrl+RButton dragging) and
; the post-capture resize labels (shown while Alt-dragging a snip's edge).
ShowDimensionLabels := true

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
    try OnMessage(0x0047, WM_WINDOWPOSCHANGED_SHADOW, 0)
    try OnMessage(0x0006, WM_ACTIVATE_SHADOW, 0)
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
SnipMenu.Add('Save Image As…`tCtrl+S', SnipMenu_Handler)

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

; Straighten (deskew) the image WITHIN a fixed frame — see StraightenSnip.
StraightenMenu := Menu()
StraightenMenu.Add('Straighten CW`tAlt+.',  SnipMenu_Handler)
StraightenMenu.Add('Straighten CCW`tAlt+,', SnipMenu_Handler)
StraightenMenu.Add('Reset Straighten',      SnipMenu_Handler)
StraightenMenu.Add('')
StraightenMenu.Add('Hold Shift → ±0.5° fine', noop)
StraightenMenu.Disable('Hold Shift → ±0.5° fine')
SnipMenu.Add('Straighten', StraightenMenu)

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
SnipMenu.Add('Shadow',          SnipMenu_Handler)   ; checkable toggle

SnipMenu.Add('')
SnipMenu.Add('Close This Snip`tEsc', SnipMenu_Handler)
SnipMenu.Add('Close All Snips',      SnipMenu_Handler)
SnipMenu.Add('')
SnipMenu.Add('Help`tF1',        SnipMenu_Handler)

; Initialise the Border menu item to reflect the default ShowSnipBorder setting
if ShowSnipBorder
    SnipMenu.Check('Border')
; Same for the Shadow item and its default
if ShowSnipShadow
    SnipMenu.Check('Shadow')

; ── WM handlers (must be registered before hotkeys fire) ──────────────────────
OnMessage(0x200, WM_MOUSEMOVE)    ; keep selection overlay from stealing focus
OnMessage(0x201, WM_LBUTTONDOWN)  ; allow dragging snip windows
OnMessage(0x000F, WM_PAINT_BEVEL) ; re-paint the 3D bevel after any repaint
OnMessage(0x0006, WM_ACTIVATE_BEVEL) ; refresh bevel strength on focus change
OnMessage(0x0020, WM_SETCURSOR_RESIZE) ; Alt-hover over an edge → resize cursor
OnMessage(0x0047, WM_WINDOWPOSCHANGED_SHADOW) ; keep each snip's drop shadow glued behind it
OnMessage(0x0006, WM_ACTIVATE_SHADOW) ; switch shadow offset on focus change (active/inactive depth)

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
    for Hwnd, snip in guiSnips {
        if SnipVisible {
            snip.GuiObj.Show('NA')
            ; The shadow is a SEPARATE top-level window, so it must be revealed
            ; explicitly. Route through UpdateSnipShadow so a snip that shouldn't
            ; cast one (tilted / skewed / translucent) stays correctly suppressed.
            UpdateSnipShadow(snip)
        } else {
            snip.GuiObj.Hide()
            ; Hide the snip's shadow window too, and mark it hidden so the next
            ; UpdateSnipShadow repaints + reveals it from scratch.
            if (snip.HasProp('ShadowGui') && snip.ShadowGui) {
                try snip.ShadowGui.Hide()
                snip.ShadowHidden := true
            }
        }
    }
}

#HotIf WinActive('SnipperWindow ahk_class AutoHotkeyGUI')
Esc::           CloseSnip() ; hide
F1::            ShowHelp() ; hide
^c::            SnipToClipboard() ; hide  — same as the menu's Copy to Clipboard
^s::            SaveSnipAs() ; hide       — same as the menu's Save Image As…
!Up::           AdjustSnipAlpha(+25) ; hide
!Down::         AdjustSnipAlpha(-25) ; hide
!WheelUp::      AdjustSnipAlpha(+10) ; hide
!WheelDown::    AdjustSnipAlpha(-10) ; hide
!Left::         AdjustSnipAngle(-1) ; hide
!Right::        AdjustSnipAngle(+1) ; hide
!+Left::        SnapSnipAngle(-1) ; hide
!+Right::       SnapSnipAngle(+1) ; hide
; Straighten (deskew): tilt the image inside a fixed frame. Comma = CCW (left
; key), period = CW (right key); add Shift for the finer sub-degree step.
!,::            StraightenSnip(-1) ; hide
!.::            StraightenSnip(+1) ; hide
!+,::           StraightenSnip(-1, true) ; hide
!+.::           StraightenSnip(+1, true) ; hide
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

; ── Right-drag over a snip = PAN the capture region (hand-tool) ────────────────
; Gated on the CURSOR being over a snip (not on focus), so it works even on a
; just-captured snip that isn't active yet. It's a plain CONSUMING RButton
; hotkey, so on a snip it takes over the right-drag gesture — which also means
; AC2's global DragTools right-drag is suppressed HERE (on snips) but untouched
; everywhere else. A right-CLICK with no meaningful travel still opens the menu.
#HotIf SnipUnderCursor()
RButton::       SnipRightButton() ; hide
#HotIf

; True when the mouse is over one of our snip windows. Used as the #HotIf
; context for the right-drag pan so the gesture is scoped to snips only.
SnipUnderCursor() {
    global guiSnips
    MouseGetPos(, , &win)
    return guiSnips.Has(win)
}

; Handle a right-button press over a snip: drag to pan (image follows the
; cursor, scaled by PanDragDivisor); a click (travel < PanClickSlop) opens the
; context menu. Panning uses the size-preserving fast path (RenderSnipFast /
; STM_SETIMAGE) so live dragging stays smooth instead of rebuilding the window.
SnipRightButton() {
    global guiSnips, PanDragDivisor, PanClickSlop
    MouseGetPos(&startX, &startY, &win)
    if !guiSnips.Has(win)
        return
    snip := guiSnips[win]
    WinActivate('ahk_id ' win)         ; focus so keyboard adjusts work after, and
                                        ; any stray DragTools keystrokes land here
    divisor := Max(1, PanDragDivisor)
    accX := 0.0, accY := 0.0
    lastX := startX, lastY := startY
    travel   := 0
    dragging := false
    while GetKeyState('RButton', 'P') {
        if !guiSnips.Has(win)          ; snip closed mid-gesture — bail cleanly
            return
        MouseGetPos(&cx, &cy)
        ddx := cx - lastX, ddy := cy - lastY
        if (ddx || ddy) {
            lastX := cx, lastY := cy
            travel += Abs(ddx) + Abs(ddy)
            ; Wait until we've cleared the click slop before panning, so a plain
            ; right-click never nudges the region. The slop itself isn't applied.
            if (!dragging && travel >= PanClickSlop)
                dragging := true
            if dragging {
                ; Image follows the cursor → the crop moves the OTHER way, /divisor.
                accX -= ddx / divisor
                accY -= ddy / divisor
                stepX := (accX >= 0) ? Floor(accX) : Ceil(accX)
                stepY := (accY >= 0) ? Floor(accY) : Ceil(accY)
                if (stepX || stepY) {
                    accX -= stepX, accY -= stepY
                    PanSnipRegionFast(snip, stepX, stepY)
                }
            }
        }
        Sleep 8
    }
    if !dragging                        ; it was a click, not a drag → show menu
        ShowSnipMenuFor(win)
}

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

    ; Drop shadow — an independent click-through window glued just behind this
    ; snip (see CreateSnipShadow / UpdateSnipShadow / WM_WINDOWPOSCHANGED_SHADOW).
    ; Created empty here; the first paint happens below once the snip object
    ; exists (UpdateSnipShadow needs its Angle/Skew/geometry).
    global ShowSnipShadow
    shadowGui := ShowSnipShadow ? CreateSnipShadow() : ""

    ; State model: SrcBitmap (frozen master) + Crop (which sub-rect shows) are
    ; the source of truth for CONTENT; Angle/FlipH/FlipV are a display transform
    ; layered on top. pBitmap always holds the current UPRIGHT crop (handy for
    ; OCR and re-rendering). Everything routes through RenderSnip().
    ObjMap[g.Hwnd] := { GuiObj: g, Area: Area, Alpha: 255, pBitmap: pBitmap
                      , Angle: 0, FlipH: false, FlipV: false, Skew: 0
                      , HasBorder: ShowSnipBorder, TransColor: snipTransColor
                      , SrcBitmap: SrcBitmap, SrcX: masterX, SrcY: masterY
                      , MasterW: masterW, MasterH: masterH, Crop: crop
                      , HasShadow: ShowSnipShadow, ShadowGui: shadowGui }

    if shadowGui                        ; first paint + place behind the snip
        UpdateSnipShadow(ObjMap[g.Hwnd])

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
        DestroySnipShadow(snip)
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
        DestroySnipShadow(snip)
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
    UpdateSnipShadow(snip)   ; hide/show the shadow (it's only shown at full opacity)
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

; Straighten (deskew) the active snip: tilt the CONTENT inside the fixed frame
; without changing the frame's size or orientation. dir is -1 (CCW) or +1 (CW);
; fine=true uses the smaller sub-degree step. Skew accumulates and is clamped to
; ±StraightenMaxAngle (the real ceiling is usually the snapshot margin — past it
; the pulled-in corners fill with the transparent color). The frame stays
; rectangular, so the border survives and there's no magenta rotation halo.
StraightenSnip(dir, fine := false, hwnd := 0) {
    global guiSnips, StraightenStep, StraightenFineStep, StraightenMaxAngle
    if !hwnd
        hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !(snip.HasProp('SrcBitmap') && snip.SrcBitmap)
        return
    step    := fine ? StraightenFineStep : StraightenStep
    newSkew := Max(-StraightenMaxAngle, Min(StraightenMaxAngle, snip.Skew + dir * step))
    if (newSkew = snip.Skew)                  ; already at the clamp — nothing to do
        return
    snip.Skew := newSkew
    RenderSnip(snip)
}

; Return a snip's content to level (Skew = 0), reverting to the lossless crop.
ResetStraighten(hwnd := 0) {
    global guiSnips
    if !hwnd
        hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if (snip.Skew = 0)
        return
    snip.Skew := 0
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

; Build the bitmap to SAVE — same transforms as the on-screen image (WYSIWYG),
; but for a non-cardinal rotation the corners are made genuinely TRANSPARENT
; (when wantTransparent is true, i.e. saving PNG) instead of filled with the
; magenta color key. Upright and 90/180/270 snips have no corners at all, so the
; flag is moot for them. Returns a NEW bitmap the caller must dispose.
BuildSaveBitmap(snip, wantTransparent) {
    DllCall('gdiplus\GdipCloneImage', 'UPtr', snip.pBitmap, 'UPtr*', &work := 0)
    if !work
        return 0
    if snip.FlipH
        DllCall('gdiplus\GdipImageRotateFlip', 'UPtr', work, 'Int', 4)   ; horizontal
    if snip.FlipV
        DllCall('gdiplus\GdipImageRotateFlip', 'UPtr', work, 'Int', 6)   ; vertical

    angle := Mod(snip.Angle + 360, 360)
    if (angle = 0) {
        result := work
    } else if (Mod(angle, 90) = 0) {
        DllCall('gdiplus\GdipImageRotateFlip', 'UPtr', work, 'Int', angle // 90)
        result := work
    } else {
        result := GDIp.RotateBitmap(work, angle, snip.TransColor, wantTransparent)
        GDIp.DisposeImage(work)
    }
    dpi := A_ScreenDPI + 0.0
    DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', result, 'Float', dpi, 'Float', dpi)
    return result
}

; Save a snip's current image (WYSIWYG) to a file the user picks. PNG (default)
; gets clean transparent corners on tilted snips; JPG/BMP have no alpha so they
; save exactly as displayed. Remembers the last-used folder for the session.
SaveSnipAs(hwnd := 0) {
    global guiSnips, appName
    static lastDir := ''
    if !hwnd
        hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]

    if (lastDir = '' || !DirExist(lastDir)) {
        lastDir := EnvGet('USERPROFILE') '\Pictures'
        if !DirExist(lastDir)
            lastDir := A_MyDocuments
    }
    default := lastDir '\ScreenSnip_' FormatTime(A_Now, 'yyyyMMdd_HHmmss') '.png'

    ; "S16" = Save-As dialog that prompts before overwriting an existing file.
    sel := FileSelect('S16', default, 'Save Snip As'
                    , 'Images (*.png; *.jpg; *.jpeg; *.bmp)')
    if (sel = '')
        return   ; user cancelled

    SplitPath(sel, , &outDir, &ext)
    ext := StrLower(ext)
    if (ext = '') {                       ; no extension typed → default to PNG
        sel .= '.png', ext := 'png'
    }
    if (outDir != '')
        lastDir := outDir

    mime := (ext = 'jpg' || ext = 'jpeg') ? 'image/jpeg'
          : (ext = 'bmp')                 ? 'image/bmp'
          :                                 'image/png'
    wantTransparent := (mime = 'image/png')

    saveBmp := BuildSaveBitmap(snip, wantTransparent)
    if !saveBmp {
        MsgBox('Could not build the image to save.', appName, 4096)
        return
    }
    status := GDIp.SaveImageToFile(saveBmp, sel, mime)
    GDIp.DisposeImage(saveBmp)

    if (status != 0)
        MsgBox('Save failed (code ' status ').`n`nThe folder may be read-only, or the format unsupported.', appName, 4096)
}

; Rebuild a snip's picture + window from its frozen master and current state.
RenderSnip(snip) {
    global BorderThickness, BorderColor, Bevel3D, Bevel3DMaxThickness
    g    := snip.GuiObj
    hwnd := g.Hwnd
    dpi  := A_ScreenDPI + 0.0

    ; 1) Fresh upright crop from the master. Clone into a temp first so a rare
    ;    failure can't leave the snip with a disposed pBitmap and no image.
    ;    When Skew ≠ 0 (deskew), instead of a straight clone we draw the master
    ;    rotated about ITS center and extract the (same-sized) crop rectangle —
    ;    so the content tilts inside an unchanged, axis-aligned frame. At
    ;    Skew = 0 CropSkewed would reproduce CloneBitmapArea exactly, but we
    ;    keep the fast, lossless clone for that common case.
    if (snip.Skew = 0)
        newCrop := GDIp.CloneBitmapArea(snip.SrcBitmap, snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H)
    else
        newCrop := GDIp.CropSkewed(snip.SrcBitmap
                 , snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H
                 , snip.MasterW / 2, snip.MasterH / 2, snip.Skew, snip.TransColor)
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

; Fast pan for live right-drag: mutate the crop like PanSnipRegion, but re-crop
; and swap the bitmap IN PLACE (RenderSnipFast) instead of rebuilding the whole
; window. Takes an already-resolved snip object. Returns true if the crop moved.
; A pan never changes the crop's size, so the size-preserving fast path is safe.
PanSnipRegionFast(snip, dx, dy) {
    if !(snip.HasProp('SrcBitmap') && snip.SrcBitmap)
        return false
    c  := snip.Crop
    nx := Max(0, Min(c.X + dx, snip.MasterW - c.W))
    ny := Max(0, Min(c.Y + dy, snip.MasterH - c.H))
    if (nx = c.X && ny = c.Y)                 ; hit the snapshot edge — nothing to do
        return false
    c.X := nx, c.Y := ny
    RenderSnipFast(snip)
    return true
}

; Size-preserving render: rebuild the upright crop + display transform and swap
; the Picture's bitmap via STM_SETIMAGE, WITHOUT destroying/recreating the
; control or moving/resizing the window. PRECONDITION: the display size is
; unchanged (true for pan). Used for smooth live dragging; anything that changes
; the snip's dimensions (resize, rotate) must still go through RenderSnip.
RenderSnipFast(snip) {
    dpi := A_ScreenDPI + 0.0
    if (snip.Skew = 0)
        newCrop := GDIp.CloneBitmapArea(snip.SrcBitmap, snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H)
    else
        newCrop := GDIp.CropSkewed(snip.SrcBitmap
                 , snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H
                 , snip.MasterW / 2, snip.MasterH / 2, snip.Skew, snip.TransColor)
    if !newCrop
        return
    DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', newCrop, 'Float', dpi, 'Float', dpi)
    if snip.pBitmap
        GDIp.DisposeImage(snip.pBitmap)
    snip.pBitmap := newCrop

    ; Keep Area (screen coords of the current capture rect) in sync for OCR etc.
    snip.Area := { X: snip.SrcX + snip.Crop.X, Y: snip.SrcY + snip.Crop.Y
                 , W: snip.Crop.W, H: snip.Crop.H }

    display := BuildDisplayBitmap(snip)
    if !display
        return
    hBitmap := GDIp.CreateHBITMAPFromBitmap(display)
    GDIp.DisposeImage(display)
    ; STM_SETIMAGE both installs the new bitmap and returns the previous one,
    ; which we own and must delete to avoid a GDI handle leak during fast pans.
    oldHbm := SendMessage(0x0172, 0, hBitmap, snip.GuiObj.Pic.Hwnd)   ; STM_SETIMAGE, IMAGE_BITMAP
    if oldHbm
        DllCall('DeleteObject', 'Ptr', oldHbm)
}

; Render for a live edge-drag resize: like RenderSnipFast, but the window (and
; the Picture control) also CHANGE SIZE, and the caller supplies the exact window
; top-left (winX, winY) so the anchored edge can stay put instead of re-centering.
; Reuses the existing Picture control (SetWindowPos + STM_SETIMAGE) rather than
; destroying/recreating it, to keep the drag smooth. Angle is 0 during a resize,
; so the display size equals the crop size (flips don't change dimensions).
RenderSnipResize(snip, winX, winY) {
    global BorderThickness, BorderColor, Bevel3D, Bevel3DMaxThickness
    g    := snip.GuiObj
    hwnd := g.Hwnd
    dpi  := A_ScreenDPI + 0.0

    if (snip.Skew = 0)
        newCrop := GDIp.CloneBitmapArea(snip.SrcBitmap, snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H)
    else
        newCrop := GDIp.CropSkewed(snip.SrcBitmap
                 , snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H
                 , snip.MasterW / 2, snip.MasterH / 2, snip.Skew, snip.TransColor)
    if !newCrop
        return
    DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', newCrop, 'Float', dpi, 'Float', dpi)
    if snip.pBitmap
        GDIp.DisposeImage(snip.pBitmap)
    snip.pBitmap := newCrop
    snip.Area := { X: snip.SrcX + snip.Crop.X, Y: snip.SrcY + snip.Crop.Y
                 , W: snip.Crop.W, H: snip.Crop.H }

    display := BuildDisplayBitmap(snip)
    if !display
        return
    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', display, 'UInt*', &newW := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', display, 'UInt*', &newH := 0)

    scale      := A_ScreenDPI / 96
    physBorder := snip.HasBorder ? Round(BorderThickness * scale) : 0
    totalW     := newW + physBorder * 2
    totalH     := newH + physBorder * 2

    DllCall('SendMessage', 'Ptr', hwnd, 'UInt', 0x000B, 'Ptr', 0, 'Ptr', 0)   ; WM_SETREDRAW off

    if snip.HasBorder {
        g.BackColor := BorderColor
        g.MarginX := BorderThickness, g.MarginY := BorderThickness
    }
    ; Resize/move the window, then the Picture child, then swap its bitmap.
    DllCall('SetWindowPos', 'Ptr', hwnd, 'Ptr', 0,
            'Int', winX, 'Int', winY, 'Int', totalW, 'Int', totalH, 'UInt', 0x0014)
    DllCall('SetWindowPos', 'Ptr', g.Pic.Hwnd, 'Ptr', 0,
            'Int', physBorder, 'Int', physBorder, 'Int', newW, 'Int', newH, 'UInt', 0x0014)
    hBitmap := GDIp.CreateHBITMAPFromBitmap(display)
    GDIp.DisposeImage(display)
    oldHbm := SendMessage(0x0172, 0, hBitmap, g.Pic.Hwnd)   ; STM_SETIMAGE
    if oldHbm
        DllCall('DeleteObject', 'Ptr', oldHbm)

    DllCall('SendMessage', 'Ptr', hwnd, 'UInt', 0x000B, 'Ptr', 1, 'Ptr', 0)   ; WM_SETREDRAW on
    DllCall('RedrawWindow', 'Ptr', hwnd, 'Ptr', 0, 'Ptr', 0, 'UInt', 0x0085)

    if (snip.HasBorder && Bevel3D && BorderThickness <= Bevel3DMaxThickness)
        DrawSnipBevel(g, BorderColor, BorderThickness, BevelStrengthFor(hwnd), BevelDarknessFor(hwnd))
    if snip.Alpha < 255
        SetLayeredWinAttribs(hwnd, snip.TransColor, snip.Alpha)
}

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
    g.Add('Edit', 'r30 w570 ReadOnly -E0x200 +VScroll', HelpText)
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
        case 'Save Image As…':          SaveSnipAs(TargetHwnd)
        case 'Copy Text (Windows)':     SnipOcrWindowsText(TargetHwnd)
        case 'Copy Text (PaddleOCR)':   SnipOcrPaddleText(TargetHwnd)
        case 'Copy Table (PaddleOCR)':  SnipOcrPaddleTable(TargetHwnd)
        case 'Rotate 90° CW':           RotateSnip(TargetHwnd, +90)
        case 'Rotate 180°':             RotateSnip(TargetHwnd, 180)
        case 'Rotate 90° CCW':          RotateSnip(TargetHwnd, -90)
        case 'Flip Horizontal (L/R)':   FlipSnip(TargetHwnd, 'FlipH')
        case 'Flip Vertical (U/D)':     FlipSnip(TargetHwnd, 'FlipV')
        case 'Straighten CW':           StraightenSnip(+1, false, TargetHwnd)
        case 'Straighten CCW':          StraightenSnip(-1, false, TargetHwnd)
        case 'Reset Straighten':        ResetStraighten(TargetHwnd)
        case 'Border':                  ToggleSnipBorder(TargetHwnd)
        case 'Shadow':                  ToggleSnipShadow(TargetHwnd)
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
    ; Resolve to the snip window (the message may arrive on the Picture child).
    snipHwnd := guiSnips.Has(hwnd) ? hwnd : DllCall("GetParent", "Ptr", hwnd, "Ptr")
    if !guiSnips.Has(snipHwnd)
        return
    ; Alt + press on an edge/corner = resize the capture region; the opposite
    ; edge stays anchored. Anything else (no Alt, or Alt away from an edge) keeps
    ; the original "left-drag moves the window" behaviour.
    if GetKeyState('Alt', 'P') {
        edge := SnipEdgeAtCursor(snipHwnd)
        if (edge != '') {
            SnipResizeDrag(snipHwnd, edge)
            return
        }
    }
    PostMessage(0xA1, 2, , snipHwnd)   ; WM_NCLBUTTONDOWN, HTCAPTION → move
}

; While Alt is held and the cursor is over a snip's edge/corner, show the
; matching resize cursor. This is PER-WINDOW (SetCursor on our own window only) —
; deliberately NOT SetSystemCursor — so there's nothing to own, restore, or leave
; stuck: the next WM_SETCURSOR (any mouse move off the edge, or Alt released)
; falls through to the default arrow on its own. Returns 1 to tell Windows we
; handled it (suppresses the default arrow); returns nothing to allow default.
WM_SETCURSOR_RESIZE(wParam, lParam, msg, hwnd) {
    global guiSnips
    if !GetKeyState('Alt', 'P')
        return
    snipHwnd := guiSnips.Has(hwnd) ? hwnd : DllCall("GetParent", "Ptr", hwnd, "Ptr")
    if !guiSnips.Has(snipHwnd)
        return
    edge := SnipEdgeAtCursor(snipHwnd)
    if (edge = '')
        return
    DllCall("SetCursor", "Ptr", DllCall("LoadCursor", "Ptr", 0, "Ptr", CursorIdForEdge(edge), "Ptr"))
    return 1
}

; Map an edge code to the appropriate IDC_SIZE* cursor id.
CursorIdForEdge(edge) {
    switch edge {
        case 'L', 'R':   return 32644   ; IDC_SIZEWE   ↔
        case 'T', 'B':   return 32645   ; IDC_SIZENS   ↕
        case 'TL', 'BR': return 32642   ; IDC_SIZENWSE ↖↘
        case 'TR', 'BL': return 32643   ; IDC_SIZENESW ↗↙
    }
    return 32512   ; IDC_ARROW (shouldn't happen)
}

; Which edge/corner of a snip is the cursor over (within the grab zone)? Returns
; a code like 'L','R','T','B','TL','TR','BL','BR', or '' for none. Only upright
; snips (Angle 0) qualify — a rotated snip's screen edges don't correspond to the
; capture rectangle. Uses absolute screen coords (GetCursorPos) so it's immune to
; whatever CoordMode is currently in effect.
SnipEdgeAtCursor(snipHwnd) {
    global guiSnips, EdgeGrabZone, BorderThickness
    if !guiSnips.Has(snipHwnd)
        return ''
    snip := guiSnips[snipHwnd]
    if (Mod(snip.Angle, 360) != 0)
        return ''
    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', snipHwnd, 'Ptr', rect)
    L := NumGet(rect, 0, 'Int'), T := NumGet(rect,  4, 'Int')
    R := NumGet(rect, 8, 'Int'), B := NumGet(rect, 12, 'Int')
    pt := Buffer(8, 0)
    DllCall('GetCursorPos', 'Ptr', pt)
    mx := NumGet(pt, 0, 'Int'), my := NumGet(pt, 4, 'Int')
    ; Ignore if the cursor isn't actually within (a hair of) the window.
    if (mx < L - 2 || mx > R + 2 || my < T - 2 || my > B + 2)
        return ''
    scale := A_ScreenDPI / 96
    z := Max(EdgeGrabZone, Round(BorderThickness * scale))
    h := (mx <= L + z) ? 'L' : (mx >= R - z) ? 'R' : ''
    v := (my <= T + z) ? 'T' : (my >= B - z) ? 'B' : ''
    return v h   ; 'T'+'L'='TL', 'B'+'R'='BR', 'T'+''='T', ''+'L'='L', ''+''=''
}

; Live W/H labels shown WHILE Alt-dragging a snip's edge/corner. The capture-time
; labels (in SelectScreenRegion) live on the full-screen selection overlay, which
; no longer exists once a snip is made — so we use our own tiny overlay window and
; position it to exactly cover the snip's IMAGE area (screen physical px). The
; labels are then placed within it just like capture: W centered on the bottom
; edge, H centered on the right edge. Same font/box style, same min-size gating,
; same dynamic digit-width math. Gated by the ShowDimensionLabels master switch.
;   cmd 'update' — show (first call) / reposition, then update the two labels
;   cmd 'hide'   — hide the overlay (call on every drag-exit path)
; Angle is 0 during a resize and flips don't change dimensions, so w/h (= the new
; crop size) equal the on-screen image size 1:1 and double as both the box size
; and the displayed numbers.
ResizeDimLabels(cmd, imgLeft := 0, imgTop := 0, w := 0, h := 0) {
    global InfoFontSize, InfoWHOffsetRight, InfoWHOffsetBottom
    global InfoWMinWidth, InfoHMinHeight, ShowDimensionLabels
    static ov := "", shown := false
    if !ShowDimensionLabels
        return
    if (ov = "") {
        ; +E0x08000020 = WS_EX_NOACTIVATE | WS_EX_TRANSPARENT: never steals focus,
        ; and the mouse passes straight through to the snip beneath during the drag.
        ov := Gui('+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000020', 'SnipResizeInfo')
        ov.MarginX := 0, ov.MarginY := 0
        ov.BackColor := 1
        WinSetTransColor(1, ov)   ; keyed color 1 → background invisible, only the boxes show
        ov.InfoW := ov.Add('Text', 'Background0xDDDDDD w55 h22 Center', '')
        ov.InfoW.SetFont('s' InfoFontSize ' bold c101010', 'Courier New')
        ov.InfoH := ov.Add('Text', 'Background0xDDDDDD w55 h22 Right', '')
        ov.InfoH.SetFont('s' InfoFontSize ' bold c101010', 'Courier New')
        ov.InfoW.Visible := false, ov.InfoH.Visible := false
    }
    if (cmd = 'hide') {
        if shown
            ov.Hide(), shown := false
        return
    }
    ; cmd = 'update' — Show once (NA = don't activate), then Move on later frames,
    ; mirroring the capture loop's show-once-then-move approach to avoid flicker.
    if !shown {
        ov.Show('NA x' imgLeft ' y' imgTop ' w' w ' h' h)
        shown := true
    } else
        ov.Move(imgLeft, imgTop, w, h)
    pxPerDigit := Round(InfoFontSize * 0.72)
    ctrlWofW := Max(30, StrLen(String(w)) * pxPerDigit + 12)
    ctrlWofH := Max(30, StrLen(String(h)) * pxPerDigit + 12)
    if (w > InfoWMinWidth) {
        ov.InfoW.Text := w
        ov.InfoW.Move(w // 2 - ctrlWofW // 2, h - InfoWHOffsetBottom, ctrlWofW, 22)
        ov.InfoW.Visible := true
    } else
        ov.InfoW.Visible := false
    if (h > InfoHMinHeight) {
        ov.InfoH.Text := h
        ov.InfoH.Move(w - InfoWHOffsetRight, h // 2 - 11, ctrlWofH, 22)
        ov.InfoH.Visible := true
    } else
        ov.InfoH.Visible := false
}

; Drag an edge/corner to resize the capture region. The dragged edge follows the
; cursor; the opposite edge stays nailed to its start screen position. Works in
; MASTER coordinates: each frame maps the cursor to a master-x/-y (accounting for
; flips), pairs it with the fixed anchor edge, and takes min/max to get the new
; crop — so flips fall out naturally with no special-casing. Angle is 0 here (the
; gate in SnipEdgeAtCursor guarantees it), so screen px map 1:1 to crop px.
SnipResizeDrag(snipHwnd, edge) {
    global guiSnips, BorderThickness
    static MINSZ := 8
    if !guiSnips.Has(snipHwnd)
        return
    snip := guiSnips[snipHwnd]
    if !(snip.HasProp('SrcBitmap') && snip.SrcBitmap)
        return

    ; Start geometry (physical px). Image area = window inset by the border.
    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', snipHwnd, 'Ptr', rect)
    winL := NumGet(rect, 0, 'Int'), winT := NumGet(rect,  4, 'Int')
    winR := NumGet(rect, 8, 'Int'), winB := NumGet(rect, 12, 'Int')
    scale      := A_ScreenDPI / 96
    physBorder := snip.HasBorder ? Round(BorderThickness * scale) : 0
    imgL := winL + physBorder, imgT := winT + physBorder
    imgR := winR - physBorder, imgB := winB - physBorder

    sc := { X: snip.Crop.X, Y: snip.Crop.Y, W: snip.Crop.W, H: snip.Crop.H }   ; start crop

    dragL := InStr(edge, 'L'), dragR := InStr(edge, 'R')
    dragT := InStr(edge, 'T'), dragB := InStr(edge, 'B')

    ; Fixed anchor edges (master coords) taken from the non-dragged side. With a
    ; flip, the visible-left edge maps to the crop's RIGHT master edge, etc.; the
    ; two expressions below already bake that in via the FlipH/FlipV branch.
    anchorMX := dragL ? (snip.FlipH ? sc.X : sc.X + sc.W)    ; dragging left → right edge anchored
                      : (snip.FlipH ? sc.X + sc.W : sc.X)    ; else            → left  edge anchored
    anchorMY := dragT ? (snip.FlipV ? sc.Y : sc.Y + sc.H)
                      : (snip.FlipV ? sc.Y + sc.H : sc.Y)

    resizeCursor := DllCall("LoadCursor", "Ptr", 0, "Ptr", CursorIdForEdge(edge), "Ptr")

    ; Show the live W/H labels immediately at the starting size (no-op if the
    ; ShowDimensionLabels master switch is off).
    ResizeDimLabels('update', imgL, imgT, imgR - imgL, imgB - imgT)

    while GetKeyState('LButton', 'P') {
        if !guiSnips.Has(snipHwnd) {
            ResizeDimLabels('hide')
            return
        }
        DllCall("SetCursor", "Ptr", resizeCursor)   ; hold the cursor through the drag
        pt := Buffer(8, 0)
        DllCall('GetCursorPos', 'Ptr', pt)
        mx := NumGet(pt, 0, 'Int'), my := NumGet(pt, 4, 'Int')

        ; ---- horizontal ----
        if (dragL || dragR) {
            dispX := mx - imgL
            draggedMX := snip.FlipH ? (sc.X + sc.W - dispX) : (sc.X + dispX)
            draggedMX := Max(0, Min(draggedMX, snip.MasterW))
            if (Abs(draggedMX - anchorMX) < MINSZ)
                draggedMX := (draggedMX >= anchorMX) ? anchorMX + MINSZ : anchorMX - MINSZ
            draggedMX := Max(0, Min(draggedMX, snip.MasterW))
            nx := Min(anchorMX, draggedMX)
            nw := Max(MINSZ, Abs(draggedMX - anchorMX))
            nw := Min(nw, snip.MasterW - nx)
        } else {
            nx := sc.X, nw := sc.W
        }

        ; ---- vertical ----
        if (dragT || dragB) {
            dispY := my - imgT
            draggedMY := snip.FlipV ? (sc.Y + sc.H - dispY) : (sc.Y + dispY)
            draggedMY := Max(0, Min(draggedMY, snip.MasterH))
            if (Abs(draggedMY - anchorMY) < MINSZ)
                draggedMY := (draggedMY >= anchorMY) ? anchorMY + MINSZ : anchorMY - MINSZ
            draggedMY := Max(0, Min(draggedMY, snip.MasterH))
            ny := Min(anchorMY, draggedMY)
            nh := Max(MINSZ, Abs(draggedMY - anchorMY))
            nh := Min(nh, snip.MasterH - ny)
        } else {
            ny := sc.Y, nh := sc.H
        }

        ; No change this frame — skip the re-render.
        if (nx = snip.Crop.X && ny = snip.Crop.Y && nw = snip.Crop.W && nh = snip.Crop.H) {
            Sleep 8
            continue
        }
        snip.Crop.X := nx, snip.Crop.Y := ny, snip.Crop.W := nw, snip.Crop.H := nh

        ; Keep the anchored VISIBLE edge fixed on screen: the left image edge
        ; stays at imgL unless we're dragging left (then the right edge, imgR,
        ; is fixed and the left is derived from the new width). Same vertically.
        newImgL := dragL ? (imgR - nw) : imgL
        newImgT := dragT ? (imgB - nh) : imgT
        RenderSnipResize(snip, newImgL - physBorder, newImgT - physBorder)
        ResizeDimLabels('update', newImgL, newImgT, nw, nh)
        Sleep 8
    }
    ResizeDimLabels('hide')   ; drag released — clear the labels
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

; ── Drop shadow ───────────────────────────────────────────────────────────────
; A snip's shadow is a SEPARATE top-level window (never a parent/child of the
; snip — reparenting would break the snip's activation, per-hwnd WM handlers,
; alpha, and drag/resize/rotate machinery). It's borderless, tool-window,
; always-on-top, layered, and — critically — WS_EX_NOACTIVATE + WS_EX_TRANSPARENT
; so it never steals focus and clicks fall straight through to whatever's beneath.
;
; The content is painted PER-PIXEL with UpdateLayeredWindow: a GDI+ 32bpp
; premultiplied-ARGB bitmap holding a translucent filled rectangle, optionally
; Gaussian-blurred (ShadowBlur) so the edges feather. The canvas is padded by the
; blur radius so the blur has room to bleed outward.
;
; Positioning + z-order + repaint are driven from ONE place: UpdateSnipShadow,
; off the snip's WM_WINDOWPOSCHANGED. That single message fires whenever the snip
; moves, resizes, rotates, toggles its border, or changes z-order (including the
; internal HTCAPTION drag loop and activation). To keep drags smooth, the bitmap
; is only re-blurred when the SIZE changes; a pure move is a cheap SetWindowPos.

; Create an empty shadow window (hidden). The first paint happens via
; UpdateSnipShadow once the snip object exists. Returns the shadow Gui.
CreateSnipShadow() {
    ; E-styles: 0x08000000 NOACTIVATE | 0x80000 LAYERED | 0x20 TRANSPARENT(click-through)
    sg := Gui('-Caption +ToolWindow +AlwaysOnTop -DPIScale +E0x08080020', 'SnipShadow')
    sg.Show('Hide')     ; realize the hwnd; stays hidden until the first paint
    return sg
}

; Reposition / resize / re-stack a snip's shadow to match the snip's current
; geometry, repainting the blurred bitmap only when the size actually changes.
; Suppressed (fully hidden) when the shadow can't look right: at non-cardinal /
; skewed angles (a rectangle wouldn't match a tilted snip and its transparent
; corners would leak through), OR when the snip isn't 100% opaque (a shadow
; behind a see-through snip looks wrong, and usually isn't wanted then).
UpdateSnipShadow(snip) {
    global ShadowOffset, ShadowOffsetInactive, ShadowBlur
    if !snip.HasProp('ShadowGui') || !snip.ShadowGui
        return
    sg := snip.ShadowGui

    ; A shadow must never show when its snip window isn't visible — e.g. after
    ; Shift+PrintScreen hides all snips. The deferred WM_ACTIVATE_SHADOW timer
    ; (scheduled when the focused snip loses focus as it hides) would otherwise
    ; fire AFTER the toggle loop and repaint this shadow behind a hidden snip.
    if !DllCall('IsWindowVisible', 'Ptr', snip.GuiObj.Hwnd, 'Int') {
        try sg.Hide()
        snip.ShadowHidden := true
        return
    }

    translucent := snip.HasProp('Alpha') && snip.Alpha < 255
    if (Mod(snip.Angle, 90) != 0 || snip.Skew != 0 || translucent) {
        try sg.Hide()
        snip.ShadowHidden := true
        return
    }

    snipHwnd := snip.GuiObj.Hwnd
    if !DllCall('IsWindow', 'Ptr', snipHwnd, 'Int')
        return
    WinGetPos(&sx, &sy, &sw, &sh, snipHwnd)

    scale := A_ScreenDPI / 96
    ; Active snip casts a longer shadow (lifted forward); inactive a shorter one
    ; (closer to the desktop) — same active/inactive language as the bevel.
    active := (DllCall('GetForegroundWindow', 'Ptr') = snipHwnd)
    off   := Round((active ? ShadowOffset : ShadowOffsetInactive) * scale)
    blur  := Min(255, Round(ShadowBlur * scale))
    coreX := sx + off,  coreY := sy + off         ; where the solid core's top-left lands

    wasHidden   := snip.HasProp('ShadowHidden') && snip.ShadowHidden
    sizeChanged := !snip.HasProp('ShadowCoreW') || snip.ShadowCoreW != sw || snip.ShadowCoreH != sh

    if (sizeChanged || wasHidden) {
        ; (Re)paint the softened bitmap at the new size and ULW it into place.
        info := PaintSnipShadow(sg.Hwnd, sw, sh, coreX, coreY, blur)
        snip.ShadowCoreW := sw,  snip.ShadowCoreH := sh
        snip.ShadowEx := info.ex,  snip.ShadowEy := info.ey
        snip.ShadowHidden := false
        ; Reveal (if returning from hidden) and re-stack just behind the snip.
        DllCall('SetWindowPos', 'Ptr', sg.Hwnd, 'Ptr', snipHwnd, 'Int', 0, 'Int', 0
              , 'Int', 0, 'Int', 0, 'UInt', 0x0001 | 0x0002 | 0x0010 | 0x0040)  ; NOSIZE|NOMOVE|NOACTIVATE|SHOWWINDOW
    } else {
        ; Same size — just relocate (layered content is retained) and re-stack.
        ; ShadowEx/Ey are the feather margins added around the core.
        DllCall('SetWindowPos', 'Ptr', sg.Hwnd, 'Ptr', snipHwnd
              , 'Int', coreX - snip.ShadowEx, 'Int', coreY - snip.ShadowEy
              , 'Int', 0, 'Int', 0, 'UInt', 0x0001 | 0x0010)                     ; NOSIZE|NOACTIVATE
    }
}

; Build the shadow bitmap and push it to the layered window. The canvas is padded
; by `pad` on every side so the softened edge has room; the solid core rect is
; drawn inset by `pad`, then the whole thing is feathered by _SoftBlurBitmap. The
; core's top-left is anchored at (coreX, coreY), so the window (which includes the
; pad margin) is shifted up-left by `pad`. Returns {ex, ey} = the pad margins.
PaintSnipShadow(sgHwnd, coreW, coreH, coreX, coreY, blur) {
    static ARGB := 0x26200A   ; PixelFormat32bppARGB (straight, non-premultiplied)
    global ShadowColor

    pad := (blur > 0) ? blur + 2 : 0
    cw  := coreW + pad * 2,  ch := coreH + pad * 2
    bg  := Integer(ShadowColor) & 0xFFFFFF   ; shadow RGB with alpha 0 (clear color)

    DllCall('gdiplus\GdipCreateBitmapFromScan0', 'Int', cw, 'Int', ch
          , 'Int', 0, 'Int', ARGB, 'Ptr', 0, 'Ptr*', &pBmp := 0)
    DllCall('gdiplus\GdipGetImageGraphicsContext', 'Ptr', pBmp, 'Ptr*', &pGfx := 0)
    ; Clear to the shadow colour at alpha 0 so blurring only feathers the ALPHA
    ; channel — no dark fringe, even if ShadowColor isn't black.
    DllCall('gdiplus\GdipGraphicsClear', 'Ptr', pGfx, 'UInt', bg)
    DllCall('gdiplus\GdipCreateSolidFill', 'UInt', _ShadowArgb(), 'Ptr*', &pBrush := 0)
    DllCall('gdiplus\GdipFillRectangleI', 'Ptr', pGfx, 'Ptr', pBrush
          , 'Int', pad, 'Int', pad, 'Int', coreW, 'Int', coreH)
    DllCall('gdiplus\GdipDeleteBrush', 'Ptr', pBrush)

    if (blur > 0)
        _SoftBlurBitmap(pGfx, pBmp, cw, ch, blur)

    DllCall('gdiplus\GdipDeleteGraphics', 'Ptr', pGfx)
    _UlwFromGdipBitmap(sgHwnd, pBmp, cw, ch, coreX - pad, coreY - pad)
    DllCall('gdiplus\GdipDisposeImage', 'Ptr', pBmp)
    return { ex: pad, ey: pad }
}

; Feather a bitmap's edges by scaling it DOWN then back UP with high-quality
; bilinear interpolation — the round-trip averaging softens hard edges. Pure
; core GDI+ (no effects API, no machine code); isotropic, so all edges feather
; equally. `k` (≈ blur radius) sets how far down we shrink = how soft it gets.
_SoftBlurBitmap(pGfx, pBmp, cw, ch, blur) {
    static ARGB := 0x26200A
    k  := blur + 1
    dw := Max(1, cw // k),  dh := Max(1, ch // k)

    ; Shrink into a small scratch bitmap (HighQualityBilinear prefilters/averages).
    DllCall('gdiplus\GdipCreateBitmapFromScan0', 'Int', dw, 'Int', dh
          , 'Int', 0, 'Int', ARGB, 'Ptr', 0, 'Ptr*', &pSmall := 0)
    DllCall('gdiplus\GdipGetImageGraphicsContext', 'Ptr', pSmall, 'Ptr*', &pSmallG := 0)
    DllCall('gdiplus\GdipSetInterpolationMode', 'Ptr', pSmallG, 'Int', 6)  ; HighQualityBilinear
    DllCall('gdiplus\GdipSetPixelOffsetMode',  'Ptr', pSmallG, 'Int', 2)   ; HighQuality
    DllCall('gdiplus\GdipSetCompositingMode',  'Ptr', pSmallG, 'Int', 1)   ; SourceCopy
    _DrawImageRectRect(pSmallG, pBmp, 0, 0, dw, dh, 0, 0, cw, ch)          ; down
    DllCall('gdiplus\GdipDeleteGraphics', 'Ptr', pSmallG)

    ; Draw the small bitmap back up over the full canvas — bilinear smooths it.
    DllCall('gdiplus\GdipSetInterpolationMode', 'Ptr', pGfx, 'Int', 6)
    DllCall('gdiplus\GdipSetPixelOffsetMode',  'Ptr', pGfx, 'Int', 2)
    DllCall('gdiplus\GdipSetCompositingMode',  'Ptr', pGfx, 'Int', 1)      ; SourceCopy (overwrite)
    _DrawImageRectRect(pGfx, pSmall, 0, 0, cw, ch, 0, 0, dw, dh)           ; up
    DllCall('gdiplus\GdipDisposeImage', 'Ptr', pSmall)
}

; Thin wrapper over GdipDrawImageRectRectI (dst rect ← src rect, UnitPixel).
_DrawImageRectRect(pGfx, pImg, dx, dy, dw, dh, sx, sy, sw, sh) {
    DllCall('gdiplus\GdipDrawImageRectRectI', 'Ptr', pGfx, 'Ptr', pImg
          , 'Int', dx, 'Int', dy, 'Int', dw, 'Int', dh
          , 'Int', sx, 'Int', sy, 'Int', sw, 'Int', sh
          , 'Int', 2, 'Ptr', 0, 'Ptr', 0, 'Ptr', 0)   ; UnitPixel
}

; Copy a GDI+ premultiplied-ARGB bitmap into a top-down 32bpp DIB and present it
; via UpdateLayeredWindow (per-pixel alpha). x64 marshalling assumed.
_UlwFromGdipBitmap(sgHwnd, pBmp, w, h, x, y) {
    ; Top-down 32bpp DIB section (negative height = top-down).
    bi := Buffer(40, 0)
    NumPut('UInt', 40, bi, 0),  NumPut('Int', w, bi, 4),  NumPut('Int', -h, bi, 8)
    NumPut('UShort', 1, bi, 12), NumPut('UShort', 32, bi, 14)   ; planes, bpp; BI_RGB = 0
    hdcScreen := DllCall('GetDC', 'Ptr', 0, 'Ptr')
    hdcMem    := DllCall('CreateCompatibleDC', 'Ptr', hdcScreen, 'Ptr')
    pBits := 0
    hDib := DllCall('CreateDIBSection', 'Ptr', hdcMem, 'Ptr', bi, 'UInt', 0
                  , 'Ptr*', &pBits, 'Ptr', 0, 'UInt', 0, 'Ptr')
    hOld := DllCall('SelectObject', 'Ptr', hdcMem, 'Ptr', hDib, 'Ptr')

    ; Lock the GDI+ bits as PARGB (already premultiplied) and blit into the DIB.
    rect := Buffer(16, 0)
    NumPut('Int', 0, 'Int', 0, 'Int', w, 'Int', h, rect)
    bd := Buffer(32, 0)   ; BitmapData: Width,Height,Stride,PixelFormat,Scan0,Reserved
    DllCall('gdiplus\GdipBitmapLockBits', 'Ptr', pBmp, 'Ptr', rect
          , 'UInt', 1, 'Int', 0x0E200B, 'Ptr', bd)             ; ImageLockModeRead, PARGB
    srcStride := NumGet(bd, 8, 'Int')
    srcScan0  := NumGet(bd, 16, 'Ptr')
    dstStride := w * 4
    Loop h
        DllCall('RtlMoveMemory', 'Ptr', pBits + (A_Index - 1) * dstStride
              , 'Ptr', srcScan0 + (A_Index - 1) * srcStride, 'UPtr', dstStride)
    DllCall('gdiplus\GdipBitmapUnlockBits', 'Ptr', pBmp, 'Ptr', bd)

    ; Present. BLENDFUNCTION = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA}; ULW_ALPHA = 2.
    ptDst := Buffer(8, 0),  NumPut('Int', x, ptDst, 0),  NumPut('Int', y, ptDst, 4)
    sz    := Buffer(8, 0),  NumPut('Int', w, sz, 0),     NumPut('Int', h, sz, 4)
    ptSrc := Buffer(8, 0)
    blend := Buffer(4, 0)
    NumPut('UChar', 0, blend, 0), NumPut('UChar', 0, blend, 1)
    NumPut('UChar', 255, blend, 2), NumPut('UChar', 1, blend, 3)
    DllCall('UpdateLayeredWindow', 'Ptr', sgHwnd, 'Ptr', hdcScreen, 'Ptr', ptDst
          , 'Ptr', sz, 'Ptr', hdcMem, 'Ptr', ptSrc, 'UInt', 0, 'Ptr', blend, 'UInt', 2)

    DllCall('SelectObject', 'Ptr', hdcMem, 'Ptr', hOld)
    DllCall('DeleteObject', 'Ptr', hDib)
    DllCall('DeleteDC', 'Ptr', hdcMem)
    DllCall('ReleaseDC', 'Ptr', 0, 'Ptr', hdcScreen)
}

; GDI+ ARGB (0xAARRGGBB) for the shadow fill, from ShadowColor + ShadowAlpha.
_ShadowArgb() {
    global ShadowColor, ShadowAlpha
    return ((ShadowAlpha & 0xFF) << 24) | (Integer(ShadowColor) & 0xFFFFFF)
}

; Tear down a snip's shadow window.
DestroySnipShadow(snip) {
    if (snip.HasProp('ShadowGui') && snip.ShadowGui) {
        try snip.ShadowGui.Destroy()
        snip.ShadowGui := ''
    }
}

; Toggle the drop shadow on/off for a single snip at runtime (right-click menu).
ToggleSnipShadow(Hwnd) {
    global guiSnips, SnipMenu
    if !guiSnips.Has(Hwnd)
        return
    snip := guiSnips[Hwnd]
    if snip.HasShadow {
        snip.HasShadow := false
        SnipMenu.UnCheck('Shadow')
        DestroySnipShadow(snip)
    } else {
        snip.HasShadow := true
        SnipMenu.Check('Shadow')
        snip.ShadowGui := CreateSnipShadow()
        try snip.DeleteProp('ShadowCoreW')  ; force a fresh paint at current size
        try snip.DeleteProp('ShadowHidden')
        UpdateSnipShadow(snip)
    }
}

; The single glue point: any time a snip window moves, resizes, or re-stacks,
; Windows sends it WM_WINDOWPOSCHANGED — we mirror that onto its shadow. Guarded
; so it ignores the Picture child, the shadow windows, and every other Gui.
; No global gate here: a per-snip "Shadow" toggle is authoritative, so a snip
; whose shadow was turned on still tracks even if ShowSnipShadow defaulted off.
WM_WINDOWPOSCHANGED_SHADOW(wParam, lParam, msg, hwnd) {
    global guiSnips
    if !guiSnips.Has(hwnd)
        return
    UpdateSnipShadow(guiSnips[hwnd])
}

; Focus changed: refresh the shadow so its offset switches between the active and
; inactive values. WM_ACTIVATE reaches BOTH the snip gaining and the one losing
; focus (unlike WM_WINDOWPOSCHANGED, which only reliably hits the one coming
; forward). Deferred via SetTimer(-1) so GetForegroundWindow reflects the settled
; state by the time we read it — the same approach the bevel uses.
WM_ACTIVATE_SHADOW(wParam, lParam, msg, hwnd) {
    global guiSnips
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !snip.HasProp('ShadowGui') || !snip.ShadowGui
        return
    SetTimer(() => UpdateSnipShadow(snip), -1)
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
    ShowSnipMenuFor(GuiObj.Hwnd)
}

; Show the snip context menu for a specific window. Split out from the
; ContextMenu-event entry point so the right-drag handler (which consumes
; RButton and thus never fires that event) can open the menu on a click too.
ShowSnipMenuFor(Hwnd) {
    global guiSnips, SnipMenu
    if !guiSnips.Has(Hwnd)
        return
    SnipMenu._targetHwnd := Hwnd
    ; Sync Border checkmark to this snip's individual state
    guiSnips[Hwnd].HasBorder
        ? SnipMenu.Check('Border')
        : SnipMenu.UnCheck('Border')
    ; Same for the Shadow checkmark
    guiSnips[Hwnd].HasShadow
        ? SnipMenu.Check('Shadow')
        : SnipMenu.UnCheck('Shadow')
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
        guiSSR.InfoW.Visible := false, guiSSR.InfoH.Visible := false
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

    ; This drag suppresses the mouse button (Key), so onscreenkeybrd.ahk's own hook
    ; never sees it and can't light it up. Tell the OSK to light it now; the matching
    ; fade call after the loop covers BOTH exits -- normal release AND the Esc-abort
    ; safety valve -- so the on-screen button can never stay stuck lit. Silent no-op
    ; when the OSK isn't running. See OSKMouseHighlight() below.
    OSKMouseHighlight(Key, true)

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
            global InfoWHOffsetRight, InfoWHOffsetBottom, InfoFontSize, InfoWMinWidth, InfoHMinHeight, ShowDimensionLabels
            if !ShowDimensionLabels {
                ; Master switch off — keep both labels hidden.
                guiSSR.InfoW.Visible := false
                guiSSR.InfoH.Visible := false
            } else {
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
    OSKMouseHighlight(Key, false)   ; drag over (released OR Esc-aborted) -> fade the button
    ; On Esc-abort, return a zero-size area so the caller's (W>8 && H>8) guard
    ; skips snip creation.
    if aborted
        return { X: X, Y: Y, W: 0, H: 0, X2: X, Y2: Y }
    return { X: X, Y: Y, W: W, H: H, X2: X+W, Y2: Y+H }
}

; Tell onscreenkeybrd.ahk to light (lightUp=true) or fade (false) a mouse button that
; THIS script is suppressing for a drag, so the on-screen keyboard still shows it held.
; RegisterWindowMessage returns the same id in every process for a given string, so no
; shared file or hard-coded number is needed -- the OSK registers the identical string
; and listens for it. Broadcast (ahk_id 0xFFFF) so we need no window handle, wrapped in
; try so it's a harmless no-op when the OSK isn't running. Only the L/R mouse buttons map
; to on-screen keys (codes 1/2, matching VK_LBUTTON/VK_RBUTTON); anything else is ignored.
OSKMouseHighlight(keyName, lightUp) {
    static msg := DllCall("RegisterWindowMessage", "Str", "AHK_OSK_MouseHighlight", "UInt")
    code := (keyName = "LButton") ? 1 : (keyName = "RButton") ? 2 : 0
    if code
        try PostMessage(msg, lightUp ? 1 : 0, code, , "ahk_id 0xFFFF")
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

    ; Deskew crop (for the Straighten feature). Draws the master rotated by
    ; angleDeg about the master-local pivot (cx, cy) into a NEW cropW×cropH
    ; bitmap whose origin is the crop's top-left. Result is the same-sized
    ; upright rectangle CloneBitmapArea would give, but with the content tilted
    ; inside it. Rotating about a FIXED pivot (the master center) rather than
    ; the moving crop center is what lets panning slide the frame over one
    ; stable rotated image instead of swirling the content.
    ;
    ; Transform (GDI+ prepend order → first call listed is applied LAST):
    ;     device = Translate(cx-cropX, cy-cropY) · Rotate(θ) · Translate(-cx,-cy) · world
    ; A master pixel at (cx,cy) lands at (cx-cropX, cy-cropY); at θ=0 the whole
    ; thing collapses to a plain (cropX,cropY)-origin crop, so a first straighten
    ; from level doesn't visibly jump. Corners the tilt pulls from beyond the
    ; master fill with transColor — but CaptureAdjustMargin normally supplies
    ; real pixels there, so the fill rarely shows.
    Static CropSkewed(pMaster, cropX, cropY, cropW, cropH, cx, cy, angleDeg, transColor := 0xFF00FF) {
        DllCall('gdiplus\GdipCreateBitmapFromScan0',
            'Int', cropW, 'Int', cropH, 'Int', 0, 'Int', 0x21808, 'Ptr', 0, 'UPtr*', &pNew := 0)
        if !pNew
            return 0
        DllCall('gdiplus\GdipGetImageGraphicsContext', 'UPtr', pNew, 'UPtr*', &pGfx := 0)

        ; Background = the transparent color key, so any exposed corner blends
        ; toward it (matches how RotateBitmap handles rotation overflow).
        fillColor := 0xFF000000 | transColor
        DllCall('gdiplus\GdipCreateSolidFill', 'UInt', fillColor, 'UPtr*', &pBrush := 0)
        DllCall('gdiplus\GdipFillRectangleI', 'UPtr', pGfx, 'UPtr', pBrush,
            'Int', 0, 'Int', 0, 'Int', cropW, 'Int', cropH)
        DllCall('gdiplus\GdipDeleteBrush', 'UPtr', pBrush)

        DllCall('gdiplus\GdipSetInterpolationMode', 'UPtr', pGfx, 'Int', 7)   ; HighQualityBicubic
        DllCall('gdiplus\GdipSetSmoothingMode',     'UPtr', pGfx, 'Int', 4)
        DllCall('gdiplus\GdipSetPixelOffsetMode',   'UPtr', pGfx, 'Int', 2)

        DllCall('gdiplus\GdipTranslateWorldTransform', 'UPtr', pGfx, 'Float', cx - cropX, 'Float', cy - cropY, 'Int', 0)
        DllCall('gdiplus\GdipRotateWorldTransform',    'UPtr', pGfx, 'Float', angleDeg + 0.0, 'Int', 0)
        DllCall('gdiplus\GdipTranslateWorldTransform', 'UPtr', pGfx, 'Float', -cx, 'Float', -cy, 'Int', 0)

        DllCall('gdiplus\GdipDrawImageI', 'UPtr', pGfx, 'UPtr', pMaster, 'Int', 0, 'Int', 0)

        dpi := A_ScreenDPI + 0.0
        DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', pNew, 'Float', dpi, 'Float', dpi)
        DllCall('gdiplus\GdipDeleteGraphics', 'UPtr', pGfx)
        return pNew
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
    Static RotateBitmap(pBitmap, angleDeg, transColor := 0xFF00FF, fillTransparent := false) {
        ; Get original dimensions
        DllCall('gdiplus\GdipGetImageWidth',  'UPtr', pBitmap, 'UInt*', &origW := 0)
        DllCall('gdiplus\GdipGetImageHeight', 'UPtr', pBitmap, 'UInt*', &origH := 0)

        ; Bounding box of the rotated rectangle
        rad  := angleDeg * 3.14159265358979 / 180
        sinA := Abs(Sin(rad)), cosA := Abs(Cos(rad))
        newW := Round(origW * cosA + origH * sinA)
        newH := Round(origW * sinA + origH * cosA)

        ; Create the destination canvas. For DISPLAY we use 24bppRGB (0x21808)
        ; and fill it with an opaque color the layered window keys out — a 24bpp
        ; surface has no alpha, so the fill survives HBITMAP conversion exactly.
        ; For SAVING transparent (fillTransparent) we need a real alpha channel,
        ; so we use 32bppARGB (0x26200A): the scan0 buffer is zero-initialised to
        ; (0,0,0,0) — fully transparent — and the un-drawn corners stay that way.
        ; (A 24bpp surface can't be transparent; its zeroed corners are opaque
        ; black, which is exactly the "black corners in the saved PNG" bug.)
        pixFmt := fillTransparent ? 0x26200A : 0x21808
        DllCall('gdiplus\GdipCreateBitmapFromScan0',
            'Int', newW, 'Int', newH, 'Int', 0, 'Int', pixFmt, 'Ptr', 0, 'UPtr*', &pNew := 0)

        ; Get graphics context for the new bitmap
        DllCall('gdiplus\GdipGetImageGraphicsContext', 'UPtr', pNew, 'UPtr*', &pGfx := 0)

        ; Fill background with the trans color so antialiased edge pixels blend
        ; toward it rather than leaving a hard, mismatched edge. In the transparent
        ; case we skip the fill and let the antialiased edges blend toward the
        ; zero-alpha background instead. The rotated content itself comes from an
        ; opaque (24bpp) source, so it draws fully opaque over the clear canvas.
        if !fillTransparent {
            fillColor := 0xFF000000 | transColor   ; GDI+ ARGB: full opacity + RGB
            DllCall('gdiplus\GdipCreateSolidFill', 'UInt', fillColor, 'UPtr*', &pBrush := 0)
            DllCall('gdiplus\GdipFillRectangleI', 'UPtr', pGfx, 'UPtr', pBrush,
                'Int', 0, 'Int', 0, 'Int', newW, 'Int', newH)
            DllCall('gdiplus\GdipDeleteBrush', 'UPtr', pBrush)
        }

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

    ; Find the GDI+ encoder CLSID for a MIME type (e.g. "image/png"), returned as
    ; a 16-byte Buffer, or 0 if not found. Walks the installed-encoders array; the
    ; MimeType field sits after the CLSID(16) + FormatID(16) + four string pointers.
    Static GetEncoderClsid(mimeType) {
        DllCall("gdiplus\GdipGetImageEncodersSize", "UInt*", &num := 0, "UInt*", &size := 0)
        if (num = 0 || size = 0)
            return 0
        ci := Buffer(size)
        DllCall("gdiplus\GdipGetImageEncoders", "UInt", num, "UInt", size, "Ptr", ci)
        ; sizeof(ImageCodecInfo): CLSID(16) + FormatID(16) + 4 DWORDs(16) + 7
        ; pointers. NOT size//num — `size` also covers the trailing string/sig
        ; data the pointers reference, so size//num overshoots the real stride
        ; and walks off into that data from the 2nd encoder on (→ bad pointer).
        structSize := 48 + 7 * A_PtrSize
        ; MimeType sits after CLSID(16) + FormatID(16) + 4 string pointers.
        offMime    := 32 + 4 * A_PtrSize
        Loop num {
            base  := ci.Ptr + (A_Index - 1) * structSize
            pMime := NumGet(base + offMime, "Ptr")
            if (pMime && StrGet(pMime, "UTF-16") = mimeType) {
                clsid := Buffer(16)
                DllCall("RtlMoveMemory", "Ptr", clsid, "Ptr", base, "UPtr", 16)
                return clsid
            }
        }
        return 0
    }

    ; Encode pBitmap to a file. mimeType picks the format ("image/png" etc.).
    ; Returns 0 on success, or a negative/GDI+ status code on failure.
    Static SaveImageToFile(pBitmap, filePath, mimeType := "image/png") {
        clsid := this.GetEncoderClsid(mimeType)
        if !clsid
            return -1
        return DllCall("gdiplus\GdipSaveImageToFile",
                       "UPtr", pBitmap, "WStr", filePath, "Ptr", clsid, "Ptr", 0, "Int")
    }
}

; ── OCR add-on ────────────────────────────────────────────────────────────────
; Provides SnipOcrWindowsText / SnipOcrPaddleText / SnipOcrPaddleTable, called
; from SnipMenu_Handler above.  Contains no top-level executable code, so it is
; safe to include here at the end of the file.
#Include SnipOCR.ahk
