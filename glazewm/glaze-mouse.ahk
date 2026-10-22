#Requires AutoHotkey v2.0
#SingleInstance Force
; Hyprland-style mouse gestures for GlazeWM, and hover focus.
;
;   Win + drag left button   -> move    (Hyprland: bindm = SUPER, mouse:272)
;   Win + drag right button  -> resize  (Hyprland: bindm = SUPER, mouse:273)
;   pointer rests on a window -> it takes focus  (Hyprland: follow_mouse)
;   N-finger touchpad swipe   -> previous / next workspace  (Hyprland: workspace_swipe)
;   Alt+Shift + that swipe     -> the same, carrying the focused window along
;
; GlazeWM owns the geometry of tiled windows, so moving one with SetWindowPos
; achieves nothing: the WM puts it straight back. Those have to go through the
; tree instead, by sending commands to the HTTP bridge autotiling.mjs runs on
; localhost.
;
; Floating windows belong to nobody, so those are moved directly.
; AltSnap keeps Alt for anyone who wants its more advanced snapping.

; The bridge is not always on the first port: if something else already holds
; it, the daemon moves along and writes where it landed to `bridge-port`. So the
; address is resolved rather than assumed — from that file first, then by asking
; each candidate who it is.
BRIDGE_PORTS := [6124, 6125, 6126, 6127]
BRIDGE_PORT_FILE := A_ScriptDir . "\bridge-port"
BRIDGE := ""           ; resolved on first use

DRAG_THRESHOLD := 6    ; px to travel before it counts as a drag
RESIZE_STEP := 4       ; % change per step
PX_PER_STEP := 28      ; px of mouse travel worth one resize step

; ------------------------------------------------------------- hover focus
;
; GlazeWM has focus_follows_cursor of its own, and this replaces it — the two
; must not both be on, or every hover is focused twice. The config that ships
; with this repo has it set to false for that reason.
;
; What the built-in one does not have is a delay. Focus moves the instant the
; pointer touches a window, so crossing a window on the way somewhere else
; focuses it in passing: the border flashes, the autotiling daemon reads the
; shape of a window you never meant to touch and sets the split axis from it.
; Waiting for the pointer to actually stay on a window fixes all of that, and
; the wait is short enough that a deliberate move still feels immediate.
;
; The rest is knowing when NOT to focus, which is most of the value:
;
;   - while a mouse button is down: that is a drag, or a click on a scrollbar
;     that happens to travel past another window
;   - while a menu is open: moving off it to reach a submenu would dismiss it
;   - over a window a modal dialog has blocked: it cannot be used anyway, and
;     reaching past the dialog to it only makes the dialog flash
;   - over bars, tooltips and the shell: they are not windows you work in
;   - when the pointer has not left the window it is already on: a focus moved
;     with the keyboard is not undone by a cursor sitting still
FOCUS_FOLLOWS_MOUSE := true
FOCUS_DWELL_MS := 90   ; rest this long on a window before it takes focus
FOCUS_POLL_MS := 40    ; how often the pointer is looked at

; Focusing a window through the WM needs `focus --container-id`, which GlazeWM
; has had since 3.9.0 — below what this setup requires, so this is a safety net
; rather than a path anyone should be on. If the daemon ever reports the command
; missing, the window is activated natively instead: the same route a mouse
; click takes, since GlazeWM watches the foreground window and follows it. It
; cannot move focus to an empty monitor, but it is hover focus. Turn it off to
; be told to fix the config by hand instead.
FOCUS_NATIVE_FALLBACK := true

; Never take focus from a pass over these: the shell's own windows, which are
; not places you work. A status bar written by somebody else does not need
; listing — GlazeWM is told to ignore it, so no window is reported there and the
; most a hover over it can do is move focus to the monitor it is on.
FOCUS_SKIP_CLASSES := Map(
    "Shell_TrayWnd", true,                ; taskbar
    "Shell_SecondaryTrayWnd", true,       ; taskbar on the other monitors
    "#32768", true,                       ; menus
    "tooltips_class32", true,
    "Windows.UI.Core.CoreWindow", true,   ; start menu, search
    "XamlExplorerHostIslandWindow", true  ; alt+tab, task view
)

; Touchpad swipe between workspaces — GNOME / Hyprland `workspace_swipe`. Slide
; TOUCHPAD_FINGERS fingers sideways and the workspace changes, the same as
; Alt+[ and Alt+]. Hold Alt+Shift while swiping and the focused window goes with
; you, like Alt+Shift+<n>. Needs a Windows Precision Touchpad; on anything else the
; script says so in the debug log and carries on without it.
;
; Windows gives those swipes its own meaning (three fingers switch apps, four
; switch virtual desktops) and does not stop at telling us about them, so set
; the swipe for that finger count to "Nothing" in Settings > Bluetooth &
; devices > Touchpad, or both happen at once.
TOUCHPAD_SWIPE := true
TOUCHPAD_FINGERS := 3
TOUCHPAD_STEP := 0.15  ; slide this fraction of the pad's width for one workspace
TOUCHPAD_INVERT := false ; false: fingers left -> next workspace, as on Linux
TOUCHPAD_SKIP_EMPTY := false ; true: only workspaces that have windows, like Alt+[ / Alt+]
TOUCHPAD_SETTLE_MS := 70 ; fingers landing wobble; the swipe starts after they settle
TOUCHPAD_COOLDOWN_MS := 120 ; minimum time between two steps

; NOTE: AutoHotkey v2 identifiers are case-insensitive, so a variable named
; DEBUG would collide with a function named Debug(). Hence the longer name.
DEBUG_ENABLED := false
DEBUG_PATH := A_ScriptDir . "\glaze-mouse.log"

Debug(text) {
    global DEBUG_ENABLED, DEBUG_PATH
    if (DEBUG_ENABLED)
        try FileAppend(A_Now . "  " . text . "`n", DEBUG_PATH)
}

Debug("=== glaze-mouse started ===")

; ------------------------------------------------------------------ helpers

HttpGet(url) {
    try {
        request := ComObject("WinHttp.WinHttpRequest.5.1")
        request.Open("GET", url, false)
        request.SetTimeouts(200, 200, 200, 600)
        request.Send()
        return request.ResponseText
    } catch {
        return ""
    }
}

; A port answering is not enough — it has to be our daemon and not whatever
; else happened to grab it.
IsOurBridge(port) {
    return InStr(HttpGet("http://127.0.0.1:" . port . "/ping"), '"service":"glazesnap"') > 0
}

ResolveBridge() {
    global BRIDGE, BRIDGE_PORTS, BRIDGE_PORT_FILE

    saved := ""
    try saved := Trim(FileRead(BRIDGE_PORT_FILE))
    if (saved != "" && IsOurBridge(saved)) {
        BRIDGE := "http://127.0.0.1:" . saved
        Debug("bridge resolved from bridge-port: " . BRIDGE)
        return true
    }

    for port in BRIDGE_PORTS {
        if (IsOurBridge(port)) {
            BRIDGE := "http://127.0.0.1:" . port
            Debug("bridge found by probing: " . BRIDGE)
            return true
        }
    }

    BRIDGE := ""
    Debug("no bridge found on " . BRIDGE_PORTS.Length . " candidate ports")
    return false
}

Query(route) {
    global BRIDGE
    if (BRIDGE != "") {
        answer := HttpGet(BRIDGE . route)
        if (answer != "")
            return answer
    }
    ; Empty either because we never resolved, or because the daemon restarted
    ; somewhere else. Worth one re-resolve before giving up on the gesture.
    if (!ResolveBridge())
        return ""
    return HttpGet(BRIDGE . route)
}

; Pulls one field out of a flat JSON object. The bridge responses are flat and
; written by us, so a real parser would be overkill.
Field(json, key) {
    if RegExMatch(json, '"' . key . '":\s*"([^"]*)"', &m)
        return m[1]
    if RegExMatch(json, '"' . key . '":\s*([-\d.]+|true|false)', &m)
        return m[1]
    return ""
}

; Not called Send(): AutoHotkey v2 lets a user function shadow the built-in of
; that name, and a reader would reasonably assume the built-in is what runs.
SendCommand(command) {
    Query("/cmd?c=" . UriEncode(command))
}

UriEncode(text) {
    static safe := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
    out := ""
    for byte in StrToUtf8(text) {
        char := Chr(byte)
        out .= InStr(safe, char, true) ? char : Format("%{:02X}", byte)
    }
    return out
}

StrToUtf8(text) {
    bytes := []
    size := StrPut(text, "UTF-8")
    buf := Buffer(size)
    StrPut(text, buf, "UTF-8")
    loop size - 1
        bytes.Push(NumGet(buf, A_Index - 1, "UChar"))
    return bytes
}

; The handle goes along with the point on purpose. A rectangle test on the
; bridge side cannot see which of two overlapping windows is on top, and
; Windows already knows.
StateUnderCursor() {
    MouseGetPos(&mx, &my, &hwnd)
    return { json: Query("/state?x=" . mx . "&y=" . my . "&hwnd=" . hwnd), x: mx, y: my, hwnd: hwnd }
}

; --------------------------------------------------------------- hover focus

hoverCandidate := 0    ; the window the pointer is over right now
hoverSince := 0        ; when it arrived there
hoverFocused := 0      ; the last window we asked for focus, so we ask once
hoverQuietUntil := 0   ; nothing answered: stop asking for a while
hoverNativeUntil := 0  ; the WM cannot focus by id: activate windows ourselves

; A gesture can afford to spend a moment finding the bridge again. Hover focus
; cannot: it would pay that cost on every window the pointer crosses, and a
; daemon that is down stays down for longer than one hover.
HOVER_QUIET_MS := 5000
HOVER_RETRY_MS := 1000    ; the daemon said "not now"
HOVER_UNSUPPORTED_MS := 60000 ; it said this GlazeWM cannot focus by id

if (FOCUS_FOLLOWS_MOUSE)
    SetTimer(HoverFocus, FOCUS_POLL_MS)

HoverFocus() {
    global FOCUS_DWELL_MS, FOCUS_SKIP_CLASSES, FOCUS_NATIVE_FALLBACK
    global HOVER_QUIET_MS, HOVER_RETRY_MS, HOVER_UNSUPPORTED_MS
    global hoverCandidate, hoverSince, hoverFocused, hoverQuietUntil, hoverNativeUntil

    if (A_TickCount < hoverQuietUntil)
        return

    ; A held button is a drag, a text selection, or a scrollbar being pulled
    ; past the edge of its window. None of them are a request to change focus.
    if (GetKeyState("LButton", "P") || GetKeyState("RButton", "P") || GetKeyState("MButton", "P")) {
        hoverCandidate := 0
        return
    }

    ; An open menu closes the moment focus goes elsewhere, and reaching a
    ; submenu means travelling over whatever is behind it.
    if (WinExist("ahk_class #32768"))
        return

    MouseGetPos(&mx, &my, &hwnd)
    if (!hwnd)
        return

    ; The pointer entering a window starts the clock; nothing happens until it
    ; is still there when the clock runs out. Note what is NOT here: any test on
    ; whether the pointer moved. Focus is decided by which window it is over, so
    ; a focus moved with the keyboard is not undone by a cursor sitting still on
    ; the previous one.
    if (hwnd != hoverCandidate) {
        hoverCandidate := hwnd
        hoverSince := A_TickCount
        return
    }
    if (hwnd = hoverFocused)
        return
    if (A_TickCount - hoverSince < FOCUS_DWELL_MS)
        return

    ; `class` would be a keyword, and AutoHotkey identifiers are
    ; case-insensitive, so the longer name is not optional.
    windowClass := ""
    try windowClass := WinGetClass("ahk_id " . hwnd)
    if (FOCUS_SKIP_CLASSES.Has(windowClass)) {
        hoverFocused := hwnd      ; remembered so it is not re-tested every tick
        return
    }

    if (BlockedByModal(hwnd))
        return

    ; The WM told us it cannot focus by id, so windows are activated here
    ; instead. The bridge is asked again once the minute is up: a GlazeWM
    ; upgrade, or a daemon that reconnected to a newer one, should be picked up
    ; without restarting anything.
    ;
    ; The desktop is the exception and still goes through the bridge below.
    ; Hovering it means "focus this monitor", there is no window to activate for
    ; that, and the command behind it is an old one that works on the GlazeWM
    ; versions this mode exists for.
    isDesktop := (windowClass = "Progman" || windowClass = "WorkerW")
    if (FOCUS_NATIVE_FALLBACK && !isDesktop && A_TickCount < hoverNativeUntil) {
        try WinActivate("ahk_id " . hwnd)
        hoverFocused := hwnd
        return
    }

    answer := Query("/focus?x=" . mx . "&y=" . my . "&hwnd=" . hwnd)
    Debug("hover " . hwnd . " (" . windowClass . ") -> " . (answer = "" ? "<no bridge>" : answer))

    ; Nothing answered: the daemon is down, and it will still be down in a
    ; moment. Note that hoverFocused is NOT set here, or on any other failure —
    ; marking a window as asked-for when the asking failed means the pointer has
    ; to leave it and come back before it can ever be focused.
    if (answer = "") {
        hoverQuietUntil := A_TickCount + HOVER_QUIET_MS
        return
    }

    ; The daemon has found out that this GlazeWM cannot focus a window by id.
    ; Whichever way that is handled, it is a decision for a minute and not for
    ; good: a daemon restart or a GlazeWM upgrade brings the proper path back
    ; without restarting AutoHotkey.
    if (InStr(answer, '"supported":false')) {
        if (FOCUS_NATIVE_FALLBACK) {
            hoverNativeUntil := A_TickCount + HOVER_UNSUPPORTED_MS
            Debug("hover focus: no focus by id, activating windows natively for a minute")
        } else {
            hoverQuietUntil := A_TickCount + HOVER_UNSUPPORTED_MS
            Debug("hover focus: no focus by id and no fallback, retrying in a minute")
        }
        return
    }

    ; Success has to be stated, not assumed from "something came back". A 404 —
    ; an older daemon still holding the bridge port after an upgrade — and the
    ; bridge's own 500 body are both non-empty and match none of the cases
    ; above, and taking them for success marked the window as done and let hover
    ; focus die without a word in the log.
    ;
    ; Anything else is the daemon saying "not now": a socket that just dropped,
    ; or a window that closed under the pointer.
    if (!InStr(answer, '"ok":true')) {
        hoverQuietUntil := A_TickCount + HOVER_RETRY_MS
        Debug("hover focus: unexpected answer, retrying shortly")
        return
    }

    hoverFocused := hwnd
}

; Would focusing this window mean reaching past a modal dialog to the window
; that dialog has blocked?
;
; A modal dialog disables its owner while it is open — that is what makes it
; modal, and it is the one dependable way to recognise one. Focusing a disabled
; owner achieves nothing except making the dialog flash.
;
; Only the owners of the dialog in front are protected, and the chain is walked
; because dialogs open dialogs. Everything else on the desktop is fair game:
; testing "is any modal dialog up" instead, which is what this did first, meant
; a Save-As box in one application froze hover focus on every other window and
; every other monitor until it was answered.
BlockedByModal(candidate) {
    window := WinExist("A")
    if (!window || window = candidate)
        return false

    loop 8 {   ; a depth no real dialog stack reaches
        owner := DllCall("GetWindow", "ptr", window, "uint", 4, "ptr")  ; GW_OWNER
        if (!owner)
            return false
        if (owner = candidate)
            return !DllCall("IsWindowEnabled", "ptr", owner)
        window := owner
    }
    return false
}

; ----------------------------------------------------------- touchpad swipe
;
; Windows does not hand multi-finger gestures to applications, but a Precision
; Touchpad is a HID device, and Raw Input will deliver its reports to anyone who
; registers for it — including while another window has focus (RIDEV_INPUTSINK).
; What arrives is the raw contact data, so the swipe is worked out here.
;
; A touchpad frame is a contact count plus, per finger, an id and a position.
; The count comes first and the fingers may be spread over several reports
; ("hybrid" mode), so a frame is only complete once that many fingers have been
; read. The positions are taken in fractions of the pad, which makes the step
; the same on any size of touchpad.

padGui := ""
padDevices := Map()    ; device handle -> its layout, or 0 if it is not usable
padRemaining := 0      ; fingers of the current frame not read yet
padTotal := 0          ; fingers the current frame announced
padContacts := Map()   ; finger id -> {x, y} for the current frame
padAnchorX := ""       ; where the fingers were when the swipe started or last stepped
padAnchorY := ""
padLanded := 0         ; when the right number of fingers arrived
padLastStep := 0       ; when the last workspace change was sent
padLastDirection := 0  ; +1 next, -1 previous
padCarryId := ""       ; the window an Alt+Shift swipe is carrying

if (TOUCHPAD_SWIPE)
    InitTouchpad()

InitTouchpad() {
    global padGui
    ; Raw Input needs a window to deliver to. It is never shown.
    padGui := Gui()

    ; RAWINPUTDEVICE: usage page, usage, flags, target window.
    size := 8 + A_PtrSize
    device := Buffer(size, 0)
    NumPut("ushort", 0x0D, "ushort", 0x05, "uint", 0x100, "ptr", padGui.Hwnd, device)  ; digitizer / touch pad, INPUTSINK
    if (!DllCall("RegisterRawInputDevices", "ptr", device, "uint", 1, "uint", size, "int")) {
        Debug("touchpad: RegisterRawInputDevices failed, swipe disabled")
        return
    }
    OnMessage(0x00FF, OnRawInput)   ; WM_INPUT
    Debug("touchpad: listening for " . TOUCHPAD_FINGERS . "-finger swipes")
}

OnRawInput(wParam, lParam, msg, hwnd) {
    static headerSize := 8 + 2 * A_PtrSize   ; RAWINPUTHEADER

    size := 0
    DllCall("GetRawInputData", "ptr", lParam, "uint", 0x10000003, "ptr", 0, "uint*", &size, "uint", headerSize, "uint")
    if (!size)
        return
    raw := Buffer(size)
    if (DllCall("GetRawInputData", "ptr", lParam, "uint", 0x10000003, "ptr", raw, "uint*", &size, "uint", headerSize, "uint") != size)
        return
    if (NumGet(raw, 0, "uint") != 2)   ; RIM_TYPEHID
        return

    layout := PadLayout(NumGet(raw, 8, "ptr"))
    if (!layout)
        return

    ; RAWHID: the size of one report, how many there are, then the reports.
    reportSize := NumGet(raw, headerSize, "uint")
    reportCount := NumGet(raw, headerSize + 4, "uint")
    loop reportCount
        PadReport(layout, raw.Ptr + headerSize + 8 + (A_Index - 1) * reportSize, reportSize)
}

; What the touchpad can report, worked out once per device from its HID
; descriptor: where the contact count lives, and for each finger slot which link
; collection holds its id and position.
PadLayout(device) {
    global padDevices
    if (padDevices.Has(device))
        return padDevices[device]
    padDevices[device] := 0

    size := 0
    DllCall("GetRawInputDeviceInfoW", "ptr", device, "uint", 0x20000005, "ptr", 0, "uint*", &size)  ; RIDI_PREPARSEDDATA
    if (!size)
        return 0
    preparsed := Buffer(size)
    if (DllCall("GetRawInputDeviceInfoW", "ptr", device, "uint", 0x20000005, "ptr", preparsed, "uint*", &size, "uint") = 0xFFFFFFFF)
        return 0

    caps := Buffer(64, 0)   ; HIDP_CAPS
    if (DllCall("hid\HidP_GetCaps", "ptr", preparsed, "ptr", caps, "int") != 0x110000)
        return 0
    count := NumGet(caps, 48, "ushort")   ; NumberInputValueCaps
    if (!count)
        return 0
    valueCaps := Buffer(72 * count, 0)    ; HIDP_VALUE_CAPS
    if (DllCall("hid\HidP_GetValueCaps", "int", 0, "ptr", valueCaps, "ushort*", &count, "ptr", preparsed, "int") != 0x110000)
        return 0

    layout := { preparsed: preparsed, countLink: -1, slots: Map(), xMin: 0, xRange: 0, yMin: 0, yRange: 0 }
    loop count {
        base := (A_Index - 1) * 72
        if (NumGet(valueCaps, base + 12, "uchar"))   ; IsRange: not how touchpads describe a finger
            continue
        page := NumGet(valueCaps, base, "ushort")
        link := NumGet(valueCaps, base + 6, "ushort")
        usage := NumGet(valueCaps, base + 56, "ushort")
        low := NumGet(valueCaps, base + 40, "int")
        high := NumGet(valueCaps, base + 44, "int")

        if (page = 0x0D && usage = 0x54) {         ; contact count
            layout.countLink := link
        } else if (page = 0x0D && usage = 0x51) {  ; contact id
            PadSlot(layout, link).id := true
        } else if (page = 0x01 && usage = 0x30) {  ; X
            PadSlot(layout, link).x := true
            layout.xMin := low, layout.xRange := high - low
        } else if (page = 0x01 && usage = 0x31) {  ; Y
            PadSlot(layout, link).y := true
            layout.yMin := low, layout.yRange := high - low
        }
    }

    ; Fingers are read in link collection order, which is the order they fill.
    links := []
    for link, slot in layout.slots {
        if (slot.id && slot.x && slot.y)
            links.Push(link)
    }
    if (layout.countLink < 0 || !links.Length || layout.xRange <= 0 || layout.yRange <= 0)
        return 0
    loop links.Length - 1 {
        loop links.Length - A_Index {
            if (links[A_Index] > links[A_Index + 1]) {
                swap := links[A_Index], links[A_Index] := links[A_Index + 1], links[A_Index + 1] := swap
            }
        }
    }
    layout.links := links
    padDevices[device] := layout
    Debug("touchpad: " . links.Length . " contacts per report, x range " . layout.xRange . ", y range " . layout.yRange)
    return layout
}

PadSlot(layout, link) {
    if (!layout.slots.Has(link))
        layout.slots[link] := { id: false, x: false, y: false }
    return layout.slots[link]
}

PadValue(layout, page, link, usage, report, length, &value) {
    value := 0
    return DllCall("hid\HidP_GetUsageValue", "int", 0, "ushort", page, "ushort", link, "ushort", usage
        , "uint*", &value, "ptr", layout.preparsed, "ptr", report, "uint", length, "int") = 0x110000
}

PadReport(layout, report, length) {
    global padRemaining, padTotal, padContacts

    ; A report of some other kind (a button, a different report id) fails here.
    if (!PadValue(layout, 0x0D, layout.countLink, 0x54, report, length, &fingers))
        return

    if (fingers > 0) {
        padTotal := padRemaining := fingers
        padContacts := Map()
    } else if (padRemaining = 0) {
        PadFrame(0)     ; nothing on the pad
        return
    }

    for link in layout.links {
        if (padRemaining <= 0)
            break
        if (!PadValue(layout, 0x0D, link, 0x51, report, length, &id)
            || !PadValue(layout, 0x01, link, 0x30, report, length, &x)
            || !PadValue(layout, 0x01, link, 0x31, report, length, &y))
            continue
        padContacts[id] := { x: (x - layout.xMin) / layout.xRange, y: (y - layout.yMin) / layout.yRange }
        padRemaining--
    }

    if (padRemaining <= 0)
        PadFrame(padTotal)
}

; One complete frame. The swipe is tracked from the point the right number of
; fingers were down; every time the centre of them has travelled TOUCHPAD_STEP
; sideways it is one workspace, and the point travelled from starts over, so
; carrying on sliding keeps going — the way it does on Linux.
PadFrame(fingers) {
    global TOUCHPAD_FINGERS, TOUCHPAD_STEP, TOUCHPAD_INVERT, TOUCHPAD_SKIP_EMPTY
    global TOUCHPAD_SETTLE_MS, TOUCHPAD_COOLDOWN_MS
    global padContacts, padAnchorX, padAnchorY, padLanded, padLastStep, padLastDirection, padCarryId

    ; Any other number of fingers is some other gesture, or a finger lifting
    ; early. The swipe starts again from wherever the right number come back.
    if (fingers != TOUCHPAD_FINGERS) {
        padAnchorX := ""
        padLanded := 0
        padLastDirection := 0
        padCarryId := ""
        return
    }

    sumX := 0, sumY := 0
    for id, contact in padContacts
        sumX += contact.x, sumY += contact.y
    centreX := sumX / fingers, centreY := sumY / fingers

    ; Fingers do not land cleanly: the first few frames drift and read as a
    ; swipe in a random direction. The swipe is measured from where they settle.
    if (!padLanded)
        padLanded := A_TickCount
    if (A_TickCount - padLanded < TOUCHPAD_SETTLE_MS) {
        padAnchorX := centreX, padAnchorY := centreY
        return
    }

    dx := centreX - padAnchorX, dy := centreY - padAnchorY

    ; Mostly vertical is Windows' own territory (task view, show desktop). Not
    ; ours, and not worth keeping the old starting point for either.
    if (Abs(dy) > Abs(dx)) {
        if (Abs(dy) >= TOUCHPAD_STEP)
            padAnchorX := centreX, padAnchorY := centreY
        return
    }
    next := (dx < 0) != TOUCHPAD_INVERT
    direction := next ? 1 : -1

    ; Turning back mid-swipe takes twice the travel: a hand that slows down at
    ; the end of a slide wobbles backwards, and that is not a request to return.
    needed := (padLastDirection = -direction) ? TOUCHPAD_STEP * 2 : TOUCHPAD_STEP
    if (Abs(dx) < needed || A_TickCount - padLastStep < TOUCHPAD_COOLDOWN_MS)
        return

    padAnchorX := centreX, padAnchorY := centreY
    padLastStep := A_TickCount
    padLastDirection := direction
    target := (next ? "next" : "prev") . (TOUCHPAD_SKIP_EMPTY ? "-active" : "") . "-workspace"

    ; Alt+Shift held: carry the focused window along and follow it, the same
    ; pair of commands as Alt+Shift+<n>. The focus is relative to the workspace
    ; we are still on, so it lands next to the one the window went to.
    carry := GetKeyState("Alt", "P") && GetKeyState("Shift", "P")
    Debug("touchpad swipe -> " . (carry ? "move + " : "") . "focus --" . target)
    ; Sent from a timer: the bridge call can wait, and this is a message handler
    ; that has the next report queued behind it.
    SetTimer(() => PadStep(carry, target), -1)
}

; `move` leaves the focus where it was, and in the workspace the window lands on
; that is the window that was already there. So a second step of the same swipe
; would carry that one instead. The window is picked once, when the swipe starts
; carrying, and addressed by id from then on; after each step it is given the
; focus again so the next one starts from it too.
PadStep(carry, target) {
    global padCarryId
    ; The next touchpad report arrives while this waits on the bridge, and a
    ; step cut off between the move and the refocus leaves the window on one
    ; workspace and you on another.
    Critical
    if (carry && padCarryId = "") {
        state := Query("/state?x=0&y=0&hwnd=" . WinExist("A"))
        if (Field(state, "found") = "true")
            padCarryId := Field(state, "id")
        Debug("  carrying window " . (padCarryId = "" ? "<none found>" : padCarryId))
    }
    if (carry && padCarryId != "")
        Debug("  move --" . target . " -> " . Query("/cmd?c=" . UriEncode("--id " . padCarryId . " move --" . target)))
    Debug("  focus --" . target . " -> " . Query("/cmd?c=" . UriEncode("focus --" . target)))
    if (carry && padCarryId != "")
        Debug("  refocus -> " . Query("/cmd?c=" . UriEncode("focus --container-id " . padCarryId)))
}

; --------------------------------------------------------------------- move

#LButton:: {
    global DRAG_THRESHOLD
    state := StateUnderCursor()
    Debug("win+LButton at " . state.x . "," . state.y . "  response=" . (state.json = "" ? "<EMPTY: bridge not answering>" : state.json))
    if (Field(state.json, "found") != "true")
        return

    id := Field(state.json, "id")
    isTiling := Field(state.json, "tiling") = "true"
    startX := state.x, startY := state.y

    if (!isTiling) {
        MoveFloating(state.hwnd, startX, startY)
        return
    }

    ; Tiled: wait for the release and turn the gesture into a direction. Moving
    ; inside the tree is discrete, not continuous — re-shuffling the layout on
    ; every pixel would be nonsense.
    while GetKeyState("LButton", "P")
        Sleep(10)

    MouseGetPos(&endX, &endY)
    dx := endX - startX, dy := endY - startY
    if (Abs(dx) < DRAG_THRESHOLD && Abs(dy) < DRAG_THRESHOLD)
        return

    direction := Abs(dx) > Abs(dy)
        ? (dx > 0 ? "right" : "left")
        : (dy > 0 ? "down" : "up")
    SendCommand("--id " . id . " move --direction " . direction)
}

; The handle comes from the hit test rather than being looked up again: the
; window under the cursor when the button went down is the one being dragged,
; and by now the pointer may already have left it.
MoveFloating(hwnd, startX, startY) {
    if (!hwnd)
        return

    WinGetPos(&wx, &wy, , , "ahk_id " . hwnd)
    offsetX := startX - wx, offsetY := startY - wy

    while GetKeyState("LButton", "P") {
        MouseGetPos(&mx, &my)
        try WinMove(mx - offsetX, my - offsetY, , , "ahk_id " . hwnd)
        Sleep(8)
    }
}

; ------------------------------------------------------------------- resize

#RButton:: {
    global RESIZE_STEP, PX_PER_STEP
    state := StateUnderCursor()
    Debug("win+RButton at " . state.x . "," . state.y . "  response=" . (state.json = "" ? "<EMPTY: bridge not answering>" : state.json))
    if (Field(state.json, "found") != "true")
        return

    id := Field(state.json, "id")
    isTiling := Field(state.json, "tiling") = "true"
    startX := state.x, startY := state.y

    if (!isTiling) {
        ResizeFloating(state.hwnd, startX, startY)
        return
    }

    ; Tiled: the drag becomes percentage steps. What has already been applied is
    ; tracked so the resize follows the mouse instead of running away with every
    ; movement event.
    appliedX := 0, appliedY := 0
    while GetKeyState("RButton", "P") {
        MouseGetPos(&mx, &my)
        wantX := Round((mx - startX) / PX_PER_STEP)
        wantY := Round((my - startY) / PX_PER_STEP)

        while (appliedX != wantX) {
            step := (wantX > appliedX) ? 1 : -1
            SendCommand("--id " . id . " resize --width " . (step > 0 ? "+" : "-") . RESIZE_STEP . "%")
            appliedX += step
        }
        while (appliedY != wantY) {
            step := (wantY > appliedY) ? 1 : -1
            SendCommand("--id " . id . " resize --height " . (step > 0 ? "+" : "-") . RESIZE_STEP . "%")
            appliedY += step
        }
        Sleep(16)
    }
}

ResizeFloating(hwnd, startX, startY) {
    if (!hwnd)
        return
    WinGetPos(&wx, &wy, &width, &height, "ahk_id " . hwnd)

    while GetKeyState("RButton", "P") {
        MouseGetPos(&mx, &my)
        newWidth := Max(120, width + (mx - startX))
        newHeight := Max(80, height + (my - startY))
        try WinMove(wx, wy, newWidth, newHeight, "ahk_id " . hwnd)
        Sleep(8)
    }
}
