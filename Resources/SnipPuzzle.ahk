#Requires AutoHotkey v2
; ==============================================================================
;
;                             SnipPuzzle.ahk
;               A sliding-tile puzzle made from any ScreenSnip
;                        Version Date: 8-22-2026 
;
; An optional add-on module for ScreenSnip.ahk.  Lives in  Resources\  and is
; pulled in by the  #Include *i  block at the bottom of ScreenSnip.ahk, on the
; same opt-out contract as SnipOCR / SnipAI / SnipImgur / SnipWinDetect:
;
;   - The PuzzleCfg class is the presence sentinel, tested with IsSet().
;   - Delete this file (or comment out its #Include) and ScreenSnip runs exactly
;     as before, minus the "Puzzle" item on the snip context menu.
;   - No top-level executable code — all state lives in class statics, because
;     the #Include sits past the end of the auto-execute section and any
;     top-level statement here would simply never run.
;
; ── What it does ──────────────────────────────────────────────────────────────
; Right-click any snip > Puzzle > pick a grid size.  The snip's image is cut
; into cols x rows tiles, one tile is removed, and the rest are shuffled by a
; long run of legal slides — so the result is ALWAYS solvable (a randomly
; permuted 15-puzzle is solvable only half the time; shuffling by real moves
; sidesteps the parity problem entirely).
;
; Click any tile in the blank's row or column to slide it (and everything
; between it and the gap) over one cell.  Arrow keys slide a single tile in the
; direction pressed.  Hold Space to peek at the finished picture.  Solve it and
; the grid lines vanish, the picture becomes whole again, and you get your time.
;
; NOT the "evil" variant — it never takes a window hostage, never hides
; anything, and the snip it was made from stays open by default so the answer is
; always on screen if you want it.
;
; ── Settings ──────────────────────────────────────────────────────────────────
; Read once at load through ScreenSnip's own SnipCfg(), so they live in
; Data\snipSettings.ini alongside everything else and need a restart to take
; effect.  The literal in each call is the fallback used when the key is absent,
; which is what makes the whole [Puzzle] section optional.
;
;   [Puzzle]                 type     default   what it does
;   GridCols                 int      4         default columns (2-12)
;   GridRows                 int      4         default rows (2-12)
;   MaxBoardSize             int      0         0 = play at the snip's own
;                                                 size, limited only by the
;                                                 screen.  Set a number of px to
;                                                 cap the longest side instead.
;   MinBoardSize             int      300       small snips scale UP to this
;   TileGap                  int      2         px of board colour between tiles
;   ShowNumbers              bool     1         bake tile numbers into the tiles
;   SlideAnimMs              int      90        slide animation; 0 = instant
;   ShuffleMoves             int      0         0 = auto (25 x tile count)
;   BoardColor               hex      1E1E1E    the gap/background colour
;   TileOutline              bool     1         hairline edge on each tile
;   CloseSnipOnStart         bool     0         1 = the snip becomes the puzzle
;   SoundOnSolve             bool     1         three-note fanfare on solving
;   AlwaysOnTop              bool     1         puzzle window floats
;
; To get these into SettingsManager, add a matching entry per key to
; Data\snipSettingsMetadata.json in the SAME SHAPE as the existing sections
; there (label / type / default / help / restart).  None of them need a
; "restart" path other than the one the other keys already use.  Skipping the
; metadata entirely is fine too — the keys still work when typed into the INI by
; hand, they just won't appear in SettingsManager's tree.
;
; ── Wiring into ScreenSnip.ahk (three small edits) ────────────────────────────
; 1. In the "Context menu for snip windows" block, after the Imgur block:
;
;        if IsSet(PuzzleCfg) {
;            puzzleMenuBuilder := 'PuzzleBuildMenu'
;            SnipMenu.Add('Puzzle', %puzzleMenuBuilder%())
;        }
;
; 2. At the bottom, with the other optional modules:
;
;        #Include *i Resources\SnipPuzzle.ahk
;
; 3. (Optional) a line in HelpText's cheat sheet.
;
; Nothing else changes.  The submenu's items are handled inside this file, so
; SnipMenu_Handler() needs no new cases.
;
; Adapted by kunkel321 / Claude
; Version date: 8-22-2026
; ==============================================================================

; ══════════════════════════════════════════════════════════════════════════════
; CONFIG + STATE  (class statics only — see the contract note above)
; ══════════════════════════════════════════════════════════════════════════════

; The presence sentinel.  Static initialisers run at LOAD time, before the
; auto-execute section, which is exactly why ScreenSnip's menu-building code can
; test IsSet(PuzzleCfg) even though this file is included 3,000 lines later.
; SnipCfg() is lazy for the same reason, so calling it from here is safe.
class PuzzleCfg {
    static Cols       := SnipCfg('Puzzle', 'GridCols',         4)
    static Rows       := SnipCfg('Puzzle', 'GridRows',         4)
    static MaxBoard   := SnipCfg('Puzzle', 'MaxBoardSize',     0)
    static MinBoard   := SnipCfg('Puzzle', 'MinBoardSize',   300)
    static Gap        := SnipCfg('Puzzle', 'TileGap',          2)
    static Numbers    := SnipCfg('Puzzle', 'ShowNumbers',      1)
    static AnimMs     := SnipCfg('Puzzle', 'SlideAnimMs',     90)
    static Shuffle    := SnipCfg('Puzzle', 'ShuffleMoves',     0)
    static BoardColor := SnipCfgHex('Puzzle', 'BoardColor', 0x1E1E1E)
    static Outline    := SnipCfg('Puzzle', 'TileOutline',      1)
    static SelColor   := SnipCfgHex('Puzzle', 'SelectColor', 0xFFC24B)
    static CloseSnip  := SnipCfg('Puzzle', 'CloseSnipOnStart', 0)
    static WinSound   := SnipCfg('Puzzle', 'SoundOnSolve',     1)
    static OnTop      := SnipCfg('Puzzle', 'AlwaysOnTop',      1)
}

; Live state.  Games is the authoritative registry — a window is a puzzle if and
; only if it has an entry here, and every in-flight handler and animation frame
; re-checks it so a mid-animation close can't paint into a destroyed control.
; (Same defensive pattern as guiSnips over in ScreenSnip.ahk.)
class PuzzleState {
    static Games  := Map()      ; gui hwnd     -> puzzle object
    static Pics   := Map()      ; picture hwnd -> gui hwnd  (for the click hook)
    static Hooked := false      ; OnMessage/OnExit registered yet?
}

; ══════════════════════════════════════════════════════════════════════════════
; MENU
; ══════════════════════════════════════════════════════════════════════════════

; Builds the size submenu for the snip context menu.  There are two of these —
; one per puzzle mode — and ScreenSnip calls each by name via the %name%() form,
; so a missing module is a non-event rather than a load-time error.
;
; Both submenus are identical apart from which handler they carry, and the
; handler is the only thing that knows the mode.  That keeps the mode out of the
; item text, so the grid sizes stay comparable between the two.
PuzzleBuildSlideMenu() {
    return PuzzleBuildSizeMenu(PuzzleSlideMenu_Handler)
}

PuzzleBuildSwapMenu() {
    return PuzzleBuildSizeMenu(PuzzleSwapMenu_Handler)
}

PuzzleBuildSizeMenu(handler) {
    m := Menu()
    m.Add('Play  (' PuzzleCfg.Cols ' x ' PuzzleCfg.Rows ')', handler)
    m.Add()
    m.Add('3 x 3   easy',   handler)
    m.Add('4 x 4',          handler)
    m.Add('5 x 5',          handler)
    m.Add('6 x 6   hard',   handler)
    m.Add()
    m.Add('Custom Size…',   handler)
    return m
}

PuzzleSlideMenu_Handler(ItemName, *) {
    PuzzleMenuPick(ItemName, 'slide')
}

PuzzleSwapMenu_Handler(ItemName, *) {
    PuzzleMenuPick(ItemName, 'swap')
}

; Items on those submenus.  The snip to play is the one ScreenSnip stashed on
; the menu object when it opened it — the same _targetHwnd every other snip-menu
; item reads.
PuzzleMenuPick(ItemName, mode) {
    global SnipMenu
    hwnd := SnipMenu._targetHwnd
    base := StrSplit(ItemName, "`t")[1]

    if InStr(base, 'Custom') {
        if !PuzzleAskSize(PuzzleCfg.Cols, PuzzleCfg.Rows, &c, &r, PuzzleSnipGui(hwnd))
            return
        PuzzlePlay(hwnd, mode, c, r)
        return
    }
    ; "4 x 4", "6 x 6   hard", "Play  (4 x 4)" — all yield their two numbers.
    if RegExMatch(base, '(\d+)\D+(\d+)', &m)
        PuzzlePlay(hwnd, mode, Integer(m[1]), Integer(m[2]))
    else
        PuzzlePlay(hwnd, mode, PuzzleCfg.Cols, PuzzleCfg.Rows)
}

; The puzzle window's own right-click menu.  One shared Menu with a _target
; property, synced on show — the same arrangement ScreenSnip uses for SnipMenu,
; and for the same reason: one menu object, however many windows are open.
; Built lazily rather than in a class static so nothing is created for people
; who never open a puzzle.
; Item labels, in one place.  Not fussiness: Menu.Check / Enable / Disable match
; on the WHOLE label, tab and accelerator text included, so Check('Show Numbers')
; would throw "menu item not found" against an item added as 'Show Numbers`tN'.
; Keeping the two uses on one string makes that class of bug impossible.
PuzzleLbl(key) {
    static L := Map(
        'shuffle', 'Shuffle Again`tR'
      , 'peek',    'Peek at Picture`tSpace'
      , 'numbers', 'Show Numbers`tN'
      , 'undo',    'Undo`tCtrl+Z'
      , 'help',    'Help`tF1'
      , 'close',   'Close`tEsc'
      , 'slide',   'Slide Puzzle'
      , 'swap',    'Swap Puzzle')
    return L[key]
}

PuzzleMenuObj() {
    static m := ''
    if IsObject(m)
        return m

    sizes := Menu()
    sizes.Add('3 x 3', PuzzleCtxMenu_Handler)
    sizes.Add('4 x 4', PuzzleCtxMenu_Handler)
    sizes.Add('5 x 5', PuzzleCtxMenu_Handler)
    sizes.Add('6 x 6', PuzzleCtxMenu_Handler)
    sizes.Add()
    sizes.Add('Custom…', PuzzleCtxMenu_Handler)

    ; Switching type mid-game rebuilds around the same picture and grid, so you
    ; can bail out of a slide puzzle you've made a mess of without going back to
    ; the snip and starting over.
    types := Menu()
    types.Add(PuzzleLbl('slide'), PuzzleCtxMenu_Handler)
    types.Add(PuzzleLbl('swap'),  PuzzleCtxMenu_Handler)

    m := Menu()
    m.Add(PuzzleLbl('shuffle'), PuzzleCtxMenu_Handler)
    m.Add(PuzzleLbl('peek'),    PuzzleCtxMenu_Handler)   ; checkable
    m.Add(PuzzleLbl('numbers'), PuzzleCtxMenu_Handler)   ; checkable
    m.Add('Grid Size', sizes)
    m.Add('Puzzle Type', types)
    m.Add()
    m.Add(PuzzleLbl('undo'),    PuzzleCtxMenu_Handler)
    m.Add()
    m.Add(PuzzleLbl('help'),    PuzzleCtxMenu_Handler)
    m.Add(PuzzleLbl('close'),   PuzzleCtxMenu_Handler)
    m._types := types                    ; kept for the radio check on show
    return m
}

PuzzleCtxMenu_Handler(ItemName, *) {
    m := PuzzleMenuObj()
    if !PuzzleState.Games.Has(m._target)
        return
    P    := PuzzleState.Games[m._target]
    base := StrSplit(ItemName, "`t")[1]

    switch base {
        case 'Shuffle Again':    PuzzleNewGame(P)
        case 'Peek at Picture':  PuzzleTogglePeek(P)
        case 'Show Numbers':     PuzzleToggleNumbers(P)
        case 'Undo':             PuzzleUndo(P)
        case 'Help':             PuzzleShowHelp(P)
        case 'Close':            PuzzleConfirmClose(P)
        case '3 x 3':            PuzzleRebuild(P, P.Mode, 3, 3)
        case '4 x 4':            PuzzleRebuild(P, P.Mode, 4, 4)
        case '5 x 5':            PuzzleRebuild(P, P.Mode, 5, 5)
        case '6 x 6':            PuzzleRebuild(P, P.Mode, 6, 6)
        case 'Slide Puzzle':     PuzzleRebuild(P, 'slide', P.Cols, P.Rows)
        case 'Swap Puzzle':      PuzzleRebuild(P, 'swap',  P.Cols, P.Rows)
        case 'Custom…':
            if PuzzleAskSize(P.Cols, P.Rows, &c, &r, P.Gui)
                PuzzleRebuild(P, P.Mode, c, r)
    }
}

; Wired to the puzzle Gui's ContextMenu event, so it covers the Picture child
; too and fires on button-UP (menu opens on a normal click, no need to hold).
PuzzleShowMenu(GuiObj, *) {
    if !PuzzleState.Games.Has(GuiObj.Hwnd)
        return
    P := PuzzleState.Games[GuiObj.Hwnd]
    m := PuzzleMenuObj()
    m._target := GuiObj.Hwnd
    ; Plain if/else rather than a ternary split over three lines.  A continuation
    ; line that starts with '?' gets glued straight onto the end of the line
    ; above, and 'P.Numbers?' then reads as the maybe-operator instead of the
    ; start of a ternary — a syntax error with a very confusing message.
    if P.Numbers
        m.Check(PuzzleLbl('numbers'))
    else
        m.UnCheck(PuzzleLbl('numbers'))

    (P.PeekLock || P.Peeking) ? m.Check(PuzzleLbl('peek')) : m.UnCheck(PuzzleLbl('peek'))

    if P.History.Length
        m.Enable(PuzzleLbl('undo'))
    else
        m.Disable(PuzzleLbl('undo'))

    t := m._types
    if (P.Mode = 'swap') {
        t.Check(PuzzleLbl('swap'))
        t.UnCheck(PuzzleLbl('slide'))
    } else {
        t.Check(PuzzleLbl('slide'))
        t.UnCheck(PuzzleLbl('swap'))
    }
    m.Show()
}

; Ask for a grid size.  Accepts "4x3", "4 x 3", "4,3" or a bare "5" (square).
; Returns false when cancelled or unparseable, leaving the outputs untouched.
; Own the dialog, or it opens BEHIND the snip.
;
; +OwnDialogs is per-THREAD, not per-Gui: setting it in the Gui() options only
; affects the thread that created the window.  A menu handler is a new thread,
; so it has to be asked for again here — otherwise the InputBox is unowned,
; and an unowned dialog loses to the snip's +AlwaysOnTop and hides behind it.
PuzzleAskSize(defCols, defRows, &cols, &rows, owner := 0) {
    if IsObject(owner) {
        try owner.Opt('+OwnDialogs')
    }
    ib := InputBox('Grid size, as  columns x rows.'
                 . '`n`nEach side 2 to 12.  A single number makes it square.'
                 , 'Snip Puzzle', 'w320 h150', defCols 'x' defRows)
    if (ib.Result != 'OK')
        return false

    if RegExMatch(ib.Value, '^\s*(\d+)\s*[xX*,\s]\s*(\d+)\s*$', &m)
        cols := Integer(m[1]), rows := Integer(m[2])
    else if RegExMatch(ib.Value, '^\s*(\d+)\s*$', &m)
        cols := Integer(m[1]), rows := cols
    else {
        MsgBox('Could not read "' ib.Value '" as a grid size.', 'Snip Puzzle', 4096)
        return false
    }
    cols := Max(2, Min(12, cols))
    rows := Max(2, Min(12, rows))
    return true
}

; ══════════════════════════════════════════════════════════════════════════════
; CREATING A GAME
; ══════════════════════════════════════════════════════════════════════════════

; Entry point from the snip context menu.  Takes a WYSIWYG copy of the snip —
; BuildDisplayBitmap applies the same flips and rotation the snip is currently
; showing — so what you play is what you were looking at.  That copy is OURS
; from here on: the snip can be closed, panned, resized or rotated afterwards
; without disturbing a game in progress.
; The Gui object behind a snip window, for use as a dialog owner.  Returns 0
; when the snip has gone, which the callers treat as "no owner".
PuzzleSnipGui(snipHwnd) {
    global guiSnips
    if !guiSnips.Has(snipHwnd)
        return 0
    try return guiSnips[snipHwnd].GuiObj
    return 0
}

PuzzlePlay(snipHwnd, mode := 'slide', cols := 0, rows := 0) {
    global guiSnips
    if !guiSnips.Has(snipHwnd)
        return
    snip := guiSnips[snipHwnd]

    cols := Max(2, Min(12, cols ? cols : PuzzleCfg.Cols))
    rows := Max(2, Min(12, rows ? rows : PuzzleCfg.Rows))

    orig := BuildDisplayBitmap(snip)     ; caller owns and must dispose
    if !orig {
        if (og := PuzzleSnipGui(snipHwnd)) {
            try og.Opt('+OwnDialogs')
        }
        MsgBox('Could not read the snip image.', 'Snip Puzzle', 4096)
        return
    }

    ; Open the board over the snip, nudged down-right so it doesn't land exactly
    ; on top of it — the snip is the reference picture, and covering it is the
    ; one thing a NON-evil puzzle should not do.
    x := y := ''
    if WinExist('ahk_id ' snipHwnd) {
        WinGetPos(&sx, &sy, , , 'ahk_id ' snipHwnd)
        x := sx + 24, y := sy + 24
    }

    if PuzzleCfg.CloseSnip
        CloseSnip(snipHwnd)

    PuzzleCreate(orig, mode, cols, rows, x, y)
}

; Build a whole game around an image.  TAKES OWNERSHIP of pOrig — it is disposed
; with the game, and every derived bitmap is rebuilt from it, which is what
; makes a mid-game grid change possible without going back to the snip.
PuzzleCreate(pOrig, mode, cols, rows, x := '', y := '') {
    PuzzleHookOnce()

    DllCall('gdiplus\GdipGetImageWidth',  'Ptr', pOrig, 'UInt*', &sw := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'Ptr', pOrig, 'UInt*', &sh := 0)
    if (sw < 1 || sh < 1) {
        GDIp.DisposeImage(pOrig)
        return
    }

    ; ── Board geometry ────────────────────────────────────────────────────────
    ; Scale so the longest side lands between MinBoardSize and MaxBoardSize:
    ; a 2000px window shrinks to something playable, and a 120px snip grows to
    ; something clickable.  Then FLOOR the tile size and derive the board from
    ; it, rather than the other way round — integer tiles mean no half-pixel
    ; seams and no rounding drift across a 6-wide grid.
    ; The board wants to be the snip's OWN size.  A tile puzzle is nothing but
    ; the picture, so shrinking it throws away the detail you are matching on —
    ; and unlike the jigsaw there is no gutter to find room for, just a few
    ; pixels of window frame.  So MaxBoardSize defaults to 0, meaning "no cap",
    ; and the screen does the limiting.
    longest := Max(sw, sh)
    scale   := 1.0
    if (PuzzleCfg.MaxBoard > 0 && longest > PuzzleCfg.MaxBoard)
        scale := PuzzleCfg.MaxBoard / longest
    else if (longest < PuzzleCfg.MinBoard)
        scale := PuzzleCfg.MinBoard / longest

    ; Fit the work area, since an oversized window can't be resized once it is
    ; up.  The reserves below are the actual chrome: window border and GUI
    ; margins across, plus title bar and the button row down.
    MonitorGetWorkArea( , &wkL, &wkT, &wkR, &wkB)
    availW := (wkR - wkL) - 46
    availH := (wkB - wkT) - 128
    prelimW := sw * scale
    prelimH := sh * scale
    if (prelimW > availW || prelimH > availH)
        scale *= Min(availW / Max(1, prelimW), availH / Max(1, prelimH))

    tileW := Max(16, Floor(sw * scale / cols))
    tileH := Max(16, Floor(sh * scale / rows))
    boardW := tileW * cols
    boardH := tileH * rows

    ; Board-sized copy of the picture.  Used whole for peeking and for the
    ; solved view, and cut up for the tiles.
    pImg := PuzzleNewBitmap(boardW, boardH)
    if !pImg {
        GDIp.DisposeImage(pOrig)
        return
    }
    gImg := PuzzleNewGfx(pImg)
    PuzzleDrawPart(gImg, pOrig, 0, 0, boardW, boardH, 0, 0, sw, sh)
    DllCall('gdiplus\GdipDeleteGraphics', 'Ptr', gImg)

    ; Back buffer.  Created once and reused for every frame; only the HBITMAP
    ; handed to the Picture control is made (and freed) per frame.
    pBack := PuzzleNewBitmap(boardW, boardH)
    gBack := PuzzleNewGfx(pBack)
    DllCall('gdiplus\GdipBitmapSetResolution', 'Ptr', pBack
          , 'Float', A_ScreenDPI + 0.0, 'Float', A_ScreenDPI + 0.0)

    ; ── Window ────────────────────────────────────────────────────────────────
    mode := (mode = 'swap') ? 'swap' : 'slide'
    opts := '-MaximizeBox +OwnDialogs' (PuzzleCfg.OnTop ? ' +AlwaysOnTop' : '')
    g := Gui(opts, 'Snip Puzzle   ' (mode = 'swap' ? 'Swap' : 'Slide') '   ' cols ' x ' rows)
    g.MarginX := 10, g.MarginY := 10

    ; Seed the control with a real (blank) board so it has something to size
    ; itself to, then never touch its dimensions again — every later frame goes
    ; in by STM_SETIMAGE at exactly this size.
    DllCall('gdiplus\GdipGraphicsClear', 'Ptr', gBack
          , 'UInt', 0xFF000000 | PuzzleCfg.BoardColor)
    hbm0 := GDIp.CreateHBITMAPFromBitmap(pBack)
    if !hbm0 {                           ; out of GDI handles, or a bad board size
        DllCall('gdiplus\GdipDeleteGraphics', 'Ptr', gBack)
        GDIp.DisposeImage(pBack), GDIp.DisposeImage(pImg), GDIp.DisposeImage(pOrig)
        MsgBox('Could not build the puzzle board.', 'Snip Puzzle', 4096)
        return
    }

    ; No w/h on purpose: the control takes the bitmap's natural pixel size, the
    ; way ScreenSnip's own snip Pictures do, which is what keeps the board 1:1
    ; on a scaled display instead of being stretched by DPI-scaled coordinates.
    ; +0x100 is SS_NOTIFY: without it a Static swallows mouse messages and the
    ; WM_LBUTTONDOWN hook below never hears the click.
    pic := g.Add('Picture', 'xm ym +0x100', 'HBITMAP:' hbm0)

    stats := g.Add('Text', 'xm y+8 w150 h22 +0x200', 'Moves 0  ·  0:00')
    bShuf := g.Add('Button', 'x+6 yp-2 w70 h26', 'Shuffle')
    bPeek := g.Add('Button', 'x+6 yp w56 h26', 'Peek')
    bHelp := g.Add('Button', 'x+6 yp w26 h26', '?')

    P := { Gui: g, Hwnd: g.Hwnd, Pic: pic, Stats: stats, PeekBtn: bPeek
         , Mode: mode
         , Cols: cols, Rows: rows, TileW: tileW, TileH: tileH
         , BoardW: boardW, BoardH: boardH, Gap: Max(0, PuzzleCfg.Gap)
         , ClientW: boardW, ClientH: boardH
         , TileDrawW: tileW, TileDrawH: tileH
         , Orig: pOrig, Img: pImg, Back: pBack, Gfx: gBack, TileBmp: Map()
         , Tiles: [], Blank: cols * rows, Sel: 0, History: []
         , Moves: 0, StartTick: 0, Elapsed: 0
         , Solved: false, Busy: false, Peeking: false, PeekLock: false
         , Numbers: PuzzleCfg.Numbers ? true : false
         , AnimSet: 0, AnimOrder: 0, AnimProg: 0
         , Ticker: 0 }

    bShuf.OnEvent('Click', (*) => PuzzleNewGame(P))
    bPeek.OnEvent('Click', (*) => PuzzleTogglePeek(P))
    bHelp.OnEvent('Click', (*) => PuzzleShowHelp(P))
    g.OnEvent('Close',       (*) => PuzzleConfirmClose(P))
    g.OnEvent('Escape',      (*) => PuzzleConfirmClose(P))
    g.OnEvent('ContextMenu', PuzzleShowMenu)

    PuzzleState.Games[g.Hwnd]  := P
    PuzzleState.Pics[pic.Hwnd] := g.Hwnd

    PuzzleBuildTiles(P)
    PuzzleNewGame(P, false)              ; lay out + shuffle before first paint

    if (IsNumber(x) && IsNumber(y))
        g.Show('x' x ' y' y)
    else
        g.Show()
    PuzzleRender(P)

    ; Measure what the control ACTUALLY ended up as, rather than assuming it
    ; matches the board.  It always has so far, but a click landing on the wrong
    ; tile is a maddening bug to chase, and the ratio below costs one multiply.
    rc := Buffer(16, 0)
    DllCall('GetClientRect', 'Ptr', pic.Hwnd, 'Ptr', rc)
    P.ClientW := Max(1, NumGet(rc,  8, 'Int'))
    P.ClientH := Max(1, NumGet(rc, 12, 'Int'))

    P.Ticker := PuzzleTick.Bind(g.Hwnd)
    SetTimer(P.Ticker, 500)
}

; Register the click hook and the exit handler — once, on the first puzzle, so
; a session that never opens one pays nothing.
;
; OnMessage order matters here in a good way: ScreenSnip registered its own
; WM_LBUTTONDOWN during auto-execute, so its monitor runs first, sees a window
; that isn't a snip, and returns an empty string — which is precisely what lets
; a later monitor (ours) get a look at the message.
;
; OnExit is the reverse: v2 calls the MOST RECENTLY added callback first, so
; ours runs before ScreenSnip's CleanupOnExit and every puzzle bitmap is
; disposed while GDI+ is still up.
PuzzleHookOnce() {
    if PuzzleState.Hooked
        return
    PuzzleState.Hooked := true
    OnMessage(0x0201, PuzzleWM_LBUTTONDOWN)
    OnExit(PuzzleCleanupOnExit)
}

PuzzleCleanupOnExit(*) {
    for hwnd, P in PuzzleState.Games.Clone()
        try PuzzleDestroy(P)
}

; ══════════════════════════════════════════════════════════════════════════════
; TILES
; ══════════════════════════════════════════════════════════════════════════════

; Pre-render every tile at its exact on-screen size, numbers and outline baked
; in.  The point is that PuzzleRender() then does nothing but 1:1 blits — no
; per-frame scaling, no per-frame text — which is what keeps a 6x6 slide smooth.
; The cost is paying for a rebuild when the numbers are toggled, which happens
; approximately never, and takes a few milliseconds when it does.
;
; Tile ids run 1..N-1 and each one's HOME is the cell of the same number, so the
; missing piece is always the bottom-right cell.  That is also what makes the
; solved test a simple "Tiles[i] = i" walk.
PuzzleBuildTiles(P) {
    PuzzleFreeTiles(P)

    ; A 12x12 grid on a small snip can make the gap wider than the tile.  Drop
    ; the gap rather than the tiles; PuzzleBlit reads P.Gap too, so fixing it
    ; here fixes the layout as well.
    if (P.TileW - P.Gap * 2 < 4 || P.TileH - P.Gap * 2 < 4)
        P.Gap := 0

    tw := P.TileW - P.Gap * 2
    th := P.TileH - P.Gap * 2

    n := P.Cols * P.Rows
    ; Slide mode removes one tile to make the gap; swap mode keeps all of them,
    ; since there is nowhere for a tile to slide INTO — you trade places instead.
    highest := (P.Mode = 'swap') ? n : n - 1
    Loop highest {
        t  := A_Index
        sx := Mod(t - 1, P.Cols) * P.TileW + P.Gap
        sy := ((t - 1) // P.Cols) * P.TileH + P.Gap

        b := PuzzleNewBitmap(tw, th)
        if !b
            continue
        gfx := PuzzleNewGfx(b)
        PuzzleDrawPart(gfx, P.Img, 0, 0, tw, th, sx, sy, tw, th)

        ; Hairline edge: a touch of dark on the outside and a touch of light
        ; just inside it.  Cheap fake bevel, but it stops adjacent tiles from
        ; merging into one another when the gap is 0 or 1.
        if PuzzleCfg.Outline {
            PuzzleDrawEdge(gfx, 0x50000000, 0, 0, tw, th)
            PuzzleDrawEdge(gfx, 0x28FFFFFF, 1, 1, tw - 2, th - 2)
        }

        if P.Numbers {
            box := Max(18, Min(34, Min(tw, th) // 4))
            PuzzleFillRect(gfx, 0x88000000, 3, 3, box, box)
            PuzzleDrawText(gfx, t, 3, 3, box, box, box * 0.62, 0xFFFFFFFF)
        }

        DllCall('gdiplus\GdipDeleteGraphics', 'Ptr', gfx)
        P.TileBmp[t] := b
    }
    P.TileDrawW := tw, P.TileDrawH := th
}

PuzzleFreeTiles(P) {
    for t, b in P.TileBmp
        try GDIp.DisposeImage(b)
    P.TileBmp := Map()
}

; ══════════════════════════════════════════════════════════════════════════════
; GAME STATE
; ══════════════════════════════════════════════════════════════════════════════

; Reset to solved, then shuffle.  Called for a new game and for the Shuffle
; button; `paint` is false only during construction, when the window isn't up
; yet and there is nothing to paint into.
PuzzleNewGame(P, paint := true) {
    if P.Busy
        return
    n := P.Cols * P.Rows
    P.Tiles := []
    if (P.Mode = 'swap') {
        Loop n
            P.Tiles.Push(A_Index)        ; every cell filled; no gap
        P.Blank := 0
    } else {
        Loop n - 1
            P.Tiles.Push(A_Index)
        P.Tiles.Push(0)                  ; blank in the bottom-right
        P.Blank := n
    }
    P.Sel     := 0
    P.History := []
    P.Moves   := 0
    P.StartTick := 0                     ; clock starts on the first real move
    P.Elapsed := 0
    P.Solved  := false
    P.Peeking := false
    ; A latched peek has to be dropped here or the fresh board would come up
    ; showing the answer.  Likewise the timer: PuzzleWin switched it off, and
    ; without this the second game's clock would sit at 0:00 forever.
    if P.PeekLock {
        P.PeekLock := false
        P.PeekBtn.Text := 'Peek'
    }
    if P.Ticker
        SetTimer(P.Ticker, 500)
    PuzzleShuffleBoard(P)
    P.Stats.SetFont('norm cDefault')
    PuzzleUpdateStats(P)
    if paint
        PuzzleRender(P)
}

; Shuffle by making legal moves from the solved state.
;
; This is not laziness — it is the whole reason the puzzle is never impossible.
; A random permutation of a 15-puzzle is solvable only half the time (parity),
; so shuffling by dealing tiles out at random would hand you an unsolvable board
; every other game.  Walking the blank around at random can only ever reach
; positions that are, by construction, walkable back.
;
; `last` blocks the immediate reversal — without it the blank does a drunkard's
; walk and tends to wander back toward where it started.
PuzzleShuffleBoard(P) {
    if (P.Mode = 'swap') {
        PuzzleShuffleSwap(P)
        return
    }
    n     := P.Cols * P.Rows
    moves := (PuzzleCfg.Shuffle > 0) ? PuzzleCfg.Shuffle : n * 25
    last  := 0

    Loop moves {
        cands := PuzzleNeighbors(P)
        pick  := 0
        ; Prefer a neighbour that isn't where we just came from; fall back to
        ; any of them if that's the only option (can't happen above 1xN, but a
        ; 2x2 board is tight enough to be worth not assuming).
        Loop 8 {
            c := cands[Random(1, cands.Length)]
            if (c != last) {
                pick := c
                break
            }
        }
        if !pick
            pick := cands[Random(1, cands.Length)]
        last := P.Blank
        PuzzleCommit(P, pick)
    }
    ; Vanishingly unlikely, but a shuffle that lands back on solved would be a
    ; sad way to start.
    if PuzzleIsSolved(P)
        PuzzleCommit(P, PuzzleNeighbors(P)[1])
}

; Swap mode gets a straight Fisher-Yates shuffle, and that is not a shortcut —
; it is a genuine difference between the two puzzles.
;
; Adjacent transpositions generate the whole symmetric group, so EVERY
; permutation of a swap board is reachable and therefore solvable.  The parity
; trap that forces the slide puzzle to shuffle by legal moves simply doesn't
; exist here: half of all slide arrangements are impossible, none of the swap
; ones are.  So we can deal the tiles out at random and be done.
PuzzleShuffleSwap(P) {
    n := P.Cols * P.Rows
    ; Fisher-Yates, walking down and swapping each cell with a random earlier
    ; one.  Uniform over all n! arrangements, unlike the "swap two at random,
    ; lots of times" approach, which is subtly biased.
    i := n
    while (i > 1) {
        j := Random(1, i)
        t := P.Tiles[i]
        P.Tiles[i] := P.Tiles[j]
        P.Tiles[j] := t
        i--
    }
    ; A shuffle can land on solved, or leave a board where nothing moved.  Both
    ; are legal and both are a dull way to start, so nudge it.
    if PuzzleIsSolved(P) {
        t := P.Tiles[1]
        P.Tiles[1] := P.Tiles[2]
        P.Tiles[2] := t
    }
}

; Cell indices orthogonally adjacent to the blank.
;
; Each body is on its OWN line for a reason.  Written as
; `if (r > 1)   out.Push(...)` on one line, v2 does not read that as an if with
; a body — it reads `(r > 1)` and `out.Push(...)` as two juxtaposed expressions
; and CONCATENATES them into the condition, then takes the NEXT line as the
; body.  Four of those in a row nest into each other, the Pushes all fire
; unconditionally, and `return out` becomes the innermost body — so the moment
; one condition is false the function falls off its end and returns an empty
; string instead of an array.  (Which is exactly what happened: the blank starts
; bottom-right, so `r < P.Rows` is false on the very first shuffle move.)
PuzzleNeighbors(P) {
    PuzzleRC(P, P.Blank, &r, &c)
    out := []
    if (r > 1)
        out.Push(PuzzleIdx(P, r - 1, c))
    if (r < P.Rows)
        out.Push(PuzzleIdx(P, r + 1, c))
    if (c > 1)
        out.Push(PuzzleIdx(P, r, c - 1))
    if (c < P.Cols)
        out.Push(PuzzleIdx(P, r, c + 1))
    return out
}

PuzzleIdx(P, r, c) => (r - 1) * P.Cols + c

PuzzleRC(P, idx, &r, &c) {
    r := (idx - 1) // P.Cols + 1
    c := Mod(idx - 1, P.Cols) + 1
}

; Solved when every tile sits on its home cell.  Slide mode checks all but the
; last cell, because that one holds the blank; swap mode checks all of them.
PuzzleIsSolved(P) {
    n := P.Cols * P.Rows
    Loop (P.Mode = 'swap') ? n : n - 1
        if (P.Tiles[A_Index] != A_Index)
            return false
    return true
}

; ══════════════════════════════════════════════════════════════════════════════
; MOVING TILES
; ══════════════════════════════════════════════════════════════════════════════

; The one move primitive: slide everything between the blank and `cell` one step
; toward the blank.  `cell` must share the blank's row or column; a click
; anywhere else is simply not a move and is ignored.
;
; Multi-tile slides (click three cells away and three tiles move together) are
; how every modern 15-puzzle behaves, and they cost nothing extra here — the
; group is contiguous by definition, so it is one shift of the array either way.
;
; Returns the number of tiles moved, or 0 for "not a legal move".
PuzzleSlide(P, cell, animate := true) {
    if (P.Busy || P.Solved || P.Peeking || P.PeekLock)
        return 0
    if (cell < 1 || cell > P.Cols * P.Rows || cell = P.Blank)
        return 0

    PuzzleRC(P, P.Blank, &br, &bc)
    PuzzleRC(P, cell,    &cr, &cc)
    if (br != cr && bc != cc)
        return 0                          ; not in line with the gap

    ; Cells that will move, listed from the blank outward, plus the direction
    ; each of them travels (one cell, toward the gap).
    cells := []
    if (br = cr) {
        step := (cc > bc) ? 1 : -1
        Loop Abs(cc - bc)
            cells.Push(PuzzleIdx(P, br, bc + A_Index * step))
        dx := -step, dy := 0
    } else {
        step := (cr > br) ? 1 : -1
        Loop Abs(cr - br)
            cells.Push(PuzzleIdx(P, br + A_Index * step, bc))
        dx := 0, dy := -step
    }

    P.Busy := true
    if (animate && PuzzleCfg.AnimMs >= 10)
        PuzzleAnimate(P, cells, PuzzleDeltas(cells, dx * P.TileW, dy * P.TileH))
    P.Busy := false

    if !PuzzleState.Games.Has(P.Hwnd)     ; closed mid-animation
        return 0

    P.History.Push({ Blank: P.Blank, Count: cells.Length })
    PuzzleCommit(P, cell)
    P.Moves += cells.Length
    if !P.StartTick
        P.StartTick := A_TickCount

    if PuzzleIsSolved(P)
        PuzzleWin(P)
    else {
        PuzzleUpdateStats(P)
        PuzzleRender(P)
    }
    return cells.Length
}

; The array surgery, with no animation, no bookkeeping and no legality check —
; the caller has already established that `cell` is in line with the blank.
; Shared by real moves and by the shuffle, which is why it does nothing else.
PuzzleCommit(P, cell) {
    PuzzleRC(P, P.Blank, &br, &bc)
    PuzzleRC(P, cell,    &cr, &cc)

    if (br = cr) {
        step := (cc > bc) ? 1 : -1
        Loop Abs(cc - bc) {
            k := A_Index
            P.Tiles[PuzzleIdx(P, br, bc + (k - 1) * step)] := P.Tiles[PuzzleIdx(P, br, bc + k * step)]
        }
    } else {
        step := (cr > br) ? 1 : -1
        Loop Abs(cr - br) {
            k := A_Index
            P.Tiles[PuzzleIdx(P, br + (k - 1) * step, bc)] := P.Tiles[PuzzleIdx(P, br + k * step, bc)]
        }
    }
    P.Tiles[cell] := 0
    P.Blank := cell
}

; ── Swap mode ─────────────────────────────────────────────────────────────────

; Swap the tiles in two orthogonally adjacent cells.  Returns true if it
; happened.  This is the whole rule set of the swap puzzle: no gap, no sliding
; group, just two neighbours trading places.
PuzzleSwap(P, a, b, animate := true, record := true) {
    if (P.Busy || P.Solved || P.Peeking || P.PeekLock)
        return false
    n := P.Cols * P.Rows
    if (a < 1 || b < 1 || a > n || b > n || a = b)
        return false
    if !PuzzleAdjacent(P, a, b)
        return false

    P.Busy := true
    if (animate && PuzzleCfg.AnimMs >= 10) {
        PuzzleRC(P, a, &ar, &ac)
        PuzzleRC(P, b, &br, &bc)
        d := Map()
        d[a] := { X: (bc - ac) * P.TileW, Y: (br - ar) * P.TileH }
        d[b] := { X: (ac - bc) * P.TileW, Y: (ar - br) * P.TileH }
        ; `a` last in the draw order so the tile you picked passes OVER the one
        ; it is trading with, rather than disappearing under it.
        PuzzleAnimate(P, [b, a], d)
    }
    P.Busy := false

    if !PuzzleState.Games.Has(P.Hwnd)      ; closed mid-animation
        return false

    t := P.Tiles[a]
    P.Tiles[a] := P.Tiles[b]
    P.Tiles[b] := t

    if record {
        P.History.Push({ A: a, B: b })
        P.Moves += 1
        if !P.StartTick
            P.StartTick := A_TickCount
    }
    P.Sel := 0                             ; a completed swap clears the pick

    if PuzzleIsSolved(P)
        PuzzleWin(P)
    else {
        PuzzleUpdateStats(P)
        PuzzleRender(P)
    }
    return true
}

; Orthogonal neighbours only — diagonals are not a move.
PuzzleAdjacent(P, a, b) {
    PuzzleRC(P, a, &ar, &ac)
    PuzzleRC(P, b, &br, &bc)
    return (Abs(ar - br) + Abs(ac - bc)) = 1
}

; A click in swap mode.  With nothing picked, the click picks.  With something
; picked: the same cell un-picks, an adjacent cell completes the swap, and
; anything else MOVES the pick rather than rejecting the click — misjudging
; which tiles are adjacent is the commonest slip, and silently doing nothing
; would just feel broken.
PuzzleSwapClick(P, cell) {
    if (P.Busy || P.Solved || P.Peeking || P.PeekLock)
        return
    if !P.Sel {
        P.Sel := cell
        PuzzleRender(P)
        return
    }
    if (cell = P.Sel) {
        P.Sel := 0
        PuzzleRender(P)
        return
    }
    if PuzzleAdjacent(P, P.Sel, cell) {
        PuzzleSwap(P, P.Sel, cell)
        return
    }
    P.Sel := cell
    PuzzleRender(P)
}

; Arrow keys.  The direction is the direction the TILE travels, which is the
; convention every sliding puzzle uses and the opposite of "move the gap":
; press Left and the tile to the RIGHT of the gap comes left into it.
;
; In swap mode the same key means "trade the picked tile with its neighbour that
; way", and the pick follows the tile, so holding a direction walks a tile
; across the board one trade at a time.  With nothing picked yet, the first
; arrow just picks the top-left cell to give you something to steer.
PuzzleArrow(P, dx, dy) {
    if (P.Mode = 'swap') {
        if !P.Sel {
            P.Sel := 1
            PuzzleRender(P)
            return
        }
        PuzzleRC(P, P.Sel, &sr, &sc)
        r := sr + dy, c := sc + dx
        if (r < 1 || r > P.Rows || c < 1 || c > P.Cols)
            return
        target := PuzzleIdx(P, r, c)
        keep   := target                   ; where the picked tile ends up
        if PuzzleSwap(P, P.Sel, target) {
            P.Sel := keep
            PuzzleRender(P)
        }
        return
    }
    PuzzleRC(P, P.Blank, &br, &bc)
    r := br - dy, c := bc - dx
    if (r < 1 || r > P.Rows || c < 1 || c > P.Cols)
        return
    PuzzleSlide(P, PuzzleIdx(P, r, c))
}

; Undo is free in both modes, and it is free for a pleasing reason: each move is
; its own inverse.  Sliding: if the gap was at B and you slid the group at C into
; it, sliding the group at B back is the identical operation, so the history only
; needs the previous blank position.  Swapping: trading two tiles twice puts them
; back, so the history only needs the pair.
PuzzleUndo(P) {
    if (P.Busy || P.Solved || !P.History.Length)
        return
    h := P.History.Pop()
    if (P.Mode = 'swap') {
        PuzzleSwap(P, h.A, h.B, true, false)   ; no record, no move count
        P.Moves := Max(0, P.Moves - 1)
        P.Sel := 0
    } else {
        PuzzleSlideNoRecord(P, h.Blank)
        P.Moves := Max(0, P.Moves - h.Count)
    }
    PuzzleUpdateStats(P)
    PuzzleRender(P)
}

; Same as PuzzleSlide but without pushing history (or it would undo the undo).
PuzzleSlideNoRecord(P, cell) {
    PuzzleRC(P, P.Blank, &br, &bc)
    PuzzleRC(P, cell,    &cr, &cc)
    if (br != cr && bc != cc)
        return
    P.Busy := true
    cells := []
    if (br = cr) {
        step := (cc > bc) ? 1 : -1
        Loop Abs(cc - bc)
            cells.Push(PuzzleIdx(P, br, bc + A_Index * step))
        dx := -step, dy := 0
    } else {
        step := (cr > br) ? 1 : -1
        Loop Abs(cr - br)
            cells.Push(PuzzleIdx(P, br + A_Index * step, bc))
        dx := 0, dy := -step
    }
    if (PuzzleCfg.AnimMs >= 10)
        PuzzleAnimate(P, cells, PuzzleDeltas(cells, dx * P.TileW, dy * P.TileH))
    P.Busy := false
    if !PuzzleState.Games.Has(P.Hwnd)
        return
    PuzzleCommit(P, cell)
    PuzzleRender(P)
}

; Solved.  The grid lines and the numbers go away and the picture is whole
; again — the payoff is meant to be visual, not a dialog box.
PuzzleWin(P) {
    P.Solved := true
    if P.StartTick
        P.Elapsed := (A_TickCount - P.StartTick) // 1000
    if P.Ticker
        SetTimer(P.Ticker, 0)
    P.Stats.SetFont('bold')
    PuzzleUpdateStats(P)
    PuzzleRender(P)
    ; Off on its own thread so the board is already repainted when it plays —
    ; SoundBeep blocks, and a fanfare over a stale board is a flat moment.
    if PuzzleCfg.WinSound
        SetTimer(PuzzleFanfare, -1)
}

PuzzleFanfare() {
    SoundBeep(659, 90)
    SoundBeep(880, 90)
    SoundBeep(1175, 170)
}

; ══════════════════════════════════════════════════════════════════════════════
; PEEK / NUMBERS / RESIZE / CLOSE
; ══════════════════════════════════════════════════════════════════════════════

; The Peek button latches (click again to hide); the Space hotkey is hold-to-
; peek.  Two mechanisms because they suit two moods, and they compose: the
; render only cares whether EITHER is on.
PuzzleTogglePeek(P) {
    if (P.Solved || P.Busy)
        return
    P.Sel := 0                            ; don't return to a stale highlight
    P.PeekLock := !P.PeekLock
    P.PeekBtn.Text := P.PeekLock ? 'Hide' : 'Peek'
    PuzzleRender(P)
}

PuzzleToggleNumbers(P) {
    if P.Busy
        return
    P.Numbers := !P.Numbers
    PuzzleBuildTiles(P)                  ; numbers are baked in, so rebuild
    PuzzleRender(P)
}

; Changing the grid means new tile dimensions, a new board size and a new
; window size, so it is cleaner to rebuild the game than to mutate it.  The
; original image is CLONED across first, then the old game (and its copy) is
; disposed — belt and braces against a half-built replacement leaving you with
; neither.
PuzzleRebuild(P, mode, cols, rows) {
    if P.Busy
        return
    if (mode = P.Mode && cols = P.Cols && rows = P.Rows)
        return                        ; nothing would change; don't wipe the board
    DllCall('gdiplus\GdipCloneImage', 'Ptr', P.Orig, 'Ptr*', &clone := 0)
    if !clone
        return
    x := y := ''
    if WinExist('ahk_id ' P.Hwnd)
        WinGetPos(&x, &y, , , 'ahk_id ' P.Hwnd)
    PuzzleDestroy(P)
    PuzzleCreate(clone, mode, cols, rows, x, y)
}

; Esc and the X button both come through here.  A half-solved board represents
; real work and there is no undo for closing, so it asks — but only when there
; is something to lose.  Confirming the close of an untouched or already-solved
; board would just be a dialog in the way.
;
; PuzzleDestroy stays the unconditional teardown, because PuzzleRebuild uses it
; to swap a board out mid-flight and must not be interrupted by a prompt.
PuzzleConfirmClose(P) {
    if P.Busy
        return
    if (P.Solved || !P.Moves) {
        PuzzleDestroy(P)
        return
    }
    ; +OwnDialogs is per-thread, so it has to be asked for again here — this is
    ; a hotkey or Gui-event thread, not the one that built the window.
    try P.Gui.Opt('+OwnDialogs')
    answer := MsgBox('Close this puzzle?`n`n'
                   . P.Moves ' move' (P.Moves = 1 ? '' : 's') ' will be lost.'
                   , 'Snip Puzzle', 0x4 | 0x20 | 0x1000)   ; Yes/No, question, topmost
    if (answer = 'Yes')
        PuzzleDestroy(P)
}

; Teardown.  Deregister FIRST so any in-flight animation frame or timer tick
; sees the window is gone and bails, then release GDI+ objects, then the window.
;
; The Picture control's current HBITMAP is deliberately left to the control's
; own destruction — the same thing ScreenSnip does for its snips.  Every
; PREVIOUS frame's bitmap was freed as it was replaced (see PuzzlePush), so
; there is at most one outstanding handle per closed puzzle.
PuzzleDestroy(P) {
    if !PuzzleState.Games.Has(P.Hwnd)
        return
    PuzzleState.Games.Delete(P.Hwnd)
    try PuzzleState.Pics.Delete(P.Pic.Hwnd)
    if P.Ticker
        try SetTimer(P.Ticker, 0)

    PuzzleFreeTiles(P)
    if P.Gfx
        try DllCall('gdiplus\GdipDeleteGraphics', 'Ptr', P.Gfx)
    for b in [P.Back, P.Img, P.Orig]
        if b
            try GDIp.DisposeImage(b)
    P.Gfx := 0, P.Back := 0, P.Img := 0, P.Orig := 0

    try P.Gui.Destroy()
}

; ══════════════════════════════════════════════════════════════════════════════
; RENDERING
; ══════════════════════════════════════════════════════════════════════════════

; One frame.  Clears the back buffer to the board colour, blits whichever tiles
; are visible, then hands the result to the Picture control.  Peeking and solved
; both bypass the tiles entirely and draw the untouched board-sized image, which
; is why the grid appears to dissolve at the moment you win.
PuzzleRender(P) {
    if !PuzzleState.Games.Has(P.Hwnd)     ; closed underneath us
        return
    gfx := P.Gfx
    if !gfx
        return

    DllCall('gdiplus\GdipGraphicsClear', 'Ptr', gfx, 'UInt', 0xFF000000 | PuzzleCfg.BoardColor)

    if (P.Solved || P.Peeking || P.PeekLock) {
        PuzzleDrawPart(gfx, P.Img, 0, 0, P.BoardW, P.BoardH, 0, 0, P.BoardW, P.BoardH)
        if P.Solved
            PuzzleBanner(P, gfx, 'Solved!   ' P.Moves ' moves   ·   ' PuzzleTimeStr(P.Elapsed))
        else
            PuzzleBanner(P, gfx, 'Peeking…')
    } else {
        Loop P.Cols * P.Rows {
            i := A_Index
            t := P.Tiles[i]
            if !t
                continue                  ; the gap, in slide mode
            if (P.AnimSet && P.AnimSet.Has(i))
                continue                  ; drawn below, at its animated offset
            PuzzleBlit(P, gfx, t, i, 0, 0)
        }
        ; Each moving tile carries its OWN delta now, rather than the whole group
        ; sharing one.  A slide passes the same delta for every cell; a swap
        ; passes two opposite ones so the pair crosses over.
        if P.AnimSet {
            for i in P.AnimOrder {
                d := P.AnimSet[i]
                PuzzleBlit(P, gfx, P.Tiles[i], i
                         , Round(d.X * P.AnimProg), Round(d.Y * P.AnimProg))
            }
        }
        ; The picked tile, drawn last so the outline sits above its neighbours.
        ; Skipped mid-animation: the tile is in flight and the ring would be
        ; hanging over the cell it already left.
        if (P.Sel && !P.AnimSet)
            PuzzleDrawSelection(P, gfx, P.Sel)
    }

    PuzzlePush(P)
}

; The "this one is picked" ring.  Two rects, a bright inner and a dark outer, so
; it reads against both a light and a dark tile without needing to know what the
; picture underneath looks like.
PuzzleDrawSelection(P, gfx, idx) {
    PuzzleRC(P, idx, &r, &c)
    x := (c - 1) * P.TileW + P.Gap
    y := (r - 1) * P.TileH + P.Gap
    w := P.TileDrawW
    h := P.TileDrawH
    PuzzleDrawEdge(gfx, 0xC0000000, x - 1, y - 1, w + 2, h + 2)
    PuzzleDrawEdge(gfx, 0xFF000000 | PuzzleCfg.SelColor, x,     y,     w,     h)
    PuzzleDrawEdge(gfx, 0xFF000000 | PuzzleCfg.SelColor, x + 1, y + 1, w - 2, h - 2)
    PuzzleDrawEdge(gfx, 0x60000000, x + 2, y + 2, w - 4, h - 4)
}

; Draw one tile into cell `idx`, offset by (offX, offY) px for animation.
PuzzleBlit(P, gfx, tileId, idx, offX, offY) {
    if (!tileId || !P.TileBmp.Has(tileId))
        return
    PuzzleRC(P, idx, &r, &c)
    x := (c - 1) * P.TileW + P.Gap + offX
    y := (r - 1) * P.TileH + P.Gap + offY
    DllCall('gdiplus\GdipDrawImageRectI', 'Ptr', gfx, 'Ptr', P.TileBmp[tileId]
          , 'Int', x, 'Int', y, 'Int', P.TileDrawW, 'Int', P.TileDrawH)
}

; A translucent strip across the bottom for the solved / peeking message.
PuzzleBanner(P, gfx, text) {
    h := Max(30, Min(52, P.BoardH // 9))
    y := P.BoardH - h
    PuzzleFillRect(gfx, 0xB4000000, 0, y, P.BoardW, h)
    PuzzleDrawText(gfx, text, 0, y, P.BoardW, h, h * 0.46, 0xFFFFFFFF)
}

; Hand the finished back buffer to the Picture control.
;
; STM_SETIMAGE installs the new bitmap AND returns the one it replaced, which is
; ours to delete — miss that and a long game leaks a GDI bitmap per frame, which
; on a 60fps animation is a few thousand handles a minute.  (Same reason
; RenderSnipFast in ScreenSnip.ahk deletes the return value.)
PuzzlePush(P) {
    hbm := GDIp.CreateHBITMAPFromBitmap(P.Back)
    if !hbm
        return
    old := SendMessage(0x0172, 0, hbm, P.Pic.Hwnd)   ; STM_SETIMAGE, IMAGE_BITMAP
    if old
        DllCall('DeleteObject', 'Ptr', old)
}

; Run the slide animation.  Synchronous on purpose: it is under a tenth of a
; second, the Busy flag keeps input out for the duration, and a state-machine
; timer would triple the size of this file for no gain.  The loop re-checks the
; registry every frame so closing the window mid-slide is clean rather than a
; paint into a destroyed control.
; `order` is the cells to move, back-to-front for drawing.  `deltas` maps each
; of those cells to its own {X, Y} travel in PIXELS — a slide hands every cell
; the same one, a swap hands the two tiles opposite ones.
PuzzleAnimate(P, order, deltas) {
    P.AnimOrder := order
    P.AnimSet   := deltas

    ms := Max(10, PuzzleCfg.AnimMs)       ; never 0 — it's a divisor below
    t0 := A_TickCount

    Loop {
        if !PuzzleState.Games.Has(P.Hwnd)
            break
        prog := (A_TickCount - t0) / ms
        if (prog >= 1)
            break
        P.AnimProg := 1 - (1 - prog) * (1 - prog)   ; ease-out: fast off the mark
        PuzzleRender(P)
        Sleep 8
    }

    P.AnimSet := 0, P.AnimOrder := 0, P.AnimProg := 0
}

; Build a delta map where every cell travels the same distance — the slide case.
PuzzleDeltas(cells, dxPx, dyPx) {
    d := Map()
    for i in cells
        d[i] := { X: dxPx, Y: dyPx }
    return d
}

; ══════════════════════════════════════════════════════════════════════════════
; HUD
; ══════════════════════════════════════════════════════════════════════════════

; Half-second tick, per game.  Takes the window handle rather than the puzzle
; object so a stale timer can discover that its game is gone and switch itself
; off, instead of holding a reference to a corpse.
PuzzleTick(hwnd) {
    if !PuzzleState.Games.Has(hwnd) {
        SetTimer(, 0)                     ; turn off the timer that called us
        return
    }
    P := PuzzleState.Games[hwnd]
    if (P.Solved || P.Busy)
        return
    PuzzleUpdateStats(P)
}

PuzzleUpdateStats(P) {
    if P.Solved {
        P.Stats.Value := 'Solved in ' P.Moves ' · ' PuzzleTimeStr(P.Elapsed)
        return
    }
    P.Elapsed := P.StartTick ? (A_TickCount - P.StartTick) // 1000 : 0
    P.Stats.Value := 'Moves ' P.Moves '  ·  ' PuzzleTimeStr(P.Elapsed)
}

PuzzleTimeStr(secs) {
    return Format('{}:{:02}', secs // 60, Mod(secs, 60))
}

PuzzleShowHelp(P) {
    static slideTxt := "
(
Snip Puzzle — a SLIDING-tile puzzle cut from your snip.

One tile is missing.  Click any tile in the blank's row
or column and it slides into the gap, and so does
everything between them, so a click three cells away
moves three tiles at once.

  Click tile        Slide it (and its neighbours) over
  Arrow keys        Slide one tile that way into the gap
  Ctrl + Z          Undo the last slide
  Space (hold)      Peek at the finished picture
  N                 Numbers on the tiles, on / off
  R                 Shuffle and start over
  Right-click       Menu — grid size, puzzle type, more
  F1                This help
  Esc               Close the puzzle

The shuffle is made of real slides, so the board is
always solvable.  Solve it and the seams disappear.
)"

    static swapTxt := "
(
Snip Puzzle — a SWAPPING-tile puzzle cut from your snip.

No tile is missing.  Click a tile to pick it up, then
click one of its four neighbours to trade places.  Only
neighbours: diagonals and distant tiles are not a move.
Clicking a tile that isn't adjacent just moves the pick
there instead.

  Click, click      Pick a tile, then a neighbour to swap
  Click the pick    Put it back down
  Arrow keys        Swap the picked tile that way
  Ctrl + Z          Undo the last swap
  Space (hold)      Peek at the finished picture
  N                 Numbers on the tiles, on / off
  R                 Shuffle and start over
  Right-click       Menu — grid size, puzzle type, more
  F1                This help
  Esc               Close the puzzle

Any arrangement of a swap board can be solved, so this
one is shuffled completely at random.
)"

    static tail := "
(

The snip it came from stays open as your reference.
Switch between slide and swap on the right-click menu.
Settings live in the [Puzzle] section of
Data\snipSettings.ini.
)"

    txt := ((P.Mode = 'swap') ? swapTxt : slideTxt) tail
    MsgBox(txt, 'Snip Puzzle — Help', 4096)
}

; ══════════════════════════════════════════════════════════════════════════════
; INPUT
; ══════════════════════════════════════════════════════════════════════════════

; Board clicks.  ScreenSnip's own WM_LBUTTONDOWN monitor runs first, finds a
; window that isn't a snip and returns an empty string, so the message reaches
; us.  We return 0 to consume it — nothing else wants a click on the board, and
; leaving it to travel on would let the Static take focus for no reason.
PuzzleWM_LBUTTONDOWN(wParam, lParam, msg, hwnd) {
    if !PuzzleState.Pics.Has(hwnd)
        return                            ; empty: pass it along
    gh := PuzzleState.Pics[hwnd]
    if !PuzzleState.Games.Has(gh)
        return
    P := PuzzleState.Games[gh]

    ; Client coords, low/high word, sign-extended — they can legitimately be
    ; negative when a drag leaves the control.
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if (x > 0x7FFF)
        x -= 0x10000
    if (y > 0x7FFF)
        y -= 0x10000

    if (P.PeekLock) {                     ; click anywhere to stop peeking
        PuzzleTogglePeek(P)
        return 0
    }
    ; Control pixels -> board pixels.  A no-op whenever the two agree, which is
    ; the normal case; see the measurement in PuzzleCreate.
    if (P.ClientW != P.BoardW)
        x := Round(x * P.BoardW / P.ClientW)
    if (P.ClientH != P.BoardH)
        y := Round(y * P.BoardH / P.ClientH)

    if (x < 0 || y < 0 || x >= P.BoardW || y >= P.BoardH)
        return 0
    c := x // P.TileW + 1
    r := y // P.TileH + 1
    ; Guard the edge: a click on the last pixel column of a board whose width
    ; isn't an exact multiple would index one cell past the grid.
    c := Max(1, Min(P.Cols, c))
    r := Max(1, Min(P.Rows, r))
    if (P.Mode = 'swap')
        PuzzleSwapClick(P, PuzzleIdx(P, r, c))
    else
        PuzzleSlide(P, PuzzleIdx(P, r, c))
    return 0
}

; True when the active window is a puzzle board — the #HotIf context below.
; A registry lookup rather than a title match, so the window title is free to
; say whatever is useful and a stray window called "Snip Puzzle" somewhere else
; can't capture the keys.
PuzzleActive() {
    hwnd := WinExist('A')
    return hwnd ? PuzzleState.Games.Has(hwnd) : false
}

; The active puzzle, or 0.  Every hotkey below goes through this.
PuzzleCurrent() {
    hwnd := WinExist('A')
    return PuzzleState.Games.Has(hwnd) ? PuzzleState.Games[hwnd] : 0
}

PuzzleKeyArrow(dx, dy) {
    if (P := PuzzleCurrent())
        PuzzleArrow(P, dx, dy)
}

; Hold-to-peek.  KeyWait blocks this thread only; the Busy/Peeking flags keep
; the board inert while the picture is up.
PuzzleKeyPeek() {
    P := PuzzleCurrent()
    if (!P || P.Solved || P.Busy || P.PeekLock)
        return
    P.Peeking := true
    PuzzleRender(P)
    KeyWait('Space')
    if !PuzzleState.Games.Has(P.Hwnd)
        return
    P.Peeking := false
    PuzzleRender(P)
}

PuzzleKeySimple(what) {
    P := PuzzleCurrent()
    if !P
        return
    switch what {
        case 'shuffle': PuzzleNewGame(P)
        case 'numbers': PuzzleToggleNumbers(P)
        case 'undo':    PuzzleUndo(P)
        case 'help':    PuzzleShowHelp(P)
        case 'close':   PuzzleConfirmClose(P)
        case 'menu':    PuzzleShowMenu(P.Gui)
    }
}

; ── Hotkeys, scoped to a puzzle window ────────────────────────────────────────
; Arrow keys and the plain letters are safe to claim here because the context
; function limits them to a board that is actually on screen and focused.  They
; are consumed rather than passed through, which also stops the arrows from
; walking focus around the buttons underneath the board.
#HotIf PuzzleActive()
Left::      PuzzleKeyArrow(-1,  0) ; hide
Right::     PuzzleKeyArrow(+1,  0) ; hide
Up::        PuzzleKeyArrow( 0, -1) ; hide
Down::      PuzzleKeyArrow( 0, +1) ; hide
Space::     PuzzleKeyPeek() ; hide
r::         PuzzleKeySimple('shuffle') ; hide
n::         PuzzleKeySimple('numbers') ; hide
^z::        PuzzleKeySimple('undo') ; hide
F1::        PuzzleKeySimple('help') ; hide
Esc::       PuzzleKeySimple('close') ; hide
AppsKey::   PuzzleKeySimple('menu') ; hide
; Enter is deliberately swallowed.  The Picture can't take focus, so the Shuffle
; button gets it when the window opens — and an absent-minded Enter would
; otherwise throw away a half-solved board with no warning and no undo.
Enter::        return ; hide
NumpadEnter::  return ; hide
#HotIf

; ══════════════════════════════════════════════════════════════════════════════
; GDI+ HELPERS
; ══════════════════════════════════════════════════════════════════════════════
; Deliberately self-contained rather than reaching for ScreenSnip's private
; _DrawImageRectRect and friends: those are internal to the shadow code, and a
; module that only leans on the documented GDIp class plus its own helpers is
; one that can't be broken by a refactor over there.

PuzzleNewBitmap(w, h) {
    ; 0x26200A = PixelFormat32bppARGB, straight (non-premultiplied) alpha — the
    ; same constant ScreenSnip's drop-shadow code uses.  It MUST be a 32bpp
    ; format with the alpha flag: 0x21808 looks similar but is 24bppRGB, and a
    ; bitmap with no alpha channel zero-fills to opaque BLACK rather than to
    ; transparent, so anything not painted shows up as a black rectangle.
    DllCall('gdiplus\GdipCreateBitmapFromScan0', 'Int', w, 'Int', h
          , 'Int', 0, 'Int', 0x26200A, 'Ptr', 0, 'Ptr*', &p := 0)
    return p
}

PuzzleNewGfx(pBmp) {
    DllCall('gdiplus\GdipGetImageGraphicsContext', 'Ptr', pBmp, 'Ptr*', &g := 0)
    if g {
        DllCall('gdiplus\GdipSetInterpolationMode', 'Ptr', g, 'Int', 7)  ; HQ bicubic
        DllCall('gdiplus\GdipSetSmoothingMode',     'Ptr', g, 'Int', 4)  ; antialias
        DllCall('gdiplus\GdipSetPixelOffsetMode',   'Ptr', g, 'Int', 2)  ; HQ
        DllCall('gdiplus\GdipSetTextRenderingHint', 'Ptr', g, 'Int', 4)  ; AA grid-fit
    }
    return g
}

; dst rect <- src rect, UnitPixel.  Explicit rects everywhere means the bitmaps'
; DPI settings never get a chance to scale anything behind our back.
PuzzleDrawPart(gfx, pImg, dx, dy, dw, dh, sx, sy, sw, sh) {
    DllCall('gdiplus\GdipDrawImageRectRectI', 'Ptr', gfx, 'Ptr', pImg
          , 'Int', dx, 'Int', dy, 'Int', dw, 'Int', dh
          , 'Int', sx, 'Int', sy, 'Int', sw, 'Int', sh
          , 'Int', 2, 'Ptr', 0, 'Ptr', 0, 'Ptr', 0)
}

PuzzleFillRect(gfx, argb, x, y, w, h) {
    DllCall('gdiplus\GdipCreateSolidFill', 'UInt', argb, 'Ptr*', &br := 0)
    if !br
        return
    DllCall('gdiplus\GdipFillRectangleI', 'Ptr', gfx, 'Ptr', br
          , 'Int', x, 'Int', y, 'Int', w, 'Int', h)
    DllCall('gdiplus\GdipDeleteBrush', 'Ptr', br)
}

PuzzleDrawEdge(gfx, argb, x, y, w, h) {
    DllCall('gdiplus\GdipCreatePen1', 'UInt', argb, 'Float', 1, 'Int', 2, 'Ptr*', &pen := 0)
    if !pen
        return
    DllCall('gdiplus\GdipDrawRectangleI', 'Ptr', gfx, 'Ptr', pen
          , 'Int', x, 'Int', y, 'Int', w - 1, 'Int', h - 1)
    DllCall('gdiplus\GdipDeletePen', 'Ptr', pen)
}

; Centred text in a box.  Font families and formats are cached because tile
; rebuilds create one string per tile and a 6x6 board would otherwise churn 35
; font objects for nothing.
PuzzleDrawText(gfx, text, x, y, w, h, sizePx, argb) {
    font := PuzzleFont(sizePx)
    if !font                              ; no usable font — skip the label
        return
    rect := Buffer(16, 0)
    NumPut('Float', x, 'Float', y, 'Float', w, 'Float', h, rect)
    DllCall('gdiplus\GdipCreateSolidFill', 'UInt', argb, 'Ptr*', &br := 0)
    if !br
        return
    DllCall('gdiplus\GdipDrawString', 'Ptr', gfx, 'WStr', String(text), 'Int', -1
          , 'Ptr', font, 'Ptr', rect, 'Ptr', PuzzleStrFmt(), 'Ptr', br)
    DllCall('gdiplus\GdipDeleteBrush', 'Ptr', br)
}

PuzzleFont(sizePx) {
    static fam := 0, fonts := Map()
    if !fam {
        DllCall('gdiplus\GdipCreateFontFamilyFromName', 'WStr', 'Segoe UI', 'Ptr', 0, 'Ptr*', &f := 0)
        if !f
            DllCall('gdiplus\GdipGetGenericFontFamilySansSerif', 'Ptr*', &f := 0)
        fam := f
    }
    key := Round(sizePx)
    if fonts.Has(key)
        return fonts[key]
    ; style 1 = bold, unit 2 = UnitPixel
    DllCall('gdiplus\GdipCreateFont', 'Ptr', fam, 'Float', key
          , 'Int', 1, 'Int', 2, 'Ptr*', &font := 0)
    return fonts[key] := font
}

PuzzleStrFmt() {
    static fmt := 0
    if fmt
        return fmt
    DllCall('gdiplus\GdipCreateStringFormat', 'Int', 0, 'Int', 0, 'Ptr*', &f := 0)
    DllCall('gdiplus\GdipSetStringFormatAlign',     'Ptr', f, 'Int', 1)   ; centre
    DllCall('gdiplus\GdipSetStringFormatLineAlign', 'Ptr', f, 'Int', 1)   ; middle
    return fmt := f
}
