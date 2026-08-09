#Requires AutoHotkey v2
;               SnipAI.ahk  —  AI vision add-on module for ScreenSnip.ahk
;
; Made by kunkel321 via Claude AI.
; Version date: 8-9-2026
;
; Credit:  The idea of sending a screen snip to an AI vision model comes from
; one of Joe Glines' apps.  Joe's site — www.the-automator.com — is where a lot
; of us first saw AHK and LLM APIs wired together.  This module is an
; independent implementation of that idea, fitted to ScreenSnip's snip objects
; and to the same optional-include pattern used by SnipImgur.ahk.
;
; Adds three items to the OCR submenu of each floating snip:
;
;   OCR > Copy Text (AI)         — verbatim transcription, straight to clipboard
;   OCR > Copy Table (AI)        — table as TSV, ready to paste into a spreadsheet
;   OCR > Ask AI About Snip…     — free-form question, answer shown in a window
;
; Copy Table (AI) exists because a vision model can see the table's RULING LINES,
; which no box-based OCR engine can.  PaddleOCR infers columns by clustering the
; x-coordinates of text boxes, so a token that lands at the same x in every row
; reads as a column even when it is only an artifact of line wrapping inside one
; wide cell.  The borders settle it.  When SnipOCR.ahk is present, Paddle also
; runs first and its text is sent along as a spelling reference — see
; SnipAiOcrHint(), which sends reading-order lines and NOT Paddle's
; reconstructed grid, so the model gets the characters without the layout guess.
;
; Unlike Windows.Media.Ocr and PaddleOCR, this sends the image OFF THIS MACHINE
; to OpenAI, and it costs money (fractions of a cent per snip).  It is also
; slower — expect several seconds.  In exchange it handles multi-column layouts,
; tables, handwriting, math, and low-resolution antialiased text far better than
; either local engine.
;
; IMPORTANT CAVEAT:  a vision model reports what it believes the text says, not
; what the pixels say.  It will silently normalize odd spacing and can "correct"
; a genuine typo in the source.  For an exact license key or hex string, prefer
; the local engines.  The prompt below pushes hard against this, but it cannot
; eliminate it.
;
; ── SETUP ─────────────────────────────────────────────────────────────────────
;
;   1. Get an API key: https://platform.openai.com/account/api-keys
;      The service is not free and requires prepaid credit.  kunkel321 receives
;      no compensation from your transactions with OpenAI.
;   2. Put the key in  Data\ApiKeys.ini  beside ScreenSnip.ahk, as:
;           [OpenAI]
;           ApiKey=sk-...
;      That is the same file SnipImgur.ahk keeps its Client ID in (under an
;      [Imgur] section), so there is one credentials file to gitignore and one
;      to back up.  ADD THE Data FOLDER TO .gitignore.  ScreenSnip creates the
;      file on demand, and the menu items say so when no key is configured.
;   3. To share one key with the rest of an AutoCorrect2 install instead, see
;      the SnipAiCfg.IniFile comment below — it is a one-line change.
;   4. Note that OpenAI prepaid credits EXPIRE after one year.  Buy a dollar or
;      two at a time and set a budget alert.
;
; ── OPT-OUT CONTRACT ──────────────────────────────────────────────────────────
;
; This file is included with `#Include *i SnipAI.ahk`, exactly like
; SnipImgur.ahk.  Delete the file (or comment out the include) and the
; SnipAiCfg class never comes into existence, so the `IsSet(SnipAiCfg)` test
; where OcrMenu is built skips the two menu items and ScreenSnip runs normally.
;
; This file contains functions and classes only; no top-level executable code,
; so it is safe to #Include at the very bottom of ScreenSnip.ahk.
;
; ══════════════════════════════════════════════════════════════════════════════


; ══════════════════════════════════════════════════════════════════════════════
; USER SETTINGS
; ══════════════════════════════════════════════════════════════════════════════

class SnipAiCfg {

    ; ── Credentials ───────────────────────────────────────────────────────────
    ; The key lives in Data\ApiKeys.ini beside ScreenSnip.ahk — the same file
    ; SnipImgur.ahk keeps its Client ID in, under an [Imgur] section.  The path
    ; comes from SnipKeysIni() in ScreenSnip.ahk so both modules stay in sync.
    ;
    ; To share one key with the rest of an AutoCorrect2 install instead, change
    ; this to point at AC2's file, which uses the same section and key names:
    ;     static IniFile => '..\Data\PersonalApiKey.ini'
    ; Note that '..\' there is relative to the WORKING directory, not the script
    ; directory — that is how ChatGptWordLookup.ahk resolves it.
    static IniFile    => SnipKeysIni()
    static IniSection := 'OpenAI'
    static IniKey     := 'ApiKey'

    ; ── Model ─────────────────────────────────────────────────────────────────
    ; Any vision-capable chat model.  If this one is not enabled on your
    ; account you will get a clear "model not found" back from the API — the
    ; error body is shown verbatim, so it is a one-line fix.  Cheaper "mini"
    ; tier models are markedly worse at dense small text; it is worth paying
    ; for the full model here.
    static Model := 'gpt-5.6'

    ; 'high' tiles the image and reads fine print; 'low' sends a single coarse
    ; thumbnail for about a tenth the cost.  For OCR you want 'high'.
    static Detail := 'high'

    ; ── Image handling ────────────────────────────────────────────────────────
    ; The API scales anything larger down before tiling, so sending a bigger
    ; image than this is pure upload with no accuracy gain.  Unlike the local
    ; OCR path there is no reason to UPSCALE — the model is not helped by it.
    static MaxSide := 2048

    ; ── Network ───────────────────────────────────────────────────────────────
    ; Vision calls are slow; the receive timeout in particular must be generous.
    ; Resolve, connect, send, receive — all milliseconds.
    static Timeouts := [10000, 10000, 60000, 180000]
    static WaitSecs := 180

    ; ── Prompts ───────────────────────────────────────────────────────────────
    ; Transcription prompt.  Every clause here is load-bearing; the model's
    ; default instinct is to summarize and tidy, and it must be talked out of it.
    static TranscribePrompt := '
    (
Transcribe all text in this image exactly as it appears.

Rules:
- Output ONLY the transcribed text. No preamble, no commentary, no explanation, no markdown code fences.
- Reproduce the text VERBATIM. Do not correct spelling, grammar, capitalization, or punctuation, even if something is obviously a typo. A misspelling in the image must appear misspelled in your output.
- Preserve the reading order and the line breaks of the original.
- If the text is laid out as a table, output it as tab-separated values, one row per line, so it can be pasted into a spreadsheet.
- If the layout is multi-column, transcribe each column completely before moving to the next.
- If a character is genuinely unreadable, write [?] in its place rather than guessing.
- If there is no legible text at all, output exactly: NO TEXT FOUND
    )'

    ; Table prompt.  Two ideas carry most of the weight here.
    ;
    ; First, RULING LINES.  This is the one thing a vision model has that a
    ; box-based OCR engine does not: it can see the drawn borders of the table.
    ; PaddleOCR only ever sees rectangles of text, so it has to infer columns by
    ; clustering x-coordinates — which means a token that happens to land at the
    ; same x in every row reads as a column even when it is just an artifact of
    ; line wrapping inside one wide cell. Pointing the model at the borders and
    ; telling it they outrank alignment is what fixes that class of error.
    ;
    ; Second, a DECLARED COLUMN COUNT.  The model states the count up front and
    ; every row must match it, which turns the silent failure (a dropped empty
    ; cell shifting a whole row left, producing a plausible and wrong table)
    ; into something SnipAiParseTableJson can actually detect and report.
    static TablePrompt := '
    (
Transcribe the table in this image as JSON.

STRUCTURE
- If the table has drawn ruling lines (borders), those lines define the cells. Use them as the authority for where every column and row begins and ends. Ruling lines OUTRANK text alignment: if some text happens to line up vertically but sits inside a bordered cell with other text, it belongs to that cell and is NOT its own column. Text that wraps onto several lines within one bordered cell is ONE cell value.
- If the table has no ruling lines, infer the columns from alignment and spacing instead.
- Count the columns first, from the widest part of the table, and report that number as "columns". Every row you output must contain exactly that many cells.
- A cell that spans several columns: put its text in the leftmost column it covers, and use "" for the remaining columns it spans.
- An empty cell must be written as "". Never omit a cell — a missing cell silently shifts the whole row.

CELL CONTENTS
- Transcribe VERBATIM. Do not correct spelling, grammar, or capitalization, even if something is obviously a typo.
- Do not normalize numbers, dates, currency, or units. Keep thousands separators, currency symbols, percent signs, leading zeros, and parenthesised negatives exactly as displayed.
- Join text that wraps within a cell into one value using single spaces.
- Replace any tab or newline inside a cell value with a single space.
- Every cell value must be a JSON string, even if it looks like a number.
- If a character is genuinely unreadable, write [?] in its place rather than guessing.

OUTPUT
- Output ONLY a JSON object, with no preamble, no explanation, and no markdown code fences.
- Shape: {"columns": <integer>, "rows": [["cell","cell",...], ...]}
- If the image contains no table at all, output {"columns": 0, "rows": []}
    )'

    ; Framing for the PaddleOCR text handed to the model alongside the image.
    ; The wording is deliberately lopsided: it grants the OCR authority over
    ; CHARACTERS and explicitly strips it of any authority over LAYOUT.  Sending
    ; Paddle's reconstructed grid instead of its raw lines would hand the model
    ; the very column mistake this feature exists to correct, so SnipAiOcrHint()
    ; sends reading-order lines only and this text tells the model to distrust
    ; even those structurally.
    static OcrHintPreamble := '
    (

---
Below is a character-level OCR reading of this same image from a different engine. That engine cannot see ruling lines, so it is often WRONG about layout — it may split one cell into several, merge separate cells, or invent column breaks where text merely happens to line up. It is usually RIGHT about characters.

Use it ONLY as a spelling and digit reference, to catch places where you might misread a character. Take ALL structure — every column and row boundary — from the ruling lines in the image itself. Where it disagrees with what you can see, trust the image.

OCR reading:
    )'

    ; ── Table cleanup ─────────────────────────────────────────────────────────
    ; Fold en/em dashes, curly quotes and non-breaking spaces down to ASCII in
    ; table cells, so what lands in the clipboard pastes cleanly into a
    ; spreadsheet.  See SnipAiNormalizePunct().  Table cells only — Copy Text
    ; (AI) stays verbatim.
    static NormalizeTablePunct := true

    ; A cell whose entire content is a dash is a "no data" marker in most
    ; printed tables, not a value.  true blanks those cells, which keeps a
    ; numeric column numeric in Excel.  Off by default because it IS a content
    ; change, and in some tables a dash means something specific.
    static DashCellToEmpty := false

    ; Run PaddleOCR first and pass its text along as a spelling reference.
    ; Costs one extra engine run (a second or two, offline). Silently skipped if
    ; SnipOCR.ahk is absent or the engine isn't installed.
    static GroundWithOcr := true
    static AskPreamble := '
    (
Answer the following question about this image. Be concise and concrete. If the answer depends on text in the image, quote that text exactly rather than paraphrasing it. If the image does not contain enough information to answer, say so plainly instead of speculating.

Question:
    )'

    ; ── Debugging ─────────────────────────────────────────────────────────────
    ; true = keep the temp PNG and write the raw request/response into the Data
    ; folder, so a failed call can be inspected.  The request dump does NOT
    ; contain the API key (that rides in a header, not the body), but it does
    ; contain the base64 image, so it will be large.
    static Debug := false
}


; ══════════════════════════════════════════════════════════════════════════════
; PUBLIC ENTRY POINTS  (called from SnipMenu_Handler in ScreenSnip.ahk)
; ══════════════════════════════════════════════════════════════════════════════

; ── Verbatim transcription -> clipboard ───────────────────────────────────────
SnipAiCopyText(Hwnd) {
    if !(key := SnipAiGetApiKey())
        return

    if !(png := SnipAiSnipToPng(Hwnd))
        return

    SnipAiToolTip('Asking AI to transcribe… (this uses your OpenAI credits)')
    text := SnipAiVisionRequest(png, SnipAiCfg.TranscribePrompt, key, &errMsg)
    SnipAiToolTip()

    if !SnipAiCfg.Debug
        try FileDelete(png)

    if (text = '') {
        MsgBox('The AI transcription request failed.`n`n' errMsg
             , 'ScreenSnip AI', 'Icon!')
        return
    }

    text := Trim(text, ' `t`r`n')
    if (text = '' || text = 'NO TEXT FOUND') {
        SnipAiToolTip('No text found', 1400)
        return
    }

    A_Clipboard := text
    SnipAiToolTip('Copied ' SnipAiCountLines(text) ' line(s) to clipboard', 1600)
}

; ── Table -> TSV on the clipboard ─────────────────────────────────────────────
SnipAiCopyTable(Hwnd) {
    if !(key := SnipAiGetApiKey())
        return

    ; Grounding runs FIRST, because it needs its own tooltip and its own render
    ; of the snip, and because there is no point paying for an API call if the
    ; user cancels out of something here.
    hint := SnipAiCfg.GroundWithOcr ? SnipAiOcrHint(Hwnd) : ''

    if !(png := SnipAiSnipToPng(Hwnd))
        return

    prompt := SnipAiCfg.TablePrompt
    if (hint != '')
        prompt .= '`n' SnipAiCfg.OcrHintPreamble '`n' hint

    SnipAiToolTip('Asking AI to read the table…'
                . (hint != '' ? ' (with OCR reference)' : ''))
    raw := SnipAiVisionRequest(png, prompt, key, &errMsg)
    SnipAiToolTip()

    if !SnipAiCfg.Debug
        try FileDelete(png)

    if (raw = '') {
        MsgBox('The AI table request failed.`n`n' errMsg, 'ScreenSnip AI', 'Icon!')
        return
    }

    rows := SnipAiParseTableJson(raw, &cols, &warn, &errMsg)
    if !rows {
        MsgBox('Could not read a table out of the response.`n`n' errMsg
             . '`n`nRaw response:`n' SubStr(Trim(raw), 1, 600)
             , 'ScreenSnip AI', 'Icon!')
        return
    }
    if !rows.Length {
        SnipAiToolTip('No table found in snip', 1600)
        return
    }

    A_Clipboard := SnipAiRowsToTsv(rows)
    SnipAiToolTip('Copied ' rows.Length ' row(s) x ' cols ' col(s) to clipboard'
                . (warn != '' ? ' — ' warn : ''), warn != '' ? 3500 : 1600)
}

; PaddleOCR text for the same snip, as a spelling reference.  Returns '' if
; anything at all is unavailable — SnipOCR.ahk not installed, engine missing,
; no text found.  Grounding is an enhancement, never a prerequisite.
;
; Deliberately uses OcrBlocksToLines (reading order) rather than the reflowed
; grid from OcrRowsToTsv.  The grid is precisely where Paddle's column guess
; lives, and sending it would hand the model the mistake we are trying to fix.
SnipAiOcrHint(Hwnd) {
    ; SnipOCR.ahk absent -> OcrCfg never declared -> nothing to call.  Both
    ; calls go through the %name%() dynamic form, because a direct reference to
    ; a function in an optional module is a LOAD-TIME error in v2.
    if !IsSet(OcrCfg)
        return ''

    try {
        blocksFn := 'OcrPaddleBlocks'
        blocks := %blocksFn%(Hwnd, true)          ; true = quiet, no popups
        if !blocks
            return ''
        linesFn := 'OcrBlocksToLines'
        lines := %linesFn%(blocks)
        if !lines.Length
            return ''
        out := ''
        for ln in lines
            out .= ln '`n'
        return RTrim(out, '`n')
    } catch {
        ; Any failure here is non-fatal by design: fall through to an
        ; image-only request rather than blocking the feature.
        return ''
    }
}

; Response text -> array of row arrays.  Returns 0 with errMsg set if the shape
; is unusable, or an array (possibly empty) otherwise.  `warn` describes any
; row that had to be padded or truncated — the whole reason for asking the model
; to declare a column count is so this can be noticed rather than pasted.
SnipAiParseTableJson(raw, &cols, &warn, &errMsg) {
    cols := 0, warn := '', errMsg := ''

    ; Strip markdown fences if the model added them despite being told not to.
    ; The fence is built with Chr(96) rather than written literally: the backtick
    ; is AHK's escape character, so a literal ``` inside a quoted string needs
    ; six backticks to survive, which is unreadable and easy to get wrong.
    static FENCE := Chr(96) Chr(96) Chr(96)
    txt := Trim(raw, ' `t`r`n')
    if (SubStr(txt, 1, 3) = FENCE) {
        if (p := InStr(txt, '`n'))
            txt := SubStr(txt, p + 1)
        if (p := InStr(txt, FENCE, , -1))
            txt := SubStr(txt, 1, p - 1)
        txt := Trim(txt, ' `t`r`n')
    }

    data := SnipAiJsonParse(txt)
    if !IsObject(data) || !(data is Map) || !data.Has('rows') {
        errMsg := 'The response was not a JSON object with a "rows" key.'
        return 0
    }

    src := data['rows']
    if !(src is Array) {
        errMsg := 'The "rows" value was not an array.'
        return 0
    }
    if !src.Length
        return []

    declared := data.Has('columns') ? Integer(data['columns']) : 0

    ; Fall back to the widest row when the model omitted or fumbled the count.
    widest := 0
    for r in src {
        if (r is Array && r.Length > widest)
            widest := r.Length
    }
    cols := (declared > 0) ? declared : widest

    padded := 0, trimmed := 0
    rows := []
    for r in src {
        if !(r is Array)
            continue
        row := []
        for c in r
            row.Push(SnipAiCleanCell(c))
        while (row.Length < cols)
            row.Push(''), padded++
        if (row.Length > cols) {
            row.RemoveAt(cols + 1, row.Length - cols)
            trimmed++
        }
        rows.Push(row)
    }

    ; A declared count that disagrees with the widest row observed is the
    ; clearest signal that the model lost its place partway through.
    if (declared > 0 && widest > declared)
        warn := 'the model declared ' declared ' columns but emitted up to '
              . widest '; CHECK THE RESULT'
    else if (padded || trimmed)
        warn := (padded ? padded ' cell(s) padded' : '')
              . (padded && trimmed ? ', ' : '')
              . (trimmed ? trimmed ' row(s) truncated' : '')
              . ' — check alignment'

    return rows
}

; A cell should be a string, but the model occasionally emits a bare number or
; null despite instructions, and the parser turns those into real types.
SnipAiFlattenCell(c) {
    if IsObject(c)
        return ''
    s := String(c)
    ; Guard the TSV: a stray tab or newline in a cell would break the grid on
    ; paste, which is exactly the corruption this feature exists to avoid.
    s := StrReplace(s, '`r`n', ' ')
    s := StrReplace(s, '`n', ' ')
    s := StrReplace(s, '`r', ' ')
    s := StrReplace(s, '`t', ' ')
    return s
}

; Flatten, then apply the table-specific cleanups.
SnipAiCleanCell(c) {
    s := SnipAiFlattenCell(c)
    if SnipAiCfg.NormalizeTablePunct
        s := SnipAiNormalizePunct(s)
    if SnipAiCfg.DashCellToEmpty {
        t := Trim(s, ' `t')
        ; Only after normalization, so this catches en/em dashes too — by this
        ; point they are all plain hyphens.
        if (t != '' && RegExMatch(t, '^-+$'))
            s := ''
    }
    return s
}

SnipAiRowsToTsv(rows) {
    out := ''
    for r in rows
        out .= SnipAiJoin(r, '`t') '`r`n'
    return RTrim(out, '`r`n')
}

SnipAiJoin(arr, sep) {
    out := ''
    for i, v in arr
        out .= (i > 1 ? sep : '') v
    return out
}


; ── Free-form question about the snip -> result window ────────────────────────
SnipAiAsk(Hwnd) {
    if !(key := SnipAiGetApiKey())
        return

    ; Ask first, capture second: the InputBox is modal, and grabbing the bitmap
    ; before it opens would be wasted work if the user cancels.
    ib := InputBox('What would you like to know about this snip?'
                 , 'ScreenSnip AI', 'w420 h130')
    if (ib.Result != 'OK' || Trim(ib.Value, ' `t') = '')
        return
    question := Trim(ib.Value, ' `t`r`n')

    if !(png := SnipAiSnipToPng(Hwnd))
        return

    SnipAiToolTip('Asking AI… (this uses your OpenAI credits)')
    answer := SnipAiVisionRequest(png, SnipAiCfg.AskPreamble '`n' question
                                , key, &errMsg)
    SnipAiToolTip()

    if !SnipAiCfg.Debug
        try FileDelete(png)

    if (answer = '') {
        MsgBox('The AI request failed.`n`n' errMsg, 'ScreenSnip AI', 'Icon!')
        return
    }

    SnipAiShowResult(question, Trim(answer, ' `t`r`n'))
}


; ══════════════════════════════════════════════════════════════════════════════
; RESULT WINDOW
; ══════════════════════════════════════════════════════════════════════════════

SnipAiShowResult(question, answer) {
    g := Gui('+Resize +MinSize420x260', 'ScreenSnip AI')
    g.MarginX := 10, g.MarginY := 10
    g.SetFont('s10', 'Segoe UI')

    g.AddText('w560 +Wrap cGray', 'Q:  ' question)
    edit := g.AddEdit('w560 r16 +Multi +ReadOnly +VScroll -Wrap', answer)
    g.SetFont('s9')
    btnCopy  := g.AddButton('xm w120', 'Copy Answer')
    btnClose := g.AddButton('x+8 w120 Default', 'Close')

    btnCopy.OnEvent('Click', (*) => (A_Clipboard := edit.Value
                                   , SnipAiToolTip('Copied to clipboard', 1200)))
    btnClose.OnEvent('Click', (*) => g.Destroy())
    g.OnEvent('Close',  (*) => g.Destroy())
    g.OnEvent('Escape', (*) => g.Destroy())

    ; Keep the Edit filling the window on resize; the two buttons ride the
    ; bottom-left corner.  Anchored manually because AHK v2 has no layout
    ; manager and the control count is too small to justify one.
    g.OnEvent('Size', SnipAiResultSize.Bind(edit, btnCopy, btnClose))
    g.Show()
}

SnipAiResultSize(edit, btnCopy, btnClose, thisGui, MinMax, W, H) {
    if (MinMax = -1)          ; minimized — nothing to lay out
        return
    editH := H - 100
    if (editH < 60)
        editH := 60
    edit.Move(10, 44, W - 20, editH)
    btnCopy.Move(10,  44 + editH + 10)
    btnClose.Move(138, 44 + editH + 10)
}


; ══════════════════════════════════════════════════════════════════════════════
; API KEY / INI
; ══════════════════════════════════════════════════════════════════════════════

; Returns the key, or '' after having told the user what to do about it.
SnipAiGetApiKey() {
    path := SnipAiCfg.IniFile

    key := ''
    ; IniRead with a 4th arg returns that default rather than throwing when the
    ; file or key is missing, so a first run is silent.  The try/catch covers
    ; the odd case of ScreenSnip living in a folder it can't read.
    try key := Trim(IniRead(path, SnipAiCfg.IniSection, SnipAiCfg.IniKey, ''), ' `t')
    catch
        key := ''

    if (key = '') {
        MsgBox('No OpenAI API key is configured.`n`n'
             . 'To use the AI snip features:`n'
             . '  1. Get a key at  https://platform.openai.com/account/api-keys`n'
             . '  2. Open this file:`n        ' path '`n'
             . '  3. Under a [' SnipAiCfg.IniSection '] heading, set`n'
             . '        ' SnipAiCfg.IniKey '=your-key-here`n'
             . '     with no quotation marks.`n'
             . '  4. Save the ini and restart ScreenSnip.`n`n'
             . 'If ScreenSnip lives in a git repo, add the Data folder to '
             . '.gitignore.`n`n'
             . 'OpenAI is a paid service and the author of ScreenSnip receives '
             . 'nothing from your usage of it. Snips cost a fraction of a cent '
             . 'each. Note that prepaid credits expire after one year, so buy '
             . 'small amounts.'
             , 'ScreenSnip AI — Setup', 'Iconi')
        return ''
    }
    return key
}


; ══════════════════════════════════════════════════════════════════════════════
; IMAGE PREP
; ══════════════════════════════════════════════════════════════════════════════

; Snip -> temp PNG, straightened and size-capped.  Returns the path, or ''.
; Deliberately does NOT reuse SnipOCR's OcrSnipToPng: that one upscales 3x for
; the benefit of the local engines, which here would only inflate the upload.
SnipAiSnipToPng(Hwnd) {
    global guiSnips
    if !guiSnips.Has(Hwnd)
        return ''

    snip    := guiSnips[Hwnd]
    pSource := snip.pBitmap
    pTemp   := 0                                 ; anything we must dispose

    ; Re-apply the fine straighten angle, filling exposed corners with white
    ; rather than the magenta color key — white reads as blank page.
    if (snip.Angle != 0) {
        pSource := pTemp := GDIp.RotateBitmap(pSource, snip.Angle, 0xFFFFFF)
    }

    ; Cap the long edge.  The API downscales anything larger anyway.
    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', pSource, 'UInt*', &w := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', pSource, 'UInt*', &h := 0)
    long := (w > h) ? w : h
    if (long > SnipAiCfg.MaxSide) {
        factor := SnipAiCfg.MaxSide / long
        if (pScaled := SnipAiScaleBitmap(pSource, factor)) {
            if pTemp
                GDIp.DisposeImage(pTemp)
            pSource := pTemp := pScaled
        }
    }

    path := SnipAiCfg.Debug ? SnipDataPath('SnipAI_debug_image.png')
                            : A_Temp '\ScreenSnip_AI_' A_TickCount '.png'

    ok := GDIp.SaveImageToFile(pSource, path, 'image/png')

    if pTemp
        GDIp.DisposeImage(pTemp)

    ; SaveImageToFile wraps GdipSaveImageToFile, which returns 0 on success.
    ; Rather than trust the sign of that convention through a wrapper, just
    ; check that a non-empty file actually landed.
    if !FileExist(path) {
        MsgBox('Could not write the temp image for the AI request:`n' path
             , 'ScreenSnip AI', 'Icon!')
        return ''
    }
    return path
}

; Bicubic rescale by an arbitrary factor (unlike OcrScaleBitmap, which only
; enlarges).  Returns a NEW pBitmap the caller must dispose, or 0 on failure.
SnipAiScaleBitmap(pBitmap, factor) {
    if (factor <= 0 || factor = 1)
        return 0

    DllCall('gdiplus\GdipGetImageWidth',  'UPtr', pBitmap, 'UInt*', &w := 0)
    DllCall('gdiplus\GdipGetImageHeight', 'UPtr', pBitmap, 'UInt*', &h := 0)
    nw := Round(w * factor), nh := Round(h * factor)
    if (nw < 1 || nh < 1)
        return 0

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

; File -> base64 string, via the Crypt32 encoder.
;   0x00000001 = CRYPT_STRING_BASE64      (plain base64)
;   0x40000000 = CRYPT_STRING_NOCRLF      (no line wrapping — required here)
; The W form emits UTF-16, so the output buffer is sized in chars * 2.
SnipAiFileToBase64(path) {
    static FLAGS := 0x40000001
    buf := FileRead(path, 'RAW')              ; v2 returns a Buffer
    if (buf.Size = 0)
        return ''

    size := 0
    if !DllCall('crypt32\CryptBinaryToStringW', 'Ptr', buf, 'UInt', buf.Size
              , 'UInt', FLAGS, 'Ptr', 0, 'UInt*', &size)
        return ''
    out := Buffer(size * 2, 0)
    if !DllCall('crypt32\CryptBinaryToStringW', 'Ptr', buf, 'UInt', buf.Size
              , 'UInt', FLAGS, 'Ptr', out, 'UInt*', &size)
        return ''
    return StrGet(out, 'UTF-16')
}


; ══════════════════════════════════════════════════════════════════════════════
; THE API CALL
; ══════════════════════════════════════════════════════════════════════════════

; Send one image + one prompt.  Returns the model's text, or '' with errMsg set.
;
; Note on the request body: base64 contains only [A-Za-z0-9+/=], all of which
; are legal inside a JSON string with no escaping, so the body is assembled by
; plain concatenation.  Only the prompt goes through the escaper — and that
; escaper renders every non-ASCII character as \uXXXX, which makes the whole
; body pure ASCII.  That sidesteps WinHttpRequest.Send()'s murky handling of
; string encoding entirely: there is nothing left for it to get wrong.
SnipAiVisionRequest(pngPath, prompt, apiKey, &errMsg) {
    errMsg := ''
    apiUrl := 'https://api.openai.com/v1/chat/completions'

    if !(b64 := SnipAiFileToBase64(pngPath)) {
        errMsg := 'Could not base64-encode the image.'
        return ''
    }

    ; No max_tokens / max_completion_tokens is sent: the two spellings are
    ; accepted by different model generations, and omitting the cap entirely
    ; works on all of them. Cost is bounded by actual output length anyway.
    body := '{"model":"' SnipAiCfg.Model '","messages":[{"role":"user","content":['
          .   '{"type":"text","text":"' SnipAiEscapeJson(prompt) '"},'
          .   '{"type":"image_url","image_url":{'
          .     '"url":"data:image/png;base64,' b64 '",'
          .     '"detail":"' SnipAiCfg.Detail '"}}'
          . ']}]}'

    if SnipAiCfg.Debug {
        dbg := SnipDataPath('SnipAI_debug_request.json')
        try FileDelete(dbg)
        try FileAppend(body, dbg, 'UTF-8')
    }

    try {
        req := ComObject('WinHttp.WinHttpRequest.5.1')
        req.Open('POST', apiUrl, true)                   ; true = async
        req.SetRequestHeader('Content-Type', 'application/json')
        req.SetRequestHeader('Authorization', 'Bearer ' apiKey)
        t := SnipAiCfg.Timeouts
        req.SetTimeouts(t[1], t[2], t[3], t[4])
        req.Send(body)
        req.WaitForResponse(SnipAiCfg.WaitSecs)
        status   := req.Status
        response := SnipAiResponseUtf8(req)
    } catch as e {
        errMsg := 'Network error: ' e.Message
        return ''
    }

    if SnipAiCfg.Debug {
        dbg := SnipDataPath('SnipAI_debug_response.json')
        try FileDelete(dbg)
        try FileAppend(response, dbg, 'UTF-8')
    }

    ; Surface the API's own error text verbatim. A wrong model name, an expired
    ; key, or an exhausted balance each produce a specific, actionable message,
    ; and swallowing it would turn a 10-second fix into a guessing game.
    if (status != 200) {
        errMsg := 'HTTP ' status ' from OpenAI:`n`n' SubStr(response, 1, 1200)
        return ''
    }

    data := SnipAiJsonParse(response)
    if !IsObject(data) || !data.Has('choices') {
        errMsg := 'Unexpected response shape:`n`n' SubStr(response, 1, 800)
        return ''
    }
    choices := data['choices']
    if !(choices is Array) || choices.Length = 0 {
        errMsg := 'The response contained no choices.'
        return ''
    }
    if !(choices[1] is Map) || !choices[1].Has('message') {
        errMsg := 'The first choice had no message object.'
        return ''
    }
    msg := choices[1]['message']
    if !msg.Has('content') || msg['content'] = '' {
        ; A populated "refusal" is the model declining, which is worth naming
        ; rather than reporting as an empty result.
        if msg.Has('refusal') && msg['refusal'] != ''
            errMsg := 'The model declined: ' msg['refusal']
        else
            errMsg := 'The response contained no text content.'
        return ''
    }
    return msg['content']
}


; Decode the response body explicitly as UTF-8.
;
; NOT req.ResponseText.  WinHttpRequest chooses its decoder from the charset
; parameter of the Content-Type header, and OpenAI sends "application/json"
; with no charset — so ResponseText falls back to Latin-1 and mangles every
; non-ASCII character in the reply.  An em dash (UTF-8 bytes E2 80 94) comes
; back as "â" followed by U+0080 and U+0094, which are INVISIBLE C1 control
; characters — so the damage is worse than it looks on screen, and those
; controls travel into the clipboard and on into Excel.
;
; ResponseBody is the undecoded bytes as a SAFEARRAY, which we walk directly and
; hand to StrGet with the correct encoding.
SnipAiResponseUtf8(req) {
    try {
        arr := req.ResponseBody
        pSA := ComObjValue(arr)          ; VT_ARRAY variant -> SAFEARRAY pointer
        if !pSA
            return ''
        pData := 0
        if DllCall('oleaut32\SafeArrayAccessData', 'Ptr', pSA, 'Ptr*', &pData)
            return ''
        lo := 0, hi := 0
        DllCall('oleaut32\SafeArrayGetLBound', 'Ptr', pSA, 'UInt', 1, 'Int*', &lo)
        DllCall('oleaut32\SafeArrayGetUBound', 'Ptr', pSA, 'UInt', 1, 'Int*', &hi)
        len := hi - lo + 1
        str := (len > 0) ? StrGet(pData, len, 'UTF-8') : ''
        DllCall('oleaut32\SafeArrayUnaccessData', 'Ptr', pSA)
        return str
    } catch {
        ; Last resort only.  This is the mis-decoding path described above, but
        ; a mangled error message still beats no error message at all.
        try return req.ResponseText
        return ''
    }
}

; Fold typographic punctuation down to ASCII.
;
; This is NOT the encoding fix — it runs after the text has been decoded
; correctly.  It exists because scanned documents genuinely contain en dashes,
; em dashes, curly quotes and non-breaking spaces, and the model transcribes
; them faithfully (sometimes; it normalizes them itself at other times, which is
; why output looks inconsistent).  For a table headed into a spreadsheet the
; ASCII forms are almost always what's wanted — a non-breaking space in
; particular will silently stop Excel parsing a cell as a number.
;
; Applied to table cells only.  Copy Text (AI) stays verbatim, since someone
; transcribing prose may well want the real dashes.
SnipAiNormalizePunct(s) {
    ; Named PUNCT, not MAP.  AHK variable names are CASE-INSENSITIVE, so a
    ; static called MAP is the same identifier as the built-in Map class and
    ; shadows it inside this function — the initializer's own Map(...) call then
    ; resolves to the not-yet-assigned static and dies with "this static
    ; variable has not been assigned a value".  Same trap as naming a property
    ; `base`.  Avoid built-in names for locals: Map, Array, Buffer, Gui, Menu,
    ; File, Object, String, Number, Func, Error.
    static PUNCT := Map(
        0x2010, '-',    ; hyphen
        0x2011, '-',    ; non-breaking hyphen
        0x2012, '-',    ; figure dash
        0x2013, '-',    ; en dash     <- the "45–47" case
        0x2014, '-',    ; em dash     <- the empty-cell case
        0x2015, '-',    ; horizontal bar
        0x2212, '-',    ; minus sign
        0x2018, "'",    ; left single quote
        0x2019, "'",    ; right single quote / apostrophe
        0x201A, "'",
        0x201C, '"',    ; left double quote
        0x201D, '"',    ; right double quote
        0x201E, '"',
        0x00A0, ' ',    ; non-breaking space
        0x2007, ' ',    ; figure space
        0x202F, ' ',    ; narrow no-break space
        0x2026, '...')  ; ellipsis
    out := ''
    Loop Parse s {
        o := Ord(A_LoopField)
        if PUNCT.Has(o)
            out .= PUNCT[o]
        else if (o < 32 || (o >= 0x7F && o <= 0x9F))
            out .= ''    ; strip C0/C1 controls outright — never wanted in a cell
        else
            out .= A_LoopField
    }
    return out
}

; Escape a string for embedding in JSON. Everything outside printable ASCII
; becomes \uXXXX, which keeps the finished request body 7-bit clean.
SnipAiEscapeJson(str) {
    out := ''
    Loop Parse str {
        c := A_LoopField
        o := Ord(c)
        if (c = '"')
            out .= '\"'
        else if (c = '\')
            out .= '\\'
        else if (o = 10)
            out .= '\n'
        else if (o = 13)
            out .= '\r'
        else if (o = 9)
            out .= '\t'
        else if (o < 32 || o > 126)
            out .= Format('\u{:04x}', o)
        else
            out .= c
    }
    return out
}

; Reverse of the above, for values coming back out of a JSON string.
; Written as a single left-to-right pass on purpose: the naive approach of
; chained StrReplace calls is wrong, because unescaping \\ first turns the
; literal two-character sequence \\n into a real newline.
SnipAiJsonUnescape(s) {
    if !InStr(s, '\')
        return s
    out := '', pos := 1, len := StrLen(s)
    while (pos <= len) {
        ch := SubStr(s, pos, 1)
        if (ch != '\') {
            out .= ch, pos++
            continue
        }
        esc := SubStr(s, pos + 1, 1)
        switch esc {
            case 'n':  out .= '`n',      pos += 2
            case 'r':  out .= '`r',      pos += 2
            case 't':  out .= '`t',      pos += 2
            case 'b':  out .= Chr(8),    pos += 2
            case 'f':  out .= Chr(12),   pos += 2
            case '/':  out .= '/',       pos += 2
            case '"':  out .= '"',       pos += 2
            case '\':  out .= '\',       pos += 2
            case 'u':  out .= Chr('0x' SubStr(s, pos + 2, 4)), pos += 6
            default:   out .= esc,       pos += 2
        }
    }
    return out
}

; Minimal recursive-descent-ish JSON reader, adapted from the parser already in
; AutoCorrect2's ChatGptWordLookup.ahk, with two corrections: the string
; terminator scan now counts trailing backslashes (an odd count means the quote
; was escaped, an even count means it was not — the original test misread any
; string ending in a literal backslash, e.g. a Windows path), and unescaping is
; delegated to the single-pass function above.
SnipAiJsonParse(jsonStr) {
    key := '', is_key := false
    stack := [tree := []]
    next := '"{[01234567890-tfn'
    pos := 0

    while ((ch := SubStr(jsonStr, ++pos, 1)) != '') {
        if InStr(' `t`n`r', ch)
            continue
        if !InStr(next, ch, true)
            return ''

        obj := stack[1]
        is_array := (obj is Array)

        if i := InStr('{[', ch) {
            val := (i = 1) ? Map() : Array()
            is_array ? obj.Push(val) : obj[key] := val
            stack.InsertAt(1, val)
            next := '"' ((is_key := (ch == '{')) ? '}' : '{[]0123456789-tfn')
        } else if InStr('}]', ch) {
            stack.RemoveAt(1)
            next := (stack[1] == tree) ? '' : (stack[1] is Array) ? ',]' : ',}'
        } else if InStr(',:', ch) {
            is_key := (!is_array && ch == ',')
            next := is_key ? '"' : '"{[0123456789-tfn'
        } else {
            if (ch == '"') {
                i := pos
                while i := InStr(jsonStr, '"', , i + 1) {
                    val := SubStr(jsonStr, pos + 1, i - pos - 1)
                    ; Count the backslashes immediately before this quote.
                    n := 0
                    while (SubStr(val, -(n + 1), 1) = '\')
                        n++
                    if (Mod(n, 2) = 0)          ; even => quote is real
                        break
                }
                if !i
                    return ''

                pos := i
                val := SnipAiJsonUnescape(val)

                if is_key {
                    key := val, next := ':'
                    continue
                }
            } else {
                val := SubStr(jsonStr, pos, i := RegExMatch(jsonStr, '[\]\},\s]|$', , pos) - pos)

                if (val = 'true')
                    val := true
                else if (val = 'false')
                    val := false
                else if (val = 'null')
                    val := ''
                else if IsInteger(val) || IsFloat(val)
                    val := val + 0

                pos += i - 1
            }

            is_array ? obj.Push(val) : obj[key] := val
            next := obj == tree ? '' : is_array ? ',]' : ',}'
        }
    }

    return tree[1]
}


; ══════════════════════════════════════════════════════════════════════════════
; SMALL UTILITIES
; ══════════════════════════════════════════════════════════════════════════════

; Own copy rather than SnipOCR's OcrToolTip, so this module stays independent
; of whether SnipOCR.ahk is present.
SnipAiToolTip(text := '', timeoutMs := 0) {
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

SnipAiCountLines(text) {
    n := 1
    Loop Parse text, '`n', '`r'
        n := A_Index
    return n
}
