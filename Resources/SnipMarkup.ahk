; ==============================================================================
; SnipMarkup.ahk  —  annotation / markup layer for ScreenSnip
;                       Version Date: 9-6-2026
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
; Two FURTHER sections, [MarkupCaps] and [MarkupDashes], hold user-defined
; arrowheads and dash patterns.  Those are deliberately NOT read through
; SnipCfg(): their key names are invented by the user, so nothing can ask for
; them by name at compile time, and they have to be re-readable at runtime for
; the style editor to work without a restart.  They are parsed a section at a
; time by MarkupLoadCustomStyles() — see the LINE STYLE REGISTRIES block.
;
; ==============================================================================

; ── Settings + presence sentinel ──────────────────────────────────────────────
; Statics, not top-level assignments: this file is #Include'd past the end of
; the auto-execute section, so top-level code here would never run.  Class
; statics initialise at load time wherever the class is declared, which is the
; same trick SnipWinDetect.ahk uses.
class MarkupCfg {
    ; Default style for a newly drawn object.  Selecting an object and changing
    ; a control on the pallet edits THAT object; changing it with nothing
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

    ; The Highlighter's colour is remembered SEPARATELY from the stroke colour,
    ; for the same reason the line styles are per-tool: picking cyan to highlight
    ; a paragraph should not silently repaint the next arrow you draw.  Clicking
    ; a swatch while the Highlighter is active edits this one instead.
    static HighlightAlpha := Integer(SnipCfg('Markup', 'HighlightAlpha', 90))
    static HighlightColor := SnipCfgHex('Markup', 'HighlightColor', 0xFFF200)
    static ArrowHeadScale := Float(SnipCfg('Markup', 'ArrowHeadScale', 3.5))

    ; Number badge disc diameter in master pixels; 0 = auto, meaning the disc is
    ; sized from the digits as it always was.  A non-zero value decouples the
    ; disc from the font — see MarkupNumDia.
    static NumberDia      := Integer(SnipCfg('Markup', 'NumberDia', 0))

    ; Path Arrow.  TurnTolerance is how far the cursor must travel ACROSS the
    ; current segment before a corner is committed: too small and hand jitter
    ; spawns phantom elbows, too large and a deliberate short jog gets eaten.
    ; It is a setting rather than a constant because the right value depends on
    ; mouse speed and DPI, and can only really be found by using it.
    static PathTurnTolerance := Integer(SnipCfg('Markup', 'PathTurnTolerance', 14))
    static PathCornerRadius  := Integer(SnipCfg('Markup', 'PathCornerRadius', 7))
    static PathMaxSegments   := Integer(SnipCfg('Markup', 'PathMaxSegments', 24))

    ; Line styling, PER TOOL.  Line, Arrow and Path Arrow are the same object as
    ; far as the renderer is concerned — the tool you pick only seeds these
    ; properties, which is what a "tool" ought to mean.  So the defaults live
    ; one per tool rather than one per script, and picking the Line tool then
    ; choosing a chevron end doesn't quietly change what Arrow draws.
    ; Values are NAMES from the cap / dash registries (see MarkupStyles); an
    ; unknown name resolves to none / solid rather than throwing.
    static LineDash      := SnipCfg('Markup', 'LineDash',      'solid')
    static LineCapStart  := SnipCfg('Markup', 'LineCapStart',  'none')
    static LineCapEnd    := SnipCfg('Markup', 'LineCapEnd',    'none')
    static ArrowDash     := SnipCfg('Markup', 'ArrowDash',     'solid')
    static ArrowCapStart := SnipCfg('Markup', 'ArrowCapStart', 'none')
    static ArrowCapEnd   := SnipCfg('Markup', 'ArrowCapEnd',   'arrow')
    static PathDash      := SnipCfg('Markup', 'PathDash',      'solid')
    static PathCapStart  := SnipCfg('Markup', 'PathCapStart',  'none')
    static PathCapEnd    := SnipCfg('Markup', 'PathCapEnd',    'arrow')
    static PenDash       := SnipCfg('Markup', 'PenDash',       'solid')
    static PenCapStart   := SnipCfg('Markup', 'PenCapStart',   'none')
    static PenCapEnd     := SnipCfg('Markup', 'PenCapEnd',     'none')

    ; Corner radius, in master pixels.  -1 means AUTO: keep whatever the type
    ; derived before this setting existed, so nothing drawn under the old code
    ; changes appearance.  Rectangles were sharp, so their auto is 0 and their
    ; default is 0; callouts derived theirs from the font size, so theirs is -1.
    static RectCorner    := Integer(SnipCfg('Markup', 'RectCorner', 0))
    static CalloutCorner := Integer(SnipCfg('Markup', 'CalloutCorner', -1))

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

    ; Ctrl+click an annotation to reach into it without leaving the tool you are
    ; drawing with.  It also works on a snip that is NOT in a markup session —
    ; annotations stay on the snip after Esc, so this is the way back in.
    ;
    ; A double-click used to do this as well and was dropped: it had to survive
    ; its own first click, which starts a draw, and the render that tidies away
    ; the discarded object could still be running when the second press arrived.
    ; OnMessage allows one thread per message, so that press was discarded and
    ; the gesture silently failed — intermittently, and worse on large snips.
    ; A single modified press has no timing window to lose.
    ;
    ; A Ctrl+click landing on bare image is always left alone, so drag-to-move
    ; is untouched.
    static CtrlClickSelect := Integer(SnipCfg('Markup', 'CtrlClickSelect', 1)) ? true : false

    ; When a double-click borrows the Select tool, remember which drawing tool
    ; was in hand and give it back at the next click on bare image.  Off makes
    ; the double-click a one-way trip to Select, as it was before.
    static StickyTool := Integer(SnipCfg('Markup', 'StickyTool', 1)) ? true : false

    ; Pallet window.  AutoShow false = hotkey-only operation for people who
    ; know the letters and don't want a second window on screen.
    static PalletAutoShow := Integer(SnipCfg('Markup', 'PalletAutoShow', 1)) ? true : false
    static PalletGap      := Integer(SnipCfg('Markup', 'PalletGap', 12))
}

; ── Mutable state ─────────────────────────────────────────────────────────────
; One markup session at a time.  Active is the hwnd of the snip being marked up
; (0 = not in markup mode), which is also what the #HotIf context tests, so the
; single-letter tool keys can't leak out onto anything else.
class MarkupState {
    static Active   := 0
    static Tool     := 'select'
    static Pallet  := ''         ; Gui object, or '' when never built
    static PalX     := ''         ; pallet position, remembered per snip
    static PalY     := ''
    static PalOwner := 0          ; which snip PalX/PalY were remembered for
    static Dragging := false
    static Band     := 0          ; live rubber-band rect (display coords) or 0
    static Ctl      := Map()      ; pallet control name → control object
    static ThickList := ''        ; which ladder the Width box is loaded with
    static HeadList  := 'arrow'   ; which ladder the Head box is loaded with
    static ColorLive := true      ; do the swatches mean anything right now?

    ; Per-tool line style, seeded from MarkupCfg on first use.  Changing a
    ; pallet control with NOTHING selected edits the entry for the current
    ; tool; with a selection it edits the objects.  See MarkupApplyStyle.
    static ToolStyle  := Map()
    static PreviewBmp := 0        ; HBITMAP behind the pallet preview strip

    ; The drawing tool a double-click borrowed Select from, or '' when Select
    ; was chosen deliberately.  See MarkupArmSticky.
    static Borrowed := ''

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

    ; The snip's own FRAME, selected as if it were an object.  It deliberately
    ; is NOT one: pushing it into Objs would mean teaching undo, Ctrl+A, the
    ; marquee, delete, duplicate, z-order and the master-space compose pass to
    ; each make an exception for a thing that has no geometry.  A flag beside
    ; Sels costs one test in the four places that actually care.
    static BorderSel := false
}

; The frame and the objects are mutually exclusive, and the rule is enforced
; HERE rather than at every assignment site: a border selection only counts
; while Sels is empty.  So anything that adds an object — Shift+click, the
; marquee, Ctrl+A, a fresh draw — drops the frame automatically, and only the
; paths that end with NOTHING selected have to clear the flag by hand.
MarkupBorderSelected() {
    return MarkupState.BorderSel && !MarkupState.Sels.Length
}

; The snip whose frame is selected, or 0.
MarkupBorderSnip() {
    global guiSnips
    if (!MarkupBorderSelected() || !guiSnips.Has(MarkupState.Active))
        return 0
    return guiSnips[MarkupState.Active]
}

; Is a click (in Picture-control display coords) on the frame rather than the
; image?  MarkupCursorPos measures from the Picture's own rect, so anything
; outside its extent is border — which makes this a bounds test rather than
; geometry, and correct at any DPI and any frame width for free.  A rotated
; snip has no frame drawn (RenderSnip suppresses it), so it can't be hit.
MarkupHitBorder(snip, dx, dy) {
    if (!snip.HasBorder || Mod(snip.Angle, 90) != 0)
        return false
    if !MarkupPicSize(snip, &pw, &ph)
        return false
    return (dx < 0 || dy < 0 || dx >= pw || dy >= ph)
}

MarkupPicSize(snip, &w, &h) {
    w := h := 0
    rect := Buffer(16, 0)
    try {
        if !DllCall('GetWindowRect', 'Ptr', snip.GuiObj.Pic.Hwnd, 'Ptr', rect)
            return false
    } catch
        return false
    w := NumGet(rect, 8, 'Int') - NumGet(rect, 0, 'Int')
    h := NumGet(rect, 12, 'Int') - NumGet(rect, 4, 'Int')
    return (w > 0 && h > 0)
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
    MarkupState.Sels      := []
    MarkupState.BorderSel := false
    for o in snip.Markup.Objs
        MarkupState.Sels.Push(o)
    MarkupSyncPallet()
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
;  8. WM_SETCURSOR /       →  MarkupSessionOn()        "is this snip mine?"
;     WM_LBUTTONDOWN
;
; Every one is a no-op when this snip has no markup and markup mode is off, so
; the cost on an un-annotated snip is a property test.

; True when a markup session is running AND its snip is the active window.
; Used as the #HotIf context for every tool key at the bottom of this file, so
; a bare "R" can never fire anywhere else.
MarkupActive() {
    return MarkupState.Active && WinActive('ahk_id ' MarkupState.Active)
}

; True when THIS snip has an open markup session — regardless of which window is
; active, and regardless of which tool is in hand.
;
; The core asks before it treats a bare press on the frame as a resize, and
; before it shows a resize cursor there.  While annotating, the frame is the
; snip's drag-to-move handle (see MarkupHitBorder, which declines a plain press
; on it for exactly that reason) and the image is drawing canvas, so a bare
; edge-drag must keep meaning "move", with Alt+edge-drag left as the way to
; resize.  Deliberately NOT tool-sensitive: the answer would then flip every time
; the tool changed, and a resize cursor that comes and goes while the pointer sits
; still is worse than one that is consistently absent for the session.
MarkupSessionOn(hwnd) {
    return (MarkupState.Active = hwnd)
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
    m.Add('Show/Hide Tool Pallet`tF3', MarkupMenu_Handler)
    m.Add('')
    m.Add('Paste Image`tCtrl+V',       MarkupMenu_Handler)
    m.Add('Add Image From File…',      MarkupMenu_Handler)
    m.Add('')
    m.Add('Swap Line Ends`tCtrl+\',    MarkupMenu_Handler)
    m.Add('Line Styles…',              MarkupMenu_Handler)
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
        case 'Show/Hide Tool Pallet': MarkupPalletMenuItem(hwnd)
        case 'Paste Image':            MarkupPasteImage(hwnd)
        case 'Add Image From File…':   MarkupImageFromFile(hwnd)
        case 'Swap Line Ends':         MarkupSwapEnds()
        case 'Line Styles…':           MarkupStyleEditor()
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
    MarkupState.Active    := hwnd
    MarkupState.Tool      := 'select'
    MarkupState.Sel       := 0
    MarkupState.BorderSel := false
    ; Only while a session is running — see MarkupOnActivate.  Re-registering
    ; the same callback is harmless in v2; it does not stack.
    OnMessage(0x0006, MarkupOnActivate)          ; WM_ACTIVATE
    MarkupWheelHotkeys(true)
    WinActivate('ahk_id ' hwnd)
    if MarkupCfg.PalletAutoShow
        MarkupShowPallet()
    MarkupRender(guiSnips[hwnd])
    ToolTip('Markup mode — Esc to leave')
    SetTimer(() => ToolTip(), -1400)
}

; leaveTip=false when we're retargeting or the snip is going away.
MarkupEnd(leaveTip := true) {
    global guiSnips
    hwnd := MarkupState.Active
    OnMessage(0x0006, MarkupOnActivate, 0)       ; stop watching WM_ACTIVATE
    MarkupWheelHotkeys(false)                    ; and leave the mouse hook alone
    MarkupHidePallet()                          ; before Active is cleared, so
    MarkupState.Active    := 0                   ; the position is filed against
    MarkupState.Sel       := 0                   ; the right snip
    MarkupState.BorderSel := false
    MarkupState.Tool      := 'select'
    MarkupState.Borrowed  := ''                  ; no tool survives the session
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
    if (MarkupState.Sels.Length || MarkupState.BorderSel) {
        MarkupState.Sels := []
        MarkupState.BorderSel := false
        MarkupSyncPallet()
        if guiSnips.Has(hwnd)
            MarkupRender(guiSnips[hwnd])
        return true
    }
    if (MarkupState.Borrowed != '') {
        ; Esc after a double-click means "never mind the tool either", so the
        ; loan is cancelled rather than silently waiting for the next click.
        MarkupState.Borrowed := ''
        MarkupSyncPallet()
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
    if (MarkupState.Active = hwnd && (MarkupState.Sels.Length || MarkupState.BorderSel)) {
        MarkupState.Sels := []
        MarkupState.BorderSel := false
        MarkupSyncPallet()
        if guiSnips.Has(hwnd)
            MarkupRender(guiSnips[hwnd])
    }
}

; Free anything a snip's markup owns that GDI+ won't collect for us.  Only
; pasted-image objects hold a bitmap; everything else is plain numbers.
MarkupOnSnipClosed(snip, hwnd) {
    if (MarkupState.Active = hwnd) {
        OnMessage(0x0006, MarkupOnActivate, 0)   ; stop watching WM_ACTIVATE
        MarkupState.Active    := 0
        MarkupState.Sel       := 0
        MarkupState.BorderSel := false
        MarkupHidePallet()
        ; The snip this position was measured against is gone, so drop it and
        ; let the next session place the pallet against its own snip.
        MarkupState.PalX := '', MarkupState.PalY := '', MarkupState.PalOwner := 0
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
    MarkupState.Sel       := 0
    MarkupState.BorderSel := false
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

; The snip's FRAME rides along in the snapshot even though it isn't an object.
; Without it, recolouring the border and then pressing Ctrl+Z would silently
; undo whatever object edit came before instead — the most confusing possible
; answer to "undo that".  Two numbers per snapshot is a cheap price.
MarkupSnapshot(mk, snip) {
    out := []
    for o in mk.Objs
        out.Push(MarkupCloneObj(o))
    return { Objs: out, NextNum: mk.NextNum
           , BorderColor: SnipBorderColor(snip), BorderW: SnipBorderW(snip) }
}

; Restoring the frame goes through SetSnipBorder rather than a bare assignment,
; because putting a width back means resizing the window — and SetSnipBorder
; returns early when nothing actually differs, so the common undo (objects only)
; costs one comparison.
MarkupRestoreSnapshot(snip, snap) {
    mk := snip.Markup
    mk.Objs := snap.Objs, mk.NextNum := snap.NextNum
    if snap.HasProp('BorderW')
        SetSnipBorder(snip.GuiObj.Hwnd, snap.BorderColor, snap.BorderW)
}

MarkupPushUndo(snip) {
    mk := MarkupEnsure(snip)
    mk.Undo.Push(MarkupSnapshot(mk, snip))
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
    mk.Redo.Push(MarkupSnapshot(mk, snip))
    MarkupRestoreSnapshot(snip, mk.Undo.Pop())
    MarkupState.Sel := 0
    MarkupSyncPallet()
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
    mk.Undo.Push(MarkupSnapshot(mk, snip))
    MarkupRestoreSnapshot(snip, mk.Redo.Pop())
    MarkupState.Sel := 0
    MarkupSyncPallet()
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
;
; Dash / CapStart / CapEnd / HeadScale / Corner are the line-style properties.
; They are set from the TOOL's remembered defaults rather than from a global,
; which is what lets Line, Arrow and Path Arrow be one object type wearing three
; different presets — see MarkupToolStyle.

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
         , Dash:      'solid'              ; named pattern  — see MarkupStyles
         , CapStart:  'none', CapEnd: 'none'   ; named end treatments
         , HeadScale: MarkupCfg.ArrowHeadScale ; head length as a multiple of Thick
         , Corner:    0                    ; corner radius; -1 = auto for the type
         , NumDia:    MarkupCfg.NumberDia  ; number badge disc size; 0 = auto
         , ImgIdx:    0
         , Pts:       []
         , Upright:   (type = 'text' || type = 'number' || type = 'callout') }

    ; A highlighter draws its fill and nothing else, so Color and FillColor are
    ; kept equal on it: the swatches then work the same way they do on every
    ; other object instead of needing a Ctrl+click nobody would guess at.
    ; MarkupApplyStyle keeps the pair in step from then on.
    if (type = 'highlight') {
        o.Fill  := true
        o.Alpha := MarkupCfg.HighlightAlpha
        o.Color := MarkupCfg.HighlightColor     ; default is the classic yellow
        o.FillColor := MarkupCfg.HighlightColor
        o.Outline := false
    }
    ; The tool's remembered line style.  This lookup is the ONLY thing that
    ; makes Line, Arrow and Path Arrow different from one another, which is why
    ; it is a table rather than a chain of ifs bolted on here.
    st := MarkupToolStyle(type)
    o.Dash     := st.Dash
    o.CapStart := st.CapStart
    o.CapEnd   := st.CapEnd
    o.Corner   := st.Corner
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
    MarkupSyncPallet()
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
    MarkupSyncPallet()
    MarkupRender(snip)
}

; ==============================================================================
; LINE STYLE REGISTRIES  —  arrowheads, dash patterns
; ==============================================================================
;
; Four properties that used to be constants are now per-object:
;
;   Dash       a named dash pattern       'solid', 'dash', ... or a user's own
;   CapStart   end treatment at X1,Y1     'none', 'arrow', 'dot', ... or ditto
;   CapEnd     end treatment at X2,Y2
;   Corner     corner radius in master px, -1 = auto for the type
;
; A CAP IS DATA.  Each definition is a polygon (or a circle) in a normalised
; frame — tip at the origin, +X back along the shaft, units of head length — so
; the built-in triangle and something a user typed into the INI go through the
; identical draw routine.  That is the whole reason "add your own arrowhead" is
; a parser and a dialog rather than a new case in the renderer.
;
; A DASH is either one of the five GDI+ DashStyles or a float array in multiples
; of the pen width.
;
; Custom entries live in their own INI sections:
;
;   [MarkupCaps]
;   ; Name = poly|circle, fill|open|line, shrink, coords...
;   Fletch = poly, fill, 0.90, 0,0, 1,-0.60, 0.60,0, 1,0.60
;   Ring   = circle, open, 0.76, 0.38, 0.38          ; centre, radius
;
;   [MarkupDashes]
;   ; Name = on, off, on, off ...  (multiples of the stroke width)
;   Railroad = 5, 2, 1, 2
;
; fill = filled solid, open = stroked outline (closed), line = stroked polyline
; (not closed — that is what makes a chevron a chevron rather than a triangle).
;
; MarkupReloadStyles() rebuilds all of this at runtime, which is why the editor
; needs no restart.  It reads the INI SECTIONS directly rather than through
; SnipCfg(): that cache is filled once at load with no way to invalidate it, and
; it can only answer for key names known at compile time — a user-invented cap
; name is neither.

class MarkupStyles {
    static Caps      := Map()     ; id (lowercased name) → definition
    static CapOrder  := []        ; ids, in the order they appear in the lists
    static Dashes    := Map()
    static DashOrder := []
    static Ready     := false
}

MarkupIniPath() => SnipDataPath('snipSettings.ini')

; Register one cap.  Re-registering an existing id REPLACES it in place and
; keeps its position in the list, so a user entry named 'arrow' overrides the
; built-in rather than appearing twice.
MarkupDefCap(def) {
    if !def.HasProp('Pts')
        def.Pts := []
    if !def.HasProp('CX')
        def.CX := 0.36
    if !def.HasProp('R')
        def.R := 0.36
    if !def.HasProp('Builtin')
        def.Builtin := false
    def.Id := StrLower(def.Name)
    isNew := !MarkupStyles.Caps.Has(def.Id)
    MarkupStyles.Caps[def.Id] := def
    ; A leading underscore marks a SCRATCH entry — the style editor registers
    ; one to draw its live preview from half-typed numbers.  It is lookupable
    ; but never listed, so an in-progress definition can't leak into the pallet.
    if (isNew && SubStr(def.Id, 1, 1) != '_')
        MarkupStyles.CapOrder.Push(def.Id)
}

MarkupDefDash(def) {
    if !def.HasProp('Arr')
        def.Arr := []
    if !def.HasProp('Style')
        def.Style := 5
    if !def.HasProp('Builtin')
        def.Builtin := false
    def.Id := StrLower(def.Name)
    isNew := !MarkupStyles.Dashes.Has(def.Id)
    MarkupStyles.Dashes[def.Id] := def
    if (isNew && SubStr(def.Id, 1, 1) != '_')       ; scratch — see MarkupDefCap
        MarkupStyles.DashOrder.Push(def.Id)
}

MarkupLoadStyles() {
    MarkupStyles.Caps   := Map(),  MarkupStyles.Caps.CaseSense   := false
    MarkupStyles.Dashes := Map(),  MarkupStyles.Dashes.CaseSense := false
    MarkupStyles.CapOrder := [],   MarkupStyles.DashOrder := []

    ; 'none' must exist and must be first — it is the fallback for an unknown
    ; name, which is what stops a deleted custom cap from throwing on every
    ; render of an object that still refers to it.
    MarkupDefCap({Name: 'none',    Kind: 'none',   Fill: false, Close: false, Shrink: 0,    Builtin: true})
    MarkupDefCap({Name: 'arrow',   Kind: 'poly',   Fill: true,  Close: true,  Shrink: 0.85
                , Pts: [0,0, 0.913,-0.408, 0.913,0.408], Builtin: true})
    MarkupDefCap({Name: 'stealth', Kind: 'poly',   Fill: true,  Close: true,  Shrink: 0.68
                , Pts: [0,0, 1.00,-0.50, 0.62,0, 1.00,0.50], Builtin: true})
    MarkupDefCap({Name: 'hollow',  Kind: 'poly',   Fill: false, Close: true,  Shrink: 0.85
                , Pts: [0,0, 0.913,-0.408, 0.913,0.408], Builtin: true})
    MarkupDefCap({Name: 'chevron', Kind: 'poly',   Fill: false, Close: false, Shrink: 0.10
                , Pts: [0.95,-0.50, 0,0, 0.95,0.50], Builtin: true})
    MarkupDefCap({Name: 'bar',     Kind: 'poly',   Fill: false, Close: false, Shrink: 0
                , Pts: [0.05,-0.50, 0.05,0.50], Builtin: true})
    MarkupDefCap({Name: 'dot',     Kind: 'circle', Fill: true,  Close: false, Shrink: 0.36
                , CX: 0.36, R: 0.36, Builtin: true})
    MarkupDefCap({Name: 'circle',  Kind: 'circle', Fill: false, Close: false, Shrink: 0.76
                , CX: 0.38, R: 0.38, Builtin: true})
    MarkupDefCap({Name: 'square',  Kind: 'poly',   Fill: true,  Close: true,  Shrink: 0.72
                , Pts: [0,-0.36, 0,0.36, 0.72,0.36, 0.72,-0.36], Builtin: true})
    MarkupDefCap({Name: 'diamond', Kind: 'poly',   Fill: true,  Close: true,  Shrink: 1.00
                , Pts: [0,0, 0.50,-0.42, 1.00,0, 0.50,0.42], Builtin: true})

    MarkupDefDash({Name: 'solid',      Style: 0, Builtin: true})
    MarkupDefDash({Name: 'dash',       Style: 1, Builtin: true})
    MarkupDefDash({Name: 'dot',        Style: 2, Builtin: true})
    MarkupDefDash({Name: 'dashdot',    Style: 3, Builtin: true})
    MarkupDefDash({Name: 'dashdotdot', Style: 4, Builtin: true})

    MarkupLoadCustomStyles()
    MarkupStyles.Ready := true
}

; A missing section makes IniRead throw, and a malformed line is skipped by the
; parsers rather than reported — a typo in the INI must never stop ScreenSnip
; drawing, it just means that one entry doesn't appear in the list.
MarkupLoadCustomStyles() {
    path := MarkupIniPath()
    if !FileExist(path)
        return
    try {
        for line in StrSplit(IniRead(path, 'MarkupCaps'), '`n')
            MarkupParseCapLine(line)
    } catch {
        ; no [MarkupCaps] section — normal, and nothing to do
    }
    try {
        for line in StrSplit(IniRead(path, 'MarkupDashes'), '`n')
            MarkupParseDashLine(line)
    } catch {
        ; no [MarkupDashes] section
    }
}

MarkupParseCapLine(line) {
    if !(pos := InStr(line, '='))
        return false
    name := Trim(SubStr(line, 1, pos - 1))
    f    := StrSplit(Trim(SubStr(line, pos + 1)), ',', ' `t')
    if (name = '' || f.Length < 3)
        return false
    kind := StrLower(f[1])
    if (kind != 'poly' && kind != 'circle')
        return false
    word := StrLower(f[2])
    if (word != 'fill' && word != 'open' && word != 'line')
        return false
    if !IsNumber(f[3])
        return false

    def := { Name:   name
           , Kind:   kind
           , Fill:   (word = 'fill')
           , Close:  (word != 'line')
           , Shrink: Float(f[3]) }

    if (kind = 'circle') {
        if (f.Length < 5 || !IsNumber(f[4]) || !IsNumber(f[5]))
            return false
        def.CX := Float(f[4]), def.R := Float(f[5])
        if (def.R <= 0)
            return false
    } else {
        pts := [], i := 4
        while (i <= f.Length) {
            if !IsNumber(f[i])
                return false
            pts.Push(Float(f[i])), i++
        }
        ; Needs at least two points, and pairs of them.
        if (pts.Length < 4 || Mod(pts.Length, 2))
            return false
        def.Pts := pts
    }
    MarkupDefCap(def)
    return true
}

MarkupParseDashLine(line) {
    if !(pos := InStr(line, '='))
        return false
    name := Trim(SubStr(line, 1, pos - 1))
    if (name = '')
        return false
    arr := []
    for v in StrSplit(Trim(SubStr(line, pos + 1)), ',', ' `t') {
        if (v = '')
            continue
        if !IsNumber(v)
            return false
        n := Float(v)
        if (n <= 0)                    ; GDI+ rejects a zero-length dash entry
            return false
        arr.Push(n)
    }
    ; A pattern is on/off pairs, so anything shorter than two numbers is not one.
    if (arr.Length < 2)
        return false
    MarkupDefDash({ Name: name, Style: 5, Arr: arr })
    return true
}

; Lookups.  Both accept the OLD numeric form (Dash 0..4, Cap 0/1) as well as a
; name, because objects created before the registry existed are still sitting in
; undo snapshots, and an unknown name resolves to none / solid rather than
; throwing — a cap the user deleted must not take the render down with it.
MarkupCap(id) {
    if !MarkupStyles.Ready
        MarkupLoadStyles()
    if (id is Number)
        id := id ? 'arrow' : 'none'
    id := StrLower(String(id))
    return MarkupStyles.Caps.Has(id) ? MarkupStyles.Caps[id] : MarkupStyles.Caps['none']
}

MarkupDash(id) {
    if !MarkupStyles.Ready
        MarkupLoadStyles()
    if (id is Number) {
        static legacy := ['solid', 'dash', 'dot', 'dashdot', 'dashdotdot']
        id := legacy[Min(Max(Integer(id) + 1, 1), 5)]
    }
    id := StrLower(String(id))
    return MarkupStyles.Dashes.Has(id) ? MarkupStyles.Dashes[id] : MarkupStyles.Dashes['solid']
}

; Serialise back to the INI's one-line grammar.  The editor writes through this,
; so what it saves is exactly what MarkupParseCapLine can read back.
MarkupCapToIni(def) {
    word := def.Fill ? 'fill' : (def.Close ? 'open' : 'line')
    out  := def.Kind ', ' word ', ' MarkupNumText(def.Shrink)
    if (def.Kind = 'circle')
        return out ', ' MarkupNumText(def.CX) ', ' MarkupNumText(def.R)
    for v in def.Pts
        out .= ', ' MarkupNumText(v)
    return out
}

MarkupDashToIni(def) {
    out := ''
    for v in def.Arr
        out .= (out = '' ? '' : ', ') MarkupNumText(v)
    return out
}

; 3.0 → "3", 3.5 → "3.5".  Used everywhere a number has to survive a round trip
; through a control or an INI without growing a trailing ".000000".
MarkupNumText(v) {
    if !IsNumber(v)
        return String(v)
    v := v + 0.0
    return (v = Round(v)) ? String(Integer(v)) : Format('{:g}', v)
}

; ── Per-tool defaults ────────────────────────────────────────────────────────
;
; The tool list is a list of PRESETS.  Line, Arrow and Path Arrow build the same
; kind of object; what differs is the style they seed it with.  Keeping that in
; a table rather than in MarkupNewObj means picking Line, choosing a chevron end
; and going back to Arrow doesn't silently redefine what Arrow draws.

MarkupToolStyle(tool) {
    if !MarkupState.ToolStyle.Count
        MarkupInitToolStyles()
    if !MarkupState.ToolStyle.Has(tool)
        MarkupState.ToolStyle[tool] := { Dash: 'solid', CapStart: 'none'
                                       , CapEnd: 'none', Corner: 0 }
    return MarkupState.ToolStyle[tool]
}

MarkupInitToolStyles() {
    ts := MarkupState.ToolStyle := Map()
    ts['line']      := { Dash: MarkupCfg.LineDash,  CapStart: MarkupCfg.LineCapStart
                       , CapEnd: MarkupCfg.LineCapEnd,  Corner: 0 }
    ts['arrow']     := { Dash: MarkupCfg.ArrowDash, CapStart: MarkupCfg.ArrowCapStart
                       , CapEnd: MarkupCfg.ArrowCapEnd, Corner: 0 }
    ts['path']      := { Dash: MarkupCfg.PathDash,  CapStart: MarkupCfg.PathCapStart
                       , CapEnd: MarkupCfg.PathCapEnd,  Corner: MarkupCfg.PathCornerRadius }
    ts['pen']       := { Dash: MarkupCfg.PenDash,   CapStart: MarkupCfg.PenCapStart
                       , CapEnd: MarkupCfg.PenCapEnd,   Corner: 0 }
    ts['rect']      := { Dash: 'solid', CapStart: 'none', CapEnd: 'none'
                       , Corner: MarkupCfg.RectCorner }
    ts['highlight'] := { Dash: 'solid', CapStart: 'none', CapEnd: 'none'
                       , Corner: MarkupCfg.RectCorner }
    ts['callout']   := { Dash: 'solid', CapStart: 'none', CapEnd: 'none'
                       , Corner: MarkupCfg.CalloutCorner }
    ts['ellipse']   := { Dash: 'solid', CapStart: 'none', CapEnd: 'none', Corner: 0 }
}

; Rebuild the registries from the INI and push the result at everything that is
; showing it.  This is what "no restart" means in practice.
MarkupReloadStyles() {
    global guiSnips
    MarkupLoadStyles()
    MarkupFillStyleLists()
    MarkupSyncPallet()
    if (MarkupState.Active && guiSnips.Has(MarkupState.Active))
        MarkupRender(guiSnips[MarkupState.Active])
}

; ==============================================================================
; GDI+ DRAWING HELPERS
; ==============================================================================

MarkupARGB(rgb, alpha := 255) => ((alpha & 0xFF) << 24) | (rgb & 0xFFFFFF)

; Every stroke in the module goes through here, which is what lets a dash
; pattern be a property rather than a special case: dash is a NAME looked up in
; the registry, so a user-defined pattern draws through exactly the same code
; path as a built-in one.
MarkupPen(rgb, alpha, width, dash := 'solid') {
    DllCall('gdiplus\GdipCreatePen1', 'UInt', MarkupARGB(rgb, alpha)
          , 'Float', Max(0.5, width + 0.0), 'Int', 2, 'UPtr*', &p := 0)   ; 2 = UnitPixel
    if p {
        DllCall('gdiplus\GdipSetPenStartCap', 'UPtr', p, 'Int', 2)        ; 2 = LineCapRound
        DllCall('gdiplus\GdipSetPenEndCap',   'UPtr', p, 'Int', 2)
        DllCall('gdiplus\GdipSetPenLineJoin', 'UPtr', p, 'Int', 2)        ; 2 = LineJoinRound
        MarkupApplyDash(p, dash)
    }
    return p
}

; The five built-in patterns are GDI+ DashStyles; everything else is a float
; array.  GDI+ measures a dash array in multiples of the PEN WIDTH, not in
; pixels, so a custom pattern keeps its proportions when the stroke weight
; changes — which is why the style editor asks for "6, 3" rather than pixels.
MarkupApplyDash(pen, dashId) {
    d := MarkupDash(dashId)
    if !d
        return
    if d.Arr.Length {
        buf := Buffer(d.Arr.Length * 4, 0)
        for i, v in d.Arr
            NumPut('Float', v + 0.0, buf, (i - 1) * 4)
        DllCall('gdiplus\GdipSetPenDashArray', 'UPtr', pen
              , 'Ptr', buf, 'Int', d.Arr.Length)
        return
    }
    if d.Style
        DllCall('gdiplus\GdipSetPenDashStyle', 'UPtr', pen, 'Int', d.Style)
}

; One point of a cap definition, mapped into the drawing.  A cap is defined in a
; normalised frame: the tip is the origin, +X runs BACK along the shaft, +Y runs
; across it, and both are measured in head-lengths.  One definition therefore
; serves every angle, every stroke weight and every head size — which is what
; makes a user-supplied row of numbers a first-class arrowhead.
;
; (The old hard-coded triangle used a half-spread of 0.42 radians; that is
; exactly [0,0, 0.913,-0.408, 0.913,0.408] in this frame, which is how the
; built-in 'arrow' still draws pixel-for-pixel what it always did.)
MarkupCapPoint(tipX, tipY, ang, head, x, y, &wx, &wy) {
    c := Cos(ang), s := Sin(ang)
    wx := tipX - head * (x * c + y * s)
    wy := tipY - head * (x * s - y * c)
}

; One end treatment, pointing along ang.  Built-in or read out of the INI, every
; shape comes through here, so adding an arrowhead is data and never code.
MarkupDrawCap(pGfx, capId, tipX, tipY, ang, head, col, alpha, strokeW := 2) {
    cap := MarkupCap(capId)
    if (cap.Kind = 'none')
        return

    if (cap.Kind = 'circle') {
        MarkupCapPoint(tipX, tipY, ang, head, cap.CX, 0, &cx, &cy)
        r := Max(0.5, head * cap.R)
        if cap.Fill {
            br := MarkupBrush(col, alpha)
            DllCall('gdiplus\GdipFillEllipse', 'UPtr', pGfx, 'UPtr', br
                  , 'Float', cx - r, 'Float', cy - r, 'Float', r * 2, 'Float', r * 2)
            MarkupDelBrush(br)
        } else {
            pn := MarkupPen(col, alpha, strokeW)
            DllCall('gdiplus\GdipDrawEllipse', 'UPtr', pGfx, 'UPtr', pn
                  , 'Float', cx - r, 'Float', cy - r, 'Float', r * 2, 'Float', r * 2)
            MarkupDelPen(pn)
        }
        return
    }

    if (cap.Pts.Length < 4)
        return
    pts := [], i := 1
    while (i <= cap.Pts.Length) {
        MarkupCapPoint(tipX, tipY, ang, head, cap.Pts[i], cap.Pts[i + 1], &wx, &wy)
        pts.Push(wx, wy), i += 2
    }
    pb := MarkupPointBuf(pts)

    if cap.Fill {
        br := MarkupBrush(col, alpha)
        DllCall('gdiplus\GdipFillPolygon', 'UPtr', pGfx, 'UPtr', br
              , 'Ptr', pb.Buf, 'Int', pb.N, 'Int', 0)
        MarkupDelBrush(br)
        return
    }
    ; Stroked caps use the object's own line weight, so a chevron head matches
    ; the shaft it sits on instead of being a hairline stuck to a fat line.
    pn := MarkupPen(col, alpha, strokeW)
    if cap.Close
        DllCall('gdiplus\GdipDrawPolygon', 'UPtr', pGfx, 'UPtr', pn
              , 'Ptr', pb.Buf, 'Int', pb.N)
    else
        DllCall('gdiplus\GdipDrawLines', 'UPtr', pGfx, 'UPtr', pn
              , 'Ptr', pb.Buf, 'Int', pb.N)
    MarkupDelPen(pn)
}

; Head length in master pixels.  The halo pass inflates it so the contrasting
; outline shows around the head as well as along the shaft.
MarkupHeadSize(o, isHalo := false) {
    sc := o.HasProp('HeadScale') ? o.HeadScale : MarkupCfg.ArrowHeadScale
    return Max(8, o.Thick * sc) + (isHalo ? MarkupCfg.OutlineWidth : 0)
}

; How far back along the shaft the stroke must stop so the cap's back edge has
; no nub of line poking through it, in master pixels.
MarkupCapShrink(capId, head) => MarkupCap(capId).Shrink * head

; Diameter of a number badge's disc, in master pixels.  The ONE place it is
; worked out — the draw pass and the bounds both call it, so a badge can never
; be drawn at a size the selection ring disagrees with.
;
; NumDia = 0 is auto: the historical formula, disc sized from the digits, so an
; untouched badge and every badge drawn before this property existed look
; exactly as they always did.  A non-zero NumDia is an ABSOLUTE size, which is
; what decouples the disc from the font — set 48 and the disc stays 48 whether
; the numeral is 14pt or 24pt.
;
; The fit floor is not negotiable in either mode: a disc that doesn't contain
; its own digit is a bug, not a style, so cranking the font past a small fixed
; disc grows the disc rather than letting the numeral hang out of it.
MarkupNumDia(o) {
    MarkupTextSize(o, &tw, &th)
    fit  := Max(tw, th) + o.FontSize * 0.15
    dia  := (o.HasProp('NumDia') && o.NumDia > 0) ? o.NumDia
                                                 : Max(tw, th) + o.FontSize * 0.7
    return Max(dia, fit)
}

; The steps the Head box offers when it is standing in for the disc size.
; Absolute pixels, not multiples: the point of the control is that the badge
; keeps the size you gave it no matter what the font does.
MarkupNumDiaSteps() {
    static t := [20, 24, 28, 32, 40, 48, 56, 64, 80, 96]
    return t
}

; Corner radius for a rectangle-ish object, clamped so shrinking the shape
; degrades to a stadium instead of overshooting into itself.
MarkupCornerRadius(o, w, h) {
    r := o.HasProp('Corner') ? o.Corner : 0
    if (r < 0)                             ; auto — a plain rectangle was sharp
        r := 0
    return Max(0, Min(r, Min(w, h) / 2))
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

; ── Path Arrow geometry ──────────────────────────────────────────────────────
;
; A Path Arrow ("dogleg", or an elbow connector in diagramming tools) is a
; multi-segment arrow that turns at right angles, for pointing at something from
; across the image without the shaft crossing whatever is in between.
;
; It stores its geometry in Pts — the same flat [x1,y1,x2,y2,...] array the pen
; tool uses, in master-local coordinates.  That is the whole reason this type
; was cheap to add: bounds, hit-testing, move and group-resize already handle
; Pts generically, so none of them needed a line changing.  Group resize even
; preserves the right angles for free, since scaling each axis independently
; keeps axis-aligned segments axis-aligned.
;
; The corners are stored SHARP.  Rounding is applied at draw time only, so the
; radius stays a display choice rather than something baked into the geometry
; that editing would then have to preserve.

MarkupPathLen(ax, ay, bx, by) => Sqrt((bx - ax) ** 2 + (by - ay) ** 2)

; Unit direction from A to B, or 0,0 for a degenerate segment.
MarkupPathDir(ax, ay, bx, by, &ux, &uy) {
    L := MarkupPathLen(ax, ay, bx, by)
    if (L < 0.0001) {
        ux := 0, uy := 0
        return false
    }
    ux := (bx - ax) / L, uy := (by - ay) / L
    return true
}

; Drop duplicate points and merge runs that carry on in the same direction.
; Both are safe on an orthogonal path: neither changes any remaining segment's
; direction, so the right angles survive.  Removing a SHORT segment would not be
; safe — that takes out two corners at once and skews its neighbours — so short
; jogs are deliberately left alone.
MarkupPathSimplify(pts) {
    out := []
    i := 1
    while (i + 1 <= pts.Length) {
        x := pts[i], y := pts[i + 1]
        n := out.Length
        if (n >= 2 && MarkupPathLen(out[n - 1], out[n], x, y) < 0.5) {
            i += 2
            continue                      ; duplicate of the previous point
        }
        out.Push(x, y)
        n := out.Length
        if (n >= 6) {                     ; collinear middle point? drop it
            MarkupPathDir(out[n - 5], out[n - 4], out[n - 3], out[n - 2], &u1x, &u1y)
            MarkupPathDir(out[n - 3], out[n - 2], out[n - 1], out[n],     &u2x, &u2y)
            if (Abs(u1x - u2x) < 0.01 && Abs(u1y - u2y) < 0.01) {
                out[n - 3] := out[n - 1], out[n - 2] := out[n]
                out.Pop(), out.Pop()
            }
        }
        i += 2
    }
    return out
}

; Build the stroked path: straight runs joined by rounded corners, with the ends
; pulled back by shrinkStart / shrinkEnd so an arrow head doesn't show a nub of
; shaft poking through it.
;
; Corners are cubic Beziers with both control points sitting on the sharp vertex.
; For a right angle that is visually indistinguishable from a true arc, and it
; needs no arc rectangle or sweep angle — which matters because the segments are
; only axis-aligned in DISPLAY space; on a rotated snip their master-space
; directions are arbitrary, and an arc-based corner would have to special-case
; that.  A Bezier does not care.
MarkupPathBuild(pts, radius, shrinkStart, shrinkEnd) {
    n := pts.Length // 2
    if (n < 2)
        return 0
    ; Working copy with the two ends pulled in.
    p := pts.Clone()
    if (shrinkStart > 0 && MarkupPathDir(p[1], p[2], p[3], p[4], &sx, &sy)) {
        segL := MarkupPathLen(p[1], p[2], p[3], p[4])
        d    := Min(shrinkStart, segL * 0.9)
        p[1] += sx * d, p[2] += sy * d
    }
    if (shrinkEnd > 0 && MarkupPathDir(p[2*n - 3], p[2*n - 2], p[2*n - 1], p[2*n], &ex, &ey)) {
        segL := MarkupPathLen(p[2*n - 3], p[2*n - 2], p[2*n - 1], p[2*n])
        d    := Min(shrinkEnd, segL * 0.9)
        p[2*n - 1] -= ex * d, p[2*n] -= ey * d
    }

    DllCall('gdiplus\GdipCreatePath', 'Int', 0, 'UPtr*', &gp := 0)
    if !gp
        return 0
    curX := p[1], curY := p[2]
    Loop n - 2 {                          ; every interior vertex
        i  := A_Index + 1
        vx := p[2*i - 1], vy := p[2*i]
        if (!MarkupPathDir(p[2*i - 3], p[2*i - 2], vx, vy, &inX, &inY)
         || !MarkupPathDir(vx, vy, p[2*i + 1], p[2*i + 2], &outX, &outY))
            continue
        ; Never eat more than half of either adjacent segment, so a tight jog
        ; degrades to a sharp corner instead of overshooting into its neighbour.
        rr := Min(radius
                , MarkupPathLen(p[2*i - 3], p[2*i - 2], vx, vy) / 2
                , MarkupPathLen(vx, vy, p[2*i + 1], p[2*i + 2]) / 2)
        ax := vx - inX * rr,  ay := vy - inY * rr
        bx := vx + outX * rr, by := vy + outY * rr
        DllCall('gdiplus\GdipAddPathLine', 'UPtr', gp
              , 'Float', curX, 'Float', curY, 'Float', ax, 'Float', ay)
        if (rr >= 0.5)
            DllCall('gdiplus\GdipAddPathBezier', 'UPtr', gp
                  , 'Float', ax, 'Float', ay, 'Float', vx, 'Float', vy
                  , 'Float', vx, 'Float', vy, 'Float', bx, 'Float', by)
        curX := bx, curY := by
    }
    DllCall('gdiplus\GdipAddPathLine', 'UPtr', gp
          , 'Float', curX, 'Float', curY, 'Float', p[2*n - 1], 'Float', p[2*n])
    return gp
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

; Corner < 0 (or absent) is AUTO, which keeps the original font-derived radius
; so callouts drawn before this setting existed look exactly as they did.  Any
; other value is an explicit radius.  The Min(w,h)/2 clamp applies either way,
; so dragging a bubble small turns it into a stadium rather than tying knots.
MarkupCalloutRadius(o, w, h) {
    r := (o.HasProp('Corner') && o.Corner >= 0) ? o.Corner : o.FontSize * 0.45
    return Max(1, Min(r, Min(w, h) / 2))
}

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
        ; Corner > 0 routes through the rounded path; 0 keeps the original
        ; single-call rectangle, which is both faster and pixel-identical to
        ; what every existing snip was drawn with.
        rad := MarkupCornerRadius(o, w, h)
        if (rad > 0) {
            gp := MarkupRoundRectPath(x1, y1, w, h, rad)
            if gp {
                if doFill {
                    br := MarkupBrush(fillCol, fillAlpha)
                    DllCall('gdiplus\GdipFillPath', 'UPtr', pGfx, 'UPtr', br, 'UPtr', gp)
                    MarkupDelBrush(br)
                }
                if (o.Type = 'rect') {
                    pn := MarkupPen(col, alpha, width, o.Dash)
                    DllCall('gdiplus\GdipDrawPath', 'UPtr', pGfx, 'UPtr', pn, 'UPtr', gp)
                    MarkupDelPen(pn)
                }
                DllCall('gdiplus\GdipDeletePath', 'UPtr', gp)
            }
            return
        }
        if doFill {
            br := MarkupBrush(fillCol, fillAlpha)
            DllCall('gdiplus\GdipFillRectangle', 'UPtr', pGfx, 'UPtr', br
                  , 'Float', x1, 'Float', y1, 'Float', w, 'Float', h)
            MarkupDelBrush(br)
        }
        if (o.Type = 'rect') {
            pn := MarkupPen(col, alpha, width, o.Dash)
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
        pn := MarkupPen(col, alpha, width, o.Dash)
        DllCall('gdiplus\GdipDrawEllipse', 'UPtr', pGfx, 'UPtr', pn
              , 'Float', x1, 'Float', y1, 'Float', w, 'Float', h)
        MarkupDelPen(pn)

    case 'line', 'arrow':
        ; ONE case for both.  A Line and an Arrow differ only in which end
        ; treatments their tool seeded, so there is nothing left to branch on —
        ; the Arrow tool is the Line tool with CapEnd preset to 'arrow'.
        ;
        ; The shaft stops short of each end by that cap's own shrink distance,
        ; so a thick line doesn't show a nub poking out through the back of its
        ; head, and a cap that needs no clearance (a bar, a chevron) gets none.
        ax := o.X1 + ox, ay := o.Y1 + oy
        bx := o.X2 + ox, by := o.Y2 + oy
        ang  := MarkupAtan2(by - ay, bx - ax)
        head := MarkupHeadSize(o, isHalo)
        len  := MarkupPathLen(ax, ay, bx, by)
        shrS := MarkupCapShrink(o.CapStart, head)
        shrE := MarkupCapShrink(o.CapEnd,   head)
        if (len > 0.5) {
            ; Never eat more than 90% of the shaft: a short line with two big
            ; heads would otherwise draw its stroke backwards.
            if (shrS + shrE > len * 0.9) {
                k := len * 0.9 / (shrS + shrE)
                shrS *= k, shrE *= k
            }
            ux := (bx - ax) / len, uy := (by - ay) / len
            pn := MarkupPen(col, alpha, width, o.Dash)
            DllCall('gdiplus\GdipDrawLine', 'UPtr', pGfx, 'UPtr', pn
                  , 'Float', ax + ux * shrS, 'Float', ay + uy * shrS
                  , 'Float', bx - ux * shrE, 'Float', by - uy * shrE)
            MarkupDelPen(pn)
        }
        MarkupDrawCap(pGfx, o.CapEnd,   bx, by, ang,          head, col, alpha, width)
        MarkupDrawCap(pGfx, o.CapStart, ax, ay, ang + 3.14159265358979
                    , head, col, alpha, width)

    case 'path':
        if (o.Pts.Length < 4)
            return
        pp := []
        i := 1
        while (i <= o.Pts.Length)
            pp.Push(o.Pts[i] + ox, o.Pts[i + 1] + oy), i += 2
        np   := pp.Length // 2
        head := MarkupHeadSize(o, isHalo)
        ; The shaft is pulled back only as far as the cap on that end needs.
        shrS := MarkupCapShrink(o.CapStart, head)
        shrE := MarkupCapShrink(o.CapEnd,   head)
        ; Elbow radius is per-object now, but still floored at the stroke width:
        ; a thick path with tight corners looks pinched next to its own weight.
        ; Corner < 0 means auto, i.e. whatever PathCornerRadius says.
        rad  := Max((o.HasProp('Corner') && o.Corner >= 0) ? o.Corner
                                                           : MarkupCfg.PathCornerRadius
                  , o.Thick)
        gp   := MarkupPathBuild(pp, rad, shrS, shrE)
        if gp {
            pn := MarkupPen(col, alpha, width, o.Dash)
            DllCall('gdiplus\GdipDrawPath', 'UPtr', pGfx, 'UPtr', pn, 'UPtr', gp)
            MarkupDelPen(pn)
            DllCall('gdiplus\GdipDeletePath', 'UPtr', gp)
        }
        ; Each end's angle comes from its own last segment, so a cap turns with
        ; the elbow it sits on rather than pointing along the overall run.
        ang := MarkupAtan2(pp[2*np] - pp[2*np - 2], pp[2*np - 1] - pp[2*np - 3])
        MarkupDrawCap(pGfx, o.CapEnd, pp[2*np - 1], pp[2*np], ang, head, col, alpha, width)
        ang := MarkupAtan2(pp[2] - pp[4], pp[1] - pp[3])
        MarkupDrawCap(pGfx, o.CapStart, pp[1], pp[2], ang, head, col, alpha, width)

    case 'pen':
        if (o.Pts.Length < 4)
            return
        shifted := []
        i := 1
        while (i <= o.Pts.Length)
            shifted.Push(o.Pts[i] + ox, o.Pts[i + 1] + oy), i += 2
        pb := MarkupPointBuf(shifted)
        pn := MarkupPen(col, alpha, width, o.Dash)
        DllCall('gdiplus\GdipDrawLines', 'UPtr', pGfx, 'UPtr', pn
              , 'Ptr', pb.Buf, 'Int', pb.N)
        MarkupDelPen(pn)
        ; A freehand stroke gets end treatments too, but its shaft is NOT pulled
        ; back: trimming a hand-drawn polyline part-way along a segment reads as
        ; a glitch, so the cap is simply drawn over the final point.
        np   := pb.N
        head := MarkupHeadSize(o, isHalo)
        if (np >= 2) {
            ang := MarkupAtan2(shifted[2*np] - shifted[2*np - 2]
                             , shifted[2*np - 1] - shifted[2*np - 3])
            MarkupDrawCap(pGfx, o.CapEnd, shifted[2*np - 1], shifted[2*np]
                        , ang, head, col, alpha, width)
            ang := MarkupAtan2(shifted[2] - shifted[4], shifted[1] - shifted[3])
            MarkupDrawCap(pGfx, o.CapStart, shifted[1], shifted[2]
                        , ang, head, col, alpha, width)
        }

    case 'text':
        MarkupDrawString(pGfx, o.Text, o.X1 + ox, o.Y1 + oy, o, col, alpha
                       , o.Outline && !isShadow)

    case 'number':
        MarkupTextSize(o, &tw, &th)          ; still needed to CENTRE the digits
        dia := MarkupNumDia(o)
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
            pn := MarkupPen(col, alpha, width, o.Dash)
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
    ; The frame ring is drawn on the outermost pixels of THIS bitmap, so the
    ; chrome pass needs its size.  Read once here rather than per-call.
    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', pBmp, 'UInt*', &bmpW := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', pBmp, 'UInt*', &bmpH := 0)

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
        MarkupDrawChrome(pGfx, snip, m, bmpW, bmpH)

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
    case 'pen', 'path':
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
        dia := MarkupNumDia(o)
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
    ; Path Arrow handles.  Deliberately NOT one per corner: dragging a corner on
    ; a right-angled path has to push both its neighbours to keep the angles, and
    ; when a neighbour is an endpoint that drags the arrow head off the thing it
    ; was pointing at.  Infuriating, and the reason most diagram tools don't do
    ; it either.
    ;
    ; Instead, each INTERIOR segment gets one handle at its midpoint, dragged
    ; sideways.  A segment has exactly one free axis, so sliding it moves both
    ; its corners together and simply lengthens the two neighbours — the right
    ; angles are preserved by construction and both endpoints stay nailed down.
    ; The first and last segments get none, since each is pinned by an endpoint.
    if (o.Type = 'path') {
        np := o.Pts.Length // 2
        if (np < 2)
            return hs
        MarkupXform(m, o.Pts[1], o.Pts[2], &sx, &sy)
        MarkupXform(m, o.Pts[2*np - 1], o.Pts[2*np], &ex, &ey)
        hs.Push({ Id: 'pStart', X: sx, Y: sy }, { Id: 'pEnd', X: ex, Y: ey })
        if (np = 3) {
            ; A single elbow has no interior segment to slide, and its corner is
            ; fully determined by the two ends plus a choice of which way round
            ; the L goes. So give it a handle that picks between those two.
            MarkupXform(m, o.Pts[3], o.Pts[4], &cx2, &cy2)
            hs.Push({ Id: 'corner', X: cx2, Y: cy2 })
        }
        Loop Max(0, np - 3) {
            i := A_Index + 1                      ; segments 2 .. np-2
            MarkupXform(m, o.Pts[2*i - 1], o.Pts[2*i],     &ax, &ay)
            MarkupXform(m, o.Pts[2*i + 1], o.Pts[2*i + 2], &bx, &by)
            hs.Push({ Id: 'seg' i, X: (ax + bx) / 2, Y: (ay + by) / 2 })
        }
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
; bmpW/bmpH are the display bitmap's own dimensions, needed only by the frame
; ring below — everything else works in coordinates the matrix supplies.
MarkupDrawChrome(pGfx, snip, m, bmpW := 0, bmpH := 0) {
    ; The FRAME, when it is what's selected.  It sits outside this bitmap
    ; entirely, so it cannot be outlined where it actually is; instead a dashed
    ; ring runs along the image's outermost pixels, immediately inside the
    ; frame, which reads as "the thing just beyond this edge is selected".
    ;
    ; No handles, deliberately.  A frame has no geometry to drag — its only two
    ; properties are the swatches and the Width box on the pallet — and drawing
    ; grab squares for something that cannot be grabbed would be a lie.
    if (MarkupBorderSelected() && bmpW > 1 && bmpH > 1) {
        ; Two passes: a solid dark under-stroke so the ring stays visible on a
        ; light image, then the dashed HandleColor over it.  Inset by half a
        ; pen width so neither stroke is clipped by the bitmap edge.
        us := MarkupPen(0x000000, 90, 3)
        DllCall('gdiplus\GdipDrawRectangle', 'UPtr', pGfx, 'UPtr', us
              , 'Float', 1.5, 'Float', 1.5, 'Float', bmpW - 3.0, 'Float', bmpH - 3.0)
        MarkupDelPen(us)
        rp := MarkupPen(MarkupCfg.HandleColor, 255, 3)
        DllCall('gdiplus\GdipSetPenDashStyle', 'UPtr', rp, 'Int', 1)   ; 1 = Dash
        DllCall('gdiplus\GdipDrawRectangle', 'UPtr', pGfx, 'UPtr', rp
              , 'Float', 1.5, 'Float', 1.5, 'Float', bmpW - 3.0, 'Float', bmpH - 3.0)
        MarkupDelPen(rp)
        return                       ; frame and objects are mutually exclusive
    }

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
    if (o.Type = 'pen' || o.Type = 'path') {
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
    if !guiSnips.Has(hwnd)
        return false
    snip := guiSnips[hwnd]

    ; Tested BEFORE the markup-mode guard, because this gesture can be the way
    ; IN to markup on a snip that isn't in a session.
    ;
    ; Shift already means extend-selection and marquee, so it wins outright
    ; rather than combining into a third meaning nobody would guess.
    if (MarkupCfg.CtrlClickSelect && GetKeyState('Ctrl', 'P')
     && !GetKeyState('Shift', 'P') && MarkupBorrowSelect(snip, hwnd))
        return true

    if (MarkupState.Active != hwnd)
        return false
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
            ; A plain press on the FRAME is the window move, same as ever — but
            ; it is not "empty canvas", so it must not sweep a marquee, must not
            ; hand a borrowed tool a click at negative coordinates, and must not
            ; deselect a frame the user just selected in order to drag it.
            if MarkupHitBorder(snip, dx, dy)
                return false
            ; Shift+drag on empty canvas sweeps a rubber band.  A PLAIN drag on
            ; empty canvas is still the window move it always was — that is the
            ; behaviour worth protecting, so the marquee took the modifier.
            if extend {
                MarkupMarquee(snip, dx, dy)
                return true
            }
            ; Bare image, and a tool is on loan — take it back and let it have
            ; this click.  Clicking away from your objects is what "I'm done
            ; editing" looks like, so it is the natural moment.
            ;
            ; Note what this does NOT cost: a click with no drag still deselects
            ; and leaves nothing behind, because MarkupStartDraw discards a
            ; zero-drag object.  So the click-empty-space-to-deselect habit
            ; survives intact, and only a DRAG actually draws.
            if MarkupReturnTool() {
                MarkupStartDraw(snip, dx, dy)
                return true
            }
            if (MarkupState.Sels.Length || MarkupState.BorderSel) {
                MarkupState.Sels := []
                MarkupState.BorderSel := false
                MarkupSyncPallet()
                MarkupRender(snip)
            }
            return false                     ; empty canvas → core moves the window
        }
        if extend {                          ; Shift+click toggles one object
            MarkupToggleSel(obj)
            MarkupSyncPallet()
            MarkupRender(snip)
            return true
        }
        ; Clicking something already in the group keeps the group, so you can
        ; grab any member and drag all of them.  Clicking outside it selects
        ; just that object.
        if !MarkupIsSelected(obj)
            MarkupState.Sel := obj
        MarkupSyncPallet()
        MarkupRender(snip)
        MarkupDragMove(snip)
        return true
    }

    MarkupStartDraw(snip, dx, dy)
    return true
}

; Ctrl+click ON AN OBJECT selects it.  Returns false when the click missed every
; object, so a Ctrl+click on bare image falls straight through to the core's
; drag-to-move exactly as it always did.
;
; Two things make this worth having.  With a drawing tool active it is the
; escape hatch: you can grab the thing you just drew without going back to the
; pallet or remembering V.  With markup mode off it is the way back in —
; annotations stay on the snip after Esc, so clicking one reopens the session
; with that object already selected.
MarkupBorrowSelect(snip, hwnd) {
    MarkupCursorPos(snip, &dx, &dy)

    ; The frame is reachable even on a snip with no annotations, so the
    ; no-objects bail has to let a border hit through.  Ctrl is required for
    ; exactly the reason it is required for objects: a PLAIN drag on the frame
    ; is still the window move, and with a fat border that is the best drag
    ; handle the snip has.
    onBorder := MarkupHitBorder(snip, dx, dy)
    if (!onBorder && (!snip.HasProp('Markup') || !snip.Markup.Objs.Length))
        return false
    wasActive := (MarkupState.Active = hwnd)

    obj := onBorder ? 0 : MarkupHitTest(snip, dx, dy)
    if (!onBorder && !obj)
        return false

    ; Order matters: MarkupBegin resets both the tool and the selection, so the
    ; object has to be selected after it, not before.
    prev := wasActive ? MarkupState.Tool : ''
    if !wasActive
        MarkupBegin(hwnd)
    MarkupSetTool('select')
    ; Borrowing, not switching: reaching into an object while a drawing tool was
    ; in hand lends you Select for as long as you are working on existing
    ; objects, and gives the tool back at the first click on bare image.
    ; Nothing is borrowed when Select was already active — there would be
    ; nothing to return.
    if (MarkupCfg.StickyTool && prev != '' && prev != 'select')
        MarkupState.Borrowed := prev

    if onBorder {
        MarkupState.Sels      := []
        MarkupState.BorderSel := true
        MarkupSyncPallet()
        MarkupRender(snip)
        MarkupToast('Frame selected — swatches and Width now edit the border')
        return true
    }

    MarkupState.Sel := obj
    MarkupSyncPallet()
    MarkupRender(snip)

    ; Text-bearing objects get the editor too, which is what a double-click
    ; means in every other application.  KeyWait first, or the dialog opens with
    ; the button still down and swallows the release.
    if (obj.Type = 'text' || obj.Type = 'callout') {
        KeyWait('LButton')
        MarkupEditSelText(hwnd)
    }
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
        MarkupSyncPallet()
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
    if (o.Type = 'path') {
        ; X1..Y2 on a path are the two ENDPOINTS, not a bounding box — normalising
        ; them would be meaningless. Just re-derive them from the edited points.
        n := o.Pts.Length
        if (n >= 4)
            o.X1 := o.Pts[1], o.Y1 := o.Pts[2], o.X2 := o.Pts[n - 1], o.Y2 := o.Pts[n]
    } else if (o.Type != 'line' && o.Type != 'arrow') {
        ; A resize can leave X1 > X2; normalise so later maths doesn't have to care.
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

; All path edits work from ORIG (the geometry at the start of the drag) so that
; nothing compounds across mouse-moves, and all of them are expressed in terms of
; each segment's OWN direction rather than in x and y.  That is what makes them
; correct on a rotated snip, where the segments are only square on screen and
; their master-space directions are arbitrary.
MarkupApplyPathHandle(snip, o, orig, id, mx, my) {
    np := orig.Pts.Length // 2
    if (np < 2)
        return
    pts := orig.Pts.Clone()

    if (id = 'pStart' || id = 'pEnd') {
        ; Move the endpoint to the cursor, then slide its NEIGHBOUR along the
        ; terminal segment's original direction so that segment keeps its angle.
        ; The neighbour only moves perpendicular to that direction — which is
        ; along the next segment — so the next segment just gets longer or
        ; shorter and nothing else in the path is disturbed.
        if (id = 'pStart')
            ei := 1, ni := 2
        else
            ei := np, ni := np - 1
        if (np >= 3 && MarkupPathDir(pts[2*ei - 1], pts[2*ei], pts[2*ni - 1], pts[2*ni], &ux, &uy)) {
            t := (pts[2*ni - 1] - mx) * ux + (pts[2*ni] - my) * uy
            pts[2*ni - 1] := mx + ux * t, pts[2*ni] := my + uy * t
        }
        pts[2*ei - 1] := mx, pts[2*ei] := my
        o.Pts := pts
        return
    }

    if (id = 'corner' && np = 3) {
        ; Two candidate elbows for one L. Chosen in DISPLAY space, because
        ; "square" means square on screen, then mapped back to master.
        m := MarkupMatrix(snip, 'display')
        if !m
            return
        MarkupXform(m, pts[1], pts[2], &sx, &sy)
        MarkupXform(m, pts[5], pts[6], &ex, &ey)
        MarkupCursorPos(snip, &dcx, &dcy)
        d1 := (dcx - ex) ** 2 + (dcy - sy) ** 2    ; horizontal-first corner
        d2 := (dcx - sx) ** 2 + (dcy - ey) ** 2    ; vertical-first corner
        if (d1 <= d2)
            ccx := ex, ccy := sy
        else
            ccx := sx, ccy := ey
        DllCall('gdiplus\GdipInvertMatrix', 'UPtr', m)
        MarkupXform(m, ccx, ccy, &nmx, &nmy)
        DllCall('gdiplus\GdipDeleteMatrix', 'UPtr', m)
        pts[3] := nmx, pts[4] := nmy
        o.Pts := pts
        return
    }

    if (SubStr(id, 1, 3) = 'seg') {
        i := Integer(SubStr(id, 4))
        if (i < 2 || i > np - 2)
            return
        ax := pts[2*i - 1], ay := pts[2*i]
        bx := pts[2*i + 1], by := pts[2*i + 2]
        if !MarkupPathDir(ax, ay, bx, by, &ux, &uy)
            return
        nx := -uy, ny := ux                         ; perpendicular to the segment
        ; Distance from the segment's original midpoint to the cursor, measured
        ; along that perpendicular. Both endpoints of the segment move by it.
        offs := (mx - (ax + bx) / 2) * nx + (my - (ay + by) / 2) * ny
        pts[2*i - 1] := ax + nx * offs, pts[2*i]     := ay + ny * offs
        pts[2*i + 1] := bx + nx * offs, pts[2*i + 2] := by + ny * offs
        o.Pts := pts
    }
}

MarkupApplyHandle(snip, o, orig, id, cx, cy) {
    MarkupToMaster(snip, cx, cy, &mx, &my)
    if (o.Type = 'path') {
        MarkupApplyPathHandle(snip, o, orig, id, mx, my)
        MarkupRender(snip)
        return
    }
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

; The Path Arrow drag, one mouse-move at a time.
;
; Tracked in DISPLAY space and mirrored into master, because "right angle" has
; to mean square ON SCREEN as you draw it.  _DPts is the display-space copy and
; _Axis is which way the live segment currently runs; both are scratch and are
; deleted when the drag ends.
;
; The last point in the list is always the LIVE end, following the cursor along
; the current axis.  A corner is committed when the cursor has travelled
; PathTurnTolerance ACROSS that axis — at which point the live point is frozen
; where it stands and a new live point starts from it on the other axis.
;
; There is no separate handling for dragging backwards: that just shortens the
; live segment, which the same two lines already do.
MarkupExtendPath(snip, o, cx, cy) {
    tol := Max(4, MarkupCfg.PathTurnTolerance)
    d   := o._DPts
    n   := d.Length
    ax  := d[n - 3], ay := d[n - 2]            ; last committed corner
    maxPts := Max(2, MarkupCfg.PathMaxSegments) + 1

    if (o._Axis = '') {
        ; Undecided until the drag clears the tolerance; then the larger of the
        ; two travels wins.
        if (Abs(cx - ax) < tol && Abs(cy - ay) < tol) {
            d[n - 1] := ax, d[n] := ay
            MarkupPathSyncMaster(snip, o)
            return
        }
        o._Axis := (Abs(cx - ax) >= Abs(cy - ay)) ? 'h' : 'v'
    }

    if (o._Axis = 'h') {
        if (Abs(cy - ay) >= tol) {
            if (Abs(cx - ax) >= tol && d.Length // 2 < maxPts) {
                d[n - 1] := cx, d[n] := ay      ; freeze the corner here
                d.Push(cx, cy)                  ; and start the new live segment
            } else {
                ; The segment so far is too short to be worth keeping — the user
                ; has simply changed their mind about the direction, so turn on
                ; the spot instead of leaving a stub behind.
                d[n - 1] := ax, d[n] := cy
            }
            o._Axis := 'v'
        } else {
            d[n - 1] := cx, d[n] := ay
        }
    } else {
        if (Abs(cx - ax) >= tol) {
            if (Abs(cy - ay) >= tol && d.Length // 2 < maxPts) {
                d[n - 1] := ax, d[n] := cy
                d.Push(cx, cy)
            } else {
                d[n - 1] := cx, d[n] := ay
            }
            o._Axis := 'h'
        } else {
            d[n - 1] := ax, d[n] := cy
        }
    }
    MarkupPathSyncMaster(snip, o)
}

; Mirror the display-space working points into the object's master-local Pts,
; which is what everything else in the module reads.
MarkupPathSyncMaster(snip, o) {
    pts := []
    i := 1
    while (i <= o._DPts.Length) {
        MarkupToMaster(snip, o._DPts[i], o._DPts[i + 1], &mx, &my)
        pts.Push(mx, my)
        i += 2
    }
    o.Pts := pts
    o.X1 := pts[1], o.Y1 := pts[2]
    o.X2 := pts[pts.Length - 1], o.Y2 := pts[pts.Length]
}

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
        MarkupSyncPallet()
        MarkupRender(snip)
        return
    }

    MarkupPushUndo(snip)
    o := MarkupNewObj(tool)
    o.X1 := mx, o.Y1 := my, o.X2 := mx, o.Y2 := my
    if (tool = 'pen')
        o.Pts := [mx, my]
    if (tool = 'path') {
        ; Scratch state for the drag; deleted below when it ends.  The list
        ; always holds committed corners plus one live end, so it starts with
        ; the anchor twice.
        o._DPts := [dx, dy, dx, dy]
        o._Axis := ''
        o.Pts   := [mx, my, mx, my]
    }
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
        if (o.Type = 'path')
            o.DeleteProp('_DPts'), o.DeleteProp('_Axis')
        mk.Objs.Pop()
        mk.Undo.Pop()
        MarkupState.Sel := 0
        MarkupRender(snip)
        return
    }

    if (o.Type = 'path') {
        ; Tidy up before the object becomes real: drop duplicate points and merge
        ; runs that never actually turned.  Then let the scratch state go.
        o.Pts := MarkupPathSimplify(o.Pts)
        o.DeleteProp('_DPts'), o.DeleteProp('_Axis')
        if (o.Pts.Length < 4) {           ; never left the anchor
            mk.Objs.Pop(), mk.Undo.Pop()
            MarkupState.Sel := 0
            MarkupRender(snip)
            return
        }
        o.X1 := o.Pts[1], o.Y1 := o.Pts[2]
        o.X2 := o.Pts[o.Pts.Length - 1], o.Y2 := o.Pts[o.Pts.Length]
    }
    if (o.Type != 'line' && o.Type != 'arrow' && o.Type != 'pen' && o.Type != 'path') {
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
    MarkupSyncPallet()
    MarkupRender(snip)
}

MarkupExtendDraw(snip, o, cx, cy) {
    if (o.Type = 'path') {
        ; Runs on the raw DISPLAY coordinates — see MarkupExtendPath.
        MarkupExtendPath(snip, o, cx, cy)
        MarkupRender(snip)
        return
    }
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

    ; OWNED by the snip.  Windows guarantees an owned window sits above its
    ; owner, which is the only reliable way to stay in front of a +AlwaysOnTop
    ; snip — relying on activation alone let the dialog end up BEHIND the snip,
    ; where it still had focus and still blocked this function's wait loop, so
    ; the whole app looked frozen.
    ;
    ; Ownership only constrains this dialog relative to that one snip.  It does
    ; not make the snip topmost, does not reorder it, and does not touch any
    ; other window.
    owner := (MarkupState.Active && WinExist('ahk_id ' MarkupState.Active))
           ? MarkupState.Active : 0
    g := Gui('+AlwaysOnTop +ToolWindow +OwnDialogs' (owner ? ' +Owner' owner : ''), title)
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

    ; Centre it on the snip and clamp to the desktop, so it lands where the user
    ; is already looking rather than wherever Windows would have cascaded it.
    ; Physical pixels via MarkupWinRect / WinMove, for the same reason as the
    ; pallet: this Gui keeps DPI scaling on for its layout, so Gui.Show's x/y
    ; would be logical units measured against a physical snip rect.
    g.Show('Hide')
    if (!MarkupWinRect(g.Hwnd, , , &pw, &ph) || !pw || !ph) {
        sc := A_ScreenDPI / 96.0
        pw := Round(340 * sc), ph := Round(180 * sc)
    }
    g.Show()
    if (owner && MarkupWinRect(owner, &ol, &ot, &ow, &oh)) {
        GetVirtualScreen(&vx, &vy, &vw, &vh)
        px := Max(vx, Min(ol + (ow - pw) // 2, vx + vw - pw))
        py := Max(vy, Min(ot + (oh - ph) // 2, vy + vh - ph))
        WinMove(px, py, , , 'ahk_id ' g.Hwnd)
    }
    MarkupPrompt.Hwnd := g.Hwnd      ; set AFTER Show, so the hotkey context
    try WinActivate('ahk_id ' g.Hwnd) ; can't match a window that isn't up yet
    ed.Focus()
    while !MarkupPrompt.Done {
        ; Bail out if the window disappears from under us (the snip being
        ; destroyed would take an owned dialog with it).  Without this the loop
        ; would spin forever on a Done flag nothing can ever set.
        if !WinExist('ahk_id ' g.Hwnd) {
            MarkupPrompt.Value := ''
            break
        }
        Sleep 20
    }
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
; TOOL Pallet
; ==============================================================================
;
; A SEPARATE always-on-top window, not a toolbar bolted onto the snip.  That is
; deliberate: the snip window's whole identity is "a picture floating there with
; no chrome", and docking controls inside it would fight the border, bevel,
; shadow and margin code and fall apart on a small snip.  As a separate window
; the pallet also serves whichever snip is active rather than needing one copy
; per snip, and RenderSnip never learns it exists — structurally the same
; arrangement as the drop shadow.
;
; WS_EX_NOACTIVATE (0x08000000) is the detail that makes it feel right: clicking
; a pallet control does NOT take focus away from the snip, so the single-letter
; tool keys keep working and the snip stays the active window throughout.

; label, internal name, key hint — one row of the tool list.
MarkupToolTable() {
    static t := [ ['Select',      'select',    'V']
                , ['Rectangle',   'rect',      'R']
                , ['Ellipse',     'ellipse',   'E']
                , ['Line',        'line',      'L']
                , ['Arrow',       'arrow',     'A']
                , ['Path Arrow',  'path',      'D']
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

MarkupShowPallet() {
    if MarkupState.Pallet {
        MarkupPositionPallet()
        MarkupState.Pallet.Show('NoActivate')
        MarkupRaisePallet()
        MarkupSyncPallet()
        return
    }
    g := Gui('+AlwaysOnTop +ToolWindow +E0x08000000', 'Markup')
    g.MarginX := 10, g.MarginY := 10
    g.SetFont('s9', 'Segoe UI')
    ctl := MarkupState.Ctl := Map()
    MarkupState.ThickList := ''
    MarkupState.HeadList  := 'arrow'   ; matches the list the Head box is built with

    ; Absolute x/y throughout.  Relative positioning (y+8 / yp) is tidier to
    ; read but it makes the swatch grid, which wraps mid-row, a nuisance — and a
    ; pallet that lays itself out differently under a non-default system font
    ; is worse than a few explicit numbers.
    items := []
    for row in MarkupToolTable()
        items.Push(row[1] '  (' row[3] ')')
    ctl['tools'] := g.Add('ListBox', 'x10 y10 w210 h206 Choose1', items)
    ctl['tools'].OnEvent('Change', MarkupPal_Tool)

    ctl['lblcolor'] := g.Add('Text', 'x10 y224 w210 h16'
                           , 'Color  (Ctrl+click sets fill)')
    i := 0
    for col in MarkupSwatches() {
        xx := 10 + Mod(i, 6) * 27
        yy := (i < 6) ? 244 : 271
        sw := g.Add('Text', 'x' xx ' y' yy ' w22 h22 Border Background' Format('{:06X}', col))
        sw.OnEvent('Click', MarkupPal_Color.Bind(col))
        i++
    }

    ctl['fill']    := g.Add('Checkbox', 'x10 y304 w210 h18', 'Fill shape')
    ctl['outline'] := g.Add('Checkbox', 'x10 y326 w210 h18', 'Outline (legibility halo)')
    ctl['shadow']  := g.Add('Checkbox', 'x10 y348 w210 h18', 'Drop shadow')
    ctl['fill'].OnEvent('Click',    MarkupPal_Check.Bind('Fill'))
    ctl['outline'].OnEvent('Click', MarkupPal_Check.Bind('Outline'))
    ctl['shadow'].OnEvent('Click',  MarkupPal_Check.Bind('Shadow'))

    ctl['lblthick'] := g.Add('Text', 'x10 y376 w44 h22 +0x200', 'Width')
    ctl['thick'] := g.Add('DropDownList', 'x58 y373 w56'
                        , MarkupStepStrings(MarkupThickSteps()))
    ctl['lblfont'] := g.Add('Text', 'x122 y376 w34 h22 +0x200', 'Font')
    ctl['font']  := g.Add('DropDownList', 'x160 y373 w60'
                        , MarkupStepStrings(MarkupFontSteps()))
    ctl['thick'].OnEvent('Change', MarkupPal_Num.Bind('Thick'))
    ctl['font'].OnEvent('Change',  MarkupPal_Num.Bind('FontSize'))

    ; ── Geometry and line style ──────────────────────────────────────────────
    ; Head is the arrowhead length as a multiple of the stroke width, so a head
    ; stays in proportion when the line gets fatter.  Corner is the rounding on
    ; a Rectangle, Highlighter or Callout box and the elbow radius on a Path
    ; Arrow; 'auto' keeps whatever the type derived before the setting existed.
    ctl['lblhead'] := g.Add('Text', 'x10 y404 w44 h22 +0x200', 'Head')
    ctl['head'] := g.Add('DropDownList', 'x58 y401 w56'
                       , ['1.5','2','2.5','3','3.5','4','4.5','5','6','8'])
    ctl['lblcorner'] := g.Add('Text', 'x120 y404 w46 h22 +0x200', 'Corner')
    ctl['corner'] := g.Add('DropDownList', 'x170 y401 w50'
                         , ['auto','0','2','3','4','6','8','10','12','16','20','24','32'])
    ctl['head'].OnEvent('Change',   MarkupPal_Head)
    ctl['corner'].OnEvent('Change', MarkupPal_Corner)

    ctl['lbldash'] := g.Add('Text', 'x10 y432 w44 h22 +0x200', 'Dash')
    ctl['dash'] := g.Add('DropDownList', 'x58 y429 w162', [])
    ctl['dash'].OnEvent('Change', MarkupPal_Style.Bind('Dash'))

    ctl['lblends'] := g.Add('Text', 'x10 y460 w44 h22 +0x200', 'Ends')
    ctl['capstart'] := g.Add('DropDownList', 'x58 y457 w70', [])
    ctl['swap']     := g.Add('Button', 'x132 y457 w22 h22', Chr(0x21C4))
    ctl['capend']   := g.Add('DropDownList', 'x158 y457 w62', [])
    ctl['capstart'].OnEvent('Change', MarkupPal_Style.Bind('CapStart'))
    ctl['capend'].OnEvent('Change',   MarkupPal_Style.Bind('CapEnd'))
    ctl['swap'].OnEvent('Click',      (*) => MarkupSwapEnds())

    ; The preview is drawn by the SAME MarkupDrawObject the snip uses, on a
    ; throwaway object — so it cannot drift out of step with what you actually
    ; get.  A preview that lies is worse than no preview at all.
    ctl['preview'] := g.Add('Picture', 'x10 y488 w210 h38 Border')

    ctl['undo'] := g.Add('Button', 'x10  y536 w66 h26', 'Undo')
    ctl['redo'] := g.Add('Button', 'x80  y536 w66 h26', 'Redo')
    ctl['del']  := g.Add('Button', 'x150 y536 w70 h26', 'Delete')
    ctl['undo'].OnEvent('Click', (*) => MarkupUndo())
    ctl['redo'].OnEvent('Click', (*) => MarkupRedo())
    ctl['del'].OnEvent('Click',  (*) => MarkupDeleteSel())

    ctl['savedef'] := g.Add('Button', 'x10  y570 w120 h26', 'Save as default')
    ctl['editsty'] := g.Add('Button', 'x134 y570 w86  h26', 'Line styles…')
    ctl['savedef'].OnEvent('Click', (*) => MarkupSaveDefaults())
    ctl['editsty'].OnEvent('Click', (*) => MarkupStyleEditor())

    ctl['done'] := g.Add('Button', 'x10 y604 w210 h26', 'Done  (Esc)')
    ctl['done'].OnEvent('Click', (*) => MarkupEnd())

    g.OnEvent('Close', (*) => MarkupEnd())
    MarkupState.Pallet := g
    ; After Pallet is set, not before: MarkupFillStyleLists (and the preview
    ; inside MarkupSyncPallet) both bail out when there is no pallet, so
    ; filling the cap and dash lists earlier would silently do nothing.
    MarkupFillStyleLists()
    ; Show('Hide') creates the window without displaying it, so GetPos in
    ; MarkupPositionPallet has real dimensions to work with. Positioning after
    ; a visible Show would make the pallet jump on first open.
    ; Placed once while hidden (so it never flashes at the wrong spot) and again
    ; once visible, because a Show with no coordinates can re-centre a window
    ; that is being displayed for the first time.  The second call is idempotent.
    g.Show('Hide')
    MarkupPositionPallet()
    g.Show('NoActivate')
    MarkupPositionPallet()
    MarkupRaisePallet()
    MarkupSyncPallet()
}

; Lift the pallet to the top of the topmost band.
;
; WHY THIS IS NEEDED: snip windows are +AlwaysOnTop, and the pallet is
; WS_EX_NOACTIVATE so that clicking its controls doesn't steal focus from the
; snip.  That combination has a nasty consequence — activating the snip raises
; it within the topmost band, and a NOACTIVATE window can never be raised by
; activation, so the pallet ends up buried under the very snip it belongs to.
;
; WHAT THIS DOES NOT DO: it never calls SetWindowPos on a snip.  Only the
; pallet's own z-order changes, with NOMOVE | NOSIZE | NOACTIVATE, so nothing
; here can demote a snip or disturb the ordering the core sets up when a snip is
; created.  That matters: snips reverting behind the window they were cut from
; is a bug this project has already had to fix once.
; A window's rect in PHYSICAL screen pixels.
;
; This exists because the pallet is the one Gui in the project that keeps DPI
; scaling switched on — it has an absolute-positioned layout that has to grow
; with the display, unlike the core's -DPIScale overlays which are positioned
; but not laid out.  The cost is that Gui.GetPos and Gui.Move speak SCALED
; logical units, while GetWindowRect (and everything the core does with snip
; coordinates) speaks physical pixels.  Mixing the two put the pallet at
; roughly 1/scale of the intended offset, which on a 125% display landed it on
; top of the snip instead of beside it.
;
; So: every placement calculation below reads with GetWindowRect and writes with
; WinMove, both of which are physical.  Gui.GetPos and Gui.Move are not used for
; positioning at all.
MarkupWinRect(hwnd, &x?, &y?, &w?, &h?) {
    r := Buffer(16, 0)
    if !DllCall('GetWindowRect', 'Ptr', hwnd, 'Ptr', r) {
        x := y := w := h := 0
        return false
    }
    x := NumGet(r, 0, 'Int'),     y := NumGet(r, 4, 'Int')
    w := NumGet(r, 8, 'Int') - x, h := NumGet(r, 12, 'Int') - y
    return true
}

MarkupRaisePallet() {
    g := MarkupState.Pallet
    if (!g || !MarkupState.Active)
        return
    if !DllCall('IsWindowVisible', 'Ptr', g.Hwnd)
        return
    DllCall('SetWindowPos', 'Ptr', g.Hwnd, 'Ptr', -1      ; HWND_TOPMOST
          , 'Int', 0, 'Int', 0, 'Int', 0, 'Int', 0
          , 'UInt', 0x0013)                               ; NOSIZE|NOMOVE|NOACTIVATE
}

; WM_ACTIVATE on the snip being marked up.  Registered only for the duration of
; a markup session (see MarkupBegin / MarkupEnd), and it ignores every window
; except the one snip in markup mode — a snip being created or activated while
; markup runs on a DIFFERENT snip falls straight through.
MarkupOnActivate(wParam, lParam, msg, hwnd) {
    if (hwnd = MarkupState.Active && (wParam & 0xFFFF) != 0)   ; WA_ACTIVE|WA_CLICKACTIVE
        MarkupRaisePallet()
}

MarkupHidePallet() {
    if MarkupState.Pallet {
        try {
            ; Physical, to match WinMove in MarkupPositionPallet.  Storing a
            ; Gui.GetPos reading here would drift the pallet by the DPI factor
            ; every time it was hidden and reshown.
            if MarkupWinRect(MarkupState.Pallet.Hwnd, &px, &py) {
                MarkupState.PalX := px, MarkupState.PalY := py
                MarkupState.PalOwner := MarkupState.Active
            }
        }
        MarkupState.Pallet.Hide()
    }
}

; Park the pallet beside the snip, PalletGap pixels clear of it: left if there
; is room, right if not, and below (or above) if neither side fits.
;
; A position the user has dragged it to is remembered, but only for the snip it
; was dragged against — PalOwner.  Remembering it globally was wrong: the
; pallet would reappear wherever it happened to sit last, which for a snip
; somewhere else on screen usually meant straight on top of the new snip, and
; made PalletGap look like it was being ignored entirely.
MarkupPositionPallet() {
    global guiSnips
    g := MarkupState.Pallet
    if (!g || !MarkupState.Active || !guiSnips.Has(MarkupState.Active))
        return
    if (MarkupState.PalX != '' && MarkupState.PalOwner = MarkupState.Active) {
        WinMove(MarkupState.PalX, MarkupState.PalY, , , 'ahk_id ' g.Hwnd)
        return
    }
    ; Physical pixels on both sides — see MarkupWinRect.  The fallback is only
    ; reached if GetWindowRect fails outright, and is scaled to match, since a
    ; logical-unit fallback would reintroduce the very mismatch this avoids.
    if (!MarkupWinRect(g.Hwnd, , , &pw, &ph) || !pw || !ph) {
        sc := A_ScreenDPI / 96.0
        pw := Round(236 * sc), ph := Round(650 * sc)
    }
    if !MarkupWinRect(MarkupState.Active, &sl, &st, &sw, &sh)
        return
    sr := sl + sw, sb := st + sh
    GetVirtualScreen(&vx, &vy, &vw, &vh)
    gap := MarkupCfg.PalletGap

    x := sl - pw - gap, y := st
    if (x < vx) {                          ; no room on the left — try the right
        x := sr + gap
        if (x + pw > vx + vw) {            ; nor the right — go under the snip
            x := sl
            y := sb + gap
            if (y + ph > vy + vh)          ; nor under — go above it
                y := st - ph - gap
        }
    }
    x := Max(vx, Min(x, vx + vw - pw))
    y := Max(vy, Min(y, vy + vh - ph))
    WinMove(x, y, , , 'ahk_id ' g.Hwnd)
    MarkupState.PalOwner := MarkupState.Active
}

; The Width box serves two ladders — object stroke widths and frame widths —
; and a DropDownList shows blank for a value that isn't one of its items, so
; the list itself has to swap when the frame is selected.  Reloaded only on an
; actual change of ladder; doing it on every sync would flicker the control.
MarkupSetThickList(border) {
    ctl  := MarkupState.Ctl
    want := border ? 'border' : 'obj'
    if (MarkupState.ThickList = want || !ctl.Has('thick'))
        return
    MarkupState.ThickList := want
    try {
        ctl['thick'].Delete()
        ctl['thick'].Add(MarkupStepStrings(border ? MarkupBorderSteps()
                                                  : MarkupThickSteps()))
    }
}

; The Head box serves two ladders as well — arrowhead scale for anything that
; strokes, disc diameter for a number badge.  Same reload-only-on-change rule as
; the Width box, and for the same reason.
MarkupSetHeadList(mode) {
    ctl := MarkupState.Ctl
    if (MarkupState.HeadList = mode || !ctl.Has('head'))
        return
    MarkupState.HeadList := mode
    try {
        ctl['head'].Delete()
        if (mode = 'number') {
            list := ['auto']
            for v in MarkupNumDiaSteps()
                list.Push(String(v))
            ctl['head'].Add(list)
        } else
            ctl['head'].Add(['1.5','2','2.5','3','3.5','4','4.5','5','6','8'])
    }
}

; WHAT the pallet is currently describing: the frame, the primary selected
; object, or — with nothing selected — the tool about to be used.  A borrowed
; tool reports the tool you get back, matching what the tool list highlights.
;
; A mixed group reports its primary, which is the same rule the style controls
; already follow; changing a control still applies to the whole group.
MarkupSubjectType() {
    if MarkupBorderSelected()
        return 'border'
    if (o := MarkupState.Sel)
        return o.Type
    return (MarkupState.Borrowed != '') ? MarkupState.Borrowed : MarkupState.Tool
}

; Which controls mean anything for which subject.  A space-delimited list per
; type, because the alternative — a Map of Maps — is more machinery than a
; fourteen-row lookup deserves and reads worse.
;
; Anything absent is GREYED, never hidden.  Hiding would reflow a pallet laid
; out in absolute coordinates, so every switch of tool would move the buttons
; under the pointer; and a dimmed Fill box still tells you Fill is a thing the
; Blur tool hasn't got, where a missing one just looks like a bug.
;
; Notes on the less obvious rows:
;   highlight — strokes nothing, so Width does nothing; Fill is forced on and
;               the halo pass skips the type outright.
;   number    — Fill is forced on and FillColor tracks Color, so the checkbox is
;               a no-op; Head is the disc size (see MarkupNumDia).
;   ellipse   — has no corners to round.
;   blur      — has no style at all.  Deliberately the empty string, not a
;               missing row: absent means "unknown type, leave everything on".
MarkupApplyTable() {
    static t := Map(
        'select',    'color fill outline shadow thick font head corner dash ends'
      , 'rect',      'color fill outline shadow thick corner dash'
      , 'ellipse',   'color fill outline shadow thick dash'
      , 'line',      'color outline shadow thick head dash ends'
      , 'arrow',     'color outline shadow thick head dash ends'
      , 'path',      'color outline shadow thick head corner dash ends'
      , 'pen',       'color outline shadow thick head dash ends'
      , 'highlight', 'color shadow corner'
      , 'text',      'color outline shadow font'
      , 'number',    'color outline shadow thick font head'
      , 'callout',   'color fill outline shadow thick font corner dash'
      , 'blur',      ''
      , 'image',     'shadow'
      , 'border',    'color thick')
    return t
}

; Grey the controls the current subject has no use for.
;
; The colour swatches are Static controls with a Background style, and a
; disabled Static still paints its background — so there is nothing to dim.
; Their LABEL greys instead, and MarkupPal_Color refuses the click, which is the
; part that actually matters.  (Blur is the only subject this affects.)
MarkupSyncEnable() {
    static groups := Map('lblcolor', 'color'
                       , 'fill',     'fill'
                       , 'outline',  'outline'
                       , 'shadow',   'shadow'
                       , 'thick',    'thick',  'lblthick',  'thick'
                       , 'font',     'font',   'lblfont',   'font'
                       , 'head',     'head',   'lblhead',   'head'
                       , 'corner',   'corner', 'lblcorner', 'corner'
                       , 'dash',     'dash',   'lbldash',   'dash'
                       , 'capstart', 'ends',   'capend',    'ends'
                       , 'swap',     'ends',   'lblends',   'ends')
    if !MarkupState.Pallet
        return
    ctl  := MarkupState.Ctl
    tbl  := MarkupApplyTable()
    subj := MarkupSubjectType()
    ; An unlisted type is left fully enabled rather than fully greyed: a new
    ; object type someone forgets to add here degrades to today's behaviour.
    live := ' ' (tbl.Has(subj) ? tbl[subj] : tbl['select']) ' '
    for key, grp in groups
        if ctl.Has(key)
            try ctl[key].Enabled := InStr(live, ' ' grp ' ') ? true : false
    MarkupState.ColorLive := InStr(live, ' color ') ? true : false

    ; The Head box means something different on a badge, so it says so.
    if ctl.Has('lblhead')
        try ctl['lblhead'].Text := (subj = 'number') ? 'Disc' : 'Head'
}

; Reflect the current selection (or, with nothing selected, the defaults for the
; NEXT object) in the style controls.  One control set doing both jobs is the
; whole trick that keeps "draw an arrow, then recolour it" from needing a
; properties dialog.
MarkupSyncPallet() {
    if !MarkupState.Pallet
        return
    ctl := MarkupState.Ctl

    ; Frame selected: Width shows the border, everything else keeps showing the
    ; current tool so the pallet still describes the next object you draw.
    if (snip := MarkupBorderSnip()) {
        MarkupSetThickList(true)
        try ctl['thick'].Text := String(SnipBorderW(snip))
        try ctl['tools'].Value := 1                     ; Select
        MarkupSyncEnable()
        MarkupUpdatePreview()
        return
    }

    ; With a group selected the controls show the PRIMARY (first) object, but
    ; changing one applies to the whole group — see MarkupApplyStyle.
    o   := MarkupState.Sel
    thick := o ? o.Thick    : MarkupCfg.Thickness
    fsize := o ? o.FontSize : MarkupCfg.FontSize
    try ctl['fill'].Value    := (o ? o.Fill    : false) ? 1 : 0
    try ctl['outline'].Value := (o ? o.Outline : MarkupCfg.Outline) ? 1 : 0
    try ctl['shadow'].Value  := (o ? o.Shadow  : MarkupCfg.Shadow)  ? 1 : 0
    MarkupSetThickList(false)
    try ctl['thick'].Text    := String(thick)
    try ctl['font'].Text     := String(fsize)

    ; Line style shows the selection when there is one, otherwise the CURRENT
    ; TOOL's remembered style — which is also what changing a control edits.
    st   := MarkupToolStyle(MarkupState.Tool)
    dash := o ? o.Dash     : st.Dash
    cs   := o ? o.CapStart : st.CapStart
    ce   := o ? o.CapEnd   : st.CapEnd
    corn := (o && o.HasProp('Corner')) ? o.Corner : (o ? 0 : st.Corner)
    hsc  := (o && o.HasProp('HeadScale')) ? o.HeadScale : MarkupCfg.ArrowHeadScale
    try ctl['dash'].Text     := MarkupDash(dash).Name
    try ctl['capstart'].Text := MarkupCap(cs).Name
    try ctl['capend'].Text   := MarkupCap(ce).Name
    try ctl['corner'].Text   := (corn < 0) ? 'auto' : MarkupNumText(corn)

    ; Head wears two hats.  On a badge it is the disc diameter in pixels, which
    ; needs its own ladder AND its own 'auto'; everywhere else it stays the
    ; arrowhead scale it always was.
    if (MarkupSubjectType() = 'number') {
        MarkupSetHeadList('number')
        nd := (o && o.HasProp('NumDia')) ? o.NumDia : MarkupCfg.NumberDia
        try ctl['head'].Text := (nd > 0) ? String(Integer(nd)) : 'auto'
    } else {
        MarkupSetHeadList('arrow')
        try ctl['head'].Text := MarkupNumText(hsc)
    }

    ; With a tool on loan the list highlights the tool you will GET BACK, not
    ; the Select you are temporarily using — otherwise the pallet would say
    ; Select right up until an arrow appeared out of nowhere.
    shown := (MarkupState.Borrowed != '') ? MarkupState.Borrowed : MarkupState.Tool
    for i, row in MarkupToolTable()
        if (row[2] = shown) {
            try ctl['tools'].Value := i
            break
        }
    MarkupSyncEnable()
    MarkupUpdatePreview()
}

; Refill the two cap lists and the dash list from the registries.  Called on
; pallet build and again after every reload, which is the whole of what the
; pallet has to do to pick up a newly defined arrowhead.
MarkupFillStyleLists() {
    if !MarkupState.Pallet
        return
    if !MarkupStyles.Ready
        MarkupLoadStyles()
    ctl  := MarkupState.Ctl
    caps := [], dashes := []
    for id in MarkupStyles.CapOrder
        caps.Push(MarkupStyles.Caps[id].Name)
    for id in MarkupStyles.DashOrder
        dashes.Push(MarkupStyles.Dashes[id].Name)
    for key in ['capstart', 'capend'] {
        if ctl.Has(key) {
            try ctl[key].Delete()
            try ctl[key].Add(caps)
        }
    }
    if ctl.Has('dash') {
        try ctl['dash'].Delete()
        try ctl['dash'].Add(dashes)
    }
}

; The object the preview strip draws.  A short line carrying whatever the
; selection (or the current tool) is set to, with the thickness capped so a
; 16px stroke doesn't overflow a 38px strip, and shadow forced off because the
; strip has no background for one to fall on.
MarkupPreviewObj() {
    o := MarkupNewObj('line')
    ; A plain bar in the frame's colour and width — the frame has no caps, dash
    ; or halo, and showing the tool's would misrepresent what a click does next.
    if (snip := MarkupBorderSnip()) {
        o.Color := SnipBorderColor(snip)
        o.Thick := SnipBorderW(snip)
        o.Dash  := 'solid', o.CapStart := 'none', o.CapEnd := 'none'
        o.Outline := false, o.Shadow := false
        o.Thick := Min(o.Thick, 7)
        o.X1 := 14, o.Y1 := 19, o.X2 := 192, o.Y2 := 19
        return o
    }
    if (sel := MarkupState.Sel) {
        o.Color   := sel.Color
        o.Thick   := sel.Thick
        o.Dash    := sel.Dash
        o.CapStart := sel.CapStart, o.CapEnd := sel.CapEnd
        o.Outline := sel.Outline
        o.HeadScale := sel.HasProp('HeadScale') ? sel.HeadScale : MarkupCfg.ArrowHeadScale
    } else {
        st := MarkupToolStyle(MarkupState.Tool)
        o.Color   := MarkupCfg.Color
        o.Thick   := MarkupCfg.Thickness
        o.Dash    := st.Dash
        o.CapStart := st.CapStart, o.CapEnd := st.CapEnd
        o.Outline := MarkupCfg.Outline
        o.HeadScale := MarkupCfg.ArrowHeadScale
    }
    o.Shadow := false
    o.Thick  := Min(o.Thick, 7)

    ; A Highlighter strokes nothing, so a thin opaque line is a poor likeness of
    ; it.  Show what it actually lays down: a fat translucent bar in its own
    ; remembered colour.
    if (MarkupSubjectType() = 'highlight') {
        sel := MarkupState.Sel
        o.Color   := sel ? sel.FillColor : MarkupCfg.HighlightColor
        o.Alpha   := sel ? sel.Alpha     : MarkupCfg.HighlightAlpha
        o.Thick   := 16
        o.Dash    := 'solid'
        o.CapStart := 'none', o.CapEnd := 'none'
        o.Outline := false
    }
    pad := MarkupHeadSize(o) * 0.6
    o.X1 := 14 + pad, o.Y1 := 19
    o.X2 := 192 - pad, o.Y2 := 19
    return o
}

MarkupUpdatePreview() {
    if (!MarkupState.Pallet || !MarkupState.Ctl.Has('preview'))
        return
    MarkupRenderStrip(MarkupState.Ctl['preview'], MarkupPreviewObj(), 206, 34, 'Pallet')
}

; Draw one markup object into an HBITMAP and hand it to a Picture control.
; Shared by the pallet strip and both previews in the style editor, so all
; three are guaranteed to agree with the snip and with each other.
;
; slot names the caller so each control's previous handle can be tracked
; separately.  The old handle is freed only after GetObjectType confirms it is
; still a live object: setting a Picture's Value can itself destroy the bitmap
; the control was showing, and double-freeing a GDI handle is a far worse bug
; than leaking a 30KB bitmap.
MarkupRenderStrip(ctrl, o, w, h, slot) {
    static handles := Map()
    static BACK := 0xFFF0F0F0                 ; button-face, so the strip blends
    DllCall('gdiplus\GdipCreateBitmapFromScan0', 'Int', w, 'Int', h, 'Int', 0
          , 'Int', 0x26200A, 'Ptr', 0, 'UPtr*', &pBmp := 0)
    if !pBmp
        return
    DllCall('gdiplus\GdipGetImageGraphicsContext', 'UPtr', pBmp, 'UPtr*', &pGfx := 0)
    if pGfx {
        DllCall('gdiplus\GdipSetSmoothingMode', 'UPtr', pGfx, 'Int', 4)
        DllCall('gdiplus\GdipGraphicsClear', 'UPtr', pGfx, 'UInt', BACK)
        try MarkupDrawObject(pGfx, o)
        DllCall('gdiplus\GdipDeleteGraphics', 'UPtr', pGfx)
    }
    DllCall('gdiplus\GdipCreateHBITMAPFromBitmap', 'UPtr', pBmp
          , 'UPtr*', &hbm := 0, 'UInt', BACK)
    DllCall('gdiplus\GdipDisposeImage', 'UPtr', pBmp)
    if !hbm
        return
    old := handles.Has(slot) ? handles[slot] : 0
    try ctrl.Value := 'HBITMAP:*' hbm
    handles[slot] := hbm
    if (slot = 'Pallet')
        MarkupState.PreviewBmp := hbm
    if (old && old != hbm && DllCall('gdi32\GetObjectType', 'Ptr', old))
        DllCall('DeleteObject', 'Ptr', old)
}

MarkupPal_Tool(ctrl, *) {
    v := ctrl.Value
    if v
        MarkupSetTool(MarkupToolTable()[v][2])
}

; Every DELIBERATE tool change comes through here — pallet click, hotkey, the
; Esc ladder — so this is also where a borrowed tool is forgotten.  Choosing a
; tool by hand means you meant it, and nothing should hand you a different one
; later.  MarkupBorrowSelect arms the loan immediately AFTER calling this, which
; is the only way the flag ever gets set.
MarkupSetTool(name) {
    MarkupState.Tool     := name
    MarkupState.Borrowed := ''
    ; Picking a drawing tool clears the selection, so the style controls
    ; immediately describe what you are about to draw rather than what you last
    ; had selected.
    if (name != 'select' && (MarkupState.Sels.Length || MarkupState.BorderSel)) {
        global guiSnips
        MarkupState.Sels := []
        MarkupState.BorderSel := false
        if guiSnips.Has(MarkupState.Active)
            MarkupRender(guiSnips[MarkupState.Active])
    }
    MarkupSyncPallet()
}

; Give a borrowed drawing tool back.  Returns true if there was one, so the
; caller knows the click it is holding belongs to that tool now.
MarkupReturnTool() {
    if (MarkupState.Borrowed = '')
        return false
    tool := MarkupState.Borrowed
    MarkupState.Borrowed := ''
    MarkupState.Tool      := tool
    MarkupState.Sels      := []
    MarkupState.BorderSel := false
    MarkupSyncPallet()
    return true
}

; Ctrl+click a swatch to set the FILL colour instead of the stroke.
;
; The swatches can't be greyed (a disabled Static still paints its Background),
; so the refusal lives here instead — see MarkupSyncEnable.
MarkupPal_Color(col, *) {
    if !MarkupState.ColorLive
        return
    prop := GetKeyState('Ctrl', 'P') ? 'FillColor' : 'Color'
    MarkupApplyStyle(prop, col)
    ; A highlighter is already fill-only, so turning the global Fill default on
    ; as a side effect of picking its colour would be a surprise aimed at every
    ; OTHER tool.
    if (prop = 'FillColor' && MarkupSubjectType() != 'highlight')
        MarkupApplyStyle('Fill', true)
}

MarkupPal_Check(prop, ctrl, *) => MarkupApplyStyle(prop, ctrl.Value ? true : false)
MarkupPal_Num(prop, ctrl, *)   => MarkupApplyStyle(prop, Integer(ctrl.Text))

; The style dropdowns carry DISPLAY names; the objects carry ids.  Lowercasing
; here is the whole of the conversion, which is why a cap's id is defined as the
; lowercase of its name rather than as a separate field the user could get wrong.
MarkupPal_Style(prop, ctrl, *) => MarkupApplyStyle(prop, StrLower(ctrl.Text))
MarkupPal_Head(ctrl, *) {
    if (MarkupSubjectType() = 'number')
        MarkupApplyStyle('NumDia', (ctrl.Text = 'auto') ? 0 : Integer(ctrl.Text))
    else
        MarkupApplyStyle('HeadScale', Float(ctrl.Text))
}
MarkupPal_Corner(ctrl, *)      => MarkupApplyStyle('Corner'
                                                 , (ctrl.Text = 'auto') ? -1 : Integer(ctrl.Text))

; Reverse the two end treatments — on the selection if there is one, otherwise
; on the tool's default.  Drawn an arrow the wrong way round is common enough
; that this beats redrawing it.
MarkupSwapEnds() {
    global guiSnips
    if MarkupState.Sels.Length {
        hwnd := MarkupState.Active
        if !guiSnips.Has(hwnd)
            return
        snip := guiSnips[hwnd]
        MarkupPushUndo(snip)
        for o in MarkupState.Sels {
            tmp := o.CapStart
            o.CapStart := o.CapEnd, o.CapEnd := tmp
        }
        MarkupRender(snip)
    } else {
        st  := MarkupToolStyle(MarkupState.Tool)
        tmp := st.CapStart
        st.CapStart := st.CapEnd, st.CapEnd := tmp
    }
    MarkupSyncPallet()
}

; Step to the next (or previous) entry in a registry.  Bound to [ ] and \\ so a
; style can be tried on without going near the pallet.
MarkupCycleStyle(prop, dir := 1) {
    if !MarkupStyles.Ready
        MarkupLoadStyles()
    list := (prop = 'Dash') ? MarkupStyles.DashOrder : MarkupStyles.CapOrder
    if !list.Length
        return
    raw := (o := MarkupState.Sel) ? o.%prop% : MarkupToolStyle(MarkupState.Tool).%prop%
    cur := (prop = 'Dash') ? MarkupDash(raw).Id : MarkupCap(raw).Id
    idx := 1
    for i, id in list
        if (id = cur) {
            idx := i
            break
        }
    MarkupApplyStyle(prop, list[Mod(idx - 1 + dir + list.Length, list.Length) + 1])
}

; Write the current pallet state into the INI.
;
; A BUTTON, not a write on every click.  Colours and widths get changed
; constantly while annotating, and saving each one would make "my default" mean
; "whatever I last happened to use" — which is the opposite of a default.
MarkupSaveDefaults() {
    path := MarkupIniPath()
    try {
        IniWrite(Format('{:06X}', MarkupCfg.Color),     path, 'Markup', 'Color')
        IniWrite(Format('{:06X}', MarkupCfg.FillColor), path, 'Markup', 'FillColor')
        IniWrite(MarkupCfg.Thickness,          path, 'Markup', 'Thickness')
        IniWrite(MarkupCfg.FontSize,           path, 'Markup', 'FontSize')
        IniWrite(MarkupCfg.FillShapes ? 1 : 0, path, 'Markup', 'FillShapes')
        IniWrite(MarkupCfg.Outline    ? 1 : 0, path, 'Markup', 'Outline')
        IniWrite(MarkupCfg.Shadow     ? 1 : 0, path, 'Markup', 'Shadow')
        IniWrite(MarkupNumText(MarkupCfg.ArrowHeadScale)
               , path, 'Markup', 'ArrowHeadScale')
        IniWrite(Format('{:06X}', MarkupCfg.HighlightColor)
               , path, 'Markup', 'HighlightColor')
        IniWrite(Integer(MarkupCfg.NumberDia), path, 'Markup', 'NumberDia')

        for tool, prefix in Map('line', 'Line', 'arrow', 'Arrow'
                              , 'path', 'Path', 'pen',  'Pen') {
            st := MarkupToolStyle(tool)
            IniWrite(st.Dash,     path, 'Markup', prefix 'Dash')
            IniWrite(st.CapStart, path, 'Markup', prefix 'CapStart')
            IniWrite(st.CapEnd,   path, 'Markup', prefix 'CapEnd')
        }
        IniWrite(MarkupToolStyle('rect').Corner,    path, 'Markup', 'RectCorner')
        IniWrite(MarkupToolStyle('callout').Corner, path, 'Markup', 'CalloutCorner')
        IniWrite(MarkupToolStyle('path').Corner,    path, 'Markup', 'PathCornerRadius')
        saved := MarkupSaveBorderDefault(path)
        MarkupToast(saved ? 'Markup + frame defaults saved' : 'Markup defaults saved')
    } catch as e {
        MarkupToast('Could not save defaults: ' e.Message, 2500)
    }
}

; The frame is the one thing this button touches that does NOT live in
; [Markup] — it belongs to the core, so it is written to [SnipWindow] where
; ScreenSnip and SettingsManager both already look for it.
;
; The live globals are updated alongside the INI so the next snip you capture
; wears the new frame without a restart; existing snips keep the frame they
; have, which is the point of the properties being per-snip in the first place.
;
; Sourced from the ACTIVE snip rather than from a separate "default frame"
; variable, so what you save is visibly what you were just looking at.  With no
; markup session running there is nothing to read, and we quietly skip it rather
; than inventing a value.
MarkupSaveBorderDefault(path) {
    global guiSnips, BorderColor, BorderThickness
    if !guiSnips.Has(MarkupState.Active)
        return false
    snip := guiSnips[MarkupState.Active]
    col  := SnipBorderColor(snip)
    wid  := SnipBorderW(snip)
    ; Six bare hex digits, no 0x and no #, matching the file's stated convention
    ; and everything already in [SnipWindow].
    IniWrite(Format('{:06X}', col), path, 'SnipWindow', 'BorderColor')
    IniWrite(wid,                   path, 'SnipWindow', 'BorderThickness')
    BorderColor     := col
    BorderThickness := wid
    return true
}

MarkupToast(txt, ms := 1400) {
    ToolTip(txt)
    SetTimer(() => ToolTip(), -ms)
}

; With something selected, edit THAT object. With nothing selected, change the
; default for the next one. Same control, two jobs, no modes to explain.
MarkupApplyStyle(prop, value) {
    global guiSnips
    ; Checked first: a frame selection is only live while Sels is empty, so this
    ; and the branch below can never both be true.
    if MarkupBorderSelected() {
        MarkupApplyBorderStyle(prop, value)
        return
    }
    if MarkupState.Sels.Length {
        hwnd := MarkupState.Active
        if !guiSnips.Has(hwnd)
            return
        snip := guiSnips[hwnd]
        MarkupPushUndo(snip)
        ; Applied to EVERY selected object — select three arrows, click a
        ; swatch, all three change.
        for o in MarkupState.Sels {
            ; Disc size is meaningless on anything but a badge, and writing it
            ; anyway would leave a stray property on every object in a mixed
            ; group.  Skip rather than pollute.
            if (prop = 'NumDia' && o.Type != 'number')
                continue
            o.%prop% := value
            ; A number badge's disc IS its colour, so recolouring the stroke on
            ; one that has never been given a separate fill recolours the badge.
            ; A highlighter is the same case for the same reason: it draws only
            ; its fill, so a stroke colour it never paints would be a dead end.
            if (prop = 'Color' && (o.Type = 'number' || o.Type = 'highlight'))
                o.FillColor := value
            if (prop = 'FillColor' && o.Type = 'highlight')
                o.Color := value
        }
        MarkupRender(snip)
        MarkupSyncPallet()
        return
    }
    switch prop {
        ; The Highlighter keeps its own colour, like it keeps its own line
        ; style: picking cyan to highlight a paragraph shouldn't repaint the
        ; next arrow.  Both swatch gestures land on it, since a highlighter's
        ; stroke and fill are the same thing.
        case 'Color', 'FillColor':
            if (MarkupState.Tool = 'highlight')
                MarkupCfg.HighlightColor := value
            else if (prop = 'Color')
                MarkupCfg.Color := value
            else
                MarkupCfg.FillColor := value
        case 'Fill':      MarkupCfg.FillShapes := value
        case 'Thick':     MarkupCfg.Thickness := value
        case 'FontSize':  MarkupCfg.FontSize  := value
        case 'Outline':   MarkupCfg.Outline   := value
        case 'Shadow':    MarkupCfg.Shadow    := value
        case 'HeadScale': MarkupCfg.ArrowHeadScale := value
        case 'NumDia':    MarkupCfg.NumberDia := value
        ; These four are per TOOL, not per script — see MarkupToolStyle.  So
        ; setting a chevron end while the Line tool is active changes what Line
        ; draws next and leaves Arrow exactly as it was.
        case 'Dash', 'CapStart', 'CapEnd', 'Corner':
            MarkupToolStyle(MarkupState.Tool).%prop% := value
    }
    MarkupSyncPallet()
}

; The frame has exactly two properties.  The controls that mean nothing on it
; (fill, halo, dash, end caps, head, corner, font) are greyed by MarkupSyncEnable
; — see the 'border' row of MarkupApplyTable — but they keep SHOWING the current
; tool's values rather than blanking, so they still describe what the next drawn
; object will look like while you happen to have the frame selected.  Anything
; that reaches here anyway is ignored rather than trusted.
;
; Width is clamped to at least 1 by SetSnipBorder: "no frame" is the Border
; menu item's job.
MarkupApplyBorderStyle(prop, value) {
    snip := MarkupBorderSnip()
    if !snip
        return
    hwnd := MarkupState.Active
    switch prop {
        case 'Color':
            MarkupPushUndo(snip)
            SetSnipBorder(hwnd, value)
        case 'Thick':
            MarkupPushUndo(snip)
            SetSnipBorder(hwnd, '', value)
        default:
            return
    }
    ; The frame lives outside the Picture's bitmap, but the selection ring that
    ; marks it does not — and a width change moves the image edge it is drawn
    ; on, so the overlay has to be recomposed either way.
    MarkupRender(snip)
    MarkupSyncPallet()
}

; From the menu: if markup isn't running, starting it already shows the pallet,
; so don't immediately toggle it back off.
MarkupPalletMenuItem(hwnd) {
    if !MarkupState.Active
        MarkupBegin(hwnd)
    else
        MarkupTogglePallet()
}

MarkupTogglePallet() {
    if (MarkupState.Pallet && DllCall('IsWindowVisible', 'Ptr', MarkupState.Pallet.Hwnd))
        MarkupHidePallet()
    else
        MarkupShowPallet()
}

; ==============================================================================
; MOUSE WHEEL  —  resize the selection
; ==============================================================================
;
; With something selected, Ctrl+Wheel steps its size: stroke width for anything
; that draws a line, point size for Text and Number badges.
;
; CTRL rather than a bare wheel, for two reasons.  A plain binding would swallow
; every scroll over a snip, including the ones where nothing is selected and the
; user just meant to scroll the window behind.  And Ctrl is already the "reach
; into the objects" modifier here — Ctrl+click selects one, Ctrl+wheel resizes
; what you selected — so the two gestures tell one story instead of two.
;
; REGISTERED AT RUNTIME, not as a static #HotIf block, and that is deliberate.
; A permanently declared wheel hotkey puts the whole script into the mouse-hook
; chain for every scroll anywhere on the machine — which is precisely why the
; core's FreezeDetectWheel() registers its own wheel keys the same way.  Binding
; these only for the length of a markup session keeps that promise.
;
; Alt+Wheel is left alone: the core uses it to adjust snip transparency.

MarkupWheelHotkeys(turnOn) {
    state := turnOn ? 'On' : 'Off'
    HotIfWinActive('SnipperWindow ahk_class AutoHotkeyGUI')
    try Hotkey('^WheelUp',   MarkupWheelUp,   state)
    try Hotkey('^WheelDown', MarkupWheelDown, state)
    HotIf()
}

MarkupWheelUp(*)   => MarkupWheelSize(1)
MarkupWheelDown(*) => MarkupWheelSize(-1)

; The size ladders.  ONE definition each, shared with the pallet dropdowns, so
; the wheel can never land on a value the dropdown has no entry for — which
; would leave the pallet showing a stale number after every scroll.
MarkupThickSteps() {
    static t := [1, 2, 3, 4, 5, 6, 8, 10, 12, 16]
    return t
}

MarkupFontSteps() {
    static t := [10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48]
    return t
}

; The frame gets its own ladder rather than borrowing the stroke widths.  A
; 16px cap is generous for a pen line and stingy for a picture frame, which is
; the whole reason the border is worth making adjustable — so it runs to 40.
MarkupBorderSteps() {
    static t := [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 30, 40]
    return t
}

MarkupStepStrings(steps) {
    out := []
    for v in steps
        out.Push(String(v))
    return out
}

; The next rung up or down.  Strictly greater / strictly less rather than
; index arithmetic, so a value that ISN'T on the ladder (typed into the INI, or
; left over from an older step list) still moves sensibly instead of snapping to
; a neighbour it already passed.
MarkupStepValue(steps, cur, dir) {
    if (dir > 0) {
        for v in steps
            if (v > cur)
                return v
        return steps[steps.Length]
    }
    i := steps.Length
    while (i >= 1) {
        if (steps[i] < cur)
            return steps[i]
        i--
    }
    return steps[1]
}

; Which size a given object actually has.  Blur, highlighter and pasted images
; are excluded because none of them strokes anything — a "width" on those would
; be a control that visibly does nothing.
MarkupSizeProp(o) {
    switch o.Type {
        case 'text', 'number':            return 'FontSize'
        case 'blur', 'image', 'highlight': return ''
    }
    return 'Thick'
}

MarkupWheelSize(dir) {
    global guiSnips
    static lastTick := 0
    if !MarkupState.Active
        return
    ; Frame selected: the same gesture steps the border width, so Ctrl+Wheel
    ; means one thing everywhere rather than going dead on the frame.  Same
    ; ladder as the Width box, and the same don't-push-undo-on-a-no-op rule.
    if (snip := MarkupBorderSnip()) {
        cur := SnipBorderW(snip)
        nxt := MarkupStepValue(MarkupBorderSteps(), cur, dir)
        if (nxt = cur)
            return
        MarkupPushUndo(snip)
        SetSnipBorder(MarkupState.Active, '', nxt)
        MarkupRender(snip)
        MarkupSyncPallet()
        return
    }
    if !MarkupState.Sels.Length
        return
    if !guiSnips.Has(MarkupState.Active)
        return
    snip := guiSnips[MarkupState.Active]

    ; Work out every new value BEFORE touching anything.  Doing it in this order
    ; is what lets the undo entry be taken only when something will really move:
    ; MarkupPushUndo also clears the redo branch, so a notch at the end of the
    ; ladder must not reach it, or scrolling against the stop would silently
    ; throw away a redo the user still wanted.
    plan := []
    for o in MarkupState.Sels {
        prop := MarkupSizeProp(o)
        if (prop = '')
            continue
        steps := (prop = 'FontSize') ? MarkupFontSteps() : MarkupThickSteps()
        val   := MarkupStepValue(steps, o.%prop%, dir)
        if (val != o.%prop%)
            plan.Push({ Obj: o, Prop: prop, Val: val })
    }
    if !plan.Length
        return

    ; One undo entry per SPIN, not per notch.  Without this a three-second
    ; scroll would bury everything else on the stack under forty snapshots.
    now := A_TickCount
    if (now - lastTick > 700)
        MarkupPushUndo(snip)
    lastTick := now

    shown := ''
    for p in plan {
        p.Obj.%p.Prop% := p.Val
        if (shown = '')
            shown := (p.Prop = 'FontSize' ? 'Font ' : 'Width ') p.Val
    }
    MarkupSyncPallet()
    MarkupRender(snip)
    MarkupToast(shown, 700)
}

; ==============================================================================
; LINE STYLE EDITOR
; ==============================================================================
;
; Defines arrowheads and dash patterns and writes them to [MarkupCaps] /
; [MarkupDashes].  Saving re-registers immediately and re-renders every open
; snip, so nothing here needs a restart of ScreenSnip.
;
; The validator is MarkupParseCapLine — the SAME function that reads the INI at
; startup.  A definition the editor accepts is therefore one the loader will
; accept next time, which is the only way to be sure the dialog can't write a
; file that then fails to load.  It also means a definition typed by hand into
; the INI and one built here are indistinguishable, by construction.
;
; A custom entry may reuse a built-in name; MarkupDefCap replaces in place, so
; the override takes the built-in's slot in the lists rather than sitting next
; to it under the same label.  Deleting the override restores the built-in on
; the next reload, which is why Delete is offered even for built-in names.

class MarkupEd {
    static Gui     := ''
    static Ctl     := Map()
    static CapIds  := []          ; parallel to the caps ListBox
    static DashIds := []
}

MarkupStyleEditor() {
    if MarkupEd.Gui {
        MarkupEd.Gui.Show()
        MarkupEd_Fill()
        return
    }
    if !MarkupStyles.Ready
        MarkupLoadStyles()

    g := Gui('+AlwaysOnTop +ToolWindow', 'Markup Line Styles')
    g.MarginX := 8, g.MarginY := 8
    g.SetFont('s9', 'Segoe UI')
    ctl := MarkupEd.Ctl := Map()

    tabs := g.Add('Tab3', 'x8 y8 w464 h330', ['Arrowheads', 'Dashes'])

    ; ── Arrowheads ───────────────────────────────────────────────────────────
    tabs.UseTab(1)
    ctl['caplist'] := g.Add('ListBox', 'x20 y40 w140 h250')
    ctl['caplist'].OnEvent('Change', MarkupEd_LoadCap)

    g.Add('Text', 'x176 y42 w40 h22 +0x200', 'Name')
    ctl['capname'] := g.Add('Edit', 'x220 y40 w236')

    g.Add('Text', 'x176 y74 w40 h22 +0x200', 'Shape')
    ctl['capkind'] := g.Add('DropDownList', 'x220 y72 w90', ['poly', 'circle'])
    g.Add('Text', 'x320 y74 w34 h22 +0x200', 'Draw')
    ctl['capfill'] := g.Add('DropDownList', 'x358 y72 w98', ['fill', 'open', 'line'])
    ctl['capkind'].OnEvent('Change', MarkupEd_CapChanged)
    ctl['capfill'].OnEvent('Change', MarkupEd_CapChanged)

    g.Add('Text', 'x176 y106 w46 h22 +0x200', 'Shrink')
    ctl['capshrink'] := g.Add('Edit', 'x224 y104 w56')
    ctl['capshrink'].OnEvent('Change', MarkupEd_CapChanged)
    g.Add('Text', 'x288 y106 w168 h22 +0x200', 'how far the shaft stops short')

    ctl['caphint'] := g.Add('Text', 'x176 y134 w280 h16', 'Points')
    ctl['cappts']  := g.Add('Edit', 'x176 y152 w280 h72 Multi')
    ctl['cappts'].OnEvent('Change', MarkupEd_CapChanged)

    ctl['cappv'] := g.Add('Picture', 'x176 y232 w280 h44 Border')

    ctl['capnew'] := g.Add('Button', 'x176 y284 w64 h26', 'New')
    ctl['capcpy'] := g.Add('Button', 'x244 y284 w64 h26', 'Copy')
    ctl['capsav'] := g.Add('Button', 'x312 y284 w64 h26', 'Save')
    ctl['capdel'] := g.Add('Button', 'x380 y284 w76 h26', 'Delete')
    ctl['capnew'].OnEvent('Click', (*) => MarkupEd_NewCap())
    ctl['capcpy'].OnEvent('Click', (*) => MarkupEd_CopyCap())
    ctl['capsav'].OnEvent('Click', (*) => MarkupEd_SaveCap())
    ctl['capdel'].OnEvent('Click', (*) => MarkupEd_DeleteCap())

    ; ── Dashes ───────────────────────────────────────────────────────────────
    tabs.UseTab(2)
    ctl['dashlist'] := g.Add('ListBox', 'x20 y40 w140 h250')
    ctl['dashlist'].OnEvent('Change', MarkupEd_LoadDash)

    g.Add('Text', 'x176 y42 w52 h22 +0x200', 'Name')
    ctl['dashname'] := g.Add('Edit', 'x232 y40 w224')

    g.Add('Text', 'x176 y74 w52 h22 +0x200', 'Pattern')
    ctl['dashpat'] := g.Add('Edit', 'x232 y72 w224')
    ctl['dashpat'].OnEvent('Change', MarkupEd_DashChanged)

    g.Add('Text', 'x176 y104 w280 h48'
        , 'Lengths alternating on, off, on, off …  Each is a multiple of the '
        . 'stroke width, so a pattern keeps its proportions at any line weight. '
        . 'Built-in patterns have no editable numbers.')

    ctl['dashpv'] := g.Add('Picture', 'x176 y232 w280 h44 Border')

    ctl['dashnew'] := g.Add('Button', 'x176 y284 w64 h26', 'New')
    ctl['dashcpy'] := g.Add('Button', 'x244 y284 w64 h26', 'Copy')
    ctl['dashsav'] := g.Add('Button', 'x312 y284 w64 h26', 'Save')
    ctl['dashdel'] := g.Add('Button', 'x380 y284 w76 h26', 'Delete')
    ctl['dashnew'].OnEvent('Click', (*) => MarkupEd_NewDash())
    ctl['dashcpy'].OnEvent('Click', (*) => MarkupEd_CopyDash())
    ctl['dashsav'].OnEvent('Click', (*) => MarkupEd_SaveDash())
    ctl['dashdel'].OnEvent('Click', (*) => MarkupEd_DeleteDash())

    tabs.UseTab()
    ctl['reload'] := g.Add('Button', 'x8   y348 w140 h26', 'Reload from INI')
    ctl['close']  := g.Add('Button', 'x392 y348 w80  h26', 'Close')
    ctl['reload'].OnEvent('Click', (*) => (MarkupReloadStyles(), MarkupEd_Fill()))
    ctl['close'].OnEvent('Click',  (*) => MarkupEd_Close())
    g.OnEvent('Close', (*) => MarkupEd_Close())

    MarkupEd.Gui := g
    MarkupEd_Fill()
    g.Show()
}

MarkupEd_Close() {
    if MarkupEd.Gui
        MarkupEd.Gui.Hide()
}

; Refill both lists from the registries, keeping the current selections if the
; names survived the reload.
MarkupEd_Fill() {
    if !MarkupEd.Gui
        return
    ctl := MarkupEd.Ctl
    capWas  := MarkupEd_Selected('caplist',  MarkupEd.CapIds)
    dashWas := MarkupEd_Selected('dashlist', MarkupEd.DashIds)

    names := [], MarkupEd.CapIds := []
    for id in MarkupStyles.CapOrder {
        d := MarkupStyles.Caps[id]
        names.Push(d.Name (d.Builtin ? '' : '  •'))
        MarkupEd.CapIds.Push(id)
    }
    ctl['caplist'].Delete(), ctl['caplist'].Add(names)

    names := [], MarkupEd.DashIds := []
    for id in MarkupStyles.DashOrder {
        d := MarkupStyles.Dashes[id]
        names.Push(d.Name (d.Builtin ? '' : '  •'))
        MarkupEd.DashIds.Push(id)
    }
    ctl['dashlist'].Delete(), ctl['dashlist'].Add(names)

    MarkupEd_Reselect('caplist',  MarkupEd.CapIds,  capWas  != '' ? capWas  : 'arrow')
    MarkupEd_Reselect('dashlist', MarkupEd.DashIds, dashWas != '' ? dashWas : 'dash')
    MarkupEd_LoadCap()
    MarkupEd_LoadDash()
}

MarkupEd_Selected(listName, ids) {
    v := 0
    try v := MarkupEd.Ctl[listName].Value
    return (v >= 1 && v <= ids.Length) ? ids[v] : ''
}

MarkupEd_Reselect(listName, ids, wantId) {
    for i, id in ids
        if (id = wantId) {
            try MarkupEd.Ctl[listName].Value := i
            return
        }
    try MarkupEd.Ctl[listName].Value := ids.Length ? 1 : 0
}

; ── Arrowhead tab ────────────────────────────────────────────────────────────

MarkupEd_LoadCap(*) {
    ctl := MarkupEd.Ctl
    id  := MarkupEd_Selected('caplist', MarkupEd.CapIds)
    if (id = '') {
        MarkupEd_CapChanged()
        return
    }
    d := MarkupStyles.Caps[id]
    ctl['capname'].Value   := d.Name
    ctl['capkind'].Text    := (d.Kind = 'none') ? 'poly' : d.Kind
    ctl['capfill'].Text    := d.Fill ? 'fill' : (d.Close ? 'open' : 'line')
    ctl['capshrink'].Value := MarkupNumText(d.Shrink)
    if (d.Kind = 'circle') {
        ctl['cappts'].Value := MarkupNumText(d.CX) ', ' MarkupNumText(d.R)
    } else {
        txt := '', i := 1
        while (i <= d.Pts.Length) {
            txt .= (txt = '' ? '' : '   ') MarkupNumText(d.Pts[i]) ',' MarkupNumText(d.Pts[i + 1])
            i += 2
        }
        ctl['cappts'].Value := txt
    }
    MarkupEd_CapChanged()
}

; Live: retitle the points box for the current shape and redraw the preview from
; whatever is typed, valid or not — an invalid definition simply draws nothing,
; which is a clearer signal than a message box on every keystroke would be.
MarkupEd_CapChanged(*) {
    ctl := MarkupEd.Ctl
    isCircle := (ctl['capkind'].Text = 'circle')
    ctl['caphint'].Value := isCircle
        ? 'Centre, radius  —  both in head-lengths back from the tip'
        : 'Points as  x,y  pairs  —  tip is 0,0 and +x runs back along the shaft'
    ctl['cappv'].Value := ''
    if !(def := MarkupEd_BuildCap(&err))
        return
    ; Register under a scratch name so the preview can draw it without touching
    ; the real registry entry the user may still be editing away from.
    def := def.Clone()
    def.Name := '_preview'
    MarkupDefCap(def)
    o := MarkupNewObj('line')
    o.Color := MarkupCfg.Color, o.Thick := 4, o.Outline := false, o.Shadow := false
    o.Dash  := 'solid', o.CapStart := 'none', o.CapEnd := '_preview'
    o.X1 := 30, o.Y1 := 22, o.X2 := 240, o.Y2 := 22
    MarkupRenderStrip(ctl['cappv'], o, 276, 40, 'edcap')
}

; Build a definition from the fields, or return 0 with err set.  Validation is
; done by handing the composed INI line to the very parser that reads the file,
; so anything this accepts is guaranteed to load again next time.
MarkupEd_BuildCap(&err) {
    ctl  := MarkupEd.Ctl
    err  := ''
    name := Trim(ctl['capname'].Value)
    if !RegExMatch(name, '^[\w][\w \-]{0,23}$') {
        err := 'Name must be 1-24 characters: letters, digits, spaces, - or _.'
        return 0
    }
    ; The points box is deliberately forgiving about separators — "0,0  1,-0.45"
    ; and "0 0 1 -0.45" and one number per line all normalise to the same thing.
    body := RegExReplace(Trim(ctl['cappts'].Value), '[\s,]+', ',')
    body := Trim(body, ',')
    spec := ctl['capkind'].Text ', ' ctl['capfill'].Text ', '
          . Trim(ctl['capshrink'].Value) ', ' body
    ; Validate by parsing into a scratch slot, so nothing is committed until
    ; Save and the check is literally the loader's own.
    if !MarkupParseCapLine('_probe=' spec) {
        err := 'That definition is not valid.  Check the numbers: '
             . (ctl['capkind'].Text = 'circle'
                ? 'a circle needs a centre and a radius.'
                : 'a polygon needs at least two x,y pairs.')
        return 0
    }
    def := MarkupStyles.Caps['_probe'].Clone()
    def.Name := name
    def.Id   := StrLower(name)
    def.Builtin := false
    return def
}

MarkupEd_SaveCap() {
    if !(def := MarkupEd_BuildCap(&err)) {
        MsgBox(err, 'Markup Line Styles', 'Icon!')
        return
    }
    MarkupDefCap(def)
    try {
        IniWrite(MarkupCapToIni(def), MarkupIniPath(), 'MarkupCaps', def.Name)
    } catch as e {
        MsgBox('Saved for this session, but the INI could not be written:`n`n'
             . e.Message, 'Markup Line Styles', 'Icon!')
    }
    MarkupReloadStyles()
    MarkupEd_Fill()
    MarkupEd_Reselect('caplist', MarkupEd.CapIds, StrLower(def.Name))
    MarkupEd_LoadCap()
}

MarkupEd_NewCap() {
    ctl := MarkupEd.Ctl
    ctl['capname'].Value   := 'MyHead'
    ctl['capkind'].Text    := 'poly'
    ctl['capfill'].Text    := 'fill'
    ctl['capshrink'].Value := '0.85'
    ctl['cappts'].Value    := '0,0   1,-0.45   1,0.45'
    MarkupEd_CapChanged()
}

MarkupEd_CopyCap() {
    ctl  := MarkupEd.Ctl
    base := Trim(ctl['capname'].Value)
    ctl['capname'].Value := SubStr(base ' copy', 1, 24)
    MarkupEd_CapChanged()
}

MarkupEd_DeleteCap() {
    id := MarkupEd_Selected('caplist', MarkupEd.CapIds)
    if (id = '')
        return
    d := MarkupStyles.Caps[id]
    if (d.Id = 'none') {
        MsgBox('"none" is what an object falls back to, so it cannot be removed.'
             , 'Markup Line Styles', 'Icon!')
        return
    }
    msg := d.Builtin
        ? 'Remove any custom override of "' d.Name '" and restore the built-in?'
        : 'Delete the arrowhead "' d.Name '"?`n`nObjects still using it will '
        . 'fall back to no end treatment.'
    if (MsgBox(msg, 'Markup Line Styles', 'YesNo Icon?') != 'Yes')
        return
    try IniDelete(MarkupIniPath(), 'MarkupCaps', d.Name)
    catch {
        ; No INI entry to remove — a pure built-in.  Reloading restores it.
    }
    MarkupReloadStyles()
    MarkupEd_Fill()
}

; ── Dash tab ─────────────────────────────────────────────────────────────────

MarkupEd_LoadDash(*) {
    ctl := MarkupEd.Ctl
    id  := MarkupEd_Selected('dashlist', MarkupEd.DashIds)
    if (id = '') {
        MarkupEd_DashChanged()
        return
    }
    d := MarkupStyles.Dashes[id]
    ctl['dashname'].Value := d.Name
    ctl['dashpat'].Value  := d.Arr.Length ? MarkupDashToIni(d) : ''
    MarkupEd_DashChanged()
}

MarkupEd_DashChanged(*) {
    ctl := MarkupEd.Ctl
    ctl['dashpv'].Value := ''
    pat := Trim(ctl['dashpat'].Value)
    id  := MarkupEd_Selected('dashlist', MarkupEd.DashIds)
    if (pat = '') {
        ; A built-in with no numbers of its own — preview the real thing.
        if (id = '')
            return
        prev := id
    } else {
        if !MarkupParseDashLine('_preview=' pat)
            return
        prev := '_preview'
    }
    o := MarkupNewObj('line')
    o.Color := MarkupCfg.Color, o.Thick := 4, o.Outline := false, o.Shadow := false
    o.Dash  := prev, o.CapStart := 'none', o.CapEnd := 'none'
    o.X1 := 18, o.Y1 := 22, o.X2 := 258, o.Y2 := 22
    MarkupRenderStrip(ctl['dashpv'], o, 276, 40, 'eddash')
}

MarkupEd_SaveDash() {
    ctl  := MarkupEd.Ctl
    name := Trim(ctl['dashname'].Value)
    if !RegExMatch(name, '^[\w][\w \-]{0,23}$') {
        MsgBox('Name must be 1-24 characters: letters, digits, spaces, - or _.'
             , 'Markup Line Styles', 'Icon!')
        return
    }
    pat := Trim(ctl['dashpat'].Value)
    if !MarkupParseDashLine(name '=' pat) {
        MsgBox('A pattern needs at least two positive numbers, alternating on '
             . 'and off — for example  6, 3  or  5, 2, 1, 2.'
             , 'Markup Line Styles', 'Icon!')
        return
    }
    try {
        IniWrite(pat, MarkupIniPath(), 'MarkupDashes', name)
    } catch as e {
        MsgBox('Saved for this session, but the INI could not be written:`n`n'
             . e.Message, 'Markup Line Styles', 'Icon!')
    }
    MarkupReloadStyles()
    MarkupEd_Fill()
    MarkupEd_Reselect('dashlist', MarkupEd.DashIds, StrLower(name))
    MarkupEd_LoadDash()
}

MarkupEd_NewDash() {
    MarkupEd.Ctl['dashname'].Value := 'MyDash'
    MarkupEd.Ctl['dashpat'].Value  := '6, 3'
    MarkupEd_DashChanged()
}

MarkupEd_CopyDash() {
    ctl  := MarkupEd.Ctl
    base := Trim(ctl['dashname'].Value)
    ctl['dashname'].Value := SubStr(base ' copy', 1, 24)
    if (Trim(ctl['dashpat'].Value) = '')
        ctl['dashpat'].Value := '6, 3'
    MarkupEd_DashChanged()
}

MarkupEd_DeleteDash() {
    id := MarkupEd_Selected('dashlist', MarkupEd.DashIds)
    if (id = '')
        return
    d := MarkupStyles.Dashes[id]
    if (d.Id = 'solid') {
        MsgBox('"solid" is what an object falls back to, so it cannot be removed.'
             , 'Markup Line Styles', 'Icon!')
        return
    }
    msg := d.Builtin
        ? 'Remove any custom override of "' d.Name '" and restore the built-in?'
        : 'Delete the dash pattern "' d.Name '"?`n`nObjects still using it will '
        . 'fall back to solid.'
    if (MsgBox(msg, 'Markup Line Styles', 'YesNo Icon?') != 'Yes')
        return
    try IniDelete(MarkupIniPath(), 'MarkupDashes', d.Name)
    catch {
        ; No INI entry — a pure built-in, restored by the reload below.
    }
    MarkupReloadStyles()
    MarkupEd_Fill()
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
; The pallet is WS_EX_NOACTIVATE, so clicking its buttons does not take the
; snip out of focus and these stay live throughout.

#HotIf WinActive('SnipperWindow ahk_class AutoHotkeyGUI') && !MarkupActive()
m::         MarkupBegin() ; hide
; F3 needs a binding in BOTH contexts.  With only the MarkupActive() one it did
; nothing at all until a session had been started some other way — which looked
; like "F3 doesn't work until you open the pallet from the menu once".  Out
; here it starts markup (which shows the pallet); inside markup it toggles.
F3::        MarkupPalletMenuItem(WinGetID('A')) ; hide
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
d::         MarkupSetTool('path') ; hide     ; D for dogleg — P is taken by Pen
p::         MarkupSetTool('pen') ; hide
h::         MarkupSetTool('highlight') ; hide
t::         MarkupSetTool('text') ; hide
n::         MarkupSetTool('number') ; hide
c::         MarkupSetTool('callout') ; hide
b::         MarkupSetTool('blur') ; hide
m::         MarkupEnd() ; hide
F2::        MarkupEditSelText() ; hide
F3::        MarkupTogglePallet() ; hide
Delete::    MarkupDeleteSel() ; hide
^a::        MarkupSelectAll() ; hide
^z::        MarkupUndo() ; hide
^y::        MarkupRedo() ; hide
^+z::       MarkupRedo() ; hide
^d::        MarkupDuplicateSel(MarkupState.Active) ; hide
^v::        MarkupPasteImage() ; hide
^PgUp::     MarkupRaiseSel(MarkupState.Active, true) ; hide
^PgDn::     MarkupRaiseSel(MarkupState.Active, false) ; hide
; Line style, without going near the pallet.  Bracket keys step the two ends,
; backslash steps the dash; Shift reverses.  All three act on the selection when
; there is one and on the current tool's default when there isn't, which is the
; same rule every other style control follows.
[::         MarkupCycleStyle('CapStart',  1) ; hide
+[::        MarkupCycleStyle('CapStart', -1) ; hide
]::         MarkupCycleStyle('CapEnd',    1) ; hide
+]::        MarkupCycleStyle('CapEnd',   -1) ; hide
\::         MarkupCycleStyle('Dash',      1) ; hide
+\::        MarkupCycleStyle('Dash',     -1) ; hide
^\::        MarkupSwapEnds() ; hide
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
