; ==============================================================================
;
;                              SnipImgur.ahk
;
;  Optional Imgur-upload add-on for ScreenSnip.ahk.
;  Made by kunkel321 / Claude.
;  Version Date: 8-11-2026
;
;  This file is OPTIONAL.  ScreenSnip.ahk includes it with `#Include *i`, and
;  builds its context-menu submenu only `if IsSet(Imgur)` — so deleting this
;  file, or commenting out that #Include line, simply removes the Imgur submenu.
;  Nothing else in ScreenSnip changes.
;
;  It contains NO top-level executable code (class and function definitions
;  only), so it is safe to include at the very end of ScreenSnip.ahk.
;
;  ---------------------------------------------------------------------------
;  ONE-TIME SETUP  —  you need a FREE Imgur account plus a Client ID
;  ---------------------------------------------------------------------------
;    1. Create a free account at  https://imgur.com/register
;       (Any e-mail address will do.  There is no paid tier involved here —
;       "free account" is genuinely all that's required.)
;    2. Signed in, go to  https://imgur.com/account/settings/apps
;       ("Applications" in your account settings.)
;    3. Add a new application.  Name it anything, e.g. "ScreenSnip Uploader".
;    4. Authorization type:  "Anonymous usage without user authorization"
;    5. Callback URL: leave blank (that field is only for the OAuth option).
;    6. Submit, then copy the Client ID.  Ignore the Client Secret —
;       anonymous uploads never use it.
;    7. In ScreenSnip, right-click a snip > Imgur > Imgur Uploader… and paste
;       the Client ID via the "Client ID…" button.
;
;    The Client ID is stored in  ImgurClientID.ini  beside ScreenSnip.ahk.
;    ADD THAT FILE TO .gitignore.  A Client ID isn't a password, but it is
;    rate-limited against YOUR account — you don't want strangers spending
;    your daily upload allowance.
;
;  ---------------------------------------------------------------------------
;  WHAT GETS UPLOADED
;  ---------------------------------------------------------------------------
;    Exactly what you see: the snip's current crop, flips, rotation and
;    straighten, rendered through ScreenSnip's own BuildSaveBitmap() — the same
;    pipeline "Save Image As…" uses.  It is written to a temporary PNG in
;    %TEMP%, uploaded, and deleted immediately afterward.
;
;  ---------------------------------------------------------------------------
;  PAGE LINK vs DIRECT LINK
;  ---------------------------------------------------------------------------
;    Imgur's API returns a link to the image's *page* (imgur.com/7Wqu8C8),
;    which carries the nav bar, favourite button, etc.  Forum [img] tags and
;    <img> tags need the *direct* file (i.imgur.com/7Wqu8C8.png).
;    We derive the direct link from the response's `id` and `type` fields
;    rather than editing the URL text — `type` is the MIME type of the image
;    as Imgur STORED it, which matters because Imgur re-encodes BMP and TIFF
;    uploads to PNG.  Guessing the extension from the source filename would
;    produce a dead link in those cases.
;
;    Thumbnails come from a letter appended to the image ID:
;      s = 90x90 square    b = 160x160 square    t = 160x160
;      m = 320x320         l = 640x640           h = 1024x1024
;    e.g. i.imgur.com/7Wqu8C8l.png .  The "BBCode thumbnail linked" format
;    uses `l` so a big screenshot doesn't blow out a forum thread's layout.
;
;  ---------------------------------------------------------------------------
;  DELETING AN UPLOAD  —  read this before you rely on it
;  ---------------------------------------------------------------------------
;    An ANONYMOUS upload isn't owned by your account and doesn't appear in it.
;    The only handle on it is the "deletehash" Imgur returns, and this script
;    deliberately keeps NO log file — so the deletehash is remembered for the
;    current ScreenSnip session ONLY.  Once ScreenSnip exits, an anonymous
;    upload is effectively permanent.
;
;    Delete while you still can via:  Imgur > Imgur Uploader… > Delete This
;    Upload  (acts on the most recent upload of this session).
;
;    If you want uploads that live in your account and can be managed from the
;    Imgur website forever, see "UPLOADING TO YOUR ACCOUNT" at the bottom.
;
;  ---------------------------------------------------------------------------
;  NOTES
;  ---------------------------------------------------------------------------
;    - Rate limit is roughly 1,250 uploads / 12,500 requests per day per
;      Client ID.  Remaining credits show in the Uploader's status line.
;    - Drag-and-drop works even when ScreenSnip is running elevated.  It
;      doesn't by default — UIPI blocks messages from non-elevated Explorer —
;      so ImgurAllowDropsWhenElevated() whitelists the three drop-related
;      messages on the Uploader's window alone.  See the comment there.
;
;  ---------------------------------------------------------------------------
;  SIZE LIMIT  —  10 MB, and it is the API's limit, not the website's
;  ---------------------------------------------------------------------------
;    Imgur's WEBSITE takes 20 MB for stills and 200 MB for animated files.
;    The JSON API this file posts to does not: it caps out around 10 MB, and
;    base64 encoding inflates the payload by roughly a third on top of that,
;    so treat 10 MB on disc as the real ceiling.
;
;    ShareX and friends get past it by posting multipart/form-data with raw
;    bytes instead of a base64 form field.  That was deliberately not done
;    here — it would mean hand-rolling a MIME body and a VT_UI1 SafeArray for
;    a case that a smaller GIF solves just as well.
;
;    For an oversized GIF the practical fix is to shrink it: drop frames,
;    reduce dimensions, or run a lossy pass (gifsicle -O3 --lossy=80 is
;    startlingly effective).
;
;  ---------------------------------------------------------------------------
;  ANIMATED GIFs  —  they work, but Imgur rewrites them
;  ---------------------------------------------------------------------------
;    Imgur re-encodes any GIF over roughly 2 MB to GIFV (an MP4 in a wrapper,
;    audio stripped) and then reports the STORED type back as video/mp4.
;    Building the direct link from `type` alone therefore yields
;    i.imgur.com/ID.mp4 — which renders as a BROKEN IMAGE inside an [img] tag
;    on every forum there is.  That is the whole reason an animated upload can
;    look like it "didn't work" when in fact it uploaded fine.
;
;    Upload() detects the conversion (via the response's `animated` flag) and
;    keeps a .gif URL as the primary link, since Imgur goes on serving the GIF
;    alongside the video.  The mp4 and gifv URLs are still available from the
;    Uploader's "Copy as:" dropdown for anywhere that can play video.
;
;    One consequence worth knowing: Imgur's thumbnails of an animated image are
;    STILL frames, so "BBCode thumbnail linked" gives a motionless preview that
;    links through to the moving version.  Usually what you want in a forum
;    thread; occasionally not.
; ==============================================================================


; ==============================================================================
; class Imgur  —  settings, API core, and pure helpers
; ==============================================================================
; Everything lives inside the class so this file can't collide with any name in
; ScreenSnip.ahk, and so `IsSet(Imgur)` is a reliable "is the add-on loaded?"
; test.  Class statics are initialised at script start, BEFORE the auto-execute
; section runs, which is why that test works even though the #Include sits at
; the very bottom of ScreenSnip.ahk.
class Imgur {

    ; ══════════════════════════════════════════════════════════════════════════
    ; USER SETTINGS — adjust these to taste
    ; ══════════════════════════════════════════════════════════════════════════

    ; Ask "are you sure?" before the one-click  Imgur > Upload → [img] Tag ?
    ; An upload is PUBLIC to anyone with the link, and (see the header) an
    ; anonymous upload can only be deleted during the session that made it.
    ; That's a lot of consequence for one menu click on a snip that might be
    ; showing an e-mail or a password field, so this defaults to true.
    ; Set false once the flow feels familiar.
    static ConfirmBeforeUpload := SnipCfg('SnipImgur', 'ImgurConfirmBeforeUpload', true)

    ; Milliseconds an upload must run before the little progress/Cancel window
    ; appears.  Small uploads finish faster than this and never flash a dialog.
    static ProgressDelayMs := SnipCfg('SnipImgur', 'ImgurProgressDelayMs', 500)

    ; WinHttp timeouts, in milliseconds: name resolution, connect, send, receive.
    ; These are deliberately much tighter than the POC's, because a stalled
    ; upload is more annoying here — see the async note in Upload() below.
    ; ReceiveTimeout is the real ceiling on how long a wedged upload can last
    ; if you don't hit Cancel.
    static ResolveTimeout := SnipCfg('SnipImgur', 'ImgurResolveTimeout',  8000)
    static ConnectTimeout := SnipCfg('SnipImgur', 'ImgurConnectTimeout', 10000)
    static SendTimeout    := SnipCfg('SnipImgur', 'ImgurSendTimeout',    30000)
    static ReceiveTimeout := SnipCfg('SnipImgur', 'ImgurReceiveTimeout', 60000)

    ; ══════════════════════════════════════════════════════════════════════════

    ; Holds the Client ID and nothing else — hence the blunt file name, which
    ; is meant to make "add this to .gitignore" an obvious thought.
    ; Routed through SnipKeysIni() so both credential-using modules resolve the
    ; same file, including its legacy ImgurClientID.ini migration.
    static IniFile => SnipKeysIni()

    ; Sentinel put in Error.Extra when the user cancels, so callers can tell a
    ; deliberate abort from a real failure without parsing message text.
    static CANCELLED := 'IMGUR_UPLOAD_CANCELLED'

    ; Offered in the Uploader's "Copy as:" dropdown.  Item 2 (BBCode [img]) is
    ; both the dropdown default and what the one-click menu item always emits.
    ; The last two only mean anything for an animated upload; on a still image
    ; FormatLink() quietly falls back to the direct link rather than handing
    ; back a URL to a video that doesn't exist.
    static FormatNames := ['Direct link'
                         , 'BBCode [img]'
                         , 'BBCode thumbnail linked'
                         , 'Markdown'
                         , 'HTML img tag'
                         , 'Page link'
                         , 'Direct MP4  (animated only)'
                         , 'HTML5 video tag  (animated only)']

    ; Which of the above the one-click upload copies, and which the Uploader's
    ; dropdown starts on.  Stored by NAME rather than by index so the INI stays
    ; readable and survives the list being reordered.
    static DefaultFormat := SnipCfg('SnipImgur', 'ImgurDefaultFormat', 'BBCode [img]')

    ; 1-based position of DefaultFormat in FormatNames, for the DDL's Choose
    ; option.  Falls back to 1 (Direct link) if the INI names a format that
    ; isn't in the list -- which is also what FormatLink() does with an
    ; unrecognised name, so the two stay consistent.
    Static DefaultFormatIndex() {
        for i, name in Imgur.FormatNames
            if (name = Imgur.DefaultFormat)
                return i
        return 1
    }

    ; ── Client ID storage ─────────────────────────────────────────────────────
    ; IniRead with a 4th arg returns that default rather than throwing when the
    ; file or key is missing, so a first run is silent.  The try/catch covers
    ; the odd case of ScreenSnip living in a folder it can't read.
    Static GetClientID() {
        try {
            return Trim(IniRead(Imgur.IniFile, 'Imgur', 'ClientID', ''))
        } catch {
            return ''
        }
    }

    Static SetClientID(id) {
        try {
            IniWrite(Trim(id), Imgur.IniFile, 'Imgur', 'ClientID')
            return true
        } catch as err {
            MsgBox('Could not save the Client ID to:`n' Imgur.IniFile '`n`n' err.Message
                 . '`n`nIs ScreenSnip in a read-only folder?'
                 , 'ScreenSnip — Imgur', 4096)
            return false
        }
    }

    ; ── Upload ────────────────────────────────────────────────────────────────
    ; Posts a local image file; returns a Map with keys:
    ;   direct     https://i.imgur.com/ID.png   (embeddable file)
    ;   page       https://imgur.com/ID         (Imgur's viewer page)
    ;   link       whatever Imgur actually returned, unmodified
    ;   id, mime, deletehash, remaining
    ; Throws on any failure, including user cancellation.
    ;
    ; progressFn, if supplied, is called roughly every 200 ms with the elapsed
    ; milliseconds; returning the string 'cancel' aborts the request.
    ;
    ; WHY ASYNC:  the request is opened in async mode and polled, rather than
    ; sent synchronously, because a synchronous Send() parks the ONE AutoHotkey
    ; thread for the duration.  In the POC that froze a dialog; here it would
    ; freeze all of ScreenSnip — hotkeys, the shadow-glue WM_WINDOWPOSCHANGED
    ; handler, the bevel repaint — for up to ReceiveTimeout.  Polling with
    ; WaitForResponse(0.2) plus a Sleep lets AHK keep pumping messages, which
    ; is also what makes the Cancel button clickable.
    ;
    ; If the async path ever misbehaves, reverting is small: change the `true`
    ; in Open() to `false`, and delete the polling Loop.  Everything below it
    ; works identically either way.
    Static Upload(filePath, clientId, progressFn := 0) {
        buf := FileRead(filePath, 'RAW')            ; v2 returns a Buffer object
        if (buf.Size = 0)
            throw Error('File is empty: ' filePath, -1)

        body := 'type=base64&image=' Imgur.PercentEncodeB64(Imgur.Base64Encode(buf))

        whr := ComObject('WinHttp.WinHttpRequest.5.1')
        whr.Open('POST', 'https://api.imgur.com/3/image', true)     ; true = async
        whr.SetRequestHeader('Authorization', 'Client-ID ' clientId)
        whr.SetRequestHeader('Content-Type', 'application/x-www-form-urlencoded')
        whr.SetTimeouts(Imgur.ResolveTimeout, Imgur.ConnectTimeout
                      , Imgur.SendTimeout,    Imgur.ReceiveTimeout)

        try {
            whr.Send(body)
        } catch as err {
            throw Error('Could not start the upload.`n`n' Imgur.NetErrorHint(err), -1)
        }

        ; Poll until the response lands.  In async mode WinHttp raises transport
        ; failures (DNS, timeout, abort) out of WaitForResponse, not Send.
        start := A_TickCount
        Loop {
            done := false
            try {
                done := whr.WaitForResponse(0.2)
            } catch as err {
                throw Error(Imgur.NetErrorHint(err), -1)
            }
            if done
                break
            if (progressFn && progressFn(A_TickCount - start) = 'cancel') {
                try whr.Abort()
                ; The 3rd Error() arg lands in err.Extra — a sentinel callers can
                ; test exactly, rather than sniffing the message text for the word
                ; "cancelled" (which a server message could plausibly contain).
                throw Error('Upload cancelled.', -1, Imgur.CANCELLED)
            }
            Sleep(20)
        }

        status := whr.Status
        resp   := whr.ResponseText

        remaining := ''
        try remaining := whr.GetResponseHeader('X-RateLimit-ClientRemaining')

        if (status != 200) {
            msg := Imgur.JsonStr(resp, 'error')
            if (msg = '')
                msg := 'HTTP ' status
            if (status = 403)
                msg .= '  (bad/blocked Client ID, or daily limit reached)'
            if (status = 429)
                msg .= '  (rate limited — try again later)'
            throw Error('Imgur said: ' msg, -1)
        }

        id   := Imgur.JsonStr(resp, 'id')
        mime := Imgur.JsonStr(resp, 'type')
        link := Imgur.JsonStr(resp, 'link')

        if (id = '' && link = '')
            throw Error('Upload seemed to succeed but no id or link was returned.', -1)

        ; Prefer building from id+MIME; fall back to repairing the returned URL.
        direct := (id != '') ? 'https://i.imgur.com/' id '.' Imgur.MimeToExt(mime)
                             : Imgur.ToDirectLink(link)
        page   := (id != '') ? 'https://imgur.com/' id
                             : RegExReplace(link, '^https?://i\.imgur\.com/([A-Za-z0-9]+)\..*$'
                                                , 'https://imgur.com/$1')

        ; ── Animated handling ────────────────────────────────────────────────
        ; `animated` is an unquoted JSON boolean, so JsonStr can't see it — hence
        ; JsonRaw.  The MIME test is a belt-and-braces second opinion: when Imgur
        ; converts a GIF to GIFV it reports the stored type as video/mp4, and a
        ; response that says video/mp4 is animated whether or not it also
        ; bothered to set the flag.
        animated := (Imgur.JsonRaw(resp, 'animated') = 'true')
                 || (StrLower(Trim(mime)) = 'video/mp4')

        ; Imgur hands back mp4/gifv URLs of its own for converted files; build
        ; them from the id when it doesn't, which happens for GIFs small enough
        ; to escape conversion.
        gifv := Imgur.JsonStr(resp, 'gifv')
        mp4  := Imgur.JsonStr(resp, 'mp4')
        gif  := ''
        if animated && (id != '') {
            gif := 'https://i.imgur.com/' id '.gif'
            if (mp4  = '')
                mp4  := 'https://i.imgur.com/' id '.mp4'
            if (gifv = '')
                gifv := 'https://i.imgur.com/' id '.gifv'
            ; THE important line.  Left alone, `direct` would be the .mp4 that
            ; MimeToExt produced from video/mp4, and every [img]/Markdown/<img>
            ; format built on top of it would be a broken image.  Imgur keeps
            ; serving the .gif next to the video, so that's what the image
            ; formats should point at.  The mp4 stays reachable via its own two
            ; dropdown entries.
            direct := gif
        }

        return Map('direct',     direct
                 , 'page',       page
                 , 'link',       link
                 , 'id',         id
                 , 'mime',       mime
                 , 'animated',   animated
                 , 'gif',        gif
                 , 'mp4',        mp4
                 , 'gifv',       gifv
                 , 'deletehash', Imgur.JsonStr(resp, 'deletehash')
                 , 'remaining',  remaining)
    }

    ; Delete an anonymous upload using its deletehash.  Synchronous: it's a tiny
    ; request with no body, and it only ever runs from a dialog the user is
    ; already sitting in front of.
    Static DeleteUpload(deleteHash, clientId) {
        whr := ComObject('WinHttp.WinHttpRequest.5.1')
        whr.Open('DELETE', 'https://api.imgur.com/3/image/' deleteHash, false)
        whr.SetRequestHeader('Authorization', 'Client-ID ' clientId)
        whr.SetTimeouts(8000, 10000, 30000, 30000)

        try {
            whr.Send()
        } catch as err {
            throw Error(Imgur.NetErrorHint(err), -1)
        }

        if (whr.Status != 200)
            throw Error('HTTP ' whr.Status ' — ' whr.ResponseText, -1)
        return true
    }

    ; Render a ScreenSnip snip to a temporary PNG and return the path.  Uses
    ; ScreenSnip's own BuildSaveBitmap(), so the upload is WYSIWYG and tilted
    ; snips get genuinely transparent corners rather than the magenta key.
    ; The caller is responsible for deleting the file.
    Static SnipToTempPng(snip) {
        bmp := BuildSaveBitmap(snip, true)          ; true = want transparency
        if !bmp
            throw Error('Could not build the image to upload.', -1)
        path := A_Temp '\ScreenSnip_imgur_' A_TickCount '_' Random(1000, 9999) '.png'
        status := GDIp.SaveImageToFile(bmp, path, 'image/png')
        GDIp.DisposeImage(bmp)
        if (status != 0)
            throw Error('Could not write the temporary PNG (GDI+ code ' status ').', -1)
        return path
    }

    ; Pixel dimensions of a snip's current (upright) crop, as " (842 × 517 px)",
    ; or an empty string if GDI+ won't say.  Written to drop straight into a
    ; sentence, so the caller needs no conditional of its own.
    Static SnipDimensions(snip) {
        w := 0, h := 0
        try {
            DllCall('gdiplus\GdipGetImageWidth',  'UPtr', snip.pBitmap, 'UInt*', &w)
            DllCall('gdiplus\GdipGetImageHeight', 'UPtr', snip.pBitmap, 'UInt*', &h)
        }
        return (w && h) ? ' (' w ' × ' h ' px)' : ''
    }

    ; ── Link formatting ───────────────────────────────────────────────────────
    ; Wrap an upload result in whatever markup the destination wants.
    ; For an animated upload `direct` is already the .gif (see Upload), so the
    ; five image formats below need no special-casing — they inherit the right
    ; URL.  Only the two video formats have to reach past it.
    Static FormatLink(res, fmt) {
        direct := res['direct']
        page   := res['page']
        ; .Has guards against a result Map built by an older copy of this file
        ; still sitting in ImgurLastResult after an edit-and-Reload.
        mp4    := res.Has('mp4') ? res['mp4'] : ''

        switch fmt {
            case 'Direct link':
                return direct
            case 'BBCode [img]':
                return '[img]' direct '[/img]'
            case 'BBCode thumbnail linked':
                return '[url=' direct '][img]' Imgur.ThumbLink(direct, 'l') '[/img][/url]'
            case 'Markdown':
                return '![](' direct ')'
            case 'HTML img tag':
                return '<img src="' direct '" alt="">'
            case 'Page link':
                return page
            case 'Direct MP4  (animated only)':
                ; A still image has no video to point at; the direct link is a
                ; more useful answer than an empty box or a URL that 404s.
                return (mp4 != '') ? mp4 : direct
            case 'HTML5 video tag  (animated only)':
                ; muted + playsinline are what make browsers honour autoplay;
                ; without them a lot of them just show a frozen first frame.
                return (mp4 != '')
                     ? '<video autoplay loop muted playsinline src="' mp4 '"></video>'
                     : '<img src="' direct '" alt="">'
        }
        return direct
    }

    ; https://i.imgur.com/7Wqu8C8.png  ->  https://i.imgur.com/7Wqu8C8l.png
    ; Works on an animated .gif too, but Imgur's thumbnails are STILL frames —
    ; so "BBCode thumbnail linked" on a GIF gives a motionless preview that
    ; links through to the moving version.  Usually the polite thing to post.
    Static ThumbLink(directUrl, sizeChar := 'l') {
        if RegExMatch(directUrl, '^(.*/[^/.]+)(\.[A-Za-z0-9]+)$', &m)
            return m[1] sizeChar m[2]
        return directUrl
    }

    ; Imgur re-encodes some formats on upload, so trust the reported MIME type.
    Static MimeToExt(mime) {
        static mimeMap := Map('image/png',  'png',  'image/jpeg', 'jpg'
                            , 'image/gif',  'gif',  'image/webp', 'webp'
                            , 'image/apng', 'png',  'image/bmp',  'png'
                            , 'image/tiff', 'png',  'video/mp4',  'mp4')
        mime := StrLower(Trim(mime))
        return mimeMap.Has(mime) ? mimeMap[mime] : 'png'
    }

    ; Fallback only, for when the response has no usable id.
    Static ToDirectLink(link) {
        if InStr(link, '//i.imgur.com/')
            return RegExMatch(link, '\.[A-Za-z0-9]+$') ? link : link '.png'
        if RegExMatch(link, 'imgur\.com/([A-Za-z0-9]+)', &m)
            return 'https://i.imgur.com/' m[1] '.png'
        return link
    }

    ; ── Helpers ───────────────────────────────────────────────────────────────
    ; WinHttp's messages are terse and hex-coded; add a plain-English hint for
    ; the two failures that actually happen (no internet / server unreachable).
    Static NetErrorHint(err) {
        m := IsObject(err) ? err.Message : String(err)
        if (InStr(m, '80072EE7') || InStr(m, 'server name') || InStr(m, 'resolved'))
            return m '`n`nThe Imgur server name could not be resolved.'
                   . '`nUsually that means no internet connection.'
        if (InStr(m, '80072EE2') || InStr(m, '80072F19') || InStr(m, 'timed out'))
            return m '`n`nThe connection timed out — Imgur may be unreachable'
                   . '`nor the network very slow.'
        if InStr(m, '80072EFD')
            return m '`n`nCould not connect to Imgur. Check your connection,'
                   . '`nproxy, or firewall.'
        return m
    }

    ; Base64-encode a Buffer using the OS crypt32 API.  No third-party lib needed.
    Static Base64Encode(buf) {
        static FLAGS := 0x00000001 | 0x40000000     ; CRYPT_STRING_BASE64 | NOCRLF

        if !DllCall('crypt32\CryptBinaryToStringW', 'Ptr', buf.Ptr, 'UInt', buf.Size
                  , 'UInt', FLAGS, 'Ptr', 0, 'UInt*', &chars := 0)
            throw Error('CryptBinaryToStringW size query failed.', -1)

        out := Buffer(chars * 2, 0)
        if !DllCall('crypt32\CryptBinaryToStringW', 'Ptr', buf.Ptr, 'UInt', buf.Size
                  , 'UInt', FLAGS, 'Ptr', out, 'UInt*', &chars)
            throw Error('CryptBinaryToStringW failed.', -1)

        return StrGet(out, 'UTF-16')
    }

    ; The base64 alphabet is A-Z a-z 0-9 + / = — only three of those need
    ; escaping inside an application/x-www-form-urlencoded body.
    Static PercentEncodeB64(s) {
        s := StrReplace(s, '+', '%2B')
        s := StrReplace(s, '/', '%2F')
        s := StrReplace(s, '=', '%3D')
        return s
    }

    ; Minimal JSON string-value extractor.  Adequate for Imgur's flat responses;
    ; swap in a real JSON lib if you ever need nested parsing.
    Static JsonStr(json, key) {
        if RegExMatch(json, 'i)"' key '"\s*:\s*"((?:[^"\\]|\\.)*)"', &m) {
            v := m[1]
            v := StrReplace(v, '\/', '/')
            v := StrReplace(v, '\"', '"')
            return v
        }
        return ''
    }

    ; Companion to JsonStr for UNQUOTED values — booleans and numbers.  Needed
    ; because Imgur's `animated` field is a bare true/false, which JsonStr's
    ; pattern (which requires surrounding quotes) can never match.  Returns the
    ; literal text: 'true', 'false', a number, or '' if the key isn't there.
    Static JsonRaw(json, key) {
        if RegExMatch(json, 'i)"' key '"\s*:\s*(true|false|null|-?\d+(?:\.\d+)?)', &m)
            return m[1]
        return ''
    }
}


; ==============================================================================
; CONTEXT-MENU HOOK-UP
; ==============================================================================
; ScreenSnip.ahk calls ImgurBuildMenu() through the %name%() dynamic-call form,
; guarded by IsSet(Imgur).  A *direct* call to a function that might not exist is
; a LOAD-TIME error in v2 — the dynamic form defers the lookup to run time, which
; is what lets ScreenSnip still start when this file is absent.

ImgurBuildMenu() {
    m := Menu()
    m.Add('Upload → [img] Tag', ImgurMenu_Handler)
    m.Add('Imgur Uploader…',    ImgurMenu_Handler)
    return m
}

; Mirrors ScreenSnip's own SnipMenu_Handler: the right-clicked snip is whichever
; window ShowSnipMenuFor() stashed in SnipMenu._targetHwnd just before .Show().
ImgurMenu_Handler(ItemName, ItemPos, *) {
    global SnipMenu
    hwnd := SnipMenu._targetHwnd
    switch StrSplit(ItemName, '`t')[1] {
        case 'Upload → [img] Tag': ImgurUploadSnipBBCode(hwnd)
        case 'Imgur Uploader…':    ShowImgurGui(hwnd)
    }
}


; ==============================================================================
; ONE-CLICK PATH:  snip  ->  Imgur  ->  [img]…[/img] on the clipboard
; ==============================================================================
ImgurUploadSnipBBCode(hwnd := 0) {
    global guiSnips
    if !hwnd
        hwnd := WinGetID('A')
    if !guiSnips.Has(hwnd)
        return
    snip := guiSnips[hwnd]

    ; No Client ID yet → open the Uploader instead, pre-loaded with this snip,
    ; so the "Client ID…" button is right there.  Once the ID is pasted, Upload
    ; is a single click; nothing has to be re-done.
    if (Imgur.GetClientID() = '') {
        ShowImgurGui(hwnd)
        return
    }

    if Imgur.ConfirmBeforeUpload {
        prompt := 'Upload this snip' Imgur.SnipDimensions(snip) ' to Imgur?'
                . '`n`nThe image becomes PUBLIC to anyone who has the link.'
                . '`nAn anonymous upload can only be deleted during this'
                . '`nScreenSnip session (Imgur ▸ Imgur Uploader…).'
                . '`n`nSet  Imgur.ConfirmBeforeUpload := false  in SnipImgur.ahk'
                . '`nto stop asking.'
        if (MsgBox(prompt, 'ScreenSnip — Upload to Imgur', 'YesNo Icon? 4096') = 'No')
            return
    }

    tmp := ''
    res := ''
    ImgurProgressStart()
    try {
        tmp := Imgur.SnipToTempPng(snip)
        res := Imgur.Upload(tmp, Imgur.GetClientID(), ImgurProgressTick)
    } catch as err {
        ; Cancellation is a normal outcome, not an error worth a dialog.
        if (err.Extra != Imgur.CANCELLED)
            MsgBox('Imgur upload failed.`n`n' err.Message, 'ScreenSnip — Imgur', 4096)
        return
    } finally {
        ImgurProgressStop()                 ; runs even on the return above
        if (tmp != '')
            try FileDelete(tmp)
    }

    ImgurLastResult(res)                    ; session memory, for Delete This Upload
    tag := Imgur.FormatLink(res, Imgur.DefaultFormat)
    A_Clipboard := tag

    ; Keep the Uploader's fields in step if it happens to be open.
    gs := ImgurGuiState()
    if gs.g {
        gs.link.Value := tag
        ImgurSetStatus(gs, 'Uploaded and copied to clipboard.')
    }

    ImgurToast('[img] tag copied to clipboard:`n' res['direct']
             . '`n`nTo remove it from Imgur, use  Imgur ▸ Imgur Uploader… ▸'
             . '`nDelete This Upload  before closing ScreenSnip.')
}

; Brief self-clearing tooltip at the cursor.  ScreenSnip has no status bar, and
; a MsgBox after every upload would defeat the point of a one-click item.
ImgurToast(msg, ms := 4000) {
    ToolTip(msg)
    SetTimer(ImgurToastClear, -Abs(ms))
}
ImgurToastClear() => ToolTip()


; ==============================================================================
; PROGRESS / CANCEL WINDOW
; ==============================================================================
; Shared state lives in a static inside one accessor function rather than in
; globals, so this file keeps its "no top-level executable code" promise and
; every handler below can be a plain named function (no binding needed).

ImgurProgressState() {
    static s := { g: 0, txt: 0, pb: 0, cancelled: false, shown: false }
    return s
}

ImgurProgressStart() {
    s := ImgurProgressState()
    s.cancelled := false
    s.shown     := false
    if !ImgurGuiAlive(s) {
        g := Gui('+AlwaysOnTop -MinimizeBox -MaximizeBox +ToolWindow +OwnDialogs'
               , 'ScreenSnip — Imgur')
        g.SetFont('s10', 'Segoe UI')
        s.txt := g.Add('Text', 'xm w330', 'Uploading to Imgur…')
        s.pb  := g.Add('Progress', 'xm y+8 w330 h18 -Smooth')
        ImgurMakeMarquee(s.pb)
        g.Add('Button', 'xm y+10 w90', 'Cancel').OnEvent('Click', ImgurProgressCancel)
        g.OnEvent('Close',  ImgurProgressCancel)
        g.OnEvent('Escape', ImgurProgressCancel)
        s.g := g
    }
}

; Wired to the Cancel button AND to Close/Escape.  Hides the window and returns
; a non-zero value so AHK does NOT destroy it — the Gui object is cached in
; state and reused on the next upload, and a destroyed handle would blow up the
; next Show().  (ImgurGuiAlive() below is the belt-and-braces version of the
; same concern for the Uploader.)
ImgurProgressCancel(*) {
    s := ImgurProgressState()
    s.cancelled := true
    s.shown     := false
    try s.g.Hide()
    return 1
}

; Called from Imgur.Upload()'s polling loop.  Returns 'cancel' to abort.
; The window only appears once the upload has run past ProgressDelayMs, so a
; fast upload never flashes a dialog on screen.
ImgurProgressTick(elapsedMs) {
    s := ImgurProgressState()
    if s.cancelled
        return 'cancel'
    if !s.g
        return ''
    if (!s.shown && elapsedMs >= Imgur.ProgressDelayMs) {
        s.txt.Value := 'Uploading to Imgur…'
        s.g.Show()
        s.shown := true
    }
    if s.shown
        s.txt.Value := 'Uploading to Imgur…      ' Round(elapsedMs / 1000) ' s'
    return ''
}

ImgurProgressStop() {
    s := ImgurProgressState()
    if s.g
        try s.g.Hide()
    s.shown := false
}

; Turn a plain Progress bar into a scrolling marquee (there's no percentage to
; report — WinHttp doesn't hand back upload progress).  Purely cosmetic, so the
; whole thing is inside a try: a static empty bar is a fine fallback.
; DllCall rather than SendMessage() because the control is still hidden at this
; point and AHK's SendMessage does DetectHiddenWindows-style window matching.
ImgurMakeMarquee(pbCtrl) {
    static GWL_STYLE := -16, PBS_MARQUEE := 0x08, PBM_SETMARQUEE := 0x040A
    try {
        fnGet := (A_PtrSize = 8) ? 'GetWindowLongPtrW' : 'GetWindowLongW'
        fnSet := (A_PtrSize = 8) ? 'SetWindowLongPtrW' : 'SetWindowLongW'
        st := DllCall('user32\' fnGet, 'Ptr', pbCtrl.Hwnd, 'Int', GWL_STYLE, 'Ptr')
        DllCall('user32\' fnSet, 'Ptr', pbCtrl.Hwnd, 'Int', GWL_STYLE, 'Ptr', st | PBS_MARQUEE)
        DllCall('user32\SendMessageW', 'Ptr', pbCtrl.Hwnd, 'UInt', PBM_SETMARQUEE
              , 'Ptr', 1, 'Ptr', 30)
    } catch {
        ; Cosmetic only — ignore.
    }
}


; ==============================================================================
; SESSION MEMORY
; ==============================================================================
; The most recent successful upload result, so "Delete This Upload" has a
; deletehash to work with.  Deliberately in-memory only: no log file, matching
; how ScreenSnip keeps no history of snips or OCR captures.  Call with no
; argument to read, with an argument to set.
ImgurLastResult(newRes := unset) {
    static last := ''
    if IsSet(newRes)
        last := newRes
    return last
}


; ==============================================================================
; THE UPLOADER DIALOG
; ==============================================================================
; Built lazily on first use and then reused (hidden, not destroyed), so opening
; it repeatedly is instant and the last link stays visible.

ImgurGuiState() {
    static s := { g: 0, path: 0, ddl: 0, link: 0, status: 0, temp: '' }
    return s
}

; Both cached windows below are hidden rather than destroyed on close, so they
; can be reopened instantly with the last link still showing.  That's only safe
; if we can tell a hidden window from a destroyed one before reusing the handle
; — hence IsWindow() rather than WinExist(), which would need
; DetectHiddenWindows.  Works for either state object (both have a .g).
ImgurGuiAlive(s) {
    if !s.g
        return false
    try {
        return DllCall('IsWindow', 'Ptr', s.g.Hwnd, 'Int') ? true : false
    } catch {
        return false        ; .Hwnd itself throws once the Gui is destroyed
    }
}

; snipHwnd, if given, is rendered to a temp PNG and pre-loaded into the path box.
ShowImgurGui(snipHwnd := 0) {
    global guiSnips
    s := ImgurGuiState()

    if !ImgurGuiAlive(s)
        ImgurBuildGui(s)

    ; Sweep any temp PNGs orphaned by an earlier crash or hard exit, then drop
    ; this session's previous one.
    ImgurSweepTemp()
    ImgurDropTemp(s)

    if (snipHwnd && guiSnips.Has(snipHwnd)) {
        try {
            s.temp := Imgur.SnipToTempPng(guiSnips[snipHwnd])
            s.path.Value := s.temp
        } catch as err {
            ImgurSetStatus(s, 'Could not prepare the snip: ' err.Message)
        }
    }

    if (Imgur.GetClientID() = '')
        ImgurSetStatus(s, 'No Client ID yet — click "Client ID…".  '
                        . 'You need a free Imgur account first.')
    else if (s.temp != '')
        ImgurSetStatus(s, 'Snip ready — click Upload.')
    else
        ImgurSetStatus(s, 'Ready.')

    s.g.Show()
}

ImgurBuildGui(s) {
    g := Gui('+Resize +OwnDialogs', 'ScreenSnip — Upload to Imgur')
    g.SetFont('s10', 'Segoe UI')

    g.Add('Text', 'xm', 'Image file  (or drag one onto this window):')
    s.path := g.Add('Edit', 'xm w430')
    g.Add('Button', 'x+6 yp-1 w90', 'Browse…').OnEvent('Click', ImgurGui_Browse)

    g.Add('Button', 'xm w120 h30 Default', 'Upload').OnEvent('Click', ImgurGui_Upload)
    g.Add('Button', 'x+6 w120 h30', 'Client ID…').OnEvent('Click', ImgurGui_ClientID)

    g.Add('Text', 'xm y+14 section', 'Copy as:')
    ; w300 rather than w230 — "HTML5 video tag  (animated only)" needs the room.
    s.ddl := g.Add('DropDownList', 'x+6 yp-4 w300 Choose' Imgur.DefaultFormatIndex()
                 , Imgur.FormatNames)
    s.ddl.OnEvent('Change', ImgurGui_FormatChange)

    s.link := g.Add('Edit', 'xm y+6 w526 ReadOnly')

    g.Add('Button', 'xm w120', 'Copy').OnEvent('Click', ImgurGui_Copy)
    g.Add('Button', 'x+6 w140', 'Open in Browser').OnEvent('Click', ImgurGui_Open)
    g.Add('Button', 'x+6 w160', 'Delete This Upload').OnEvent('Click', ImgurGui_Delete)

    s.status := g.Add('Text', 'xm y+14 w526', 'Ready.')

    g.OnEvent('DropFiles', ImgurGui_DropFiles)
    g.OnEvent('Close',  ImgurGui_Close)
    g.OnEvent('Escape', ImgurGui_Close)
    s.g := g

    ; Must come AFTER the window exists, which it does by now — Gui() creates it
    ; (hidden) up front, so g.Hwnd is already a real handle.  Filtering only the
    ; Gui's own hwnd is enough: WS_EX_ACCEPTFILES lives on the Gui, not the
    ; controls, so WM_DROPFILES is posted there no matter which control the file
    ; was actually dropped on.  (AHK works out the Ctrl parameter afterwards,
    ; from the drop coordinates.)
    ImgurAllowDropsWhenElevated(g.Hwnd)
}

; ── UIPI: let file drops through when running elevated ────────────────────────
; User Interface Privilege Isolation silently discards window messages sent from
; a lower-integrity process to a higher one.  Explorer runs at medium integrity;
; ScreenSnip launched via StartupLauncher's Task Scheduler entry (/RL HIGHEST)
; runs at high.  So dragging a file from the Desktop onto this dialog does
; nothing whatsoever — no error, no beep, no cursor change, no hint that Windows
; ate the message.  It is a genuinely baffling failure the first time.
;
; ChangeWindowMessageFilterEx whitelists specific messages for ONE window.  That
; per-window scope is the whole reason this is acceptable: only the Uploader
; dialog, and only the three messages a file drop needs, become reachable from
; medium integrity.  (Its predecessor, ChangeWindowMessageFilter, relaxed the
; filter process-wide — don't use that one.)
;
; Three messages, because a drop is not a single message:
;   WM_DROPFILES       0x233  the notification itself
;   WM_COPYDATA        0x04A  how some drag sources hand over their payload
;   WM_COPYGLOBALDATA  0x049  undocumented, and the one everyone forgets.  The
;                             HDROP is a handle into global memory; without this
;                             the notification arrives carrying nothing, which
;                             looks like a drop that "half worked".
;
; Unelevated, this is a no-op with a success return: there was no filter to
; relax.  Calling unconditionally beats branching on A_IsAdmin and letting the
; two paths drift apart.  The try is because the API is Win7+ and this is a
; convenience — if it fails, Browse… still works exactly as before.
ImgurAllowDropsWhenElevated(hwnd) {
    static MSGFLT_ALLOW := 1
    static msgs := [0x0233, 0x004A, 0x0049]
    try {
        for _, msg in msgs
            DllCall('user32\ChangeWindowMessageFilterEx'
                  , 'Ptr',  hwnd
                  , 'UInt', msg
                  , 'UInt', MSGFLT_ALLOW
                  , 'Ptr',  0            ; optional CHANGEFILTERSTRUCT — not needed
                  , 'Int')
    } catch {
        ; Pre-Win7 or refused.  Browse… remains the way in.
    }
}

ImgurSetStatus(s, msg) {
    if s.status
        s.status.Value := msg
}

; ── Uploader handlers ─────────────────────────────────────────────────────────
ImgurGui_Browse(*) {
    s := ImgurGuiState()
    p := FileSelect(3, , 'Choose an image'
                  , 'Images (*.png; *.jpg; *.jpeg; *.gif; *.bmp; *.webp)')
    if (p != '') {
        ImgurDropTemp(s)                    ; a browsed file replaces the snip temp
        s.path.Value := p
        ImgurSetStatus(s, 'Ready.')
    }
}

ImgurGui_DropFiles(GuiObj, Ctrl, FileArray, X, Y) {
    s := ImgurGuiState()
    if FileArray.Length {
        ImgurDropTemp(s)
        s.path.Value := FileArray[1]
        ImgurSetStatus(s, 'Ready.')
    }
}

ImgurGui_ClientID(*) {
    ImgurClientIDDialog()
}

ImgurGui_Upload(*) {
    s  := ImgurGuiState()
    id := Imgur.GetClientID()
    path := Trim(s.path.Value, ' "')

    if (id = '') {
        ImgurSetStatus(s, 'No Client ID set — click "Client ID…" first.')
        return
    }
    if (path = '' || !FileExist(path)) {
        ImgurSetStatus(s, 'File not found: ' path)
        return
    }

    ; The cap being warned about is the API's, not Imgur's — the website would
    ; happily take this file.  Worth spelling out, because "but I uploaded a
    ; bigger one through the browser yesterday" is the obvious objection.
    sizeMB := FileGetSize(path) / 1048576
    if (sizeMB > 10) {
        msg := Format("That file is {:.1f} MB.`n`n"
                    . "Imgur's website accepts far more than this — 20 MB for stills, "
                    . "200 MB for animated — but the JSON API this uploader posts to "
                    . "caps out around 10 MB, and base64 encoding adds roughly a third "
                    . "on top of whatever is on disc.`n`n"
                    . "For an oversized GIF the practical fix is to shrink it first: "
                    . "drop frames, reduce the dimensions, or run a lossy pass "
                    . "(gifsicle -O3 --lossy=80 is startlingly effective).`n`n"
                    . "Try anyway?", sizeMB)
        if (MsgBox(msg, 'Larger than the API allows', 'YesNo Icon! 4096') = 'No')
            return
    }

    ImgurSetStatus(s, 'Uploading…')
    ImgurProgressStart()
    res := ''
    try {
        res := Imgur.Upload(path, id, ImgurProgressTick)
    } catch as err {
        ImgurSetStatus(s, (err.Extra = Imgur.CANCELLED)
                        ? 'Upload cancelled.'
                        : 'FAILED: ' StrReplace(err.Message, '`n', '  '))
        return
    } finally {
        ImgurProgressStop()
    }

    ImgurLastResult(res)
    s.link.Value := Imgur.FormatLink(res, s.ddl.Text)
    A_Clipboard := s.link.Value

    ; Say plainly when the animated path was taken.  Otherwise the link just
    ; silently says .gif when the file went up as a GIFV, and the next question
    ; is always "did the animation survive?"  (It did — Imgur serves both.)
    note := res['animated']
          ? 'Uploaded — animated, so links use the .gif.  MP4 formats are in the dropdown.'
          : 'Uploaded and copied to clipboard.'
    ImgurSetStatus(s, note
                    . (res['remaining'] != '' ? '   Credits left today: ' res['remaining'] : ''))
}

ImgurGui_FormatChange(*) {
    s   := ImgurGuiState()
    res := ImgurLastResult()
    if !IsObject(res)
        return
    s.link.Value := Imgur.FormatLink(res, s.ddl.Text)
    A_Clipboard := s.link.Value
    ImgurSetStatus(s, 'Reformatted and copied to clipboard.')
}

ImgurGui_Copy(*) {
    s := ImgurGuiState()
    if (s.link.Value = '') {
        ImgurSetStatus(s, 'Nothing to copy yet.')
        return
    }
    A_Clipboard := s.link.Value
    ImgurSetStatus(s, 'Copied to clipboard.')
}

ImgurGui_Open(*) {
    s   := ImgurGuiState()
    res := ImgurLastResult()
    if !IsObject(res) {
        ImgurSetStatus(s, 'Nothing to open yet.')
        return
    }
    try Run(res['page'])                    ; the page, not the raw file
}

ImgurGui_Delete(*) {
    s   := ImgurGuiState()
    res := ImgurLastResult()
    if (!IsObject(res) || res['deletehash'] = '') {
        ImgurSetStatus(s, 'No deletehash — nothing from this session to delete.')
        return
    }
    if (MsgBox('Permanently delete this image from Imgur?`n`n' res['direct']
             , 'Confirm delete', 'YesNo Icon? 4096') = 'No')
        return
    try {
        Imgur.DeleteUpload(res['deletehash'], Imgur.GetClientID())
    } catch as err {
        ImgurSetStatus(s, 'Delete failed: ' StrReplace(err.Message, '`n', '  '))
        return
    }
    ImgurLastResult('')
    s.link.Value := ''
    ImgurSetStatus(s, 'Deleted from Imgur.')
}

; Hide, don't destroy — see ImgurGuiAlive().  Returning non-zero suppresses
; AHK's default destroy-on-close.
ImgurGui_Close(*) {
    s := ImgurGuiState()
    ImgurDropTemp(s)
    try s.g.Hide()
    return 1
}

; ── Temp-file housekeeping ────────────────────────────────────────────────────
; Delete the temp PNG this dialog is currently holding (if any).
ImgurDropTemp(s) {
    if (s.temp != '') {
        try FileDelete(s.temp)
        if (s.path && s.path.Value = s.temp)
            s.path.Value := ''
        s.temp := ''
    }
}

; Best-effort sweep of temp PNGs left behind by a crash or a hard exit.  Cheap
; (the folder scan is filtered by name) and self-healing, which is why there's
; no need to hook ScreenSnip's CleanupOnExit.
ImgurSweepTemp() {
    try {
        Loop Files, A_Temp '\ScreenSnip_imgur_*.png'
            try FileDelete(A_LoopFileFullPath)
    } catch {
        ; Nothing to clean, or no access — either way, harmless.
    }
}


; ==============================================================================
; CLIENT ID DIALOG
; ==============================================================================
; A plain InputBox can't render a clickable link, and the moment the user needs
; a Client ID is exactly the moment they want to click through to Imgur — hence
; a small Gui with Link controls.  AHK v2's Link control opens href targets by
; itself when no Click handler is registered.
ImgurClientIDDialog() {
    g := Gui('+AlwaysOnTop +OwnDialogs', 'Imgur Client ID')
    g.SetFont('s10', 'Segoe UI')

    g.Add('Text', 'xm w480'
        , 'Uploading needs a FREE Imgur account plus a Client ID. One-time setup:')

    g.SetFont('s9', 'Segoe UI')
    g.Add('Text', 'xm w480'
        , '1.  Create a free account at imgur.com — any e-mail address will do.`n'
        . '2.  Signed in, open  Settings ▸ Applications  and add an application.`n'
        . '3.  Name it anything, e.g. "ScreenSnip Uploader".`n'
        . '4.  Authorization type:  "Anonymous usage without user authorization".`n'
        . '5.  Leave the callback URL blank and submit.`n'
        . '6.  Copy the Client ID and paste it below.  (Ignore the Client Secret —`n'
        . '     anonymous uploads never use it.)')

    g.Add('Link', 'xm w480'
        , '<a href="https://imgur.com/register">Create a free account</a>'
        . '     ·     '
        . '<a href="https://imgur.com/account/settings/apps">Settings ▸ Applications</a>')

    g.SetFont('s10', 'Segoe UI')
    g.Add('Text', 'xm y+10', 'Client ID:')
    ed := g.Add('Edit', 'xm w480', Imgur.GetClientID())

    g.SetFont('s8', 'Segoe UI')
    g.Add('Text', 'xm w480'
        , 'Saved to ' Imgur.IniFile '`n'
        . 'If ScreenSnip lives in a git repo, add that file to .gitignore.')

    g.SetFont('s10', 'Segoe UI')
    ok := g.Add('Button', 'xm y+10 w90 Default', 'OK')
    ok.OnEvent('Click', ImgurClientIDSave.Bind(g, ed))
    g.Add('Button', 'x+6 w90', 'Cancel').OnEvent('Click', (*) => g.Destroy())
    g.OnEvent('Escape', (*) => g.Destroy())
    g.OnEvent('Close',  (*) => g.Destroy())

    g.Show()
    ed.Focus()
}

ImgurClientIDSave(g, ed, *) {
    v := Trim(ed.Value)
    saved := (v != '') ? Imgur.SetClientID(v) : false
    g.Destroy()
    s := ImgurGuiState()
    if s.g
        ImgurSetStatus(s, saved ? 'Client ID saved — click Upload.'
                                : 'No Client ID entered.')
}


; ==============================================================================
;  UPLOADING TO YOUR ACCOUNT INSTEAD
;  Anonymous uploads (what this file does) are unowned — they don't show up
;  under your Imgur account and can only be managed via the deletehash, which
;  is remembered for the current session only.  To have uploads land in your
;  account instead — where you can browse and delete them on the Imgur website
;  indefinitely — register the app with "OAuth 2 authorization without a
;  callback URL", do a one-time browser consent to get a refresh token, then
;  exchange that refresh token for an access token before each upload and send
;  "Authorization: Bearer <token>" instead of the Client-ID header.
;  Everything else in Imgur.Upload() stays identical.
; ==============================================================================
