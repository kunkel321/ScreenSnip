;               ScreenSnip.ahk
;
; Github https://github.com/kunkel321/ScreenSnip
; AHK Forum https://www.autohotkey.com/boards/viewtopic.php?f=83&t=140802
;
; Based on Snipper by FanaticGuru 
; https://www.autohotkey.com/boards/viewtopic.php?f=83&t=115622
;
; Adapted and simplified by kunkel321 / Claude
; Version date: 6-19-2026
; Drag to capture a screen region; the snip floats as a borderless
; always-on-top window.  Multiple snips can be open at once.
;
; Hotkeys:
;   Ctrl + RButton drag             Capture region, create floating snip
;   Ctrl + Shift + RButton drag     Also copy to clipboard
;   Shift + PrintScreen           Toggle show / hide all snips
;
; Floating snip controls (snip window must be active/focused):
;   Left-click drag               Move the snip
;   Right-click                   Context menu (Copy / Rotate / Flip / Border / Close)
;   Esc                           Close the snip
;   Alt + Up/Down                 Adjust transparency (coarse ±25)
;   Alt + Wheel                   Adjust transparency (fine ±10)
;   Alt + Left/Right              Rotate ±1°
;   Alt + Shift + Left/Right      Snap to next 30° increment (CW/CCW)
;   Shift + Left/Right            Flip horizontal
;   Shift + Up/Down               Flip vertical
;   Ctrl + Arrow                  Nudge position ±1 px
;   Ctrl + Shift + Arrow          Nudge position ±10 px
;
#Requires AutoHotkey v2
#Warn All, Off
#SingleInstance Force
DetectHiddenWindows true
SetWinDelay(0)

; ── Globals ────────────────────────────────────────────────────────────────────
global guiSnips    := Map()   ; hwnd → { GuiObj, Area }
global SnipVisible := true

; ══════════════════════════════════════════════════════════════════════════════
; USER SETTINGS — adjust these to taste
; ══════════════════════════════════════════════════════════════════════════════

; Color of the semi-transparent selection overlay while dragging.
; Any AHK color name or hex value (e.g. 'Lime', 'Teal', '0xFF8800').
SelectionColor := 'b58500'

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
Bevel3DMaxThickness := 2
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
Bevel3DInactiveDarknessFactor := 0.2

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

; Hotkey cheat sheet — shown via F1 or right-click menu > Help.
HelpText := "
(
  CAPTURING
  Ctrl + RButton drag          Capture region
  Ctrl + Shift + RButton drag  Capture + copy to clipboard
  Shift + PrintScreen          Toggle show / hide all snips

  SNIP CONTROLS  (snip window must be focused)
  Left-click drag              Move
  Right-click                  Context menu
  Esc                          Close this snip

  TRANSPARENCY
  Alt + Up / Down              Adjust ±25
  Alt + Wheel                  Adjust ±10

  ROTATION
  Alt + Left / Right           Rotate ±1°
  Shift + Alt + Left / Right   Snap to next 30° (CW / CCW)

  FLIP
  Shift + Left / Right         Flip horizontal
  Shift + Up / Down            Flip vertical

  NUDGE POSITION
  Ctrl + Arrow                 Move ±1 px
  Ctrl + Shift + Arrow         Move ±10 px
)"

; ══════════════════════════════════════════════════════════════════════════════

; ── DPI awareness (helps on scaled displays) ───────────────────────────────────
Try DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr")

; ── GDI+ stays alive for the entire session ────────────────────────────────────
GDIp.Startup()
OnExit((*) => GDIp.Shutdown())

; ── Tray icon & menu ──────────────────────────────────────────────────────────
TraySetIcon(A_WinDir '\system32\shell32.dll', 260)   ; scissors

appName := StrReplace(A_ScriptName, '.ahk')
trayMenu := A_TrayMenu
trayMenu.Delete()
trayMenu.Add(appName, (*) => False)
trayMenu.Disable(appName)
trayMenu.Add()
trayMenu.AddStandard()
trayMenu.Add()
trayMenu.Add('Start with Windows', TrayStartup)
if FileExist(A_Startup '\' appName '.lnk')
    trayMenu.Check('Start with Windows')
trayMenu.Add()
trayMenu.Add('ScreenSnip Help', (*) => ShowHelp())
trayMenu.Default := appName

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
SnipMenu := Menu()
SnipMenu.Add('Copy to Clipboard', SnipMenu_Handler)
SnipMenu.Add('')

RotateMenu := Menu()
RotateMenu.Add('Rotate 90° CW',  SnipMenu_Handler)
RotateMenu.Add('Rotate 180°',    SnipMenu_Handler)
RotateMenu.Add('Rotate 90° CCW', SnipMenu_Handler)
SnipMenu.Add('Rotate', RotateMenu)

FlipMenu := Menu()
FlipMenu.Add('Flip Horizontal (L/R)', SnipMenu_Handler)
FlipMenu.Add('Flip Vertical (U/D)',   SnipMenu_Handler)
SnipMenu.Add('Flip', FlipMenu)

SnipMenu.Add('')
SnipMenu.Add('Border',          SnipMenu_Handler)   ; checkable toggle

SnipMenu.Add('')
SnipMenu.Add('Close This Snip',   SnipMenu_Handler)
SnipMenu.Add('Close All Snips',   SnipMenu_Handler)
SnipMenu.Add('')
SnipMenu.Add('Help (F1)',         SnipMenu_Handler)

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

^RButton:: {                       ; Ctrl + RButton drag — snip (+ clipboard if Shift held)
    global guiSnips, SelectionColor
    Area := SelectScreenRegion('RButton', SelectionColor)
    if (Area.W > 8 && Area.H > 8)
        SnipArea(Area, GetKeyState('Shift'), &guiSnips)
}

+PrintScreen:: {                   ; Shift + PrintScreen — toggle all snips
    global SnipVisible, guiSnips
    SnipVisible := !SnipVisible
    for Hwnd, snip in guiSnips
        SnipVisible ? snip.GuiObj.Show('NA') : snip.GuiObj.Hide()
}

#HotIf WinActive('SnipperWindow ahk_class AutoHotkeyGUI')
Esc::           CloseSnip()
F1::            ShowHelp()
!Up::           AdjustSnipAlpha(+25)
!Down::         AdjustSnipAlpha(-25)
!WheelUp::      AdjustSnipAlpha(+10)
!WheelDown::    AdjustSnipAlpha(-10)
!Left::         AdjustSnipAngle(-1)
!Right::        AdjustSnipAngle(+1)
!+Left::        SnapSnipAngle(-1)
!+Right::       SnapSnipAngle(+1)
+Left::         FlipSnip('FlipH')
+Right::        FlipSnip('FlipH')
+Up::           FlipSnip('FlipV')
+Down::         FlipSnip('FlipV')
^Left::         NudgeSnip(-1,  0)
^Right::        NudgeSnip(+1,  0)
^Up::           NudgeSnip( 0, -1)
^Down::         NudgeSnip( 0, +1)
^+Left::        NudgeSnip(-10,  0)
^+Right::       NudgeSnip(+10,  0)
^+Up::          NudgeSnip(  0, -10)
^+Down::        NudgeSnip(  0, +10)
#HotIf

; ==============================================================================
; SNIP MANAGEMENT
; ==============================================================================

; Create a floating snip from a screen area.
; SetClipboard=true also puts the image on the clipboard.
SnipArea(Area, SetClipboard, &ObjMap) {
    global ShowSnipBorder, BorderThickness, BorderColor, TransColor
    pBitmap := GDIp.BitmapFromScreen(Area)
    ; Pin the bitmap's DPI to the screen DPI so it displays 1:1 pixel-perfect.
    dpi := A_ScreenDPI + 0.0
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

    g.Show('x' Area.X - picOffset ' y' Area.Y - picOffset)
    global Bevel3D, Bevel3DMaxThickness
    if (ShowSnipBorder && Bevel3D && BorderThickness <= Bevel3DMaxThickness)
        DrawSnipBevel(g, BorderColor, BorderThickness, BevelStrengthFor(g.Hwnd), BevelDarknessFor(g.Hwnd))
    ObjMap[g.Hwnd] := { GuiObj: g, Area: Area, Alpha: 255, pBitmap: pBitmap
                      , Angle: 0, HasBorder: ShowSnipBorder, TransColor: snipTransColor }

    ; Do NOT DisposeImage here — pBitmap is stored for later transforms.
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

; Rotate the active snip by delta degrees (cumulative).
; Redraws from pBitmap each time to avoid quality loss from repeated transforms.
AdjustSnipAngle(delta) {
    global guiSnips, BorderThickness, BorderColor
    hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    g    := snip.GuiObj
    snip.Angle := Mod(snip.Angle + delta + 360, 360)

    ; At non-cardinal angles the window is still rectangular but the image
    ; is rotated inside it, so the border would just show as background flash.
    ; Suppress it during rotation and restore at 0/90/180/270.
    isCardinal := (snip.Angle = 0 || snip.Angle = 90
                || snip.Angle = 180 || snip.Angle = 270)
    showBorder := snip.HasBorder && isCardinal
    if showBorder {
        g.BackColor := BorderColor
        g.MarginX   := BorderThickness
        g.MarginY   := BorderThickness
    } else {
        g.BackColor := Format('0x{:06X}', snip.TransColor)
        g.MarginX   := 0
        g.MarginY   := 0
    }

    ; Build rotated bitmap from the stored original pBitmap
    rotBitmap := GDIp.RotateBitmap(snip.pBitmap, snip.Angle, snip.TransColor)

    ; New bitmap dimensions are already in physical pixels
    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', rotBitmap, 'UInt*', &newW := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', rotBitmap, 'UInt*', &newH := 0)

    ; Account for border in physical pixels at cardinal angles
    scale      := A_ScreenDPI / 96
    physBorder := showBorder ? Round(BorderThickness * scale) : 0
    totalW     := newW + physBorder * 2
    totalH     := newH + physBorder * 2

    ; Get current window rect in physical screen pixels
    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', hwnd, 'Ptr', rect)
    curL := NumGet(rect,  0, 'Int')
    curT := NumGet(rect,  4, 'Int')
    curR := NumGet(rect,  8, 'Int')
    curB := NumGet(rect, 12, 'Int')

    ; Keep the window centered on its current physical position
    centerX := (curL + curR) // 2
    centerY := (curT + curB) // 2
    newX := centerX - totalW // 2
    newY := centerY - totalH // 2

    ; Suppress all redraws during the swap to prevent flicker.
    ; WM_SETREDRAW(FALSE) queues all paint messages until we re-enable.
    DllCall('SendMessage', 'Ptr', hwnd, 'UInt', 0x000B, 'Ptr', 0, 'Ptr', 0)

    ; Swap out the Picture control
    DllCall("DestroyWindow", "Ptr", g.Pic.Hwnd)
    hBitmap    := GDIp.CreateHBITMAPFromBitmap(rotBitmap)
    picOffset  := showBorder ? BorderThickness : 0
    g.Pic      := g.Add('Picture', 'x' picOffset ' y' picOffset, 'HBITMAP:' hBitmap)
    GDIp.DisposeImage(rotBitmap)

    DllCall('SetWindowPos', 'Ptr', hwnd, 'Ptr', 0,
            'Int', newX, 'Int', newY, 'Int', totalW, 'Int', totalH,
            'UInt', 0x0014)   ; SWP_NOZORDER | SWP_NOACTIVATE

    ; Re-enable redraws and force a single clean repaint.
    DllCall('SendMessage', 'Ptr', hwnd, 'UInt', 0x000B, 'Ptr', 1, 'Ptr', 0)
    DllCall('RedrawWindow', 'Ptr', hwnd, 'Ptr', 0, 'Ptr', 0,
            'UInt', 0x0085)   ; RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN

    global Bevel3D, Bevel3DMaxThickness
    if (showBorder && Bevel3D && BorderThickness <= Bevel3DMaxThickness)
        DrawSnipBevel(g, BorderColor, BorderThickness, BevelStrengthFor(hwnd), BevelDarknessFor(hwnd))

    if snip.Alpha < 255
        SetLayeredWinAttribs(hwnd, snip.TransColor, snip.Alpha)
}

; Flip the active snip horizontally or vertically.
FlipSnip(transform) {
    hwnd := WinGetID('A')
    TransformSnip(hwnd, transform)
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
NudgeSnip(dx, dy) {
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
    g.Add('Edit', 'r25 w462 ReadOnly -E0x200 -VScroll', HelpText)
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

SnipMenu_Handler(ItemName, ItemPos, *) {
    global SnipMenu
    TargetHwnd := SnipMenu._targetHwnd
    switch ItemName {
        case 'Copy to Clipboard':       SnipToClipboard(TargetHwnd)
        case 'Rotate 90° CW':           TransformSnip(TargetHwnd, 'Rotate90CW')
        case 'Rotate 180°':             TransformSnip(TargetHwnd, 'Rotate180')
        case 'Rotate 90° CCW':          TransformSnip(TargetHwnd, 'Rotate90CCW')
        case 'Flip Horizontal (L/R)':   TransformSnip(TargetHwnd, 'FlipH')
        case 'Flip Vertical (U/D)':     TransformSnip(TargetHwnd, 'FlipV')
        case 'Border':                  ToggleSnipBorder(TargetHwnd)
        case 'Help (F1)':               ShowHelp()
        case 'Close This Snip':         CloseSnip(TargetHwnd)
        case 'Close All Snips':         CloseAllSnips()
    }
}

; Apply a rotation or flip transform to a snip in-place.
; Replaces pBitmap in the map entry and rebuilds the Picture control.
; For 90/270 rotations, W and H are swapped and the window is resized
; so the image stays centered on the same screen position.
TransformSnip(Hwnd, Transform) {
    global guiSnips
    if !guiSnips.Has(Hwnd)
        return
    snip := guiSnips[Hwnd]
    g    := snip.GuiObj

    ; Apply transform — produces a new pBitmap, disposes the old one
    oldBitmap  := snip.pBitmap
    newBitmap  := GDIp.TransformBitmap(oldBitmap, Transform)
    GDIp.DisposeImage(oldBitmap)
    snip.pBitmap := newBitmap

    ; Get new image dimensions (physical pixels)
    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', newBitmap, 'UInt*', &newW := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', newBitmap, 'UInt*', &newH := 0)

    ; Account for border in physical pixels
    global ShowSnipBorder, BorderThickness, BorderColor
    scale      := A_ScreenDPI / 96
    physBorder := ShowSnipBorder ? Round(BorderThickness * scale) : 0
    totalW     := newW + physBorder * 2
    totalH     := newH + physBorder * 2

    ; Get current window rect in physical pixels and keep it centered
    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', Hwnd, 'Ptr', rect)
    curL := NumGet(rect,  0, 'Int'), curT := NumGet(rect,  4, 'Int')
    curR := NumGet(rect,  8, 'Int'), curB := NumGet(rect, 12, 'Int')
    centerX := (curL + curR) // 2
    centerY := (curT + curB) // 2
    newX := centerX - totalW // 2
    newY := centerY - totalH // 2

    ; Rebuild the Picture control at the correct inset
    DllCall("DestroyWindow", "Ptr", g.Pic.Hwnd)
    hBitmap := GDIp.CreateHBITMAPFromBitmap(newBitmap)
    picOffset := ShowSnipBorder ? BorderThickness : 0
    g.Pic   := g.Add('Picture', 'x' picOffset ' y' picOffset, 'HBITMAP:' hBitmap)

    ; Reposition in physical pixels via SetWindowPos
    DllCall('SetWindowPos', 'Ptr', Hwnd, 'Ptr', 0,
            'Int', newX, 'Int', newY, 'Int', totalW, 'Int', totalH,
            'UInt', 0x0014)   ; SWP_NOZORDER | SWP_NOACTIVATE

    ; Restore the border (and bevel, if enabled) after the bitmap swap
    if ShowSnipBorder
        SnipWinBorderColor(g, BorderColor)

    ; Re-apply transparency if it was set
    if snip.Alpha < 255
        SetLayeredWinAttribs(Hwnd, snip.TransColor, snip.Alpha)

    snip.Angle := 0
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

~RButton:: {
    global guiSnips, SnipMenu
    ; Ignore when Ctrl is held — that's the snip-drag hotkey, not a context menu request
    if GetKeyState('Ctrl', 'P')
        return
    MouseGetPos(, , &OutputVarWin)
    title := WinGetTitle('ahk_id ' OutputVarWin)
    targetHwnd := ''
    if (title = 'SnipperWindow')
        targetHwnd := OutputVarWin
    else {
        parent := DllCall("GetParent", "Ptr", OutputVarWin, "Ptr")
        if guiSnips.Has(parent)
            targetHwnd := parent
    }
    if (targetHwnd != '') {
        SnipMenu._targetHwnd := targetHwnd
        ; Sync Border checkmark to this snip's individual state
        guiSnips[targetHwnd].HasBorder
            ? SnipMenu.Check('Border')
            : SnipMenu.UnCheck('Border')
        WinActivate('ahk_id ' targetHwnd)
        SnipMenu.Show()
    }
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
    Loop {
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
    } Until !GetKeyState(Key, 'p')

    guiSSR.GetPos(&X, &Y, &W, &H)
    guiSSR.Hide()
    guiSSR.InfoW.Visible := false
    guiSSR.InfoH.Visible := false
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
