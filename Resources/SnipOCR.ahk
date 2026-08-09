#Requires AutoHotkey v2
;               SnipOCR.ahk  —  OCR add-on module for ScreenSnip.ahk
;
; Made by kunkel321 via Claude AI.
; Version date: 7-13-2026 
;
; Adds three context-menu actions to each floating snip:
;
;   OCR > Copy Text (Windows)      — fast, zero-install, uses Windows.Media.Ocr
;   OCR > Copy Text (PaddleOCR)    — slower, more accurate, offline engine
;   OCR > Copy Table (PaddleOCR)   — reconstructs a table as TSV (pastes into Excel)
;
; ── SETUP ─────────────────────────────────────────────────────────────────────
;
; WINDOWS OCR path (optional but recommended — it's free and instant):
;   Requires Descolada's OCR.ahk library.  Download OCR.ahk from
;     https://github.com/Descolada/OCR
;   and drop it in  Resources\  next to THIS file.  Then uncomment the #Include
;   below.  In AHK v2 a relative #Include resolves against the folder of the
;   file containing the directive, so no path is needed — "#Include OCR.ahk"
;   finds it beside this one.
;   If it's absent, the Windows menu item simply reports that it's not set up;
;   everything else still works.
;
; PADDLEOCR path (only needed if you want tables / higher accuracy):
;   1. Download PaddleOCR-json (Windows x64) from
;        https://github.com/hiroi-sora/PaddleOCR-json/releases/latest
;   2. Unzip it into  Resources\  as well.  You want the folder that contains
;      PaddleOCR-json.exe AND a "models" subfolder — they MUST stay together.
;      OcrRunPaddle launches the engine with that folder as its working
;      directory, which is how LangConfig ("models\config_en.txt") resolves.
;   3. If you put it somewhere else, point OcrCfg.PaddleExe (below) at the .exe.
;   4. Note: requires a CPU with AVX (any modern Core/Ryzen).  If yours lacks
;      it, use RapidOCR-json instead — same JSON output, same code works.
;
; ── OPT-OUT CONTRACT ──────────────────────────────────────────────────────────
;
; Included with  #Include *i Resources\SnipOCR.ahk , the same as SnipAI.ahk and
; SnipImgur.ahk.  Delete this file (or comment out that line) and the OcrCfg
; class never comes into existence, so the IsSet(OcrCfg) test where the OCR
; submenu is built skips its three items and ScreenSnip runs normally.
;
; This file contains functions and a config class only; no top-level executable
; code.  #Include it at the BOTTOM of ScreenSnip.ahk.
;
; ══════════════════════════════════════════════════════════════════════════════

#Include OCR.ahk       ; <-- uncomment once you've downloaded Descolada's OCR.ahk


; ══════════════════════════════════════════════════════════════════════════════
; USER SETTINGS
; (Static class props initialize at script load, so this is safe to #Include
;  after the auto-execute section.)
; ══════════════════════════════════════════════════════════════════════════════
class OcrCfg {

    ; ── PaddleOCR engine ──────────────────────────────────────────────────────
    ; Full path to PaddleOCR-json.exe.  The "models" folder must be its sibling.
    ; A_ScriptDir is the MAIN script's folder, not this file's, so this stays
    ; anchored to the top-level ScreenSnip folder wherever this module lives.
    static PaddleExe := A_ScriptDir '\Resources\PaddleOCR-json\PaddleOCR-json.exe'

    ; Language config, RELATIVE to the engine folder.  The engine defaults to
    ; Simplified Chinese if this is blank, so leave it set for English.
    ; Others shipped in the release: config_chinese_cht.txt, config_japan.txt,
    ; config_korean.txt.
    static LangConfig := 'models\config_en.txt'

    ; ── Image preprocessing ───────────────────────────────────────────────────
    ; Upscale factor before OCR.  Screen text is typically 10-14px tall, which
    ; is right at the edge of what OCR engines handle well.  Bicubic upscaling
    ; to 2-3x makes a large accuracy difference and costs almost nothing.
    ; 1 = disable.
    static Upscale := 3

    ; Paddle DOWNSIZES any image whose long edge exceeds this — which silently
    ; undoes our upscaling and is a very easy way to sabotage yourself.  A 3x
    ; upscale of a modest snip lands around 5000px, so a fixed 2880 here would
    ; shrink it straight back to an effective 1.7x.
    ;
    ; 0 = AUTO: size the limit to the image so no downscaling ever happens.
    ; This is what you want.  Set a fixed number only to deliberately cap it.
    static LimitSideLen := 0

    ; Safety ceiling for AUTO mode.  Detection cost scales with area, so a huge
    ; snip at 3x could get slow.  If the image exceeds this, Paddle will shrink
    ; it (and you should lower Upscale instead).
    static MaxSideLen := 6144

    ; If the snip has been fine-rotated (Alt+Left/Right, e.g. to deskew tilted
    ; scanned text), the rotation exposes triangular corners that have to be
    ; filled with something.  On screen that's the magenta color key; for OCR we
    ; use white, so the corners read as blank page instead of as content.
    ; Set to 0x000000 if you routinely OCR light-on-dark text.
    static RotateFill := 0xFFFFFF

    ; ── Result filtering ──────────────────────────────────────────────────────
    ; Discard text blocks whose confidence is below this (0.0-1.0).
    ;
    ; DEFAULT IS 0 (keep everything), and that is deliberate.  A confidence
    ; filter would earn its keep if a junk block could SHIFT your data — but it
    ; can't: every block gets snapped to a column anchor, so dropping one leaves
    ; a hole and moves nothing.  Filtering therefore buys no safety and costs
    ; real cells.  And a hole is worse than a typo: a misread value is visible
    ; and fixable, whereas a dropped one just looks like a legitimately empty
    ; cell.  On a real 21x20 table, MinScore 0.5 silently discarded 41% of it.
    ;
    ; Only raise this if you're OCRing prose and want to suppress noise.
    static MinScore := 0.0

    ; If > 0, append '?' to any cell whose confidence is below this, so you can
    ; find the shaky ones in Excel with Ctrl+F.  Note this makes those cells
    ; text rather than numbers, so leave it at 0 for tables you'll compute on.
    static MarkBelow := 0.0

    ; ── Table reconstruction tuning ───────────────────────────────────────────
    ; PaddleOCR returns loose text blocks with bounding boxes, NOT a table.  We
    ; rebuild the grid by clustering those boxes.  Both tolerances are expressed
    ; as a fraction of the median text-block HEIGHT, so they scale automatically
    ; with font size and with the Upscale factor above.
    ;
    ; RowTol   — two blocks land in the same ROW if their vertical centers are
    ;            within (RowTol x medianHeight) of each other.  Raise if a single
    ;            visual row is being split in two; lower if two rows are merging.
    static RowTol := 0.60
    ;
    ; ColTol   — two blocks land in the same COLUMN if their left edges are
    ;            within (ColTol x medianHeight) of each other.  Raise if one
    ;            column is being split; lower if two columns are merging.
    static ColTol := 1.20

    ; ── Wrapped-cell reflow ───────────────────────────────────────────────────
    ; A cell whose text wraps onto several lines arrives as several separate
    ; blocks, so a 5-row table can come out as 31 rows.  Reflow stitches them
    ; back together.
    ;
    ; How it decides: it measures the WHITESPACE between consecutive rows (not
    ; centre-to-centre pitch, which is contaminated by text height).  In a table
    ; with wrapped cells those gaps are strongly bimodal — small ones are line
    ; spacing inside a cell, large ones are actual row borders.  In a table with
    ; no wrapping they're all the same size.  So we split the gaps into two
    ; groups and only reflow if the large group is clearly larger than the small
    ; one; otherwise every row is left alone.  On real tables the separation is
    ; obvious (ratio 2.3 for a wrapped rubric, 1.6 for an unwrapped number grid).
    static Reflow := true

    ; How much bigger the "row border" gaps must be than the "line spacing" gaps
    ; before we believe the table has wrapped cells.  Lower = more eager to
    ; reflow.  Below about 1.6 you risk merging genuinely separate rows.
    static ReflowRatio := 1.8

    ; Anchor (key) column — the one that holds a label on every logical row, and
    ; is blank on wrapped continuation lines.  Column 1 in almost every table.
    ;
    ; This exists because GAPS ALONE ARE NOT ENOUGH, and a real document proved
    ; it: on a scanned IEP service grid, an 85px gap sat INSIDE a cell (a faint
    ; dash the engine never detected left a hole) while a genuine row border was
    ; only 39px.  The geometry lied.  But column 1 — "1,2 / 2 / ALL / 3 / 4" —
    ; did not.  So a new logical row must satisfy BOTH tests: a big gap above it
    ; AND content in the anchor column.
    ;
    ; Set to 0 to use gaps alone.  Falls back to gaps automatically if the anchor
    ; column turns out to be too sparse to group by.
    static ReflowAnchorCol := 1

    ; A gap counts as "big" if it exceeds this multiple of the median row gap.
    static ReflowGapFactor := 1.8

    ; ── "This isn't a table" guard ────────────────────────────────────────────
    ; If more than this fraction of the text sits in one column, the snip is
    ; almost certainly prose or a form, not a grid — and Copy Text will do a far
    ; better job than Copy Table.  Measured on real documents: a numeric grid ran
    ; 7%, a rubric 27%, a scanned service matrix 40%, but a one-column form with
    ; bullets hit 77%.  Set to 0 to disable the prompt.
    static NotATableWarn := 0.60

    ; ── Debugging ─────────────────────────────────────────────────────────────
    ; true = write three files next to this script, stamped with the run time:
    ;   SnipOCR_<stamp>_image.png   what the engine was actually fed
    ;   SnipOCR_<stamp>_raw.json    what the engine returned
    ;   SnipOCR_<stamp>_blocks.txt  how we clustered it (the useful one)
    ; The blocks dump tells you whether a wrong table is the ENGINE misreading
    ; the text or the CLUSTERING misplacing it — you can't tell from the TSV.
    static Debug := False
}


; Module-internal state.  OcrSnipToPng records the final image size here so
; OcrRunPaddle can size limit_side_len to it (see OcrCfg.LimitSideLen).
class OcrState {
    static ImgW := 0
    static ImgH := 0
    static Stamp := ''      ; per-run timestamp, so debug files don't clobber each other
    static ReflowRatio := 0 ; measured gap-separation ratio, for the debug dump
    static ReflowSplit := 0 ; px threshold that separated the two gap groups
    static ReflowNote := ''  ; human-readable account of what reflow decided
}

; Debug files are stamped per run.  They used to use fixed names, which meant
; each OCR clobbered the last one's evidence — very easy to end up comparing a
; run against itself without noticing.
OcrDebugPath(suffix) {
    if (OcrState.Stamp = '')
        OcrState.Stamp := FormatTime(, 'yyyyMMdd_HHmmss')
    return SnipDataPath('SnipOCR_' OcrState.Stamp '_' suffix)
}


; ══════════════════════════════════════════════════════════════════════════════
; PUBLIC ENTRY POINTS  (called from SnipMenu_Handler in ScreenSnip.ahk)
; ══════════════════════════════════════════════════════════════════════════════

; ── Windows.Media.Ocr — fast, no bundled engine, plain text only ──────────────
SnipOcrWindowsText(Hwnd) {
    if !IsSet(OCR) {
        MsgBox('Windows OCR is not set up.`n`n'
             . 'Download OCR.ahk from  https://github.com/Descolada/OCR ,'
             . ' place it next to ScreenSnip.ahk, then uncomment the'
             . ' #Include line near the top of SnipOCR.ahk.'
             , 'ScreenSnip OCR', 'Iconi')
        return
    }

    if !(png := OcrSnipToPng(Hwnd))
        return

    OcrToolTip('Reading text...')
    try {
        result := OCR.FromFile(png)
        text := Trim(result.Text, ' `t`r`n')
    } catch as e {
        OcrToolTip()
        MsgBox('Windows OCR failed:`n`n' e.Message, 'ScreenSnip OCR', 'Icon!')
        return
    } finally {
        if !OcrCfg.Debug
            try FileDelete(png)
    }

    OcrToolTip()
    if (text = '') {
        OcrToolTip('No text found', 1200)
        return
    }
    A_Clipboard := text
    OcrToolTip('Copied ' OcrCountLines(text) ' line(s) to clipboard', 1400)
}

; ── PaddleOCR — plain text, in reading order ──────────────────────────────────
SnipOcrPaddleText(Hwnd) {
    if !(blocks := OcrPaddleBlocks(Hwnd))
        return

    lines := OcrBlocksToLines(blocks)
    A_Clipboard := OcrJoin(lines, '`r`n')
    OcrToolTip('Copied ' lines.Length ' line(s) to clipboard', 1400)
}

; Blocks -> one line of text per visual row, in reading order.
OcrBlocksToLines(blocks) {
    lines := []
    for row in OcrGroupIntoRows(blocks) {
        parts := []
        for b in row
            parts.Push(b.text)
        lines.Push(OcrJoin(parts, ' '))
    }
    return lines
}

; ── PaddleOCR — reconstruct a table and copy as TSV ───────────────────────────
SnipOcrPaddleTable(Hwnd) {
    if !(blocks := OcrPaddleBlocks(Hwnd))
        return

    rows := OcrGroupIntoRows(blocks)
    cols := OcrFindColumns(rows)

    ; Is this actually a table?  Prose and forms put nearly all their text in one
    ; column; a real grid spreads it out.  Copy Text does a far better job on
    ; those, so offer it rather than silently producing a mangled grid.
    dens := OcrColumnDensity(rows, cols)
    if (OcrCfg.NotATableWarn > 0) && (dens > OcrCfg.NotATableWarn) {
        answer := MsgBox('This snip does not look much like a table — '
                       . Round(dens * 100) '% of the text sits in a single column, '
                       . 'which is what prose or a form looks like rather than a grid.'
                       . '`r`n`r`nCopy it as plain text instead?'
                       , 'ScreenSnip OCR', 0x4 + 0x20)      ; Yes/No, question icon
        if (answer = 'Yes') {
            txt := OcrBlocksToLines(blocks)
            A_Clipboard := OcrJoin(txt, '`r`n')
            OcrToolTip('Copied ' txt.Length ' line(s) of text to clipboard', 1400)
            return
        }
    }

    grid := OcrBuildGrid(rows, cols)
    final := OcrCfg.Reflow ? OcrReflowGrid(grid, rows) : grid

    lines := []
    for cells in final
        lines.Push(OcrJoin(cells, '`t'))

    ; Nothing is dropped any more (MinScore defaults to 0), so tell the user how
    ; many cells are shaky.  Those are the ones to eyeball against the original —
    ; the table's SHAPE is reliable; individual readings may not be.
    shaky := 0
    for b in blocks
        if (b.score < 0.6)
            shaky++

    A_Clipboard := OcrJoin(lines, '`r`n')
    OcrToolTip('Copied ' final.Length ' x ' cols.Length ' table'
             . (final.Length < rows.Length
                  ? ' (' rows.Length ' lines reflowed into ' final.Length ' rows)' : '')
             . (shaky ? ' — ' shaky ' cell(s) low-confidence, worth checking' : '')
             , 2500)
}


; ══════════════════════════════════════════════════════════════════════════════
; PADDLEOCR ENGINE PLUMBING
; ══════════════════════════════════════════════════════════════════════════════

; Run a snip through PaddleOCR and return an array of text blocks:
;   { text, x, y, w, h, cx, cy, score }
; Coordinates are in UPSCALED image space, which is fine — all the clustering
; below is relative, and the tolerances scale with the text height.
; Returns 0 (falsy) on failure or empty result; messages the user itself.
;
; `quiet` suppresses every MsgBox and tooltip and is for callers who are running
; Paddle as a SUPPORTING step rather than as the user's actual request — see
; SnipAiOcrHint() in SnipAI.ahk, which uses the text as a spelling reference for
; an AI table read.  Such a caller must degrade silently when the engine isn't
; installed: popping "PaddleOCR engine not found" at someone who asked for an AI
; transcription would be nonsense.
OcrPaddleBlocks(Hwnd, quiet := false) {
    if !(png := OcrSnipToPng(Hwnd, quiet))
        return 0

    if !quiet
        OcrToolTip('Running PaddleOCR...')
    json := OcrRunPaddle(png, &errMsg)

    if !OcrCfg.Debug
        try FileDelete(png)

    if (errMsg != '') {
        if !quiet {
            OcrToolTip()
            MsgBox(errMsg, 'ScreenSnip OCR', 'Icon!')
        }
        return 0
    }

    blocks := OcrParsePaddleJson(json, &errMsg)
    if !quiet
        OcrToolTip()

    if (errMsg != '') {
        if !quiet
            MsgBox(errMsg, 'ScreenSnip OCR', 'Icon!')
        return 0
    }
    if !blocks.Length {
        if !quiet
            OcrToolTip('No text found in snip', 1400)
        return 0
    }

    if OcrCfg.Debug
        OcrDumpBlocks(blocks)

    return blocks
}

; Write a human-readable dump of what the engine saw and how we're about to
; cluster it.  The raw JSON tells you whether the ENGINE misread the text; this
; tells you whether the CLUSTERING is misplacing it.  When a table comes out
; wrong, those are the two suspects, and you can't tell them apart from the TSV.
OcrDumpBlocks(blocks) {
    path := OcrDebugPath('blocks.txt')
    medH := OcrMedianHeight(blocks)
    rows := OcrGroupIntoRows(blocks)
    cols := OcrFindColumns(rows)
    grid := OcrBuildGrid(rows, cols)
    final := OcrCfg.Reflow ? OcrReflowGrid(grid, rows) : grid

    s := 'SnipOCR debug dump — ' FormatTime(, 'yyyy-MM-dd HH:mm:ss') '`r`n'
       . 'Blocks: ' blocks.Length '   Physical rows: ' rows.Length
       . '   Logical rows: ' final.Length '   Cols: ' cols.Length '`r`n'
       . '`r`nReflow: ' (OcrCfg.Reflow ? 'enabled' : 'DISABLED')
       . '   gap-separation ratio ' OcrState.ReflowRatio
       . ' vs threshold ' OcrCfg.ReflowRatio '`r`n'
       . '        -> ' OcrState.ReflowNote '`r`n'
       . 'Column density: ' Round(OcrColumnDensity(rows, cols) * 100)
       . '% of the text is in the busiest column'
       . (OcrColumnDensity(rows, cols) > OcrCfg.NotATableWarn
            ? '   <-- looks like PROSE, not a table' : '') '`r`n'
       . '`r`nMedian text height: ' Round(medH, 1) ' px (upscaled)`r`n'
       . 'RowTol ' OcrCfg.RowTol ' -> ' Round(Max(4, medH * OcrCfg.RowTol), 1) ' px'
       . '   (raise if one row splits in two; lower if two rows merge)`r`n'
       . 'ColTol ' OcrCfg.ColTol ' -> ' Round(Max(6, medH * OcrCfg.ColTol), 1) ' px'
       . '   (raise if one column splits; lower if two columns merge)`r`n'

    s .= '`r`nColumn anchors (left edges, px): '
    for i, c in cols
        s .= (i = 1 ? '' : ', ') Round(c)
    s .= '`r`n'

    s .= '`r`n' OcrPad('ROW', 5) OcrPad('COL', 5) OcrPad('X', 7) OcrPad('Y', 7)
       . OcrPad('W', 7) OcrPad('H', 6) OcrPad('SCORE', 8) 'TEXT`r`n'
       . '--------------------------------------------------------------`r`n'

    for ri, row in rows {
        for b in row {
            ci := cols.Length ? OcrNearestIndex(cols, b.x) : 0
            s .= OcrPad(ri, 5) OcrPad(ci, 5) OcrPad(Round(b.x), 7) OcrPad(Round(b.y), 7)
               . OcrPad(Round(b.w), 7) OcrPad(Round(b.h), 6)
               . OcrPad(Round(b.score, 3), 8) b.text '`r`n'
        }
    }

    s .= '`r`nRECONSTRUCTED TABLE (as copied to clipboard):`r`n'
       . '--------------------------------------------------------------`r`n'
    for cells in final
        s .= OcrJoin(cells, '`t') '`r`n'

    try FileDelete(path)
    try FileAppend(s, path, 'UTF-8')
}

OcrPad(v, width) {
    s := String(v)
    while (StrLen(s) < width)
        s .= ' '
    return s
}

; Decide what to pass as -limit_side_len.
;
; The engine downscales any image whose LONG edge exceeds this value.  If we
; upscale 3x and then hand it a limit below the result, we've paid for the
; upscale and thrown it away — which is exactly what a fixed 2880 did to a
; 4986px image: an effective magnification of 1.7x instead of 3x, and digits
; started dropping out of two-digit numbers.
;
; In AUTO mode (LimitSideLen = 0) we size the limit to the image itself, so no
; downscaling happens at all.  Paddle wants a multiple of both 32 and 48, so we
; round up to the next multiple of 96 (their LCM).
OcrLimitSideLen() {
    if (OcrCfg.LimitSideLen > 0)                    ; user pinned it explicitly
        return OcrCfg.LimitSideLen

    long := Max(OcrState.ImgW, OcrState.ImgH)
    if (long <= 0)                                  ; shouldn't happen; be safe
        return 2880

    limit := Ceil(long / 96) * 96
    return Min(limit, OcrCfg.MaxSideLen)
}

; Shell out to PaddleOCR-json.exe and return its raw JSON string.
; The engine is run once per call (single-shot mode).  Init costs roughly a
; second; if that ever becomes annoying, the engine also supports a persistent
; stdin/stdout pipe mode and a TCP mode — but single-shot keeps this simple and
; leaves no background process running.
OcrRunPaddle(imgPath, &errMsg) {
    errMsg := ''
    exe := OcrCfg.PaddleExe

    if !FileExist(exe) {
        errMsg := 'PaddleOCR engine not found at:`n' exe '`n`n'
                . 'Download PaddleOCR-json (Windows x64) from`n'
                . 'https://github.com/hiroi-sora/PaddleOCR-json/releases/latest'
                . '`n`nUnzip it into the Resources folder, keeping'
                . ' PaddleOCR-json.exe and its "models" subfolder together.'
                . '`n`nIf you put it elsewhere, set OcrCfg.PaddleExe at the top'
                . ' of SnipOCR.ahk.'
        return ''
    }

    ; The engine resolves LangConfig relative to its own folder, so run it there.
    engineDir := RegExReplace(exe, '\\[^\\]+$')
    outFile   := A_Temp '\ScreenSnip_OCR_' A_TickCount '.json'

    args := ' -image_path="' imgPath '"'
          . ' -limit_side_len=' OcrLimitSideLen()
          . (OcrCfg.LangConfig ? ' -config_path="' OcrCfg.LangConfig '"' : '')

    ; cmd.exe is used only to redirect stdout to a file.  The doubled outer
    ; quotes are the standard `cmd /c "..."` idiom — without them, cmd mangles
    ; the command line as soon as any path contains a space.
    cmdLine := A_ComSpec ' /c ""' exe '"' args ' > "' outFile '""'

    try {
        RunWait(cmdLine, engineDir, 'Hide')
    } catch as e {
        errMsg := 'Failed to launch the OCR engine:`n`n' e.Message
        return ''
    }

    raw := ''
    try raw := FileRead(outFile, 'UTF-8')
    catch {
        errMsg := 'The OCR engine produced no output file.'
        return ''
    }
    try FileDelete(outFile)

    ; NOTE: these must be two separate `try` statements.  Chaining them as
    ; `try FileDelete(...), FileAppend(...)` means a throw from FileDelete (which
    ; happens whenever the file doesn't exist yet) aborts the whole expression
    ; and silently skips the FileAppend — so the file could never be created.
    if OcrCfg.Debug
        try FileAppend(raw, OcrDebugPath('raw.json'), 'UTF-8')

    ; The engine may print a startup banner before the JSON, so start at the
    ; first '{"code"' rather than assuming the whole file is JSON.
    if !RegExMatch(raw, '\{\s*"code"', &m) {
        errMsg := 'The OCR engine returned no JSON.`n`n'
                . 'Raw output:`n' (raw = '' ? '(empty)' : SubStr(raw, 1, 600))
                . '`n`nCommon causes: the "models" folder is missing from the'
                . ' engine directory, or your CPU lacks AVX support.'
        return ''
    }
    return SubStr(raw, m.Pos)
}

; Parse PaddleOCR-json output into an array of text blocks.
;
; Schema (compact, keys alphabetical):
;   {"code":100,"data":[{"box":[[x,y],[x,y],[x,y],[x,y]],"score":0.99,"text":"hi"}]}
;   box corners are: top-left, top-right, bottom-right, bottom-left.
;   code 100 = text found, 101 = image had no text (not an error), else error.
;
; Text is scanned character-by-character rather than regexed, because the engine
; defaults to ensure_ascii, which means non-ASCII arrives as \uXXXX escapes.
OcrParsePaddleJson(json, &errMsg) {
    errMsg := ''
    blocks := []

    if RegExMatch(json, '"code"\s*:\s*(\d+)', &cm) {
        code := Integer(cm[1])
        if (code = 101)                     ; blank image — a normal outcome
            return blocks
        if (code != 100) {
            detail := RegExMatch(json, '"data"\s*:\s*"([^"]*)"', &dm) ? ': ' dm[1] : ''
            errMsg := 'OCR engine returned error code ' code detail
            return blocks
        }
    }

    pos := 1
    while RegExMatch(json, '"box"\s*:\s*\[\s*\[(-?\d+),(-?\d+)\]\s*,\s*\[(-?\d+),(-?\d+)\]'
                         . '\s*,\s*\[(-?\d+),(-?\d+)\]\s*,\s*\[(-?\d+),(-?\d+)\]\s*\]'
                         , &m, pos) {
        pos := m.Pos + m.Len

        score := 1.0
        if RegExMatch(json, '"score"\s*:\s*([\d.eE+-]+)', &sm, pos)
            score := Number(sm[1])

        if !RegExMatch(json, '"text"\s*:\s*"', &tm, pos)
            break
        text := OcrScanJsonString(json, tm.Pos + tm.Len, &pos)

        if (score < OcrCfg.MinScore) || (Trim(text) = '')
            continue

        xs := [m[1]+0, m[3]+0, m[5]+0, m[7]+0]
        ys := [m[2]+0, m[4]+0, m[6]+0, m[8]+0]
        x1 := Min(xs*), x2 := Max(xs*)
        y1 := Min(ys*), y2 := Max(ys*)

        blocks.Push({ text: text, score: score
                    , x: x1, y: y1, w: x2 - x1, h: y2 - y1
                    , cx: (x1 + x2) / 2, cy: (y1 + y2) / 2 })
    }
    return blocks
}

; Read a JSON string literal starting at startPos (the first char AFTER the
; opening quote).  Returns the unescaped text; sets endPos past the close quote.
OcrScanJsonString(s, startPos, &endPos) {
    out := '', i := startPos, len := StrLen(s)
    while (i <= len) {
        c := SubStr(s, i, 1)
        if (c = '"') {
            endPos := i + 1
            return out
        }
        if (c = '\') {
            e := SubStr(s, i + 1, 1)
            switch e, true {                       ; true = case-sensitive
                case '"':  out .= '"',      i += 2
                case '\':  out .= '\',      i += 2
                case '/':  out .= '/',      i += 2
                case 'n':  out .= '`n',     i += 2
                case 'r':  out .= '`r',     i += 2
                case 't':  out .= '`t',     i += 2
                case 'b':  out .= Chr(8),   i += 2
                case 'f':  out .= Chr(12),  i += 2
                case 'u':  out .= Chr(Integer('0x' SubStr(s, i + 2, 4))), i += 6
                default:   out .= e,        i += 2
            }
            continue
        }
        out .= c
        i++
    }
    endPos := len + 1
    return out
}


; ══════════════════════════════════════════════════════════════════════════════
; TABLE RECONSTRUCTION
;
; PaddleOCR gives us floating text blocks, not a grid.  We rebuild the grid in
; two passes:
;   1. Cluster blocks vertically  -> rows
;   2. Cluster left edges horizontally across ALL rows -> a set of column anchors
;   3. Snap each block to its nearest column anchor
;
; This works well on screen-captured tables with consistent alignment.  It has
; three known weaknesses, all inherent to reconstructing structure from boxes:
;   - merged cells become a value in the leftmost column they touch
;   - a cell whose text wraps to two visual lines becomes two rows
;   - a right-aligned numeric column sitting next to a left-aligned text column
;     may not cluster cleanly (we anchor on LEFT edges)
; ══════════════════════════════════════════════════════════════════════════════

; Group blocks into rows by vertical center, then sort each row left-to-right.
OcrGroupIntoRows(blocks) {
    if !blocks.Length
        return []

    tol := Max(4, OcrMedianHeight(blocks) * OcrCfg.RowTol)
    sorted := OcrSortBlocks(blocks, 'cy')

    rows := [], cur := [sorted[1]], anchor := sorted[1].cy
    i := 2
    while (i <= sorted.Length) {
        b := sorted[i]
        if (Abs(b.cy - anchor) <= tol) {
            cur.Push(b)
            sum := 0                     ; re-anchor on the running mean so a tall
            for c in cur                 ; row doesn't drift away from its members
                sum += c.cy
            anchor := sum / cur.Length
        } else {
            rows.Push(cur)
            cur := [b], anchor := b.cy
        }
        i++
    }
    rows.Push(cur)

    out := []
    for r in rows
        out.Push(OcrSortBlocks(r, 'x'))
    return out
}

; Cluster the left edges of every block into a set of column anchor positions.
OcrFindColumns(rows) {
    all := []
    for r in rows
        for b in r
            all.Push(b)
    if !all.Length
        return []

    tol := Max(6, OcrMedianHeight(all) * OcrCfg.ColTol)

    lefts := []
    for b in all
        lefts.Push(b.x)
    OcrSortNumbers(&lefts)

    cols := [], cur := [lefts[1]]
    i := 2
    while (i <= lefts.Length) {
        ; Chain to the previous member, not to the cluster mean — column left
        ; edges of the same column jitter by a pixel or two, and chaining keeps
        ; that jitter from splitting them.
        if (lefts[i] - cur[cur.Length] <= tol)
            cur.Push(lefts[i])
        else {
            cols.Push(OcrMean(cur))
            cur := [lefts[i]]
        }
        i++
    }
    cols.Push(OcrMean(cur))
    return cols
}

; Snap each block to its nearest column anchor, producing a grid of strings.
OcrBuildGrid(rows, cols) {
    grid := []
    for row in rows {
        cells := []
        Loop cols.Length
            cells.Push('')

        for b in row {
            ci := OcrNearestIndex(cols, b.x)
            txt := b.text
            if (OcrCfg.MarkBelow > 0) && (b.score < OcrCfg.MarkBelow)
                txt .= '?'
            ; Two blocks landing in one cell means the engine split a phrase —
            ; rejoin them with a space rather than losing one.
            cells[ci] := (cells[ci] = '') ? txt : cells[ci] ' ' txt
        }
        ; Tabs and newlines inside a cell would corrupt the TSV grid.
        for i, c in cells
            cells[i] := StrReplace(StrReplace(StrReplace(c, '`t', ' '), '`r', ''), '`n', ' ')

        grid.Push(cells)
    }
    return grid
}

; Stitch wrapped cells back together.  See OcrCfg.Reflow for the reasoning.
; Returns a new grid; returns the input untouched if it doesn't detect wrapping.
OcrReflowGrid(grid, rows) {
    OcrState.ReflowNote := ''
    if (rows.Length < 3)                     ; too few rows to judge
        return grid

    ; Vertical WHITESPACE between each pair of consecutive rows.
    gaps := []
    Loop rows.Length - 1
        gaps.Push(OcrRowTop(rows[A_Index + 1]) - OcrRowBottom(rows[A_Index]))

    ; ── Gate: does this table contain wrapped cells at all? ───────────────────
    ; If it does, the gaps are bimodal (line spacing vs row border).  If it
    ; doesn't, they're all much the same and we must leave the rows alone.
    ratio := OcrGapBimodality(gaps, &otsuSplit)
    OcrState.ReflowRatio := Round(ratio, 2)

    if (ratio < OcrCfg.ReflowRatio) {
        OcrState.ReflowSplit := 0
        OcrState.ReflowNote := 'no wrapping detected - rows left alone'
        return grid
    }

    ; ── Decide which rows START a logical row ────────────────────────────────
    gapThresh := OcrMedianOf(gaps) * OcrCfg.ReflowGapFactor
    OcrState.ReflowSplit := Round(gapThresh, 1)

    col := OcrCfg.ReflowAnchorCol
    starts := OcrRowStarts(grid, gaps, gapThresh, col)

    if (starts.Count < 1) {
        ; The anchor column never coincided with a big gap, so it isn't acting
        ; as a key column here.  Fall back to gaps alone rather than collapsing
        ; the whole table into one row.
        starts := OcrRowStarts(grid, gaps, otsuSplit, 0)
        OcrState.ReflowNote := 'wrapped cells; anchor column unusable, used gaps alone'
    } else {
        OcrState.ReflowNote := 'wrapped cells; new row where gap > '
                             . Round(gapThresh) ' px'
                             . (col > 0 ? ' AND column ' col ' is filled' : '')
    }

    ; ── Merge continuation lines upward ──────────────────────────────────────
    out := [], cur := grid[1].Clone()
    Loop grid.Length - 1 {
        i := A_Index + 1

        if starts.Has(i) {
            out.Push(cur)
            cur := grid[i].Clone()
            continue
        }
        for j, v in grid[i] {                ; a wrapped continuation line
            if (v = '')
                continue
            if (cur[j] = '') {
                cur[j] := v
                continue
            }
            ; A fragment ending in '-' or '/' was mid-word, so don't insert a
            ; space: "assignments/" + "appointments." = "assignments/appointments."
            last := SubStr(cur[j], -1)
            cur[j] .= (last = '-' || last = '/') ? v : ' ' v
        }
    }
    out.Push(cur)
    return out
}

; Which grid rows begin a new logical row?  Returns a Map keyed by row index.
;
; anchorCol > 0: a new row needs a big gap above it AND content in that column.
; anchorCol = 0: a big gap above it is enough.
OcrRowStarts(grid, gaps, gapThresh, anchorCol) {
    starts := Map()
    Loop grid.Length - 1 {
        i := A_Index + 1                     ; grid row under consideration

        if (gaps[i - 1] <= gapThresh)        ; too close to the row above
            continue
        if (anchorCol > 0) && (anchorCol <= grid[i].Length) && (grid[i][anchorCol] = '')
            continue                         ; no key value: it's a continuation

        starts[i] := true
    }
    return starts
}

; 1-D Otsu threshold on the gaps: find the split that best separates them into
; two groups, and report how far apart those groups are.  A ratio near 1 means
; the gaps are all alike (no wrapped cells); a ratio of 2+ means the table has
; a clear "line spacing" population and a clear "row border" population.
OcrGapBimodality(gaps, &split) {
    srt := gaps.Clone()
    OcrSortNumbers(&srt)
    n := srt.Length
    split := 0, bestScore := -1, meanLo := 1, meanHi := 1

    Loop n - 1 {
        k := A_Index
        sumLo := 0, sumHi := 0
        Loop k
            sumLo += srt[A_Index]
        Loop n - k
            sumHi += srt[k + A_Index]

        mLo := sumLo / k, mHi := sumHi / (n - k)
        score := k * (n - k) * (mHi - mLo) ** 2
        if (score > bestScore)
            bestScore := score, split := srt[k], meanLo := mLo, meanHi := mHi
    }
    return (meanLo > 1) ? (meanHi / meanLo) : 999
}

; What fraction of the text sits in the single most crowded column?  High means
; the snip is prose or a form, not a grid.  See OcrCfg.NotATableWarn.
OcrColumnDensity(rows, cols) {
    if !cols.Length
        return 1

    counts := []
    Loop cols.Length
        counts.Push(0)

    total := 0
    for row in rows
        for b in row {
            ci := OcrNearestIndex(cols, b.x)
            counts[ci] += 1
            total += 1
        }

    top := 0
    for c in counts
        top := Max(top, c)
    return total ? (top / total) : 1
}

OcrMedianOf(nums) {
    a := nums.Clone()
    OcrSortNumbers(&a)
    n := a.Length
    if !n
        return 0
    return (Mod(n, 2) = 1) ? a[(n + 1) // 2] : (a[n // 2] + a[n // 2 + 1]) / 2
}

OcrRowTop(row) {
    v := row[1].y
    for b in row
        v := Min(v, b.y)
    return v
}

OcrRowBottom(row) {
    v := row[1].y + row[1].h
    for b in row
        v := Max(v, b.y + b.h)
    return v
}

; Build the final tab-separated table.
; TSV is deliberate: it pastes straight into Excel / Sheets as a real grid.
OcrRowsToTsv(rows, cols) {
    if !cols.Length
        return ''

    grid := OcrBuildGrid(rows, cols)
    if OcrCfg.Reflow
        grid := OcrReflowGrid(grid, rows)

    lines := []
    for cells in grid
        lines.Push(OcrJoin(cells, '`t'))
    return OcrJoin(lines, '`r`n')
}


; ══════════════════════════════════════════════════════════════════════════════
; IMAGE HELPERS  (standalone — the GDIp class in ScreenSnip.ahk is untouched)
; ══════════════════════════════════════════════════════════════════════════════

; Render what the user is ACTUALLY LOOKING AT to a temp PNG, ready for OCR.
; Returns the file path, or '' on failure.
;
; Important subtlety: the snip's stored pBitmap is not always what's on screen.
; TransformSnip (90/180/270 rotation, flips) replaces pBitmap in the map, so
; those are already baked in.  But AdjustSnipAngle (Alt+Left/Right, fine
; rotation) deliberately does NOT — it preserves the pristine original and
; re-renders from it each time, storing only the cumulative angle in snip.Angle.
; So we must re-apply that angle here, or fine-rotating to deskew tilted text
; would have no effect on the OCR result.
;
; Order is upscale-then-rotate: rotating at the higher resolution means the
; rotation's resampling pass costs much less text quality.
OcrSnipToPng(Hwnd, quiet := false) {
    global guiSnips
    if !guiSnips.Has(Hwnd)
        return ''

    snip    := guiSnips[Hwnd]
    pSource := snip.pBitmap
    pTemp   := 0                                        ; anything we must dispose

    ; 1. Upscale.  Small screen text is the single biggest OCR accuracy factor.
    if (pScaled := OcrScaleBitmap(pSource, OcrCfg.Upscale))
        pSource := pTemp := pScaled

    ; 2. Re-apply any fine rotation the user dialed in with Alt+Left/Right.
    ;    Fill the exposed corners with white rather than the magenta color key —
    ;    white reads as blank page to the OCR engine; magenta is just noise.
    if (snip.Angle != 0) {
        pRotated := GDIp.RotateBitmap(pSource, snip.Angle, OcrCfg.RotateFill)
        if pTemp
            GDIp.DisposeImage(pTemp)                    ; done with the upscale
        pSource := pTemp := pRotated
    }

    if OcrCfg.Debug
        OcrState.Stamp := FormatTime(, 'yyyyMMdd_HHmmss')   ; new stamp per run

    path := OcrCfg.Debug ? OcrDebugPath('image.png')
                         : A_Temp '\ScreenSnip_OCR_' A_TickCount '.png'

    ; Record the final size so OcrRunPaddle can size limit_side_len to match and
    ; stop the engine from shrinking away everything we just did.
    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', pSource, 'UInt*', &fw := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', pSource, 'UInt*', &fh := 0)
    OcrState.ImgW := fw, OcrState.ImgH := fh

    ok := OcrSaveBitmapToPng(pSource, path)

    if pTemp
        GDIp.DisposeImage(pTemp)

    if !ok {
        if !quiet
            MsgBox('Could not write the temp image for OCR:`n' path, 'ScreenSnip OCR', 'Icon!')
        return ''
    }
    return path
}

; Bicubic upscale.  Returns a NEW pBitmap the caller must dispose, or 0 if
; factor <= 1 (meaning "just use the original").
OcrScaleBitmap(pBitmap, factor) {
    if (factor <= 1)
        return 0

    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', pBitmap, 'UInt*', &w := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', pBitmap, 'UInt*', &h := 0)
    nw := Round(w * factor), nh := Round(h * factor)

    ; 0x26200A = PixelFormat32bppARGB
    if DllCall('gdiplus\GdipCreateBitmapFromScan0', 'Int', nw, 'Int', nh
             , 'Int', 0, 'Int', 0x26200A, 'UPtr', 0, 'UPtr*', &pNew := 0)
        return 0

    DllCall('gdiplus\GdipGetImageGraphicsContext', 'UPtr', pNew, 'UPtr*', &pGfx := 0)
    DllCall('gdiplus\GdipSetInterpolationMode', 'UPtr', pGfx, 'Int', 7)  ; HighQualityBicubic
    DllCall('gdiplus\GdipSetPixelOffsetMode',   'UPtr', pGfx, 'Int', 2)  ; HighQuality
    DllCall('gdiplus\GdipDrawImageRectI', 'UPtr', pGfx, 'UPtr', pBitmap
          , 'Int', 0, 'Int', 0, 'Int', nw, 'Int', nh)
    DllCall('gdiplus\GdipDeleteGraphics', 'UPtr', pGfx)

    return pNew
}

; Save a pBitmap as PNG.  CLSIDFromString saves us from having to enumerate the
; GDI+ encoder list — the PNG encoder GUID is fixed and documented.
OcrSaveBitmapToPng(pBitmap, filePath) {
    clsid := Buffer(16, 0)
    if DllCall('ole32\CLSIDFromString'
             , 'WStr', '{557CF406-1A04-11D3-9A73-0000F81EF32E}', 'Ptr', clsid)
        return false
    return 0 = DllCall('gdiplus\GdipSaveImageToFile', 'UPtr', pBitmap
                     , 'WStr', filePath, 'Ptr', clsid, 'UPtr', 0)
}


; ══════════════════════════════════════════════════════════════════════════════
; SMALL UTILITIES
; ══════════════════════════════════════════════════════════════════════════════

OcrMedianHeight(blocks) {
    hs := []
    for b in blocks
        hs.Push(b.h)
    OcrSortNumbers(&hs)
    n := hs.Length
    if !n
        return 10
    return (Mod(n, 2) = 1) ? hs[(n + 1) // 2] : (hs[n // 2] + hs[n // 2 + 1]) / 2
}

OcrMean(nums) {
    sum := 0
    for n in nums
        sum += n
    return nums.Length ? sum / nums.Length : 0
}

; Index of the value in sorted array 'arr' closest to 'target' (1-based).
OcrNearestIndex(arr, target) {
    best := 1, bestDist := Abs(arr[1] - target)
    i := 2
    while (i <= arr.Length) {
        if ((d := Abs(arr[i] - target)) < bestDist)
            best := i, bestDist := d
        i++
    }
    return best
}

; Insertion sort — n is tiny here (a screenful of text blocks), and it keeps the
; module dependency-free.
OcrSortNumbers(&arr) {
    i := 2
    while (i <= arr.Length) {
        v := arr[i], j := i - 1
        while (j >= 1 && arr[j] > v)
            arr[j + 1] := arr[j], j--
        arr[j + 1] := v
        i++
    }
}

OcrSortBlocks(blocks, key) {
    out := []
    for b in blocks
        out.Push(b)
    i := 2
    while (i <= out.Length) {
        v := out[i], j := i - 1
        while (j >= 1 && out[j].%key% > v.%key%)
            out[j + 1] := out[j], j--
        out[j + 1] := v
        i++
    }
    return out
}

OcrJoin(arr, sep) {
    s := ''
    for i, v in arr
        s .= (i = 1 ? '' : sep) v
    return s
}

OcrCountLines(text) {
    n := 1
    Loop Parse, text, '`n', '`r'
        n := A_Index
    return n
}

; Transient status tooltip.  Call with no args to clear immediately.
OcrToolTip(text := '', timeoutMs := 0) {
    static TimerFn := (*) => ToolTip()
    SetTimer(TimerFn, 0)
    if (text = '') {
        ToolTip()
        return
    }
    ToolTip(text)
    if timeoutMs
        SetTimer(TimerFn, -timeoutMs)
}
