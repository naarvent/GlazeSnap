#Requires AutoHotkey v2.0
#SingleInstance Force
; Hyprland-style mouse gestures for GlazeWM, and hover focus.
;
;   Win + drag left button   -> move    (Hyprland: bindm = SUPER, mouse:272)
;   Win + drag right button  -> resize  (Hyprland: bindm = SUPER, mouse:273)
;   pointer rests on a window -> it takes focus  (Hyprland: follow_mouse)
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
