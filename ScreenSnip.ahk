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
; Version date: 8-30-2026 
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
;
; Optional add-on modules live in  Resources\  and are all included with the
; *i flag, so any of them can simply be deleted:
;   SnipOCR.ahk       OCR via Descolada's OCR.ahk and PaddleOCR-json.
;   SnipAI.ahk        OCR and free-form questions via an AI vision model (paid).
;   SnipImgur.ahk     One-click upload to imgur.com.
;   SnipWinDetect.ahk Hover-highlight a whole window during Freeze Capture and
;                     grab it with one left-click (SnagIt-style).
;   ToolTipOptions.ahk  just me's tooltip styling library — makes the status
;                     tooltips the modules above raise bigger and easier to see.
; See each file's own header for setup.  Credentials and anything else written
; at runtime go in  Data\  — add that folder to .gitignore.
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

  FREEZE CAPTURE  (grabs menus, tooltips, drop-downs)
  {FreezeTrig}
  Then RButton drag            Select a region from the frozen image
  Hold Shift on release        ...and copy to clipboard
  Or LButton click             Capture the highlighted window whole
  Wheel up / down              Cycle to a window stacked underneath
  Esc                          Cancel the freeze
  A mouse click closes a menu; a key press doesn't — so the whole
  desktop is snapshotted first and you select from that image.
  Trigger key is set by FreezeCaptureKey at the top of the script.

  ON A SNIP  (mouse — click a snip first)
  Left-drag                    Move the window
  Drag an edge / corner        Resize (trim / grow the capture)
  Right-drag                   Pan the image within the frame
  Alt + right-drag             Resize — drag right/down to grow
  Right-click                  Context menu
  Esc                          Close this snip

  EXPORT
  Ctrl + C                     Copy image to clipboard
  Ctrl + S                     Save image  (PNG / JPG / BMP)
  Menu > OCR > Text (Windows)  Fast text grab, no setup
  Menu > OCR > Text (Paddle)   Slower, more accurate
  Menu > OCR > Table (Paddle)  Rebuilds a grid for Excel
  Menu > OCR > Text (AI)       Better on odd layouts; paid
  Menu > OCR > Table (AI)      Reads cell borders; best tables; paid
  Menu > OCR > Ask AI...       Any question about the snip; paid
  Menu > Imgur > Upload        Public link; [img] tag to clipboard
  Menu > Imgur > Uploader...   Formats, delete, Client ID setup
  Tray > Imgur Uploader...     Same dialog, for files already on disc
  Imgur needs a free imgur.com account — see SnipImgur.ahk.

  ADJUST CAPTURE REGION  (re-crops the frozen snapshot)
  Ctrl + Alt + Arrow           Pan  ± 1 px    (or right-drag)
  Ctrl + Shift + Alt + Arrow   Pan  ± 10 px
  Win + Alt + Arrow            Resize ± 1 px  (or drag an edge)
  Win + Shift + Alt + Arrow    Resize ± 10 px (grow = Right / Down)
  Range is limited by CaptureAdjustMargin (top of script).

  ROTATE  (turns the whole snip, frame and all)
  Alt + Left / Right           Rotate ± 1°
  Shift + Alt + Left / Right   Snap to next 30° (CW / CCW)

  STRAIGHTEN  (deskew — tilts the image inside a fixed frame)
  Alt + , / .                  Straighten ± 1°  (CCW / CW)
  Shift + Alt + , / .          Straighten ± 0.5°  (fine)
  Squares up a skewed table before OCR: straighten,
  then drag an edge to trim the exposed corners.

  FLIP
  Shift + Left / Right         Flip horizontal
  Shift + Up / Down            Flip vertical

  MOVE WINDOW  (the floating window, not the capture)
  Ctrl + Arrow                 Move ± 1 px
  Ctrl + Shift + Arrow         Move ± 10 px

  TRANSPARENCY
  Alt + Up / Down              Adjust ± 25
  Alt + Wheel                  Adjust ± 10
{SettingsHelp}  --------------------------------------------------
)"

; ── Globals ────────────────────────────────────────────────────────────────────
global guiSnips    := Map()   ; hwnd → { GuiObj, Area }
global SnipVisible := true
; True only while a Freeze Capture is in progress (backdrop up, awaiting a
; selection). Used to short-circuit the normal Ctrl+RButton capture hotkey so a
; Ctrl-held right-drag on the backdrop can't start a SECOND, nested selection.
global FreezeActive := false

; ══════════════════════════════════════════════════════════════════════════════
; USER SETTINGS
; ══════════════════════════════════════════════════════════════════════════════
; Every knob below now lives in  Data\snipSettings.ini  and is edited with
; Resources\SettingsManager.exe, which takes its labels, help text, types and
; ranges from  Data\snipSettingsMetadata.json.
;
; The long explanatory notes that used to fill this block moved into that JSON,
; where SettingsManager shows them in its help pane AS YOU EDIT.  That is the
; whole point of the move: the guidance is now in front of the person changing
; the setting, instead of in a source file they may never open.  If you want to
; know what one of these does, select it in SettingsManager and read the pane.
;
; The literal after each SnipCfg() call is the FALLBACK, used when the INI is
; missing, unreadable, or has no such key.  So deleting Data\snipSettings.ini is
; a safe factory reset, and a corrupt one degrades to these values instead of
; stopping the script.  Keep them in step with the "default" fields in the JSON.
;
; SETTINGS ARE READ ONCE, AT LOAD.  Nothing re-reads the file, so a change needs
; a restart — which is why every key in the metadata carries a "restart"
; property.  Note that restarting ScreenSnip closes any open snips.
; ══════════════════════════════════════════════════════════════════════════════

; ── Capture ───────────────────────────────────────────────────────────────────
SelectionColor        := SnipCfg('Capture', 'SelectionColor', 'b58500')
SelectionOverlayAlpha := SnipCfg('Capture', 'SelectionOverlayAlpha', 80)
CaptureAdjustMargin   := SnipCfg('Capture', 'CaptureAdjustMargin', 250)

; ── Dimension labels ──────────────────────────────────────────────────────────
ShowDimensionLabels := SnipCfg('DimensionLabels', 'ShowDimensionLabels', true)
InfoFontSize        := SnipCfg('DimensionLabels', 'InfoFontSize', 10)
InfoWHOffsetRight   := SnipCfg('DimensionLabels', 'InfoWHOffsetRight', 38)
InfoWHOffsetBottom  := SnipCfg('DimensionLabels', 'InfoWHOffsetBottom', 25)
InfoWMinWidth       := SnipCfg('DimensionLabels', 'InfoWMinWidth', 75)
InfoHMinHeight      := SnipCfg('DimensionLabels', 'InfoHMinHeight', 55)

; ── Freeze capture ────────────────────────────────────────────────────────────
; Blank FreezeCaptureKey disables the built-in trigger; the cross-script
; RegisterWindowMessage trigger further down still works.
FreezeCaptureKey      := SnipCfg('FreezeCapture', 'FreezeCaptureKey', 'CapsLock')
FreezeDoublePress     := SnipCfg('FreezeCapture', 'FreezeDoublePress', true)
FreezeDoublePressTime := SnipCfg('FreezeCapture', 'FreezeDoublePressTime', 400)
FreezeNullifyCapsLock := SnipCfg('FreezeCapture', 'FreezeNullifyCapsLock', true)

; ── Freeze hint ───────────────────────────────────────────────────────────────
; The two hint strings are separate on purpose: deleting SnipWinDetect.ahk has
; to leave the hint truthful, rather than advertising a click that does nothing.
; `n in the INI value becomes a real line break — SnipCfg() unescapes it.
ShowFreezeHint          := SnipCfg('FreezeHint', 'ShowFreezeHint', true)
FreezeHintText          := SnipCfg('FreezeHint', 'FreezeHintText'
    , 'ScreenSnip has frozen the screen.`nRight-click-drag to select a region.'
    . '`n`nThe new snip will "float" above the screen.`n`nEsc cancels.')
FreezeHintTextWinDetect := SnipCfg('FreezeHint', 'FreezeHintTextWinDetect'
    , 'ScreenSnip has frozen the screen.`nLeft-click a highlighted window to grab it whole,'
    . '`nor right-click-drag to select any region.'
    . '`n`nThe new snip will "float" above the screen.`n`nEsc cancels.')
FreezeHintFontName      := SnipCfg('FreezeHint', 'FreezeHintFontName', 'Segoe UI')
FreezeHintFontSize      := SnipCfg('FreezeHint', 'FreezeHintFontSize', 15)
FreezeHintTextColor     := SnipCfg('FreezeHint', 'FreezeHintTextColor', 'FFFFFF')   ; hex RRGGBB
FreezeHintBackColor     := SnipCfg('FreezeHint', 'FreezeHintBackColor', '1E1E1E')   ; hex RRGGBB
FreezeHintAlpha         := SnipCfg('FreezeHint', 'FreezeHintAlpha', 215)
FreezeHintCornerRadius  := SnipCfg('FreezeHint', 'FreezeHintCornerRadius', 16)

; ── Snip window: border, bevel, transparency key ──────────────────────────────
; BorderColor falls back to SelectionColor rather than to a literal, so the
; "selection tint and finished snip match" relationship survives someone
; changing SelectionColor with no snipSettings.ini present.
ShowSnipBorder  := SnipCfg('SnipWindow', 'ShowSnipBorder', true)
BorderColor     := SnipCfg('SnipWindow', 'BorderColor', SelectionColor)
BorderThickness := SnipCfg('SnipWindow', 'BorderThickness', 2)
Bevel3D                       := SnipCfg('SnipWindow', 'Bevel3D', true)
Bevel3DMaxThickness           := SnipCfg('SnipWindow', 'Bevel3DMaxThickness', 3)
Bevel3DStrength               := SnipCfg('SnipWindow', 'Bevel3DStrength', 0.55)
Bevel3DInactiveStrength       := SnipCfg('SnipWindow', 'Bevel3DInactiveStrength', 0.55)
Bevel3DInactiveDarknessFactor := SnipCfg('SnipWindow', 'Bevel3DInactiveDarknessFactor', 0.2)
; Numeric 0xRRGGBB — SnipCfgHex() strips any 0x/# and validates the 6 hex digits.
TransColor := SnipCfgHex('SnipWindow', 'TransColor', 0xFF00FF)

; ── Snip shadow ───────────────────────────────────────────────────────────────
ShowSnipShadow       := SnipCfg('SnipShadow', 'ShowSnipShadow', true)
ShadowColor          := SnipCfgHex('SnipShadow', 'ShadowColor', 0x000000)
ShadowOffset         := SnipCfg('SnipShadow', 'ShadowOffset', 7)
ShadowOffsetInactive := SnipCfg('SnipShadow', 'ShadowOffsetInactive', 4)
ShadowBlur           := SnipCfg('SnipShadow', 'ShadowBlur', 6)
ShadowAlpha          := SnipCfg('SnipShadow', 'ShadowAlpha', 105)

; ── Gestures ──────────────────────────────────────────────────────────────────
PanDragDivisor := SnipCfg('Gestures', 'PanDragDivisor', 3)
PanClickSlop   := SnipCfg('Gestures', 'PanClickSlop', 5)
EdgeGrabZone   := SnipCfg('Gestures', 'EdgeGrabZone', 6)
; Alt+right-drag resize, same idea as PanDragDivisor: cursor travel is divided by
; this before it becomes pixels, so a bigger number means a slower, finer drag.
; 1 = the corner tracks the cursor 1:1. Kept separate from the pan divisor
; because the two gestures want different feels — panning hunts for a detail and
; wants damping, resizing usually knows where it's going.
ResizeDragDivisor := SnipCfg('Gestures', 'ResizeDragDivisor', 1)

; ── Straighten ────────────────────────────────────────────────────────────────
StraightenStep     := SnipCfg('Straighten', 'StraightenStep', 1)
StraightenFineStep := SnipCfg('Straighten', 'StraightenFineStep', 0.5)
StraightenMaxAngle := SnipCfg('Straighten', 'StraightenMaxAngle', 15)

; ── Saving ────────────────────────────────────────────────────────────────────
; SaveDefaultFolder is only the FIRST folder offered in a session; after that
; the last folder actually saved to wins.  SnipCfgPath() expands %USERPROFILE%.
SaveDefaultFolder := SnipCfgPath('Saving', 'SaveDefaultFolder', '%USERPROFILE%\Pictures')
SaveDefaultExt    := SnipCfg('Saving', 'SaveDefaultExt', 'png')

; ── Tooltips ──────────────────────────────────────────────────────────────────
; Handed to Resources\ToolTipOptions.ahk by InitToolTips() below, which
; subclasses the tooltip window CLASS — so these reach every ToolTip any module
; raises, with no change to a single ToolTip call anywhere.
; TipBackColor/TipTextColor fall back to the freeze hint's colours so the hint
; and the status tooltips stay one visual family by default.
EnhanceToolTips := SnipCfg('Tooltips', 'EnhanceToolTips', true)
TipFontName  := SnipCfg('Tooltips', 'TipFontName', 'Segoe UI')
TipFontSize  := SnipCfg('Tooltips', 'TipFontSize', 12)
TipFontStyle := SnipCfg('Tooltips', 'TipFontStyle', '')
TipBackColor := SnipCfg('Tooltips', 'TipBackColor', FreezeHintBackColor)
TipTextColor := SnipCfg('Tooltips', 'TipTextColor', FreezeHintTextColor)
TipMarginL   := SnipCfg('Tooltips', 'TipMarginL', 10)
TipMarginT   := SnipCfg('Tooltips', 'TipMarginT', 8)
TipMarginR   := SnipCfg('Tooltips', 'TipMarginR', 10)
TipMarginB   := SnipCfg('Tooltips', 'TipMarginB', 8)
TipTitle     := SnipCfg('Tooltips', 'TipTitle', '')
TipTitleIcon := SnipCfg('Tooltips', 'TipTitleIcon', 4)

; ══════════════════════════════════════════════════════════════════════════════
; SETTINGS PLUMBING
; ══════════════════════════════════════════════════════════════════════════════
; Three things about these functions are load-order critical.
;
; 1. The cache is LAZY, filled by whoever calls first.  It has to be: the add-on
;    modules are #Include'd at the BOTTOM of this file, and class static
;    initialisers run BEFORE the auto-execute section — so OcrCfg and friends
;    ask for their settings before the block above has run a single line.  A
;    load routine called from up here would be far too late for them.
;
; 2. SnipCfgLoad() swallows everything.  A class static initialiser that throws
;    is a LOAD-TIME failure, so a locked or malformed INI would stop ScreenSnip
;    from starting at all.  Failing to an empty Map means every SnipCfg() call
;    quietly returns its coded fallback and the app still runs.
;
; 3. The return type follows the FALLBACK's type, not the INI text.  Pass 250
;    and you get an Integer back, pass 0.55 and you get a Float, pass 'x' and
;    you get a String.  So callers never have to think about the fact that
;    everything in an INI file is text.

; Read one setting.  section/key match the INI; default is both the fallback
; and the type template (see note 3 above).
SnipCfg(section, key, default := '') {
    static vals := ''
    if !IsObject(vals)
        vals := SnipCfgLoad()

    k := section '.' key
    if !vals.Has(k)
        return default

    v := Trim(vals[k])
    if (v = '')                              ; key present but deliberately blank
        return (default is Number) ? default : ''

    try {
        if (default is Float)
            return Float(v)
        if (default is Integer)               ; true/false are Integers here too
            return Integer(v)
    } catch {
        return default                        ; e.g. 'abc' where a number belongs
    }

    ; Text.  INI values are a single line, so `n is the line-break escape.
    return StrReplace(v, '``n', '`n')
}

; Slurp the whole INI into a Map keyed 'Section.Key'.  One pass, one file open,
; rather than 100 separate IniRead calls at startup.
SnipCfgLoad() {
    m := Map()
    m.CaseSense := false                      ; INI section/key names aren't case sensitive
    try {
        path := SnipDataPath('snipSettings.ini')
        if !FileExist(path)
            return m
        ; IniRead with no section returns the section names; with a section and
        ; no key, all of that section's key=value lines.
        for sect in StrSplit(IniRead(path), '`n') {
            if (sect = '')
                continue
            for line in StrSplit(IniRead(path, sect), '`n')
                if (pos := InStr(line, '='))  ; first '=' only, so values may contain '='
                    m[sect '.' SubStr(line, 1, pos - 1)] := SubStr(line, pos + 1)
        }
    }
    return m
}

; A color as a numeric 0xRRGGBB, for the values GDI+ and the layered-window
; APIs need as a number rather than a name.  Anything that isn't 6 hex digits
; (with an optional 0x or # in front) falls back rather than producing a
; nonsense color — a bad TransColor would punch holes in every snip.
SnipCfgHex(section, key, default) {
    v := SnipCfg(section, key, '')
    if (v = '')
        return default
    v := RegExReplace(Trim(v), 'i)^(0x|#)', '')
    return RegExMatch(v, '^[0-9A-Fa-f]{6}$') ? Integer('0x' v) : default
}

; A path setting.  Expands %USERPROFILE% and resolves anything relative against
; A_ScriptDir, so the INI can ship a portable 'Resources\...' path while a user
; who browses to a file with SettingsManager gets an absolute one that still
; works.  Absolute means a drive letter or a UNC prefix.
SnipCfgPath(section, key, default) {
    v := Trim(SnipCfg(section, key, ''))
    if (v = '')
        v := default
    v := StrReplace(v, '%USERPROFILE%', EnvGet('USERPROFILE'))
    return RegExMatch(v, '^([A-Za-z]:|\\\\)') ? v : A_ScriptDir '\' v
}

; HelpText is built at the very top of the script, ABOVE the settings, so its
; freeze trigger line is left as a {FreezeTrig} placeholder and filled in here —
; once FreezeCaptureKey / FreezeDoublePress are actually known, rather than
; hard-coding a key name that goes stale the moment someone changes it. Padding
; to 29 chars keeps the row aligned with the hard-coded ones around it.
HelpText := StrReplace(HelpText, '{FreezeTrig}'
    , (FreezeCaptureKey = '')
        ? 'No trigger key set — see FreezeCaptureKey'
        : Format('{:-29s}', (FreezeDoublePress ? 'Double-tap ' : 'Press ') FreezeCaptureKey)
          . 'Freeze the whole screen')

; Same placeholder trick for the settings block: it only earns a place on the
; cheat sheet when the menu items it describes actually exist, so it's filled
; from the same SettingsManagerPath() test the two menus use.  The token sits
; alone at the start of its line, so an absent SettingsManager substitutes to
; nothing at all and leaves no gap behind.
SettingsHelpBlock := "
(

SETTINGS
Tray > Settings...           Edit every setting, with help for each
Menu > Settings...           The same, from a snip's right-click menu
Settings live in Data\snipSettings.ini and are read once, at
launch, so a change needs a restart — which SettingsManager
offers after you save.

)"
HelpText := StrReplace(HelpText, '{SettingsHelp}'
    , SettingsManagerPath() = '' ? '' : SettingsHelpBlock)

; ── DPI awareness (helps on scaled displays) ───────────────────────────────────
Try DllCall("SetThreadDpiAwarenessContext", "ptr", -3, "ptr")

; ── Tooltip styling ───────────────────────────────────────────────────────────
; Applied AFTER the DPI call above, because the point size is converted to
; pixels through GetDeviceCaps(LOGPIXELSY) and that reading depends on the
; thread's DPI awareness — set the font first and a 12pt tooltip comes out
; noticeably small on a scaled display.
InitToolTips()

; Hand the TOOLTIP APPEARANCE settings to Resources\ToolTipOptions.ahk.
;
; Three things make this safe when the file has been deleted:
;   - The whole body is behind IsSet(ToolTipOptions).  The class is the presence
;     sentinel, exactly like OcrCfg / SnipAiCfg / Imgur / WinDetectCfg, and class
;     objects come into existence before the auto-execute section runs, so this
;     can see one declared 3,000 lines further down.
;   - ToolTipOptions.Init() is a VARIABLE dereference followed by a method call,
;     not a direct call to a named function, so an absent class is a runtime
;     concern rather than the load-time error a bare SomeFunc() would be.  That's
;     why this one needs no %name%() dynamic-call dance.
;   - Nothing else in ScreenSnip depends on it.  Every ToolTip() call in every
;     module is untouched, styled or not.
;
; Wrapped in try/catch because SetFont validates its options and throws on a
; bad one (a typo'd style word, a size outside 1-255).  A misconfigured tooltip
; is not worth taking the script down over, so it reports once and carries on
; with plain system tooltips.
InitToolTips() {
    global EnhanceToolTips, TipFontSize, TipFontStyle, TipFontName
    global TipBackColor, TipTextColor, TipTitle, TipTitleIcon
    global TipMarginL, TipMarginT, TipMarginR, TipMarginB
    ; NB: ToolTipOptions is deliberately NOT declared global here.  Declaring it
    ; would CREATE the global variable at load time, and the class declaration
    ; down in the included file would then fail with "This class declaration
    ; conflicts with an existing global variable."  It doesn't need declaring:
    ; the name is only ever read, never assigned, so it resolves to the global
    ; class if one exists — the same way GDIp resolves in every function above,
    ; even though the class is declared much further down the file.  If the file
    ; was deleted, there's no global to resolve to and IsSet() returns false,
    ; which is exactly the outcome the guard wants.

    if !IsSet(ToolTipOptions) || !EnhanceToolTips
        return

    try {
        ToolTipOptions.Init()
        ToolTipOptions.SetFont(Trim('s' TipFontSize ' ' TipFontStyle), TipFontName)
        ToolTipOptions.SetColors(TipBackColor, TipTextColor)
        ToolTipOptions.SetMargins(TipMarginL, TipMarginT, TipMarginR, TipMarginB)
        if (TipTitle != '')
            ToolTipOptions.SetTitle(TipTitle, TipTitleIcon)
    } catch as e {
        ; Undo any half-applied styling so tooltips are consistently plain
        ; rather than, say, huge but still pale yellow.
        try ToolTipOptions.Reset()
        MsgBox('Could not apply the tooltip settings.`n`n' e.Message
             . '`n`nCheck the TOOLTIP APPEARANCE block at the top of the script.'
             . '`nTooltips will use the plain Windows style for this session.'
             , 'ScreenSnip', 4096)
    }
}

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
        '`n', SnipDataPath('ScreenSnip_error.log'))
    return 0
}

; ══════════════════════════════════════════════════════════════════════════════
; RESOURCE AND DATA FOLDERS
; ══════════════════════════════════════════════════════════════════════════════
;
; ScreenSnip's own folder holds just ScreenSnip.ahk/.exe.  Everything else is in
; one of two subfolders, split by WHO WRITES IT:
;
;   Resources\   Shipped with ScreenSnip and never modified — the optional
;                add-on modules, Descolada's OCR.ahk, the PaddleOCR-json engine.
;   Data\        Written at runtime — ApiKeys.ini, the error log, debug dumps.
;                ADD THIS FOLDER TO .gitignore.  That is the point of the split:
;                one folder to ignore beats remembering one filename.
;
; A_ScriptDir is the MAIN script's folder even when these are called from an
; #Include'd file, which is exactly what's wanted — the add-ons down in
; Resources\ still resolve Data\ against the top-level folder, not their own.

; Returns A_ScriptDir\Data\<name>, creating the folder on first use.  Called
; with no argument, returns the folder itself.
SnipDataPath(name := '') {
    static dir := ''
    if (dir = '') {
        dir := A_ScriptDir '\Data'
        if !DirExist(dir) {
            try {
                DirCreate(dir)
            } catch {
                ; Read-only or protected install folder.  Fall back to the
                ; script dir so writes still land somewhere, rather than
                ; throwing on every OCR run and every error-log append.
                dir := A_ScriptDir
            }
        }
    }
    return (name = '') ? dir : dir '\' name
}

; The one credentials file, shared by the add-ons that need one:
;   [Imgur]   ClientID   — SnipImgur.ahk
;   [OpenAI]  ApiKey     — SnipAI.ahk
; One file to gitignore, one to back up.  Neither value is a password, but the
; Imgur ID is rate-limited against your account and the OpenAI key spends your
; prepaid credit, so treat both as private.
;
; Older installs kept the Client ID in ImgurClientID.ini beside ScreenSnip.ahk.
; The first call migrates it across and renames the original to .bak — nothing
; is silently destroyed, and downgrading to an older ScreenSnip still works.
SnipKeysIni() {
    static path := ''
    if (path != '')
        return path

    path   := SnipDataPath('ApiKeys.ini')
    legacy := A_ScriptDir '\ImgurClientID.ini'

    if (!FileExist(path) && FileExist(legacy)) {
        try {
            id := Trim(IniRead(legacy, 'Imgur', 'ClientID', ''))
            if (id != '')
                IniWrite(id, path, 'Imgur', 'ClientID')
            FileMove(legacy, legacy '.bak', true)
        } catch {
            ; Best effort.  If the migration fails (read-only folder, file in
            ; use), keep using the legacy file so Imgur uploads carry on.
            if FileExist(legacy)
                path := legacy
        }
    }
    return path
}

; Ordered teardown: unhook the bevel paint/activate handlers FIRST so they
; can't fire against half-destroyed windows during shutdown, then dispose all
; snip bitmaps + windows, then shut GDI+ down last (so no image object outlives
; the GDI+ session). Each step is guarded so one failure can't abort the rest.
CleanupOnExit(*) {
    try OnMessage(0x000F, WM_PAINT_BEVEL, 0)     ; deregister (MaxThreads 0)
    try OnMessage(0x0006, WM_ACTIVATE_BEVEL, 0)
    try OnMessage(0x0047, WM_WINDOWPOSCHANGED_SHADOW, 0)
    try OnMessage(0x0047, WM_WINDOWPOSCHANGED_SIZESYNC, 0)
    try OnMessage(0x0006, WM_ACTIVATE_SHADOW, 0)
    try CloseAllSnips()
    try GDIp.Shutdown()
}

; ── SettingsManager (optional) ────────────────────────────────────────────────
; Resources\SettingsManager.exe edits Data\snipSettings.ini, taking its labels,
; help text, types and ranges from Data\snipSettingsMetadata.json.  Opt-out on
; the same contract as the #Include'd add-ons: delete it and the two menu items
; that call it simply never get added, rather than sitting there dead.
;
; Returns a ready-to-Run() command line, or '' when there's nothing to run.
; Two launch shapes are recognised, in this order:
;   1. SettingsManager.exe — the suite convention: a RENAMED copy of
;      AutoHotkey64.exe, which runs the .ahk of the same name sitting beside it.
;      Preferred because it needs no AutoHotkey installation on the machine.
;   2. SettingsManager.ahk alone — covers a git clone that skipped the .exe
;      (they're bulky, and often gitignored).  Only workable while ScreenSnip
;      itself is running on an interpreter, hence the A_IsCompiled test.
;
; Resolved once and cached: the menus below are built during auto-execute and
; both ask, and nobody drops a new .exe into Resources\ mid-session.
SettingsManagerPath() {
    static target := '', resolved := false
    if resolved
        return target
    resolved := true

    exe := A_ScriptDir '\Resources\SettingsManager.exe'
    ahk := A_ScriptDir '\Resources\SettingsManager.ahk'

    if FileExist(exe)
        target := '"' exe '"'
    else if (FileExist(ahk) && !A_IsCompiled && FileExist(A_AhkPath))
        target := '"' A_AhkPath '" "' ahk '"'

    return target
}

; Open SettingsManager, or raise the copy that's already open.
;
; The working directory argument is not decoration.  Each key in the metadata
; JSON carries a "restart" path — '..\ScreenSnip.exe' — which SettingsManager
; hands to Run() after a save, and a relative path there resolves against ITS
; working directory.  A launched process inherits the launcher's, so without
; this argument that path would be resolved against wherever ScreenSnip happens
; to have been started from and the "Restart now?" prompt would fail.  Pinning
; it to Resources\ makes it resolve exactly as it does when SettingsManager is
; launched by double-clicking it, which is the case its paths were written for.
;
; Raising an existing window rather than just running it again is deliberate
; too: SettingsManager is #SingleInstance Force, so a second launch would kill
; the first and take any unsaved edits with it.
LaunchSettingsManager(*) {
    target := SettingsManagerPath()
    if (target = '') {
        MsgBox('SettingsManager was not found in the Resources folder.', 'ScreenSnip', 4096)
        return
    }
    if (smHwnd := WinExist('ScreenSnip Settings Manager ahk_class AutoHotkeyGUI')) {
        WinActivate('ahk_id ' smHwnd)
        return
    }
    try
        Run(target, A_ScriptDir '\Resources')
    catch as e
        MsgBox('Could not start SettingsManager.`n`n' e.Message, 'ScreenSnip', 4096)
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
; A discoverable way in for anyone who never reads the config block, and a
; fallback when another script has won the race for FreezeCaptureKey. Safe
; despite the "can't freeze ScreenSnip's own menus" limitation: selecting a tray
; item makes TrackPopupMenu return and the menu close BEFORE the callback runs,
; so the script's thread is free by the time FreezeCapture() blocks on it.
trayMenu.Add('Freeze Capture', (*) => FreezeCapture())
trayMenu.Add('Start with Windows', TrayStartup)
if FileExist(A_Startup '\' appName '.lnk')
    trayMenu.Check('Start with Windows')
; Imgur Uploader — the same dialog as the snip context menu's  Imgur ▸ Imgur
; Uploader…, but reachable with no snip on screen, so a file already sitting on
; disc (an animated GIF, an old screenshot) can go up without capturing
; something first.  Same opt-out contract as the snip submenu below: no
; SnipImgur.ahk means no `Imgur` class, means no tray item.
if IsSet(Imgur) {
    trayMenu.Add()
    trayMenu.Add('Imgur Uploader…', TrayImgurUploader)
}
; Settings — same opt-out contract as the Imgur item above: no SettingsManager
; in Resources\ means no item.  Given its own separator because it acts on the
; whole app rather than on a snip.
if SettingsManagerPath() {
    trayMenu.Add()
    trayMenu.Add('Settings…', LaunchSettingsManager)
}
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

; Tray callback for the Imgur Uploader.  Two things are going on here:
;   - Menu callbacks are handed (ItemName, ItemPos, MenuObj), none of which
;     ShowImgurGui wants, so it can't be wired to the tray item directly.  The
;     `(*)` swallows those three; the 0 means "no snip — open with an empty path
;     box", which is exactly the state you want for a Browse… or a drag-and-drop.
;   - The call is dynamic for the same reason ImgurBuildMenu's is (see the
;     SnipMenu block below): a direct ShowImgurGui(0) would be a LOAD-TIME error
;     whenever SnipImgur.ahk is absent, which would wreck the opt-out
;     arrangement.  Nothing can reach this function in that case anyway — the
;     tray item that calls it is only added when IsSet(Imgur).
TrayImgurUploader(*) {
    showImgurGuiFn := 'ShowImgurGui'
    %showImgurGuiFn%(0)
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

; Markup — see Resources\SnipMarkup.ahk.  Sits with the primary actions rather
; than down among Rotate/Flip, because it is a step in the CAPTURE → ANNOTATE →
; SHARE workflow and belongs above the OCR and Imgur items that follow it, not
; below them.  Same opt-out contract as every module in this file: delete
; SnipMarkup.ahk and MarkupCfg never exists, so this block is skipped and every
; other markup hook short-circuits on the same test.
if IsSet(MarkupCfg) {
    markupMenuBuilder := 'MarkupBuildMenu'
    SnipMenu.Add('Markup', %markupMenuBuilder%())
}

; OCR submenu — assembled from whichever text-extraction add-ons are present.
; Both are opt-out on the same contract as Imgur below: delete the module (or
; comment out its #Include at the bottom of this file) and its config class
; never comes into existence, so these tests skip its items.  Class objects are
; created before the auto-execute section runs, which is why IsSet() can see one
; declared in a file that is #Include'd 2,500 lines further down.
;
; The whole submenu is omitted when neither module is present, rather than
; leaving an empty 'OCR' entry on the menu.
haveOcr := IsSet(OcrCfg)        ; SnipOCR.ahk    — Windows.Media.Ocr + PaddleOCR
haveAi  := IsSet(SnipAiCfg)     ; SnipAI.ahk     — AI vision model (paid, online)
if (haveOcr || haveAi) {
    OcrMenu := Menu()
    if haveOcr {
        OcrMenu.Add('Copy Text (Windows)',    SnipMenu_Handler)  ; fast, no engine to install
        OcrMenu.Add('Copy Text (PaddleOCR)',  SnipMenu_Handler)  ; slower, more accurate
        OcrMenu.Add('Copy Table (PaddleOCR)', SnipMenu_Handler)  ; rebuilds a grid as TSV
    }
    if haveAi {
        if haveOcr
            OcrMenu.Add()       ; separator: below it, the image leaves this PC
        OcrMenu.Add('Copy Text (AI)',      SnipMenu_Handler)  ; better on odd layouts
        OcrMenu.Add('Copy Table (AI)',     SnipMenu_Handler)  ; reads the ruling lines
        OcrMenu.Add('Ask AI About Snip…',  SnipMenu_Handler)  ; free-form question
    }
    SnipMenu.Add('OCR', OcrMenu)
}

; Imgur submenu — see SnipImgur.ahk (optionally included at the bottom of this
; file).  The whole feature is opt-out: delete SnipImgur.ahk, or comment out its
; #Include, and the `Imgur` class never comes into existence, so this block is
; skipped and the menu is built without it.  Class objects are created before the
; auto-execute section runs, which is why IsSet() can see one that's declared
; 2,000 lines further down.  ImgurBuildMenu is invoked through the %name%()
; dynamic-call form on purpose: a DIRECT call to a function that might not exist
; is a LOAD-TIME error in v2, which would defeat the whole point.
if IsSet(Imgur) {
    imgurMenuBuilder := 'ImgurBuildMenu'
    SnipMenu.Add('Imgur', %imgurMenuBuilder%())
}

; Games — the puzzle modules, gathered under one item so three of them don't
; crowd out the snip's actual tools.  Two independent modules and two separate
; sentinels: SnipPuzzle.ahk gives the grid puzzles, SnipJigsaw.ahk the jigsaw,
; and either can be deleted without touching the other.  The whole Games item
; disappears when both are gone, so the menu never shows an empty submenu.
;
; The %name%() dynamic call is for the same reason as the Imgur block above: a
; DIRECT call to a function that might not exist is a LOAD-TIME error in v2.
;
; These belong to SnipMenu, NOT to the tray menu further up — the handlers read
; SnipMenu._targetHwnd to learn which snip to cut up, and that is only set when
; a snip's context menu is opened.
if (IsSet(PuzzleCfg) || IsSet(JigCfg)) {
    gamesMenu := Menu()
    if IsSet(PuzzleCfg) {
        slideMenuBuilder := 'PuzzleBuildSlideMenu'
        swapMenuBuilder  := 'PuzzleBuildSwapMenu'
        gamesMenu.Add('Slide Puzzle', %slideMenuBuilder%())
        gamesMenu.Add('Swap Puzzle',  %swapMenuBuilder%())
    }
    if IsSet(JigCfg) {
        jigsawMenuBuilder := 'JigBuildMenu'
        gamesMenu.Add('Jigsaw Puzzle', %jigsawMenuBuilder%())
    }
    SnipMenu.Add('Games', gamesMenu)
}

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
; Grouped with Help rather than with the snip actions above, because neither
; item does anything to the snip you right-clicked.  Present only when
; SettingsManager is (see SettingsManagerPath).
if SettingsManagerPath()
    SnipMenu.Add('Settings…', SnipMenu_Handler)
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
OnMessage(0x0020, WM_SETCURSOR_RESIZE) ; hover over an edge → resize cursor
OnMessage(0x0047, WM_WINDOWPOSCHANGED_SHADOW) ; keep each snip's drop shadow glued behind it
OnMessage(0x0047, WM_WINDOWPOSCHANGED_SIZESYNC) ; repair image/border/window size if anything outside resizes a snip
OnMessage(0x0006, WM_ACTIVATE_SHADOW) ; switch shadow offset on focus change (active/inactive depth)

; ── Freeze Capture triggers (see the FREEZE CAPTURE section further down) ─────
; Registered HERE, above the first hotkey definition, so they're unambiguously
; part of the auto-execute section.
;
; The trigger key goes through Hotkey() rather than a literal double-colon line
; so it stays configurable from the settings block. '*' fires regardless of
; stray modifiers.
;
; The '~' prefix — pass the key through so it keeps its normal function — is
; used for every trigger key EXCEPT a CapsLock that we've been told to nullify.
; There, passing it through IS the bug:
;
;   With '~', Windows gets the press and toggles the lock on its own schedule,
;   and the script is left trying to undo that afterwards. Every version of
;   "undo it afterwards" is a race with something. A per-press
;   SetCapsLockState('Off') is a read-then-toggle that no-ops if it reads the
;   state before Windows has applied the press. AlwaysOff has the hook correct
;   the state instead, but that correction and a per-press correction can both
;   fire for one press and cancel each other out — and neither is reliable while
;   a full-screen modal capture is up, which is exactly where the last failure
;   reproduced (a third CapsLock press during freeze mode).
;
; Dropping the '~' removes the whole class of problem instead of racing it: the
; hook swallows the key, Windows never sees a CapsLock event at all, and there
; is no toggle left to undo. Presses one, two, three or thirty — inside a freeze
; or outside one — cannot change the lock state, because nothing downstream of
; this hook ever learns the key was pressed. The hotkey itself still fires
; normally, so the trigger keeps working.
;
; Trade-off worth knowing: a suppressed key is invisible to every hook loaded
; after this one, so no other script can bind CapsLock while this is active.
; That's the intent of FreezeNullifyCapsLock, but it's also why the suppression
; is guarded on the key NAME as well as the setting — anyone who picked a
; different trigger key gets the pass-through '~' form and keeps their key.
FreezeCapsNullified := (FreezeNullifyCapsLock && FreezeCaptureKey = 'CapsLock')

if (FreezeCaptureKey != '') {
    try Hotkey((FreezeCapsNullified ? '*' : '~*') FreezeCaptureKey, FreezeHotkeyPressed)
    catch as e
        MsgBox('Could not register the Freeze Capture key "' FreezeCaptureKey '".'
             . '`n`n' e.Message
             . '`n`nCheck FreezeCaptureKey at the top of the script.', appName, 4096)
}

; One-time clear, not a forced mode. Suppression above stops the KEY from ever
; toggling the lock, but it can't clear a lock that was already on when this
; script started — and with the key swallowed, the user would have no way to
; turn it off. So turn it off once, here.
;
; Deliberately NOT SetCapsLockState('AlwaysOff'): that installs a continuous
; hook-level correction which is both redundant now (there's nothing left to
; correct) and a second corrector that can fight the per-press one in
; FreezeHotkeyPressed. One mechanism, not two.
if FreezeCapsNullified
    SetCapsLockState('Off')

; Cross-script trigger. RegisterWindowMessage returns the same id in every
; process for a given string, so another script can start a Freeze Capture with
; no shared file and no hard-coded number — the same trick OSKMouseHighlight()
; uses in the other direction. This matters when some OTHER script already owns
; the key you'd like to trigger with: each AHK script installs its own keyboard
; hook, and whichever hook sits earlier in the chain and suppresses a key wins,
; so two scripts claiming one key is a race. Rather than fight it, let the script
; that already owns the key keep it and have it broadcast this message. E.g. in
; PersonalHotstrings.ahk, which nullifies CapsLock:
;
;     *CapsLock:: {          ; no '~' — the key is swallowed, so it can't toggle
;         static lastTick := 0, msg := DllCall('RegisterWindowMessage'
;                                     , 'Str', 'AHK_ScreenSnip_FreezeCapture', 'UInt')
;         if (A_TickCount - lastTick <= 400) {
;             lastTick := 0
;             try PostMessage(msg, 0, 0, , 'ahk_id 0xFFFF')
;         } else
;             lastTick := A_TickCount
;     }
;
; Note what that example does NOT do: call SetCapsLockState('Off') per press.
; Only ONE script should be touching the lock state, or the two read-then-toggle
; sequences race — both read "on", both send a correction, and the second one
; turns it back on. When ScreenSnip owns the key it nullifies it by SUPPRESSION
; (see the Hotkey() registration above), which leaves nothing for anyone else to
; correct. When some other script owns the key, that script should do the same:
; bind CapsLock without the '~' prefix so the key is swallowed outright, rather
; than passing it through and trying to undo the toggle afterwards.
;
; Harmless no-op when ScreenSnip isn't running, so it can live in the library
; unconditionally.
OnMessage(DllCall('RegisterWindowMessage', 'Str', 'AHK_ScreenSnip_FreezeCapture', 'UInt')
        , FreezeCaptureMessage)

; ==============================================================================
; HOTKEYS
; ==============================================================================

^+RButton::  ; hide
^RButton:: {  ; Ctrl + RButton drag — snip (+ clipboard if Shift held) ; hide
    global guiSnips, SelectionColor, FreezeActive
    ; During a Freeze Capture the backdrop is up and FreezeCapture() is running
    ; its own wait loop, watching the PHYSICAL RButton state. Returning here
    ; still SUPPRESSES the button (the hotkey fired), which is what we want — the
    ; click must not reach anything — while the physical state the hook records
    ; is exactly what the freeze loop reads. Same mechanism SelectScreenRegion
    ; relies on for its own suppressed drag.
    if FreezeActive
        return
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

; ==============================================================================
; FREEZE CAPTURE  (snapshot the whole desktop first, then select from the image)
; ==============================================================================
; See the FREEZE CAPTURE settings block at the top of the script for the why.
; The flow is deliberately ordered:
;
;   1. hook fires  →  2. BitBlt the whole virtual screen  →  3. show backdrop
;   →  4. show hint  →  5. start window highlighting (optional module)
;   →  6. wait for RButton or LButton  →  7. stop highlighting, hide hint, and
;   EITHER take the highlighted window's rect (LButton) OR run the NORMAL
;   SelectScreenRegion drag (RButton)  →  8. hide backdrop  →  9. SnipArea()
;   from the frozen bitmap instead of the live screen.
;
; Steps 2 and 3 must not be swapped: creating any window first steals activation
; and the menu we're trying to capture is gone before the BitBlt happens.
;
; Step 5 must come AFTER step 3 for a different reason: among topmost windows the
; most recently raised one wins, so the highlight bars have to be created after
; the backdrop or they end up behind it and are never seen.

; (The trigger key and the cross-script message are REGISTERED up in the
; WM-handler block, above the first hotkey definition, so they're guaranteed to
; run in the auto-execute section. The handlers themselves live here.)

; Fired by the broadcast message registered up top. The capture runs a blocking wait loop,
; which must never happen inside a message handler — so hand off to a -1 timer
; (runs once, on the next message check, outside this handler) and return
; immediately.
FreezeCaptureMessage(*) {
    SetTimer(FreezeCapture, -1)
    return 1
}

; Trigger-key handler: fire immediately, or on the second press within
; FreezeDoublePressTime when FreezeDoublePress is on.
;
; The lock state is mostly not this function's job: when CapsLock is the trigger
; and FreezeNullifyCapsLock is on, the hotkey is registered WITHOUT '~', so the
; key is swallowed by the hook and can't toggle anything in the first place. The
; per-press reset kept here is a cheap safety net for a lock turned on by some
; OTHER means — a second keyboard, a remote session, another app — while
; ScreenSnip is running. It is the only corrector in the script, so it has
; nothing to race.
;
; When the trigger is anything else the hotkey keeps its '~' prefix, the key
; passes through untouched, and this reset stays inert.
FreezeHotkeyPressed(*) {
    global FreezeDoublePress, FreezeDoublePressTime
    global FreezeCaptureKey, FreezeNullifyCapsLock
    static lastTick := 0

    if (FreezeNullifyCapsLock && FreezeCaptureKey = 'CapsLock')
        SetCapsLockState('Off')

    ; Hand the capture off to a one-shot timer instead of calling it here.
    ;
    ; FreezeCapture() blocks for the ENTIRE capture — backdrop up, waiting on the
    ; selection drag — and a hotkey that is still running its own thread cannot
    ; fire again (#MaxThreadsPerHotkey is 1 by default), so every trigger-key
    ; press during those seconds used to be discarded outright: no handler, no
    ; reset, and a stray press left the caps light on. A -1 timer ends this
    ; thread immediately, keeps the hotkey live for the whole capture, and fires
    ; on the next message check — during the wait loop's Sleep 10 if a capture is
    ; already up, where FreezeCapture()'s own FreezeActive guard rejects it.
    ;
    ; Same reasoning, and the same one-line fix, as FreezeCaptureMessage above.
    if !FreezeDoublePress
        SetTimer(FreezeCapture, -1)
    else if (A_TickCount - lastTick <= FreezeDoublePressTime) {
        lastTick := 0            ; consume the pair, so a 3rd press starts fresh
        SetTimer(FreezeCapture, -1)
    } else
        lastTick := A_TickCount
}

; The capture itself.
FreezeCapture() {
    global guiSnips, SelectionColor, FreezeActive, ShowFreezeHint
    if FreezeActive              ; already frozen — ignore a re-trigger
        return
    FreezeActive := true

    frozen := backdrop := backdropPic := hbm := 0
    try {
        ; ── 1) Snapshot FIRST, before any window exists ──────────────────────
        GetVirtualScreen(&vx, &vy, &vw, &vh)
        frozen := GDIp.BitmapFromScreen({ X: vx, Y: vy, W: vw, H: vh })
        if !frozen
            return
        dpi := A_ScreenDPI + 0.0
        DllCall('gdiplus\GdipBitmapSetResolution', 'UPtr', frozen, 'Float', dpi, 'Float', dpi)

        ; ── 2) Full-screen backdrop showing the frozen image ─────────────────
        ; +E0x08000000 = WS_EX_NOACTIVATE: never takes focus, so it can't fight
        ; the foreground window or disturb the selection drag. -DPIScale because
        ; the coordinates below are already real (physical) screen pixels.
        hbm      := GDIp.CreateHBITMAPFromBitmap(frozen)
        backdrop := Gui('-Caption +AlwaysOnTop +ToolWindow -DPIScale +E0x08000000', 'SnipperFreeze')
        backdrop.MarginX := 0, backdrop.MarginY := 0
        backdrop.BackColor := 0x000000
        backdropPic := backdrop.Add('Picture', 'x0 y0 w' vw ' h' vh, 'HBITMAP:' hbm)
        backdrop.Show('NA x' vx ' y' vy ' w' vw ' h' vh)

        ; ── 3) Hint, floated ABOVE the backdrop ──────────────────────────────
        ; Not captured: the snip is cut from `frozen`, which was grabbed before
        ; this window existed. Shown after the backdrop so it lands on top of it;
        ; SelectScreenRegion's own overlay then shows on top of BOTH.
        hint := ShowFreezeHint ? ShowFreezeHintGui(backdrop.Hwnd) : 0

        ; ── 3b) Window highlighting — optional, see Resources\SnipWinDetect.ahk
        ; Called through the %name%() dynamic form because a DIRECT call to a
        ; function that might not exist is a LOAD-TIME error in v2 (same reason
        ; ImgurBuildMenu is invoked that way up in the menu-building block).
        ; Shown after the backdrop so the outline lands on top of it.
        detecting := false
        if IsSet(WinDetectCfg) {
            fnBegin   := 'WinDetect_Begin'
            detecting := %fnBegin%()
            if detecting
                FreezeDetectWheel(true)
        }

        ; ── 4) Wait for the gesture that ends the wait ───────────────────────
        ; RButton  → freehand region drag, exactly as before.
        ; LButton  → grab the highlighted window whole (only when detecting).
        ; The frozen backdrop is NOT click-through, so a left-click here lands
        ; harmlessly on it and can never leak to the app underneath.
        aborted := false
        picked  := 0
        while true {
            if GetKeyState('Escape', 'P') {
                aborted := true
                break
            }
            if GetKeyState('RButton', 'P')
                break
            if (detecting && GetKeyState('LButton', 'P')) {
                fnGetRect := 'WinDetect_GetRect'
                if %fnGetRect%(&wdX, &wdY, &wdW, &wdH)
                    picked := { X: wdX, Y: wdY, W: wdW, H: wdH }
                ; Swallow the rest of the click so the button-up can't land on
                ; whatever the backdrop uncovers when it comes down.
                ;
                ; Bounded, and with an Esc check, for the UIPI reason
                ; SelectScreenRegion documents at its own exit test: if the
                ; release happens over an ELEVATED window while ScreenSnip is
                ; not elevated, Windows hides that event from the hook and the
                ; state reads "down" indefinitely. An unbounded wait here would
                ; strand a full-screen topmost backdrop with no way out at all,
                ; which is a worse place for that failure than the drag loop.
                waitStart := A_TickCount
                while (GetKeyState('LButton', 'P') && A_TickCount - waitStart < 3000) {
                    if GetKeyState('Escape', 'P') {
                        aborted := true
                        picked  := 0
                        break
                    }
                    Sleep 10
                }
                break
            }
            Sleep 10
        }
        if aborted
            return

        ; Highlighting is done either way: on the LButton path the rect is
        ; already captured, and on the RButton path the outline would only
        ; compete with the selection rectangle.
        if detecting {
            FreezeDetectWheel(false)
            fnEnd := 'WinDetect_End'
            %fnEnd%()
            detecting := false
        }

        ; The hint has said what it needed to; drop it now that the drag is
        ; starting, so it doesn't compete with the W×H dimension labels.
        if hint
            HideFreezeHintGui(&hint)

        ; ── 5) Either the picked window, or the normal selection drag ────────
        ; SelectScreenRegion only reads mouse coordinates and returns a rect —
        ; it neither knows nor cares that the pixels beneath it are frozen.
        if picked
            Area := FreezeClampArea(picked, vx, vy, vw, vh)
        else
            Area := SelectScreenRegion('RButton', SelectionColor)

        ; ── 6) Drop the backdrop BEFORE creating the snip ────────────────────
        ; The live desktop comes back immediately, and the new snip window can't
        ; end up sandwiched behind a full-screen topmost window.
        if hint
            HideFreezeHintGui(&hint)
        DestroyFreezeBackdrop(&backdrop, &backdropPic, &hbm)

        ; ── 7) Cut the snip out of the frozen bitmap ─────────────────────────
        if (Area.W > 8 && Area.H > 8)
            SnipArea(Area, GetKeyState('Shift'), &guiSnips, frozen, vx, vy)
    } catch as e {
        LogUnhandledError(e, 'FreezeCapture')
    } finally {
        ; Guaranteed teardown on every path — normal finish, Esc abort, or a
        ; throw part-way through. Each helper clears the reference it frees, so
        ; the second call here is a no-op rather than a double-free, and one
        ; failure can't strand a full-screen topmost window on the desktop.
        ; Detection teardown belongs here too, and unconditionally: an Esc abort
        ; or a throw part-way through would otherwise strand four topmost outline
        ; bars on the desktop with no window left to dismiss them. Both calls are
        ; no-ops when detection was never started or has already been stopped.
        if IsSet(WinDetectCfg) {
            try FreezeDetectWheel(false)
            fnEndFinal := 'WinDetect_End'
            try %fnEndFinal%()
        }
        if (IsSet(hint) && hint)
            try HideFreezeHintGui(&hint)
        DestroyFreezeBackdrop(&backdrop, &backdropPic, &hbm)
        if frozen
            try GDIp.DisposeImage(frozen)
        FreezeActive := false
    }
}

; Turn the wheel-to-cycle hotkeys on for the duration of a freeze, off after.
;
; Registered at RUNTIME rather than as static hotkeys so that ScreenSnip carries
; no wheel binding at all outside a freeze — a permanently registered WheelUp
; would put this script in the mouse-hook chain for every scroll on the machine.
;
; SUPPRESSING (no '~') on purpose: the screen is frozen, so letting the wheel
; through would scroll the real window underneath while the backdrop kept showing
; the old pixels, and the snip you finally cut would not match what you saw.
FreezeDetectWheel(turnOn) {
    state := turnOn ? 'On' : 'Off'
    try Hotkey('WheelUp',   FreezeDetectCycleUp,   state)
    try Hotkey('WheelDown', FreezeDetectCycleDown, state)
}

FreezeDetectCycleUp(*)   => FreezeDetectCycle(1)
FreezeDetectCycleDown(*) => FreezeDetectCycle(-1)

FreezeDetectCycle(delta) {
    if !IsSet(WinDetectCfg)
        return
    fn := 'WinDetect_Cycle'
    try %fn%(delta)
}

; Clamp a window rectangle to the virtual screen.
;
; A window can legitimately extend past the desktop edge — dragged half off, or
; a shadow-less frame sitting at a negative coordinate — and the frozen bitmap
; only covers the virtual screen. SnipArea does clamp defensively, but it clamps
; the CROP after computing a master area from the raw rect, so feeding it
; out-of-range values shifts the result rather than trimming it. Trim here.
FreezeClampArea(rect, vx, vy, vw, vh) {
    L := Max(rect.X,            vx)
    T := Max(rect.Y,            vy)
    R := Min(rect.X + rect.W,   vx + vw)
    B := Min(rect.Y + rect.H,   vy + vh)
    W := Max(0, R - L)
    H := Max(0, B - T)
    ; Same shape SelectScreenRegion returns, so SnipArea can't tell them apart.
    return { X: L, Y: T, W: W, H: H, X2: L + W, Y2: T + H }
}

; Tear down the frozen backdrop and release its bitmap, clearing every reference
; so a second call does nothing.
;
; Ordering matters and mirrors what RenderSnip already does for its own picture
; swap: destroy the Picture control's window FIRST, then DeleteObject the HBITMAP
; we created. RenderSnip's comment records why — an HBITMAP handed to a Picture
; control is not reliably freed for us, and at full-virtual-screen size that's a
; ~vw × vh × 4 byte leak per capture, which would add up fast. Destroying the
; control before deleting the bitmap means nothing is still referencing it.
DestroyFreezeBackdrop(&backdrop, &pic, &hbm) {
    if pic {
        try DllCall('DestroyWindow', 'Ptr', pic.Hwnd)
        pic := 0
    }
    if hbm {
        try DllCall('DeleteObject', 'Ptr', hbm)
        hbm := 0
    }
    if backdrop {
        try backdrop.Destroy()
        backdrop := 0
    }
}

; Build and show the floating hint. Returns the Gui (or 0 if it couldn't be
; made). WS_EX_TRANSPARENT (0x20) makes it click-through so the right-drag goes
; straight to whatever is underneath; WS_EX_NOACTIVATE (0x08000000) keeps it from
; ever taking focus. Owned by the backdrop so the z-order between them is stable.
;
; Deliberately NOT using a color-key (WinSetTransColor) for the transparency:
; antialiased glyph edges pick up colored fringing against it, which looks
; especially bad over an arbitrary screenshot. A uniform WinSetTransparent alpha
; on the whole pill has no such problem, and the solid backing is what makes the
; text readable over a busy desktop in the first place.
ShowFreezeHintGui(ownerHwnd) {
    global FreezeHintText, FreezeHintTextWinDetect, FreezeHintFontSize, FreezeHintFontName
    global FreezeHintTextColor, FreezeHintBackColor, FreezeHintAlpha
    global FreezeHintCornerRadius

    ; Advertise the click-a-window gesture only when the module that provides it
    ; is actually loaded AND switched on.
    txt := FreezeHintText
    if (IsSet(WinDetectCfg) && WinDetectCfg.Enabled)
        txt := FreezeHintTextWinDetect

    hint := Gui('-Caption +AlwaysOnTop +ToolWindow -DPIScale +E0x08000020', 'SnipperFreezeHint')
    hint.Opt('+Owner' ownerHwnd)
    hint.MarginX := 22, hint.MarginY := 16
    hint.BackColor := FreezeHintBackColor
    hint.SetFont('s' FreezeHintFontSize ' c' FreezeHintTextColor, FreezeHintFontName)
    hint.Add('Text', 'Center', txt)

    ; Create it hidden so we can measure the auto-sized result, then place it
    ; centered on whichever monitor the cursor is on (NOT the primary — on a
    ; multi-monitor setup those are usually different).
    hint.Show('Hide AutoSize')
    hint.GetPos(, , &hw, &hh)
    CoordMode('Mouse', 'Screen')
    MouseGetPos(&mx, &my)
    MonitorGet(MonitorIndexAt(mx, my), &mL, &mT, &mR, &mB)
    hint.Show('NA x' (mL + (mR - mL - hw) // 2) ' y' (mT + (mB - mT - hh) // 2)
            . ' w' hw ' h' hh)

    WinSetTransparent(FreezeHintAlpha, hint)

    ; Rounded corners via a window region. The +1s are because CreateRoundRectRgn
    ; treats the right/bottom edges as exclusive.
    if (FreezeHintCornerRadius > 0) {
        r := FreezeHintCornerRadius
        hRgn := DllCall('CreateRoundRectRgn', 'Int', 0, 'Int', 0
                      , 'Int', hw + 1, 'Int', hh + 1, 'Int', r, 'Int', r, 'Ptr')
        if hRgn                        ; the window owns the region after this,
            DllCall('SetWindowRgn', 'Ptr', hint.Hwnd, 'Ptr', hRgn, 'Int', 1)
    }                                  ; so we must NOT DeleteObject it.
    return hint
}

; Destroy the hint and clear the caller's reference, so the finally-block's
; second call is a safe no-op rather than a double-destroy.
HideFreezeHintGui(&hint) {
    if hint {
        try hint.Destroy()
        hint := 0
    }
}

; 1-based index of the monitor containing a screen point; falls back to the
; primary monitor if the point is in a gap between/outside displays.
MonitorIndexAt(x, y) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &L, &T, &R, &B)
        if (x >= L && x < R && y >= T && y < B)
            return A_Index
    }
    return MonitorGetPrimary()
}

#HotIf WinActive('SnipperWindow ahk_class AutoHotkeyGUI')
Esc::           SnipEscape() ; hide
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
;
; Alt + right-drag is the RESIZE variant of the same gesture (see
; SnipAltRightButton below). A bare 'RButton::' hotkey only fires with NO
; modifiers held, so the two never compete for the same press.
#HotIf SnipUnderCursor()
RButton::       SnipRightButton() ; hide
!RButton::      SnipAltRightButton() ; hide
#HotIf

; True when the mouse is over one of our snip windows. Used as the #HotIf
; context for the right-drag pan so the gesture is scoped to snips only.
SnipUnderCursor() {
    global guiSnips
    MouseGetPos(, , &win)
    return guiSnips.Has(win)
}

; Alt + right-drag anywhere on a snip = resize the capture region.
;
; Plain right-drag is already the pan (hand) tool, so resize takes the Alt
; variant. This is ScreenSnip's in-process answer to the same gesture AC2's
; MoveResizeTools.ahk offers from outside (^!RButton): because it runs in HERE it
; re-crops the frozen master through the normal path, so the live W/H labels
; appear, the border and drop shadow stay in step, and there's no external resize
; for WM_WINDOWPOSCHANGED_SIZESYNC to repair afterwards. The two gestures don't
; collide either — MoveResizeTools wants Ctrl+Alt, and '!RButton' won't fire
; while Ctrl is also down.
;
; It deliberately copies MoveResizeTools' FEEL rather than the edge-drag's:
; nothing jumps to the cursor. Wherever you press, the top-left corner stays put
; and the bottom-right follows your travel, so dragging 50px left on a 300x300
; snip makes it 250 wide. That's what makes the gesture usable from the middle of
; a snip, where there's no edge to "grab" and no sensible corner to snap to.
SnipAltRightButton() {
    global guiSnips
    MouseGetPos(, , &win)
    if !guiSnips.Has(win)
        return
    snip := guiSnips[win]
    ; Same gate the edge drag relies on: a rotated snip's screen axes don't
    ; correspond to the capture rectangle, so cursor travel has no sane mapping
    ; onto a crop. Leave it alone rather than resizing the wrong axis.
    if (Mod(snip.Angle, 360) != 0)
        return
    WinActivate('ahk_id ' win)   ; as with the pan gesture — focus the snip so the
                                 ; keyboard adjustments work straight afterwards
    SnipResizeDragRelative(win)
}

; Handle a right-button press over a snip: drag to pan (image follows the
; cursor, scaled by PanDragDivisor); a click (travel < PanClickSlop) opens the
; context menu. Panning uses the size-preserving fast path (RenderSnipFast /
; STM_SETIMAGE) so live dragging stays smooth instead of rebuilding the window.
SnipRightButton() {
    global guiSnips, PanDragDivisor, PanClickSlop

    ; MouseGetPos honours CoordMode 'Mouse', which in v2 defaults to CLIENT —
    ; coordinates relative to whichever window is ACTIVE at the moment of the
    ; call.  This function activates the snip partway through, so without this
    ; line the origin would MOVE between the anchor reading and the loop's
    ; readings, and the first delta would be the distance between two unrelated
    ; origins.  That produced a violent jump on the first right-click of a snip
    ; and none afterwards — because once the snip is active, WinActivate is a
    ; no-op and both readings happen to share an origin again.
    ;
    ; Set per-thread rather than at script startup, matching what
    ; ShowFreezeHintGui and SelectScreenRegion already do, so nothing that
    ; relies on the client-relative default is disturbed.
    CoordMode('Mouse', 'Screen')

    MouseGetPos(, , &win)
    if !guiSnips.Has(win)
        return
    snip := guiSnips[win]
    WinActivate('ahk_id ' win)         ; focus so keyboard adjusts work after, and
                                        ; any stray DragTools keystrokes land here

    ; Anchor AFTER the activation, never before.  WinActivate can take a
    ; noticeable moment, and any pointer travel during it belongs to neither the
    ; click nor the drag — reading it as the first frame of a drag would nudge
    ; the region before the gesture has really begun.
    MouseGetPos(&startX, &startY)

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
;
; FrozenSrc (optional) is a GDI+ bitmap of the whole virtual screen, already
; captured, with FrozenX/FrozenY as its top-left in screen coordinates — passed
; in by FreezeCapture(). When supplied, the master snapshot below is cut from
; THAT image instead of being BitBlt'd from the live screen. Everything
; downstream (crop, margin, pan, resize, straighten, render) is identical, so
; a frozen snip behaves exactly like a normal one. The caller retains ownership
; of FrozenSrc and disposes it; we only copy out of it.
SnipArea(Area, SetClipboard, &ObjMap, FrozenSrc := 0, FrozenX := 0, FrozenY := 0) {
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

    ; Frozen source → copy the master out of the snapshot we already hold. Note
    ; the master is cut to the SAME selection+CaptureAdjustMargin size as a live
    ; grab, rather than keeping the whole desktop: identical adjust behaviour,
    ; identical memory cost, and no surprise where panning wanders off across
    ; unrelated parts of the screen. (Want whole-desktop roam? That's already
    ; what a very large CaptureAdjustMargin does — for both capture modes.)
    if FrozenSrc {
        SrcBitmap := GDIp.CloneBitmapArea(FrozenSrc, masterX - FrozenX, masterY - FrozenY, masterW, masterH)
        if !SrcBitmap                       ; clone failed — fall back to a live
            SrcBitmap := GDIp.BitmapFromScreen({ X: masterX, Y: masterY, W: masterW, H: masterH })
    } else                                  ; grab so we still produce a snip
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

    ; +0x02000000 = WS_CLIPCHILDREN. Excludes the Picture child's rectangle from
    ; everything the PARENT paints, so the window's background — which for a
    ; bordered snip is the BORDER COLOUR — can never be painted over the image,
    ; not on an erase, not during a resize, not on any repaint. Without it every
    ; erase of the client area briefly floods the whole snip with the border
    ; colour before the child repaints on top, which is the flicker seen during
    ; live resizes. The parent legitimately owns only the frame; this says so.
    g := Gui('-Caption +AlwaysOnTop +OwnDialogs +0x02000000 +E0x80000', 'SnipperWindow')

    ; The two border properties start from the script-wide defaults but are
    ; stored PER SNIP from here on (see SetSnipBorder), so one snip can wear a
    ; fat red frame while its neighbour keeps the thin gold one. Normalised to a
    ; plain 0xRRGGBB integer at birth so every later consumer — BackColor,
    ; DrawSnipBevel, the markup palette — gets the same type.
    snipBorderColor := ColorToHex(BorderColor)
    snipBorderW     := Max(1, Integer(BorderThickness))

    if ShowSnipBorder {
        g.MarginX := snipBorderW, g.MarginY := snipBorderW
        g.BackColor := Format('0x{:06X}', snipBorderColor)
    } else {
        g.MarginX := 0, g.MarginY := 0
        g.BackColor := Format('0x{:06X}', snipTransColor)
    }
    SetLayeredWinAttribs(g.Hwnd, snipTransColor, 255)

    hBitmap := GDIp.CreateHBITMAPFromBitmap(pBitmap)
    picOffset := ShowSnipBorder ? snipBorderW : 0
    g.Pic := g.Add('Picture', 'x' picOffset ' y' picOffset, 'HBITMAP:' hBitmap)

    ; Right-click context menu via the GUI's own ContextMenu event. This fires
    ; on button-UP (so the menu opens with a normal click instead of needing
    ; the button held) and runs in the context of the clicked window (so the
    ; activation below isn't fighting the foreground lock the way the old
    ; global ~RButton hotkey was). The event covers the Picture child too.
    g.OnEvent('ContextMenu', ShowSnipMenu)

    g.Show('NA x' Area.X - picOffset ' y' Area.Y - picOffset)
    global Bevel3D, Bevel3DMaxThickness
    if (ShowSnipBorder && Bevel3D && snipBorderW <= Bevel3DMaxThickness)
        DrawSnipBevel(g, snipBorderColor, snipBorderW, BevelStrengthFor(g.Hwnd), BevelDarknessFor(g.Hwnd))

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
    ; SkewPivotX/Y — the master-local point the Straighten tilt turns about (see
    ; SkewPivotOf / StraightenSnip). Anchored at the CROP centre, not the master
    ; centre: for a normal grab those coincide, but they diverge whenever the
    ; margin gets clamped by a screen edge, and they diverge a lot after panning.
    ObjMap[g.Hwnd] := { GuiObj: g, Area: Area, Alpha: 255, pBitmap: pBitmap
                      , Angle: 0, FlipH: false, FlipV: false, Skew: 0
                      , HasBorder: ShowSnipBorder, TransColor: snipTransColor
                      , BorderColor: snipBorderColor, BorderW: snipBorderW
                      , SrcBitmap: SrcBitmap, SrcX: masterX, SrcY: masterY
                      , MasterW: masterW, MasterH: masterH, Crop: crop
                      , SkewPivotX: crop.X + crop.W / 2
                      , SkewPivotY: crop.Y + crop.H / 2
                      , HasShadow: ShowSnipShadow, ShadowGui: shadowGui }

    if shadowGui                        ; first paint + place behind the snip
        UpdateSnipShadow(ObjMap[g.Hwnd])

    ; Do NOT DisposeImage here — pBitmap and SrcBitmap are kept for the snip's life.
    return g.Hwnd
}

; What Esc does on a snip.  Normally it closes the snip, but markup mode gets a
; chance to consume the key first so that Esc can ESCALATE while annotating:
; deselect → back to the Select tool → leave markup → only then close.  That
; gives a panic key which can't destroy work with a mistimed press.  Wired to
; the Esc hotkey rather than into CloseSnip itself, so the menu's "Close This
; Snip" still means exactly that.
SnipEscape() {
    if IsSet(MarkupCfg) {
        markupEscFn := 'MarkupEscape'
        if %markupEscFn%(WinGetID('A'))
            return
    }
    CloseSnip()
}

; Close one snip (defaults to active window).
CloseSnip(Hwnd?) {
    global guiSnips
    if !IsSet(Hwnd)
        Hwnd := WinGetID('A')
    if guiSnips.Has(Hwnd) {
        snip := guiSnips[Hwnd]
        guiSnips.Delete(Hwnd)   ; remove first so in-flight handlers/timers bail out
        if IsSet(MarkupCfg) {   ; end any markup session and free its image pool
            markupCloseFn := 'MarkupOnSnipClosed'
            %markupCloseFn%(snip, Hwnd)
        }
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
    ; This path copies the Picture control's EXISTING bitmap rather than
    ; re-rendering, so anything drawn into it goes to the clipboard — including
    ; markup's selection handles.  Give markup a chance to drop the selection
    ; and re-render first; without this, Ctrl+C mid-annotation copies the blue
    ; boxes along with the image.
    if IsSet(MarkupCfg) {
        markupExpFn := 'MarkupBeforeExport'
        %markupExpFn%(Hwnd)
    }
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
    ; Starting a fresh straighten from level → (re-)anchor the pivot to what the
    ; user is actually looking at, i.e. the centre of the CURRENT crop. While the
    ; skew is non-zero the pivot then stays put, which is what lets panning slide
    ; the frame across one stable rotated image instead of swirling the content.
    ; Re-anchoring only at the 0 → non-zero transition gives both properties.
    if (snip.Skew = 0) {
        snip.SkewPivotX := snip.Crop.X + snip.Crop.W / 2
        snip.SkewPivotY := snip.Crop.Y + snip.Crop.H / 2
    }
    snip.Skew := newSkew
    RenderSnip(snip)
}

; The master-local point a snip's Straighten tilt turns about. Falls back to the
; master centre (the pre-pivot behaviour) if a snip object somehow predates the
; SkewPivot properties — e.g. one handed in by a companion script.
;
; Why this matters: the tilt is applied to the MASTER and the crop rectangle is
; then cut out of the result, so a pivot far from the crop turns a 1° straighten
; into a large sideways sweep of the content (arc length ≈ radius × angle). With
; a 150px CaptureAdjustMargin the master centre is close enough to pass, but the
; error is real at screen edges, grows with every pan, and would be severe with
; a very large margin — where the master can span the whole desktop and the
; centre may be a thousand pixels from the crop.
SkewPivotOf(snip, &cx, &cy) {
    if (snip.HasProp('SkewPivotX') && snip.HasProp('SkewPivotY')) {
        cx := snip.SkewPivotX, cy := snip.SkewPivotY
    } else {
        cx := snip.MasterW / 2, cy := snip.MasterH / 2
    }
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

    ; MARKUP, stage 1 — redaction (blur/pixelate) onto the UPRIGHT crop, before
    ; any transform, because hiding pixels is an operation on the image itself.
    ; See the header of Resources\SnipMarkup.ahk for why the compose is split.
    if (IsSet(MarkupCfg) && snip.HasProp('Markup')) {
        markupImgFn := 'MarkupComposeImage'
        %markupImgFn%(snip, work)
    }

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

    ; MARKUP, stage 2 — every other annotation, drawn onto the FINISHED display
    ; bitmap so vector art lands at final resolution and is never resampled by
    ; the skew or rotation pass.  wantChrome is true here: selection handles are
    ; part of the on-screen picture but never part of an exported one.
    if (IsSet(MarkupCfg) && snip.HasProp('Markup')) {
        markupOvFn := 'MarkupComposeOverlay'
        %markupOvFn%(snip, result, true)
    }
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
    if (IsSet(MarkupCfg) && snip.HasProp('Markup')) {   ; markup stage 1 — redaction
        markupImgFn := 'MarkupComposeImage'
        %markupImgFn%(snip, work)
    }
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
    ; markup stage 2 — annotations, but wantChrome FALSE: no selection handles
    ; in a saved or uploaded image.
    if (IsSet(MarkupCfg) && snip.HasProp('Markup')) {
        markupOvFn := 'MarkupComposeOverlay'
        %markupOvFn%(snip, result, false)
    }
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

    global SaveDefaultFolder, SaveDefaultExt

    if (lastDir = '' || !DirExist(lastDir)) {
        lastDir := SaveDefaultFolder
        if !DirExist(lastDir)
            lastDir := A_MyDocuments
    }
    default := lastDir '\ScreenSnip_' FormatTime(A_Now, 'yyyyMMdd_HHmmss') '.' SaveDefaultExt

    ; "S16" = Save-As dialog that prompts before overwriting an existing file.
    sel := FileSelect('S16', default, 'Save Snip As'
                    , 'Images (*.png; *.jpg; *.jpeg; *.bmp)')
    if (sel = '')
        return   ; user cancelled

    SplitPath(sel, , &outDir, &ext)
    ext := StrLower(ext)
    if (ext = '') {                       ; no extension typed → use SaveDefaultExt
        sel .= '.' SaveDefaultExt, ext := StrLower(SaveDefaultExt)
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
    global Bevel3D, Bevel3DMaxThickness
    bw   := SnipBorderW(snip), bcol := SnipBorderColor(snip)
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
    else {
        SkewPivotOf(snip, &pvx, &pvy)
        newCrop := GDIp.CropSkewed(snip.SrcBitmap
                 , snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H
                 , pvx, pvy, snip.Skew, snip.TransColor)
    }
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
    physBorder := showBorder ? Round(bw * scale) : 0
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
        g.BackColor := Format('0x{:06X}', bcol)
        g.MarginX := bw, g.MarginY := bw
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
    picOffset := showBorder ? bw : 0
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

    if (showBorder && Bevel3D && bw <= Bevel3DMaxThickness)
        DrawSnipBevel(g, bcol, bw, BevelStrengthFor(hwnd), BevelDarknessFor(hwnd))

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
    else {
        SkewPivotOf(snip, &pvx, &pvy)
        newCrop := GDIp.CropSkewed(snip.SrcBitmap
                 , snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H
                 , pvx, pvy, snip.Skew, snip.TransColor)
    }
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
    global Bevel3D, Bevel3DMaxThickness
    bw   := SnipBorderW(snip), bcol := SnipBorderColor(snip)
    g    := snip.GuiObj
    hwnd := g.Hwnd
    dpi  := A_ScreenDPI + 0.0

    if (snip.Skew = 0)
        newCrop := GDIp.CloneBitmapArea(snip.SrcBitmap, snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H)
    else {
        SkewPivotOf(snip, &pvx, &pvy)
        newCrop := GDIp.CropSkewed(snip.SrcBitmap
                 , snip.Crop.X, snip.Crop.Y, snip.Crop.W, snip.Crop.H
                 , pvx, pvy, snip.Skew, snip.TransColor)
    }
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
    physBorder := snip.HasBorder ? Round(bw * scale) : 0
    totalW     := newW + physBorder * 2
    totalH     := newH + physBorder * 2

    ; WM_SETREDRAW off — on BOTH windows, which is the fix for the resize flicker.
    ;
    ; WM_SETREDRAW is per-window: silencing only the parent leaves the Picture
    ; free to repaint itself when SetWindowPos resizes it below, and a SS_BITMAP
    ; static fills whatever its bitmap does not cover with its background brush.
    ; For a bordered snip that brush is the BORDER COLOUR, and the bitmap does
    ; not cover the control for the moment between "control is now the new size"
    ; and "control now has the new bitmap" — so every frame of the drag painted
    ; one border-coloured flash through the image. Silencing the child collapses
    ; that pair of intermediate paints into nothing; the single RedrawWindow at
    ; the end then paints the finished state once.
    ;
    ; This is also why panning never flickered: RenderSnipFast changes no window
    ; sizes, so the child has no intermediate state to paint.
    DllCall('SendMessage', 'Ptr', hwnd,       'UInt', 0x000B, 'Ptr', 0, 'Ptr', 0)
    DllCall('SendMessage', 'Ptr', g.Pic.Hwnd, 'UInt', 0x000B, 'Ptr', 0, 'Ptr', 0)

    if snip.HasBorder {
        ; Assigning BackColor rebuilds the brush and invalidates the window, so
        ; doing it unconditionally added a full erase to every drag frame for a
        ; colour that cannot change mid-drag. Compare against what the Gui
        ; already holds rather than caching it on the snip: BackColor is written
        ; from half a dozen places (RenderSnip, the border-colour setter, the
        ; border toggle), and a cache would go stale behind every one of them.
        ; If the comparison ever fails to match types it simply assigns, which is
        ; the old behaviour — the fallback is the previous cost, not a bug.
        if (g.BackColor != bcol)
            g.BackColor := Format('0x{:06X}', bcol)
        g.MarginX := bw, g.MarginY := bw
    }
    ; Picture FIRST, then the window. The order matters now that the shadow and
    ; the size-sync handler both judge a snip by "window = image + 2 * border":
    ; sizing the window first would leave that briefly false, and WM_WINDOWPOS-
    ; CHANGED fires inside the call, so both would see a snip mid-flight. Doing
    ; the child first means the only message either of them ever sees carries a
    ; consistent snip. Redraws are suppressed here, so the moment where the child
    ; is larger than its parent is never painted.
    DllCall('SetWindowPos', 'Ptr', g.Pic.Hwnd, 'Ptr', 0,
            'Int', physBorder, 'Int', physBorder, 'Int', newW, 'Int', newH, 'UInt', 0x0014)
    DllCall('SetWindowPos', 'Ptr', hwnd, 'Ptr', 0,
            'Int', winX, 'Int', winY, 'Int', totalW, 'Int', totalH, 'UInt', 0x0014)
    hBitmap := GDIp.CreateHBITMAPFromBitmap(display)
    GDIp.DisposeImage(display)
    oldHbm := SendMessage(0x0172, 0, hBitmap, g.Pic.Hwnd)   ; STM_SETIMAGE
    if oldHbm
        DllCall('DeleteObject', 'Ptr', oldHbm)

    ; Redraw back on, child first so it is ready to paint when the parent's
    ; RedrawWindow reaches it. RDW_ERASE stays in the flags — a snip that GREW
    ; has newly exposed frame that genuinely needs filling — and is now safe to
    ; keep, because WS_CLIPCHILDREN confines that erase to the frame.
    DllCall('SendMessage', 'Ptr', g.Pic.Hwnd, 'UInt', 0x000B, 'Ptr', 1, 'Ptr', 0)
    DllCall('SendMessage', 'Ptr', hwnd,       'UInt', 0x000B, 'Ptr', 1, 'Ptr', 0)
    DllCall('RedrawWindow', 'Ptr', hwnd, 'Ptr', 0, 'Ptr', 0, 'UInt', 0x0085)   ; INVALIDATE|ERASE|ALLCHILDREN

    if (snip.HasBorder && Bevel3D && bw <= Bevel3DMaxThickness)
        DrawSnipBevel(g, bcol, bw, BevelStrengthFor(hwnd), BevelDarknessFor(hwnd))
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

    ; Take the in-place path when it applies. RenderSnip DESTROYS and recreates
    ; the Picture control; the replacement paints itself the instant it is added,
    ; before the window has been resized around it, so a held-down arrow key
    ; flickers for the same reason a drag used to. RenderSnipResize reuses the
    ; control, so there is no such moment.
    ;
    ; Gated to RenderSnipResize's documented precondition — upright and unskewed,
    ; where the display size is exactly the crop size. Anything else (rotated,
    ; straightened) still goes the long way round.
    ;
    ; The geometry below reproduces RenderSnip's centring exactly, so the
    ; keystroke still grows the snip symmetrically about its centre rather than
    ; suddenly anchoring a corner.
    if (Mod(snip.Angle, 360) = 0 && snip.Skew = 0) {
        scale      := A_ScreenDPI / 96
        physBorder := snip.HasBorder ? Round(SnipBorderW(snip) * scale) : 0
        rect := Buffer(16, 0)
        DllCall('GetWindowRect', 'Ptr', hwnd, 'Ptr', rect)
        curL := NumGet(rect, 0, 'Int'), curT := NumGet(rect,  4, 'Int')
        curR := NumGet(rect, 8, 'Int'), curB := NumGet(rect, 12, 'Int')
        totalW := nw + physBorder * 2,  totalH := nh + physBorder * 2
        RenderSnipResize(snip, (curL + curR) // 2 - totalW // 2
                             , (curT + curB) // 2 - totalH // 2)
        return
    }
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
        ; Add-on entry points are called through the %name%() dynamic form on
        ; purpose.  A DIRECT call to a function that might not exist is a
        ; LOAD-TIME error in v2, which would defeat the opt-out arrangement —
        ; deleting SnipOCR.ahk or SnipAI.ahk would stop the whole script from
        ; loading instead of just dropping the menu items.  Nothing can reach
        ; these cases when the module is absent anyway, because the items are
        ; only added when the module's config class exists.
        case 'Copy Text (Windows)':     addOnFn := 'SnipOcrWindowsText', %addOnFn%(TargetHwnd)
        case 'Copy Text (PaddleOCR)':   addOnFn := 'SnipOcrPaddleText',  %addOnFn%(TargetHwnd)
        case 'Copy Table (PaddleOCR)':  addOnFn := 'SnipOcrPaddleTable', %addOnFn%(TargetHwnd)
        case 'Copy Text (AI)':          addOnFn := 'SnipAiCopyText',     %addOnFn%(TargetHwnd)
        case 'Copy Table (AI)':         addOnFn := 'SnipAiCopyTable',    %addOnFn%(TargetHwnd)
        case 'Ask AI About Snip…':      addOnFn := 'SnipAiAsk',          %addOnFn%(TargetHwnd)
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
        case 'Settings…':               LaunchSettingsManager()
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
    ; edge stays anchored. Checked BEFORE markup so Alt is the unambiguous
    ; override: it resizes from an edge even when a drawing tool is active and
    ; would otherwise swallow the click.
    if GetKeyState('Alt', 'P') {
        edge := SnipEdgeAtCursor(snipHwnd)
        if (edge != '') {
            SnipResizeDrag(snipHwnd, edge)
            return
        }
    }
    ; Markup gets first refusal on the click.  It returns TRUE only when it
    ; actually used the press (drawing, or grabbing an object/handle); a click
    ; on empty canvas with the Select tool comes back FALSE and falls through to
    ; the edge-resize and window-move below, so the drag-to-move muscle memory
    ; survives markup mode.  Everything is behind IsSet(MarkupCfg), so with the
    ; module deleted this is one variable test.
    if IsSet(MarkupCfg) {
        markupClickFn := 'MarkupOnLButton'
        if %markupClickFn%(snipHwnd)
            return
    }
    ; Bare press on an edge/corner = resize too, but NOT while a markup session
    ; owns this snip. Markup's contract makes the frame the snip's drag-to-move
    ; handle (see MarkupHitBorder: a plain press on the frame is declined
    ; precisely so the move below happens), and with a fat border that's the best
    ; handle an annotated snip has — the image itself is drawing canvas. So while
    ; annotating, the frame keeps meaning "move" and resizing wants Alt (above);
    ; WM_SETCURSOR_RESIZE stays quiet to match, so the cursor never promises a
    ; resize that this branch won't perform.
    ;
    ; Everywhere else the resize arrow shows on any edge hover with no modifier
    ; held, so a plain drag from there has to do what the arrow says.
    if !SnipMarkupOnSnip(snipHwnd) {
        edge := SnipEdgeAtCursor(snipHwnd)
        if (edge != '') {
            SnipResizeDrag(snipHwnd, edge)
            return
        }
    }
    PostMessage(0xA1, 2, , snipHwnd)   ; WM_NCLBUTTONDOWN, HTCAPTION → move
}

; True when SnipMarkup.ahk is present AND has an open markup session on this
; snip. The module stays optional in the usual two ways: IsSet(MarkupCfg) means
; a missing module costs one variable test, and the dynamic-name call is wrapped
; in try so an OLDER SnipMarkup.ahk without this hook degrades to false (bare
; edge-drag resize stays on) instead of throwing.
SnipMarkupOnSnip(snipHwnd) {
    if !IsSet(MarkupCfg)
        return false
    fnSession := 'MarkupSessionOn'
    try
        return %fnSession%(snipHwnd)
    catch
        return false
}

; When the cursor is over a snip's edge/corner, show the matching resize cursor —
; no modifier needed, the way a normal resizable window behaves. This is
; PER-WINDOW (SetCursor on our own window only) — deliberately NOT
; SetSystemCursor — so there's nothing to own, restore, or leave stuck: the next
; WM_SETCURSOR (any mouse move off the edge) falls through to the default arrow
; on its own. Returns 1 to tell Windows we handled it (suppresses the default
; arrow); returns nothing to allow default.
;
; The arrow is a promise, so it's shown only where a bare drag will actually
; keep it — which is why a snip with a markup session open gets no arrow: there
; the frame is markup's drag-to-move handle and resizing wants Alt. Same test on
; both sides, so the cursor and WM_LBUTTONDOWN can't disagree.
WM_SETCURSOR_RESIZE(wParam, lParam, msg, hwnd) {
    global guiSnips
    snipHwnd := guiSnips.Has(hwnd) ? hwnd : DllCall("GetParent", "Ptr", hwnd, "Ptr")
    if !guiSnips.Has(snipHwnd)
        return
    if SnipMarkupOnSnip(snipHwnd)
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
    global guiSnips, EdgeGrabZone
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
    z := Max(EdgeGrabZone, Round(SnipBorderW(snip) * scale))
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
;
; `btn` is which button the drag is held with — 'LButton' for the edge drag
; started from WM_LBUTTONDOWN, 'RButton' for the Alt+right-drag. It only changes
; which key the loop watches; everything else about the drag is identical, which
; is the whole point of sharing one function between the two gestures.
SnipResizeDrag(snipHwnd, edge, btn := 'LButton') {
    global guiSnips
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
    physBorder := snip.HasBorder ? Round(SnipBorderW(snip) * scale) : 0
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

    while GetKeyState(btn, 'P') {
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

; Resize by cursor TRAVEL rather than by grabbing an edge — the Alt+right-drag.
;
; The visible top-left corner is nailed down and the size follows the cursor:
; total travel since the press, divided by ResizeDragDivisor, added to the crop
; size the snip had when the drag began. Measuring from the START each frame
; (rather than accumulating per-frame deltas the way the pan does) is what keeps
; it exact — no rounding drift over a long drag, and putting the cursor back
; where it started puts the snip back at its original size.
;
; The pan needs accumulation because PanSnipRegionFast moves the crop by a step;
; here the crop is recomputed absolutely every frame, so from-start is both
; simpler and better behaved.
;
; Flips: the visible top-left maps to a different master corner once an axis is
; flipped, so the ANCHORED master edge changes with it. Unflipped, the crop's X
; is fixed and width grows to the right; flipped, the crop's right master edge
; (X+W) is fixed and X slides as the width changes. Same for Y/H under FlipV.
; Angle is 0 here — SnipAltRightButton gates on it.
SnipResizeDragRelative(snipHwnd) {
    global guiSnips, ResizeDragDivisor
    static MINSZ := 8
    if !guiSnips.Has(snipHwnd)
        return
    snip := guiSnips[snipHwnd]
    if !(snip.HasProp('SrcBitmap') && snip.SrcBitmap)
        return

    ; Start geometry (physical px). The window's top-left never moves during this
    ; drag, so it's read once and reused as the render origin every frame.
    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', snipHwnd, 'Ptr', rect)
    winL := NumGet(rect, 0, 'Int'), winT := NumGet(rect, 4, 'Int')
    scale      := A_ScreenDPI / 96
    physBorder := snip.HasBorder ? Round(SnipBorderW(snip) * scale) : 0
    imgL := winL + physBorder, imgT := winT + physBorder

    sc := { X: snip.Crop.X, Y: snip.Crop.Y, W: snip.Crop.W, H: snip.Crop.H }   ; start crop

    ; Fixed master edges, chosen by flip state (see the comment block above).
    anchorMX := snip.FlipH ? sc.X + sc.W : sc.X
    anchorMY := snip.FlipV ? sc.Y + sc.H : sc.Y

    pt := Buffer(8, 0)
    DllCall('GetCursorPos', 'Ptr', pt)
    startX := NumGet(pt, 0, 'Int'), startY := NumGet(pt, 4, 'Int')

    divisor := Max(1, ResizeDragDivisor)
    ResizeDimLabels('update', imgL, imgT, sc.W, sc.H)

    while GetKeyState('RButton', 'P') {
        if !guiSnips.Has(snipHwnd) {          ; snip closed mid-gesture — bail cleanly
            ResizeDimLabels('hide')
            return
        }
        DllCall('GetCursorPos', 'Ptr', pt)
        mx := NumGet(pt, 0, 'Int'), my := NumGet(pt, 4, 'Int')

        nw := Max(MINSZ, sc.W + Round((mx - startX) / divisor))
        nh := Max(MINSZ, sc.H + Round((my - startY) / divisor))

        ; Clamp to what the frozen master can actually supply, measured from the
        ; anchored edge — growing past it would show nothing but empty pixels.
        nw := snip.FlipH ? Min(nw, anchorMX) : Min(nw, snip.MasterW - anchorMX)
        nh := snip.FlipV ? Min(nh, anchorMY) : Min(nh, snip.MasterH - anchorMY)
        nw := Max(MINSZ, nw), nh := Max(MINSZ, nh)
        nx := snip.FlipH ? anchorMX - nw : anchorMX
        ny := snip.FlipV ? anchorMY - nh : anchorMY

        ; No change this frame — skip the re-render.
        if (nx = snip.Crop.X && ny = snip.Crop.Y && nw = snip.Crop.W && nh = snip.Crop.H) {
            Sleep 8
            continue
        }
        snip.Crop.X := nx, snip.Crop.Y := ny, snip.Crop.W := nw, snip.Crop.H := nh
        RenderSnipResize(snip, winL, winT)
        ResizeDimLabels('update', imgL, imgT, nw, nh)
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
    global guiSnips, Bevel3D, Bevel3DMaxThickness
    static lastFire := Map()
    if !Bevel3D
        return
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !snip.HasBorder
        return
    ; Per-snip now: a frame widened past Bevel3DMaxThickness loses its bevel
    ; while its neighbours keep theirs.
    bw := SnipBorderW(snip), bcol := SnipBorderColor(snip)
    if (bw > Bevel3DMaxThickness)
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
    SetTimer(() => DrawSnipBevel(snip.GuiObj, bcol, bw, BevelStrengthFor(hwnd), BevelDarknessFor(hwnd)), -1)
}

; WM_ACTIVATE fires on both the window gaining focus AND the one losing it.
; WM_PAINT isn't reliably sent to the window that just lost focus, so without
; this hook a snip could keep its "active" bevel strength after focus moves
; away. wParam low word: 0 = deactivated, nonzero = activated — either way
; we just need to repaint with whatever strength is now correct for hwnd.
WM_ACTIVATE_BEVEL(wParam, lParam, msg, hwnd) {
    global guiSnips, Bevel3D, Bevel3DMaxThickness
    if !Bevel3D
        return
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !snip.HasBorder
        return
    bw := SnipBorderW(snip), bcol := SnipBorderColor(snip)
    if (bw > Bevel3DMaxThickness)
        return
    isCardinal := (snip.Angle = 0 || snip.Angle = 90 || snip.Angle = 180 || snip.Angle = 270)
    if !isCardinal
        return
    SetTimer(() => DrawSnipBevel(snip.GuiObj, bcol, bw, BevelStrengthFor(hwnd), BevelDarknessFor(hwnd)), -1)
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

; ── Per-snip border accessors ─────────────────────────────────────────────────
; A snip's frame colour and width live ON THE SNIP (see SnipArea), seeded from
; the [SnipWindow] defaults. These two readers exist so every consumer gets the
; same fallback in one place: any snip record built without the properties (an
; older module, a future one) still renders with the script-wide default rather
; than throwing. Width is logical px, matching BorderThickness; colour is a
; plain 0xRRGGBB integer.
SnipBorderW(snip) {
    global BorderThickness
    return (snip.HasProp('BorderW') && snip.BorderW >= 1)
         ? snip.BorderW : Max(1, Integer(BorderThickness))
}

SnipBorderColor(snip) {
    global BorderColor
    return snip.HasProp('BorderColor') ? ColorToHex(snip.BorderColor)
                                       : ColorToHex(BorderColor)
}

; Change a snip's frame colour and/or width at runtime.
;
; Pass '' for either to leave it alone. This is the generalisation of what
; ToggleSnipBorder always did for the on/off case: the WINDOW has to grow or
; shrink by the width delta while the IMAGE stays exactly where it is, which
; means moving the top-left out by the delta and adding twice the delta to the
; size. Doing it here rather than via RenderSnip keeps the crop, the display
; bitmap and any markup composition untouched — only the frame changes.
;
; Returns true when something actually changed.
SetSnipBorder(hwnd, newColor := '', newW := '') {
    global guiSnips, Bevel3D, Bevel3DMaxThickness
    if !guiSnips.Has(hwnd)
        return false
    snip := guiSnips[hwnd]
    g    := snip.GuiObj

    oldW   := SnipBorderW(snip)
    oldCol := SnipBorderColor(snip)
    ; Clamp rather than allow 0: "no frame" is the Border menu item's job, and
    ; letting the width reach 0 would give two different ways to say it.
    wantW   := (newW = '')     ? oldW   : Max(1, Integer(newW))
    wantCol := (newColor = '') ? oldCol : ColorToHex(newColor)
    if (wantW = oldW && wantCol = oldCol)
        return false

    snip.BorderW     := wantW
    snip.BorderColor := wantCol

    ; A frame is only actually ON the window when the snip has one AND sits at a
    ; cardinal angle (RenderSnip suppresses it otherwise). When it isn't, we've
    ; recorded the new values and there is no geometry to touch — the next
    ; RenderSnip back to upright will pick them up.
    isCardinal := (Mod(snip.Angle, 90) = 0)
    if !(snip.HasBorder && isCardinal)
        return true

    scale   := A_ScreenDPI / 96
    oldPhys := Round(oldW  * scale)
    newPhys := Round(wantW * scale)
    delta   := newPhys - oldPhys

    g.BackColor := Format('0x{:06X}', wantCol)
    if delta {
        g.MarginX := wantW, g.MarginY := wantW
        g.Pic.Move(wantW, wantW)          ; logical px — the Gui has +DPIScale

        rect := Buffer(16, 0)
        DllCall('GetWindowRect', 'Ptr', hwnd, 'Ptr', rect)
        curL := NumGet(rect,  0, 'Int'), curT := NumGet(rect,  4, 'Int')
        curR := NumGet(rect,  8, 'Int'), curB := NumGet(rect, 12, 'Int')
        DllCall('SetWindowPos', 'Ptr', hwnd, 'Ptr', 0
              , 'Int', curL - delta, 'Int', curT - delta
              , 'Int', (curR - curL) + delta * 2, 'Int', (curB - curT) + delta * 2
              , 'UInt', 0x0014)           ; SWP_NOZORDER | SWP_NOACTIVATE
        SetLayeredWinAttribs(hwnd, snip.TransColor, snip.Alpha)
    }

    ; Force the flat BackColor fill FIRST. That is what erases a bevel the frame
    ; has just outgrown — WM_PAINT_BEVEL only declines to draw a new one, it
    ; can't rub out the pixels already on the window.
    WinRedraw(hwnd)
    if (Bevel3D && wantW <= Bevel3DMaxThickness)
        DrawSnipBevel(g, wantCol, wantW, BevelStrengthFor(hwnd), BevelDarknessFor(hwnd))
    return true
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
    ; Clear to the shadow color at alpha 0 so blurring only feathers the ALPHA
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
    snip := guiSnips[hwnd]
    ; An outside tool may have just stretched this window past what the frozen
    ; master can fill, in which case SyncSnipToWindowSize is about to put it
    ; back. Painting a shadow to that transient size is what left an oversized
    ; shadow behind: the picture and border stopped at the master's limit, the
    ; shadow kept following the window. So skip while the invariant is broken —
    ; the repair updates the shadow itself once the geometry is settled.
    gm := SnipGeom(snip)
    if (gm && !gm.OK)
        return
    UpdateSnipShadow(snip)
}

; Measure a snip's window against the invariant it always holds internally:
; window = image + 2 * border. Returns 0 when the geometry can't be read (a
; Picture control being swapped, a window already gone), which callers treat as
; "don't second-guess it" rather than as a failure.
SnipGeom(snip) {
    hwnd := snip.GuiObj.Hwnd
    if !DllCall('IsWindow', 'Ptr', hwnd, 'Int')
        return 0
    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', hwnd, 'Ptr', rect)
    L := NumGet(rect, 0, 'Int'), T := NumGet(rect,  4, 'Int')
    W := NumGet(rect, 8, 'Int') - L
    H := NumGet(rect, 12, 'Int') - T
    try {
        if !DllCall('GetWindowRect', 'Ptr', snip.GuiObj.Pic.Hwnd, 'Ptr', rect)
            return 0
    } catch
        return 0
    picW := NumGet(rect, 8, 'Int') - NumGet(rect, 0, 'Int')
    picH := NumGet(rect, 12, 'Int') - NumGet(rect, 4, 'Int')
    if (picW < 1 || picH < 1)
        return 0
    scale      := A_ScreenDPI / 96
    isCardinal := (Mod(snip.Angle, 90) = 0)
    b := (snip.HasBorder && isCardinal) ? Round(SnipBorderW(snip) * scale) : 0
    wantW := picW + b * 2,  wantH := picH + b * 2
    return { X: L, Y: T, W: W, H: H, WantW: wantW, WantH: wantH
           , OK: (W = wantW && H = wantH) }
}

; ── External resize sync ──────────────────────────────────────────────────────
; A snip's window is always exactly image + 2 * border. Nothing inside ScreenSnip
; can break that — but an OUTSIDE tool can, because a snip is just a window and
; anybody's WinMove will resize it. What that used to produce was the giveaway
; symptom: the picture stayed put and the bottom/right border grew fat (or got
; chopped), because the Gui's BackColor was filling space the Picture control
; never claimed.
;
; So rather than teaching every possible resizer about snips, the snip watches
; its own geometry and repairs the invariant. Any external resize is read as a
; re-crop of the frozen master — the only thing "bigger" can mean here, since a
; snip is always 1:1 with the pixels it captured and never scales.
;
; This handler shares WM_WINDOWPOSCHANGED with the shadow one (AHK allows
; several callbacks per message); it deliberately does NOT do the work inline:
;   * SWP_NOSIZE filters out plain drags, which are most of this traffic.
;   * The repair itself resizes the window, which would re-enter us.
;   * ScreenSnip's own renders briefly leave window and Picture out of step
;     (RenderSnipResize moves the window before the child), and a drag loop
;     fires hundreds of these.
;
; Throttled rather than debounced, and the difference matters: an outside
; resizer holds the mouse down and calls WinMove continuously, so a pure
; debounce would never fire until the drag ENDED — the snip would sit there
; visibly broken for the whole gesture and only heal on release. Throttling
; repairs it about twenty times a second, so the picture grows under the cursor.
; The trailing timer is still armed as well, to catch the last frame after the
; flurry stops.
WM_WINDOWPOSCHANGED_SIZESYNC(wParam, lParam, msg, hwnd) {
    global guiSnips
    static pending := Map(), last := Map()
    if !guiSnips.Has(hwnd)
        return
    ; WINDOWPOS: hwnd, hwndInsertAfter (two pointers), then x, y, cx, cy as
    ; four ints — so flags sits at 2 pointers + 16 bytes, on either bitness.
    ; SWP_NOSIZE (0x1) means this was a move, so the invariant can't have
    ; broken and there is nothing to check.
    if (lParam && (NumGet(lParam, A_PtrSize * 2 + 16, 'UInt') & 0x0001))
        return
    ; One stable BoundFunc per window, or every message would stack a NEW timer
    ; instead of resetting the existing one.
    if !pending.Has(hwnd)
        pending[hwnd] := SyncSnipToWindowSize.Bind(hwnd), last[hwnd] := 0
    now := A_TickCount
    if (now - last[hwnd] >= 50) {
        last[hwnd] := now
        SetTimer(pending[hwnd], -1)              ; keep up with the drag
    } else
        SetTimer(pending[hwnd], -60)             ; and settle once it stops
}

; Put the window back in agreement with the image, by re-cropping the master to
; whatever size the window has been given. Anchors the top-left, matching what
; a bottom-right resize gesture means (and what MoveResizeTools.ahk does).
SyncSnipToWindowSize(hwnd) {
    global guiSnips
    static busy := false
    if (busy || !guiSnips.Has(hwnd))
        return
    snip := guiSnips[hwnd]
    if !(snip.HasProp('SrcBitmap') && snip.SrcBitmap)
        return
    mm := 0
    try mm := WinGetMinMax('ahk_id ' hwnd)
    if mm                                        ; min/maximised — not our geometry
        return

    gm := SnipGeom(snip)
    if (!gm || gm.OK)                            ; unreadable, or intact — the usual case
        return

    busy := true
    try {
        ; Only an upright snip can honour the resize: at 90/180/270 the window
        ; box is the ROTATED bitmap, so window width isn't crop width and there
        ; is no sane mapping. Same for a non-cardinal tilt. Put it back instead,
        ; which at least never leaves a lopsided frame on screen.
        if (Mod(snip.Angle, 360) != 0) {
            SnipForceWinSize(hwnd, gm)
            return
        }

        c := snip.Crop
        SnipGrowAxis(c.X, c.W, gm.W - gm.WantW, snip.MasterW, snip.FlipH, &nx, &nw)
        SnipGrowAxis(c.Y, c.H, gm.H - gm.WantH, snip.MasterH, snip.FlipV, &ny, &nh)
        if (nx = c.X && ny = c.Y && nw = c.W && nh = c.H) {
            ; Clamped solid — already showing everything the frozen master holds
            ; in that direction. Snap the window back so the stretch doesn't
            ; survive as a fat border.
            SnipForceWinSize(hwnd, gm)
            return
        }
        c.X := nx, c.Y := ny, c.W := nw, c.H := nh
        ; RenderSnipResize sets the window to the exact right size for the new
        ; crop, so a partially-clamped resize self-corrects with no extra work.
        RenderSnipResize(snip, gm.X, gm.Y)
        ; Explicitly, rather than trusting the WM_WINDOWPOSCHANGED that the line
        ; above raises: that message arrives while this monitor is still on the
        ; stack, and a message monitor already running is not re-entered. Calling
        ; it here makes the shadow's correctness independent of that timing.
        UpdateSnipShadow(snip)
    } finally {
        busy := false
    }
}

; Put a snip's window back to the size its image and border actually require,
; leaving the top-left where it is, and bring the shadow with it.
SnipForceWinSize(hwnd, gm) {
    global guiSnips
    DllCall('SetWindowPos', 'Ptr', hwnd, 'Ptr', 0
          , 'Int', gm.X, 'Int', gm.Y, 'Int', gm.WantW, 'Int', gm.WantH
          , 'UInt', 0x0014)                      ; SWP_NOZORDER | SWP_NOACTIVATE
    if guiSnips.Has(hwnd)
        UpdateSnipShadow(guiSnips[hwnd])
}

; Resolve one axis of a re-crop that grew (or shrank) by d pixels at its FAR
; edge in DISPLAY space — the right edge horizontally, the bottom vertically.
;
; The flip is the only subtlety: on a flipped snip the display's far edge is the
; master's NEAR edge, so growing to the right means extending the crop leftwards
; in master coordinates. Same reasoning as the anchor maths in SnipResizeDrag.
SnipGrowAxis(origin, len, d, masterLen, flipped, &newOrigin, &newLen) {
    static MINSZ := 8
    far := origin + len                          ; master coord of the fixed edge
    if flipped {
        newOrigin := origin - d
        newOrigin := Max(0, Min(newOrigin, far - MINSZ))
        newLen    := far - newOrigin
    } else {
        newOrigin := origin
        newLen    := Max(MINSZ, Min(len + d, masterLen - origin))
    }
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
    global guiSnips, SnipMenu
    if !guiSnips.Has(Hwnd)
        return
    snip := guiSnips[Hwnd]
    g    := snip.GuiObj
    bw   := SnipBorderW(snip), bcol := SnipBorderColor(snip)

    scale      := A_ScreenDPI / 96
    physBorder := Round(bw * scale)

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
        g.BackColor := Format('0x{:06X}', bcol)
        g.MarginX := bw, g.MarginY := bw
        g.Pic.Move(bw, bw)
        newW := curW + physBorder * 2
        newH := curH + physBorder * 2
        newX := curL - physBorder
        newY := curT - physBorder
    }

    DllCall('SetWindowPos', 'Ptr', Hwnd, 'Ptr', 0,
            'Int', newX, 'Int', newY, 'Int', newW, 'Int', newH,
            'UInt', 0x0014)   ; SWP_NOZORDER | SWP_NOACTIVATE
    SetLayeredWinAttribs(Hwnd, snip.TransColor, snip.Alpha)
    WinRedraw(Hwnd)
    global Bevel3D, Bevel3DMaxThickness
    if (snip.HasBorder && Bevel3D && bw <= Bevel3DMaxThickness)
        DrawSnipBevel(g, bcol, bw, BevelStrengthFor(Hwnd), BevelDarknessFor(Hwnd))
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

; Transparent defaults to '' rather than a number so a caller can simply omit
; it and get the user's SelectionOverlayAlpha, without that value having to be
; repeated at every call site.
SelectScreenRegion(Key, Color := 'Lime', Transparent := '') {
    global SelectionOverlayAlpha
    if (Transparent = '')
        Transparent := SelectionOverlayAlpha
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
    ; inside it. (cx, cy) is supplied by the caller as the snip's SkewPivot: it's
    ; set to the crop centre when a straighten begins from level and then held
    ; FIXED while the skew is non-zero. Being near the crop keeps a 1° tilt a 1°
    ; tilt rather than a wide sideways sweep; being fixed is what lets panning
    ; slide the frame over one stable rotated image instead of swirling it.
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

; ══════════════════════════════════════════════════════════════════════════════
; OPTIONAL ADD-ON MODULES
; ══════════════════════════════════════════════════════════════════════════════
;
; They all follow one contract:
;
;   - They live in  Resources\  and are included with the *i flag, which means
;     "include only if the file exists".  Delete any of them (or comment out its
;     line here) and ScreenSnip still runs; the feature's menu items are simply
;     left off.
;   - Each declares a class that acts as the presence sentinel, tested with
;     IsSet() where it's needed: OcrCfg, SnipAiCfg, Imgur, WinDetectCfg,
;     ToolTipOptions.
;   - Each is reached through the %name%() dynamic-call form, because a direct
;     call to a function that might not exist is a LOAD-TIME error in v2.
;     ToolTipOptions is the one exception, and only because everything it
;     exposes is a METHOD on the sentinel class itself: ToolTipOptions.Init() is
;     a variable dereference, and an unset variable is a runtime matter, not a
;     load-time one.  The IsSet() guard is doing the same job either way.
;     Do NOT "helpfully" add a `global ToolTipOptions` to InitToolTips() — a
;     global declaration CREATES the variable at load time, and the class
;     declaration in this file then dies with "This class declaration conflicts
;     with an existing global variable."  Reading an undeclared name in an
;     assume-local function already resolves to the global class when it exists.
;   - None contains top-level executable code that needs to RUN, so including
;     them here at the very end of the file is safe.  Note what that actually
;     means: this point is past the end of the auto-execute section, so any
;     top-level statement in an included file is simply never reached.  That is
;     why every one of these modules keeps its state in class statics (which
;     initialise at load time, wherever the class is declared) rather than in
;     top-level assignments — SnipWinDetect.ahk has a WinDetectState class for
;     exactly this reason, and relies on the same rule to keep its standalone
;     self-test inert when included.
;
; In v2 a relative #Include resolves against the folder of the file containing
; the directive — NOT the working directory — so SnipOCR.ahk's own
; "#Include OCR.ahk" finds Descolada's library beside it in Resources\ with no
; path of its own.

; OCR — Windows.Media.Ocr and PaddleOCR-json.  Provides OcrCfg plus
; SnipOcrWindowsText / SnipOcrPaddleText / SnipOcrPaddleTable.  Needs
; Resources\OCR.ahk and/or Resources\PaddleOCR-json\; see its header.
#Include *i Resources\SnipOCR.ahk

; AI vision — provides SnipAiCfg plus SnipAiCopyText / SnipAiAsk.  Sends the
; image to OpenAI and costs money per use; needs an API key in Data\ApiKeys.ini.
; Setup is in its header and in the dialog shown when no key is configured.
#Include *i Resources\SnipAI.ahk

; Imgur upload — provides the Imgur class plus ImgurBuildMenu /
; ImgurUploadSnipBBCode / ShowImgurGui.  Needs a free imgur.com account and a
; Client ID in Data\ApiKeys.ini; setup is documented in its header and in its
; "Client ID…" dialog.
#Include *i Resources\SnipImgur.ahk

; Window highlighting during Freeze Capture — provides WinDetectCfg plus
; WinDetect_Begin / _End / _GetRect / _Cycle, all called from FreezeCapture().
; No dependencies and nothing to configure; settings live in its own header.
#Include *i Resources\SnipWinDetect.ahk

; Tile puzzles — provides PuzzleCfg plus PuzzleBuildSlideMenu /
; PuzzleBuildSwapMenu / PuzzlePlay, called from the two submenus added to
; SnipMenu above.  Cuts a snip into a grid and either removes a tile to slide
; the rest around, or keeps them all and has you swap neighbours.  No
; dependencies; its settings live in the [Puzzle] section of
; Data\snipSettings.ini and fall back to coded defaults when absent.
#Include *i Resources\SnipPuzzle.ahk

; Jigsaw puzzle — provides JigCfg plus JigBuildMenu / JigPlay.  Cuts a snip into
; interlocking shaped pieces that scatter across a table and snap to each other
; when dropped in the right relative position.  No dependencies, and none on
; SnipPuzzle.ahk either; settings live in the [Jigsaw] section of
; Data\snipSettings.ini and fall back to coded defaults when absent.
#Include *i Resources\SnipJigsaw.ahk

; Markup / annotation — provides MarkupCfg plus MarkupBuildMenu and the compose,
; click, escape, export and close hooks called from the seven places in this
; file marked "MARKUP" or guarded by IsSet(MarkupCfg).  Adds rectangles,
; ellipses, lines, arrows, freehand pen, highlighter, text, numbered callouts,
; speech callouts, blur/pixelate redaction and pasted images as EDITABLE objects
; that survive rotate/pan/flip because they are stored in the same master-local
; coordinate space the crop uses.  No dependencies; settings live in the
; [Markup] section of Data\snipSettings.ini and fall back to coded defaults.
#Include *i Resources\SnipMarkup.ahk

; Tooltip styling — bigger, colored, padded tooltips.  Unlike the four above,
; this one isn't a ScreenSnip module at all: it's an unmodified copy of
; ToolTipOptions.ahk by AHK forum member "just me", dropped in as-is so it can
; be replaced wholesale whenever he posts an update.
;   https://www.autohotkey.com/boards/viewtopic.php?t=113308
;
; It provides the ToolTipOptions class, which is its own presence sentinel;
; InitToolTips() near the top of this file tests IsSet(ToolTipOptions) and feeds
; it the TOOLTIP APPEARANCE settings.  Because it works by subclassing the
; tooltip window class rather than by wrapping ToolTip(), NO CALL SITE ANYWHERE
; CHANGES — every ToolTip() in every module, present and future, is styled or
; not depending only on whether this file exists.  Delete it and they all fall
; back to the plain Windows tooltip.
;
; One caveat worth knowing if the file is present but EnhanceToolTips is false:
; merely loading it creates one hidden tooltip window (a class static), which is
; harmless but not literally zero-cost.  Nothing is subclassed until Init() runs.
#Include *i Resources\ToolTipOptions.ahk

