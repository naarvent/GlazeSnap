#!/usr/bin/env node
/**
 * Autotiling daemon for GlazeWM v3 — emulates komorebi's BSP/dwindle layout.
 *
 * The idea is the one sway's `autotiling` script uses: GlazeWM inserts every
 * new window as a sibling of the focused one, following the tiling direction
 * of the parent container. Set that direction from the shape of the focused
 * window before each insertion — always split along the longer side — and what
 * comes out is a binary partition of the screen.
 *
 * It also owns three things that grew out of the same event loop: an HTTP bridge
 * the other scripts talk to, the fullscreen-game taskbar fix, and floating the
 * popups that have no business being tiled.
 *
 * Requires Node 22+ for the global WebSocket. No dependencies, no elevation:
 * GlazeWM's IPC is a plain TCP socket on localhost.
 */

const IPC_URL = 'ws://127.0.0.1:6123';

// The bridge is an HTTP server for glaze-mouse.ahk, which has no sockets but
// does speak HTTP through WinHttpRequest. Its port doubles as a single-instance
// lock, because only one process can listen on a port.
//
// Using it as a lock needs care: a failed bind means "someone is here", not
// "another copy of me is here". So a taken port is probed. If it answers /ping
// as this service, it really is a second copy and this one exits. If it is a
// stranger, the bridge moves to the next port instead of dying silently.
//
// Moving costs something: the port is also the address clients use, so it is
// written to PORT_FILE and clients resolve it from there.
const BRIDGE_PORTS = [6124, 6125, 6126, 6127];
const SERVICE = 'glazesnap';
const PORT_FILE = fileURLToPath(new URL('./bridge-port', import.meta.url));

const EVENTS = ['focus_changed', 'window_managed', 'window_unmanaged', 'workspace_activated'];
const MAX_RETRIES = 10; // roughly two minutes of backoff before giving up
const MAX_PASSES = 6; // deepest tree the rebalancer will walk
const SETTLE_MS = 300; // let the WM finish moving things before we look

// --- placement ---------------------------------------------------------
const PLACE_GAP = 6; // px around a placed window, matches inner_gap
const PLACE_MIN = { width: 160, height: 100 }; // never ask for a slit
// A caller usually places a window it has just launched, so the window may not
// exist yet when the request arrives. Wait rather than fail.
const PLACE_TRIES = 20;
const PLACE_POLL_MS = 100;

// --- hover focus -------------------------------------------------------
// One failed focus command is not a verdict. The window may have closed in the
// two round trips since the hit test, or GlazeWM may have refused for a reason
// of its own. Only a run of failures with no success in between means the
// command is not there at all — and getting that wrong costs the user hover
// focus for the rest of the session.
const FOCUS_FAILURES = 5;

// --- popups ------------------------------------------------------------
// Tiling a dialog is the most disruptive thing a tiling WM does to an ordinary
// Windows desktop: the layout is rearranged around a "Save as" box, and it is
// rearranged again when the box closes. GlazeWM's window_rules can only match
// process, class and title, which is not enough — what makes a window a popup
// is its Win32 style and whether another window owns it, and neither is visible
// over the IPC. So the daemon asks `wm-helpers inspect` and decides here.
//
// The policy is deliberately in this file: it is a text file you can edit and
// reload, while the helper needs a compiler.
const POPUPS = {
  enabled: true,

  // Owned windows are dialogs, palettes and inspectors. Their owner is the
  // real window; they come and go around it.
  floatOwned: true,

  // WS_EX_TOOLWINDOW is the explicit "I am a utility window" bit.
  floatToolWindows: true,

  // No resize border and no maximize box: the application refuses to be given
  // a size, so tiling it leaves either a hole or an overlap. This is the one
  // rule that can catch a small main window — turn it off if an application
  // you use stops tiling.
  floatNonResizable: true,

  // A borderless popup counts as one only while it is smaller than this
  // fraction of the work area, so a borderless fullscreen game is left alone.
  smallFraction: 0.6,

  // Process names, lowercase. Escape hatches for when the heuristics get it
  // wrong on your machine — no rebuild, just an edit and a restart.
  neverFloat: [],
  alwaysFloat: [],
};

const LOG_PATH = new URL('./autotiling.log', import.meta.url);
const MAX_LOG_BYTES = 512 * 1024;

import { appendFileSync, existsSync, statSync, truncateSync, writeFileSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Native helper, source in wm-helpers/. Node cannot reach the Windows window
// API, and the taskbar fix needs SetWindowPos while popup detection needs the
// window style bits. Everything else works without it.
const HELPER = fileURLToPath(new URL('./wm-helpers.exe', import.meta.url));
const HELPER_AVAILABLE = existsSync(HELPER);

/** Runs wm-helpers and returns its JSON, or null if anything goes wrong. */
function helper(...args) {
  return new Promise((resolve) => {
    execFile(HELPER, args, { timeout: 5000, windowsHide: true }, (err, stdout) => {
      if (err) {
        log(`wm-helpers ${args[0]}: ${err.message}`);
        resolve(null);
        return;
      }
      try {
        resolve(JSON.parse(stdout));
      } catch {
        resolve(null);
      }
    });
  });
}

function log(line) {
  const stamp = new Date().toISOString();
  const text = `${stamp} ${line}\n`;
  process.stdout.write(text);
  try {
    try {
      if (statSync(LOG_PATH).size > MAX_LOG_BYTES) truncateSync(LOG_PATH, 0);
    } catch {
      // Log file does not exist yet.
    }
    appendFileSync(LOG_PATH, text);
  } catch {
    // A failing log is not worth killing the process over.
  }
}

const clamp = (value, low, high) => Math.min(Math.max(value, low), high);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Is this window a transient popup rather than something worth a tile?
 *
 * `facts` is what `wm-helpers inspect` printed. The order of the tests is the
 * point: the explicit signals an application can send ("I am a taskbar app",
 * "I am a tool window") are read before the heuristics that guess from shape.
 */
function popupVerdict(facts, policy = POPUPS) {
  if (!facts?.ok) return { float: false, reason: 'no window facts' };

  const process = (facts.process ?? '').toLowerCase();
  const lower = (list) => list.map((name) => name.toLowerCase());
  if (lower(policy.neverFloat).includes(process)) {
    return { float: false, reason: `${process} is on the never-float list` };
  }
  if (lower(policy.alwaysFloat).includes(process)) {
    return { float: true, reason: `${process} is on the always-float list` };
  }

  const style = facts.style ?? {};
  const exStyle = facts.exStyle ?? {};

  // WS_EX_APPWINDOW is how a window asks for its own taskbar button: it is
  // claiming to be a main window, and that claim outranks every guess below.
  if (exStyle.appWindow) return { float: false, reason: 'WS_EX_APPWINDOW' };

  // A child window is not a top-level window at all: its coordinates belong to
  // its parent's client area. GlazeWM should never see one, and if it does,
  // floating it — which means centring it on the workspace — would move it
  // somewhere that means nothing. Hands off entirely.
  if (style.child) return { float: false, reason: 'child window, not ours to move' };

  // Anything covering its whole monitor is not a popup, whatever its style bits
  // say. A borderless fullscreen game has no resize border and no maximize box
  // either, and floating one would move it: centred, then slid inside the
  // workspace, several pixels off the monitor edge it was covering exactly.
  const work = facts.work ?? {};
  const rect = facts.rect ?? {};
  const measured = work.width > 0 && work.height > 0;
  if (measured && rect.width >= work.width && rect.height >= work.height) {
    return { float: false, reason: 'covers the monitor' };
  }

  if (exStyle.noActivate) return { float: true, reason: 'WS_EX_NOACTIVATE' };
  if (policy.floatToolWindows && exStyle.toolWindow) {
    return { float: true, reason: 'tool window' };
  }
  if (policy.floatOwned && facts.owner) {
    return {
      float: true,
      reason: facts.ownerDisabled ? 'modal dialog' : `owned by ${facts.ownerProcess || 'another window'}`,
    };
  }
  if (facts.dialogClass) return { float: true, reason: `dialog class ${facts.class}` };

  if (policy.floatNonResizable && !style.thickFrame && !style.maximizeBox) {
    return { float: true, reason: 'cannot be resized' };
  }

  const small =
    measured &&
    rect.width <= work.width * policy.smallFraction &&
    rect.height <= work.height * policy.smallFraction;
  if (style.popup && !style.caption && small) {
    return { float: true, reason: 'small borderless popup' };
  }

  return { float: false, reason: 'ordinary application window' };
}

/**
 * Reads the fractions of a /place request.
 *
 * Everything is optional and defaults to the whole workspace. A missing
 * parameter used to arrive as `Number(null)`, which is 0, so leaving out `fw`
 * asked for a window of negative width and got whatever GlazeWM made of that.
 * Out-of-range values are clamped rather than refused: the caller wants a
 * window it can see, not an error message.
 */
function readFractions(raw) {
  const MIN_FRACTION = 0.05;
  const read = (value, fallback) => {
    if (value === null || value === undefined || value === '') return fallback;
    const number = Number(value);
    return Number.isFinite(number) ? number : NaN;
  };

  const asked = {
    fx: read(raw.fx, 0),
    fy: read(raw.fy, 0),
    fWidth: read(raw.fWidth, 1),
    fHeight: read(raw.fHeight, 1),
  };
  if (Object.values(asked).some(Number.isNaN)) {
    return { error: 'fx, fy, fw and fh have to be numbers' };
  }

  const fx = clamp(asked.fx, 0, 1 - MIN_FRACTION);
  const fy = clamp(asked.fy, 0, 1 - MIN_FRACTION);
  const fWidth = clamp(asked.fWidth, MIN_FRACTION, 1 - fx);
  const fHeight = clamp(asked.fHeight, MIN_FRACTION, 1 - fy);
  const clamped = { fx, fy, fWidth, fHeight };

  return {
    ...clamped,
    adjusted: Object.keys(clamped).some((key) => clamped[key] !== asked[key]),
    asked,
  };
}

/**
 * The pixel rectangle a fraction of a workspace stands for.
 *
 * The gap is not the same on every side, and that is what makes a placed window
 * line up with the tiled ones next to it: a full gap where the cell touches the
 * edge of the workspace, half a gap on a seam it shares with the neighbouring
 * cell — the two halves adding up to the one gap `inner_gap` puts between two
 * tiles. Insetting all four sides by the full gap, which is what this did
 * before, left twice as much air down the middle as around the outside.
 */
function cellRect(workspace, fractions, gap = PLACE_GAP) {
  const EDGE = 0.005; // slack, so 0.3333 + 0.6667 still counts as "the edge"
  const inset = (touchesEdge) => (touchesEdge ? gap : gap / 2);

  const left = workspace.x + fractions.fx * workspace.width;
  const top = workspace.y + fractions.fy * workspace.height;
  const right = workspace.x + (fractions.fx + fractions.fWidth) * workspace.width;
  const bottom = workspace.y + (fractions.fy + fractions.fHeight) * workspace.height;

  const x = Math.round(left + inset(fractions.fx <= EDGE));
  const y = Math.round(top + inset(fractions.fy <= EDGE));
  const rightEdge = Math.round(right - inset(fractions.fx + fractions.fWidth >= 1 - EDGE));
  const bottomEdge = Math.round(bottom - inset(fractions.fy + fractions.fHeight >= 1 - EDGE));

  // The minimum is a floor on a cell that would otherwise be a slit, and it can
  // push the cell past the edge it was measured from: a 5% strip of a 1920px
  // workspace is 96px, so the floor of 160 hangs 64px off the screen. Growing a
  // rectangle means checking again that it still fits.
  const box = {
    width: Math.min(Math.max(PLACE_MIN.width, rightEdge - x), workspace.width - gap * 2),
    height: Math.min(Math.max(PLACE_MIN.height, bottomEdge - y), workspace.height - gap * 2),
  };
  return { ...fitInside({ ...box, x, y }, workspace, gap), ...box };
}

/**
 * Slides a box until it lies inside an area, without resizing it.
 *
 * Used on windows that ended up somewhere they cannot be reached: a dialog an
 * application centred on coordinates from a monitor that is no longer plugged
 * in, or one that refused the size it was given and now hangs off the edge.
 * The top-left corner wins if the box is simply too big — a window you can
 * grab beats a window whose title bar is off-screen.
 */
function fitInside(box, area, gap = PLACE_GAP) {
  const lowX = area.x + gap;
  const lowY = area.y + gap;
  const highX = Math.max(lowX, area.x + area.width - gap - box.width);
  const highY = Math.max(lowY, area.y + area.height - gap - box.height);
  return { x: Math.round(clamp(box.x, lowX, highX)), y: Math.round(clamp(box.y, lowY, highY)) };
}

/** Is this point inside this rectangle? */
const contains = (rect, x, y) =>
  x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height;

/** Walks a workspace tree looking for a window node, and says where it was. */
function locate(workspaces, matches) {
  for (const workspace of workspaces) {
    let hit = null;
    const visit = (node) => {
      if (hit) return;
      if (node.type === 'window' && matches(node)) {
        hit = node;
        return;
      }
      for (const child of node.children ?? []) visit(child);
    };
    for (const child of workspace.children ?? []) visit(child);
    if (hit) return { window: hit, workspace };
  }
  return null;
}

/** Is whatever holds this port one of us? */
async function isOurBridge(port) {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/ping`, {
      signal: AbortSignal.timeout(400),
    });
    return (await res.json())?.service === SERVICE;
  } catch {
    return false;
  }
}

/**
 * Tries to own one port. Returns 'listening', 'ours' (a real second instance,
 * so this process should stand down) or 'stranger' (someone else's server).
 */
function listenOn(client, port) {
  return new Promise((resolve) => {
    const server = buildServer(client, port);
    server.once('error', async () => {
      resolve((await isOurBridge(port)) ? 'ours' : 'stranger');
    });
    server.once('listening', () => resolve('listening'));
    server.listen(port, '127.0.0.1');
  });
}

/**
 * Walks the candidate ports. Returns the one we ended up on, or null when this
 * process should exit — with `reason` explaining which of the two cases it was.
 */
async function openBridge(client) {
  for (const port of BRIDGE_PORTS) {
    const outcome = await listenOn(client, port);
    if (outcome === 'listening') return { port };
    if (outcome === 'ours') return { reason: 'another instance is already running' };
    log(`port ${port} is taken by something that is not us, trying the next one`);
  }
  return { reason: `no free port in ${BRIDGE_PORTS.join(', ')}` };
}

/**
 * The bridge itself.
 *
 *   GET /ping                    identifies this service, used to resolve the port
 *   GET /state?x=&y=[&hwnd=]     which window sits at that screen point
 *   GET /focus?x=&y=[&hwnd=]     focus what is at that point (hover focus)
 *   GET /windows?process=        windows of a process, with their handles
 *   GET /focused-workspace       name of the workspace you are on
 *   GET /place?...               float one window into a fraction of a workspace
 *   GET /cmd?c=                  run a GlazeWM command verbatim
 *
 * `hwnd` is a hint, and an authoritative one: the caller already knows which
 * window Windows says is under the cursor, which settles the Z order that a
 * rectangle test cannot see.
 */
function buildServer(client, port) {
  return createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    res.setHeader('Content-Type', 'application/json');

    try {
      if (url.pathname === '/ping') {
        res.end(
          JSON.stringify({
            ok: true,
            service: SERVICE,
            port,
            pid: process.pid,
            // null until the probe at startup has answered. Clients that drive
            // hover focus watch this: false means GlazeWM will not focus a
            // window by id and the feature cannot work.
            focusById: client.focusById,
          }),
        );
        return;
      }
      if (url.pathname === '/state') {
        const x = Number(url.searchParams.get('x'));
        const y = Number(url.searchParams.get('y'));
        res.end(JSON.stringify(await client.windowAt(x, y, url.searchParams.get('hwnd'))));
        return;
      }
      if (url.pathname === '/focus') {
        const x = Number(url.searchParams.get('x'));
        const y = Number(url.searchParams.get('y'));
        res.end(JSON.stringify(await client.focusAt(x, y, url.searchParams.get('hwnd'))));
        return;
      }
      if (url.pathname === '/focused-workspace') {
        res.end(JSON.stringify(await client.focusedWorkspace()));
        return;
      }
      if (url.pathname === '/windows') {
        res.end(JSON.stringify(await client.windowsOf(url.searchParams.get('process'))));
        return;
      }
      if (url.pathname === '/place') {
        // The fractions are handed over as they arrived, strings and all:
        // telling "absent" from "zero" is the caller's protection against
        // asking for a window of no width, and Number() erases the difference.
        const raw = (key) => url.searchParams.get(key);
        res.end(
          JSON.stringify(
            await client.placeWindow({
              handle: raw('handle'),
              workspace: raw('ws'),
              fx: raw('fx'),
              fy: raw('fy'),
              fWidth: raw('fw'),
              fHeight: raw('fh'),
              fit: raw('fit'),
            }),
          ),
        );
        return;
      }
      if (url.pathname === '/cmd') {
        const command = url.searchParams.get('c') ?? '';
        await client.send(`command ${command}`);
        res.end('{"ok":true}');
        return;
      }
      res.statusCode = 404;
      res.end('{"error":"unknown route"}');
    } catch (err) {
      res.statusCode = 500;
      res.end(JSON.stringify({ error: String(err) }));
    }
  });
}

class GlazeClient {
  #ws = null;
  #pending = []; // FIFO: GlazeWM answers in the order it was asked.
  #onEvent = null;
  #backoff = 1000;
  #failures = 0;
  #known = new Set(); // window ids already looked at, for popup detection
  #seeded = false; // has #known been filled with what was already open?
  #focusFailures = 0; // consecutive failures of `focus` by id

  // null while unknown, then whether `focus --container-id <id>` works on this
  // build of GlazeWM — it arrived in 3.9.0. Hover focus is built on it, so it is
  // probed rather than assumed: if the command is not there the answer has to be
  // a clear line in the log, not a pointer that quietly focuses nothing.
  focusById = null;

  constructor(onEvent) {
    this.#onEvent = onEvent;
  }

  /** Is the IPC actually up? A closed socket answers null to everything. */
  get connected() {
    return this.#ws?.readyState === WebSocket.OPEN;
  }

  connect() {
    const ws = new WebSocket(IPC_URL);
    this.#ws = ws;

    ws.onopen = async () => {
      this.#backoff = 1000;
      this.#failures = 0;
      this.#focusFailures = 0;
      // Asked again on every connection. The GlazeWM on the other end may be a
      // different build from the one that answered last time, and the failures
      // that latched this belonged to a socket that is gone.
      this.focusById = null;
      log(`connected to ${IPC_URL}`);
      const res = await this.send(`sub --events ${EVENTS.join(' ')}`);
      log(`subscribed to [${EVENTS.join(', ')}] id=${res?.subscriptionId}`);

      // Whatever is open right now is what the desktop looked like before this
      // process started. Record it, so a restart does not go and float every
      // dialog that has been sitting there since the morning.
      //
      // First of everything after the subscription, and guarded by a flag on
      // top of that: an event arriving while this is still in flight would
      // otherwise find an empty set and treat the whole desktop as new.
      await this.watchNewWindows({ seedOnly: true });
      await this.probeFocusById();
      await this.apply('startup');
    };

    ws.onmessage = (ev) => {
      let msg;
      try {
        msg = JSON.parse(ev.data);
      } catch {
        return;
      }

      if (msg.messageType === 'client_response') {
        const resolve = this.#pending.shift();
        // A command that worked answers with no data at all, so `data` alone
        // cannot be the success flag: `?? {}` keeps "it worked, there is
        // nothing to say" distinguishable from "it failed", which is what the
        // focus-by-id probe reads.
        if (resolve) resolve(msg.success ? (msg.data ?? {}) : null);
        if (!msg.success && msg.error) log(`error response: ${msg.error}`);
        return;
      }

      if (msg.messageType === 'event_subscription') {
        this.#onEvent(msg.data?.eventType);
      }
    };

    ws.onclose = () => {
      // In-flight requests would hang forever otherwise.
      for (const resolve of this.#pending.splice(0)) resolve(null);

      // If GlazeWM is gone for good there is no point retrying forever: exit
      // and let the WM's own startup_commands bring us back next time.
      if (++this.#failures > MAX_RETRIES) {
        log(`no connection after ${MAX_RETRIES} attempts, exiting`);
        process.exit(0);
      }

      log(`connection closed, retrying in ${this.#backoff}ms`);
      setTimeout(() => this.connect(), this.#backoff);
      this.#backoff = Math.min(this.#backoff * 2, 30_000);
    };

    // `onerror` is always followed by `onclose`, which already schedules the
    // retry. Swallowed here so it does not escalate to an uncaught exception.
    ws.onerror = () => {};
  }

  send(message) {
    if (this.#ws?.readyState !== WebSocket.OPEN) return Promise.resolve(null);
    return new Promise((resolve) => {
      this.#pending.push(resolve);
      this.#ws.send(message);
    });
  }

  /**
   * Sets the tiling direction of the focused window's container so the next
   * window splits the space along its longer side. This is the whole BSP trick.
   */
  async apply(reason) {
    const focused = (await this.send('query focused'))?.focused;
    if (focused?.type !== 'window') return;

    // Floating, minimized and fullscreen windows are not part of the tree.
    if (focused.state?.type !== 'tiling') return;

    const wanted = focused.width > focused.height ? 'horizontal' : 'vertical';
    const current = (await this.send('query tiling-direction'))?.tilingDirection;
    if (current === wanted) return;

    await this.send(`command set-tiling-direction ${wanted}`);
    log(
      `${reason}: "${focused.title?.slice(0, 40)}" ${focused.width}x${focused.height}` +
        ` — ${current} -> ${wanted}`,
    );
  }

  /**
   * Finds out whether this GlazeWM will focus a window by id.
   *
   * `focus --container-id <id>` is the whole basis of hover focus, and it is
   * not a command this repository can guarantee: it belongs to GlazeWM, and it
   * only exists from **3.9.0** onwards. Re-focusing the window that already has
   * focus is a no-op with a useful answer, so that is the probe.
   *
   * Note that the container id goes in the command's own argument and NOT in
   * the `--id` subject prefix the other commands here use. `focus` is the one
   * command that ignores the subject: it reads the subject only for
   * `--direction`, and its argument group is mandatory, so a bare
   * `command --id <id> focus` does not even parse.
   */
  async probeFocusById() {
    if (this.focusById !== null) return; // already answered
    const focused = (await this.send('query focused'))?.focused;
    // Nothing focused yet — the usual case at startup, since the daemon is
    // launched by the WM before there is anything to focus. The event loop
    // calls this again on the first focus change, so the answer does arrive.
    if (focused?.type !== 'window') return;
    this.focusById = (await this.send(`command focus --container-id ${focused.id}`)) !== null;
    if (!this.focusById) {
      log(
        'this GlazeWM will not focus a window by id (needs 3.9.0 or newer):' +
          ' the mouse script falls back to activating windows natively, or set' +
          ' focus_follows_cursor: true in config.yaml for the built-in one',
      );
    }
  }

  /**
   * Looks at every window that has appeared since the last check and floats the
   * ones that are popups.
   *
   * Diffing the window list rather than reading the event payload is deliberate:
   * events are coalesced and can be dropped, but a window that exists now and
   * did not exist a moment ago is a fact that survives both.
   */
  async watchNewWindows({ seedOnly = false } = {}) {
    if (!POPUPS.enabled || !HELPER_AVAILABLE) return;
    // Nothing is new until it is known what was old.
    if (!seedOnly && !this.#seeded) return;

    const windows = (await this.send('query windows'))?.windows ?? [];
    const fresh = windows.filter((w) => !this.#known.has(w.id));
    // Rebuilt rather than added to, so closed windows drop out of the set.
    this.#known = new Set(windows.map((w) => w.id));
    if (seedOnly) {
      this.#seeded = true;
      return;
    }

    for (const window of fresh) await this.floatIfPopup(window);
  }

  /** Floats one window if `wm-helpers inspect` says it is a popup. */
  async floatIfPopup(window) {
    // Anything GlazeWM has already decided not to tile needs no rescuing.
    if (window.state?.type !== 'tiling') return;

    const facts = await helper('inspect', String(window.handle));
    const verdict = popupVerdict(facts);
    if (!verdict.float) return;

    // Inspecting means waiting for a subprocess, which is long enough for
    // somebody else to have taken charge of this window: a script placing it
    // through /place, or Alt+F. Centring it now would throw that away, so the
    // state is read again and a window that has stopped being tiled is left
    // where it was put.
    const current = ((await this.send('query windows'))?.windows ?? []).find(
      (w) => w.id === window.id,
    );
    if (current?.state?.type !== 'tiling') {
      log(`popup: "${(window.title ?? '').slice(0, 40)}" was handled while inspecting, left alone`);
      return;
    }

    // Centred with `position` and not with set-floating's own --centered, for
    // the same reason /place does its geometry separately: that flag is ignored
    // once the window has a custom floating placement, and `position` never is.
    await this.send(`command --id ${window.id} set-floating --shown-on-top=true`);
    await this.send(`command --id ${window.id} position --centered`);
    log(
      `popup: floated "${(window.title ?? '').slice(0, 40)}" (${window.processName || '?'})` +
        ` — ${verdict.reason}`,
    );
    await this.keepInsideWorkspace(window.id);
  }

  /**
   * Slides a floating window back inside its workspace if it is hanging off it.
   *
   * Applications place their own dialogs, and they get it wrong often enough:
   * centred on a monitor that has since been unplugged, or on coordinates
   * remembered from a different resolution. A dialog whose buttons are past the
   * edge of the screen cannot be answered, and it is usually modal.
   */
  async keepInsideWorkspace(id) {
    const workspaces = (await this.send('query workspaces'))?.workspaces ?? [];
    const found = locate(workspaces, (node) => node.id === id);
    if (!found) return;

    const { window, workspace } = found;
    const at = fitInside(window, workspace);
    if (at.x === window.x && at.y === window.y) return;

    await this.send(`command --id ${id} position --x-pos ${at.x} --y-pos ${at.y}`);
    log(
      `fit: "${(window.title ?? '').slice(0, 40)}" ${window.x},${window.y} -> ${at.x},${at.y}` +
        ` inside workspace ${workspace.name}`,
    );
  }

  /**
   * Focuses whatever is at a screen point. This is hover focus, and it runs on
   * every pass of the cursor from one window to another.
   *
   * The empty-space case is not a fallback, it is half the feature: with
   * nothing managed under the cursor the workspace it sits on is focused
   * instead, which is what makes a new window open on the monitor the mouse is
   * on. It is skipped when that workspace already has focus, so resting the
   * pointer on a bar or on an ignored overlay does not keep issuing commands.
   */
  async focusAt(x, y, handleHint) {
    // A closed socket answers null to everything, and that is not GlazeWM
    // saying no. Say "ask again" rather than counting it as a refusal.
    if (!this.connected) return { ok: false, retry: true };

    const hit = await this.windowAt(x, y, handleHint);
    if (hit.found) {
      // Only focusing a *window* needs 3.9.0. Focusing the workspace under the
      // pointer, below, is an old command and keeps working without it — so the
      // check belongs here and not at the top, or an older GlazeWM would lose
      // monitor-follows-mouse as well.
      if (this.focusById === false) return { ok: false, supported: false };

      const focused = (await this.send('query focused'))?.focused;
      if (focused?.id === hit.id) return { ok: true, focused: 'unchanged' };

      const done = await this.send(`command focus --container-id ${hit.id}`);
      if (done === null) {
        // The likeliest reason by far is that the window closed during the two
        // round trips it took to get here. Only a run of failures with nothing
        // working in between says the command itself is missing.
        if (++this.#focusFailures < FOCUS_FAILURES) return { ok: false, retry: true };
        this.focusById = false;
        log(
          `focusing a window by id failed ${FOCUS_FAILURES} times in a row:` +
            ' treating it as unsupported, see the note about GlazeWM 3.9.0',
        );
        return { ok: false, supported: false };
      }
      this.#focusFailures = 0;
      this.focusById = true;
      return { ok: true, focused: 'window', id: hit.id };
    }

    const workspaces = (await this.send('query workspaces'))?.workspaces ?? [];
    const under = workspaces.find((w) => w.isDisplayed && contains(w, x, y));
    if (!under || under.hasFocus) return { ok: true, focused: 'none' };

    await this.send(`command focus --workspace ${under.name}`);
    return { ok: true, focused: 'workspace', workspace: under.name };
  }

  /**
   * Stops the taskbar from surfacing over a fullscreen game.
   *
   * Symptom: game running fullscreen, you switch workspace, come back, push the
   * mouse to the bottom edge and the auto-hidden taskbar slides up over it. The
   * manual workaround was killing and restarting explorer.exe.
   *
   * What was measured on a real desktop:
   *   - MarkFullscreenWindow (ITaskbarList2) from another process does NOT fix
   *     it, neither setting it nor clearing and setting it again.
   *   - SetForegroundWindow does not either, nor SetWindowPos with
   *     SWP_FRAMECHANGED over the same rectangle.
   *   - Moving the window 1px and putting it back DOES fix it.
   *   - Growing it by 1px and shrinking it back does NOT: the window never
   *     stops covering the monitor, so the shell sees no edge.
   *
   * So the shell tracks this on an edge, not a level: it learns a window is
   * fullscreen when it sees a position change that ends up covering the whole
   * monitor. The nudge manufactures that edge.
   *
   * See docs/FULLSCREEN-GAMES.md.
   */
  async fixTaskbar() {
    const candidate = await helper('fix-fullscreen', '--dry');
    if (!candidate?.found) return;

    // If GlazeWM has it tiled, the geometry belongs to the WM: moving it behind
    // its back looks like a user drag. That case does not show the bug anyway.
    const windows = (await this.send('query windows'))?.windows ?? [];
    const managed = windows.find((w) => String(w.handle) === String(candidate.hwnd));
    if (managed?.state?.type === 'tiling') return;

    await helper('nudge', String(candidate.hwnd));
    log(
      `taskbar: nudged ${candidate.process || '?'} (hwnd ${candidate.hwnd})` +
        `${managed ? ` state=${managed.state?.type}` : ' unmanaged'}`,
    );
  }

  /** Name of the focused workspace. */
  async focusedWorkspace() {
    const workspaces = (await this.send('query workspaces'))?.workspaces ?? [];
    const active = workspaces.find((w) => w.hasFocus) ?? workspaces.find((w) => w.isDisplayed);
    return { name: active?.name ?? null };
  }

  /** Windows of a process, so a launcher can tell which ones already existed. */
  async windowsOf(process) {
    const windows = (await this.send('query windows'))?.windows ?? [];
    return windows
      .filter((w) => !process || w.processName === process)
      .map((w) => ({ id: w.id, handle: w.handle, title: w.title }));
  }

  /**
   * Floats one window into a fraction of a workspace. Coordinates are given as
   * fractions (0..1) of the workspace, so the same call works on any monitor.
   *
   *   fit=stretch  the window fills its rectangle
   *   fit=center   the window keeps its own size and is centered in it
   *
   * `ws` is optional: without it the window is placed on the workspace it is
   * already on. With it, the window is *moved* there first — placing a window
   * with the coordinates of a workspace it does not live on was the reliable
   * way to lose one, because the numbers were right for the target monitor and
   * the window stayed on the other.
   *
   * Windows are addressed by their Win32 handle rather than by title on
   * purpose: Windows Terminal does not propagate the tab title to the window
   * title, so several terminals are all called "Terminal" and cannot be told
   * apart by name. Whatever launched them does know which one it just created.
   */
  async placeWindow({ handle, workspace, fx, fy, fWidth, fHeight, fit }) {
    if (!handle) return { ok: false, error: 'no handle given' };

    const fractions = readFractions({ fx, fy, fWidth, fHeight });
    if (fractions.error) return { ok: false, error: fractions.error };
    if (fractions.adjusted) {
      log(
        `place: fractions out of range, clamped to fx=${fractions.fx} fy=${fractions.fy}` +
          ` fw=${fractions.fWidth} fh=${fractions.fHeight}`,
      );
    }

    const allWorkspaces = async () => (await this.send('query workspaces'))?.workspaces ?? [];
    let workspaces = await allWorkspaces();
    const target = workspace ? workspaces.find((w) => w.name === workspace) : null;
    if (workspace && !target) {
      const names = workspaces.map((w) => w.name).join(', ');
      return { ok: false, error: `no such workspace: ${workspace} (active: ${names})` };
    }

    const find = async () =>
      ((await this.send('query windows'))?.windows ?? []).find(
        (w) => String(w.handle) === String(handle),
      );

    // The caller has usually just launched this window, so it may not be
    // managed yet when the request arrives. Waiting a couple of seconds beats
    // answering "no such window" to a window that shows up right afterwards.
    let window = await find();
    for (let tries = 0; !window && tries < PLACE_TRIES; tries++) {
      await sleep(PLACE_POLL_MS);
      window = await find();
    }
    if (!window) {
      const waited = PLACE_TRIES * PLACE_POLL_MS;
      return { ok: false, error: `no window with handle ${handle} after ${waited}ms` };
    }

    workspaces = await allWorkspaces();
    const here = locate(workspaces, (node) => String(node.handle) === String(handle))?.workspace;
    const destination = target ?? here;
    if (!destination) {
      return { ok: false, error: `cannot tell which workspace holds handle ${handle}` };
    }
    // `!here` rather than skipping: if the window could not be found in the
    // tree, a workspace was still asked for, and moving it there is the request.
    // Applying another monitor's coordinates to a window that never moved is
    // the failure this is here to prevent.
    if (target && (!here || target.name !== here.name)) {
      await this.send(`command --id ${window.id} move --workspace ${destination.name}`);
      window = (await find()) ?? window;
      log(`place: handle ${handle} moved from workspace ${here.name} to ${destination.name}`);
    }

    const cell = cellRect(destination, fractions);

    // `--centered=false` is mandatory: state_defaults.floating.centered is true
    // in the config, and that centering overrides --x-pos (the size was honored,
    // the position always ended up in the middle). The `=` is not optional
    // either: `--centered false` makes GlazeWM answer "unexpected argument
    // 'false' found" and run nothing at all.
    //
    // `--shown-on-top=true` because floating.shown_on_top is false in the
    // config: a placed window sharing a workspace with a fullscreen tiled one
    // ends up underneath it on the way back from another workspace, and looks
    // like it vanished.
    if (fit === 'center') {
      // Float it first, then query it again: size changes on the tiling ->
      // floating transition, and centering with the old numbers is off by the
      // difference.
      await this.send(
        `command --id ${window.id} set-floating --centered=false --shown-on-top=true`,
      );
      window = (await find()) ?? window;

      // Max(0) rather than a plain halving: a window larger than its cell would
      // otherwise be centred to a negative offset, which pushes it out of the
      // workspace on the way to being "centred".
      const box = {
        x: cell.x + Math.max(0, Math.round((cell.width - window.width) / 2)),
        y: cell.y + Math.max(0, Math.round((cell.height - window.height) / 2)),
        width: window.width,
        height: window.height,
      };
      const at = fitInside(box, destination);

      await this.send(`command --id ${window.id} position --x-pos ${at.x} --y-pos ${at.y}`);
      log(
        `place: handle ${handle} centered ${window.width}x${window.height} @${at.x},${at.y}` +
          ` on ${destination.name}`,
      );
      return {
        ok: true,
        // Keeping its own size is the point of fit=center, so the only way to
        // miss here is the window not fitting in the cell at all and having to
        // be slid to stay on the workspace.
        honored: at.x === box.x && at.y === box.y,
        workspace: destination.name,
        x: at.x,
        y: at.y,
        width: window.width,
        height: window.height,
      };
    }

    // Three commands rather than one, and the reason is a rule inside GlazeWM:
    // `set-floating` applies its own --x-pos/--width only while the window has
    // no custom floating placement, and it acquires one the first time anything
    // moves it — an earlier /place, a Win+drag, AltSnap. So a second placement
    // of the same window silently kept the first one's size, and the readback
    // below then blamed the application for refusing it.
    //
    // `size` and `position` carry no such condition. set-floating is left to do
    // the one thing only it can do, which is change the state.
    await this.send(
      `command --id ${window.id} set-floating --centered=false --shown-on-top=true`,
    );
    await this.send(`command --id ${window.id} size --width ${cell.width} --height ${cell.height}`);
    await this.send(`command --id ${window.id} position --x-pos ${cell.x} --y-pos ${cell.y}`);

    // Not every window can be given a size. One with a minimum larger than its
    // cell keeps its own, and what it does with the excess is hang off the
    // right and the bottom, over the neighbour or off the screen. So the result
    // is read back rather than assumed, and the window is slid to where it
    // still fits.
    const settled = (await find()) ?? window;
    const off = Math.abs(settled.x - cell.x) > 2 || Math.abs(settled.y - cell.y) > 2;
    const oversized = settled.width > cell.width + 2 || settled.height > cell.height + 2;
    if (off || oversized) {
      const at = fitInside({ ...cell, width: settled.width, height: settled.height }, destination);
      if (at.x !== settled.x || at.y !== settled.y) {
        await this.send(`command --id ${window.id} position --x-pos ${at.x} --y-pos ${at.y}`);
      }
      log(
        `place: handle ${handle} asked ${cell.width}x${cell.height} @${cell.x},${cell.y},` +
          ` got ${settled.width}x${settled.height} @${settled.x},${settled.y}` +
          ` — moved to ${at.x},${at.y}`,
      );
      return {
        ok: true,
        honored: false,
        workspace: destination.name,
        x: at.x,
        y: at.y,
        width: settled.width,
        height: settled.height,
      };
    }

    log(
      `place: handle ${handle} -> ${cell.width}x${cell.height} @${cell.x},${cell.y}` +
        ` on ${destination.name}`,
    );
    return { ok: true, honored: true, workspace: destination.name, ...cell };
  }

  /**
   * Hit test: which window occupies screen point (x, y). The mouse script uses
   * it to tell whether what is under the cursor is tiled — in which case the
   * drag has to go through the tree — or floating, where it can just be moved.
   *
   * A rectangle test cannot see the Z order, so two overlapping floating
   * windows are a coin flip and an always-on-top overlay is invisible to it.
   * When the caller can say which window Windows itself reports under the
   * cursor, that answer is taken as final — including its silences: a handle
   * that matches nothing managed means the thing under the cursor is a bar, a
   * tooltip or a window GlazeWM was told to ignore, and the honest answer is
   * "nothing", not the tile buried underneath.
   */
  async windowAt(x, y, handleHint) {
    const windows = ((await this.send('query windows'))?.windows ?? []).filter(
      (w) => w.displayState === 'shown',
    );

    let hit;
    if (handleHint) {
      hit = windows.find((w) => String(w.handle) === String(handleHint));
      if (!hit) return { found: false, unmanaged: true, hwnd: handleHint };
    } else {
      // No hint: guess the top of the stack. Floating windows are drawn above
      // tiled ones, and among equals the smaller window is the one sitting on
      // the other rather than the one underneath.
      const rank = (w) => (w.state?.type === 'floating' ? 0 : 1);
      hit = windows
        .filter((w) => contains(w, x, y))
        .sort((a, b) => rank(a) - rank(b) || a.width * a.height - b.width * b.height)[0];
    }

    if (!hit) return { found: false };
    return {
      found: true,
      id: hit.id,
      tiling: hit.state?.type === 'tiling',
      x: hit.x,
      y: hit.y,
      width: hit.width,
      height: hit.height,
      handle: hit.handle,
    };
  }

  /**
   * When a window closes, its sibling absorbs the space and the container can
   * be left with a direction that no longer suits its shape — two windows
   * stacked vertically inside a wide, short gap, say. Walk the tree and turn
   * the mismatched containers, which is what komorebi does when it rebuilds the
   * BSP. No window changes place: only the container direction flips.
   *
   * One change per pass, re-querying in between: changing a container recomputes
   * the geometry of everything below it, so its children have to be judged on
   * the new numbers rather than the stale ones.
   */
  async rebalance() {
    for (let pass = 0; pass < MAX_PASSES; pass++) {
      const workspaces = (await this.send('query workspaces'))?.workspaces;
      if (!workspaces) return;

      let target = null;
      const visit = (node) => {
        if (target) return;
        const isContainer = node.type === 'workspace' || node.type === 'split';
        if (isContainer && (node.children?.length ?? 0) > 1) {
          const wanted = node.width > node.height ? 'horizontal' : 'vertical';
          if (node.tilingDirection !== wanted) {
            target = { id: node.id, type: node.type, wanted, current: node.tilingDirection };
            return;
          }
        }
        for (const child of node.children ?? []) visit(child);
      };
      workspaces.forEach(visit);

      if (!target) return;
      await this.send(`command --id ${target.id} set-tiling-direction ${target.wanted}`);
      log(`rebalance: ${target.type} ${target.current} -> ${target.wanted}`);
    }
  }
}

// Events arrive in bursts: opening a window fires window_managed and
// focus_changed almost together. They are coalesced into a single command, but
// the types seen are ACCUMULATED. Keeping only the last one meant focus_changed
// clobbered the window_managed it came with, and window openings were never
// processed at all.
let timer = null;
const pending = new Set();

// One burst at a time, whatever the timer does. The work inside is async and
// some of it is slow — `watchNewWindows` waits on the wm-helpers subprocess —
// so without this a burst arriving 50 ms later ran its `apply()` while the
// previous one was still deciding whether the new window is a dialog, and set
// the split axis from the shape of that dialog. Exactly what doing popups first
// is supposed to prevent, undone by two of these running at once.
let working = Promise.resolve();

async function handleBurst() {
  const types = new Set(pending);
  pending.clear();

  // Popups first: floating one takes it out of the tree, and the direction
  // and the rebalance should be decided on the tree that is left. Doing it
  // the other way round set the split axis from the shape of a dialog.
  if (types.has('window_managed')) await client.watchNewWindows();

  // The startup probe finds nothing to re-focus when the WM launches the
  // daemon before any window exists. This is where it gets its answer.
  if (client.focusById === null) await client.probeFocusById();

  // Closing a window leaves the tree out of shape; opening one only needs the
  // direction set before it arrives.
  if (types.has('window_unmanaged')) await client.rebalance();
  await client.apply([...types].join('+'));
  await watchWorkspaceChange();
}

const client = new GlazeClient((eventType) => {
  if (!EVENTS.includes(eventType)) return;
  pending.add(eventType);
  clearTimeout(timer);
  timer = setTimeout(() => {
    working = working.then(handleBurst).catch((err) => log(`event handling failed: ${err}`));
  }, 50);
});

// The taskbar fix triggers on a workspace change. Listening to
// `workspace_activated` is not enough: GlazeWM emits it for the workspace
// lifecycle, not every time you jump to one that is already active. So the name
// is compared instead.
let previousWorkspace = null;
let fixingTaskbar = false;

async function watchWorkspaceChange() {
  const current = (await client.focusedWorkspace())?.name;
  if (!current || current === previousWorkspace) return;

  const firstRead = previousWorkspace === null;
  previousWorkspace = current;
  if (firstRead || fixingTaskbar) return;

  fixingTaskbar = true;
  setTimeout(async () => {
    try {
      await client.fixTaskbar();
    } finally {
      fixingTaskbar = false;
    }
  }, SETTLE_MS);
}

const bridge = await openBridge(client);
if (!bridge.port) {
  log(`${bridge.reason}, exiting`);
  process.exit(0);
}

// Clients read this to find the bridge, since it does not always land on the
// first port. They fall back to probing the candidates if the file is stale.
try {
  writeFileSync(PORT_FILE, String(bridge.port));
  process.on('exit', () => {
    try {
      rmSync(PORT_FILE, { force: true });
    } catch {
      // Best effort: a stale file is survivable, clients re-probe.
    }
  });
} catch {
  log(`could not write ${PORT_FILE}, clients will have to probe for the port`);
}

log('--- autotiling started ---');
log(`HTTP bridge listening on 127.0.0.1:${bridge.port}`);
if (HELPER_AVAILABLE) {
  log('wm-helpers found: fullscreen-game taskbar fix and popup floating active');
} else {
  log(`missing ${HELPER}: taskbar fix and popup floating disabled (build wm-helpers/)`);
}
client.connect();
