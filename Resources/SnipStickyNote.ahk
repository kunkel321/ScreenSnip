#Requires AutoHotkey v2.0
; ==============================================================================
; SnipStickyNote.ahk — send a snip to Sticky Notes
; Optional add-on module for ScreenSnip.ahk.  Part of the ScreenSnip project.
; Version date: 9-6-2026 
; ==============================================================================
;
; WHAT IT DOES
; Adds one item, "Send to Sticky Note", to a snip's right-click menu.  The snip
; goes onto the clipboard and a broadcast message tells Sticky Notes to pick it
; up.  If a note is open in the Sticky Notes editor the image is appended to the
; bottom of it; otherwise a new note is created holding just the image.
;
; WHY THE CLIPBOARD
; The obvious design would be to write a PNG into Sticky Notes' Images folder
; and poke it, but that means this module has to be told where Sticky Notes is
; installed, has to know its file naming, and ends up writing inside another
; app's data folder.  Going through the clipboard costs one broadcast and buys:
;
;   - No path setting.  Nothing here knows or cares where Sticky Notes lives.
;   - No shared file format between the two projects.
;   - Nothing to undo if Sticky Notes isn't running.  The broadcast lands
;     nowhere, the snip is still on the clipboard, and pasting it by hand into a
;     note does exactly the same thing.  A missed handoff is never a dead end.
;
; It is also the same clipboard path Sticky Notes already handles for the
; Snipping Tool, Greenshot and browser copy-image, so nothing new had to be
; written on that side either.
;
; The one real cost: this overwrites the clipboard.  Copy to Clipboard on the
; same menu does that too, so it shouldn't be a surprise.
;
; WHAT STICKY NOTES NEEDS
; StickyNotes.ahk listens for AHK_StickyNotes_NewImageNote and handles the rest.
; That listener is a dozen lines and is in StickyNotes.ahk itself — Sticky Notes
; is a deliberately single-file app, so it has no Resources\ folder of its own to
; put a matching module in.  An older Sticky Notes without the listener simply
; ignores the broadcast; the snip still reaches the clipboard.
;
; ONE THING ANY LISTENER MUST DO — learned the hard way.  Windows delivers a
; broadcast to EVERY top-level window in the receiving process, not once per
; process.  Sticky Notes owns one window per note, another for each bordered
; note, plus its manager and any open editors, so a single click on this menu
; item arrives there a dozen or more times.  Treating each arrival as a separate
; request produced a screenful of duplicate notes.  That is why wParam carries a
; token identifying the send: repeats of a token already seen must be dropped.
; Anything else listening for this message has to do the same.
;
; OPT-OUT CONTRACT (the same one every module in Resources\ follows)
; Delete this file, or comment out its #Include at the bottom of ScreenSnip.ahk,
; and the StickyCfg class never comes into existence.  The two hooks in
; ScreenSnip.ahk are both guarded — the menu item is only added when
; IsSet(StickyCfg), and the handler case is only reachable through that item —
; so ScreenSnip loads and runs exactly as it did before.
;
; SETTINGS — [StickyNote] in Data\snipSettings.ini
;   Enabled       true    Master switch.  False hides the menu item entirely.
;   ProcessName   ...     Used ONLY to word the confirmation tooltip.  See below.
;   ShowTip       true    Show a tooltip confirming the send.
;   TipMs         1500    How long that tooltip stays up, in milliseconds.
;
; About ProcessName: it is not used to deliver anything.  The broadcast reaches
; Sticky Notes whether or not this name is right.  It only decides which of two
; tooltips you get, and it errs safe — a name that doesn't match makes the
; tooltip say Sticky Notes may not be running and that the snip is on the
; clipboard, which is true regardless.  Set it to whatever your renamed
; AutoHotkey64.exe is actually called if you want the shorter message.
; ==============================================================================

; Presence sentinel.  Class statics initialise at load time, before the
; auto-execute section, which is what lets ScreenSnip.ahk test IsSet(StickyCfg)
; up at the top of a file that includes this one 3,600 lines further down.
class StickyCfg {
    static Enabled     := SnipCfg('StickyNote', 'Enabled', true)
    static ProcessName := SnipCfg('StickyNote', 'ProcessName', 'StickyNotes.exe')
    static ShowTip     := SnipCfg('StickyNote', 'ShowTip', true)
    static TipMs       := SnipCfg('StickyNote', 'TipMs', 1500)
}

; The message id.  RegisterWindowMessage returns the same number in every
; process for a given string, so the two apps agree on it without sharing a file
; or hard-coding a number — the same trick ScreenSnip already uses for
; AHK_ScreenSnip_FreezeCapture and OSKMouseHighlight.
StickyMessageId() {
    static id := 0
    if !id
        id := DllCall('RegisterWindowMessage', 'Str', 'AHK_StickyNotes_NewImageNote', 'UInt')
    return id
}

; Menu entry point.  Called from SnipMenu_Handler's 'Send to Sticky Note' case
; through the %name%() dynamic form, so a missing module can't be a load-time
; error.  Hwnd is the right-clicked snip.
StickySendSnip(Hwnd := 0) {
    global guiSnips, SnipMenu, appName

    if !StickyCfg.Enabled
        return

    if (!Hwnd && SnipMenu.HasProp('_targetHwnd'))
        Hwnd := SnipMenu._targetHwnd
    if !Hwnd
        Hwnd := WinGetID('A')
    if !guiSnips.Has(Hwnd)
        return

    ; ScreenSnip's own clipboard export, not a private copy of it.  That matters
    ; for more than tidiness: SnipToClipboard drops any markup selection handles
    ; first, so a snip sent mid-annotation doesn't arrive with blue boxes on it.
    SnipToClipboard(Hwnd)

    ; Broadcast rather than target a window, so nothing here has to find Sticky
    ; Notes first.  Wrapped because a broadcast to a busy or hung window
    ; elsewhere on the desktop can throw, and that must not take the snip down.
    ;
    ; wParam is a token identifying THIS send, and it is not optional.  Windows
    ; delivers a broadcast to every top-level window in the receiving process,
    ; and Sticky Notes owns one per note plus borders, editors and its manager
    ; window — so a single click here lands there a dozen or more times.  The
    ; token is how the receiver tells those copies apart from a genuine second
    ; send.  A_TickCount is plenty: two menu clicks in the same millisecond
    ; aren't a thing.  Masked to stay positive, since wParam is unsigned.
    sent := false
    try {
        PostMessage(StickyMessageId(), A_TickCount & 0x7FFFFFFF, 0, , 'ahk_id 0xFFFF')
        sent := true
    } catch {
        sent := false
    }

    if !StickyCfg.ShowTip
        return

    ; ProcessExist is a courtesy check for the wording only — see the header.
    ; SplitPath because this setting may arrive either way: hand-typed as a bare
    ; 'StickyNotes.exe', or as a full path if it was picked through a Browse
    ; button.  ProcessExist matches on the NAME, so a full path would never
    ; match and every send would claim Sticky Notes wasn't running.
    running := 0
    if StickyCfg.ProcessName {
        SplitPath(StickyCfg.ProcessName, &stickyExe)
        running := ProcessExist(stickyExe)
    }
    if (sent && running) {
        ToolTip('Sent to Sticky Notes')
        SetTimer(() => ToolTip(), -StickyCfg.TipMs)
    } else {
        ToolTip('Sticky Notes may not be running.`nThe snip is on the clipboard —`npaste it into a note with Ctrl+V.')
        SetTimer(() => ToolTip(), -(StickyCfg.TipMs * 2))
    }
}
