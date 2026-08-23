#Requires AutoHotkey v2
; ==============================================================================
;
;                             SnipJigsaw.ahk
;              A real jigsaw puzzle cut from any ScreenSnip
;                        Version Date: 8-22-2026 
;
; An optional add-on module for ScreenSnip.ahk.  Lives in  Resources\  and is
; pulled in by the  #Include *i  block at the bottom of ScreenSnip.ahk, on the
; same opt-out contract as SnipOCR / SnipAI / SnipImgur / SnipPuzzle:
;
;   - The JigCfg class is the presence sentinel, tested with IsSet().
;   - Delete this file (or comment out its #Include) and ScreenSnip runs exactly
;     as before, minus the "Jigsaw Puzzle" item on the snip context menu.
;   - No top-level executable code — all state lives in class statics, because
;     the #Include sits past the end of the auto-execute section.
;
; Standalone on purpose.  SnipPuzzle.ahk (slide + swap) shares the idea and a
; few leaf helpers with this file, but nothing else: those two are permutations
; of a grid, this one is free-floating shapes.  Rather than factor the common
; GDI+ plumbing into a third file that both would depend on — which would break
; the "any module is independently deletable" contract — this file carries its
; own Jig-prefixed copies.  Sixty duplicated lines is the cheaper trade.
;
; ── How the pieces are made ───────────────────────────────────────────────────
; The trick to interlocking pieces is to generate the EDGES, not the pieces.
;
; Two tables are built up front: horizontal edges (Rows+1 by Cols) and vertical
; edges (Rows by Cols+1).  Border edges are straight; every interior edge gets a
; random tab direction plus jitter on the knob's position and size.  A piece is
; then assembled from four edges it LOOKS UP rather than invents — its bottom
; edge is literally the same table entry as the piece below's top edge, walked
; backwards.  Interlock is structural: a tab and its socket cannot disagree,
; because they are the same curve.
;
; Each edge is six cubic Beziers over a normalised span, mapped onto the real
; edge with an along/perpendicular basis, so the same recipe serves horizontal
; and vertical edges and either tab direction.
;
; Pieces are rendered once into their own ARGB bitmaps (clip to path, draw the
; source, stroke the outline) and after that the game is pure alpha blitting.
; The paths are thrown away once the bitmap exists: hit-testing reads the
; bitmap's alpha channel instead, which is simpler AND exact, since it accounts
; for the outline stroke too.
;
; ── How snapping works ────────────────────────────────────────────────────────
; Every piece knows its home position in the assembled picture.  Define a
; piece's TRANSLATION as (current position - home position).  Two pieces are
; correctly placed relative to each other exactly when their translations match,
; whatever their absolute position on the canvas.
;
; So the snap test is: are these two pieces neighbours in the grid, and are
; their translations within tolerance on both axes?  No per-edge geometry, no
; rotation to consider.  Joining a group means translating it so its members'
; translations equal the target group's, then relabelling.  Solved is "every
; piece in one group" — the assembly can be sitting anywhere.
;
; ── Settings ──────────────────────────────────────────────────────────────────
; Read once at load through ScreenSnip's SnipCfg(), so they live in
; Data\snipSettings.ini and need a restart to take effect.  The literal in each
; call is the fallback, which is what makes the whole [Jigsaw] section optional.
;
;   [Jigsaw]                 type     default   what it does
;   PieceCount               int      48        default pieces (12-300)
;   MaxBoardSize             int      520       longest side of the picture, px
;   MinBoardSize             int      280       small snips scale UP to this
;   CanvasScale              int      180       canvas as a % of the picture (110-280)
;   SnapPixels               int      0         0 = auto (a sixth of a piece)
;   KnobDepth                int      22        tab height as a % of a piece
;   PieceOutline             bool     1         hairline edge on each piece
;   ShowBoardOutline         bool     1         faint frame where it assembles
;   FeltColor                hex      141A20    the table the pieces lie on
;   SoundOnSnap              bool     1         click when pieces join
;   SoundOnSolve             bool     1         fanfare on completion
;   AlwaysOnTop              bool     1         window floats
;   CloseSnipOnStart         bool     0         1 = the snip becomes the puzzle
;
; ── Wiring into ScreenSnip.ahk (two small edits) ──────────────────────────────
; 1. In the "Context menu for snip windows" block, with the other puzzle items:
;
;        if IsSet(JigCfg) {
;            jigsawMenuBuilder := 'JigBuildMenu'
;            SnipMenu.Add('Jigsaw Puzzle', %jigsawMenuBuilder%())
;        }
;
; 2. At the bottom, with the other optional modules:
;
;        #Include *i Resources\SnipJigsaw.ahk
;
; Adapted by kunkel321 / Claude
; Version date: 8-22-2026
; ==============================================================================

; ══════════════════════════════════════════════════════════════════════════════
; CONFIG + STATE
; ══════════════════════════════════════════════════════════════════════════════

class JigCfg {
    static Pieces     := SnipCfg('Jigsaw', 'PieceCount',       48)
    static MaxBoard   := SnipCfg('Jigsaw', 'MaxBoardSize',    520)
    static MinBoard   := SnipCfg('Jigsaw', 'MinBoardSize',    280)
    static Canvas     := SnipCfg('Jigsaw', 'CanvasScale',     180)
    static Snap       := SnipCfg('Jigsaw', 'SnapPixels',        0)
    static Knob       := SnipCfg('Jigsaw', 'KnobDepth',        22)
    static Outline    := SnipCfg('Jigsaw', 'PieceOutline',      1)
    static Frame      := SnipCfg('Jigsaw', 'ShowBoardOutline',  1)
    static Felt       := SnipCfgHex('Jigsaw', 'FeltColor', 0x141A20)
    static SnapSound  := SnipCfg('Jigsaw', 'SoundOnSnap',       1)
    static WinSound   := SnipCfg('Jigsaw', 'SoundOnSolve',      1)
    static OnTop      := SnipCfg('Jigsaw', 'AlwaysOnTop',       1)
    static CloseSnip  := SnipCfg('Jigsaw', 'CloseSnipOnStart',  0)
}

class JigState {
    static Games  := Map()      ; gui hwnd     -> game object
    static Pics   := Map()      ; picture hwnd -> gui hwnd
    static Hooked := false
}

; ══════════════════════════════════════════════════════════════════════════════
; MENU
; ══════════════════════════════════════════════════════════════════════════════

; Piece counts rather than grid dimensions, because that is how jigsaws are
; sold and because the actual grid depends on the snip's aspect ratio — 48
; pieces is 8x6 on a landscape snip and 6x8 on a portrait one.
JigBuildMenu() {
    m := Menu()
    m.Add('Play  (' JigCfg.Pieces ' pieces)', JigSnipMenu_Handler)
    m.Add()
    m.Add('12 pieces   very easy', JigSnipMenu_Handler)
    m.Add('24 pieces   easy',      JigSnipMenu_Handler)
    m.Add('48 pieces',             JigSnipMenu_Handler)
    m.Add('96 pieces   hard',      JigSnipMenu_Handler)
    m.Add('150 pieces   brutal',   JigSnipMenu_Handler)
    m.Add()
    m.Add('Custom Count…',         JigSnipMenu_Handler)
    return m
}

JigSnipMenu_Handler(ItemName, *) {
    global SnipMenu
    hwnd := SnipMenu._targetHwnd
    base := StrSplit(ItemName, "`t")[1]

    if InStr(base, 'Custom') {
        if !JigAskCount(JigCfg.Pieces, &n, JigSnipGui(hwnd))
            return
        JigPlay(hwnd, n)
        return
    }
    if RegExMatch(base, '(\d+)', &m)
        JigPlay(hwnd, Integer(m[1]))
    else
        JigPlay(hwnd, JigCfg.Pieces)
}

; Labels shared between Add and Check/Enable.  Menu methods match on the WHOLE
; label including the tab and its accelerator, so 'Peek' would not find an item
; added as 'Peek at Picture`tSpace'.
JigLbl(key) {
    static L := Map(
        'shuffle', 'New Puzzle`tR'
      , 'scatter', 'Scatter Loose Pieces`tS'
      , 'peek',    'Peek at Picture`tSpace'
      , 'frame',   'Show Assembly Frame`tF'
      , 'help',    'Help`tF1'
      , 'close',   'Close`tEsc')
    return L[key]
}

JigMenuObj() {
    static m := ''
    if IsObject(m)
        return m

    counts := Menu()
    counts.Add('12 pieces',  JigCtxMenu_Handler)
    counts.Add('24 pieces',  JigCtxMenu_Handler)
    counts.Add('48 pieces',  JigCtxMenu_Handler)
    counts.Add('96 pieces',  JigCtxMenu_Handler)
    counts.Add('150 pieces', JigCtxMenu_Handler)
    counts.Add()
    counts.Add('Custom…',    JigCtxMenu_Handler)

    m := Menu()
    m.Add(JigLbl('shuffle'), JigCtxMenu_Handler)
    m.Add(JigLbl('scatter'), JigCtxMenu_Handler)
    m.Add(JigLbl('peek'),    JigCtxMenu_Handler)   ; checkable
    m.Add(JigLbl('frame'),   JigCtxMenu_Handler)   ; checkable
    m.Add('Piece Count', counts)
    m.Add()
    m.Add(JigLbl('help'),    JigCtxMenu_Handler)
    m.Add(JigLbl('close'),   JigCtxMenu_Handler)
    return m
}

JigCtxMenu_Handler(ItemName, *) {
    m := JigMenuObj()
    if !JigState.Games.Has(m._target)
        return
    J    := JigState.Games[m._target]
    base := StrSplit(ItemName, "`t")[1]

    switch base {
        case 'New Puzzle':           JigNewGame(J)
        case 'Scatter Loose Pieces': JigScatterLoose(J)
        case 'Peek at Picture':      JigTogglePeek(J)
        case 'Show Assembly Frame':  JigToggleFrame(J)
        case 'Help':                 JigShowHelp(J)
        case 'Close':                JigConfirmClose(J)
        case '12 pieces':            JigRebuild(J, 12)
        case '24 pieces':            JigRebuild(J, 24)
        case '48 pieces':            JigRebuild(J, 48)
        case '96 pieces':            JigRebuild(J, 96)
        case '150 pieces':           JigRebuild(J, 150)
        case 'Custom…':
            if JigAskCount(J.Want, &n, J.Gui)
                JigRebuild(J, n)
    }
}

JigShowMenu(GuiObj, *) {
    if !JigState.Games.Has(GuiObj.Hwnd)
        return
    J := JigState.Games[GuiObj.Hwnd]
    m := JigMenuObj()
    m._target := GuiObj.Hwnd

    if (J.PeekLock || J.Peeking)
        m.Check(JigLbl('peek'))
    else
        m.UnCheck(JigLbl('peek'))

    if J.Frame
        m.Check(JigLbl('frame'))
    else
        m.UnCheck(JigLbl('frame'))

    m.Show()
}

; Own the dialog, or it opens BEHIND the snip.
;
; +OwnDialogs is per-THREAD, not per-Gui: setting it in the Gui() options only
; affects the thread that created the window.  A menu handler is a new thread,
; so it has to be asked for again here — otherwise the InputBox is unowned,
; and an unowned dialog loses to the snip's +AlwaysOnTop and hides behind it.
JigAskCount(def, &count, owner := 0) {
    if IsObject(owner) {
        try owner.Opt('+OwnDialogs')
    }
    ; No apostrophe in this text on purpose.  It sits in a single-quoted string,
    ; and v2 does not treat '' as an escaped quote the way some languages do —
    ; it ends the string and leaves the rest of the line dangling.  A backtick
    ; would escape it, but rewording is less of a trap for the next edit.
    ib := InputBox('How many pieces?'
                 . '`n`n12 to 300.  The exact count is rounded to fit the'
                 . '`nshape of the snip.'
                 , 'Snip Jigsaw', 'w320 h150', def)
    if (ib.Result != 'OK')
        return false
    if !RegExMatch(ib.Value, '^\s*(\d+)\s*$', &m) {
        MsgBox('Could not read "' ib.Value '" as a piece count.', 'Snip Jigsaw', 4096)
        return false
    }
    count := Max(12, Min(300, Integer(m[1])))
    return true
}

; ══════════════════════════════════════════════════════════════════════════════
; CREATING A GAME
; ══════════════════════════════════════════════════════════════════════════════

; The Gui object behind a snip window, for use as a dialog owner.  Returns 0
; when the snip has gone, which the callers treat as "no owner".
JigSnipGui(snipHwnd) {
    global guiSnips
    if !guiSnips.Has(snipHwnd)
        return 0
    try return guiSnips[snipHwnd].GuiObj
    return 0
}

JigPlay(snipHwnd, want := 0) {
    global guiSnips
    if !guiSnips.Has(snipHwnd)
        return
    snip := guiSnips[snipHwnd]

    want := Max(12, Min(300, want ? want : JigCfg.Pieces))

    orig := BuildDisplayBitmap(snip)      ; caller owns and must dispose
    if !orig {
        if (og := JigSnipGui(snipHwnd)) {
            try og.Opt('+OwnDialogs')
        }
        MsgBox('Could not read the snip image.', 'Snip Jigsaw', 4096)
        return
    }

    x := y := ''
    if WinExist('ahk_id ' snipHwnd) {
        WinGetPos(&sx, &sy, , , 'ahk_id ' snipHwnd)
        x := sx + 24, y := sy + 24
    }

    if JigCfg.CloseSnip
        CloseSnip(snipHwnd)

    JigCreate(orig, want, x, y)
}

; TAKES OWNERSHIP of pOrig — disposed with the game, and every derived bitmap is
; rebuilt from it, which is what lets the piece count change mid-game.
JigCreate(pOrig, want, x := '', y := '') {
    JigHookOnce()

    DllCall('gdiplus\GdipGetImageWidth',  'Ptr', pOrig, 'UInt*', &sw := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'Ptr', pOrig, 'UInt*', &sh := 0)
    if (sw < 1 || sh < 1) {
        GDIp.DisposeImage(pOrig)
        return
    }

    ; ── Grid ──────────────────────────────────────────────────────────────────
    ; Turn a piece COUNT into a grid that respects the snip's shape, so pieces
    ; come out roughly square instead of long slivers on a wide screenshot.
    aspect := sw / sh
    cols := Max(2, Round(Sqrt(want * aspect)))
    rows := Max(2, Round(want / cols))

    ; ── Board geometry ────────────────────────────────────────────────────────
    longest := Max(sw, sh)
    scale   := 1.0
    if (longest > JigCfg.MaxBoard)
        scale := JigCfg.MaxBoard / longest
    else if (longest < JigCfg.MinBoard)
        scale := JigCfg.MinBoard / longest

    ; Canvas: the table the pieces lie on.  The margin around the picture is
    ; where loose pieces live while you work, so it wants to be generous — at
    ; 180% the gutter is 40% of the picture's width on each side.
    cscale := Max(110, Min(280, JigCfg.Canvas)) / 100.0

    ; ...but a generous gutter on a large snip can push the window off-screen,
    ; and there is no way to shrink it once it is up.  Work out what the canvas
    ; WOULD be, and if it doesn't fit the work area, scale the picture down
    ; until it does.  The gutter keeps its proportion either way.
    MonitorGetWorkArea( , &wkL, &wkT, &wkR, &wkB)
    availW := (wkR - wkL) - 80
    availH := (wkB - wkT) - 170        ; title bar, margins and the button row
    prelimW := sw * scale * cscale
    prelimH := sh * scale * cscale
    if (prelimW > availW || prelimH > availH)
        scale *= Min(availW / Max(1, prelimW), availH / Max(1, prelimH))

    tileW := Max(24, Floor(sw * scale / cols))
    tileH := Max(24, Floor(sh * scale / rows))
    boardW := tileW * cols
    boardH := tileH * rows

    canvasW := Round(boardW * cscale)
    canvasH := Round(boardH * cscale)
    boardX  := (canvasW - boardW) // 2
    boardY  := (canvasH - boardH) // 2

    pImg := JigNewBitmap(boardW, boardH)
    if !pImg {
        GDIp.DisposeImage(pOrig)
        return
    }
    gImg := JigNewGfx(pImg)
    JigDrawPart(gImg, pOrig, 0, 0, boardW, boardH, 0, 0, sw, sh)
    DllCall('gdiplus\GdipDeleteGraphics', 'Ptr', gImg)

    pBack := JigNewBitmap(canvasW, canvasH)
    gBack := JigNewGfx(pBack)
    DllCall('gdiplus\GdipBitmapSetResolution', 'Ptr', pBack
          , 'Float', A_ScreenDPI + 0.0, 'Float', A_ScreenDPI + 0.0)

    ; ── Window ────────────────────────────────────────────────────────────────
    opts := '-MaximizeBox +OwnDialogs' (JigCfg.OnTop ? ' +AlwaysOnTop' : '')
    g := Gui(opts, 'Snip Jigsaw   ' (cols * rows) ' pieces')
    g.MarginX := 10, g.MarginY := 10

    DllCall('gdiplus\GdipGraphicsClear', 'Ptr', gBack, 'UInt', 0xFF000000 | JigCfg.Felt)
    hbm0 := GDIp.CreateHBITMAPFromBitmap(pBack)
    if !hbm0 {
        DllCall('gdiplus\GdipDeleteGraphics', 'Ptr', gBack)
        GDIp.DisposeImage(pBack), GDIp.DisposeImage(pImg), GDIp.DisposeImage(pOrig)
        MsgBox('Could not build the jigsaw canvas.', 'Snip Jigsaw', 4096)
        return
    }

    pic := g.Add('Picture', 'xm ym +0x100', 'HBITMAP:' hbm0)

    stats := g.Add('Text', 'xm y+8 w240 h22 +0x200', '')
    bNew  := g.Add('Button', 'x+6 yp-2 w62 h26', 'New')
    bScat := g.Add('Button', 'x+6 yp w70 h26', 'Scatter')
    bPeek := g.Add('Button', 'x+6 yp w52 h26', 'Peek')
    bHelp := g.Add('Button', 'x+6 yp w26 h26', '?')

    J := { Gui: g, Hwnd: g.Hwnd, Pic: pic, Stats: stats, PeekBtn: bPeek
         , Want: want, Cols: cols, Rows: rows, TileW: tileW, TileH: tileH
         , BoardW: boardW, BoardH: boardH, BoardX: boardX, BoardY: boardY
         , CanvasW: canvasW, CanvasH: canvasH
         , ClientW: canvasW, ClientH: canvasH
         , Over: 0, Snap: 0
         , Orig: pOrig, Img: pImg, Back: pBack, Gfx: gBack
         , HEdge: 0, VEdge: 0, Pieces: [], Z: []
         , Groups: 0, StartTick: 0, Elapsed: 0
         , Solved: false, Busy: false, Peeking: false, PeekLock: false
         , Frame: JigCfg.Frame ? true : false
         , Ticker: 0 }

    ; Tab overhang.  A knob on a vertical edge sticks out by a fraction of the
    ; edge's OWN length, so on a non-square piece the two axes differ; take the
    ; larger for a square margin and keep the arithmetic simple.
    J.Over := Ceil(JigCfg.Knob / 100.0 * Max(tileW, tileH)) + 3
    J.Snap := (JigCfg.Snap > 0) ? JigCfg.Snap : Max(10, Min(tileW, tileH) // 6)

    bNew.OnEvent('Click',  (*) => JigNewGame(J))
    bScat.OnEvent('Click', (*) => JigScatterLoose(J))
    bPeek.OnEvent('Click', (*) => JigTogglePeek(J))
    bHelp.OnEvent('Click', (*) => JigShowHelp(J))
    g.OnEvent('Close',       (*) => JigConfirmClose(J))
    g.OnEvent('Escape',      (*) => JigConfirmClose(J))
    g.OnEvent('ContextMenu', JigShowMenu)

    JigState.Games[g.Hwnd]  := J
    JigState.Pics[pic.Hwnd] := g.Hwnd

    JigNewGame(J, false)

    if (IsNumber(x) && IsNumber(y))
        g.Show('x' x ' y' y)
    else
        g.Show()
    JigRender(J)

    rc := Buffer(16, 0)
    DllCall('GetClientRect', 'Ptr', pic.Hwnd, 'Ptr', rc)
    J.ClientW := Max(1, NumGet(rc,  8, 'Int'))
    J.ClientH := Max(1, NumGet(rc, 12, 'Int'))

    J.Ticker := JigTick.Bind(g.Hwnd)
    SetTimer(J.Ticker, 500)
}

JigHookOnce() {
    if JigState.Hooked
        return
    JigState.Hooked := true
    OnMessage(0x0201, JigWM_LBUTTONDOWN)
    OnExit(JigCleanupOnExit)
}

JigCleanupOnExit(*) {
    for hwnd, J in JigState.Games.Clone()
        try JigDestroy(J)
}

; ══════════════════════════════════════════════════════════════════════════════
; EDGES AND PIECES
; ══════════════════════════════════════════════════════════════════════════════

; Build both edge tables.  H edges run left-to-right, V edges top-to-bottom;
; that canonical direction matters, because a piece walking its bottom or left
; edge reads the SAME entry backwards, which is what makes tab and socket agree.
JigBuildEdges(J) {
    k := Max(8, Min(40, JigCfg.Knob)) / 100.0

    J.HEdge := []
    Loop J.Rows + 1 {
        r := A_Index
        row := []
        Loop J.Cols {
            c  := A_Index
            ax := (c - 1) * J.TileW
            ay := (r - 1) * J.TileH
            row.Push(JigMakeEdge(ax, ay, c * J.TileW, ay, (r = 1 || r = J.Rows + 1), k))
        }
        J.HEdge.Push(row)
    }

    J.VEdge := []
    Loop J.Rows {
        r := A_Index
        row := []
        Loop J.Cols + 1 {
            c  := A_Index
            ax := (c - 1) * J.TileW
            ay := (r - 1) * J.TileH
            row.Push(JigMakeEdge(ax, ay, ax, r * J.TileH, (c = 1 || c = J.Cols + 1), k))
        }
        J.VEdge.Push(row)
    }
}

; One edge as an array of cubic segments, each [x1,y1, c1x,c1y, c2x,c2y, x2,y2]
; in board coordinates.
;
; The knob is described once in normalised (along, perpendicular) space and then
; mapped onto the real edge, so the same nineteen numbers serve horizontal and
; vertical edges and either tab direction.  `d` flips the tab, `o` slides it
; along, `s` resizes it — without that jitter every piece looks identical and
; the puzzle stops being solvable by shape.
JigMakeEdge(ax, ay, bx, by, straight, k) {
    dx  := bx - ax
    dy  := by - ay
    len := Sqrt(dx * dx + dy * dy)
    if (len < 1)
        len := 1
    ux := dx / len
    uy := dy / len
    px := -uy                             ; perpendicular
    py := ux

    segs := []
    if straight {
        segs.Push([ax, ay
                 , ax + dx * 0.333, ay + dy * 0.333
                 , ax + dx * 0.667, ay + dy * 0.667
                 , bx, by])
        return segs
    }

    d  := (Random(0, 1) = 1) ? 1 : -1
    o  := Random(-30, 30) / 1000.0
    kk := k * (1 + Random(-15, 15) / 100.0)

    ; 19 points = 6 cubics.  Flat run in, neck, bulb, neck, flat run out.
    uv := [ [0.00, 0.00], [0.15, 0.00], [0.25, 0.00], [0.35 + o, 0.00]
          , [0.40 + o, 0.13 * kk], [0.42 + o, 0.32 * kk], [0.35 + o, 0.41 * kk]
          , [0.25 + o, 0.59 * kk], [0.28 + o, 1.00 * kk], [0.50 + o, 1.00 * kk]
          , [0.72 + o, 1.00 * kk], [0.75 + o, 0.59 * kk], [0.65 + o, 0.41 * kk]
          , [0.58 + o, 0.32 * kk], [0.60 + o, 0.13 * kk], [0.65 + o, 0.00]
          , [0.75, 0.00], [0.90, 0.00], [1.00, 0.00] ]

    flat := []
    for pt in uv {
        u := pt[1]
        v := pt[2] * d
        flat.Push(ax + ux * len * u + px * len * v)
        flat.Push(ay + uy * len * u + py * len * v)
    }

    Loop 6 {
        b := (A_Index - 1) * 6
        segs.Push([flat[b + 1], flat[b + 2], flat[b + 3], flat[b + 4]
                 , flat[b + 5], flat[b + 6], flat[b + 7], flat[b + 8]])
    }
    return segs
}

; Walk an edge's segments into a path, forwards or backwards.  Reversing a cubic
; is just swapping its endpoints and its two control points.
JigAddEdge(path, segs, reverse) {
    if !reverse {
        for s in segs
            DllCall('gdiplus\GdipAddPathBezier', 'Ptr', path
                  , 'Float', s[1], 'Float', s[2], 'Float', s[3], 'Float', s[4]
                  , 'Float', s[5], 'Float', s[6], 'Float', s[7], 'Float', s[8])
        return
    }
    i := segs.Length
    while (i >= 1) {
        s := segs[i]
        DllCall('gdiplus\GdipAddPathBezier', 'Ptr', path
              , 'Float', s[7], 'Float', s[8], 'Float', s[5], 'Float', s[6]
              , 'Float', s[3], 'Float', s[4], 'Float', s[1], 'Float', s[2])
        i--
    }
}

; Top forwards, right forwards, bottom backwards, left backwards — a clockwise
; circuit that ends where it started.
JigPiecePath(J, r, c) {
    DllCall('gdiplus\GdipCreatePath', 'Int', 0, 'Ptr*', &path := 0)
    if !path
        return 0
    JigAddEdge(path, J.HEdge[r][c],     false)
    JigAddEdge(path, J.VEdge[r][c + 1], false)
    JigAddEdge(path, J.HEdge[r + 1][c], true)
    JigAddEdge(path, J.VEdge[r][c],     true)
    DllCall('gdiplus\GdipClosePathFigure', 'Ptr', path)
    return path
}

; Render every piece into its own bitmap, once.  After this the game never
; touches a path again — dragging is alpha blits and hit-testing reads alpha.
JigBuildPieces(J) {
    JigFreePieces(J)
    over := J.Over
    J.Pieces := []
    J.Z := []

    Loop J.Rows {
        r := A_Index
        Loop J.Cols {
            c  := A_Index
            ox := (c - 1) * J.TileW - over
            oy := (r - 1) * J.TileH - over
            w  := J.TileW + over * 2
            h  := J.TileH + over * 2

            ; Note this piece is pushed even if its bitmap fails to allocate.
            ; JigPieceId() maps (row,col) to an ARRAY INDEX, so skipping one
            ; would silently shift every later piece and break both neighbour
            ; lookups and snapping.
            bmp := JigNewBitmap(w, h)
            gfx := bmp ? JigNewGfx(bmp) : 0
            path := gfx ? JigPiecePath(J, r, c) : 0
            if path {
                ; Shift the world so board coordinates land inside this piece's
                ; bitmap, then clip to the path and draw the whole picture — the
                ; clip keeps only this piece's worth of it.
                DllCall('gdiplus\GdipTranslateWorldTransform', 'Ptr', gfx
                      , 'Float', -ox, 'Float', -oy, 'Int', 0)
                DllCall('gdiplus\GdipSetClipPath', 'Ptr', gfx, 'Ptr', path, 'Int', 0)
                JigDrawPart(gfx, J.Img, 0, 0, J.BoardW, J.BoardH
                                     , 0, 0, J.BoardW, J.BoardH)
                DllCall('gdiplus\GdipResetClip', 'Ptr', gfx)
                ; GDI+ clipping is not antialiased, so the cut edge comes out
                ; jagged.  Stroking the same path over it hides that and gives
                ; the piece definition against its neighbours.
                if JigCfg.Outline {
                    DllCall('gdiplus\GdipCreatePen1', 'UInt', 0x70000000
                          , 'Float', 1.4, 'Int', 2, 'Ptr*', &pen := 0)
                    if pen {
                        DllCall('gdiplus\GdipDrawPath', 'Ptr', gfx, 'Ptr', pen, 'Ptr', path)
                        DllCall('gdiplus\GdipDeletePen', 'Ptr', pen)
                    }
                }
                DllCall('gdiplus\GdipDeletePath', 'Ptr', path)
            }
            if gfx
                DllCall('gdiplus\GdipDeleteGraphics', 'Ptr', gfx)

            id := JigPieceId(J, r, c)
            J.Pieces.Push({ Id: id, Row: r, Col: c, Bmp: bmp
                          , OX: ox, OY: oy, W: w, H: h
                          , X: 0, Y: 0, Grp: id })
            J.Z.Push(id)
        }
    }
}

JigFreePieces(J) {
    for p in J.Pieces
        if p.Bmp
            try GDIp.DisposeImage(p.Bmp)
    J.Pieces := []
    J.Z := []
}

; Where a piece sits when the picture is assembled at its natural spot.
JigHomeX(J, p) => J.BoardX + p.OX
JigHomeY(J, p) => J.BoardY + p.OY

; ══════════════════════════════════════════════════════════════════════════════
; GAME STATE
; ══════════════════════════════════════════════════════════════════════════════

JigNewGame(J, paint := true) {
    if J.Busy
        return
    JigBuildEdges(J)
    JigBuildPieces(J)
    J.Groups    := J.Pieces.Length
    J.StartTick := 0
    J.Elapsed   := 0
    J.Solved    := false
    J.Peeking   := false
    if J.PeekLock {
        J.PeekLock := false
        J.PeekBtn.Text := 'Peek'
    }
    if J.Ticker
        SetTimer(J.Ticker, 500)
    JigScatterAll(J)
    J.Stats.SetFont('norm cDefault')
    JigUpdateStats(J)
    if paint
        JigRender(J)
}

; Deal the pieces onto a jittered lattice covering the canvas.
;
; Purely random positions look right for about ten seconds and then you are
; hunting for a piece buried under three others.  A lattice with jitter keeps
; the scattered look while guaranteeing that almost every piece has an exposed
; edge to grab at the start.
JigScatterAll(J) {
    n := J.Pieces.Length
    if !n
        return
    ; Lattice shaped like the canvas, so slots come out roughly square.
    slotCols := Max(1, Ceil(Sqrt(n * J.CanvasW / Max(1, J.CanvasH))))
    slotRows := Max(1, Ceil(n / slotCols))
    slotW    := J.CanvasW / slotCols
    slotH    := J.CanvasH / slotRows

    slots := []
    Loop slotRows * slotCols
        slots.Push(A_Index)
    ; Fisher-Yates, so which piece lands where is uniform.
    ;
    ; The swap index is NOT called `j`.  AHK variable names are case-insensitive,
    ; so `j := ...` in here would assign straight over this function's own `J`
    ; parameter and turn the game object into an integer partway through.
    i := slots.Length
    while (i > 1) {
        pick := Random(1, i)
        t := slots[i]
        slots[i] := slots[pick]
        slots[pick] := t
        i--
    }

    idx := 0
    for p in J.Pieces {
        idx++
        s  := slots[idx]
        sc := Mod(s - 1, slotCols)
        sr := (s - 1) // slotCols
        cx := (sc + 0.5) * slotW
        cy := (sr + 0.5) * slotH
        jx := Random(-Round(slotW * 0.18), Round(slotW * 0.18))
        jy := Random(-Round(slotH * 0.18), Round(slotH * 0.18))
        p.X := Round(cx - p.W / 2 + jx)
        p.Y := Round(cy - p.H / 2 + jy)
        p.X := Max(-J.Over, Min(J.CanvasW - p.W + J.Over, p.X))
        p.Y := Max(-J.Over, Min(J.CanvasH - p.H + J.Over, p.Y))
        p.Grp := p.Id
    }
    J.Groups := n
}

; Re-scatter only the pieces that are still on their own, leaving assembled
; groups exactly where they are.  This is the "I have buried something" button.
JigScatterLoose(J) {
    if (J.Busy || J.Solved)
        return
    loose := []
    for p in J.Pieces
        if (JigGroupSize(J, p.Grp) = 1)
            loose.Push(p)
    if !loose.Length
        return

    for p in loose {
        p.X := Random(-J.Over, J.CanvasW - p.W + J.Over)
        p.Y := Random(-J.Over, J.CanvasH - p.H + J.Over)
    }
    ; Loose pieces go to the front, so they are not re-buried under the
    ; assembly they were just pulled out from behind.
    for p in loose
        JigRaise(J, p.Id)
    JigRender(J)
}

JigGroupSize(J, grp) {
    n := 0
    for p in J.Pieces
        if (p.Grp = grp)
            n++
    return n
}

JigGroupMembers(J, grp) {
    out := []
    for p in J.Pieces
        if (p.Grp = grp)
            out.Push(p.Id)
    return out
}

JigCountGroups(J) {
    seen := Map()
    for p in J.Pieces
        seen[p.Grp] := true
    return seen.Count
}

; Move one piece to the front of the draw order.
JigRaise(J, id) {
    i := 1
    while (i <= J.Z.Length) {
        if (J.Z[i] = id) {
            J.Z.RemoveAt(i)
            break
        }
        i++
    }
    J.Z.Push(id)
}

; ══════════════════════════════════════════════════════════════════════════════
; DRAGGING AND SNAPPING
; ══════════════════════════════════════════════════════════════════════════════

; Topmost piece under a canvas point, or 0.
;
; Hit-testing reads the piece bitmap's alpha rather than doing geometry, so a
; click on a tab picks the piece the tab BELONGS to, not whichever cell the
; point happens to fall in.  Walking Z backwards means the piece you can see is
; the piece you get.
JigPieceAt(J, x, y) {
    i := J.Z.Length
    while (i >= 1) {
        p  := J.Pieces[J.Z[i]]
        lx := x - p.X
        ly := y - p.Y
        if (lx >= 0 && ly >= 0 && lx < p.W && ly < p.H) {
            DllCall('gdiplus\GdipBitmapGetPixel', 'Ptr', p.Bmp
                  , 'Int', lx, 'Int', ly, 'UInt*', &argb := 0)
            if (((argb >> 24) & 0xFF) > 100)
                return p.Id
        }
        i--
    }
    return 0
}

; Drag a piece and everything joined to it.
;
; Synchronous loop rather than a WM_MOUSEMOVE handler plus mouse capture: AHK's
; Sleep pumps messages, so the window still repaints, and the Busy flag keeps
; re-entry out.  Far less machinery than the message-based version for a thing
; that lasts as long as the button is held.
JigDrag(J, id, downX, downY) {
    J.Busy := true
    members := JigGroupMembers(J, J.Pieces[id].Grp)
    for mid in members
        JigRaise(J, mid)

    ; Offsets from the cursor, captured once so the group stays rigid.
    offX := Map()
    offY := Map()
    bx0 := 999999, by0 := 999999, bx1 := -999999, by1 := -999999
    for mid in members {
        p := J.Pieces[mid]
        offX[mid] := p.X - downX
        offY[mid] := p.Y - downY
        bx0 := Min(bx0, offX[mid])
        by0 := Min(by0, offY[mid])
        bx1 := Max(bx1, offX[mid] + p.W)
        by1 := Max(by1, offY[mid] + p.H)
    }
    ; Keep at least a corner of the group reachable, or it can be dragged off
    ; the canvas and lost with no way to get it back.
    minCx := 40 - bx1
    maxCx := J.CanvasW - 40 - bx0
    minCy := 40 - by1
    maxCy := J.CanvasH - 40 - by0

    while GetKeyState('LButton', 'P') {
        if !JigState.Games.Has(J.Hwnd)
            break
        if !JigCursorPos(J, &cx, &cy)
            break
        cx := Max(minCx, Min(maxCx, cx))
        cy := Max(minCy, Min(maxCy, cy))
        for mid in members {
            J.Pieces[mid].X := cx + offX[mid]
            J.Pieces[mid].Y := cy + offY[mid]
        }
        JigRender(J)
        Sleep 8
    }

    J.Busy := false
    if !JigState.Games.Has(J.Hwnd)
        return
    JigTrySnap(J, members)
}

; Cursor position in canvas coordinates.  GetCursorPos + ScreenToClient rather
; than MouseGetPos, so the script's CoordMode setting is irrelevant.
JigCursorPos(J, &x, &y) {
    pt := Buffer(8, 0)
    if !DllCall('GetCursorPos', 'Ptr', pt)
        return false
    DllCall('ScreenToClient', 'Ptr', J.Pic.Hwnd, 'Ptr', pt)
    x := NumGet(pt, 0, 'Int')
    y := NumGet(pt, 4, 'Int')
    if (J.ClientW != J.CanvasW)
        x := Round(x * J.CanvasW / J.ClientW)
    if (J.ClientH != J.CanvasH)
        y := Round(y * J.CanvasH / J.ClientH)
    return true
}

; After a drop: does the dragged group belong to anything it is now touching?
;
; Translation is the whole trick.  A piece's translation is (position - home),
; and two pieces are correctly placed relative to each other exactly when their
; translations match — wherever on the canvas that happens to be.  So the test
; is "are we grid neighbours" plus "are the translations within tolerance",
; with no edge geometry involved at all.
JigTrySnap(J, members) {
    if J.Solved
        return
    tol := J.Snap
    inGroup := Map()
    for mid in members
        inGroup[mid] := true

    ; Best (closest) candidate wins, so a piece dropped between two possible
    ; partners joins the one it is actually nearest to.
    ; Seeded high, not at tol: the score is dx+dy, which can reach twice the
    ; tolerance while both axes are still individually within it.
    bestD := 999999
    bestA := 0
    bestB := 0
    for mid in members {
        a := J.Pieces[mid]
        for nb in JigGridNeighbors(J, a) {
            b := J.Pieces[nb]
            if inGroup.Has(b.Id)
                continue
            dx := Abs((a.X - JigHomeX(J, a)) - (b.X - JigHomeX(J, b)))
            dy := Abs((a.Y - JigHomeY(J, a)) - (b.Y - JigHomeY(J, b)))
            if (dx > tol || dy > tol)
                continue
            d := dx + dy
            if (d < bestD) {
                bestD := d
                bestA := a.Id
                bestB := b.Id
            }
        }
    }
    if !bestA {
        JigRender(J)
        return
    }

    ; Align the dragged group onto the stationary one, never the other way
    ; round — the assembly you have already built should not jump.
    a := J.Pieces[bestA]
    b := J.Pieces[bestB]
    shiftX := (b.X - JigHomeX(J, b)) - (a.X - JigHomeX(J, a))
    shiftY := (b.Y - JigHomeY(J, b)) - (a.Y - JigHomeY(J, a))
    for mid in members {
        J.Pieces[mid].X += shiftX
        J.Pieces[mid].Y += shiftY
    }
    JigMerge(J, a.Grp, b.Grp)

    ; Snapping one edge often lines up others exactly (think of a piece dropping
    ; into a corner of three).  Sweep for perfectly-aligned neighbours until
    ; nothing more joins.
    JigMergeExact(J)

    J.Groups := JigCountGroups(J)
    if !J.StartTick
        J.StartTick := A_TickCount

    if (J.Groups = 1)
        JigWin(J)
    else {
        if JigCfg.SnapSound
            SetTimer(JigClick, -1)
        JigUpdateStats(J)
        JigRender(J)
    }
}

; Grid neighbours of a piece, by id.
JigGridNeighbors(J, p) {
    out := []
    if (p.Row > 1)
        out.Push(JigPieceId(J, p.Row - 1, p.Col))
    if (p.Row < J.Rows)
        out.Push(JigPieceId(J, p.Row + 1, p.Col))
    if (p.Col > 1)
        out.Push(JigPieceId(J, p.Row, p.Col - 1))
    if (p.Col < J.Cols)
        out.Push(JigPieceId(J, p.Row, p.Col + 1))
    return out
}

JigPieceId(J, r, c) => (r - 1) * J.Cols + c

JigMerge(J, fromGrp, toGrp) {
    if (fromGrp = toGrp)
        return
    for p in J.Pieces
        if (p.Grp = fromGrp)
            p.Grp := toGrp
}

; Join any neighbouring pieces whose translations already agree exactly.
JigMergeExact(J) {
    changed := true
    while changed {
        changed := false
        for p in J.Pieces {
            for nb in JigGridNeighbors(J, p) {
                q := J.Pieces[nb]
                if (q.Grp = p.Grp)
                    continue
                if ((p.X - JigHomeX(J, p)) != (q.X - JigHomeX(J, q)))
                    continue
                if ((p.Y - JigHomeY(J, p)) != (q.Y - JigHomeY(J, q)))
                    continue
                JigMerge(J, q.Grp, p.Grp)
                changed := true
            }
        }
    }
}

JigWin(J) {
    J.Solved := true
    if J.StartTick
        J.Elapsed := (A_TickCount - J.StartTick) // 1000
    if J.Ticker
        SetTimer(J.Ticker, 0)
    ; Settle the finished picture onto its natural spot, so it ends framed
    ; rather than hanging off a corner of the table.
    if J.Pieces.Length {
        p := J.Pieces[1]
        shiftX := JigHomeX(J, p) - p.X
        shiftY := JigHomeY(J, p) - p.Y
        for q in J.Pieces {
            q.X += shiftX
            q.Y += shiftY
        }
    }
    J.Stats.SetFont('bold')
    JigUpdateStats(J)
    JigRender(J)
    if JigCfg.WinSound
        SetTimer(JigFanfare, -1)
}

JigClick() {
    SoundBeep(1400, 25)
}

JigFanfare() {
    SoundBeep(659, 90)
    SoundBeep(880, 90)
    SoundBeep(1175, 170)
}

; ══════════════════════════════════════════════════════════════════════════════
; PEEK / FRAME / REBUILD / CLOSE
; ══════════════════════════════════════════════════════════════════════════════

JigTogglePeek(J) {
    if (J.Solved || J.Busy)
        return
    J.PeekLock := !J.PeekLock
    J.PeekBtn.Text := J.PeekLock ? 'Hide' : 'Peek'
    JigRender(J)
}

JigToggleFrame(J) {
    J.Frame := !J.Frame
    JigRender(J)
}

JigRebuild(J, want) {
    if J.Busy
        return
    DllCall('gdiplus\GdipCloneImage', 'Ptr', J.Orig, 'Ptr*', &clone := 0)
    if !clone
        return
    x := y := ''
    if WinExist('ahk_id ' J.Hwnd)
        WinGetPos(&x, &y, , , 'ahk_id ' J.Hwnd)
    JigDestroy(J)
    JigCreate(clone, want, x, y)
}

; Esc and the X button both come through here.  A part-assembled jigsaw is a
; lot of work to lose and there is no undo for closing, so it asks — but only
; once something has actually been joined.  Prompting on a freshly scattered
; board, or a finished one, would just be a dialog in the way.
;
; JigDestroy stays the unconditional teardown, because JigRebuild uses it to
; swap the puzzle out mid-flight and must not be interrupted by a prompt.
JigConfirmClose(J) {
    if J.Busy
        return
    joined := J.Pieces.Length - J.Groups
    if (J.Solved || joined < 1) {
        JigDestroy(J)
        return
    }
    ; +OwnDialogs is per-thread, so it has to be asked for again here — this is
    ; a hotkey or Gui-event thread, not the one that built the window.
    try J.Gui.Opt('+OwnDialogs')
    answer := MsgBox('Close this jigsaw?`n`n'
                   . joined ' joined piece' (joined = 1 ? '' : 's') ' will be lost.'
                   , 'Snip Jigsaw', 0x4 | 0x20 | 0x1000)   ; Yes/No, question, topmost
    if (answer = 'Yes')
        JigDestroy(J)
}

JigDestroy(J) {
    if !JigState.Games.Has(J.Hwnd)
        return
    JigState.Games.Delete(J.Hwnd)
    try JigState.Pics.Delete(J.Pic.Hwnd)
    if J.Ticker
        try SetTimer(J.Ticker, 0)

    JigFreePieces(J)
    if J.Gfx
        try DllCall('gdiplus\GdipDeleteGraphics', 'Ptr', J.Gfx)
    for b in [J.Back, J.Img, J.Orig]
        if b
            try GDIp.DisposeImage(b)
    J.Gfx := 0, J.Back := 0, J.Img := 0, J.Orig := 0

    try J.Gui.Destroy()
}

; ══════════════════════════════════════════════════════════════════════════════
; RENDERING
; ══════════════════════════════════════════════════════════════════════════════

JigRender(J) {
    if !JigState.Games.Has(J.Hwnd)
        return
    gfx := J.Gfx
    if !gfx
        return

    DllCall('gdiplus\GdipGraphicsClear', 'Ptr', gfx, 'UInt', 0xFF000000 | JigCfg.Felt)

    if (J.Solved || J.Peeking || J.PeekLock) {
        JigDrawPart(gfx, J.Img, J.BoardX, J.BoardY, J.BoardW, J.BoardH
                             , 0, 0, J.BoardW, J.BoardH)
        if J.Solved
            JigBanner(J, gfx, 'Solved!   ' J.Pieces.Length ' pieces   ·   ' JigTimeStr(J.Elapsed))
        else
            JigBanner(J, gfx, 'Peeking…')
        JigPush(J)
        return
    }

    ; A faint frame showing where the picture belongs.  Not authentic, but a
    ; jigsaw with no box lid and no table edge is disorienting.
    if J.Frame
        JigDrawEdge(gfx, 0x30FFFFFF, J.BoardX, J.BoardY, J.BoardW, J.BoardH)

    for id in J.Z {
        p := J.Pieces[id]
        DllCall('gdiplus\GdipDrawImageRectI', 'Ptr', gfx, 'Ptr', p.Bmp
              , 'Int', p.X, 'Int', p.Y, 'Int', p.W, 'Int', p.H)
    }

    JigPush(J)
}

JigBanner(J, gfx, text) {
    h := Max(30, Min(52, J.CanvasH // 11))
    y := J.CanvasH - h
    JigFillRect(gfx, 0xB4000000, 0, y, J.CanvasW, h)
    JigDrawText(gfx, text, 0, y, J.CanvasW, h, h * 0.46, 0xFFFFFFFF)
}

; STM_SETIMAGE hands back the bitmap it replaced, and that one is ours to free.
JigPush(J) {
    hbm := GDIp.CreateHBITMAPFromBitmap(J.Back)
    if !hbm
        return
    old := SendMessage(0x0172, 0, hbm, J.Pic.Hwnd)
    if old
        DllCall('DeleteObject', 'Ptr', old)
}

; ══════════════════════════════════════════════════════════════════════════════
; HUD
; ══════════════════════════════════════════════════════════════════════════════

JigTick(hwnd) {
    if !JigState.Games.Has(hwnd) {
        SetTimer(, 0)
        return
    }
    J := JigState.Games[hwnd]
    if (J.Solved || J.Busy)
        return
    JigUpdateStats(J)
}

JigUpdateStats(J) {
    if J.Solved {
        J.Stats.Value := 'Solved in ' JigTimeStr(J.Elapsed)
        return
    }
    J.Elapsed := J.StartTick ? (A_TickCount - J.StartTick) // 1000 : 0
    n := J.Pieces.Length
    ; Groups counts down to 1, which is the finish line, and it moves on every
    ; join — a plain "pieces placed" number would sit still while you assemble
    ; clusters away from the frame.
    J.Stats.Value := J.Groups ' groups   ·   ' n ' pieces   ·   ' JigTimeStr(J.Elapsed)
}

JigTimeStr(secs) {
    return Format('{}:{:02}', secs // 60, Mod(secs, 60))
}

JigShowHelp(J) {
    static txt := "
(
Snip Jigsaw — a real jigsaw cut from your snip.

Drag a piece anywhere on the table.  Let go with it near
where it belongs, next to a piece it joins onto, and the
two snap together and move as one from then on.

  Drag              Move a piece, or a joined group
  Space (hold)      Peek at the finished picture
  S                 Re-scatter the pieces still loose
  F                 The faint assembly frame, on / off
  R                 New puzzle, freshly cut
  Right-click       Menu — piece count, and the above
  F1                This help
  Esc               Close the puzzle

Pieces only snap to pieces, never to the frame, so the
picture can be assembled anywhere you like.  The counter
shows how many separate groups are left; at 1 you are
done.

Every cut is generated fresh, so the same snip gives a
different puzzle each time.

The snip it came from stays open as your reference.
Settings live in the [Jigsaw] section of
Data\snipSettings.ini.
)"
    MsgBox(txt, 'Snip Jigsaw — Help', 4096)
}

; ══════════════════════════════════════════════════════════════════════════════
; INPUT
; ══════════════════════════════════════════════════════════════════════════════

JigWM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    if !JigState.Pics.Has(hwnd)
        return
    gh := JigState.Pics[hwnd]
    if !JigState.Games.Has(gh)
        return
    J := JigState.Games[gh]
    if (J.Busy || J.Solved)
        return 0

    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if (x > 0x7FFF)
        x -= 0x10000
    if (y > 0x7FFF)
        y -= 0x10000

    if (J.ClientW != J.CanvasW)
        x := Round(x * J.CanvasW / J.ClientW)
    if (J.ClientH != J.CanvasH)
        y := Round(y * J.CanvasH / J.ClientH)

    if (J.PeekLock) {
        JigTogglePeek(J)
        return 0
    }
    id := JigPieceAt(J, x, y)
    if id
        JigDrag(J, id, x, y)
    return 0
}

JigActive() {
    hwnd := WinExist('A')
    return hwnd ? JigState.Games.Has(hwnd) : false
}

JigCurrent() {
    hwnd := WinExist('A')
    return JigState.Games.Has(hwnd) ? JigState.Games[hwnd] : 0
}

JigKeyPeek() {
    J := JigCurrent()
    if (!J || J.Solved || J.Busy || J.PeekLock)
        return
    J.Peeking := true
    JigRender(J)
    KeyWait('Space')
    if !JigState.Games.Has(J.Hwnd)
        return
    J.Peeking := false
    JigRender(J)
}

JigKeySimple(what) {
    J := JigCurrent()
    if !J
        return
    switch what {
        case 'new':     JigNewGame(J)
        case 'scatter': JigScatterLoose(J)
        case 'frame':   JigToggleFrame(J)
        case 'help':    JigShowHelp(J)
        case 'close':   JigConfirmClose(J)
        case 'menu':    JigShowMenu(J.Gui)
    }
}

#HotIf JigActive()
Space::     JigKeyPeek() ; hide
r::         JigKeySimple('new') ; hide
s::         JigKeySimple('scatter') ; hide
f::         JigKeySimple('frame') ; hide
F1::        JigKeySimple('help') ; hide
Esc::       JigKeySimple('close') ; hide
AppsKey::   JigKeySimple('menu') ; hide
; Enter is swallowed: the Picture can't take focus, so the New button has it
; when the window opens, and a stray Enter would bin a half-built puzzle.
Enter::        return ; hide
NumpadEnter::  return ; hide
#HotIf

; ══════════════════════════════════════════════════════════════════════════════
; GDI+ HELPERS
; ══════════════════════════════════════════════════════════════════════════════
; Jig-prefixed copies rather than shared with SnipPuzzle.ahk, so either module
; can be deleted without taking the other with it.

JigNewBitmap(w, h) {
    ; 0x26200A = PixelFormat32bppARGB, straight (non-premultiplied) alpha — the
    ; same constant ScreenSnip's drop-shadow code uses.  It MUST be a 32bpp
    ; format with the alpha flag: 0x21808 looks similar but is 24bppRGB, and a
    ; bitmap with no alpha channel zero-fills to opaque BLACK rather than to
    ; transparent, so anything not painted shows up as a black rectangle.
    DllCall('gdiplus\GdipCreateBitmapFromScan0', 'Int', w, 'Int', h
          , 'Int', 0, 'Int', 0x26200A, 'Ptr', 0, 'Ptr*', &p := 0)
    return p
}

JigNewGfx(pBmp) {
    DllCall('gdiplus\GdipGetImageGraphicsContext', 'Ptr', pBmp, 'Ptr*', &g := 0)
    if g {
        DllCall('gdiplus\GdipSetInterpolationMode', 'Ptr', g, 'Int', 7)
        DllCall('gdiplus\GdipSetSmoothingMode',     'Ptr', g, 'Int', 4)
        DllCall('gdiplus\GdipSetPixelOffsetMode',   'Ptr', g, 'Int', 2)
        DllCall('gdiplus\GdipSetTextRenderingHint', 'Ptr', g, 'Int', 4)
    }
    return g
}

JigDrawPart(gfx, pImg, dx, dy, dw, dh, sx, sy, sw, sh) {
    DllCall('gdiplus\GdipDrawImageRectRectI', 'Ptr', gfx, 'Ptr', pImg
          , 'Int', dx, 'Int', dy, 'Int', dw, 'Int', dh
          , 'Int', sx, 'Int', sy, 'Int', sw, 'Int', sh
          , 'Int', 2, 'Ptr', 0, 'Ptr', 0, 'Ptr', 0)
}

JigFillRect(gfx, argb, x, y, w, h) {
    DllCall('gdiplus\GdipCreateSolidFill', 'UInt', argb, 'Ptr*', &br := 0)
    if !br
        return
    DllCall('gdiplus\GdipFillRectangleI', 'Ptr', gfx, 'Ptr', br
          , 'Int', x, 'Int', y, 'Int', w, 'Int', h)
    DllCall('gdiplus\GdipDeleteBrush', 'Ptr', br)
}

JigDrawEdge(gfx, argb, x, y, w, h) {
    DllCall('gdiplus\GdipCreatePen1', 'UInt', argb, 'Float', 1, 'Int', 2, 'Ptr*', &pen := 0)
    if !pen
        return
    DllCall('gdiplus\GdipDrawRectangleI', 'Ptr', gfx, 'Ptr', pen
          , 'Int', x, 'Int', y, 'Int', w - 1, 'Int', h - 1)
    DllCall('gdiplus\GdipDeletePen', 'Ptr', pen)
}

JigDrawText(gfx, text, x, y, w, h, sizePx, argb) {
    font := JigFont(sizePx)
    if !font
        return
    rect := Buffer(16, 0)
    NumPut('Float', x, 'Float', y, 'Float', w, 'Float', h, rect)
    DllCall('gdiplus\GdipCreateSolidFill', 'UInt', argb, 'Ptr*', &br := 0)
    if !br
        return
    DllCall('gdiplus\GdipDrawString', 'Ptr', gfx, 'WStr', String(text), 'Int', -1
          , 'Ptr', font, 'Ptr', rect, 'Ptr', JigStrFmt(), 'Ptr', br)
    DllCall('gdiplus\GdipDeleteBrush', 'Ptr', br)
}

JigFont(sizePx) {
    static fam := 0, fonts := Map()
    if !fam {
        DllCall('gdiplus\GdipCreateFontFamilyFromName', 'WStr', 'Segoe UI'
              , 'Ptr', 0, 'Ptr*', &f := 0)
        if !f
            DllCall('gdiplus\GdipGetGenericFontFamilySansSerif', 'Ptr*', &f := 0)
        fam := f
    }
    key := Round(sizePx)
    if fonts.Has(key)
        return fonts[key]
    DllCall('gdiplus\GdipCreateFont', 'Ptr', fam, 'Float', key
          , 'Int', 1, 'Int', 2, 'Ptr*', &font := 0)
    return fonts[key] := font
}

JigStrFmt() {
    static fmt := 0
    if fmt
        return fmt
    DllCall('gdiplus\GdipCreateStringFormat', 'Int', 0, 'Int', 0, 'Ptr*', &f := 0)
    DllCall('gdiplus\GdipSetStringFormatAlign',     'Ptr', f, 'Int', 1)
    DllCall('gdiplus\GdipSetStringFormatLineAlign', 'Ptr', f, 'Int', 1)
    return fmt := f
}
