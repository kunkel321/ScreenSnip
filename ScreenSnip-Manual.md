# ScreenSnip — User Manual

- **Project:** ScreenSnip.ahk, an AutoHotkey v2 screen capture tool
- **Repository:** https://github.com/kunkel321/ScreenSnip
- **Forum thread:** https://www.autohotkey.com/boards/viewtopic.php?f=83&t=140802
- **Based on:** *Snipper* by FanaticGuru — https://www.autohotkey.com/boards/viewtopic.php?f=83&t=115622

---

## Table of contents

1. [What ScreenSnip is](#1-what-screensnip-is)
2. [Installation](#2-installation)
3. [Quick start](#3-quick-start)
4. [Capturing](#4-capturing)
5. [Freeze Capture](#5-freeze-capture)
6. [Working with a snip](#6-working-with-a-snip)
7. [Adjusting the capture after the fact](#7-adjusting-the-capture-after-the-fact)
8. [Rotate, Straighten, Flip](#8-rotate-straighten-flip)
9. [Exporting](#9-exporting)
10. [OCR](#10-ocr)
11. [Imgur uploads](#11-imgur-uploads)
12. [Menu reference](#12-menu-reference)
13. [Keyboard and mouse reference](#13-keyboard-and-mouse-reference)
14. [Things that will bite you](#14-things-that-will-bite-you)
15. [Tunables](#15-tunables)
16. [Credits](#16-credits)

---

## 1. What ScreenSnip is

ScreenSnip captures a region of your screen and leaves it floating on the desktop as a borderless, always-on-top window. You can have as many of these snips open at once as you like.

That "floating window" part is the whole point. Most capture tools hand you a file or a clipboard blob and get out of the way. ScreenSnip instead gives you a persistent visual reference you can park next to whatever you're working on — a phone number from an email while you fill in a form, a chart from one PDF while you write about it in another, a config value from a webpage that keeps scrolling away.

Three things it does that the built-in Windows tools don't:

**It keeps a frozen snapshot around the edges of your capture.** When you drag a selection, ScreenSnip actually grabs a rectangle several hundred pixels larger than what you asked for and keeps it in memory. So if you clip the bottom of a sentence, you don't re-snip — you drag the snip's bottom edge down and the missing pixels are already there. Nothing on screen has to still be showing.

**It can capture things that vanish when you click.** Context menus, tooltips, and drop-downs all close the moment a mouse button goes down, which makes them impossible to capture with a drag gesture. Freeze Capture solves this with a keyboard trigger that photographs the entire desktop first, then lets you select from that still image.

**It reads text out of the capture.** Two OCR engines are wired in — a fast built-in Windows one, and PaddleOCR for harder material. The PaddleOCR path can also reconstruct a table and hand it to you as TSV, ready to paste into Excel.

---

## 2. Installation

### The portable approach

ScreenSnip is distributed as a script, not a compiled executable. The repository convention — shared across the whole AutoCorrect2 suite — is a **renamed copy of `AutoHotkey64.exe`** sitting next to the `.ahk` file.

Copy `AutoHotkey64.exe` into the ScreenSnip folder and rename it `ScreenSnip.exe`. When you run it, AutoHotkey looks for a script with its own name in its own folder and runs `ScreenSnip.ahk`. Nothing is compiled, so edits to the `.ahk` take effect on the next launch, and the whole folder stays portable — you can drop it on a flash drive and it works on a machine with no AutoHotkey installed.

You can also just run `ScreenSnip.ahk` directly if you have AutoHotkey v2 installed. The renamed-exe trick is about portability, not necessity.

### Files in the folder

| File | Required? | What it does |
|---|---|---|
| `ScreenSnip.ahk` | **Yes** | The main script — capture, snip windows, all the geometry |
| `SnipOCR.ahk` | **Yes** | OCR module. `#Include`d without the `*i` flag, so ScreenSnip will not start without it |
| `OCR.ahk` | Yes, as shipped | Descolada's Windows OCR library. `SnipOCR.ahk` includes it near the top — comment that line out if you don't have it |
| `SnipImgur.ahk` | Optional | Imgur upload. Included with `#Include *i`, so deleting it simply removes the Imgur menus |
| `ImgurClientID.ini` | Created on demand | Holds your Imgur Client ID. **Add this to `.gitignore`** |
| `PaddleOCR-json\` | Optional | The PaddleOCR engine folder, if you want table OCR |

The asymmetry between `SnipOCR.ahk` and `SnipImgur.ahk` is worth noting because it will confuse you exactly once: the Imgur module is genuinely optional and its absence is handled gracefully, but the OCR module is a hard dependency. If you delete `SnipOCR.ahk`, ScreenSnip won't launch at all.

### Starting with Windows

Two options, and which one you want depends on whether you need to capture elevated windows.

**Tray menu → Start with Windows** creates a shortcut in your Startup folder. Simple, works fine, and ScreenSnip will run at normal integrity.

**Task Scheduler with "Run with highest privileges"** is what you need if you want to snip elevated applications. See [section 14](#14-things-that-will-bite-you) for why. A Startup-folder shortcut to an elevation-requesting program is silently skipped by Windows at logon, so the Startup folder is not a route to running elevated — Task Scheduler is.

---

## 3. Quick start

1. Launch ScreenSnip. A scissors icon appears in the system tray.
2. Hold **Ctrl** and **right-click-drag** a rectangle around something on screen.
3. Release. The captured region is now a floating window.
4. **Left-drag** it wherever you want it.
5. Press **Esc** while it's focused to close it, or **F1** for the full hotkey list.

That's the core loop. Everything else in this manual is refinement.

Two shortcuts worth learning immediately: add **Shift** to the capture drag (`Ctrl+Shift+RButton`) to also copy the image to the clipboard, and double-tap **CapsLock** to start a [Freeze Capture](#5-freeze-capture).

---

## 4. Capturing

### The normal drag

Hold `Ctrl` and drag with the **right** mouse button. A translucent overlay follows your drag, with width and height labels in the corner once the selection is big enough to fit them (75 px wide for the W label, 55 px tall for the H label — below that they'd overlap the selection itself).

Release to create the snip. Selections smaller than 8×8 px are discarded, so a stray Ctrl+right-click won't litter your desktop with tiny snips.

Add `Shift` to also drop the image on the clipboard as you capture.

**Why the right button?** Left-drag is the universal "select things" gesture and is claimed by nearly every application. Right-drag is not, so ScreenSnip can take it without fighting anything.

### Show / hide everything

`Shift+PrintScreen` toggles all open snips at once. This is more useful than it sounds — it's how you take a screenshot *of* your desktop without a dozen snips cluttering it, and how you check what's underneath a snip without moving it.

The snips aren't closed, just hidden. Press it again and they all come back where they were.

---

## 5. Freeze Capture

### The problem

Try to capture a context menu with a normal drag and you can't. Pressing a mouse button dismisses the menu, so by the time the drag starts there's nothing left to capture. The same goes for tooltips, drop-down lists, and anything else that closes on a click elsewhere.

### The solution

Freeze Capture is triggered by a **key**, not a click. The instant you press it, ScreenSnip BitBlts the entire virtual desktop into memory and puts up a full-screen backdrop showing that frozen image. The real menu is then free to close — its pixels are already captured.

You then right-drag a selection on the frozen image exactly as you normally would. The snip is cut from the bitmap, never re-read from the screen.

A pleasant consequence of that design: anything ScreenSnip itself floats over the backdrop — the hint message, the dimension labels, the selection rectangle — is invisible to the capture by construction. There's no need for the code to hide its own UI before grabbing, because the grab already happened.

### Using it

| Action | Result |
|---|---|
| Double-tap `CapsLock` (default) | Freeze the screen |
| Right-drag on the frozen image | Select a region |
| Hold `Shift` when you release | ...and copy to clipboard |
| `Esc` | Cancel, unfreeze, capture nothing |

### Choosing a trigger key

The trigger is set by `FreezeCaptureKey` near the top of the script. It ships as `CapsLock`, with `FreezeDoublePress := true`.

The double-press default exists for a specific reason. The hotkey is registered with `~` (pass-through), so the key keeps doing its normal job. On a toggle key like CapsLock or ScrollLock, two presses turn the lock on and then straight back off — net effect zero, lock state untouched. A single-press trigger on the same key would leave CapsLock stuck on every time you used it.

Candidate keys, with the tradeoffs:

- **`ScrollLock`** — arguably the best choice. Almost nothing uses it, it has a status LED, and no application will fight you for it.
- **`CapsLock`** — fine *if* no other AHK script already claims CapsLock. Each script installs its own keyboard hook, and if a hook earlier in the chain consumes the key, ScreenSnip never sees it.
- **`PrintScreen`** — the conventional choice, but SnagIt and Windows 11's Snipping Tool both grab it. Only viable if nothing else on your machine wants it.

Set `FreezeCaptureKey := ''` to disable the built-in trigger entirely.

### The cross-script trigger

If another script already owns the key you'd like to use, don't fight over it. ScreenSnip listens for a registered window message and will start a Freeze Capture whenever it arrives. `RegisterWindowMessage` returns the same ID in every process for a given string, so no shared file and no hard-coded number is needed.

From the script that owns the key:

```ahk
~CapsLock:: {
    static lastTick := 0, msg := DllCall('RegisterWindowMessage'
                                , 'Str', 'AHK_ScreenSnip_FreezeCapture', 'UInt')
    if (A_TickCount - lastTick <= 400) {
        lastTick := 0
        try PostMessage(msg, 0, 0, , 'ahk_id 0xFFFF')
    } else
        lastTick := A_TickCount
    SetCapsLockState('Off')      ; whatever that script normally does
}
```

This is a harmless no-op when ScreenSnip isn't running, so it can live in a library unconditionally.

### The CapsLock nullify option

`FreezeNullifyCapsLock` (default `true` in the shipped config) switches CapsLock back off after *every* press, single or double, so a stray press can't leave it on. It only takes effect when `FreezeCaptureKey` is actually `CapsLock`, so it can't surprise someone who chose a different key.

If you have another script that reads the caps *state* rather than just hotkeying on the key, leave this false.

---

## 6. Working with a snip

A snip is an ordinary window as far as your mouse is concerned — click it to focus it, and the hotkeys in this section apply to whichever snip is focused.

### Mouse gestures

| Gesture | Effect |
|---|---|
| Left-drag | Move the window |
| Right-drag | Pan the image within the frame (hand-tool style) |
| `Alt` + drag an edge or corner | Resize the capture region — trim or grow |
| Right-click | Context menu |
| `Alt` + wheel | Transparency ± 10 |

Right-drag has a small dead zone at the start (`PanClickSlop`, 5 px) so that a plain right-click opens the menu instead of nudging the image a pixel. Drag further than that and it becomes a pan.

Pan sensitivity is set by `PanDragDivisor` (default 3), meaning three pixels of mouse travel move the image one pixel. That sounds sluggish until you try to nudge a single row of text into view, at which point it's exactly right. Set it to 1 for 1:1 tracking. The fractional remainder is carried between frames, so slow drags move smoothly rather than stair-stepping.

### The border and bevel

Each snip gets a colored border (`ShowSnipBorder`, `BorderColor`, `BorderThickness`) with an optional 3D bevel — lighter on the top and left, darker on the bottom and right, both derived from the border color.

The **focused** snip's bevel is drawn at full strength; unfocused snips are dimmed by `Bevel3DInactiveDarknessFactor`. Same shape, same contrast, just darker overall. It's a focus cue that doesn't require a second border color.

The bevel is automatically disabled above `Bevel3DMaxThickness` (default 3 px), because thick beveled frames look chunky.

### The drop shadow

Each snip can cast a soft translucent shadow down and to the right. It's a separate click-through window glued to the snip via `WM_WINDOWPOSCHANGED` — the snip window itself is never touched, which is what keeps the geometry code from having to know about shadows at all.

Like the bevel, the shadow participates in the focus cue: `ShadowOffset` for the active snip, `ShadowOffsetInactive` (smaller) for the rest, so the focused snip appears to lift forward off the desktop.

The shadow is suppressed automatically in two cases: at skewed or non-cardinal angles (a rectangular shadow behind a tilted snip looks wrong), and whenever the snip isn't fully opaque (a shadow behind a see-through window is incoherent).

Toggle it per-snip from the right-click menu.

### Transparency

`Alt+Up` / `Alt+Down` steps opacity by 25; `Alt+wheel` steps by 10. Useful for tracing — drop a snip to half opacity over a document and you can see both at once.

Remember the shadow disappears below full opacity. That's intentional, not a bug.

---

## 7. Adjusting the capture after the fact

This is ScreenSnip's most distinctive feature, and the one most worth understanding properly.

### How it works

When you drag a selection, ScreenSnip doesn't capture just that rectangle. It captures a **frozen master snapshot** extending `CaptureAdjustMargin` pixels (default 250) beyond your selection in every direction, and keeps it in memory for the life of the snip.

What you see in the floating window is a crop of that snapshot. So "adjusting the capture" is really just moving the crop rectangle around inside an image you already have. The screen behind it can have scrolled, closed, or changed entirely — irrelevant. Nothing is ever re-read from the screen.

### Panning the region

Moves the crop over the snapshot. The frame stays put; different pixels show through it.

| Keys | Step |
|---|---|
| `Ctrl+Alt+Arrow` | 1 px |
| `Ctrl+Shift+Alt+Arrow` | 10 px |
| Right-drag | Continuous |

### Resizing the region

Grows or shrinks the crop. The frame changes size to match.

| Keys | Step |
|---|---|
| `Win+Alt+Arrow` | 1 px (Right/Down grow) |
| `Win+Shift+Alt+Arrow` | 10 px |
| `Alt` + drag an edge/corner | Continuous, opposite edge stays put |

### The margin tradeoff

`CaptureAdjustMargin` is the maximum you can pan or grow in any direction before you hit the edge of the snapshot. Bigger margin, more headroom — but a 32-bit bitmap costs `width × height × 4` bytes, and that's per snip.

- `0` — no headroom. The region is fixed at exactly what you selected.
- `150` — comfortable for fixing small clipped edges.
- `250` — the shipped default.
- `99999` — effectively snapshots the entire desktop into every snip.

Oversized values are safe: the number is clamped to the virtual desktop bounds, so you get "everything" and higher RAM use rather than a crash.

Note that Straighten also draws on this margin (see below), so if you deskew a lot, a larger margin buys you more clean rotation before the corners run past the snapshot edge.

### Distinguishing the three "move" operations

Easy to conflate, so:

| Operation | What moves | Keys |
|---|---|---|
| **Nudge window** | The floating window, on your desktop | `Ctrl+Arrow` |
| **Pan region** | The crop, over the frozen snapshot | `Ctrl+Alt+Arrow` |
| **Resize region** | The crop's size | `Win+Alt+Arrow` |

Nudging changes nothing about the image. Panning and resizing change what the image *is*.

---

## 8. Rotate, Straighten, Flip

### Rotate

Turns the **whole snip, frame and all**. The window itself becomes a rotated rectangle.

| Keys | Effect |
|---|---|
| `Alt+Left` / `Alt+Right` | ± 1° |
| `Shift+Alt+Left` / `Right` | Snap to the next 30° |
| Menu → Rotate | 90° CW, 180°, 90° CCW |

At angles other than 0/90/180/270 the border is suppressed and the corners are keyed out with magenta (`TransColor`, `0xFF00FF` — chosen because that exact value essentially never occurs in a real screenshot). See [section 14](#14-things-that-will-bite-you) for the known halo artifact.

### Straighten (deskew)

Tilts the **image inside a fixed rectangular frame**. The frame stays axis-aligned; only the content rotates.

| Keys | Effect |
|---|---|
| `Alt+,` / `Alt+.` | ± 1° (CCW / CW) |
| `Shift+Alt+,` / `.` | ± 0.5°, fine |
| Menu → Straighten → Reset | Back to level |

Clamped to `StraightenMaxAngle` (15°), though in practice the margin runs out first.

**The main use case is squaring up a skewed table before OCR.** A photographed or scanned table that sits a couple of degrees off level confuses the row-and-column clustering badly. Straighten it, then `Alt`-drag an edge to trim the exposed corners, then run Copy Table.

The pivot behaviour is subtle but deliberate: content rotates about the centre of the crop *as it was when you began straightening*, and that pivot is then held fixed until you return to level. This means you can pan around afterwards and the frame slides over one stable rotated image — no swirling — while the tilt itself still turns about what you were actually looking at.

### Flip

| Keys | Effect |
|---|---|
| `Shift+Left` / `Shift+Right` | Flip horizontal |
| `Shift+Up` / `Shift+Down` | Flip vertical |

---

## 9. Exporting

### Clipboard

`Ctrl+C`, or menu → Copy to Clipboard. Copies exactly what you see — current crop, rotation, straighten, and flips all applied.

### Save to file

`Ctrl+S`, or menu → Save Image As…

- Formats: **PNG**, **JPG/JPEG**, **BMP**. Type no extension and you get PNG.
- Default filename is `ScreenSnip_yyyyMMdd_HHmmss.png`.
- Defaults to your Pictures folder the first time, then remembers the last folder you used for the rest of the session.
- **PNG saves with real transparency.** JPG and BMP can't carry an alpha channel, so a rotated snip's corners come out filled rather than transparent. If you've rotated something and want clean corners, save as PNG.

Everything goes through the same rendering pipeline (`BuildSaveBitmap`), so saving, clipboard, and Imgur upload all produce identical pixels.

---

## 10. OCR

Three actions live under the right-click menu's **OCR** submenu. All three copy their result to the clipboard and report with a brief tooltip.

| Action | Engine | Best for |
|---|---|---|
| Copy Text (Windows) | Windows.Media.Ocr | Quick grabs. Instant, no setup beyond one library file |
| Copy Text (PaddleOCR) | PaddleOCR-json | Harder material — small text, low contrast, unusual fonts |
| Copy Table (PaddleOCR) | PaddleOCR-json | Grids. Reconstructs rows and columns, outputs TSV for Excel |

### Setting up Windows OCR

Download `OCR.ahk` from **https://github.com/Descolada/OCR** and drop it next to `ScreenSnip.ahk`. `SnipOCR.ahk` includes it near the top; make sure that line isn't commented out.

If the library is missing, the Windows OCR menu item reports as much and everything else keeps working.

### Setting up PaddleOCR

1. Download **PaddleOCR-json** (Windows x64) from https://github.com/hiroi-sora/PaddleOCR-json/releases/latest
2. Unzip it. You want the folder containing `PaddleOCR-json.exe` **and** its `models` subfolder — these must stay together.
3. Point `OcrCfg.PaddleExe` at that `.exe`. The default expects `PaddleOCR-json\PaddleOCR-json.exe` beside the script.
4. Leave `OcrCfg.LangConfig` at `models\config_en.txt` for English. **The engine defaults to Simplified Chinese if this is blank.** Other configs shipped in the release: `config_chinese_cht.txt`, `config_japan.txt`, `config_korean.txt`.

Requires a CPU with AVX — any modern Core or Ryzen. If yours lacks it, RapidOCR-json is a drop-in substitute with the same JSON output.

### How table reconstruction works

PaddleOCR doesn't return a table. It returns loose text blocks with bounding boxes. ScreenSnip rebuilds the grid by clustering those boxes: blocks whose vertical centres are close become a row, blocks whose left edges are close become a column.

Both tolerances are expressed as a fraction of the **median text-block height**, so they scale automatically with font size and with the upscale factor — you shouldn't need to retune them when you switch between a small screenshot and a large one.

| Setting | Default | Raise it if... | Lower it if... |
|---|---|---|---|
| `RowTol` | 0.60 | One visual row is splitting in two | Two rows are merging |
| `ColTol` | 1.20 | One column is splitting | Two columns are merging |

### Wrapped cells and reflow

A cell whose text wraps onto three lines arrives as three separate blocks, so a 5-row table can come out as 31 rows. Reflow stitches them back together.

The decision is made by measuring the **whitespace between consecutive rows** — not centre-to-centre pitch, which is contaminated by text height. In a table with wrapped cells those gaps are strongly bimodal: small gaps are line spacing inside a cell, large gaps are actual row borders. Split them into two groups, and reflow only if the large group is clearly bigger than the small one (`ReflowRatio`, default 1.8). In a table with no wrapping the gaps are all the same size and nothing gets merged.

But gaps alone aren't enough, and a real document proved it: on a scanned service grid, an 85 px gap sat *inside* a cell because a faint dash was never detected, while a genuine row border was only 39 px. The geometry lied. So there's a second test — the **anchor column** (`ReflowAnchorCol`, default column 1), which holds a label on every logical row and is blank on continuation lines. A new logical row must satisfy **both**: a big gap above it *and* content in the anchor column. Set it to 0 to use gaps alone; it falls back to gaps automatically if the anchor column turns out to be too sparse.

### The "this isn't a table" guard

If more than `NotATableWarn` (default 60%) of the text sits in a single column, the snip is almost certainly prose or a form rather than a grid, and Copy Text will do a far better job. ScreenSnip offers to switch rather than silently producing a mangled TSV.

Measured on real documents: a numeric grid ran 7%, a rubric 27%, a scanned service matrix 40% — but a one-column form with bullets hit 77%. Set to 0 to disable the prompt.

### Confidence

`MinScore` defaults to **0 — keep everything** — and that default is deliberate.

The reasoning: a confidence filter would earn its keep if a junk block could *shift* your data, but it can't. Every block is snapped to a column anchor, so dropping one leaves a hole and moves nothing. Filtering therefore buys no safety and costs real cells. And a hole is worse than a typo — a misread value is visible and fixable, whereas a dropped one just looks like a legitimately empty cell. On a real 21×20 table, `MinScore` 0.5 silently discarded 41% of it.

Raise it only when you're OCRing prose and want to suppress noise.

Instead of dropping cells, Copy Table **counts** the shaky ones (confidence below 0.6) and tells you in the completion tooltip. The table's *shape* is reliable; individual readings may not be. Those are the cells to eyeball against the original.

`MarkBelow` will append `?` to low-confidence cells so you can find them with Ctrl+F in Excel — but note that makes those cells text rather than numbers, so leave it at 0 for tables you'll compute on.

### Upscaling

Screen text is typically 10–14 px tall, right at the edge of what OCR engines handle well. `OcrCfg.Upscale` (default 3) bicubically enlarges the image before OCR, which makes a large accuracy difference for almost no cost.

There's a trap here worth knowing about. Paddle downsizes any image whose long edge exceeds `limit_side_len`, which would silently undo the upscaling. A 3× upscale of a modest snip lands around 5000 px, so a fixed limit of 2880 would shrink it straight back to an effective 1.7×. `OcrCfg.LimitSideLen := 0` means **auto** — size the limit to the image so no downscaling ever happens. That's what you want. `MaxSideLen` (6144) is the safety ceiling; if you're exceeding it, lower `Upscale` rather than raising the ceiling.

### Debugging a bad table

Set `OcrCfg.Debug := true` and three timestamped files appear next to the script:

| File | Contents |
|---|---|
| `SnipOCR_<stamp>_image.png` | Exactly what the engine was fed |
| `SnipOCR_<stamp>_raw.json` | Exactly what the engine returned |
| `SnipOCR_<stamp>_blocks.txt` | How ScreenSnip clustered it — **the useful one** |

The blocks dump is the one to read. When a table comes out wrong there are only two suspects — the engine misread the text, or the clustering misplaced it — and you cannot tell which from the TSV alone. The dump shows you the per-block coordinates, scores, column anchors, computed tolerances, and what reflow decided and why.

Files are stamped per run. They used to use fixed names, which meant each OCR clobbered the previous one's evidence — very easy to end up comparing a run against itself without noticing.

---

## 11. Imgur uploads

Entirely optional. Delete `SnipImgur.ahk` and the feature vanishes cleanly — the `#Include` uses the `*i` flag and every menu is built behind an `IsSet(Imgur)` test.

### One-time setup

You need a free Imgur account and a Client ID:

1. Create an account at https://imgur.com/register — any email address will do. There's no paid tier involved.
2. Signed in, go to **Settings → Applications** (https://imgur.com/account/settings/apps).
3. Add a new application. Name it anything.
4. Authorization type: **"Anonymous usage without user authorization"**.
5. Leave the callback URL blank and submit.
6. Copy the **Client ID**. Ignore the Client Secret — anonymous uploads never use it.
7. Paste it into ScreenSnip via the Uploader's **Client ID…** button.

It's stored in `ImgurClientID.ini` beside the script. **Add that file to `.gitignore`.** A Client ID isn't a password, but it's rate-limited against your account and you don't want strangers spending your daily allowance.

### Two ways in

**Right-click a snip → Imgur → Upload → [img] Tag** is the one-click path. It renders the snip, uploads it, and puts a BBCode `[img]` tag on your clipboard ready to paste into a forum post.

**Imgur Uploader…** opens the full dialog. Reachable two ways:

- Right-click a snip → **Imgur → Imgur Uploader…** — opens with that snip pre-loaded
- **Tray menu → Imgur Uploader…** — opens empty, for files already on disk

The tray route is the one to use for an animated GIF or an old screenshot that ScreenSnip never captured. Drag a file onto the dialog, or use **Browse…**.

### The Uploader dialog

| Control | Purpose |
|---|---|
| Path box | The file to upload. Drag-and-drop onto the window works |
| Browse… | File picker |
| Upload | Sends it |
| Client ID… | Opens the setup dialog, with clickable links to Imgur |
| Copy as: | Link format — changing it re-copies immediately |
| Copy | Re-copy the current link |
| Open in Browser | Opens the Imgur *page* for the upload |
| Delete This Upload | Removes it from Imgur — read the warning below |

Link formats offered:

- **Direct link** — `https://i.imgur.com/ID.png`, the embeddable file
- **BBCode [img]** — the default, and what the one-click menu item always emits
- **BBCode thumbnail linked** — a 640 px thumbnail that links to the full image, so a big screenshot doesn't blow out a forum thread's layout
- **Markdown**
- **HTML img tag**
- **Page link** — Imgur's viewer page, with its nav bar and buttons
- **Direct MP4** *(animated only)*
- **HTML5 video tag** *(animated only)*

### Page link vs direct link

Imgur's API returns a link to the image's *page* (`imgur.com/7Wqu8C8`). Forum `[img]` tags and HTML `<img>` tags need the *file* (`i.imgur.com/7Wqu8C8.png`).

ScreenSnip derives the direct link from the response's `id` and `type` fields rather than by editing the URL text. `type` is the MIME type of the image **as Imgur stored it**, which matters because Imgur re-encodes BMP and TIFF uploads to PNG. Guessing the extension from the source filename would produce a dead link in those cases.

### Deleting an upload — read this before relying on it

An **anonymous upload isn't owned by your account** and doesn't appear in it. The only handle on it is the "deletehash" that Imgur returns, and ScreenSnip deliberately keeps **no log file** — so the deletehash is remembered for the current session only.

**Once ScreenSnip exits, an anonymous upload is effectively permanent.**

Delete while you still can via *Imgur Uploader… → Delete This Upload*, which acts on the most recent upload of the session.

Because that's a lot of consequence for one menu click on a snip that might be showing an email or a password field, the one-click path asks for confirmation by default. Set `Imgur.ConfirmBeforeUpload := false` in `SnipImgur.ahk` once the flow feels familiar.

### Size limit

**Treat 10 MB on disk as the ceiling**, and note this is the *API's* limit, not Imgur's.

Imgur's website accepts 20 MB for stills and 200 MB for animated files. The JSON API that ScreenSnip posts to caps out around 10 MB, and base64 encoding inflates the payload by roughly a third on top of whatever the file weighs.

Some tools get past this by posting `multipart/form-data` with raw bytes instead of a base64 form field. ScreenSnip deliberately doesn't — it would mean hand-rolling a MIME body and a SafeArray for a case that a smaller GIF solves just as well.

For an oversized GIF the practical fix is to shrink it: drop frames, reduce the dimensions, or run a lossy pass. `gifsicle -O3 --lossy=80` is startlingly effective.

### Animated GIFs

They work, with one caveat you should know about.

Imgur re-encodes any GIF over roughly **2 MB** to GIFV — an MP4 in a wrapper, audio stripped — and then reports the stored type back as `video/mp4`. A naive uploader builds the direct link from that type and produces `i.imgur.com/ID.mp4`, which renders as a **broken image** inside an `[img]` tag on every forum there is. This is why an animated upload can look like it failed when in fact it uploaded perfectly.

ScreenSnip detects the conversion and keeps a `.gif` URL as the primary link, since Imgur goes on serving the GIF alongside the video. The `.mp4` and `.gifv` URLs remain available from the "Copy as:" dropdown for anywhere that can play video.

One consequence: Imgur's thumbnails of an animated image are **still frames**, so "BBCode thumbnail linked" on a GIF gives a motionless preview that links through to the moving version. Usually the polite thing to post in a thread; occasionally not what you wanted.

### Rate limits

Roughly 1,250 uploads and 12,500 requests per day per Client ID. Remaining credits are shown in the Uploader's status line after each upload.

### What actually gets uploaded

Exactly what you see: the snip's current crop, flips, rotation, and straighten, rendered through the same pipeline Save Image As uses. It's written to a temporary PNG in `%TEMP%`, uploaded, and deleted immediately. Orphaned temp files from a crash are swept on the next open of the dialog.

---

## 12. Menu reference

### Right-click menu (on a snip)

| Item | Notes |
|---|---|
| Copy to Clipboard | |
| Save Image As… | `Ctrl+S` |
| **OCR** → | Copy Text (Windows) · Copy Text (PaddleOCR) · Copy Table (PaddleOCR) |
| **Imgur** → | Upload → [img] Tag · Imgur Uploader… *(only if `SnipImgur.ahk` is present)* |
| **Rotate** → | 90° CW · 180° · 90° CCW |
| **Flip** → | Horizontal · Vertical |
| **Straighten** → | CW · CCW · Reset Straighten |
| **Nudge Position** → | Moves the window |
| **Pan Region** → | Moves the crop |
| **Resize Region** → | Resizes the crop |
| Border | Checkable toggle, per snip |
| Shadow | Checkable toggle, per snip |
| Close This Snip | `Esc` |
| Close All Snips | |
| Help | `F1` |

Menu items that have a hotkey display it right-aligned as a reminder. The directional submenus use a 1 px step; hold Shift with the equivalent hotkey for 10 px. Greyed-out lines like "Hold Shift → ±10 px" are hints, not clickable items.

The menu acts on the snip you right-clicked, which is not necessarily the focused one.

### Tray menu

| Item | Notes |
|---|---|
| **ScreenSnip** *(or* **ScreenSnip (admin)** *)* | Disabled title. Shows elevation state at a glance |
| *(standard AHK items)* | Open, Help, Window Spy, Reload, Edit, Suspend, Pause, Exit |
| Freeze Capture | Same as the trigger key. A discoverable way in, and a fallback when another script has won the race for the key |
| Start with Windows | Checkable. Creates/removes a Startup folder shortcut |
| Imgur Uploader… | *(only if `SnipImgur.ahk` is present)* |
| ScreenSnip Help | |

The `(admin)` suffix on the title is worth glancing at whenever a capture mysteriously doesn't work — see the next section.

---

## 13. Keyboard and mouse reference

Most snip hotkeys are context-sensitive: they only fire when a snip window is focused, so they don't interfere with anything else.

### Capturing

| Keys | Action |
|---|---|
| `Ctrl` + RButton drag | Capture a region |
| `Ctrl+Shift` + RButton drag | Capture and copy to clipboard |
| Double-tap `CapsLock` | Freeze the screen (configurable) |
| `Shift+PrintScreen` | Show / hide all snips |

### On a snip

| Keys | Action |
|---|---|
| `F1` | Help |
| `Esc` | Close this snip |
| `Ctrl+C` | Copy image to clipboard |
| `Ctrl+S` | Save image as… |

### Move the window

| Keys | Action |
|---|---|
| `Ctrl+Arrow` | ± 1 px |
| `Ctrl+Shift+Arrow` | ± 10 px |
| Left-drag | Free |

### Adjust the capture region

| Keys | Action |
|---|---|
| `Ctrl+Alt+Arrow` | Pan ± 1 px |
| `Ctrl+Shift+Alt+Arrow` | Pan ± 10 px |
| Right-drag | Pan, continuous |
| `Win+Alt+Arrow` | Resize ± 1 px |
| `Win+Shift+Alt+Arrow` | Resize ± 10 px |
| `Alt` + drag edge/corner | Resize, continuous |

### Rotate, straighten, flip

| Keys | Action |
|---|---|
| `Alt+Left` / `Alt+Right` | Rotate ± 1° |
| `Shift+Alt+Left` / `Right` | Snap to next 30° |
| `Alt+,` / `Alt+.` | Straighten ± 1° |
| `Shift+Alt+,` / `.` | Straighten ± 0.5° |
| `Shift+Left` / `Shift+Right` | Flip horizontal |
| `Shift+Up` / `Shift+Down` | Flip vertical |

### Transparency

| Keys | Action |
|---|---|
| `Alt+Up` / `Alt+Down` | ± 25 |
| `Alt+wheel` | ± 10 |

---

## 14. Things that will bite you

### You can't snip an elevated window unless ScreenSnip is also elevated

This is the big one, and it isn't a bug — it's Windows UIPI (User Interface Privilege Isolation). A normal-integrity process can't hook input over a higher-integrity window. If you have XYplorer, VSCode, or anything else running as admin, ScreenSnip at normal integrity can't capture over it.

Symptoms are confusing: dragging a selection *onto* such a window can leave the rectangle stuck on screen, because the button-release event never reaches ScreenSnip's hook. Press **Esc** to clear a stuck rectangle — that's the safety valve.

**Check the tray menu title.** It reads `ScreenSnip (admin)` when elevated. `A_IsAdmin` is fixed at launch, so this is reliable.

**The fix is Task Scheduler, not the Startup folder.** An elevation-requesting program in the Startup folder is silently blocked at logon — Windows won't auto-approve a UAC prompt. Create a task with "Run with highest privileges", triggered at logon, and set **Start in** to the script's folder. Also uncheck "Start the task only if the computer is on AC power" on the Conditions tab if you're on a laptop; it's ticked by default and is a classic silent-failure trap.

**A confusing corollary:** launching `ScreenSnip.exe` from within an already-elevated file manager makes it inherit the parent's admin token. So it works that session and mysteriously stops the next time you launch it normally. If elevation seems intermittent, this is usually why.

### Drag-and-drop into the Imgur Uploader when elevated

Same UIPI wall, opposite direction. Explorer runs at medium integrity; an elevated ScreenSnip runs at high; messages from the former to the latter are silently discarded. Dragging a file from your Desktop onto the Uploader used to do nothing at all — no error, no beep, no cursor change.

This is handled now. `ImgurAllowDropsWhenElevated()` uses `ChangeWindowMessageFilterEx` to whitelist the three drop-related messages (`WM_DROPFILES`, `WM_COPYDATA`, and the undocumented `WM_COPYGLOBALDATA`) on the Uploader's window alone. Per-window scope, three messages — nothing else about the process's isolation changes.

### The magenta halo on rotated snips

At angles other than 0/90/180/270, a fringe of magenta pixels can appear around the edge of a snip. This is the transparency color key bleeding through at the anti-aliased boundary.

It's a display artifact only. **Saved PNGs and Imgur uploads are unaffected** — they go through a separate path that produces genuinely transparent corners rather than the color key. Known issue; cosmetic.

### Borders disappear when you rotate

Deliberate. A rectangular border doesn't map onto a tilted snip, so it's suppressed at non-cardinal angles. Same rule applies to the drop shadow and to Alt-edge-drag resizing.

### Two scripts can't share a hotkey

Each AHK script installs its own keyboard hook. Whichever hook sits earlier in the chain and *suppresses* a key wins, and the other script never sees it. If your Freeze Capture trigger does nothing, something else probably owns it.

Don't fight it — use the [cross-script message trigger](#the-cross-script-trigger) and let the script that already owns the key broadcast to ScreenSnip.

### Straighten runs out of room

Tilting the image pulls in pixels from outside the current crop, and those come from the `CaptureAdjustMargin` snapshot. Past a certain angle you run out and the corners go empty. Increase the margin if you deskew a lot.

### Copy Table on something that isn't a table

You'll get a prompt offering plain text instead. Take it. Forms and prose put nearly all their text in one column, and the grid reconstruction has nothing sensible to do with that.

### JPG and BMP lose transparency

Only PNG carries an alpha channel. Rotate a snip and save it as JPG and the corners come out filled, not transparent.

### Deleting SnipOCR.ahk breaks the script

Unlike `SnipImgur.ahk`, the OCR module is included without the `*i` flag. ScreenSnip won't start without it. If you don't want OCR, keep the file and comment out its `#Include OCR.ahk` line instead.

---

## 15. Tunables

All in the settings block near the top of `ScreenSnip.ahk` unless noted. Values shown are the shipped defaults.

### Capture

| Setting | Default | Purpose |
|---|---|---|
| `SelectionColor` | `'b58500'` | Selection overlay color while dragging |
| `CaptureAdjustMargin` | `250` | Snapshot headroom in px, per side |
| `ShowDimensionLabels` | `true` | Master switch for W×H labels |
| `InfoFontSize` | `10` | Label font size |
| `InfoWMinWidth` / `InfoHMinHeight` | `75` / `55` | Minimum selection size before each label shows |
| `InfoWHOffsetRight` / `InfoWHOffsetBottom` | `38` / `25` | Label inset from the edges |

### Freeze Capture

| Setting | Default | Purpose |
|---|---|---|
| `FreezeCaptureKey` | `'CapsLock'` | Trigger key. `''` disables |
| `FreezeDoublePress` | `true` | Require a double press |
| `FreezeDoublePressTime` | `400` | Max ms between the two presses |
| `FreezeNullifyCapsLock` | `true` | Force CapsLock off after every press. CapsLock only |
| `ShowFreezeHint` | `true` | Show the hint pill over the backdrop |
| `FreezeHintText` | *(see script)* | Hint wording. `` `n `` for line breaks |
| `FreezeHintFontSize` / `FontName` | `15` / `'Segoe UI'` | |
| `FreezeHintTextColor` / `BackColor` | `'FFFFFF'` / `'1E1E1E'` | Hex RRGGBB |
| `FreezeHintAlpha` | `215` | Pill opacity, 0–255 |
| `FreezeHintCornerRadius` | `16` | Corner rounding in px |

### Interaction

| Setting | Default | Purpose |
|---|---|---|
| `PanDragDivisor` | `3` | Mouse px per 1 px of pan. `1` = 1:1 |
| `PanClickSlop` | `5` | Drag distance below which it's a right-click |
| `EdgeGrabZone` | `6` | Grabbable band inward from each edge |

### Straighten

| Setting | Default | Purpose |
|---|---|---|
| `StraightenStep` | `1` | Degrees per `Alt+,` / `Alt+.` |
| `StraightenFineStep` | `0.5` | Degrees per `Shift+Alt+,` / `.` |
| `StraightenMaxAngle` | `15` | Hard clamp |

### Appearance

| Setting | Default | Purpose |
|---|---|---|
| `ShowSnipBorder` | `true` | |
| `BorderColor` | `SelectionColor` | Matches the selection overlay by default |
| `BorderThickness` | `2` | px |
| `Bevel3D` | `true` | 3D floating look |
| `Bevel3DMaxThickness` | `3` | Bevel auto-disables above this |
| `Bevel3DStrength` / `InactiveStrength` | `0.55` / `0.55` | Blend toward white/black, 0–1 |
| `Bevel3DInactiveDarknessFactor` | `0.2` | How much both edges dim when unfocused |
| `ShowSnipShadow` | `true` | Default for new snips |
| `ShadowColor` | `0x000000` | Hex only — GDI+ needs numeric RGB |
| `ShadowOffset` / `ShadowOffsetInactive` | `7` / `4` | Down/right offset, logical px |
| `ShadowBlur` | `6` | Edge softness. Keep ≤ `ShadowOffset` for a drop rather than a halo |
| `ShadowAlpha` | `105` | Peak opacity, 0–255 |
| `TransColor` | `0xFF00FF` | Magenta color key for rotated corners |

### OCR (in `SnipOCR.ahk`, class `OcrCfg`)

| Setting | Default | Purpose |
|---|---|---|
| `PaddleExe` | `A_ScriptDir\PaddleOCR-json\PaddleOCR-json.exe` | Engine path |
| `LangConfig` | `models\config_en.txt` | **Blank defaults to Chinese** |
| `Upscale` | `3` | Pre-OCR enlargement |
| `LimitSideLen` | `0` | `0` = auto, never downscale. Recommended |
| `MaxSideLen` | `6144` | Safety ceiling for auto mode |
| `RotateFill` | `0xFFFFFF` | Corner fill for rotated snips. `0x000000` for light-on-dark |
| `MinScore` | `0.0` | Confidence filter. Keep at 0 for tables |
| `MarkBelow` | `0.0` | Append `?` below this confidence |
| `RowTol` / `ColTol` | `0.60` / `1.20` | Clustering tolerances, × median text height |
| `Reflow` | `true` | Stitch wrapped cells back together |
| `ReflowRatio` | `1.8` | Gap separation required before reflowing |
| `ReflowAnchorCol` | `1` | Key column. `0` = gaps alone |
| `ReflowGapFactor` | `1.8` | What counts as a "big" gap |
| `NotATableWarn` | `0.60` | Single-column density that triggers the prose prompt |
| `Debug` | `false` | Write the three diagnostic files |

### Imgur (in `SnipImgur.ahk`, class `Imgur`)

| Setting | Default | Purpose |
|---|---|---|
| `ConfirmBeforeUpload` | `true` | Ask before the one-click upload |
| `ProgressDelayMs` | `500` | Delay before the progress window appears |
| `ResolveTimeout` | `8000` | DNS, ms |
| `ConnectTimeout` | `10000` | ms |
| `SendTimeout` | `30000` | ms |
| `ReceiveTimeout` | `60000` | Real ceiling on a wedged upload |

---

## 16. Credits

**ScreenSnip** is adapted by **kunkel321** with **Claude**, from **Snipper** by **FanaticGuru**.

The post-capture adjust-region idea — the frozen master snapshot that lets you pan and resize after the fact — was suggested by AutoHotkey forum user **alnz123**.

**OCR.ahk** for Windows.Media.Ocr is by **Descolada** — https://github.com/Descolada/OCR

**PaddleOCR-json** is by **hiroi-sora** — https://github.com/hiroi-sora/PaddleOCR-json

Bug reports and feature suggestions are welcome on the [AutoHotkey forum thread](https://www.autohotkey.com/boards/viewtopic.php?f=83&t=140802) or the [GitHub repository](https://github.com/kunkel321/ScreenSnip).
