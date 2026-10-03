// Pinned sentinel tab of a project window. Its URL (?ctx=&proj=) is what the
// background uses to identify the window; the page itself just lists the
// project's bookmarks and offers a save button.
const api = typeof browser !== "undefined" ? browser : chrome;
const q = new URL(location.href).searchParams;
const ctx = q.get("ctx") ?? "?", proj = q.get("proj") ?? "?";

document.title = `${ctx}/${proj}`;
document.getElementById("title").innerHTML = `${esc(ctx)} <small>/</small> ${esc(proj)}`;
const status = document.getElementById("status");
const list = document.getElementById("list");

function esc(s) { return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])); }

function send(msg) {
  return new Promise((resolve, reject) => {
    api.runtime.sendMessage(msg, (r) => {
      const err = api.runtime.lastError;
      if (err) return reject(new Error(err.message));
      if (!r) return reject(new Error("no reply from background"));
      r.ok ? resolve(r.result) : reject(new Error(r.error));
    });
  });
}

function note(text, isErr = false) {
  status.textContent = text;
  status.className = isErr ? "err" : "";
}

async function load() {
  try {
    const entries = await send({ op: "bookmarks", ctx, proj });
    list.replaceChildren(...entries.map(({ label, url }) => {
      const li = document.createElement("li");
      const a = document.createElement("a");
      a.href = url; a.textContent = label; a.target = "_blank"; a.rel = "noopener";
      const u = document.createElement("span");
      u.className = "url"; u.textContent = url;
      li.append(a, u);
      return li;
    }));
    note(entries.length ? "" : "no bookmarks in this project yet");
  } catch (e) {
    note(e.message, true);
  }
}

document.getElementById("save").addEventListener("click", async () => {
  note("saving…");
  try {
    const r = await send({ op: "save-window" });
    const extra = r.new?.length ? ` · ${r.new.length} url(s) not in bookmarks` : "";
    note(`saved ${r.tabs} tab(s) → ${r.path}${extra}`);
  } catch (e) {
    note(e.message, true);
  }
});

load();
