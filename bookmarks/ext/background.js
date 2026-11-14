// bsession background: bridges the native host (bsession host --browser X)
// and the browser's windows/tabs API. Runs as an event page in Firefox and
// a service worker in Chromium; both paths are covered by the same code.
//
// Wire protocol (both directions, one JSON object per native message):
//   request:  { id, op, ...params }
//   reply:    { re: id, ok: true, result } | { re: id, ok: false, error }
//
// Ops served here (host -> ext): ping, list, open, focus, close.
// Ops asked of the host (ext -> host): bookmarks, save.

const IS_FF = typeof browser !== "undefined" && typeof browser.runtime?.getBrowserInfo === "function";
const api = IS_FF ? browser : chrome;
const HOST = "bsession";
const SENTINEL = api.runtime.getURL("project.html");
const GROUP_COLORS = new Set(["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]);

let port = null;
let nextId = 1;
const pending = new Map();

function connect() {
  if (port) return;
  try {
    port = api.runtime.connectNative(HOST);
  } catch (e) {
    console.warn("bsession: connectNative failed", e);
    port = null;
    return;
  }
  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    const err = api.runtime.lastError?.message;
    if (err) console.warn("bsession: host disconnected:", err);
    port = null;
    for (const p of pending.values()) p.reject(new Error("host disconnected"));
    pending.clear();
  });
}

function onHostMessage(msg) {
  if (msg.re !== undefined) {
    const p = pending.get(msg.re);
    if (!p) return;
    pending.delete(msg.re);
    msg.ok ? p.resolve(msg.result) : p.reject(new Error(msg.error));
    return;
  }
  handle(msg).then(
    (result) => port?.postMessage({ re: msg.id, ok: true, result }),
    (e) => port?.postMessage({ re: msg.id, ok: false, error: String(e?.message ?? e) }),
  );
}

// ext -> host request
function ask(op, params = {}) {
  if (!port) connect();
  if (!port) return Promise.reject(new Error("bsession host not connected"));
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    port.postMessage({ id, op, ...params });
  });
}

async function handle(msg) {
  switch (msg.op) {
    case "ping":
      return "pong";
    case "list":
      return listWindows();
    case "open":
      return openProject(msg);
    case "focus":
      return focusWindow(msg.windowId);
    case "close":
      return closeWindow(msg.windowId);
    default:
      throw new Error(`unknown op ${msg.op}`);
  }
}

// A minimized window ignores `focused: true` under Wayland; restore it first.
async function focusWindow(windowId) {
  const w = await api.windows.get(windowId);
  if (w.state === "minimized") await api.windows.update(windowId, { state: "normal" });
  await api.windows.update(windowId, { focused: true });
  touch(windowId);
  return opened(windowId);
}

// `windows.remove` resolves even when a page's beforeunload prompt keeps the
// window alive; report that instead of a false "closed".
async function closeWindow(windowId) {
  await api.windows.remove(windowId);
  for (let i = 0; i < 6; i++) {
    await new Promise((r) => setTimeout(r, 250));
    try {
      await api.windows.get(windowId);
    } catch (e) {
      return null; // gone
    }
  }
  throw new Error("window is still open (a page is asking to confirm leaving, or the browser refused)");
}

// ---- window snapshot ------------------------------------------------------

// Chromium reports `url: ""` until a navigation commits; the target is in
// `pendingUrl`. Treat both as the tab's URL everywhere.
const urlOf = (t) => t.url || t.pendingUrl || "";

function projectOf(tabs) {
  for (const t of tabs) {
    const u = urlOf(t);
    if (t.pinned && u.startsWith(SENTINEL)) {
      const q = new URL(u).searchParams;
      const ctx = q.get("ctx"), proj = q.get("proj");
      if (ctx && proj) return { ctx, proj, tabId: t.id };
    }
  }
  return null;
}

async function findProjectWindow(ctx, proj) {
  for (const w of await api.windows.getAll({ populate: true, windowTypes: ["normal"] })) {
    const p = projectOf(w.tabs);
    if (p && p.ctx === ctx && p.proj === proj) return w;
  }
  return null;
}

async function snapshotWindow(w) {
  const project = projectOf(w.tabs);
  const byId = new Map();
  if (api.tabGroups) {
    for (const g of await api.tabGroups.query({ windowId: w.id })) {
      byId.set(g.id, { title: g.title ?? "", color: g.color, collapsed: !!g.collapsed });
    }
  }
  // Groups are emitted in order of first appearance; tabs reference them by index.
  const groups = [];
  const index = new Map();
  const tabs = [];
  for (const t of w.tabs) {
    if (t.id === project?.tabId) continue;
    let group = null;
    if (typeof t.groupId === "number" && t.groupId >= 0 && byId.has(t.groupId)) {
      if (!index.has(t.groupId)) {
        index.set(t.groupId, groups.length);
        groups.push(byId.get(t.groupId));
      }
      group = index.get(t.groupId);
    }
    tabs.push({ url: urlOf(t), title: t.title ?? "", pinned: !!t.pinned, active: !!t.active, group });
  }
  return {
    windowId: w.id,
    focused: !!w.focused,
    lastFocused: w.id === lastFocused.windowId,
    lastFocusedAt: w.id === lastFocused.windowId ? lastFocused.at : 0,
    project: project ? { ctx: project.ctx, proj: project.proj } : null,
    tabs,
    groups,
  };
}

// A global keybind (kitty panel, notify-send…) steals focus before the CLI
// asks, so `focused` alone is useless for "the window I'm in". Remember the
// last window that had focus instead; the timestamp lets the CLI pick
// between browsers. onFocusChanged is the primary signal, but under Wayland
// it is not guaranteed to fire for windows we create or raise ourselves, so
// those paths call touch() directly and tab activation counts as presence.
let lastFocused = { windowId: null, at: 0 };
function touch(windowId) {
  lastFocused = { windowId, at: Date.now() };
}
api.windows.onFocusChanged.addListener((id) => {
  if (id !== api.windows.WINDOW_ID_NONE) touch(id);
});
// Tab switches only count in the window that has focus: a tab closing itself
// in a background window also activates a neighbour there.
api.tabs.onActivated.addListener(async ({ windowId }) => {
  try {
    if ((await api.windows.get(windowId)).focused) touch(windowId);
  } catch (e) { /* window already gone */ }
});
// A closed window must not stay "last focused": fall back to whatever has
// focus now, else to the browser's own notion on the next list.
api.windows.onRemoved.addListener(async (id) => {
  if (lastFocused.windowId !== id) return;
  lastFocused = { windowId: null, at: 0 };
  try {
    const w = await api.windows.getLastFocused();
    if (w && w.id !== id && w.focused) touch(w.id);
  } catch (e) { /* no windows left */ }
});

async function listWindows() {
  if (lastFocused.windowId === null) {
    try {
      const w = await api.windows.getLastFocused();
      if (w) lastFocused = { windowId: w.id, at: 0 };
    } catch (e) { /* no windows */ }
  }
  const wins = await api.windows.getAll({ populate: true, windowTypes: ["normal"] });
  return Promise.all(wins.map(snapshotWindow));
}

// ---- open -----------------------------------------------------------------

// Serialised: two `open`s for the same project racing (double-tapped key)
// must not build two windows; an existing window is focused instead.
let opening = Promise.resolve();

function openProject(params) {
  const run = opening.then(() => openProjectNow(params));
  opening = run.catch(() => {});
  return run;
}

async function openProjectNow({ ctx, proj, tabs = [], groups = [] }) {
  const existing = await findProjectWindow(ctx, proj);
  if (existing) return focusWindow(existing.id);

  const sentinel = `${SENTINEL}?ctx=${encodeURIComponent(ctx)}&proj=${encodeURIComponent(proj)}`;
  const win = await api.windows.create({ url: sentinel, focused: true });
  touch(win.id);
  const sentinelTab = win.tabs?.[0] ?? (await api.tabs.query({ windowId: win.id }))[0];
  await api.tabs.update(sentinelTab.id, { pinned: true });

  let activeIdx = tabs.findIndex((t) => t.active);
  if (activeIdx < 0 && tabs.length) activeIdx = 0;
  // One URL the browser refuses (Firefox: file:, data:, privileged about:)
  // must not abort the rest of the window; it is reported instead.
  const created = [];
  const failed = [];
  for (let i = 0; i < tabs.length; i++) {
    const t = tabs[i];
    const props = { windowId: win.id, url: t.url, pinned: !!t.pinned, active: false };
    // Firefox can create lazy tabs: no network until the user clicks them.
    if (IS_FF && i !== activeIdx) {
      props.discarded = true;
      if (t.title) props.title = t.title;
    }
    try {
      created.push(await api.tabs.create(props));
    } catch (e) {
      created.push(null);
      failed.push(`${t.url}: ${e?.message ?? e}`);
    }
  }

  if (api.tabs.group && api.tabGroups && groups.length) {
    for (let gi = 0; gi < groups.length; gi++) {
      const tabIds = created.filter((c, i) => c && tabs[i].group === gi).map((t) => t.id);
      if (!tabIds.length) continue;
      try {
        const gid = await api.tabs.group({ tabIds, createProperties: { windowId: win.id } });
        const g = groups[gi];
        const upd = { title: g.title ?? "", collapsed: !!g.collapsed };
        if (GROUP_COLORS.has(g.color)) upd.color = g.color;
        await api.tabGroups.update(gid, upd);
      } catch (e) {
        console.warn("bsession: tab group restore failed", e);
      }
    }
  }

  const active = created[activeIdx] ?? created.find((c) => c);
  if (active) await api.tabs.update(active.id, { active: true });
  return { ...(await opened(win.id)), failed };
}

// Reply shape for open/focus: the compositor's window title starts with the
// active tab's title, which is how the CLI finds the toplevel to place.
async function opened(windowId) {
  const [t] = await api.tabs.query({ windowId, active: true });
  return { windowId, activeTitle: t?.title ?? "" };
}

// ---- project page (project.html) ------------------------------------------

api.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    switch (msg.op) {
      case "bookmarks":
        return ask("bookmarks", { ctx: msg.ctx, proj: msg.proj });
      case "save-window": {
        // Only the window's own pinned sentinel may save it: the same page
        // opened as a plain tab elsewhere would otherwise write that other
        // window into this project's file.
        const w = await api.windows.get(sender.tab.windowId, { populate: true });
        const project = projectOf(w.tabs);
        if (!project) throw new Error("window has no project sentinel tab");
        if (project.tabId !== sender.tab.id) throw new Error("this page is not the window's pinned project tab");
        const snap = await snapshotWindow(w);
        return ask("save", { project: snap.project, tabs: snap.tabs, groups: snap.groups });
      }
      case "connected":
        return !!port;
      default:
        throw new Error(`unknown op ${msg.op}`);
    }
  })().then(
    (result) => sendResponse({ ok: true, result }),
    (e) => sendResponse({ ok: false, error: String(e?.message ?? e) }),
  );
  return true;
});

// ---- lifecycle ------------------------------------------------------------

api.runtime.onStartup.addListener(connect);
api.runtime.onInstalled.addListener(connect);
api.alarms.onAlarm.addListener((a) => { if (a.name === "bsession-reconnect") connect(); });
api.alarms.create("bsession-reconnect", { periodInMinutes: 0.5 });
connect();
