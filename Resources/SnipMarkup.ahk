; ==============================================================================
; SnipMarkup.ahk  —  annotation / markup layer for ScreenSnip
;                       Version Date: 8-28-2026 
; ==============================================================================
;
; An optional add-on on the same contract as SnipOCR / SnipAI / SnipImgur /
; SnipPuzzle: delete this file (or comment out its #Include at the bottom of
; ScreenSnip.ahk) and the MarkupCfg class never comes into existence, so every
; hook in the core is skipped and ScreenSnip runs exactly as it did before.
;
; ── THE ONE BIG IDEA ──────────────────────────────────────────────────────────
;
; ScreenSnip's render pipeline already re-derives everything from source on
; every change:
;
;     SrcBitmap ──crop(Crop)──► pBitmap (upright) ──flips──►──rotate──► display
;
; Markup slots in as one more re-derived layer.  Objects are NEVER baked into
; a bitmap; they live as a plain array on the snip and are re-drawn from scratch
; on every render.  That single decision buys the whole feature:
;
;   - Objects stay selectable and editable forever, which is what the feature
;     request actually asked for.
;   - Pan / resize-region / rotate / flip / straighten all "just work", because
;     the objects are stored in MASTER-LOCAL coordinates (the same space as
;     Crop.X/Crop.Y) and drawn through a GDI+ matrix that mirrors whatever
;     transform chain the snip is currently in.  Pan and the annotations track
;     the pixels they were drawn on.  Rotate and they turn with the image.
;     Shrink the region and they clip at the frame edge.  None of that is code
;     written here — it falls out of using the same coordinate space the crop
;     already uses.
;   - Hit-testing is the same matrix, inverted (GdipInvertMatrix), so editing
;     works at any rotation, not just cardinal ones.  No hand-rolled inverse.
;
; Two objects opt OUT of the rotation part: text and numbered callouts carry
; Upright := true and are drawn after the matrix is reset, at a matrix-mapped
; anchor.  Nobody wants their label mirrored because they flipped the snip.
;
; ── TWO COMPOSITE STAGES ──────────────────────────────────────────────────────
;
; Blur/pixelate is a PIXEL operation on the image; arrows and text are an
; OVERLAY on top of it.  So the compose splits in two, and the core calls us
; twice per render:
;
;   MarkupComposeImage()    onto the upright crop, BEFORE flips/rotation.
;                           Blur + pixelate only.  Redaction lives in image
;                           space, so it stays glued to the pixels it hides.
;
;   MarkupComposeOverlay()  onto the finished display bitmap, AFTER everything.
;                           Every other object type.  Vector art drawn at final
;                           resolution, so it is never resampled by the skew or
;                           rotation pass and text stays crisp.
;
; The side effect of that split is a fixed z-order: blur is always underneath
; every other annotation.  That is also what you want (you don't put an arrow
; under a blur), so it's documented rather than fought.
;
; ── WHAT THE CORE NEEDS ───────────────────────────────────────────────────────
;
; Seven hooks, all guarded by IsSet(MarkupCfg) and all reached through the
; %name%() dynamic-call form, because a DIRECT call to a function that might
; not exist is a LOAD-TIME error in v2 and would defeat the opt-out.  They are
; listed in full in the "CORE HOOKS" comment further down; search ScreenSnip.ahk
; for "SnipMarkup" to find every one of them.
;
; ── SETTINGS ──────────────────────────────────────────────────────────────────
;
; Everything below reads from the [Markup] section of Data\snipSettings.ini via
; the core's SnipCfg()/SnipCfgHex() helpers, so SettingsManager picks them up
; with no extra work.  Every key falls back to a coded default, so an INI with
; no [Markup] section at all is fine.
;
; ==============================================================================

; ── Settings + presence sentinel ──────────────────────────────────────────────
; Statics, not top-level assignments: this file is #Include'd past the end of
; the auto-execute section, so top-level code here would never run.  Class
; statics initialise at load time wherever the class is declared, which is the
; same trick SnipWinDetect.ahk uses.
class MarkupCfg {
    ; Default style for a newly drawn object.  Selecting an object and changing
    ; a control on the palette edits THAT object; changing it with nothing
    ; selected changes these, i.e. what the next object will look like.
    static Color      := SnipCfgHex('Markup', 'Color',      0xE81123)   ; stroke
    static FillColor  := SnipCfgHex('Markup', 'FillColor',  0xFFFFFF)   ; used when Fill is on
    static Thickness  := Integer(SnipCfg('Markup', 'Thickness',  3))
    static FillShapes := Integer(SnipCfg('Markup', 'FillShapes', 0)) ? true : false
    static FontName   :=         SnipCfg('Markup', 'FontName',   'Segoe UI')
    static FontSize   := Integer(SnipCfg('Markup', 'FontSize',   18))

    ; Legibility.  Outline is a thin contrasting halo drawn UNDER each object,
    ; black or white picked from the object's own color luminance (not from the
    ; background — sampling the background is expensive and flickers while you
    ; drag).  A red arrow gets a white halo; a white arrow gets a black one.
    ; This is what stops a red arrow vanishing on a red-ish UI, and it is why
    ; it defaults ON while shadows default OFF.
    static Outline      := Integer(SnipCfg('Markup', 'Outline', 1)) ? true : false
    static OutlineWidth := Integer(SnipCfg('Markup', 'OutlineWidth', 2))

    ; Shadow is decorative, costs a second full draw per object, and the snip
    ; window may already have its own drop shadow.  Off by default, per-object
    ; toggle on the right-click menu.  This is the cheap "hard" shadow — the
    ; shape redrawn in translucent black at an offset — which reads correctly at
    ; screenshot scale without a blur pass.
    static Shadow       := Integer(SnipCfg('Markup', 'Shadow', 0)) ? true : false
    static ShadowOffset := Integer(SnipCfg('Markup', 'ShadowOffset', 2))
    static ShadowAlpha  := Integer(SnipCfg('Markup', 'ShadowAlpha', 110))

    static HighlightAlpha := Integer(SnipCfg('Markup', 'HighlightAlpha', 90))
    static ArrowHeadScale := Float(SnipCfg('Markup', 'ArrowHeadScale', 3.5))

    ; Redaction.  Pixelate is cheaper than a true blur and is the more honest
    ; choice for hiding data, so it is the default.  BlurAmount is the block
    ; size in pixels for pixelate, or the downscale factor for blur.
    static Pixelate   := Integer(SnipCfg('Markup', 'Pixelate', 1)) ? true : false
    static BlurAmount := Integer(SnipCfg('Markup', 'BlurAmount', 10))

    ; Selection chrome.  Drawn into the DISPLAY bitmap only, never into the save
    ; or clipboard bitmap (see MarkupComposeOverlay's wantChrome argument).
    static HandleSize  := Integer(SnipCfg('Markup', 'HandleSize', 7))
    static HandleColor := SnipCfgHex('Markup', 'HandleColor', 0x00A2FF)

    static UndoDepth   := Integer(SnipCfg('Markup', 'UndoDepth', 60))

    ; Palette window.  AutoShow false = hotkey-only operation for people who
    ; know the letters and don't want a second window on screen.
    static PaletteAutoShow := Integer(SnipCfg('Markup', 'PaletteAutoShow', 1)) ? true : false
    static PaletteGap      := Integer(SnipCfg('Markup', 'PaletteGap', 12))
}

; ── Mutable state ─────────────────────────────────────────────────────────────
; One markup session at a time.  Active is the hwnd of the snip being marked up
; (0 = not in markup mode), which is also what the #HotIf context tests, so the
; single-letter tool keys can't leak out onto anything else.
class MarkupState {
    static Active   := 0
    static Tool     := 'select'
    static Palette  := ''         ; Gui object, or '' when never built
    static PalX     := ''         ; remembered palette position for the session
    static PalY     := ''
    static Dragging := false
    static Band     := 0          ; live rubber-band rect (display coords) or 0
    static Ctl      := Map()      ; palette control name → control object

    ; Sels is the real selection — an array, so a group of objects can be moved,
    ; resized and restyled together.  Sel is kept as a one-object view onto it
    ; (first selected, or 0) because most of the code only ever cares about
    ; "is there a selection, and what is the primary one".  Assigning to Sel
    ; REPLACES the whole selection, which is exactly what every existing
    ; single-object call site meant, so nothing had to change to add groups.
    static Sels     := []
    static Sel {
        get => this.Sels.Length ? this.Sels[1] : 0
        set => this.Sels := value ? [value] : []
    }
}

MarkupIsSelected(o) {
    for s in MarkupState.Sels
        if (s = o)
            return true
    return false
}

; Add if absent, remove if present — Shift+click semantics.
MarkupToggleSel(o) {
    for i, s in MarkupState.Sels {
        if (s = o) {
            MarkupState.Sels.RemoveAt(i)
            return
        }
    }
    MarkupState.Sels.Push(o)
}

MarkupSelectAll(hwnd := 0) {
    global guiSnips
    if !hwnd
        hwnd := MarkupState.Active
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !snip.HasProp('Markup')
        return
    MarkupState.Sels := []
    for o in snip.Markup.Objs
        MarkupState.Sels.Push(o)
    MarkupSyncPalette()
    MarkupRender(snip)
}

; Union of every selected object's extent, in master space.  This is the box a
; group resize scales, and the box the group handles sit on.
MarkupSelUnionMaster(&x1, &y1, &x2, &y2) {
    x1 := y1 := x2 := y2 := 0
    first := true
    for o in MarkupState.Sels {
        MarkupBoundsMaster(o, &a1, &b1, &a2, &b2)
        if first
            x1 := a1, y1 := b1, x2 := a2, y2 := b2, first := false
        else
            x1 := Min(x1, a1), y1 := Min(y1, b1), x2 := Max(x2, a2), y2 := Max(y2, b2)
    }
    return !first
}

MarkupSelUnionDisplay(snip, m, &x1, &y1, &x2, &y2) {
    x1 := y1 := x2 := y2 := 0
    first := true
    for o in MarkupState.Sels {
        MarkupBoundsDisplay(snip, o, m, &a1, &b1, &a2, &b2)
        if first
            x1 := a1, y1 := b1, x2 := a2, y2 := b2, first := false
        else
            x1 := Min(x1, a1), y1 := Min(y1, b1), x2 := Max(x2, a2), y2 := Max(y2, b2)
    }
    return !first
}

; A group gets the eight box handles only — no endpoint or tail handles, since
; those belong to one specific object and would be ambiguous across several.
MarkupGroupHandleList(snip, m) {
    hs := []
    if !MarkupSelUnionDisplay(snip, m, &x1, &y1, &x2, &y2)
        return hs
    mx := (x1 + x2) / 2, my := (y1 + y2) / 2
    hs.Push({ Id: 'nw', X: x1, Y: y1 }, { Id: 'n',  X: mx, Y: y1 }
          , { Id: 'ne', X: x2, Y: y1 }, { Id: 'e',  X: x2, Y: my }
          , { Id: 'se', X: x2, Y: y2 }, { Id: 's',  X: mx, Y: y2 }
          , { Id: 'sw', X: x1, Y: y2 }, { Id: 'w',  X: x1, Y: my })
    return hs
}

; ==============================================================================
; CORE HOOKS  —  the seven things ScreenSnip.ahk calls
; ==============================================================================
;
;  1. SnipMenu build       →  MarkupBuildMenu()        submenu for the snip menu
;  2. BuildDisplayBitmap   →  MarkupComposeImage()     blur, pre-transform
;                          →  MarkupComposeOverlay()   everything else, post
;  3. BuildSaveBitmap      →  same two, wantChrome := false
;  4. WM_LBUTTONDOWN       →  MarkupOnLButton()        claim the click in mode
;  5. Esc hotkey           →  MarkupEscape()           staged escape
;  6. SnipToClipboard      →  MarkupBeforeExport()     drop selection chrome
;  7. CloseSnip            →  MarkupOnSnipClosed()     free per-snip resources
;
; Every one is a no-op when this snip has no markup and markup mode is off, so
; the cost on an un-annotated snip is a property test.

; True when a markup session is running AND its snip is the active window.
; Used as the #HotIf context for every tool key at the bottom of this file, so
; a bare "R" can never fire anywhere else.
MarkupActive() {
    return MarkupState.Active && WinActive('ahk_id ' MarkupState.Active)
}

; The submenu added to SnipMenu.  Built fresh on each call (like ImgurBuildMenu)
; so it is always in step with the current defaults.
; The object operations live here rather than on a right-click-the-object menu
; of their own, because a snip's right-click ALREADY opens SnipMenu — putting
; them on this submenu means no extra hook in the core and no second gesture to
; learn.  They act on whatever is currently selected.
MarkupBuildMenu() {
    m := Menu()
    m.Add('Annotate…`tM',              MarkupMenu_Handler)
    m.Add('Show/Hide Tool Palette`tF3', MarkupMenu_Handler)
    m.Add('')
    m.Add('Paste Image`tCtrl+V',       MarkupMenu_Handler)
    m.Add('Add Image From File…',      MarkupMenu_Handler)
    m.Add('')
    m.Add('Select All`tCtrl+A',        MarkupMenu_Handler)
    m.Add('Edit Text…`tF2',            MarkupMenu_Handler)
    m.Add('Duplicate`tCtrl+D',         MarkupMenu_Handler)
    m.Add('Bring to Front`tCtrl+PgUp', MarkupMenu_Handler)
    m.Add('Send to Back`tCtrl+PgDn',   MarkupMenu_Handler)
    m.Add('Delete Selected`tDel',      MarkupMenu_Handler)
    m.Add('')
    m.Add('Undo`tCtrl+Z',              MarkupMenu_Handler)
    m.Add('Redo`tCtrl+Y',              MarkupMenu_Handler)
    m.Add('Clear All Markup',          MarkupMenu_Handler)
    return m
}

MarkupMenu_Handler(ItemName, ItemPos, *) {
    global SnipMenu
    hwnd := SnipMenu._targetHwnd
    switch StrSplit(ItemName, "`t")[1] {
        case 'Annotate…':              MarkupBegin(hwnd)
        case 'Show/Hide Tool Palette': MarkupPaletteMenuItem(hwnd)
        case 'Paste Image':            MarkupPasteImage(hwnd)
        case 'Add Image From File…':   MarkupImageFromFile(hwnd)
        case 'Select All':             MarkupSelectAll(hwnd)
        case 'Edit Text…':             MarkupEditSelText(hwnd)
        case 'Duplicate':              MarkupDuplicateSel(hwnd)
        case 'Bring to Front':         MarkupRaiseSel(hwnd, true)
        case 'Send to Back':           MarkupRaiseSel(hwnd, false)
        case 'Delete Selected':        MarkupDeleteSel(hwnd)
        case 'Undo':                   MarkupUndo(hwnd)
        case 'Redo':                   MarkupRedo(hwnd)
        case 'Clear All Markup':       MarkupClearAll(hwnd)
    }
}

; ── Enter / leave markup mode ─────────────────────────────────────────────────

; Lazily attach the markup record to a snip.  Objs is the object list — the
; single source of truth.  Undo/Redo hold whole-list SNAPSHOTS rather than
; command objects: the objects are small plain records, so a deep copy is
; cheap, and a snapshot stack cannot get out of step with the model the way a
; hand-written undo/redo command pair can.
; Images is a per-snip POOL of GDI+ bitmaps for pasted-image objects; an object
; stores an INDEX into it, never a raw pointer.  That is what makes the snapshot
; undo model safe: several snapshots can reference the same image, nothing has
; to reason about who owns it, and the pool is disposed once when the snip
; closes.  Deleting an image object leaves its slot in the pool (a few bytes and
; one bitmap) rather than invalidating indices held by older snapshots.
MarkupEnsure(snip) {
    if !snip.HasProp('Markup')
        snip.Markup := { Objs: [], Undo: [], Redo: [], NextNum: 1, Images: [] }
    return snip.Markup
}

MarkupBegin(hwnd := 0) {
    global guiSnips
    if !hwnd
        hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    if (MarkupState.Active && MarkupState.Active != hwnd)
        MarkupEnd(false)                       ; retarget: one session at a time

    MarkupEnsure(guiSnips[hwnd])
    MarkupState.Active := hwnd
    MarkupState.Tool   := 'select'
    MarkupState.Sel    := 0
    WinActivate('ahk_id ' hwnd)
    if MarkupCfg.PaletteAutoShow
        MarkupShowPalette()
    MarkupRender(guiSnips[hwnd])
    ToolTip('Markup mode — Esc to leave')
    SetTimer(() => ToolTip(), -1400)
}

; leaveTip=false when we're retargeting or the snip is going away.
MarkupEnd(leaveTip := true) {
    global guiSnips
    hwnd := MarkupState.Active
    MarkupState.Active := 0
    MarkupState.Sel    := 0
    MarkupState.Tool   := 'select'
    MarkupHidePalette()
    if (hwnd && guiSnips.Has(hwnd))
        MarkupRender(guiSnips[hwnd])           ; redraw without selection chrome
    if leaveTip {
        ToolTip('Markup off')
        SetTimer(() => ToolTip(), -900)
    }
}

; Staged Escape, called from the core's Esc hotkey. Returns true when markup
; consumed the keypress, false to let the normal "close this snip" happen.
; The escalation is: deselect → back to the Select tool → leave markup mode →
; (only then) close the snip. That gives a panic key that never destroys work.
MarkupEscape(hwnd) {
    if !MarkupState.Active
        return false
    if (MarkupState.Active != hwnd)
        return false
    global guiSnips
    if MarkupState.Sels.Length {
        MarkupState.Sels := []
        MarkupSyncPalette()
        if guiSnips.Has(hwnd)
            MarkupRender(guiSnips[hwnd])
        return true
    }
    if (MarkupState.Tool != 'select') {
        MarkupSetTool('select')
        return true
    }
    MarkupEnd()
    return true
}

; Called just before the core copies a snip to the clipboard.  The clipboard
; path reads the Picture control's existing HBITMAP (STM_GETIMAGE) rather than
; re-rendering, so selection handles would otherwise be copied along with the
; image.  Dropping the selection and re-rendering first is the whole fix.
MarkupBeforeExport(hwnd) {
    global guiSnips
    if (MarkupState.Active = hwnd && MarkupState.Sels.Length) {
        MarkupState.Sels := []
        MarkupSyncPalette()
        if guiSnips.Has(hwnd)
            MarkupRender(guiSnips[hwnd])
    }
}

; Free anything a snip's markup owns that GDI+ won't collect for us.  Only
; pasted-image objects hold a bitmap; everything else is plain numbers.
MarkupOnSnipClosed(snip, hwnd) {
    if (MarkupState.Active = hwnd) {
        MarkupState.Active := 0
        MarkupState.Sel    := 0
        MarkupHidePalette()
    }
    if !snip.HasProp('Markup')
        return
    ; The image pool is the only thing here GDI+ won't collect for us.  Objects
    ; and undo snapshots are plain records and go with the property.
    for pImg in snip.Markup.Images
        if pImg
            GDIp.DisposeImage(pImg)
    snip.DeleteProp('Markup')
}

MarkupClearAll(hwnd := 0) {
    global guiSnips
    if !hwnd
        hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !snip.HasProp('Markup')
        return
    MarkupPushUndo(snip)
    snip.Markup.Objs := []
    snip.Markup.NextNum := 1
    MarkupState.Sel := 0
    MarkupRender(snip)
}

; ==============================================================================
; COORDINATE SPACE
; ==============================================================================
;
; Objects store MASTER-LOCAL coordinates: the same space as snip.Crop.X/Y, i.e.
; pixels of snip.SrcBitmap (the frozen master snapshot).  Everything else is a
; transform of that space, and every transform is expressed as one GDI+ matrix
; so that neither the drawing code nor the hit-testing code ever does geometry
; by hand.
;
; The chain, in the order it is applied to a point:
;
;   1. master → crop-local     (plain offset, or the Straighten rotation about
;                               SkewPivotOf when Skew ≠ 0 — the exact inverse of
;                               what GDIp.CropSkewed does to the pixels)
;   2. flips                   (mirror inside a cropW × cropH surface)
;   3. rotation                (about the surface centre, into the padded
;                               bounding box GDIp.RotateBitmap produces)
;
; MarkupMatrix builds it in stages so a caller can stop early: the blur pass
; needs stage 1 only (it draws onto the upright crop, before flips/rotation),
; the overlay pass needs all three.
;
; NOTE ON MATRIX ORDER: GDI+ is row-vector, so MatrixOrderAppend (1) means "this
; transform happens AFTER the ones already in the matrix".  Building with Append
; and listing the calls in application order is therefore the readable way round,
; and it is the opposite of the Prepend order GDIp.CropSkewed uses on its
; graphics context.  Don't mix them up.

; Build the master-local → target matrix.  stage is 'crop' (stage 1 only) or
; 'display' (all three).  Caller must GdipDeleteMatrix the result.
MarkupMatrix(snip, stage := 'display') {
    DllCall('gdiplus\GdipCreateMatrix', 'UPtr*', &m := 0)
    if !m
        return 0
    cw := snip.Crop.W, ch := snip.Crop.H

    ; ── 1. master → crop-local ────────────────────────────────────────────────
    if (snip.Skew = 0)
        DllCall('gdiplus\GdipTranslateMatrix', 'UPtr', m
              , 'Float', -snip.Crop.X, 'Float', -snip.Crop.Y, 'Int', 1)
    else {
        SkewPivotOf(snip, &pvx, &pvy)
        DllCall('gdiplus\GdipTranslateMatrix', 'UPtr', m, 'Float', -pvx, 'Float', -pvy, 'Int', 1)
        DllCall('gdiplus\GdipRotateMatrix',    'UPtr', m, 'Float', snip.Skew + 0.0, 'Int', 1)
        DllCall('gdiplus\GdipTranslateMatrix', 'UPtr', m
              , 'Float', pvx - snip.Crop.X, 'Float', pvy - snip.Crop.Y, 'Int', 1)
    }
    if (stage = 'crop')
        return m

    ; ── 2. flips ──────────────────────────────────────────────────────────────
    if snip.FlipH {
        DllCall('gdiplus\GdipScaleMatrix',     'UPtr', m, 'Float', -1.0, 'Float', 1.0, 'Int', 1)
        DllCall('gdiplus\GdipTranslateMatrix', 'UPtr', m, 'Float', cw + 0.0, 'Float', 0.0, 'Int', 1)
    }
    if snip.FlipV {
        DllCall('gdiplus\GdipScaleMatrix',     'UPtr', m, 'Float', 1.0, 'Float', -1.0, 'Int', 1)
        DllCall('gdiplus\GdipTranslateMatrix', 'UPtr', m, 'Float', 0.0, 'Float', ch + 0.0, 'Int', 1)
    }

    ; ── 3. rotation ───────────────────────────────────────────────────────────
    ; Mirrors GDIp.RotateBitmap exactly, INCLUDING its bounding-box rounding, so
    ; an annotation lands on the pixel it was drawn on.  The same formula is
    ; correct for the cardinal angles the core routes through GdipImageRotateFlip
    ; instead — for 90/180/270 the bounding box and the centres coincide, so the
    ; two agree to within the half-pixel difference between a pixel index and a
    ; continuous coordinate.
    angle := Mod(snip.Angle + 360, 360)
    if (angle != 0) {
        rad  := angle * 3.14159265358979 / 180
        sinA := Abs(Sin(rad)), cosA := Abs(Cos(rad))
        nw   := Round(cw * cosA + ch * sinA)
        nh   := Round(cw * sinA + ch * cosA)
        DllCall('gdiplus\GdipTranslateMatrix', 'UPtr', m
              , 'Float', -cw / 2.0, 'Float', -ch / 2.0, 'Int', 1)
        DllCall('gdiplus\GdipRotateMatrix',    'UPtr', m, 'Float', angle + 0.0, 'Int', 1)
        DllCall('gdiplus\GdipTranslateMatrix', 'UPtr', m
              , 'Float', nw / 2.0, 'Float', nh / 2.0, 'Int', 1)
    }
    return m
}

; Push one point through a matrix.
MarkupXform(pMatrix, x, y, &ox, &oy) {
    pt := Buffer(8, 0)
    NumPut('Float', x + 0.0, pt, 0)
    NumPut('Float', y + 0.0, pt, 4)
    DllCall('gdiplus\GdipTransformMatrixPoints', 'UPtr', pMatrix, 'Ptr', pt, 'Int', 1)
    ox := NumGet(pt, 0, 'Float'), oy := NumGet(pt, 4, 'Float')
}

; Display-space point → master-local.  This is the whole of hit-testing's
; geometry: invert the same matrix the drawing used and push the click through
; it.  Works at any rotation because GDI+ does the inverse for us.
MarkupToMaster(snip, dx, dy, &mx, &my) {
    m := MarkupMatrix(snip, 'display')
    if !m {
        mx := dx, my := dy
        return false
    }
    if (DllCall('gdiplus\GdipInvertMatrix', 'UPtr', m) != 0) {
        DllCall('gdiplus\GdipDeleteMatrix', 'UPtr', m)
        mx := dx, my := dy
        return false
    }
    MarkupXform(m, dx, dy, &mx, &my)
    DllCall('gdiplus\GdipDeleteMatrix', 'UPtr', m)
    return true
}

; Master-local point → display space.
MarkupToDisplay(snip, mx, my, &dx, &dy) {
    m := MarkupMatrix(snip, 'display')
    if !m {
        dx := mx, dy := my
        return false
    }
    MarkupXform(m, mx, my, &dx, &dy)
    DllCall('gdiplus\GdipDeleteMatrix', 'UPtr', m)
    return true
}

; Cursor position, in the display-space pixels of a snip's Picture control.
; Read from the control's own screen rect rather than from a WM_ message's
; lParam, because the message can arrive on either the Gui or its Picture child
; and the border/DPI offset differs between them.  One reading, no cases.
MarkupCursorPos(snip, &dx, &dy) {
    CoordMode('Mouse', 'Screen')
    MouseGetPos(&sx, &sy)
    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', snip.GuiObj.Pic.Hwnd, 'Ptr', rect)
    dx := sx - NumGet(rect, 0, 'Int')
    dy := sy - NumGet(rect, 4, 'Int')
}

; Cursor position in master-local coordinates — what every tool actually wants.
MarkupCursorMaster(snip, &mx, &my) {
    MarkupCursorPos(snip, &dx, &dy)
    MarkupToMaster(snip, dx, dy, &mx, &my)
}

; ==============================================================================
; UNDO  (whole-list snapshots)
; ==============================================================================
; Objects are small plain records, so a deep copy of the list costs almost
; nothing and cannot drift out of step with the model the way a hand-written
; command/inverse-command pair can.  Pasted images are referenced by pool INDEX
; (see MarkupEnsure), so copying a record never copies a bitmap.

MarkupCloneObj(o) {
    c := {}
    for k, v in o.OwnProps()
        c.%k% := (v is Array) ? v.Clone() : v
    return c
}

MarkupSnapshot(mk) {
    out := []
    for o in mk.Objs
        out.Push(MarkupCloneObj(o))
    return { Objs: out, NextNum: mk.NextNum }
}

MarkupPushUndo(snip) {
    mk := MarkupEnsure(snip)
    mk.Undo.Push(MarkupSnapshot(mk))
    if (mk.Undo.Length > MarkupCfg.UndoDepth)
        mk.Undo.RemoveAt(1)
    mk.Redo := []                      ; a new edit invalidates the redo branch
}

MarkupUndo(hwnd := 0) {
    global guiSnips
    if !hwnd
        hwnd := MarkupState.Active
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !snip.HasProp('Markup') || !snip.Markup.Undo.Length
        return
    mk := snip.Markup
    mk.Redo.Push(MarkupSnapshot(mk))
    snap := mk.Undo.Pop()
    mk.Objs := snap.Objs, mk.NextNum := snap.NextNum
    MarkupState.Sel := 0
    MarkupSyncPalette()
    MarkupRender(snip)
}

MarkupRedo(hwnd := 0) {
    global guiSnips
    if !hwnd
        hwnd := MarkupState.Active
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]
    if !snip.HasProp('Markup') || !snip.Markup.Redo.Length
        return
    mk := snip.Markup
    mk.Undo.Push(MarkupSnapshot(mk))
    snap := mk.Redo.Pop()
    mk.Objs := snap.Objs, mk.NextNum := snap.NextNum
    MarkupState.Sel := 0
    MarkupSyncPalette()
    MarkupRender(snip)
}

; ==============================================================================
; OBJECT MODEL
; ==============================================================================
;
; One flat record per object.  Geometry is always master-local:
;   rect / ellipse / highlight / blur / image : X1,Y1 → X2,Y2 corners
;   line / arrow                              : X1,Y1 → X2,Y2 endpoints
;   pen                                       : Pts, a flat [x1,y1,x2,y2,...]
;   text / number                             : X1,Y1 anchor (top-left)
;   callout                                   : X1,Y1 → X2,Y2 box + TailX,TailY
;
; Upright is the "don't turn with the image" flag described at the top of this
; file.  It is set for the types whose whole job is to be read.

MarkupNewObj(type) {
    o := { Type:      type
         , X1:        0,   Y1: 0,  X2: 0,  Y2: 0
         , Color:     MarkupCfg.Color
         , FillColor: MarkupCfg.FillColor
         , Fill:      MarkupCfg.FillShapes
         , Thick:     MarkupCfg.Thickness
         , Alpha:     255
         , Outline:   MarkupCfg.Outline
         , Shadow:    MarkupCfg.Shadow
         , Text:      ''
         , FontSize:  MarkupCfg.FontSize
         , FontName:  MarkupCfg.FontName
         , Num:       0
         , TailX:     0,   TailY: 0
         , TailA:     0,   TailB: 0        ; tail base, offsets along the edge
         , ImgIdx:    0
         , Pts:       []
         , Upright:   (type = 'text' || type = 'number' || type = 'callout') }

    if (type = 'highlight') {
        o.Fill  := true
        o.Alpha := MarkupCfg.HighlightAlpha
        o.FillColor := 0xFFF200                 ; classic highlighter yellow
        o.Outline := false
    }
    if (type = 'number')
        o.Fill := true, o.FillColor := o.Color
    if (type = 'callout')
        o.Fill := true, o.FillColor := 0xFFFFFF
    return o
}

; Renumber every numbered callout from 1, in list order.  Called after a delete
; so removing #2 turns 3 and 4 into 2 and 3 rather than leaving a hole — which
; is the entire reason the feature is worth having over plain text labels.
; A manual override set from the object menu survives, because it rewrites Num
; on that object and the next renumber simply overwrites it again; if you want
; a fixed number, use a text object.
MarkupRenumber(mk) {
    n := 0
    for o in mk.Objs
        if (o.Type = 'number')
            o.Num := ++n
    mk.NextNum := n + 1
}

; Delete every selected object.  Walks the list BACKWARDS so removing an item
; can't shift the index of one not yet examined.
MarkupDeleteSel(hwnd := 0) {
    global guiSnips
    if !hwnd
        hwnd := MarkupState.Active
    if (!guiSnips.Has(hwnd) || !MarkupState.Sels.Length)
        return
    snip := guiSnips[hwnd]
    mk   := MarkupEnsure(snip)
    MarkupPushUndo(snip)
    i := mk.Objs.Length
    while (i >= 1) {
        if MarkupIsSelected(mk.Objs[i])
            mk.Objs.RemoveAt(i)
        i--
    }
    MarkupState.Sels := []
    MarkupRenumber(mk)
    MarkupSyncPalette()
    MarkupRender(snip)
}

; Move the whole selection to the front or the back, keeping the objects'
; relative order among themselves.
MarkupRaiseSel(hwnd, toTop) {
    global guiSnips
    if (!guiSnips.Has(hwnd) || !MarkupState.Sels.Length)
        return
    snip := guiSnips[hwnd]
    mk   := MarkupEnsure(snip)
    picked := [], rest := []
    for o in mk.Objs
        MarkupIsSelected(o) ? picked.Push(o) : rest.Push(o)
    if !picked.Length
        return
    MarkupPushUndo(snip)
    out := []
    if toTop {
        for o in rest
            out.Push(o)
        for o in picked
            out.Push(o)
    } else {
        for o in picked
            out.Push(o)
        for o in rest
            out.Push(o)
    }
    mk.Objs := out
    MarkupRenumber(mk)
    MarkupRender(snip)
}

MarkupDuplicateSel(hwnd) {
    global guiSnips
    if (!guiSnips.Has(hwnd) || !MarkupState.Sels.Length)
        return
    snip := guiSnips[hwnd]
    mk   := MarkupEnsure(snip)
    MarkupPushUndo(snip)
    copies := []
    for src in MarkupState.Sels {
        c := MarkupCloneObj(src)
        c.X1 += 12, c.Y1 += 12, c.X2 += 12, c.Y2 += 12
        c.TailX += 12, c.TailY += 12
        if c.Pts.Length {
            i := 1
            while (i <= c.Pts.Length)
                c.Pts[i] += 12, c.Pts[i + 1] += 12, i += 2
        }
        mk.Objs.Push(c)
        copies.Push(c)
    }
    ; The copies become the selection, so a duplicate-then-drag is one gesture.
    MarkupState.Sels := copies
    MarkupRenumber(mk)
    MarkupSyncPalette()
    MarkupRender(snip)
}

; ==============================================================================
; GDI+ DRAWING HELPERS
; ==============================================================================

MarkupARGB(rgb, alpha := 255) => ((alpha & 0xFF) << 24) | (rgb & 0xFFFFFF)

MarkupPen(rgb, alpha, width) {
    DllCall('gdiplus\GdipCreatePen1', 'UInt', MarkupARGB(rgb, alpha)
          , 'Float', Max(0.5, width + 0.0), 'Int', 2, 'UPtr*', &p := 0)   ; 2 = UnitPixel
    if p {
        DllCall('gdiplus\GdipSetPenStartCap', 'UPtr', p, 'Int', 2)        ; 2 = LineCapRound
        DllCall('gdiplus\GdipSetPenEndCap',   'UPtr', p, 'Int', 2)
        DllCall('gdiplus\GdipSetPenLineJoin', 'UPtr', p, 'Int', 2)        ; 2 = LineJoinRound
    }
    return p
}

MarkupBrush(rgb, alpha := 255) {
    DllCall('gdiplus\GdipCreateSolidFill', 'UInt', MarkupARGB(rgb, alpha), 'UPtr*', &b := 0)
    return b
}

MarkupDelPen(p)   => p && DllCall('gdiplus\GdipDeletePen',   'UPtr', p)
MarkupDelBrush(b) => b && DllCall('gdiplus\GdipDeleteBrush', 'UPtr', b)

; The contrasting halo color for an object.  Chosen from the OBJECT'S own color,
; not from the pixels behind it: sampling the background is expensive, and it
; makes the halo flicker between black and white while you drag a shape across
; a busy screenshot.  Perceptual luminance weights, so a saturated red (dark by
; this measure) correctly gets a white halo.
MarkupHalo(rgb) {
    r := (rgb >> 16) & 0xFF, g := (rgb >> 8) & 0xFF, b := rgb & 0xFF
    lum := (0.299 * r + 0.587 * g + 0.114 * b) / 255
    return (lum > 0.55) ? 0x000000 : 0xFFFFFF
}

; AHK v2 has ATan but no ATan2, and arrow heads need the full four quadrants.
MarkupAtan2(y, x) {
    static PI := 3.14159265358979
    if (x > 0)
        return ATan(y / x)
    if (x < 0)
        return ATan(y / x) + ((y >= 0) ? PI : -PI)
    return (y > 0) ? PI / 2 : ((y < 0) ? -PI / 2 : 0)
}

; A shared 8x8 scratch context, only ever used for GdipMeasureString.  Text
; metrics are needed during hit-testing, which runs on every mouse move, so
; building a bitmap for each measurement would be silly.
MarkupMeasureGfx() {
    static pGfx := 0
    if !pGfx {
        DllCall('gdiplus\GdipCreateBitmapFromScan0'
              , 'Int', 8, 'Int', 8, 'Int', 0, 'Int', 0x26200A, 'Ptr', 0, 'UPtr*', &pBmp := 0)
        if pBmp
            DllCall('gdiplus\GdipGetImageGraphicsContext', 'UPtr', pBmp, 'UPtr*', &pGfx := 0)
    }
    return pGfx
}

; Fonts are cached by name+size: a snip with a dozen numbered callouts would
; otherwise create and destroy a dozen identical fonts on every single render,
; and renders happen on every mouse move during a drag.
MarkupFont(name, size) {
    static cache := Map()
    key := name '|' size
    if cache.Has(key)
        return cache[key]
    DllCall('gdiplus\GdipCreateFontFamilyFromName', 'WStr', name, 'UPtr', 0, 'UPtr*', &fam := 0)
    if !fam                                   ; unknown font name — fall back
        DllCall('gdiplus\GdipGetGenericFontFamilySansSerif', 'UPtr*', &fam := 0)
    if !fam
        return 0
    ; 2 = UnitPixel, so the size is in image pixels and an annotation keeps its
    ; size relative to the screenshot rather than to the display DPI.
    DllCall('gdiplus\GdipCreateFont', 'UPtr', fam, 'Float', size + 0.0
          , 'Int', 0, 'Int', 2, 'UPtr*', &font := 0)
    cache[key] := font
    return font
}

MarkupStringFormat() {
    static fmt := 0
    if !fmt {
        DllCall('gdiplus\GdipCreateStringFormat', 'Int', 0, 'UShort', 0, 'UPtr*', &fmt := 0)
        ; NoClip, so a descender or an italic overhang isn't shaved off at the
        ; edge of the layout rect we measured for it.
        DllCall('gdiplus\GdipSetStringFormatFlags', 'UPtr', fmt, 'Int', 0x4000)
    }
    return fmt
}

; Measured size of an object's text, in master-space pixels.
MarkupTextSize(o, &w, &h) {
    w := 0, h := 0
    txt := (o.Type = 'number') ? String(o.Num) : o.Text
    if (txt = '')
        txt := ' '
    font := MarkupFont(o.FontName, o.FontSize)
    gfx  := MarkupMeasureGfx()
    if (!font || !gfx)
        return
    layout := Buffer(16, 0)
    NumPut('Float', 0, layout, 0), NumPut('Float', 0, layout, 4)
    NumPut('Float', 4000, layout, 8), NumPut('Float', 4000, layout, 12)
    bounds := Buffer(16, 0)
    DllCall('gdiplus\GdipMeasureString', 'UPtr', gfx, 'WStr', txt, 'Int', -1
          , 'UPtr', font, 'Ptr', layout, 'UPtr', MarkupStringFormat()
          , 'Ptr', bounds, 'UInt*', 0, 'UInt*', 0)
    w := NumGet(bounds, 8, 'Float')
    h := NumGet(bounds, 12, 'Float')
}

; Draw a string, optionally with a halo.  The halo is eight offset copies rather
; than a stroked GraphicsPath: it is a handful of extra DrawString calls instead
; of a path build per render, and at annotation sizes the two are visually
; identical.
MarkupDrawString(pGfx, txt, x, y, o, color, alpha, halo := false) {
    font := MarkupFont(o.FontName, o.FontSize)
    if !font
        return
    fmt  := MarkupStringFormat()
    rect := Buffer(16, 0)
    if halo {
        hb := MarkupBrush(MarkupHalo(color), alpha)
        d  := Max(1, MarkupCfg.OutlineWidth // 2)
        for off in [[-d,-d],[0,-d],[d,-d],[-d,0],[d,0],[-d,d],[0,d],[d,d]] {
            NumPut('Float', x + off[1], rect, 0), NumPut('Float', y + off[2], rect, 4)
            NumPut('Float', 4000, rect, 8),       NumPut('Float', 4000, rect, 12)
            DllCall('gdiplus\GdipDrawString', 'UPtr', pGfx, 'WStr', txt, 'Int', -1
                  , 'UPtr', font, 'Ptr', rect, 'UPtr', fmt, 'UPtr', hb)
        }
        MarkupDelBrush(hb)
    }
    br := MarkupBrush(color, alpha)
    NumPut('Float', x, rect, 0), NumPut('Float', y, rect, 4)
    NumPut('Float', 4000, rect, 8), NumPut('Float', 4000, rect, 12)
    DllCall('gdiplus\GdipDrawString', 'UPtr', pGfx, 'WStr', txt, 'Int', -1
          , 'UPtr', font, 'Ptr', rect, 'UPtr', fmt, 'UPtr', br)
    MarkupDelBrush(br)
}

; A rounded-rectangle GraphicsPath.  Caller deletes it.
MarkupRoundRectPath(x, y, w, h, r) {
    r := Min(r, Min(w, h) / 2)
    d := r * 2
    DllCall('gdiplus\GdipCreatePath', 'Int', 0, 'UPtr*', &p := 0)
    if !p
        return 0
    if (r <= 0) {
        DllCall('gdiplus\GdipAddPathRectangle', 'UPtr', p
              , 'Float', x, 'Float', y, 'Float', w, 'Float', h)
    } else {
        DllCall('gdiplus\GdipAddPathArc', 'UPtr', p, 'Float', x,         'Float', y
              , 'Float', d, 'Float', d, 'Float', 180, 'Float', 90)
        DllCall('gdiplus\GdipAddPathArc', 'UPtr', p, 'Float', x + w - d, 'Float', y
              , 'Float', d, 'Float', d, 'Float', 270, 'Float', 90)
        DllCall('gdiplus\GdipAddPathArc', 'UPtr', p, 'Float', x + w - d, 'Float', y + h - d
              , 'Float', d, 'Float', d, 'Float', 0,   'Float', 90)
        DllCall('gdiplus\GdipAddPathArc', 'UPtr', p, 'Float', x,         'Float', y + h - d
              , 'Float', d, 'Float', d, 'Float', 90,  'Float', 90)
    }
    DllCall('gdiplus\GdipClosePathFigure', 'UPtr', p)
    return p
}

; ── Callout geometry ─────────────────────────────────────────────────────────
;
; The tail is not a triangle stuck onto a rectangle; it is part of ONE outline.
; That is what makes a callout read as a speech bubble instead of a box with a
; spike poking out of it, and it is why the border has to be missing between the
; two points where the tail meets the box.
;
; The base is pinned to whichever EDGE the tip lies beyond, and its two ends are
; stored as signed offsets (TailA, TailB) measured along that edge from the
; point where the centre→tip ray crosses it.  Storing offsets rather than
; absolute points means the tail stays attached when the box is moved or
; resized, and it survives the tip being dragged round to a different side.
; TailB - TailA < 2 means "never adjusted" and a default width is used, so an
; older callout picks up sensible proportions on its own.
;
; Clockwise is the traversal direction used everywhere below, matching the
; order MarkupCalloutPath walks the perimeter: +x along the top, +y down the
; right, -x along the bottom, -y up the left.

MarkupCalloutRadius(o, w, h) => Max(1, Min(o.FontSize * 0.45, Min(w, h) / 2))

; Returns 0 when there should be no tail at all (tip inside the box, or a
; degenerate box); otherwise a record describing the base.  Edge is the index of
; the gapped segment in MarkupCalloutPath's perimeter walk.
MarkupCalloutGeom(o, bx1, by1, bx2, by2, tipX, tipY, r) {
    w := bx2 - bx1, h := by2 - by1
    if (w < 4 || h < 4)
        return 0
    cx := (bx1 + bx2) / 2, cy := (by1 + by2) / 2
    dx := tipX - cx,       dy := tipY - cy
    hw := w / 2,           hh := h / 2
    if (Abs(dx) <= hw && Abs(dy) <= hh)      ; tip is inside → plain rounded box
        return 0

    if (Abs(dx) * hh > Abs(dy) * hw) {       ; crosses a vertical edge
        t  := hw / Abs(dx)
        ax := cx + dx * t, ay := cy + dy * t
        if (dx > 0)
            edge := 3, ux := 0, uy :=  1, lo := (by1 + r) - ay, hi := (by2 - r) - ay
        else
            edge := 7, ux := 0, uy := -1, lo := ay - (by2 - r), hi := ay - (by1 + r)
    } else {                                 ; crosses a horizontal edge
        t  := hh / Abs(dy)
        ax := cx + dx * t, ay := cy + dy * t
        if (dy < 0)
            edge := 1, ux :=  1, uy := 0, lo := (bx1 + r) - ax, hi := (bx2 - r) - ax
        else
            edge := 5, ux := -1, uy := 0, lo := ax - (bx2 - r), hi := ax - (bx1 + r)
    }
    if (hi - lo < 4)                          ; corner radius eats the whole edge
        return 0

    ta := o.HasProp('TailA') ? o.TailA : 0
    tb := o.HasProp('TailB') ? o.TailB : 0
    if (tb - ta < 2) {
        base := Max(5, Min(w, h) * 0.20)
        ta := -base, tb := base
    }
    ta := Max(lo, Min(hi - 4, ta))
    tb := Max(ta + 4, Min(hi, tb))

    return { Edge: edge, R: r
           , Ax: ax, Ay: ay, Ux: ux, Uy: uy, Lo: lo, Hi: hi, Ta: ta, Tb: tb
           , P1x: ax + ux * ta, P1y: ay + uy * ta
           , P2x: ax + ux * tb, P2y: ay + uy * tb }
}

; Write the currently-effective base offsets onto the object, so that grabbing a
; base handle on a never-adjusted callout starts from where it visibly is rather
; than jumping to zero.
MarkupCalloutMaterialize(o) {
    MarkupBoundsMaster(o, &x1, &y1, &x2, &y2)
    r := MarkupCalloutRadius(o, x2 - x1, y2 - y1)
    g := MarkupCalloutGeom(o, x1, y1, x2, y2, o.TailX, o.TailY, r)
    if g
        o.TailA := g.Ta, o.TailB := g.Tb
}

; The whole bubble as ONE closed path: the rounded rectangle with a gap cut out
; of one edge, and the tail's two sides bridging that gap.  Filling and stroking
; this single path is what removes the seam the old two-shape version had —
; there is no longer a border segment running across the base of the tail,
; because that border segment is simply not in the path.
;
; The perimeter is walked clockwise as eight segments (four straight edges at
; odd indices, four corner arcs at even ones).  We start just after the gap,
; walk all the way round, and finish with the two tail lines.
MarkupCalloutPath(x, y, w, h, r, g, tipX, tipY) {
    if !g
        return MarkupRoundRectPath(x, y, w, h, r)
    d := r * 2
    segs := [ { K: 'L', X1: x + r,     Y1: y,         X2: x + w - r, Y2: y         }
            , { K: 'A', X:  x + w - d, Y:  y,         W:  d, H: d, S: 270, E: 90   }
            , { K: 'L', X1: x + w,     Y1: y + r,     X2: x + w,     Y2: y + h - r }
            , { K: 'A', X:  x + w - d, Y:  y + h - d, W:  d, H: d, S: 0,   E: 90   }
            , { K: 'L', X1: x + w - r, Y1: y + h,     X2: x + r,     Y2: y + h     }
            , { K: 'A', X:  x,         Y:  y + h - d, W:  d, H: d, S: 90,  E: 90   }
            , { K: 'L', X1: x,         Y1: y + h - r, X2: x,         Y2: y + r     }
            , { K: 'A', X:  x,         Y:  y,         W:  d, H: d, S: 180, E: 90   } ]

    DllCall('gdiplus\GdipCreatePath', 'Int', 0, 'UPtr*', &p := 0)
    if !p
        return 0
    gi := g.Edge
    ; Remainder of the gapped edge, from the far side of the gap to its end.
    DllCall('gdiplus\GdipAddPathLine', 'UPtr', p
          , 'Float', g.P2x, 'Float', g.P2y
          , 'Float', segs[gi].X2, 'Float', segs[gi].Y2)
    ; The other seven segments, in clockwise order.
    Loop 7 {
        sg := segs[Mod(gi - 1 + A_Index, 8) + 1]
        if (sg.K = 'L')
            DllCall('gdiplus\GdipAddPathLine', 'UPtr', p
                  , 'Float', sg.X1, 'Float', sg.Y1, 'Float', sg.X2, 'Float', sg.Y2)
        else
            DllCall('gdiplus\GdipAddPathArc', 'UPtr', p
                  , 'Float', sg.X, 'Float', sg.Y, 'Float', sg.W, 'Float', sg.H
                  , 'Float', sg.S, 'Float', sg.E)
    }
    ; Back along the gapped edge to the near side of the gap, then out and back.
    DllCall('gdiplus\GdipAddPathLine', 'UPtr', p
          , 'Float', segs[gi].X1, 'Float', segs[gi].Y1
          , 'Float', g.P1x, 'Float', g.P1y)
    DllCall('gdiplus\GdipAddPathLine', 'UPtr', p
          , 'Float', g.P1x, 'Float', g.P1y, 'Float', tipX, 'Float', tipY)
    DllCall('gdiplus\GdipAddPathLine', 'UPtr', p
          , 'Float', tipX, 'Float', tipY, 'Float', g.P2x, 'Float', g.P2y)
    DllCall('gdiplus\GdipClosePathFigure', 'UPtr', p)
    return p
}

; Pack an array of x,y pairs into a PointF buffer for GdipDrawLines / FillPolygon.
MarkupPointBuf(pts) {
    n   := pts.Length // 2
    buf := Buffer(n * 8, 0)
    Loop n {
        NumPut('Float', pts[A_Index * 2 - 1] + 0.0, buf, (A_Index - 1) * 8)
        NumPut('Float', pts[A_Index * 2]     + 0.0, buf, (A_Index - 1) * 8 + 4)
    }
    return { Buf: buf, N: n }
}

; ==============================================================================
; OBJECT RENDERING
; ==============================================================================
;
; Every object is drawn in up to three passes — shadow, halo, main — by the same
; code path, with only the colour, the alpha, the stroke width and the offset
; changing between them.  Doing it this way means a new object type only has to
; describe its geometry once and gets legibility and shadowing for free.
;
; ox/oy shift every coordinate.  For a normal (rotating) object it is 0,0 and
; the world transform on the graphics context does the work.  For an Upright
; object the world transform has been reset, and ox/oy carries the difference
; between the object's master anchor and where that anchor maps to on screen —
; so the identical geometry code draws a label that has MOVED with the image but
; not TURNED with it.  tox/toy is the same thing for a callout's tail tip, which
; is mapped separately so it keeps pointing at the feature it was aimed at.

MarkupDrawObject(pGfx, o, ox := 0, oy := 0, tox := '', toy := '') {
    if (tox = '')
        tox := ox, toy := oy
    if o.Shadow
        MarkupDrawPass(pGfx, o, 'shadow', ox, oy, tox, toy)
    ; Text is excluded from the halo pass on purpose: MarkupDrawString paints
    ; its own halo during the main pass, where it still knows the real text
    ; colour.  Running the generic halo pass as well would just draw the same
    ; glyphs underneath in the halo colour, invisibly.
    if (o.Outline && o.Type != 'highlight' && o.Type != 'text')
        MarkupDrawPass(pGfx, o, 'halo',   ox, oy, tox, toy)
    MarkupDrawPass(pGfx, o, 'main',       ox, oy, tox, toy)
}

MarkupDrawPass(pGfx, o, pass, ox, oy, tox, toy) {
    isShadow := (pass = 'shadow')
    isHalo   := (pass = 'halo')

    ; Shadow displaces everything; halo and main sit where the object is.
    d  := isShadow ? MarkupCfg.ShadowOffset : 0
    ox += d, oy += d, tox += d, toy += d

    col   := isShadow ? 0x000000
           : isHalo   ? MarkupHalo(o.Color)
           :            o.Color
    alpha := isShadow ? MarkupCfg.ShadowAlpha : o.Alpha
    width := o.Thick + (isHalo ? MarkupCfg.OutlineWidth : 0)

    ; The halo pass never fills: it is a widened stroke drawn UNDER the object,
    ; so filling it would just hide the object's own fill behind a fat outline.
    doFill    := o.Fill && !isHalo
    fillCol   := isShadow ? 0x000000 : o.FillColor
    fillAlpha := isShadow ? MarkupCfg.ShadowAlpha : o.Alpha

    x1 := Min(o.X1, o.X2) + ox, y1 := Min(o.Y1, o.Y2) + oy
    x2 := Max(o.X1, o.X2) + ox, y2 := Max(o.Y1, o.Y2) + oy
    w  := x2 - x1,              h  := y2 - y1

    switch o.Type {

    case 'rect', 'highlight':
        if doFill {
            br := MarkupBrush(fillCol, fillAlpha)
            DllCall('gdiplus\GdipFillRectangle', 'UPtr', pGfx, 'UPtr', br
                  , 'Float', x1, 'Float', y1, 'Float', w, 'Float', h)
            MarkupDelBrush(br)
        }
        if (o.Type = 'rect') {
            pn := MarkupPen(col, alpha, width)
            DllCall('gdiplus\GdipDrawRectangle', 'UPtr', pGfx, 'UPtr', pn
                  , 'Float', x1, 'Float', y1, 'Float', w, 'Float', h)
            MarkupDelPen(pn)
        }

    case 'ellipse':
        if doFill {
            br := MarkupBrush(fillCol, fillAlpha)
            DllCall('gdiplus\GdipFillEllipse', 'UPtr', pGfx, 'UPtr', br
                  , 'Float', x1, 'Float', y1, 'Float', w, 'Float', h)
            MarkupDelBrush(br)
        }
        pn := MarkupPen(col, alpha, width)
        DllCall('gdiplus\GdipDrawEllipse', 'UPtr', pGfx, 'UPtr', pn
              , 'Float', x1, 'Float', y1, 'Float', w, 'Float', h)
        MarkupDelPen(pn)

    case 'line':
        pn := MarkupPen(col, alpha, width)
        DllCall('gdiplus\GdipDrawLine', 'UPtr', pGfx, 'UPtr', pn
              , 'Float', o.X1 + ox, 'Float', o.Y1 + oy
              , 'Float', o.X2 + ox, 'Float', o.Y2 + oy)
        MarkupDelPen(pn)

    case 'arrow':
        ; Shaft stops short of the tip so the head's back edge doesn't show a
        ; nub of shaft poking through it on thick arrows.
        ang  := MarkupAtan2(o.Y2 - o.Y1, o.X2 - o.X1)
        head := Max(8, o.Thick * MarkupCfg.ArrowHeadScale) + (isHalo ? MarkupCfg.OutlineWidth : 0)
        tipX := o.X2 + ox, tipY := o.Y2 + oy
        bx   := tipX - Cos(ang) * head * 0.85
        by   := tipY - Sin(ang) * head * 0.85
        pn := MarkupPen(col, alpha, width)
        DllCall('gdiplus\GdipDrawLine', 'UPtr', pGfx, 'UPtr', pn
              , 'Float', o.X1 + ox, 'Float', o.Y1 + oy, 'Float', bx, 'Float', by)
        MarkupDelPen(pn)
        spread := 0.42
        pts := [ tipX, tipY
               , tipX - Cos(ang - spread) * head, tipY - Sin(ang - spread) * head
               , tipX - Cos(ang + spread) * head, tipY - Sin(ang + spread) * head ]
        pb := MarkupPointBuf(pts)
        br := MarkupBrush(col, alpha)
        DllCall('gdiplus\GdipFillPolygon', 'UPtr', pGfx, 'UPtr', br
              , 'Ptr', pb.Buf, 'Int', pb.N, 'Int', 0)
        MarkupDelBrush(br)

    case 'pen':
        if (o.Pts.Length < 4)
            return
        shifted := []
        i := 1
        while (i <= o.Pts.Length)
            shifted.Push(o.Pts[i] + ox, o.Pts[i + 1] + oy), i += 2
        pb := MarkupPointBuf(shifted)
        pn := MarkupPen(col, alpha, width)
        DllCall('gdiplus\GdipDrawLines', 'UPtr', pGfx, 'UPtr', pn
              , 'Ptr', pb.Buf, 'Int', pb.N)
        MarkupDelPen(pn)

    case 'text':
        MarkupDrawString(pGfx, o.Text, o.X1 + ox, o.Y1 + oy, o, col, alpha
                       , o.Outline && !isShadow)

    case 'number':
        MarkupTextSize(o, &tw, &th)
        dia := Max(tw, th) + o.FontSize * 0.7
        cx  := o.X1 + ox, cy := o.Y1 + oy
        if !isHalo {
            br := MarkupBrush(fillCol, fillAlpha)
            DllCall('gdiplus\GdipFillEllipse', 'UPtr', pGfx, 'UPtr', br
                  , 'Float', cx, 'Float', cy, 'Float', dia, 'Float', dia)
            MarkupDelBrush(br)
        }
        pn := MarkupPen(col, alpha, isHalo ? MarkupCfg.OutlineWidth * 2 : Max(1, o.Thick - 1))
        DllCall('gdiplus\GdipDrawEllipse', 'UPtr', pGfx, 'UPtr', pn
              , 'Float', cx, 'Float', cy, 'Float', dia, 'Float', dia)
        MarkupDelPen(pn)
        if !isHalo {
            ; Digits sit on the disc, so they take their colour from the DISC,
            ; not from the stroke — a red-filled badge needs white numerals.
            numCol := isShadow ? 0x000000 : MarkupHalo(o.FillColor)
            MarkupDrawString(pGfx, String(o.Num)
                           , cx + (dia - tw) / 2, cy + (dia - th) / 2
                           , o, numCol, alpha, false)
        }

    case 'callout':
        ; One path for the entire bubble — box and tail together, with the box
        ; border omitted across the tail's base.  Fill and stroke both use it,
        ; so there is no seam to hide and no draw-order trickery needed.
        r    := MarkupCalloutRadius(o, w, h)
        tipX := o.TailX + tox, tipY := o.TailY + toy
        geom := MarkupCalloutGeom(o, x1, y1, x2, y2, tipX, tipY, r)
        path := MarkupCalloutPath(x1, y1, w, h, r, geom, tipX, tipY)
        if path {
            if !isHalo {
                br := MarkupBrush(fillCol, fillAlpha)
                DllCall('gdiplus\GdipFillPath', 'UPtr', pGfx, 'UPtr', br, 'UPtr', path)
                MarkupDelBrush(br)
            }
            pn := MarkupPen(col, alpha, width)
            DllCall('gdiplus\GdipDrawPath', 'UPtr', pGfx, 'UPtr', pn, 'UPtr', path)
            MarkupDelPen(pn)
            DllCall('gdiplus\GdipDeletePath', 'UPtr', path)
        }
        if (!isHalo && o.Text != '') {
            MarkupTextSize(o, &tw, &th)
            txtCol := isShadow ? 0x000000 : MarkupHalo(o.FillColor)
            MarkupDrawString(pGfx, o.Text, x1 + (w - tw) / 2, y1 + (h - th) / 2
                           , o, txtCol, alpha, false)
        }

    case 'image':
        if isHalo || isShadow
            return
        ; Resolved by the compose pass, which has the snip in hand; see the
        ; note on the image pool in MarkupEnsure.
        if (o.HasProp('_pImg') && o._pImg)
            DllCall('gdiplus\GdipDrawImageRect', 'UPtr', pGfx, 'UPtr', o._pImg
                  , 'Float', x1, 'Float', y1, 'Float', w, 'Float', h)
    }
}

; ==============================================================================
; COMPOSITE — the two entry points the core's render pipeline calls
; ==============================================================================

; STAGE 1: onto the upright crop, before flips and rotation.
; Blur and pixelate only.  A redaction is a change to the IMAGE, so it lives in
; image space and stays glued to the pixels it hides no matter what transform is
; applied afterwards.  It also means an exported snip has the pixels genuinely
; destroyed rather than merely covered.
MarkupComposeImage(snip, pBmp) {
    if !snip.HasProp('Markup')
        return
    any := false
    for o in snip.Markup.Objs
        if (o.Type = 'blur') {
            any := true
            break
        }
    if !any
        return

    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', pBmp, 'UInt*', &bw := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', pBmp, 'UInt*', &bh := 0)
    m := MarkupMatrix(snip, 'crop')
    if !m
        return
    DllCall('gdiplus\GdipGetImageGraphicsContext', 'UPtr', pBmp, 'UPtr*', &pGfx := 0)
    if !pGfx {
        DllCall('gdiplus\GdipDeleteMatrix', 'UPtr', m)
        return
    }
    DllCall('gdiplus\GdipSetPixelOffsetMode', 'UPtr', pGfx, 'Int', 2)   ; Half
    DllCall('gdiplus\GdipSetSmoothingMode',   'UPtr', pGfx, 'Int', 3)   ; None

    for o in snip.Markup.Objs {
        if (o.Type != 'blur')
            continue
        ; Axis-aligned bounding box of the four mapped corners.  Under a
        ; Straighten tilt this over-covers slightly at the corners, which is the
        ; safe direction to err for a redaction.
        MarkupXform(m, o.X1, o.Y1, &ax, &ay)
        MarkupXform(m, o.X2, o.Y1, &bx, &by)
        MarkupXform(m, o.X2, o.Y2, &cx, &cy)
        MarkupXform(m, o.X1, o.Y2, &dx, &dy)
        rx1 := Floor(Min(ax, bx, cx, dx)), ry1 := Floor(Min(ay, by, cy, dy))
        rx2 := Ceil(Max(ax, bx, cx, dx)),  ry2 := Ceil(Max(ay, by, cy, dy))
        rx1 := Max(0, rx1), ry1 := Max(0, ry1)
        rx2 := Min(bw, rx2), ry2 := Min(bh, ry2)
        rw  := rx2 - rx1,   rh  := ry2 - ry1
        if (rw < 2 || rh < 2)
            continue
        ; Flush first: we are about to read a rectangle back OUT of the same
        ; bitmap this context draws into, and GDI+ batches. Without the flush an
        ; overlapping second redaction could sample pre-redaction pixels.
        DllCall('gdiplus\GdipFlush', 'UPtr', pGfx, 'Int', 1)   ; 1 = FlushIntentionSync
        MarkupRedactRect(pGfx, pBmp, rx1, ry1, rw, rh, o)
    }
    DllCall('gdiplus\GdipDeleteGraphics', 'UPtr', pGfx)
    DllCall('gdiplus\GdipDeleteMatrix',   'UPtr', m)
}

; Downscale a rectangle of the bitmap and blow it back up over itself.
; NearestNeighbour both ways gives hard blocks (pixelate); bicubic gives a soft
; blur.  Pixelate is the default because it is cheaper and, more importantly,
; because a viewer can SEE that something was deliberately hidden.
MarkupRedactRect(pGfx, pBmp, x, y, w, h, o) {
    amt := Max(2, o.HasProp('BlurAmount') ? o.BlurAmount : MarkupCfg.BlurAmount)
    sw  := Max(1, w // amt), sh := Max(1, h // amt)
    pix := o.HasProp('Pixelate') ? o.Pixelate : MarkupCfg.Pixelate
    interp := pix ? 5 : 7                          ; 5 = NearestNeighbor, 7 = HQ bicubic

    sub := GDIp.CloneBitmapArea(pBmp, x, y, w, h)
    if !sub
        return
    DllCall('gdiplus\GdipCreateBitmapFromScan0'
          , 'Int', sw, 'Int', sh, 'Int', 0, 'Int', 0x26200A, 'Ptr', 0, 'UPtr*', &small := 0)
    if !small {
        GDIp.DisposeImage(sub)
        return
    }
    DllCall('gdiplus\GdipGetImageGraphicsContext', 'UPtr', small, 'UPtr*', &sg := 0)
    if sg {
        DllCall('gdiplus\GdipSetInterpolationMode', 'UPtr', sg, 'Int', 7)
        DllCall('gdiplus\GdipSetPixelOffsetMode',   'UPtr', sg, 'Int', 2)
        DllCall('gdiplus\GdipDrawImageRectRectI', 'UPtr', sg, 'UPtr', sub
              , 'Int', 0, 'Int', 0, 'Int', sw, 'Int', sh
              , 'Int', 0, 'Int', 0, 'Int', w,  'Int', h
              , 'Int', 2, 'UPtr', 0, 'UPtr', 0, 'UPtr', 0)
        DllCall('gdiplus\GdipDeleteGraphics', 'UPtr', sg)
    }
    DllCall('gdiplus\GdipSetInterpolationMode', 'UPtr', pGfx, 'Int', interp)
    DllCall('gdiplus\GdipDrawImageRectRectI', 'UPtr', pGfx, 'UPtr', small
          , 'Int', x, 'Int', y, 'Int', w,  'Int', h
          , 'Int', 0, 'Int', 0, 'Int', sw, 'Int', sh
          , 'Int', 2, 'UPtr', 0, 'UPtr', 0, 'UPtr', 0)
    GDIp.DisposeImage(small)
    GDIp.DisposeImage(sub)
}

; STAGE 2: onto the finished display bitmap, after every transform.
; wantChrome is false for the save and clipboard paths, so selection handles are
; never exported — that, plus MarkupBeforeExport, is what keeps the blue boxes
; out of the PNG you upload to Imgur.
MarkupComposeOverlay(snip, pBmp, wantChrome := true) {
    if !snip.HasProp('Markup')
        return
    mk       := snip.Markup
    isActive := wantChrome && (MarkupState.Active = snip.GuiObj.Hwnd)
    if (!mk.Objs.Length && !isActive)
        return

    DllCall('gdiplus\GdipGetImageGraphicsContext', 'UPtr', pBmp, 'UPtr*', &pGfx := 0)
    if !pGfx
        return
    DllCall('gdiplus\GdipSetSmoothingMode',     'UPtr', pGfx, 'Int', 4)   ; AntiAlias
    DllCall('gdiplus\GdipSetTextRenderingHint', 'UPtr', pGfx, 'Int', 4)   ; AntiAliasGridFit
    DllCall('gdiplus\GdipSetPixelOffsetMode',   'UPtr', pGfx, 'Int', 2)   ; Half
    DllCall('gdiplus\GdipSetInterpolationMode', 'UPtr', pGfx, 'Int', 7)

    m := MarkupMatrix(snip, 'display')

    ; ── Pass A: objects that turn with the image ─────────────────────────────
    if m
        DllCall('gdiplus\GdipSetWorldTransform', 'UPtr', pGfx, 'UPtr', m)
    for o in mk.Objs {
        if (o.Upright || o.Type = 'blur')
            continue
        if (o.Type = 'image')
            o._pImg := mk.Images.Has(o.ImgIdx) ? mk.Images[o.ImgIdx] : 0
        MarkupDrawObject(pGfx, o)
    }
    DllCall('gdiplus\GdipResetWorldTransform', 'UPtr', pGfx)

    ; ── Pass B: objects that stay readable ───────────────────────────────────
    ; Anchor mapped through the matrix, geometry drawn square. A flipped snip
    ; keeps its labels the right way round; a rotated one keeps them upright.
    if m {
        for o in mk.Objs {
            if !o.Upright
                continue
            MarkupXform(m, o.X1, o.Y1, &ax, &ay)
            MarkupXform(m, o.TailX, o.TailY, &tx, &ty)
            MarkupDrawObject(pGfx, o, ax - o.X1, ay - o.Y1, tx - o.TailX, ty - o.TailY)
        }
    }

    if isActive
        MarkupDrawChrome(pGfx, snip, m)

    if m
        DllCall('gdiplus\GdipDeleteMatrix', 'UPtr', m)
    DllCall('gdiplus\GdipDeleteGraphics', 'UPtr', pGfx)
}

; ==============================================================================
; BOUNDS, HANDLES, SELECTION CHROME
; ==============================================================================

; An object's extent in MASTER space.  Text and numbers have to be measured
; rather than read off the record, because their size follows the font.
MarkupBoundsMaster(o, &x1, &y1, &x2, &y2) {
    switch o.Type {
    case 'pen':
        if !o.Pts.Length {
            x1 := o.X1, y1 := o.Y1, x2 := o.X1, y2 := o.Y1
            return
        }
        x1 := x2 := o.Pts[1], y1 := y2 := o.Pts[2]
        i := 3
        while (i <= o.Pts.Length) {
            x1 := Min(x1, o.Pts[i]),     x2 := Max(x2, o.Pts[i])
            y1 := Min(y1, o.Pts[i + 1]), y2 := Max(y2, o.Pts[i + 1])
            i += 2
        }
    case 'text':
        MarkupTextSize(o, &tw, &th)
        x1 := o.X1, y1 := o.Y1, x2 := o.X1 + tw, y2 := o.Y1 + th
    case 'number':
        MarkupTextSize(o, &tw, &th)
        dia := Max(tw, th) + o.FontSize * 0.7
        x1 := o.X1, y1 := o.Y1, x2 := o.X1 + dia, y2 := o.Y1 + dia
    default:
        x1 := Min(o.X1, o.X2), y1 := Min(o.Y1, o.Y2)
        x2 := Max(o.X1, o.X2), y2 := Max(o.Y1, o.Y2)
    }
}

; The same extent in DISPLAY space, as an axis-aligned box.  For a rotated snip
; the box is the bounding box of the rotated shape, which is bigger than the
; shape — the standard, and honest, way to show a selection under rotation.
MarkupBoundsDisplay(snip, o, m, &x1, &y1, &x2, &y2) {
    MarkupBoundsMaster(o, &a1, &b1, &a2, &b2)
    if !m {
        x1 := a1, y1 := b1, x2 := a2, y2 := b2
        return
    }
    if o.Upright {
        ; Square in display space; only the anchor moves.
        MarkupXform(m, o.X1, o.Y1, &ax, &ay)
        x1 := ax, y1 := ay, x2 := ax + (a2 - a1), y2 := ay + (b2 - b1)
        return
    }
    MarkupXform(m, a1, b1, &p1x, &p1y)
    MarkupXform(m, a2, b1, &p2x, &p2y)
    MarkupXform(m, a2, b2, &p3x, &p3y)
    MarkupXform(m, a1, b2, &p4x, &p4y)
    x1 := Min(p1x, p2x, p3x, p4x), y1 := Min(p1y, p2y, p3y, p4y)
    x2 := Max(p1x, p2x, p3x, p4x), y2 := Max(p1y, p2y, p3y, p4y)
}

; Grab handles, in display coordinates.  Deliberately NOT uniform across types:
; a line wants its two ends, a callout wants its box plus its tail tip, and a
; freehand stroke wants nothing at all, because nobody has ever wanted to
; reshape a pen stroke by dragging a control point.
MarkupHandleList(snip, o, m) {
    hs := []
    if (o.Type = 'line' || o.Type = 'arrow') {
        MarkupXform(m, o.X1, o.Y1, &ax, &ay)
        MarkupXform(m, o.X2, o.Y2, &bx, &by)
        hs.Push({ Id: 'p1', X: ax, Y: ay }, { Id: 'p2', X: bx, Y: by })
        return hs
    }
    if (o.Type = 'pen' || o.Type = 'text' || o.Type = 'number')
        return hs
    MarkupBoundsDisplay(snip, o, m, &x1, &y1, &x2, &y2)
    mx := (x1 + x2) / 2, my := (y1 + y2) / 2
    hs.Push({ Id: 'nw', X: x1, Y: y1 }, { Id: 'n',  X: mx, Y: y1 }
          , { Id: 'ne', X: x2, Y: y1 }, { Id: 'e',  X: x2, Y: my }
          , { Id: 'se', X: x2, Y: y2 }, { Id: 's',  X: mx, Y: y2 }
          , { Id: 'sw', X: x1, Y: y2 }, { Id: 'w',  X: x1, Y: my })
    if (o.Type = 'callout') {
        MarkupXform(m, o.TailX, o.TailY, &tx, &ty)
        hs.Push({ Id: 'tip', X: tx, Y: ty })
        ; Two more on the tail's base, where it meets the box, so the tail can
        ; be widened, narrowed or skewed independently of the tip.  They sit on
        ; the object's MASTER geometry and map through the same matrix as
        ; everything else, so they follow a rotated snip correctly.
        MarkupBoundsMaster(o, &mx1, &my1, &mx2, &my2)
        rr := MarkupCalloutRadius(o, mx2 - mx1, my2 - my1)
        g  := MarkupCalloutGeom(o, mx1, my1, mx2, my2, o.TailX, o.TailY, rr)
        if g {
            MarkupXform(m, g.P1x, g.P1y, &b1x, &b1y)
            MarkupXform(m, g.P2x, g.P2y, &b2x, &b2y)
            hs.Push({ Id: 'tail1', X: b1x, Y: b1y }, { Id: 'tail2', X: b2x, Y: b2y })
        }
    }
    return hs
}

; The selection box and its handles.  Drawn into the DISPLAY bitmap only —
; MarkupComposeOverlay is called with wantChrome := false on the save and
; clipboard paths, so none of this can reach an exported image.
MarkupDrawChrome(pGfx, snip, m) {
    ; Rubber band first, so it sits under any selection boxes it is sweeping up.
    if MarkupState.Band {
        b  := MarkupState.Band
        bp := MarkupPen(MarkupCfg.HandleColor, 200, 1)
        DllCall('gdiplus\GdipSetPenDashStyle', 'UPtr', bp, 'Int', 1)
        DllCall('gdiplus\GdipDrawRectangle', 'UPtr', pGfx, 'UPtr', bp
              , 'Float', Min(b.X1, b.X2), 'Float', Min(b.Y1, b.Y2)
              , 'Float', Abs(b.X2 - b.X1), 'Float', Abs(b.Y2 - b.Y1))
        MarkupDelPen(bp)
        bb := MarkupBrush(MarkupCfg.HandleColor, 40)
        DllCall('gdiplus\GdipFillRectangle', 'UPtr', pGfx, 'UPtr', bb
              , 'Float', Min(b.X1, b.X2), 'Float', Min(b.Y1, b.Y2)
              , 'Float', Abs(b.X2 - b.X1), 'Float', Abs(b.Y2 - b.Y1))
        MarkupDelBrush(bb)
    }
    if (!MarkupState.Sels.Length || !m)
        return
    multi := MarkupState.Sels.Length > 1
    pad   := 3

    ; A thin dashed box round EVERY selected object, so with a group you can see
    ; exactly what is in it rather than only the outer extent.
    pn := MarkupPen(MarkupCfg.HandleColor, multi ? 160 : 220, 1)
    DllCall('gdiplus\GdipSetPenDashStyle', 'UPtr', pn, 'Int', 1)   ; 1 = Dash
    for o in MarkupState.Sels {
        MarkupBoundsDisplay(snip, o, m, &x1, &y1, &x2, &y2)
        DllCall('gdiplus\GdipDrawRectangle', 'UPtr', pGfx, 'UPtr', pn
              , 'Float', x1 - pad, 'Float', y1 - pad
              , 'Float', (x2 - x1) + pad * 2, 'Float', (y2 - y1) + pad * 2)
    }
    MarkupDelPen(pn)

    ; Handles: the object's own when one thing is selected, the group's union
    ; box when several are.
    if multi {
        MarkupSelUnionDisplay(snip, m, &ux1, &uy1, &ux2, &uy2)
        gp := MarkupPen(MarkupCfg.HandleColor, 235, 1)
        DllCall('gdiplus\GdipDrawRectangle', 'UPtr', pGfx, 'UPtr', gp
              , 'Float', ux1 - pad * 2, 'Float', uy1 - pad * 2
              , 'Float', (ux2 - ux1) + pad * 4, 'Float', (uy2 - uy1) + pad * 4)
        MarkupDelPen(gp)
        handles := MarkupGroupHandleList(snip, m)
    } else {
        handles := MarkupHandleList(snip, MarkupState.Sels[1], m)
    }

    s  := MarkupCfg.HandleSize
    br := MarkupBrush(MarkupCfg.HandleColor, 255)
    wb := MarkupBrush(0xFFFFFF, 255)
    for h in handles {
        DllCall('gdiplus\GdipFillRectangle', 'UPtr', pGfx, 'UPtr', wb
              , 'Float', h.X - s / 2 - 1, 'Float', h.Y - s / 2 - 1
              , 'Float', s + 2, 'Float', s + 2)
        DllCall('gdiplus\GdipFillRectangle', 'UPtr', pGfx, 'UPtr', br
              , 'Float', h.X - s / 2, 'Float', h.Y - s / 2, 'Float', s, 'Float', s)
    }
    MarkupDelBrush(br)
    MarkupDelBrush(wb)
}

; ==============================================================================
; HIT TESTING
; ==============================================================================

MarkupDistToSeg(px, py, ax, ay, bx, by) {
    dx := bx - ax, dy := by - ay
    len2 := dx * dx + dy * dy
    if (len2 = 0)
        return Sqrt((px - ax) ** 2 + (py - ay) ** 2)
    t := ((px - ax) * dx + (py - ay) * dy) / len2
    t := Max(0, Min(1, t))
    cx := ax + t * dx, cy := ay + t * dy
    return Sqrt((px - cx) ** 2 + (py - cy) ** 2)
}

; Is the display-space point on this object?  Line-like objects get a distance
; test against the stroke, everything else its display bounding box, so a click
; anywhere inside a rectangle picks it up rather than only on its edge.
MarkupHitObj(snip, o, m, dx, dy) {
    slop := Max(6, o.Thick + 4)
    if (o.Type = 'line' || o.Type = 'arrow') {
        MarkupXform(m, o.X1, o.Y1, &ax, &ay)
        MarkupXform(m, o.X2, o.Y2, &bx, &by)
        return MarkupDistToSeg(dx, dy, ax, ay, bx, by) <= slop
    }
    if (o.Type = 'pen') {
        i := 1
        while (i + 3 <= o.Pts.Length) {
            MarkupXform(m, o.Pts[i],     o.Pts[i + 1], &ax, &ay)
            MarkupXform(m, o.Pts[i + 2], o.Pts[i + 3], &bx, &by)
            if (MarkupDistToSeg(dx, dy, ax, ay, bx, by) <= slop)
                return true
            i += 2
        }
        return false
    }
    MarkupBoundsDisplay(snip, o, m, &x1, &y1, &x2, &y2)
    if (o.Type = 'callout') {
        MarkupXform(m, o.TailX, o.TailY, &tx, &ty)
        if (Abs(dx - tx) <= 8 && Abs(dy - ty) <= 8)
            return true
    }
    return (dx >= x1 - 2 && dx <= x2 + 2 && dy >= y1 - 2 && dy <= y2 + 2)
}

; Topmost object under the point, or 0.  Iterates backwards because the list is
; in paint order, so the LAST match is the one visually on top.
MarkupHitTest(snip, dx, dy) {
    if !snip.HasProp('Markup')
        return 0
    m := MarkupMatrix(snip, 'display')
    if !m
        return 0
    found := 0
    i := snip.Markup.Objs.Length
    while (i >= 1) {
        if MarkupHitObj(snip, snip.Markup.Objs[i], m, dx, dy) {
            found := snip.Markup.Objs[i]
            break
        }
        i--
    }
    DllCall('gdiplus\GdipDeleteMatrix', 'UPtr', m)
    return found
}

; Which handle of the selected object is under the point, or ''.
MarkupHitHandle(snip, dx, dy) {
    if !MarkupState.Sels.Length
        return ''
    m := MarkupMatrix(snip, 'display')
    if !m
        return ''
    hit := ''
    tol := MarkupCfg.HandleSize + 3
    list := (MarkupState.Sels.Length > 1) ? MarkupGroupHandleList(snip, m)
                                          : MarkupHandleList(snip, MarkupState.Sels[1], m)
    for h in list {
        if (Abs(dx - h.X) <= tol && Abs(dy - h.Y) <= tol) {
            hit := h.Id
            break
        }
    }
    DllCall('gdiplus\GdipDeleteMatrix', 'UPtr', m)
    return hit
}

; ==============================================================================
; RENDER  (markup's own fast path)
; ==============================================================================
; The crop never changes during a markup gesture, so there is no need to re-cut
; it from the master the way RenderSnipFast does.  This rebuilds only the
; display transform (which is where both compose hooks live) and swaps the
; Picture's bitmap via STM_SETIMAGE — no window move, no control recreate.  That
; keeps a drag smooth no matter how many objects are on the snip.
MarkupRender(snip) {
    display := BuildDisplayBitmap(snip)
    if !display
        return
    hBitmap := GDIp.CreateHBITMAPFromBitmap(display)
    GDIp.DisposeImage(display)
    oldHbm := SendMessage(0x0172, 0, hBitmap, snip.GuiObj.Pic.Hwnd)   ; STM_SETIMAGE
    if oldHbm
        DllCall('DeleteObject', 'Ptr', oldHbm)
}

; ==============================================================================
; MOUSE
; ==============================================================================
;
; The core's WM_LBUTTONDOWN hands us the click first when markup mode is on for
; that snip.  Returning TRUE means "handled, don't move the window".
;
; The gesture split is what keeps markup from feeling like a mode:
;   Select tool, empty canvas        → we return false and the window drags,
;                                      exactly as it always has.  Muscle memory
;                                      survives.
;   Select tool, on an object        → move it (and everything else selected).
;   Select tool, on a handle         → resize/reshape it; with several objects
;                                      selected the handles belong to the group
;                                      box and scale all of them together.
;   Shift+click an object            → add it to / remove it from the selection.
;   Shift+drag on empty canvas       → rubber-band, adds what it sweeps up.
;   Ctrl+A                           → select everything.
;   Any drawing tool                 → draw.
; Tools are sticky (three arrows in a row without re-picking), and V or Esc
; comes back to Select.

MarkupOnLButton(hwnd) {
    global guiSnips
    if (MarkupState.Active != hwnd || !guiSnips.Has(hwnd))
        return false
    snip := guiSnips[hwnd]
    MarkupEnsure(snip)
    MarkupCursorPos(snip, &dx, &dy)

    if (MarkupState.Tool = 'select') {
        extend := GetKeyState('Shift', 'P')
        h := MarkupHitHandle(snip, dx, dy)
        if (h != '') {
            MarkupDragHandle(snip, h)
            return true
        }
        obj := MarkupHitTest(snip, dx, dy)
        if !obj {
            ; Shift+drag on empty canvas sweeps a rubber band.  A PLAIN drag on
            ; empty canvas is still the window move it always was — that is the
            ; behaviour worth protecting, so the marquee took the modifier.
            if extend {
                MarkupMarquee(snip, dx, dy)
                return true
            }
            if MarkupState.Sels.Length {
                MarkupState.Sels := []
                MarkupSyncPalette()
                MarkupRender(snip)
            }
            return false                     ; empty canvas → core moves the window
        }
        if extend {                          ; Shift+click toggles one object
            MarkupToggleSel(obj)
            MarkupSyncPalette()
            MarkupRender(snip)
            return true
        }
        ; Clicking something already in the group keeps the group, so you can
        ; grab any member and drag all of them.  Clicking outside it selects
        ; just that object.
        if !MarkupIsSelected(obj)
            MarkupState.Sel := obj
        MarkupSyncPalette()
        MarkupRender(snip)
        MarkupDragMove(snip)
        return true
    }

    MarkupStartDraw(snip, dx, dy)
    return true
}

; Wait for the button to come up without a drag having started, so a plain click
; doesn't nudge anything. Returns true once travel clears the slop.
MarkupDragLoop(snip, onMove) {
    static SLOP := 3
    CoordMode('Mouse', 'Screen')
    MarkupCursorPos(snip, &sx, &sy)
    moved := false
    while GetKeyState('LButton', 'P') {
        MarkupCursorPos(snip, &cx, &cy)
        if (!moved && (Abs(cx - sx) + Abs(cy - sy)) >= SLOP)
            moved := true
        if moved
            onMove(cx, cy, sx, sy)
        Sleep 8
    }
    return moved
}

; Move the selected object.  The delta is computed in MASTER space (both the
; anchor and the current position are un-transformed first), so dragging feels
; right on a rotated or flipped snip: the object follows the cursor rather than
; shooting off at the rotation angle.
; Move every selected object.  The delta is computed in MASTER space (both the
; anchor and the current position are un-transformed first), so dragging feels
; right on a rotated or flipped snip: the objects follow the cursor rather than
; shooting off at the rotation angle.
MarkupDragMove(snip) {
    ; The undo entry is pushed up front (the loop mutates the objects as it
    ; goes) and popped again if the gesture turned out to be a plain click.
    ; Otherwise selecting an object would leave a no-op step and Ctrl+Z would
    ; look broken.
    MarkupPushUndo(snip)
    MarkupCursorPos(snip, &sdx, &sdy)
    MarkupToMaster(snip, sdx, sdy, &smx, &smy)
    sels := MarkupState.Sels
    origs := []
    for o in sels
        origs.Push(MarkupCloneObj(o))
    MarkupState.Dragging := true
    moved := MarkupDragLoop(snip, (cx, cy, *) => MarkupApplyMove(snip, sels, origs, smx, smy, cx, cy))
    MarkupState.Dragging := false
    if !moved
        snip.Markup.Undo.Pop()
    MarkupRender(snip)
}

MarkupApplyMove(snip, sels, origs, smx, smy, cx, cy) {
    MarkupToMaster(snip, cx, cy, &mx, &my)
    ddx := mx - smx, ddy := my - smy
    for idx, o in sels {
        orig := origs[idx]
        o.X1 := orig.X1 + ddx, o.Y1 := orig.Y1 + ddy
        o.X2 := orig.X2 + ddx, o.Y2 := orig.Y2 + ddy
        o.TailX := orig.TailX + ddx, o.TailY := orig.TailY + ddy
        if orig.Pts.Length {
            pts := []
            i := 1
            while (i <= orig.Pts.Length)
                pts.Push(orig.Pts[i] + ddx, orig.Pts[i + 1] + ddy), i += 2
            o.Pts := pts
        }
    }
    MarkupRender(snip)
}

; Rubber-band select.  The band lives in DISPLAY coordinates (it is a screen
; gesture, not an image feature) and is drawn by MarkupDrawChrome; the objects
; it catches are tested with their display bounds, so it behaves sensibly on a
; rotated snip too.  It ADDS to the existing selection, because you got here by
; holding Shift.
; Named rather than a fat-arrow lambda: a `=>` at the end of a line is NOT one
; of AHK's line-continuation operators, so the multi-statement body would have
; had to sit on one very long line.
MarkupBandTo(snip, cx, cy, *) {
    MarkupState.Band.X2 := cx
    MarkupState.Band.Y2 := cy
    MarkupRender(snip)
}

MarkupMarquee(snip, dx, dy) {
    MarkupState.Band := { X1: dx, Y1: dy, X2: dx, Y2: dy }
    moved := MarkupDragLoop(snip, MarkupBandTo.Bind(snip))
    b := MarkupState.Band
    MarkupState.Band := 0
    if moved {
        bx1 := Min(b.X1, b.X2), by1 := Min(b.Y1, b.Y2)
        bx2 := Max(b.X1, b.X2), by2 := Max(b.Y1, b.Y2)
        m := MarkupMatrix(snip, 'display')
        if m {
            for o in snip.Markup.Objs {
                MarkupBoundsDisplay(snip, o, m, &ox1, &oy1, &ox2, &oy2)
                if (ox1 <= bx2 && ox2 >= bx1 && oy1 <= by2 && oy2 >= by1)
                    if !MarkupIsSelected(o)
                        MarkupState.Sels.Push(o)
            }
            DllCall('gdiplus\GdipDeleteMatrix', 'UPtr', m)
        }
        MarkupSyncPalette()
    }
    MarkupRender(snip)
}

MarkupDragHandle(snip, id) {
    if (MarkupState.Sels.Length > 1) {
        MarkupDragGroupHandle(snip, id)
        return
    }
    o := MarkupState.Sel
    ; A callout whose base has never been adjusted carries TailA/TailB of 0/0,
    ; meaning "use the default width".  Write the current effective values onto
    ; it first, or the first pixel of the drag would snap the base to nothing.
    if (o.Type = 'callout' && (id = 'tail1' || id = 'tail2'))
        MarkupCalloutMaterialize(o)
    MarkupPushUndo(snip)
    orig := MarkupCloneObj(o)
    MarkupState.Dragging := true
    moved := MarkupDragLoop(snip, (cx, cy, *) => MarkupApplyHandle(snip, o, orig, id, cx, cy))
    MarkupState.Dragging := false
    if !moved
        snip.Markup.Undo.Pop()
    ; A resize can leave X1 > X2; normalise so later maths doesn't have to care.
    if (o.Type != 'line' && o.Type != 'arrow') {
        a := Min(o.X1, o.X2), b := Max(o.X1, o.X2)
        c := Min(o.Y1, o.Y2), d := Max(o.Y1, o.Y2)
        o.X1 := a, o.X2 := b, o.Y1 := c, o.Y2 := d
    }
    MarkupRender(snip)
}

; Group resize.  Everything is expressed as "the union box changed from THIS to
; THAT", and each object's geometry is re-mapped through the same two scale
; factors — so an arrow inside the group keeps its angle and its position
; relative to the others, and nothing has to know which handle was grabbed.
;
; Working from clones of the ORIGINAL geometry on every mouse-move (rather than
; from the live objects) is what keeps the scaling from compounding as you drag.
MarkupDragGroupHandle(snip, id) {
    if !MarkupSelUnionMaster(&ox1, &oy1, &ox2, &oy2)
        return
    MarkupPushUndo(snip)
    sels  := MarkupState.Sels
    origs := []
    for o in sels
        origs.Push(MarkupCloneObj(o))
    box := { X1: ox1, Y1: oy1, X2: ox2, Y2: oy2 }
    MarkupState.Dragging := true
    moved := MarkupDragLoop(snip, (cx, cy, *) => MarkupApplyGroupHandle(snip, sels, origs, box, id, cx, cy))
    MarkupState.Dragging := false
    if !moved
        snip.Markup.Undo.Pop()
    MarkupRender(snip)
}

MarkupApplyGroupHandle(snip, sels, origs, box, id, cx, cy) {
    static MINSZ := 6
    MarkupToMaster(snip, cx, cy, &mx, &my)
    nx1 := box.X1, ny1 := box.Y1, nx2 := box.X2, ny2 := box.Y2
    if InStr(id, 'n')
        ny1 := my
    if InStr(id, 's')
        ny2 := my
    if InStr(id, 'w')
        nx1 := mx
    if InStr(id, 'e')
        nx2 := mx
    ; Don't let the box collapse or invert; a zero-width group would divide by
    ; zero below and a flipped one would mirror every object mid-drag.
    if (nx2 - nx1 < MINSZ)
        InStr(id, 'w') ? (nx1 := nx2 - MINSZ) : (nx2 := nx1 + MINSZ)
    if (ny2 - ny1 < MINSZ)
        InStr(id, 'n') ? (ny1 := ny2 - MINSZ) : (ny2 := ny1 + MINSZ)

    ow := Max(1, box.X2 - box.X1), oh := Max(1, box.Y2 - box.Y1)
    sx := (nx2 - nx1) / ow,        sy := (ny2 - ny1) / oh
    ; Font size follows the geometric mean of the two factors, so labels inside
    ; a shrunken group shrink with it.  Stroke thickness deliberately does NOT:
    ; a scaled-down hairline reads as a rendering bug, not as a smaller arrow.
    fs := Sqrt(Abs(sx * sy))

    for idx, o in sels {
        g := origs[idx]
        o.X1 := nx1 + (g.X1 - box.X1) * sx,    o.Y1 := ny1 + (g.Y1 - box.Y1) * sy
        o.X2 := nx1 + (g.X2 - box.X1) * sx,    o.Y2 := ny1 + (g.Y2 - box.Y1) * sy
        o.TailX := nx1 + (g.TailX - box.X1) * sx
        o.TailY := ny1 + (g.TailY - box.Y1) * sy
        if g.Pts.Length {
            pts := []
            i := 1
            while (i <= g.Pts.Length) {
                pts.Push(nx1 + (g.Pts[i]     - box.X1) * sx
                       , ny1 + (g.Pts[i + 1] - box.Y1) * sy)
                i += 2
            }
            o.Pts := pts
        }
        if (o.Type = 'text' || o.Type = 'number' || o.Type = 'callout')
            o.FontSize := Max(6, Round(g.FontSize * fs))
        if (o.Type = 'callout' && g.TailB - g.TailA >= 2)
            o.TailA := g.TailA * fs, o.TailB := g.TailB * fs
    }
    MarkupRender(snip)
}

MarkupApplyHandle(snip, o, orig, id, cx, cy) {
    MarkupToMaster(snip, cx, cy, &mx, &my)
    switch id {
    case 'p1':  o.X1 := mx, o.Y1 := my
    case 'p2':  o.X2 := mx, o.Y2 := my
    case 'tip': o.TailX := mx, o.TailY := my
    case 'tail1', 'tail2':
        ; Project the cursor onto the edge the base sits on and store the signed
        ; distance from the crossing point.  Clamped to the straight part of the
        ; edge (the corner radii are excluded) with a minimum gap between the
        ; two ends, so the tail can't invert or swallow a corner.
        MarkupBoundsMaster(o, &bx1, &by1, &bx2, &by2)
        rr := MarkupCalloutRadius(o, bx2 - bx1, by2 - by1)
        g  := MarkupCalloutGeom(o, bx1, by1, bx2, by2, o.TailX, o.TailY, rr)
        if !g
            return
        sOff := (mx - g.Ax) * g.Ux + (my - g.Ay) * g.Uy
        if (id = 'tail1')
            o.TailA := Max(g.Lo, Min(o.TailB - 4, sOff))
        else
            o.TailB := Min(g.Hi, Max(o.TailA + 4, sOff))
    default:
        ; Edge letters drive one or both axes; the opposite edge stays anchored.
        if InStr(id, 'n')
            o.Y1 := my
        if InStr(id, 's')
            o.Y2 := my
        if InStr(id, 'w')
            o.X1 := mx
        if InStr(id, 'e')
            o.X2 := mx
    }
    MarkupRender(snip)
}

; ── Creating a new object ────────────────────────────────────────────────────

MarkupStartDraw(snip, dx, dy) {
    mk := MarkupEnsure(snip)
    MarkupToMaster(snip, dx, dy, &mx, &my)
    tool := MarkupState.Tool

    ; Click-placed types: no drag, so they are created and finished here.
    if (tool = 'text' || tool = 'number') {
        MarkupPushUndo(snip)
        o := MarkupNewObj(tool)
        o.X1 := mx, o.Y1 := my, o.X2 := mx, o.Y2 := my
        if (tool = 'text') {
            KeyWait('LButton')            ; don't open the dialog mid-click
            txt := MarkupTextPrompt('', 'Text label')
            if (txt = '') {
                mk.Undo.Pop()                    ; cancelled — undo entry not earned
                return
            }
            o.Text := txt
        } else {
            o.Num := mk.NextNum++
            ; Centre the badge on the click. The diameter depends on how many
            ; digits the number has, so it can only be worked out once Num is
            ; set — which is why this isn't in MarkupNewObj.
            MarkupTextSize(o, &tw, &th)
            dia := Max(tw, th) + o.FontSize * 0.7
            o.X1 -= dia / 2, o.Y1 -= dia / 2
        }
        mk.Objs.Push(o)
        MarkupState.Sel := o
        MarkupSyncPalette()
        MarkupRender(snip)
        return
    }

    MarkupPushUndo(snip)
    o := MarkupNewObj(tool)
    o.X1 := mx, o.Y1 := my, o.X2 := mx, o.Y2 := my
    if (tool = 'pen')
        o.Pts := [mx, my]
    if (tool = 'callout')
        o.TailX := mx, o.TailY := my
    mk.Objs.Push(o)
    MarkupState.Sel := o

    MarkupState.Dragging := true
    moved := MarkupDragLoop(snip, (cx, cy, *) => MarkupExtendDraw(snip, o, cx, cy))
    MarkupState.Dragging := false

    if !moved {
        ; A click with no drag produced a zero-size shape — drop it rather than
        ; leaving an invisible object for the user to wonder about later.
        mk.Objs.Pop()
        mk.Undo.Pop()
        MarkupState.Sel := 0
        MarkupRender(snip)
        return
    }

    if (o.Type != 'line' && o.Type != 'arrow' && o.Type != 'pen') {
        a := Min(o.X1, o.X2), b := Max(o.X1, o.X2)
        c := Min(o.Y1, o.Y2), d := Max(o.Y1, o.Y2)
        o.X1 := a, o.X2 := b, o.Y1 := c, o.Y2 := d
    }
    if (o.Type = 'callout') {
        ; Default the tail to below-left of the bubble, pointing back at where
        ; the drag began.  Drag the tip handle to aim it anywhere.
        o.TailX := o.X1 - (o.X2 - o.X1) * 0.25
        o.TailY := o.Y2 + (o.Y2 - o.Y1) * 0.5
        txt := MarkupTextPrompt('', 'Callout text')
        o.Text := txt
    }
    MarkupSyncPalette()
    MarkupRender(snip)
}

MarkupExtendDraw(snip, o, cx, cy) {
    MarkupToMaster(snip, cx, cy, &mx, &my)
    if (o.Type = 'pen') {
        ; Only record a point once the cursor has actually travelled, so a slow
        ; drag doesn't pile up hundreds of coincident points.
        n := o.Pts.Length
        if (n < 2 || Abs(mx - o.Pts[n - 1]) + Abs(my - o.Pts[n]) >= 2)
            o.Pts.Push(mx, my)
        o.X2 := mx, o.Y2 := my
    } else if (GetKeyState('Shift', 'P') && (o.Type = 'line' || o.Type = 'arrow')) {
        ; Shift constrains a line or arrow to the nearest 45°.
        ddx := mx - o.X1, ddy := my - o.Y1
        if (Abs(ddx) > Abs(ddy) * 2.414)
            o.X2 := mx, o.Y2 := o.Y1
        else if (Abs(ddy) > Abs(ddx) * 2.414)
            o.X2 := o.X1, o.Y2 := my
        else {
            s := (Abs(ddx) + Abs(ddy)) / 2
            o.X2 := o.X1 + (ddx < 0 ? -s : s)
            o.Y2 := o.Y1 + (ddy < 0 ? -s : s)
        }
    } else if (GetKeyState('Shift', 'P') && (o.Type = 'rect' || o.Type = 'ellipse')) {
        s := Max(Abs(mx - o.X1), Abs(my - o.Y1))       ; Shift = square / circle
        o.X2 := o.X1 + ((mx < o.X1) ? -s : s)
        o.Y2 := o.Y1 + ((my < o.Y1) ? -s : s)
    } else {
        o.X2 := mx, o.Y2 := my
    }
    MarkupRender(snip)
}

; Nudge the selection with the arrow keys.  Plain arrows are unbound on a snip
; by design (see the core's hotkey block), so there is nothing to fight here.
MarkupNudgeSel(ddx, ddy) {
    global guiSnips
    hwnd := MarkupState.Active
    if (!guiSnips.Has(hwnd) || !MarkupState.Sels.Length)
        return
    snip := guiSnips[hwnd]
    MarkupPushUndo(snip)
    for o in MarkupState.Sels {
        o.X1 += ddx, o.X2 += ddx, o.TailX += ddx
        o.Y1 += ddy, o.Y2 += ddy, o.TailY += ddy
        i := 1
        while (i <= o.Pts.Length)
            o.Pts[i] += ddx, o.Pts[i + 1] += ddy, i += 2
    }
    MarkupRender(snip)
}

; ==============================================================================
; TEXT ENTRY
; ==============================================================================
; A small modal dialog rather than an in-place caret over the Picture control.
; In-place editing would mean a transparent Edit positioned and rotated to match
; the annotation, which is a lot of machinery for something the user looks at
; for four seconds. Multi-line is supported: GdipDrawString honours newlines.
; The prompt's state lives in a class rather than in function statics so the
; Ctrl+Enter hotkey at the bottom of this file can reach it.  A `Default` button
; does NOT catch Enter here: the Edit has WantReturn (you want newlines in a
; callout), which swallows the key before the dialog ever sees it — so the
; accelerator has to be a real hotkey, scoped to this window.
class MarkupPrompt {
    static Hwnd  := 0
    static Edit  := 0
    static Done  := 0
    static Value := ''
}

MarkupPromptActive() => MarkupPrompt.Hwnd && WinActive('ahk_id ' MarkupPrompt.Hwnd)

MarkupPromptAccept(*) {
    if MarkupPrompt.Edit
        MarkupPrompt.Value := MarkupPrompt.Edit.Value
    MarkupPrompt.Done := 1
}

MarkupPromptCancel(*) {
    MarkupPrompt.Value := ''
    MarkupPrompt.Done  := 1
}

MarkupTextPrompt(initial := '', title := 'Text') {
    MarkupPrompt.Done := 0, MarkupPrompt.Value := ''

    g := Gui('+AlwaysOnTop +ToolWindow +OwnDialogs', title)
    g.MarginX := 10, g.MarginY := 10
    g.SetFont('s10')
    ed := g.Add('Edit', 'w300 h70 Multi WantReturn', initial)
    g.Add('Text', 'xm y+6 cGray', 'Ctrl+Enter or OK to accept  ·  Esc cancels')
    ok := g.Add('Button', 'xm y+8 w90 Default', 'OK')
    cn := g.Add('Button', 'x+8 w90', 'Cancel')

    ok.OnEvent('Click', MarkupPromptAccept)
    cn.OnEvent('Click', MarkupPromptCancel)
    g.OnEvent('Close',  MarkupPromptCancel)
    g.OnEvent('Escape', MarkupPromptCancel)

    MarkupPrompt.Edit := ed
    g.Show()
    MarkupPrompt.Hwnd := g.Hwnd      ; set AFTER Show, so the hotkey context
    ed.Focus()                        ; can't match a window that isn't up yet
    while !MarkupPrompt.Done
        Sleep 20
    MarkupPrompt.Hwnd := 0, MarkupPrompt.Edit := 0
    value := MarkupPrompt.Value
    g.Destroy()
    ; The dialog stole focus (it has to, you type into it).  Hand it straight
    ; back to the snip, or the single-letter tool keys stay dead until the user
    ; happens to click the image again.
    if (MarkupState.Active && WinExist('ahk_id ' MarkupState.Active))
        WinActivate('ahk_id ' MarkupState.Active)
    return value
}

MarkupEditSelText(hwnd := 0) {
    global guiSnips
    if !hwnd
        hwnd := MarkupState.Active
    o := MarkupState.Sel
    if (!o || !guiSnips.Has(hwnd))
        return
    if (o.Type != 'text' && o.Type != 'callout') {
        ToolTip('That object has no text')
        SetTimer(() => ToolTip(), -1200)
        return
    }
    txt := MarkupTextPrompt(o.Text, 'Edit text')
    if (txt = '' && o.Type = 'text')
        return                              ; emptying a text object would hide it
    snip := guiSnips[hwnd]
    MarkupPushUndo(snip)
    o.Text := txt
    MarkupRender(snip)
}

; ==============================================================================
; IMAGES
; ==============================================================================
; Pasted images join the per-snip pool and the object stores an INDEX, never a
; raw bitmap pointer — see the note on MarkupEnsure for why that matters to the
; snapshot undo model.

MarkupAddImage(hwnd, pImg) {
    global guiSnips
    if (!pImg || !guiSnips.Has(hwnd))
        return
    snip := guiSnips[hwnd]
    mk   := MarkupEnsure(snip)
    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', pImg, 'UInt*', &iw := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', pImg, 'UInt*', &ih := 0)
    if (!iw || !ih) {
        GDIp.DisposeImage(pImg)
        return
    }
    ; Fit into three-quarters of the visible crop, keeping the aspect ratio, so
    ; a full-screen paste doesn't arrive bigger than the snip it lands on.
    maxW := snip.Crop.W * 0.75, maxH := snip.Crop.H * 0.75
    sc   := Min(1, Min(maxW / iw, maxH / ih))
    w    := Round(iw * sc), h := Round(ih * sc)

    mk.Images.Push(pImg)
    MarkupPushUndo(snip)
    o := MarkupNewObj('image')
    o.ImgIdx := mk.Images.Length
    o.X1 := snip.Crop.X + (snip.Crop.W - w) / 2
    o.Y1 := snip.Crop.Y + (snip.Crop.H - h) / 2
    o.X2 := o.X1 + w, o.Y2 := o.Y1 + h
    o.Outline := false
    mk.Objs.Push(o)
    MarkupState.Sel := o
    if !MarkupState.Active
        MarkupBegin(hwnd)
    else
        MarkupRender(snip)
}

MarkupPasteImage(hwnd := 0) {
    if !hwnd
        hwnd := MarkupState.Active ? MarkupState.Active : WinGetID('A')
    if !DllCall('OpenClipboard', 'Ptr', 0) {
        ToolTip('Clipboard busy'), SetTimer(() => ToolTip(), -1200)
        return
    }
    hbm := DllCall('GetClipboardData', 'UInt', 2, 'Ptr')     ; 2 = CF_BITMAP
    pImg := hbm ? GDIp.CreateBitmapFromHBITMAP(hbm) : 0
    DllCall('CloseClipboard')
    if !pImg {
        ToolTip('No image on the clipboard'), SetTimer(() => ToolTip(), -1400)
        return
    }
    MarkupAddImage(hwnd, pImg)
}

MarkupImageFromFile(hwnd := 0) {
    if !hwnd
        hwnd := MarkupState.Active ? MarkupState.Active : WinGetID('A')
    sel := FileSelect(3, , 'Add Image', 'Images (*.png; *.jpg; *.jpeg; *.bmp; *.gif)')
    if (sel = '')
        return
    DllCall('gdiplus\GdipCreateBitmapFromFile', 'WStr', sel, 'UPtr*', &pImg := 0)
    if !pImg {
        ToolTip('Could not load that image'), SetTimer(() => ToolTip(), -1400)
        return
    }
    MarkupAddImage(hwnd, pImg)
}

; ==============================================================================
; TOOL PALETTE
; ==============================================================================
;
; A SEPARATE always-on-top window, not a toolbar bolted onto the snip.  That is
; deliberate: the snip window's whole identity is "a picture floating there with
; no chrome", and docking controls inside it would fight the border, bevel,
; shadow and margin code and fall apart on a small snip.  As a separate window
; the palette also serves whichever snip is active rather than needing one copy
; per snip, and RenderSnip never learns it exists — structurally the same
; arrangement as the drop shadow.
;
; WS_EX_NOACTIVATE (0x08000000) is the detail that makes it feel right: clicking
; a palette control does NOT take focus away from the snip, so the single-letter
; tool keys keep working and the snip stays the active window throughout.

; label, internal name, key hint — one row of the tool list.
MarkupToolTable() {
    static t := [ ['Select',      'select',    'V']
                , ['Rectangle',   'rect',      'R']
                , ['Ellipse',     'ellipse',   'E']
                , ['Line',        'line',      'L']
                , ['Arrow',       'arrow',     'A']
                , ['Pen',         'pen',       'P']
                , ['Highlighter', 'highlight', 'H']
                , ['Text',        'text',      'T']
                , ['Number',      'number',    'N']
                , ['Callout',     'callout',   'C']
                , ['Blur',        'blur',      'B'] ]
    return t
}

MarkupSwatches() {
    static c := [0xE81123, 0xFF8C00, 0xFFF200, 0x00B050, 0x00B7C3, 0x0078D7
               , 0x8E24AA, 0xFF00A0, 0xFFFFFF, 0x9E9E9E, 0x000000, 0x5D4037]
    return c
}

MarkupShowPalette() {
    if MarkupState.Palette {
        MarkupPositionPalette()
        MarkupState.Palette.Show('NoActivate')
        MarkupSyncPalette()
        return
    }
    g := Gui('+AlwaysOnTop +ToolWindow +E0x08000000', 'Markup')
    g.MarginX := 10, g.MarginY := 10
    g.SetFont('s9', 'Segoe UI')
    ctl := MarkupState.Ctl := Map()

    ; Absolute x/y throughout.  Relative positioning (y+8 / yp) is tidier to
    ; read but it makes the swatch grid, which wraps mid-row, a nuisance — and a
    ; palette that lays itself out differently under a non-default system font
    ; is worse than a few explicit numbers.
    items := []
    for row in MarkupToolTable()
        items.Push(row[1] '  (' row[3] ')')
    ctl['tools'] := g.Add('ListBox', 'x10 y10 w170 h186 Choose1', items)
    ctl['tools'].OnEvent('Change', MarkupPal_Tool)

    g.Add('Text', 'x10 y204 w170 h16', 'Color  (Ctrl+click sets fill)')
    i := 0
    for col in MarkupSwatches() {
        xx := 10 + Mod(i, 6) * 27
        yy := (i < 6) ? 224 : 251
        sw := g.Add('Text', 'x' xx ' y' yy ' w22 h22 Border Background' Format('{:06X}', col))
        sw.OnEvent('Click', MarkupPal_Color.Bind(col))
        i++
    }

    ctl['fill']    := g.Add('Checkbox', 'x10 y284 w170 h18', 'Fill shape')
    ctl['outline'] := g.Add('Checkbox', 'x10 y306 w170 h18', 'Outline (legibility halo)')
    ctl['shadow']  := g.Add('Checkbox', 'x10 y328 w170 h18', 'Drop shadow')
    ctl['fill'].OnEvent('Click',    MarkupPal_Check.Bind('Fill'))
    ctl['outline'].OnEvent('Click', MarkupPal_Check.Bind('Outline'))
    ctl['shadow'].OnEvent('Click',  MarkupPal_Check.Bind('Shadow'))

    g.Add('Text', 'x10 y356 w44 h22 +0x200', 'Width')
    ctl['thick'] := g.Add('DropDownList', 'x58 y353 w56'
                        , ['1','2','3','4','5','6','8','10','12','16'])
    g.Add('Text', 'x10 y384 w44 h22 +0x200', 'Font')
    ctl['font']  := g.Add('DropDownList', 'x58 y381 w56'
                        , ['10','12','14','16','18','20','24','28','32','40','48'])
    ctl['thick'].OnEvent('Change', MarkupPal_Num.Bind('Thick'))
    ctl['font'].OnEvent('Change',  MarkupPal_Num.Bind('FontSize'))

    ctl['undo'] := g.Add('Button', 'x10  y416 w56 h26', 'Undo')
    ctl['redo'] := g.Add('Button', 'x70  y416 w56 h26', 'Redo')
    ctl['del']  := g.Add('Button', 'x130 y416 w50 h26', 'Delete')
    ctl['undo'].OnEvent('Click', (*) => MarkupUndo())
    ctl['redo'].OnEvent('Click', (*) => MarkupRedo())
    ctl['del'].OnEvent('Click',  (*) => MarkupDeleteSel())

    ctl['done'] := g.Add('Button', 'x10 y450 w170 h26', 'Done  (Esc)')
    ctl['done'].OnEvent('Click', (*) => MarkupEnd())

    g.OnEvent('Close', (*) => MarkupEnd())
    MarkupState.Palette := g
    ; Show('Hide') creates the window without displaying it, so GetPos in
    ; MarkupPositionPalette has real dimensions to work with. Positioning after
    ; a visible Show would make the palette jump on first open.
    g.Show('Hide')
    MarkupPositionPalette()
    g.Show('NoActivate')
    MarkupSyncPalette()
}

MarkupHidePalette() {
    if MarkupState.Palette {
        try {
            MarkupState.Palette.GetPos(&px, &py)
            MarkupState.PalX := px, MarkupState.PalY := py
        }
        MarkupState.Palette.Hide()
    }
}

; Park the palette beside the snip: left if there is room, otherwise right,
; otherwise clamped onto the monitor. A position the user has dragged it to is
; remembered for the rest of the session and wins over both.
MarkupPositionPalette() {
    global guiSnips
    g := MarkupState.Palette
    if (!g || !MarkupState.Active || !guiSnips.Has(MarkupState.Active))
        return
    if (MarkupState.PalX != '') {
        g.Move(MarkupState.PalX, MarkupState.PalY)
        return
    }
    g.GetPos(, , &pw, &ph)
    rect := Buffer(16, 0)
    DllCall('GetWindowRect', 'Ptr', MarkupState.Active, 'Ptr', rect)
    sl := NumGet(rect, 0, 'Int'), st := NumGet(rect,  4, 'Int')
    sr := NumGet(rect, 8, 'Int')
    GetVirtualScreen(&vx, &vy, &vw, &vh)
    gap := MarkupCfg.PaletteGap
    x := sl - pw - gap
    if (x < vx)
        x := sr + gap
    if (x + pw > vx + vw)
        x := Max(vx, vx + vw - pw)
    y := Max(vy, Min(st, vy + vh - ph))
    g.Move(x, y)
}

; Reflect the current selection (or, with nothing selected, the defaults for the
; NEXT object) in the style controls.  One control set doing both jobs is the
; whole trick that keeps "draw an arrow, then recolour it" from needing a
; properties dialog.
MarkupSyncPalette() {
    if !MarkupState.Palette
        return
    ctl := MarkupState.Ctl
    ; With a group selected the controls show the PRIMARY (first) object, but
    ; changing one applies to the whole group — see MarkupApplyStyle.
    o   := MarkupState.Sel
    thick := o ? o.Thick    : MarkupCfg.Thickness
    fsize := o ? o.FontSize : MarkupCfg.FontSize
    try ctl['fill'].Value    := (o ? o.Fill    : false) ? 1 : 0
    try ctl['outline'].Value := (o ? o.Outline : MarkupCfg.Outline) ? 1 : 0
    try ctl['shadow'].Value  := (o ? o.Shadow  : MarkupCfg.Shadow)  ? 1 : 0
    try ctl['thick'].Text    := String(thick)
    try ctl['font'].Text     := String(fsize)
    for i, row in MarkupToolTable()
        if (row[2] = MarkupState.Tool) {
            try ctl['tools'].Value := i
            break
        }
}

MarkupPal_Tool(ctrl, *) {
    v := ctrl.Value
    if v
        MarkupSetTool(MarkupToolTable()[v][2])
}

MarkupSetTool(name) {
    MarkupState.Tool := name
    ; Picking a drawing tool clears the selection, so the style controls
    ; immediately describe what you are about to draw rather than what you last
    ; had selected.
    if (name != 'select' && MarkupState.Sels.Length) {
        global guiSnips
        MarkupState.Sels := []
        if guiSnips.Has(MarkupState.Active)
            MarkupRender(guiSnips[MarkupState.Active])
    }
    MarkupSyncPalette()
}

; Ctrl+click a swatch to set the FILL colour instead of the stroke.
MarkupPal_Color(col, *) {
    prop := GetKeyState('Ctrl', 'P') ? 'FillColor' : 'Color'
    MarkupApplyStyle(prop, col)
    if (prop = 'FillColor')
        MarkupApplyStyle('Fill', true)
}

MarkupPal_Check(prop, ctrl, *) => MarkupApplyStyle(prop, ctrl.Value ? true : false)
MarkupPal_Num(prop, ctrl, *)   => MarkupApplyStyle(prop, Integer(ctrl.Text))

; With something selected, edit THAT object. With nothing selected, change the
; default for the next one. Same control, two jobs, no modes to explain.
MarkupApplyStyle(prop, value) {
    global guiSnips
    if MarkupState.Sels.Length {
        hwnd := MarkupState.Active
        if !guiSnips.Has(hwnd)
            return
        snip := guiSnips[hwnd]
        MarkupPushUndo(snip)
        ; Applied to EVERY selected object — select three arrows, click a
        ; swatch, all three change.
        for o in MarkupState.Sels {
            o.%prop% := value
            ; A number badge's disc IS its colour, so recolouring the stroke on
            ; one that has never been given a separate fill recolours the badge.
            if (prop = 'Color' && o.Type = 'number')
                o.FillColor := value
        }
        MarkupRender(snip)
        MarkupSyncPalette()
        return
    }
    switch prop {
        case 'Color':     MarkupCfg.Color     := value
        case 'FillColor': MarkupCfg.FillColor := value
        case 'Fill':      MarkupCfg.FillShapes := value
        case 'Thick':     MarkupCfg.Thickness := value
        case 'FontSize':  MarkupCfg.FontSize  := value
        case 'Outline':   MarkupCfg.Outline   := value
        case 'Shadow':    MarkupCfg.Shadow    := value
    }
    MarkupSyncPalette()
}

; From the menu: if markup isn't running, starting it already shows the palette,
; so don't immediately toggle it back off.
MarkupPaletteMenuItem(hwnd) {
    if !MarkupState.Active
        MarkupBegin(hwnd)
    else
        MarkupTogglePalette()
}

MarkupTogglePalette() {
    if (MarkupState.Palette && DllCall('IsWindowVisible', 'Ptr', MarkupState.Palette.Hwnd))
        MarkupHidePalette()
    else
        MarkupShowPalette()
}

; ==============================================================================
; HOTKEYS
; ==============================================================================
;
; Two contexts, both narrow.  Nothing here collides with the core's snip hotkey
; block: the core deliberately leaves the plain arrows and all the bare letters
; unbound, and MarkupActive() additionally requires the marked-up snip to be the
; ACTIVE window — so a bare "R" can never escape onto anything else, including
; the text-entry dialog (a different window, so the context is false while it is
; up and you can type an R into your label).
;
; The palette is WS_EX_NOACTIVATE, so clicking its buttons does not take the
; snip out of focus and these stay live throughout.

#HotIf WinActive('SnipperWindow ahk_class AutoHotkeyGUI') && !MarkupActive()
m::         MarkupBegin() ; hide
; F3 needs a binding in BOTH contexts.  With only the MarkupActive() one it did
; nothing at all until a session had been started some other way — which looked
; like "F3 doesn't work until you open the palette from the menu once".  Out
; here it starts markup (which shows the palette); inside markup it toggles.
F3::        MarkupPaletteMenuItem(WinGetID('A')) ; hide
#HotIf

; Ctrl+Enter in the text dialog.  Scoped to that one window, so it can't leak.
#HotIf MarkupPromptActive()
^Enter::        MarkupPromptAccept() ; hide
^NumpadEnter::  MarkupPromptAccept() ; hide
#HotIf

#HotIf MarkupActive()
v::         MarkupSetTool('select') ; hide
r::         MarkupSetTool('rect') ; hide
e::         MarkupSetTool('ellipse') ; hide
l::         MarkupSetTool('line') ; hide
a::         MarkupSetTool('arrow') ; hide
p::         MarkupSetTool('pen') ; hide
h::         MarkupSetTool('highlight') ; hide
t::         MarkupSetTool('text') ; hide
n::         MarkupSetTool('number') ; hide
c::         MarkupSetTool('callout') ; hide
b::         MarkupSetTool('blur') ; hide
m::         MarkupEnd() ; hide
F2::        MarkupEditSelText() ; hide
F3::        MarkupTogglePalette() ; hide
Delete::    MarkupDeleteSel() ; hide
^a::        MarkupSelectAll() ; hide
^z::        MarkupUndo() ; hide
^y::        MarkupRedo() ; hide
^+z::       MarkupRedo() ; hide
^d::        MarkupDuplicateSel(MarkupState.Active) ; hide
^v::        MarkupPasteImage() ; hide
^PgUp::     MarkupRaiseSel(MarkupState.Active, true) ; hide
^PgDn::     MarkupRaiseSel(MarkupState.Active, false) ; hide
; Plain arrows only, deliberately.  Shift+arrow is already the core's Flip, and
; when two #HotIf variants of one key both have a true context the FIRST one
; created wins — so a Shift+arrow defined here would silently never fire, which
; is a worse outcome than not defining it.  Hold an arrow instead; key repeat
; covers the distance.
Left::      MarkupNudgeSel(-1,  0) ; hide
Right::     MarkupNudgeSel(+1,  0) ; hide
Up::        MarkupNudgeSel( 0, -1) ; hide
Down::      MarkupNudgeSel( 0, +1) ; hide
#HotIf
