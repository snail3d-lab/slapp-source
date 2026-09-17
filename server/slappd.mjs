// slappd — the Slapp daemon.
// One POST creates a project: folder + xcodegen template + private GitHub repo
// + a long-running Pi session (local model). Voice in (mlx-whisper), SSE out.
// SECURITY: this daemon runs an autonomous coding agent with shell access.
// It trusts whoever can reach it. Keep it on localhost/your tailnet, and set
// SLAPP_TOKEN to require an X-Slapp-Token header on every request.
import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFile, spawn } from "node:child_process";
import { randomUUID, createSign, timingSafeEqual } from "node:crypto";
import { fileURLToPath } from "node:url";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";

// ── config ──────────────────────────────────────────────────────────────────
const PORT = Number(process.env.SLAPP_PORT || 8123);
const BASE_DIR = process.env.SLAPP_BASE_DIR ||
  path.join(os.homedir(), "Desktop", "custom stuff - do not delete");
const GITHUB_OWNER = process.env.SLAPP_GH_OWNER || "Snail3D";
const UDID = process.env.SLAPP_UDID || "C83F08A6-AB9C-402A-8B39-E7E85C237A0D";
const WATCH_UDID = process.env.SLAPP_WATCH_UDID || ""; // watch sim; auto-detected when empty
const MLX_WHISPER = process.env.SLAPP_WHISPER ||
  path.join(os.homedir(), "Library/Python/3.9/bin/mlx_whisper");
// Voice input filter (SnailFlow): whisper + smart-fix cleanup via snail-api.
// Falls back to local mlx-whisper when the fleet is unreachable.
const SNAIL_API = process.env.SLAPP_SNAIL_API || "http://127.0.0.1:8900";
const SNAIL_KEY = process.env.SLAPP_SNAIL_KEY || "";
const WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo";
const LOG_CAP = 500;
const HOST = process.env.SLAPP_HOST || "::"; // "::" = all interfaces (phone needs it); 127.0.0.1 = loopback only
const RUN_TIMEOUT = Number(process.env.SLAPP_RUN_TIMEOUT || 15 * 60_000); // hung xcodebuild/simctl can't wedge a session forever
const MAX_UPLOAD = Number(process.env.SLAPP_MAX_UPLOAD || 256 * 1024 * 1024);

const log = (...a) => console.log("[slappd]", ...a);

// ── helpers ─────────────────────────────────────────────────────────────────
const home = (p) => (p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p);

function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    execFile(cmd, args, { maxBuffer: 64 * 1024 * 1024, timeout: RUN_TIMEOUT, ...opts }, (err, stdout, stderr) => {
      resolve({ code: err ? (err.code ?? 1) : 0, stdout: stdout?.toString() ?? "", stderr: stderr?.toString() ?? "", err });
    });
  });
}

function slugify(name) {
  return String(name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || `app-${Date.now().toString(36)}`;
}

// quotes matter: this lands inside HTML attributes on the public share page
const esc = (s) => String(s).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");

// ── session registry ────────────────────────────────────────────────────────
const sessions = new Map(); // slug -> sess
const HERE = path.dirname(fileURLToPath(import.meta.url));
const STATE_FILE = path.join(HERE, "state.json");
const TOKEN = process.env.SLAPP_TOKEN || ""; // if set, required as X-Slapp-Token
const tokenOk = (s) => {
  if (!TOKEN) return true;
  const a = Buffer.from(String(s ?? "")), b = Buffer.from(TOKEN);
  return a.length === b.length && timingSafeEqual(a, b); // no string-compare timing leaks
};
const MAXSESS_FILE = path.join(HERE, "maxsessions.json");
const DEFAULT_MAX_SESSIONS = 4;
let maxSessions = (() => {
  try { return Math.min(12, Math.max(1, JSON.parse(fs.readFileSync(MAXSESS_FILE, "utf8")).n)); }
  catch { return DEFAULT_MAX_SESSIONS; }
})();
function persistMaxSessions() {
  fsp.writeFile(MAXSESS_FILE, JSON.stringify({ n: maxSessions }, null, 1)).catch(() => {});
}

// the cap counts agents MID-RUN — state "running", not merely an open space.
// the launcher is coordination, not a work slot: it counts, but is never refused.
function workingCount() {
  let n = 0;
  for (const [, sx] of sessions) if (sx.busy) n++;
  return n;
}

function makeSess(e) {
  const sess = {
    slug: e.slug, name: e.name, dir: e.dir, repo: e.repo ?? null,
    createdAt: e.createdAt ?? new Date().toISOString(),
    model: e.model ?? null, kind: e.kind ?? "ios", herdr: e.herdr ?? null,
    thinking: e.thinking === undefined ? undefined : e.thinking, launcher: e.launcher ?? undefined, bridgeToken: e.bridgeToken ?? undefined, self: e.self ?? false, selfSessionId: e.selfSessionId ?? undefined, live: e.live ?? undefined,
    ctxCount: e.ctxCount ?? 0,
    watchTasks: e.watchTasks ?? [],
    pi: null, busy: false, phase: "restoring",
    clients: new Set(), log: [], screenPath: path.join(e.dir, ".slapp", "screen.png"),
    panes: new Set(), toolStart: new Map(),
  };
  sessions.set(e.slug, sess);
  return sess;
}

function persistSessions() {
  const arr = [...sessions.values()].map(s =>
    ({ slug: s.slug, name: s.name, dir: s.dir, repo: s.repo, createdAt: s.createdAt, model: s.model ?? null, kind: s.kind ?? "ios", herdr: s.herdr ?? null,
       thinking: s.thinking === undefined ? undefined : s.thinking, launcher: s.launcher ?? undefined, bridgeToken: s.bridgeToken ?? undefined, self: s.self || undefined, selfSessionId: s.selfSessionId ?? undefined, live: s.live ?? undefined, babysit: s.babysitTimer ? { intervalMin: s.babysitMin ?? 5 } : undefined,
       ctxCount: s.ctxCount ?? 0,
       watchTasks: (s.watchTasks || []).length ? s.watchTasks.map(t => ({ ...t, endsAt: Math.min(t.endsAt, Date.now() + 24 * 3.6e6) })) : undefined }));
  // atomic: a crash mid-write used to lose the whole registry
  fsp.writeFile(STATE_FILE + ".tmp", JSON.stringify(arr, null, 1))
    .then(() => fsp.rename(STATE_FILE + ".tmp", STATE_FILE)).catch(() => {});
}

async function restoreSessions() {
  let arr = [];
  try { arr = JSON.parse(await fsp.readFile(STATE_FILE, "utf8")); } catch {}
  for (const e of arr) {
    if (sessions.has(e.slug)) continue;
    if (!fs.existsSync(e.dir)) {
      // the project folder was deleted by hand — the pencil must not ghost:
      // retire its bridge channel so it leaves every phone, and say so
      log(`${e.slug}: its folder (${e.dir}) is gone — retiring the pencil`);
      bridgeSync(e.slug, e.name, true).catch(() => {});
      continue;
    }
    const sess = makeSess(e);
    log(`restoring ${sess.slug} from ${sess.dir}`);
    rebuildTranscript(sess); // transcript always reflects the full event log
    // slapp itself pins to its own session id (--session-id), so restoring
    // it is safe now — it can never grab the human's desk conversations
    attachPi(sess, true).catch((err) => {
      sess.phase = "error";
      push(sess, { type: "error", text: "reattach failed: " + String(err?.message ?? err).slice(0, 200) });
    });
    if (sess.launcher) {
      const iv = e.babysit?.intervalMin ?? e.babysitMin; // state stores {babysit:{intervalMin}}
      if (iv) startBabysit(sess, iv);                                          // the eye reopens
      if ((sess.watchTasks || []).length) startWatchTimer(sess);               // the watch resumes
    }
  }
}

// every session gets a live space on the Mac: a herdr tab running the pane
// client — the SAME pi session the phone talks to, visible and typeable.
// Re-created whenever it's missing; old sessions included.
const herdrInflight = new Set(); // slug → dedupe concurrent connects
async function herdrTab(sess) {
  if (herdrInflight.has(sess.slug)) return;
  herdrInflight.add(sess.slug);
  try {
    // each session gets its OWN space — named after the session, not a
    // pile of tabs under the human's workspace
    const probe = await run("herdr", ["workspace", "list"]);
    if (probe.code) return;
    let wsId = "";
    let wsIsOurs = false;
    try {
      const j = JSON.parse(probe.stdout);
      const ws = j?.result?.workspaces ?? [];
      const label = sess.name.toLowerCase();
      const mine = ws.find(w => (w.label || "").toLowerCase() === label);
      if (mine) { wsId = mine.workspace_id; wsIsOurs = true; }
      else {
        const c = await run("herdr", ["workspace", "create", "--label", sess.name, "--cwd", sess.dir]);
        if (c.code) { log(`[tab ${sess.slug}] workspace create failed: ${c.stderr?.slice(0, 120)}`); return; }
        const cj = JSON.parse(c.stdout);
        wsId = cj?.result?.workspace?.workspace_id ?? cj?.result?.workspace_id;
        wsIsOurs = true;
        log(`[tab ${sess.slug}] workspace created: ${sess.name} → ${wsId}`);
      }
    } catch {}
    if (!wsId) return;
    // the space changed under us (first migration to per-session spaces):
    // retire the old tab wherever it lives
    if (sess.herdr && sess.herdr.ws !== wsId) {
      if (sess.herdr.tabId) run("herdr", ["tab", "close", sess.herdr.tabId]).catch(() => {});
      sess.herdr = null;
      persistSessions();
    }

    // still alive? if the tab was closed, open a fresh one. If the tab lives
    // but the client inside died (daemon restart), relight just the pane.
    if (sess.herdr?.tabId) {
      const alive = await run("herdr", ["tab", "get", sess.herdr.tabId]);
      if (alive.code === 0) {
        const pi = await run("herdr", ["pane", "process-info", "--pane", sess.herdr.paneId]);
        // pi is alive if any foreground process is the pi binary (argv0/name
        // "pi", or a node running the pi entrypoint)
        let hasPi = false;
        try {
          const info = JSON.parse(pi.stdout)?.result?.process_info ?? {};
          const procs = info.foreground_processes ?? [];
          hasPi = procs.some(x => x?.argv0 === "pi" || x?.name === "pi");
        } catch {}
        if (pi.code === 0 && hasPi) return; // healthy — the TUI lives
        await run("herdr", ["pane", "send-keys", sess.herdr.paneId, "C-c"]);
        run("herdr", ["pane", "run", sess.herdr.paneId, piTuiCommand(sess)]).catch(() => {});
        startTail(sess);
        log(`[tab ${sess.slug}] pane relit`);
        return;
      }
      sess.herdr = null;
    }
    await fsp.mkdir(path.join(sess.dir, ".slapp"), { recursive: true });
    await fsp.appendFile(path.join(sess.dir, ".slapp", "transcript.txt"), "").catch(() => {});
    const envArgs = ["--env", `SLAPP_PANE_PORT=${PANE_PORT}`];
    if (TOKEN) envArgs.push("--env", `SLAPP_PANE_TOKEN=${TOKEN}`);
    const t = await run("herdr", ["tab", "create", "--workspace", wsId, "--cwd", sess.dir,
      "--label", sess.name, "--no-focus", ...envArgs]);
    if (t.code) return;
    const j = JSON.parse(t.stdout);
    const tabId = j?.result?.tab?.tab_id, paneId = j?.result?.root_pane?.pane_id;
    if (!tabId || !paneId) return;
    sess.herdr = { tabId, paneId, ws: wsId };
    if (sess.asleep) {
      sess.asleep = false;
      bridgeSay(sess, "awake again — its space is open on the Mac.").catch(() => {});
    }
    persistSessions();
    // the REAL thing: the actual pi coding TUI — same one as the terminal
    // (fire-and-forget: pane run may follow the process — don't let it hang us)
    run("herdr", ["pane", "run", paneId, piTuiCommand(sess)]).catch(() => {});
    startTail(sess);
    log(`[tab ${sess.slug}] pane armed in ${wsId}`);
    push(sess, { type: "status", text: "live space open on your Mac — a real pi session, type there or talk on the phone" });
  } catch {}
  finally { herdrInflight.delete(sess.slug); }
}

function newSess(name, kind = "ios", slugOverride = null) {
  const slug = slugOverride ?? slugify(name);
  if (sessions.has(slug)) return null;
  const dir = path.join(BASE_DIR, name.replace(/[^\w .-]/g, "").trim() || slug);
  const sess = {
    slug, name, dir,
    repo: null, createdAt: new Date().toISOString(),
    model: null, kind: kind === "watch" ? "watch" : "ios", herdr: null,
    pi: null, busy: false, phase: "starting",
    clients: new Set(), log: [], screenPath: path.join(dir, ".slapp", "screen.png"),
    panes: new Set(), toolStart: new Map(), ctxCount: 0,
  };
  sessions.set(slug, sess);
  return sess;
}

// append + rotate by bytes tracked on the session — no statSync per write,
// and rotation no longer waits for a `done` event to notice the file is huge
function appendRotating(file, text, cap, sess, key) {
  try {
    if (sess[key] == null) { try { sess[key] = fs.statSync(file).size; } catch { sess[key] = 0; } }
    fs.appendFileSync(file, text);
    sess[key] += Buffer.byteLength(text);
    if (sess[key] > cap) { fs.renameSync(file, file + ".1"); sess[key] = 0; }
  } catch {}
}

function push(sess, ev) {
  ev.t = Date.now();
  // deltas/thinking are live-only: the backlog stays readable (user, tools,
  // replies, errors) instead of drowning in raw stream chunks
  if (ev.type !== "thinking" && ev.type !== "delta") {
    sess.log.push(ev);
    if (sess.log.length > LOG_CAP) sess.log.splice(0, sess.log.length - LOG_CAP);
  }
  // the nanny's ticker: runs that land or break get noted for the launcher
  if (!sess.launcher && (ev.type === "done" || ev.type === "error")) {
    fleetNote(sess.slug, `${sess.name} ${ev.type === "done" ? "finished its run" : "hit an error"} — ${String(ev.text ?? "").slice(0, 70)}`);
  }
  if (ev.type === "done" && ev.text && sess.bridgeCtx) {
    bridgeSay(sess, ev.text).catch(() => {});
    const media = mediaIn(ev.text, sess);
    if (media.photo || media.audio) {
      const extra = {};
      if (media.photo) extra.photo = media.photo;
      if (media.audio) extra.audio = media.audio;
      setTimeout(() => bridgeSay(sess, "", extra).catch(() => {}), 400);
    }
  }
  const line = `data: ${JSON.stringify(ev)}\n\n`;
  for (const c of sess.clients) c.res.write(line);
  for (const p of sess.panes) { try { p.write(JSON.stringify(ev) + "\n"); } catch {} } // herdr door
  // the on-disk live log — machine-readable, rotated when huge
  appendRotating(path.join(sess.dir, ".slapp", "events.jsonl"), JSON.stringify(ev) + "\n", 8e6, sess, "eventBytes");
  if (ev.type === "status" || ev.type === "done" || ev.type === "error" || ev.type === "tool")
    log(`[${sess.slug}]`, ev.type, ev.text || ev.name || "");
  writeTranscript(sess, ev);
}

// ── the human transcript (what herdr shows) ────────────────────────────────
// Styled to read like a real pi session: dim prose, green $ tool blocks, no
// brackets, no timestamps. ANSI in the file; herdr's terminal does the rest.
const A = {
  dim: s => `\x1b[90m${s}\x1b[0m`,
  bold: s => `\x1b[1m${s}\x1b[0m`,
  lime: s => `\x1b[1;38;5;154m${s}\x1b[0m`,
  red: s => `\x1b[91m${s}\x1b[0m`,
  green: s => `\x1b[38;5;114m${s}\x1b[0m`,
  white: s => `\x1b[38;5;252m${s}\x1b[0m`,
};
// ── slapp bridge: every session wears a channel on the user's devices ──
// voice into a session = the bridge fires its transcript at this daemon's
// slapp door; replies flow back via /say so the tile's play-by-play fills.
const SLAPP_BRIDGE = process.env.SLAPP_BRIDGE || "http://127.0.0.1:8651";
let bridgeAuthCache = null;
async function bridgeAuth() {
  if (bridgeAuthCache !== null) return bridgeAuthCache;
  try {
    const cfg = JSON.parse(await fsp.readFile(path.join(os.homedir(), ".config/slapp/config.json"), "utf8").catch(async () =>
      fsp.readFile(path.join(os.homedir(), ".config/monocle/config.json"), "utf8")));
    bridgeAuthCache = cfg.auth_token || "";
  } catch { bridgeAuthCache = ""; }
  return bridgeAuthCache;
}
async function bridgeSync(slug, name, remove = false) {
  const token = await bridgeAuth();
  if (!token) return;
  const sess = sessions.get(slug);
  if (!remove && sess && !sess.bridgeToken) sess.bridgeToken = randomUUID().replace(/-/g, "");
  if (sess) persistSessions();
  try {
    await fetch(`${SLAPP_BRIDGE}/channels/sync`, { method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ name, webhook: `http://127.0.0.1:8123/api/session/${slug}/slapp`,
                             webhook_token: sess?.bridgeToken ?? "", remove }) });
  } catch { /* bridge asleep — next boot retries */ }
}
// the LIVE wire: the desk session's own extension broadcasts thinking +
// tools on its /traffic SSE as they happen — forward them into the
// session's events so the phone watches the mind work in real time
function startLiveTraffic(sess) {
  stopLiveTraffic(sess);
  if (!sess.live?.port) return;
  let buf = "";
  let dead = false;
  const req = http.get({ host: "127.0.0.1", port: sess.live.port, path: "/traffic" }, (res) => {
    res.setEncoding("utf8");
    res.on("data", (c) => {
      buf += c;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
        if (!line.startsWith("data:")) continue;
        try {
          const ev = JSON.parse(line.slice(5).trim());
          if (ev.type === "tool") push(sess, { type: "tool", name: ev.name || "tool", preview: ev.preview, phase: ev.phase, ok: ev.ok });
          else if (ev.type === "thinking") { const d = String(ev.text || "").trim(); if (d) push(sess, { type: "thinking", text: d.slice(-300) }); }
          else if (ev.type === "status") { sess.busy = true; }   // the run started — no line needed
        } catch {}
      }
    });
    res.on("end", () => { if (!dead) { dead = true; stopLiveTraffic(sess); setTimeout(() => { if (sess.live?.port && sessions.has(sess.slug)) startLiveTraffic(sess); }, 3000); } });
  });
  req.on("error", () => { if (!dead) { dead = true; setTimeout(() => { if (sess.live?.port && sessions.has(sess.slug)) startLiveTraffic(sess); }, 3000); } });
  sess.trafficReq = req;
}

function stopLiveTraffic(sess) {
  if (sess.trafficReq) { try { sess.trafficReq.destroy(); } catch {} sess.trafficReq = null; }
}

async function relayLive(sess, payload) {
  if (!sess.live?.port) return false;
  try {
    const r = await fetch(`http://127.0.0.1:${sess.live.port}/slapp`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...(sess.live.token ? { "x-monocle-token": sess.live.token } : {}) },
      body: JSON.stringify(payload),
    });
    if (r.ok) return true;
    log(`${sess.slug}: live relay → HTTP ${r.status}`);
    return false;
  } catch (e) {
    // the desk session is gone — the pencil sleeps, the fleet is told
    if (!sess.asleep) {
      sess.asleep = true; sess.phase = "idle"; persistSessions();
      fleetNote(sess.slug, `${sess.name}'s desk session closed — asleep on the pencil`);
      bridgeSay(sess, "your desk session just closed — this pencil sleeps. run /slapp in that session again to wake it.").catch(() => {});
    }
    return false;
  }
}

async function bridgeSay(sess, text, extra = null) {
  const ctx = sess.bridgeCtx;
  if (!ctx) return;
  const token = await bridgeAuth();
  if (!token) return;
  try {
    const body = { device: ctx.device, channel: ctx.channel, text: String(text).slice(0, 3500) };
    if (extra) Object.assign(body, extra);
    await fetch(`${SLAPP_BRIDGE}/say`, { method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify(body) });
  } catch { /* play-by-play stays one reply behind — harmless */ }
}

// media the agent made: files it saved under the project dir that the phone
// can show or play. returns {photo} / {audio} for the first hit of each.
function mediaIn(text, sess) {
  const out = {};
  const re = /\/[\w .()\/-]+\.(png|jpe?g|gif|webp|mp3|wav|ogg|m4a|flac|aac)/gi;
  for (const m of text.matchAll(re)) {
    const f = m[0];
    if (!fs.existsSync(f)) continue;
    if (f !== sess.dir && !f.startsWith(sess.dir + path.sep)) continue;
    if (/\.(png|jpe?g|gif|webp)$/i.test(f)) { if (!out.photo) out.photo = f; }
    else if (!out.audio) out.audio = f;
  }
  return out;
}

// ── the watch: per-thing nanny loops with a goal and a time budget ──
function startWatchTimer(launcher) {
  if (launcher.watchTimer) return;
  launcher.watchTimer = setInterval(() => watchTick(launcher).catch(e => log("watch tick: " + (e?.message ?? e))), 4 * 60 * 1000);
  setTimeout(() => watchTick(launcher).catch(() => {}), 6000);
}
async function watchTick(launcher) {
  const now = Date.now();
  const tasks = (launcher.watchTasks || []).filter(t => t.endsAt > now);
  const expired = (launcher.watchTasks || []).filter(t => t.endsAt <= now);
  for (const t of expired) push(launcher, { type: "status", text: `watch over — ${t.slug} (${t.hours}h budget spent)` });
  launcher.watchTasks = tasks;
  if (!tasks.length) { clearInterval(launcher.watchTimer); launcher.watchTimer = null; persistSessions(); return; }
  persistSessions();
  for (const t of tasks) {
    const target = sessions.get(t.slug);
    let state = "(session not found)";
    if (target) {
      const lines = target.log.slice(-2).map(e => `${e.type}: ${String(e.text ?? "").slice(0, 100)}`);
      state = `phase=${target.phase} busy=${target.busy ? "yes" : "no"}\n` + lines.join("\n");
    }
    const leftH = (Math.max(0, t.endsAt - now) / 3.6e6).toFixed(1);
    sendPrompt(launcher, `WATCH CHECK — session "${t.slug}", time left ${leftH}h.\nGOAL: ${t.goal}\nSTATE:\n${state}\n\nAssess against the goal. If the last turn finished, send the next step toward the goal (a prompt to that session). If it is stuck the same way twice, restart it once (POST /api/session/${t.slug}/restart). If the goal is truly met, reply exactly "WATCH DONE ${t.slug}" and nothing else. One line per action, plain words.`);
  }
}

function startBabysit(sess, intervalMin) {
  if (sess.babysitTimer) clearInterval(sess.babysitTimer);
  const tick = async () => {
    try {
      const lines = [];
      for (const [slug, s2] of sessions) {
        if (s2.launcher) continue;
        let lastEv = "";
        try { const evs = s2.log.slice(-1); if (evs[0]) lastEv = `${evs[0].type}: ${String(evs[0].text ?? "").slice(0, 90)}`; } catch {}
        lines.push(`- ${slug} · phase=${s2.phase} · busy=${s2.busy ? "yes" : "no"}${s2.building ? " · BUILDING" : ""} · ${lastEv}`);
      }
      // fresh fleet transitions since the last check — the nanny sees what
      // changed, not just the standing state
      const fresh = fleetNotes.filter(n => Date.now() - n.t < intervalMin * 60 * 1000);
      const noteLines = fresh.slice(0, 12).map(n => `- ${n.text}`);
      fleetNotes = fleetNotes.filter(n => Date.now() - n.t >= intervalMin * 60 * 1000);
      sendPrompt(sess, `BABYSIT CHECK — every session, its state:\n${lines.join("\n") || "(no other sessions)"}${noteLines.length ? `\n\njust happened:\n${noteLines.join("\n")}` : ""}\n\nKeep anything stalled going: restart stuck builds (POST /api/session/<slug>/restart), nudge idle-but-unfinished work with a prompt, leave healthy sessions alone. Words from the user's Action Button land here too — he may be on another app or away from the desk; answer like he's listening. Act only where needed; note what you did in one line each.`);
    } catch (e) { log("babysit tick failed: " + (e?.message ?? e)); }
  };
  sess.babysitTimer = setInterval(tick, intervalMin * 60 * 1000);
  sess.babysitMin = intervalMin;
  persistSessions();
  setTimeout(tick, 5000);
}

function transcriptLine(ev, toolStart) {
  if (ev.type === "user")
    return `\n${A.lime("❯ you")}\n${A.white(String(ev.text || "(a photo)").trim())}\n`;
  if (ev.type === "done" && ev.text)
    return `\n${A.dim("◆ slapp")}\n${A.dim(String(ev.text).replace(/\s*\n+\s*/g, " ").trim().slice(0, 2000))}\n`;
  if (ev.type === "tool" && ev.phase === "start") {
    if (ev.tid) toolStart.set(ev.tid, ev.t);
    return `  ${A.green("$")} ${A.bold(String(ev.preview || ev.name || "").trim().slice(0, 120))}`;
  }
  if (ev.type === "tool" && ev.phase === "end") {
    const t0 = ev.tid ? toolStart.get(ev.tid) : null;
    if (ev.tid) toolStart.delete(ev.tid);
    const dur = t0 ? ` · ${((ev.t - t0) / 1000).toFixed(1)}s` : "";
    return ev.ok === false
      ? `  ${A.red("✗ " + (ev.name || "tool") + " failed")}`
      : `  ${A.dim("✓ " + (dur ? dur.replace(" · ", "") : (ev.name || "tool")))}`;
  }
  if (ev.type === "error") return A.red("!! " + ev.text);
  if (ev.type === "status" && ev.text && ev.text !== "thinking" &&
      !String(ev.text).startsWith("screenshot failed")) return A.dim("· " + ev.text);
  return null;
}
function writeTranscript(sess, ev) {
  const s = transcriptLine(ev, sess.toolStart);
  if (!s) return;
  try {
    const tl = path.join(sess.dir, ".slapp", "transcript.txt");
    appendRotating(tl, s + "\n", 2e6, sess, "transcriptBytes");
  } catch {}
}
// regenerate the whole transcript from the event log — new format, full history
function rebuildTranscript(sess) {
  try {
    const el = path.join(sess.dir, ".slapp", "events.jsonl");
    const toolStart = new Map();
    const out = fs.readFileSync(el, "utf8").split("\n").filter(Boolean)
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(Boolean)
      .map(ev => transcriptLine(ev, toolStart))
      .filter(Boolean).join("\n") + "\n";
    fs.writeFileSync(path.join(sess.dir, ".slapp", "transcript.txt"), out);
  } catch {}
}

// ── project scaffold ───────────────────────────────────────────────────────
function templateFiles(name, slug, kind = "ios", watchUDID = "") {
  const bundle = `com.snail3d.${slug}`;
  if (kind === "watch") return watchTemplateFiles(name, slug, watchUDID);
  return {
    "project.yml": `name: ${name}
options:
  bundleIdPrefix: com.snail3d
  deploymentTarget: { iOS: "17.0" }
  createIntermediateGroups: true
settings: { base: { SWIFT_VERSION: "5.0" } }
targets:
  ${name}:
    type: application
    platform: iOS
    sources: [${name}]
    info:
      path: ${name}/Info.plist
      properties:
        CFBundleDisplayName: "${name}"
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: ${bundle}
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        DEVELOPMENT_TEAM: 9V8U7PCW58
        CODE_SIGN_STYLE: Automatic
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
`,
    ".gitignore": ".DS_Store\n*.xcodeproj\nDerivedData/\n.slapp/dd/\n",
    [`${name}/Info.plist`]: `{}`,
    [`${name}/App.swift`]: `import SwiftUI

@main
struct ${name.replace(/[^A-Za-z0-9]/g, "")}App: App {
    var body: some Scene {
        WindowGroup { Canvas() }
    }
}

// A blank canvas. Drag the word around. The builder agent will replace this.
struct Canvas: View {
    @State private var drag: CGSize = .zero
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.06).ignoresSafeArea()
            Text("${name.replace(/["\\]/g, "")}")
                .font(.system(size: 34, weight: .bold, design: .serif))
                .foregroundStyle(.white.opacity(0.9))
                .offset(drag)
                .gesture(DragGesture().onChanged { drag = $0.translation })
        }
    }
}
`,
    "AGENTS.md": `# ${name} — a Slapp project

You are the builder agent for this iPhone app. The user talks to you by voice
through Slapp on their phone. Keep replies short and plain — they may be read
aloud. Confirm what you did, briefly.

## The build loop on this Mac

- The app icon (Assets.xcassets/AppIcon.appiconset) is generated at scaffold
  time from the app's name and hue — icons are first-class here. If the user
  describes an icon, redraw it: \`swift ${import.meta.dirname}/make-icon.swift <out.png> <letter> <hue 0-1> <sat 0-1>\`
  (or hand-write vector art into the asset catalog).
- \`project.yml\` (xcodegen) is the source of truth. Never edit pbxproj. After
  adding/removing source files run \`xcodegen generate\`.
- Build:
  xcodebuild -project ${name}.xcodeproj -scheme ${name} -destination 'platform=iOS Simulator,id=${UDID}' -configuration Debug build
- Install + launch:
  xcrun simctl install ${UDID} "<path to ${name}.app>"
  xcrun simctl launch ${UDID} ${bundle}
- Verify visually, always: screenshot, read it, judge, fix, repeat.
  \`xcrun simctl io ${UDID} screenshot <this dir>/.slapp/screen.png\` — that file
  IS the canvas the user sees in Slapp. Write it after every working build.
- Never control the Simulator via its window.

## Putting builds on a real iPhone (when asked)

- Find it: \`xcrun devicectl list devices\` — the phone must be plugged in and
  UNLOCKED. If "unavailable", say so plainly and ask the user to plug/unlock.
- Install: \`xcrun devicectl device install app --device <id> "<path to .app>"\`
  (build first with \`-destination 'generic/platform=iOS' -configuration Release\`).
- Launch: \`xcrun devicectl device process launch --device <id> <bundle>\` —
  fails while locked; that's fine, tell the user to tap the icon.
- Never say "CoreDevice error" — say "the phone is locked or unplugged".

## Context on every message

Messages from Slapp start with a "[slapp context · …]" line: which app the user
is looking at in the simulator, how old the canvas screenshot is, the project
dir, the repo, and — if they attached one — the path of their annotated
screenshot (circles/arrows drawn on it). READ that file before replying when
present. Use the context to orient yourself; never echo it back to the user.

## Sharing media back (photos, audio)

- Save any image the user should see into the project dir (or .slapp/), then
  INCLUDE the full absolute path in your reply — e.g. "here's the mock:
  /path/to/mock.png". Slapp shows it as a photo right in the chat.
- Same for audio: .mp3/.wav/.ogg/.m4a files whose path appears in your reply
  become playable players in the chat. (e.g. generate a wav with ffmpeg or
  say -o file.aiff --data-format=LEF32@22050 -o out.wav "hello")
- Photos the user sends arrive as files in the project dir — the [slapp
  context] line names them. Open/inspect them before answering.
- Keep filenames simple (no spaces). Media paths must be under the project
  dir or they won't reach the phone.


\n## Keep tool output small (the local model chokes on giant logs)

Always pipe long build/run output: \`xcodebuild ... 2>&1 | tail -40\`.
Never paste whole build logs into the conversation.\n\n## Discipline

- Commit early, commit often, one-line messages. Push to origin after each
  working build.
- The user may interrupt with new instructions mid-build; handle gracefully.
- Deployment target iOS 17, SwiftUI, Swift 5 language mode. No extra
  dependencies unless asked.
`,
  };
}

// ── Apple Watch variant ────────────────────────────────────────────────────
// Single-target watchOS app (Xcode 14+ style): one target, WKApplication key.
function watchTemplateFiles(name, slug, watchUDID) {
  const bundle = `com.snail3d.${slug}`;
  return {
    "project.yml": `name: ${name}
options:
  bundleIdPrefix: com.snail3d
  deploymentTarget: { watchOS: "10.0" }
  createIntermediateGroups: true
settings: { base: { SWIFT_VERSION: "5.0" } }
targets:
  ${name}:
    type: application
    platform: watchOS
    sources: [${name}]
    info:
      path: ${name}/Info.plist
      properties:
        WKApplication: true
        WKWatchOnly: true
        CFBundleDisplayName: "${name}"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: ${bundle}
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        DEVELOPMENT_TEAM: 9V8U7PCW58
        CODE_SIGN_STYLE: Automatic
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
`,
    ".gitignore": ".DS_Store\n*.xcodeproj\nDerivedData/\n.slapp/dd/\n",
    [`${name}/Info.plist`]: `{}`,
    [`${name}/App.swift`]: `import SwiftUI

@main
struct ${name.replace(/[^A-Za-z0-9]/g, "")}App: App {
    var body: some Scene { WindowGroup { Canvas() } }
}

// A tiny canvas for the wrist. The builder agent will replace this.
struct Canvas: View {
    @State private var drag: CGSize = .zero
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("${name.replace(/["\\]/g, "")}")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(Color.green.opacity(0.9))
                .multilineTextAlignment(.center)
                .offset(drag)
                .gesture(DragGesture().onChanged { drag = $0.translation })
        }
    }
}
`,
    "AGENTS.md": `# ${name} — a Slapp watch app

You are the builder agent for this Apple Watch app. The user talks to you by
voice through Slapp on their iPhone. Keep replies short and plain — they may
be read aloud. Confirm what you did, briefly.

## The build loop on this Mac (watchOS)

- The app icon (Assets.xcassets/AppIcon.appiconset) is generated at scaffold
  time from the app's name and hue — icons are first-class here. If the user
  describes an icon, redraw it: \`swift ${import.meta.dirname}/make-icon.swift <out.png> <letter> <hue 0-1> <sat 0-1>\`
  (or hand-write vector art into the asset catalog).
- \`project.yml\` (xcodegen) is the source of truth. Never edit pbxproj. After
  adding/removing source files run \`xcodegen generate\`.
- This is a single-target watchOS app (WKApplication). Deployment target
  watchOS 10, SwiftUI, Swift 5.
- Build:
  xcodebuild -project ${name}.xcodeproj -scheme ${name} -destination 'platform=watchOS Simulator,id=${watchUDID}' -configuration Debug build 2>&1 | tail -40
- Install + launch:
  xcrun simctl install ${watchUDID} "<path to ${name}.app>"
  xcrun simctl launch ${watchUDID} ${bundle}
- Verify visually, always: screenshot, read it, judge, fix, repeat.
  \`xcrun simctl io ${watchUDID} screenshot <this dir>/.slapp/screen.png\` — that
  file IS the canvas the user sees in Slapp. Write it after every working build.
- The watch screen is tiny: one idea per screen, big text, minimal chrome.
  Digital Crown scrolling beats buttons. Design for a 2-second glance.

## Keep tool output small (the local model chokes on giant logs)

Always pipe long build/run output: \`xcodebuild ... 2>&1 | tail -40\`.
Never paste whole build logs into the conversation.\n\n## Discipline

- Commit early, commit often, one-line messages. Push to origin after each
  working build.
- The user may interrupt with new instructions mid-build; handle gracefully.
- No extra dependencies unless asked.
`,
  };
}

// which simulator this session builds for / screenshots
async function simIdFor(sess) {
  if (sess.simId) return sess.simId;
  if (sess.kind !== "watch") { sess.simId = UDID; return UDID; }
  if (WATCH_UDID) { sess.simId = WATCH_UDID; return WATCH_UDID; }
  const r = await run("xcrun", ["simctl", "list", "devices", "available"]);
  let inWatch = false;
  for (const line of r.stdout.split("\n")) {
    if (line.startsWith("--")) { inWatch = /watchOS/i.test(line); continue; }
    if (inWatch) { const m = line.match(/\(([0-9A-Fa-f-]{36})\)/); if (m) { sess.simId = m[1]; return sess.simId; } }
  }
  throw new Error("no Apple Watch simulator found — open Xcode's simulator list once to install them");
}

async function scaffoldProject(sess) {
  await fsp.mkdir(path.join(sess.dir, ".slapp"), { recursive: true });
  const watchUDID = sess.kind === "watch" ? await simIdFor(sess) : "";
  for (const [rel, content] of Object.entries(templateFiles(sess.name, sess.slug, sess.kind, watchUDID))) {
    const p = path.join(sess.dir, rel);
    await fsp.mkdir(path.dirname(p), { recursive: true });
    await fsp.writeFile(p, content);
  }
  push(sess, { type: "status", text: "template scaffolded" });

  // icons are one of the first things: every app is born with a face —
  // ink ground, its own hue, its initial in serif. same Cells math as the app.
  try {
    push(sess, { type: "status", text: "drawing the app icon" });
    const { hue, sat } = cellsColor(sess.slug);
    const letter = (sess.name.trim()[0] || "A").toUpperCase();
    const iconDir = path.join(sess.dir, sess.name, "Assets.xcassets", "AppIcon.appiconset");
    await fsp.mkdir(iconDir, { recursive: true });
    await fsp.writeFile(path.join(iconDir, "Contents.json"), JSON.stringify({
      images: [{ filename: "AppIcon.png", idiom: "universal", platform: sess.kind === "watch" ? "watchos" : "ios", size: "1024x1024" }],
      info: { author: "xcode", version: 1 },
    }));
    const gen = await run("swift", [path.join(import.meta.dirname, "make-icon.swift"),
      path.join(iconDir, "AppIcon.png"), letter, String(hue), String(sat)]);
    push(sess, { type: "status", text: gen.code ? "icon skipped (swift unavailable)" : "icon drawn — it has a face" });
  } catch {}

  const gitr = await run("git", ["init", "-q"], { cwd: sess.dir });
  if (gitr.code) throw new Error("git init failed: " + gitr.stderr);
  await run("git", ["add", "-A"], { cwd: sess.dir });
  await run("git", ["commit", "-qm", "Scaffold blank canvas template"], { cwd: sess.dir });
  push(sess, { type: "status", text: "initial commit" });

  const gh = await run("gh", ["repo", "create", `${GITHUB_OWNER}/${sess.slug}`, "--private",
    "--source=.", "--remote=origin", "--push"], { cwd: sess.dir });
  if (gh.code) {
    // repo may already exist (recreated app) — attach it and push instead of failing
    const remote = `https://github.com/${GITHUB_OWNER}/${sess.slug}.git`;
    await run("git", ["remote", "remove", "origin"], { cwd: sess.dir });
    const add = await run("git", ["remote", "add", "origin", remote], { cwd: sess.dir });
    const up = add.code ? add : await run("git", ["push", "-u", "origin", "HEAD"], { cwd: sess.dir });
    if (!up.code) {
      sess.repo = `https://github.com/${GITHUB_OWNER}/${sess.slug}`;
      push(sess, { type: "status", text: `attached to existing repo: ${GITHUB_OWNER}/${sess.slug}` });
    } else {
      push(sess, { type: "status", text: "github repo failed: " + gh.stderr.trim().slice(0, 200) });
    }
  } else {
    sess.repo = `https://github.com/${GITHUB_OWNER}/${sess.slug}`;
    push(sess, { type: "status", text: `github repo: ${GITHUB_OWNER}/${sess.slug} (private)` });
  }
  persistSessions();
}

// ── watch signing self-heal ──────────────────────────────────────────────
// The capture wall, root-caused 2026-09-01: the portal had the WRONG watch
// UDID (a stale pairing), so every profile was "not for this device" and the
// watch's installer died at _installEmbeddedProfilesWithError (-402620398)
// with a provably valid profile. Cure: check the watch's REAL udid (from
// devicectl) against the embedded profile; if absent — register the device,
// mint a fresh development profile via the ASC API, embed it, re-sign.
const ASC_KEY_ID = process.env.SLAPP_ASC_KEY || "ZZM3GSQ7RD";
const ASC_ISSUER_FILE = process.env.SLAPP_ASC_ISSUER_FILE || path.join(os.homedir(), ".appstoreconnect/issuer");
const ASC_KEY_FILE = process.env.SLAPP_ASC_KEY_FILE || path.join(os.homedir(), `.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8`);

function ascJwt() {
  const pem = fs.readFileSync(ASC_KEY_FILE, "utf8");
  const iss = fs.readFileSync(ASC_ISSUER_FILE, "utf8").trim();
  const b64 = (b) => Buffer.from(b).toString("base64url");
  const header = b64(JSON.stringify({ alg: "ES256", kid: ASC_KEY_ID, typ: "JWT" }));
  const payload = b64(JSON.stringify({ iss, iat: Math.floor(Date.now() / 1000) - 30, exp: Math.floor(Date.now() / 1000) + 1200, aud: "appstoreconnect-v1" }));
  const signing = `${header}.${payload}`;
  const signer = createSign("SHA256"); signer.update(signing);
  const der = signer.sign(pem); // DER ECDSA signature → raw r||s
  let i = 2; const rLen = der[i + 1]; i += 2;
  let r = der.subarray(i, i + rLen); i += rLen;
  i += 1; const sLen = der[i + 1]; i += 2;
  let s = der.subarray(i, i + sLen);
  const pad = (b) => { b = b.subarray(b[0] === 0 && b.length > 32 ? 1 : 0); const out = Buffer.alloc(32); b.copy(out, 32 - b.length); return out; };
  return `${signing}.${b64(Buffer.concat([pad(r), pad(s)]))}`;
}

async function asc(path_, opts = {}) {
  const r = await fetch(`https://api.appstoreconnect.apple.com${path_}`, { ...opts,
    headers: { Authorization: `Bearer ${ascJwt()}`, "Content-Type": "application/json", ...(opts.headers || {}) } });
  const text = await r.text();
  let body = null; try { body = JSON.parse(text); } catch {}
  if (!r.ok) throw new Error(body?.errors?.[0]?.detail || text.slice(0, 200));
  return body;
}

async function watchRealUdid(devId) {
  const r = await run("xcrun", ["devicectl", "device", "info", "details", "--device", devId]);
  return (r.stdout.match(/udid:\s*(\S+)/) || [])[1] || null;
}

async function profileHasDevice(appPath, udid) {
  const p = path.join(appPath, "embedded.mobileprovision");
  if (!fs.existsSync(p)) return false;
  const r = await run("security", ["cms", "-D", "-i", p]);
  return r.stdout.includes(udid);
}

async function ensureWatchSigned(appPath, sess, watchDev) {
  const udid = await watchRealUdid(watchDev.id);
  if (!udid) return; // can't verify — let the install speak for itself
  if (await profileHasDevice(appPath, udid)) return; // profile already knows the watch
  push(sess, { type: "status", text: "the portal doesn't know this watch yet — fixing the signing" });
  // 1) register the device (idempotent — reused if already there)
  let devs = await asc("/v1/devices?filter%5Bplatform%5D=IOS&limit=100");
  let rec = devs.data.find(d => d.attributes.udid === udid);
  if (!rec) {
    rec = (await asc("/v1/devices", { method: "POST", body: JSON.stringify({ data: { type: "devices",
      attributes: { name: `Slapp watch ${watchDev.name}`, udid, platform: "IOS" } } }) })).data;
  }
  for (let i = 0; i < 12; i++) { // portal states: PROCESSING → ENABLED
    const cur = await asc(`/v1/devices/${rec.id}`);
    if (cur.data.attributes.status === "ENABLED") break;
    await new Promise(r2 => setTimeout(r2, 5000));
  }
  // 2) bundle id record
  const bundleId = `com.snail3d.${sess.slug}`;
  let bids = await asc(`/v1/bundleIds?filter%5Bidentifier%5D=${bundleId}`);
  let bid = bids.data[0];
  if (!bid) bid = (await asc("/v1/bundleIds", { method: "POST", body: JSON.stringify({ data: { type: "bundleIds",
    attributes: { name: sess.name, identifier: bundleId, platform: "IOS" } } }) })).data;
  // 3) development certificate
  const certs = await asc("/v1/certificates?limit=100");
  const cert = certs.data.find(c => c.attributes.certificateType === "DEVELOPMENT");
  if (!cert) throw new Error("no Apple Development certificate exists on the portal account — open Xcode once, sign in, and it appears");
  // 4) fresh profile with every enabled device
  devs = await asc("/v1/devices?filter%5Bplatform%5D=IOS&limit=100");
  const devRels = devs.data.filter(d => d.attributes.status === "ENABLED").map(d => ({ type: "devices", id: d.id }));
  const prof = await asc("/v1/profiles", { method: "POST", body: JSON.stringify({ data: { type: "profiles",
    attributes: { name: `Slapp ${sess.slug} ${Date.now()}`, profileType: "IOS_APP_DEVELOPMENT" },
    relationships: { bundleId: { data: { type: "bundleIds", id: bid.id } },
      certificates: { data: [{ type: "certificates", id: cert.id }] }, devices: { data: devRels } } } }) });
  const full = await asc(`/v1/profiles/${prof.data.id}?fields%5Bprofiles%5D=profileContent`);
  fs.writeFileSync(path.join(appPath, "embedded.mobileprovision"), Buffer.from(full.data.attributes.profileContent, "base64"));
  // 5) entitlements from the profile, re-sign with the dev identity
  const pp = await run("security", ["cms", "-D", "-i", path.join(appPath, "embedded.mobileprovision")]);
  const raw = path.join(os.tmpdir(), `slapp-pp-${randomUUID().slice(0, 8)}.plist`);
  fs.writeFileSync(raw, pp.stdout);
  const ents = path.join(os.tmpdir(), `slapp-ents-${randomUUID().slice(0, 8)}.plist`);
  const pe = await run("python3", ["-c",
    `import plistlib,sys\nd=plistlib.load(open(sys.argv[1],'rb'))\ne=d['Entitlements']\nplistlib.dump({'application-identifier':e['application-identifier'],'com.apple.developer.team-identifier':e['com.apple.developer.team-identifier'],'keychain-access-groups':e.get('keychain-access-groups'),'get-task-allow':True},open(sys.argv[2],'wb'))`,
    raw, ents]);
  if (pe.code) throw new Error("couldn't derive entitlements from the fresh profile");
  const ids = await run("security", ["find-identity", "-v", "-p", "codesigning"]);
  const sha = (ids.stdout.match(/([A-F0-9]{40}) "Apple Development/) || [])[1];
  if (!sha) throw new Error("no Apple Development certificate in this Mac's keychain — open Xcode once to fetch it");
  const cs = await run("codesign", ["--force", "--sign", sha, "--entitlements", ents, appPath]);
  if (cs.code) throw new Error("re-signing failed: " + (cs.stderr || cs.stdout).slice(-200));
  push(sess, { type: "status", text: "signing fixed — the watch is in the profile now" });
}

// THE LAUNCHER'S CHARTER — written into its workspace at creation.
function LAUNCHER_CHARTER() {
  const home = os.homedir();
  return `# launcher — the session whose job is sessions

You are the launcher. Three duties, in this order of importance:

## 1. Skills are your ledger
You own every skill on this Mac:
- ${home}/.pi/agent/skills (pi's own)
- ${home}/.agents/skills (the fleet's shared skills)
- ${home}/.hermes/skills (the hermes corpus — big, older, uneven)

Your standing job: know what's in them, consolidate duplicates, fix stale
instructions, and IMPROVE them over time. When you learn something new about
how work actually gets done on this Mac, fold it into the relevant skill.
Editing skills is not a side effect — it IS the job. Keep each skill's
SKILL.md tight: what it's for, how to do it, gotchas learned the hard way.

## 2. Launching crews
When someone describes a mission (from the phone, the watch, or the pane),
you create a session for it via the daemon API:

    curl -s -X POST http://127.0.0.1:8123/api/session \
      -H "Content-Type: application/json" \
      -d '{"name":"fish log","kind":"ios","prompt":"<one-line brief>",
           "model":"snail-api-256/snail-top","thinking":"medium"}'

- Pick the MODEL and REASONING from the task: heavy build/debug work gets
  snail-api-256/snail-top + medium; quick lookups get snail-api/NextMac131 +
  "none". Say why in one line.
- Search the skill territories for skills relevant to the mission and name
  them in the prompt ("load the ios-simulator skill first") so the worker
  starts with its tools already in hand.
- Sessions appear instantly on the phone's mosaic and can be taken over in
  a herdr pane:  node server/herdr-pane.mjs <slug>

## 3. Babysitting
When babysitting mode is on (the daemon ticks you periodically), you get a
state digest of every session. Keep stalled ones going; leave healthy ones
alone. A session stuck in error twice gets restarted once; twice more gets
reported, not endlessly restarted.

## House laws
- Plain words, always — the person you serve is not a jargon person.
- One alive accent, serif display, true black: the cells laws apply to
  anything you build.
- Never scaffold over an existing project. Adopt, don't flatten.
`;
}

// find the buildable project for a session — scaffolded apps live at
// <dir>/<name>.xcodeproj; bound existing projects can carry theirs anywhere
// within two levels (watch projects keep their app in watchos/).
function findProject(sess) {
  const direct = path.join(sess.dir, `${sess.name}.xcodeproj`);
  if (fs.existsSync(direct)) return { proj: direct, dir: sess.dir, scheme: sess.name, runXcodegen: fs.existsSync(path.join(sess.dir, "project.yml")) };
  const sub = fs.readdirSync(sess.dir).filter(f => { try { return fs.statSync(path.join(sess.dir, f)).isDirectory(); } catch { return false; } });
  for (const d of [sess.dir, ...sub.map(f => path.join(sess.dir, f))]) {
    for (const f of fs.readdirSync(d)) {
      if (f.endsWith(".xcodeproj")) {
        return { proj: path.join(d, f), dir: d, scheme: f.replace(/\.xcodeproj$/, ""), runXcodegen: fs.existsSync(path.join(d, "project.yml")) };
      }
    }
  }
  return null;
}

async function buildAndLaunch(sess) {
  sess.phase = "building";
  const isWatch = sess.kind === "watch";
  // a real Apple Watch beats a simulator — but only when it's actually there
  const watchDev = isWatch ? await findWatchDevice() : null;
  const platform = isWatch ? "watchOS" : "iOS";
  push(sess, { type: "status", text: watchDev ? `building for your ${watchDev.name}`
    : isWatch ? "building for the wrist (simulator — watch not reachable)" : "building for the phone" });
  const proj = findProject(sess);
  if (!proj) throw new Error("no Xcode project found in this project folder");
  const appName = path.basename(proj.proj, ".xcodeproj");
  if (proj.runXcodegen) {
    const xg = await run("xcodegen", ["generate"], { cwd: proj.dir });
    if (xg.code) throw new Error("xcodegen failed: " + xg.stderr);
  }
  const simId = watchDev ? null : await simIdFor(sess);
  if (simId) await run("xcrun", ["simctl", "bootstatus", simId, "-b"]); // sim awake before we talk to it
  const ddPath = path.join(proj.dir, ".slapp", "dd");
  // -allowProvisioningUpdates ALWAYS on device builds: a profile made before
  // the watch was reachable lacks the watch — rebuild registers it (the
  // flaky-install lesson)
  const b = await run("xcodebuild", ["-project", proj.proj, "-scheme", proj.scheme,
    "-destination", watchDev ? "generic/platform=watchOS" : `platform=${platform} Simulator,id=${simId}`,
    "-configuration", watchDev ? "Release" : "Debug",
    ...(watchDev ? ["-allowProvisioningUpdates"] : []),
    "-derivedDataPath", ddPath, "build"],
    { cwd: sess.dir });
  if (b.code) throw new Error("xcodebuild failed: " + b.stderr.slice(-500));
  push(sess, { type: "status", text: "build ok, installing" });

  if (watchDev) {
    const appPath = path.join(ddPath, "Build/Products/Release-watchos", `${appName}.app`);
    if (!fs.existsSync(appPath)) throw new Error("built .app missing at " + appPath);
    try { await ensureWatchSigned(appPath, sess, watchDev); } // the flaky-install cure, automatic
    catch (e) { push(sess, { type: "status", text: `signing fixup skipped: ${String(e?.message ?? e).slice(0, 120)} — trying the install anyway` }); }
    let installed = false, lastRaw = "";
    for (let attempt = 1; attempt <= 3; attempt++) {
      const ins = await run("xcrun", ["devicectl", "device", "install", "app", "--device", watchDev.id, appPath]);
      if (!ins.code) { installed = true; break; }
      lastRaw = ((ins.stderr || "") + (ins.stdout || "")).toLowerCase();
      // installs to the wrist are flaky, not blocked —
      // retry hard, but surface the known walls in human words immediately
      if (lastRaw.includes("profil"))
        throw new Error("the watch wasn't reachable when the signing profile was made — it's rebuilt with the watch connected, so send it again in a moment");
      if (lastRaw.includes("developer mode"))
        throw new Error("on the watch itself: Settings → Privacy & Security → Developer Mode → on, then ask me again");
      await new Promise(r => setTimeout(r, 2500));
    }
    if (!installed) {
      if (lastRaw.includes("tunnel") || lastRaw.includes("timed out") || lastRaw.includes("could not be established") || lastRaw.includes("disconnected"))
        throw new Error("can't hold a line to the watch — it's routing through the phone's bluetooth. on the iPhone: Control Center → Airplane Mode ON → WiFi ON (the watch hops to home wifi), then ask me again");
      throw new Error("couldn't install on the watch — " + (lastRaw.slice(-140).trim() || "unknown hiccup"));
    }
    // bundle id follows the slug (com.snail3d.fish-log), never the raw name —
    // same id the template and the signing self-heal both use
    const devLaunch = await run("xcrun", ["devicectl", "device", "process", "launch", "--device", watchDev.id, `com.snail3d.${sess.slug}`]);
    if (!devLaunch.code) push(sess, { type: "status", text: `running on your ${watchDev.name} — look down` });
    push(sess, { type: "status", text: `live on your ${watchDev.name} — real watches have no canvas yet` });
    sess.phase = "ready";
    return;
  }

  const sdkDir = sess.kind === "watch" ? "watchsimulator" : "iphonesimulator";
  const appPath = path.join(ddPath, `Build/Products/Debug-${sdkDir}`, `${appName}.app`);
  if (!fs.existsSync(appPath)) throw new Error("built .app missing at " + appPath);
  const inst = await run("xcrun", ["simctl", "install", simId, appPath]);
  if (inst.code) throw new Error("simctl install failed: " + inst.stderr);
  const launch = await run("xcrun", ["simctl", "launch", simId, `com.snail3d.${sess.slug}`]);
  if (launch.code) throw new Error("simctl launch failed: " + launch.stderr);
  simForeground.set(simId, `com.snail3d.${sess.slug}`);
  await new Promise(r => setTimeout(r, 1400)); // let the first frame render — no white birth photos
  await takeScreenshot(sess);
  sess.phase = "ready";
  push(sess, { type: "status", text: "canvas live — template is on screen" });
}

// find a real Apple Watch devicectl can reach — SLAPP_WATCH_DEVICE matches
// name or id, otherwise any available watch wins. Hard-won lesson: the
// install tunnel clings to Bluetooth-through-iPhone, so availability != speed.
async function findWatchDevice() {
  const want = (process.env.SLAPP_WATCH_DEVICE || "").trim().toLowerCase();
  const r = await run("xcrun", ["devicectl", "list", "devices"]);
  if (r.code) return null;
  for (const line of r.stdout.split("\n")) {
    if (!/watch/i.test(line) || /watchos simulator/i.test(line)) continue;
    const id = (line.match(/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/) || [])[0];
    if (!id) continue;
    const name = line.split(/\s{2,}/)[0].trim();
    const avail = /available/i.test(line);
    if (want) {
      if (name.toLowerCase().includes(want) || id.toLowerCase() === want) return { id, name, avail };
    } else if (avail) return { id, name, avail };
  }
  return null;
}

// ── screenshots ─────────────────────────────────────────────────────────────
// which app each simulator last had brought to the front — so a session's
// canvas shows ITS app, not whatever else is frontmost in the shared sim
const simForeground = new Map(); // simId -> bundle id

// screenshots are serialized (two at once make simctl fail) and written to a
// temp file first, so the canvas is never half-written while the phone reads it
let shotChain = Promise.resolve();
let lastShotAt = 0;
async function takeScreenshot(sess) {
  const prev = shotChain;
  let release;
  shotChain = new Promise(r => { release = r; });
  await prev;
  try {
    if (Date.now() - lastShotAt < 1200) return true; // a shot just landed
    const simId = await simIdFor(sess); // the session's own screen — watch ≠ phone
    // a shut-down sim would hang simctl — serve the last canvas instead
    const st = await run("xcrun", ["simctl", "list", "devices"]);
    if (!st.stdout.includes(simId) || !new RegExp(simId + "[^\n]*Booted").test(st.stdout)) return false;
    await fsp.mkdir(path.dirname(sess.screenPath), { recursive: true });
    const tmp = sess.screenPath + ".tmp";
    const r = await run("xcrun", ["simctl", "io", simId, "screenshot", tmp]);
    if (r.code) {
      push(sess, { type: "status", text: "screenshot failed: " + r.stderr.slice(0, 120) });
      return false;
    }
    fs.renameSync(tmp, sess.screenPath);
    lastShotAt = sess.lastShotAt = Date.now();
    push(sess, { type: "screen", text: "canvas updated" });
    return true;
  } catch { return false; }
  finally { release(); }
}

// ── pi session ──────────────────────────────────────────────────────────────
// No compromises: every session IS a real pi process (`pi --mode rpc`). Same
// engine, same model switches, same session files as the terminal. The phone
// and the herdr pane are two doors into the identical run.
// Pin to OpenRouter's GLM-5.3-Flash — the local vLLM cluster flaps under load.
let sharedModelRuntime = null;
async function pinnedModel() {
  // the fleet: snail-top on the DGX pair, 256k window, medium thinking
  try {
    sharedModelRuntime ??= await ModelRuntime.create();
    const m = sharedModelRuntime.getModel("snail-api-256", "snail-top");
    return m ? { provider: "snail-api-256", id: "snail-top" } : undefined;
  } catch { return undefined; }
}

// ── the real pi instance ────────────────────────────────────────────────────
// Every session's pane runs the actual interactive pi TUI — the same one as
// the terminal. The daemon joins by typing into the pane and reading pi's own
// session log, so the phone and the pane are two doors into one real run.

function piTuiCommand(sess, resume = false) {
  const args = ["pi"];
  if (sess.selfSessionId) args.push("--session-id", sess.selfSessionId);
  else if (sess.sessionFile) args.push("--session", sess.sessionFile);
  else if (resume) args.push("-c");
  else args.push("-n", sess.name);
  const mdl = sess.model;
  if (mdl?.provider && mdl?.id) args.push("--model", `${mdl.provider}/${mdl.id}`);
  if (sess.thinking !== null) args.push("--thinking", sess.thinking ?? "medium");
  // POSIX single-quote escaping — JSON.stringify is NOT shell-safe ($(…),
  // backticks inside double quotes would execute)
  const shq = (a) => `'${String(a).replaceAll("'", `'\\''`)}'`;
  // the pane command must cd first: herdr runs it from the daemon's cwd, and
  // the session's own tools (slapp live-thinking, project-relative work)
  // need process.cwd() to be the project
  return `cd ${shq(sess.dir)} && ` + args.map(shq).join(" ");
}

function piSessionDir(sess) {
  // pi's project slug: leading/trailing "--", inner "/" → "-" (verified on
  // disk: /Users/youruser → --Users-youruser--). Fall back to a scan.
  const base = path.join(os.homedir(), ".pi", "agent", "sessions");
  const guess = path.join(base, "--" + sess.dir.replace(/^\//, "").replace(/\//g, "-") + "--");
  try { if (fs.statSync(guess).isDirectory()) return guess; } catch {}
  try {
    const want = sess.dir.toLowerCase().replace(/[^a-z0-9]/g, "");
    for (const d of fs.readdirSync(base)) {
      if (d.toLowerCase().replace(/[^a-z0-9]/g, "") === want) return path.join(base, d);
    }
  } catch {}
  return guess;
}

async function searchAllSessions(q, res) {
    // past conversations, pi /resume style: keyword search across every
    // session's pi history, newest first. one road for the phone, the
  // watch, and anything else — no session hardcoding anywhere.
    const out = [];
    for (const [slug, sx] of sessions) {
      const dir = piSessionDir(sx);
      let files = [];
      try { files = (await fsp.readdir(dir)).filter(f => f.endsWith(".jsonl"))
        .map(f => ({ f, t: fs.statSync(path.join(dir, f)).mtimeMs }))
        .sort((a, b) => b.t - a.t); } catch { continue; }
      for (const { f, t } of files.slice(0, 40)) {
        // async + size cap: sync reads of giant pi logs froze the whole daemon
        const fp = path.join(dir, f);
        try { if (fs.statSync(fp).size > 32e6) continue; } catch { continue; }
        let lines;
        try { lines = (await fsp.readFile(fp, "utf8")).split("\n"); } catch { continue; }
        let title = "", snippet = "", turns = 0, matched = false;
        for (const line of lines) {
          let j; try { j = JSON.parse(line); } catch { continue; }
          const m = j.message ?? {};
          if (m.role !== "user" && m.role !== "assistant") continue;
          let text = "";
          for (const c of (m.content ?? [])) if (c?.type === "text") text += c.text;
          if (!text) continue;
          if (m.role === "user" && !title && !text.startsWith("[slapp context") && !/^pi\s+-/.test(text)) title = text.slice(0, 90);
          turns++;
          if (q && !matched && text.toLowerCase().includes(q)) { matched = true; snippet = text.slice(0, 160); }
        }
        if (q && !matched && !title.toLowerCase().includes(q)) continue;
        out.push({ slug, session: sx.name, file: path.join(dir, f), mtime: t,
                   title: title || "(untitled)", snippet, turns });
        if (out.length >= 60) break;
      }
      if (out.length >= 60) break;
    }
    out.sort((a, b) => b.mtime - a.mtime);
    return json(res, 200, { ok: true, results: out.slice(0, 40) });
}

function newestSessionFile(dir) {
  try {
    const files = fs.readdirSync(dir).filter(f => f.endsWith(".jsonl"))
      .map(f => ({ f, t: fs.statSync(path.join(dir, f)).mtimeMs }));
    files.sort((a, b) => b.t - a.t);
    return files[0] ? path.join(dir, files[0].f) : null;
  } catch { return null; }
}

const ARG_MAX_PREVIEW = 110;
function argsPreview(name, a) {
  if (!a) return "";
  try {
    if (name === "bash") return String(a.command ?? "").replace(/\s+/g, " ").trim().slice(0, ARG_MAX_PREVIEW);
    if (a.path) return String(a.path).split("/").slice(-2).join("/");
    return String(a.command ?? JSON.stringify(a)).slice(0, ARG_MAX_PREVIEW);
  } catch { return ""; }
}

function startTail(sess) {
  if (sess.tail) return;
  if (sess.live?.port) startLiveTraffic(sess);   // the live wire rides along
  // offset -1 = first sight: old sessions attach at EOF (never replay
  // history as events), fresh/birth files follow from the start
  sess.tail = { file: null, offset: -1, reply: "", thinkBlocks: 0, userSeen: 0, lastActivity: Date.now() };
  const timer = setInterval(() => tailTick(sess).catch(() => {}), 600);
  timer.unref?.();
  sess.tailTimer = timer;
  log(`[tail ${sess.slug}] armed`);
}

async function tailTick(sess) {
  const t = sess.tail;
  if (!t) return;
  // quiet-run watchdog: "busy" with zero log activity for 15 min isn't work.
  // the tail path had no agent_end — without this, the phone shows building… forever.
  if (sess.busy && Date.now() - t.lastActivity > 15 * 60_000) {
    sess.busy = false; sess.rpcBusy = false; t.lastActivity = Date.now();
    push(sess, { type: "status", text: "the run went quiet for 15 minutes — I've stopped waiting. Nudge it or say it again." });
    return;
  }
  // LIVE: the claimant pi process doesn't hold its session file open, so we
  // identify it by movement — the file that grows after the claim is the
  // conversation (the relayed words themselves guarantee growth). Once
  // found: backfill the last ~96KB as history so the phone opens with
  // context, then follow live.
  if (sess.live?.port && !t.file) {
    const dirL = piSessionDir(sess);
    let files = [];
    try { files = fs.readdirSync(dirL).filter(f => f.endsWith(".jsonl")).map(f => path.join(dirL, f)); } catch {}
    const sizes = new Map();
    for (const f of files) { try { const sz = fs.statSync(f).size; if (sz < 10 * 1024 * 1024) sizes.set(f, sz); } catch {} }
    if (!t.liveSizes) {
      t.liveSizes = sizes; t.liveArmAt = Date.now();
      // the probe: injected through the live listener, it grows exactly one
      // file — ours — even in a project where old conversations still move
      relayLive(sess, { kind: "capture", mode: "text", text: "[slapp linked] this conversation is now on the phone", device: "slapp", ts: Date.now() }).catch(() => {});
      return;
    }
    let moved = null, best = 0;
    for (const [f, sz] of sizes) {
      const grew = sz - (t.liveSizes.get(f) ?? -1);   // the one that GREW most is the conversation
      if (grew > best) { best = grew; moved = f; }
    }
    if (!moved && Date.now() - t.liveArmAt < 30_000) { t.liveSizes = sizes; return; }
    if (!moved) { // idle too long — fall back to the newest file
      let newest = null, nm = -1;
      for (const [f] of sizes) { const m = fs.statSync(f).mtimeMs; if (m > nm) { nm = m; newest = f; } }
      moved = newest;
    }
    if (!moved) return;
    const sz0 = sizes.get(moved) ?? 0;
    t.file = moved;
    t.offset = Math.max(0, sz0 - 96 * 1024);   // a decent amount of history
    t.backfill = true;
    t.liveSizes = null;
    log(`[tail ${sess.slug}] live conversation found → ${path.basename(moved)} (backfill from ${t.offset})`);
    return;
  }

  const dir = piSessionDir(sess);
  let file = null;
  if (sess.selfSessionId) {
    // the pin: follow slapp itself's own conversation file, whatever else
    // lives in this project dir (the desk pi writes here too)
    try {
      file = fs.readdirSync(dir).map(f => path.join(dir, f)).find(f => f.includes(sess.selfSessionId)) || null;
    } catch {}
  }
  // sticky: once a file is chosen, keep it until it vanishes — busy project
  // dirs have several live writers and newest-by-mtime would flip-flop,
  // losing agent_end and leaving the session busy forever
  if (!file && t.file) {
    try { if (fs.existsSync(t.file)) file = t.file; } catch {}
  }
  if (!file) file = newestSessionFile(dir);
  if (!file) return;
  if (t.file !== file) { log(`[tail ${sess.slug}] file → ${path.basename(file)}`); t.file = file; t.offset = -1; t.reply = ""; t.thinkBlocks = 0; }
  let size = 0;
  try { size = fs.statSync(file).size; } catch { return; }
  if (t.offset === -1) {
    // first sight: a young file (this run's own session) is followed from
    // birth; a big old one is history — attach at the end
    t.offset = size < 65536 ? 0 : size;
    log(`[tail ${sess.slug}] attach at ${t.offset} (size ${size})`);
  }
  if (size < t.offset) t.offset = 0;             // truncated/rewritten → reread
  if (size === t.offset) return;
  let chunk;
  try { chunk = fs.readFileSync(file).slice(t.offset).toString("utf8"); } catch (e) { log(`[tail ${sess.slug}] read err ${e?.message}`); return; }
  t.offset = size;
  const lines = chunk.split("\n");
  if (chunk.endsWith("\n")) lines.pop();
  log(`[tail ${sess.slug}] +${lines.length} lines (${size}B)`);
  const wasBackfill = t.backfill === true;
  if (wasBackfill) t.backfill = false;
  t.inHistory = wasBackfill;
  for (const line of lines) {
    let j; try { j = JSON.parse(line); } catch { continue; }
    mapPiEntry(sess, j);
  }
  if (wasBackfill) { sess.busy = false; sess.rpcBusy = false; t.inHistory = false; }   // history is not work
}

function mapPiEntry(sess, j) {
  const t = sess.tail;
  t.lastActivity = Date.now();          // any log line means the run is alive
  if (j.type !== "message") return;
  const m = j.message ?? {};
  const role = m.role;
  const content = Array.isArray(m.content) ? m.content : [];
  if (role === "user") {
    let text = "";
    for (const c of content) if (c.type === "text") text += c.text;
    text = text.replace(/^\[slapp context[^\]]*\]\s*/, "").trim();
    if (!text) return;
    if (/--model|--thinking|\.jsonl/.test(text)) return;   // the launch echo, not a word
    t.userSeen++; t.reply = ""; t.thinkBlocks = 0;
    sess.busy = true; sess.rpcBusy = true;
    push(sess, { type: "user", text: text.slice(0, 2000) });
    return;
  }
  if (role !== "assistant") {
    if (role === "toolResult") {
      if (t.inHistory) push(sess, { type: "tool", name: "tool", phase: "end", ok: !m.isError });
    }
    return;
  }
  let text = "", tools = 0;
  for (const c of content) {
    if (c.type === "thinking") {
      t.thinkBlocks++;
      const d = String(c.thinking ?? "").trim();
      if (d && t.inHistory) push(sess, { type: "thinking", text: d.slice(-1400) });
      if (t.thinkBlocks >= 60) {   // thought-loop watchdog, pane edition
        paneSend(sess, "", "Escape");
        push(sess, { type: "status", text: "stopped this run — it was thinking in circles. Nudge it or say it again." });
        t.thinkBlocks = 0;
      }
    } else if (c.type === "toolCall") {
      tools++;
      if (t.inHistory) push(sess, { type: "tool", tid: c.id, name: c.name, preview: argsPreview(c.name, c.arguments), phase: "start" });
    } else if (c.type === "text") {
      text += c.text;
    }
  }
  if (text && tools === 0) {
    // a message with words and no tools is the run's final word
    sess.busy = false; sess.rpcBusy = false;
    t.reply = text;
    push(sess, { type: "done", text: text.slice(-4000) });
    takeScreenshot(sess).catch(() => {});
  }
}

// type into the pane — agent prompt types literal text (bracketed paste
// + Enter, lifecycle-aware); special keys go through send-keys
function paneSend(sess, text, special = null) {
  if (!sess.herdr?.paneId) return false;
  if (text) run("herdr", ["agent", "prompt", sess.herdr.paneId, text]).catch(() => {});
  else if (special) run("herdr", ["pane", "send-keys", sess.herdr.paneId, special]).catch(() => {});
  return true;
}

async function attachPi(sess, resume = false) {
  // the pane IS the pi instance — a real TUI on the Mac, same session the
  // phone types into. The RPC child below is only for when herdr is gone.
  try { await herdrTab(sess); } catch {}
  if (sess.herdr?.paneId) {
    startTail(sess);
    sess.phase = "ready"; sess.busy = false; sess.rpcBusy = false;
    return;
  }
  push(sess, { type: "status", text: "no herdr pane — headless fallback" });
  const args = ["--mode", "rpc"];
  if (sess.selfSessionId) args.push("--session-id", sess.selfSessionId);
  else if (resume) args.push("-c");            // continue the project's most recent session
  else args.push("-n", sess.name);        // fresh session, named after the app
  const mdl = (sess.model?.provider && sess.model?.id) ? sess.model : (await pinnedModel());
  if (mdl?.provider && mdl?.id) args.push("--model", `${mdl.provider}/${mdl.id}`);
  if (sess.thinking !== null) args.push("--thinking", sess.thinking ?? "medium"); // medium everywhere; null = flash model, no thinking

  const child = spawn("pi", args, { cwd: sess.dir, stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, PATH: process.env.PATH + ":" + os.homedir() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin" } });
  sess.pi = child;
  sess.rpcBusy = false;
  sess.rpcPending = new Map();
  child.on("error", (e) => { // e.g. pi missing from PATH under LaunchAgents
    push(sess, { type: "error", text: "couldn't start pi: " + String(e?.message ?? e).slice(0, 120) });
    sess.pi = null; sess.busy = false; sess.rpcBusy = false;
  });

  let buf = "";
  let currentReply = "";
  let runHadAction = false;
  let emptyStreak = 0;
  const born = Date.now();
  child.stdout.on("data", (d) => {
    buf += d.toString();
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      if (!line.trim()) continue;
      let m; try { m = JSON.parse(line); } catch { continue; }
      if (m.type === "response") {
        const p = m.id && sess.rpcPending.get(m.id);
        if (p) { sess.rpcPending.delete(m.id); p(m); }
        continue;
      }
      switch (m.type) {
        case "message_update": {
          const ame = m.assistantMessageEvent ?? {};
          if (ame.type === "text_delta") { currentReply += ame.delta; runHadAction = true; push(sess, { type: "delta", text: ame.delta }); }
          else if (ame.type === "thinking_delta") {
            push(sess, { type: "thinking", text: ame.delta });
            sess.thinkCount = (sess.thinkCount || 0) + 1;
            if (sess.thinkCount === 4000) {
              rpcSend(sess, { type: "abort" });
              push(sess, { type: "status", text: "stopped this run — it was thinking in circles without doing anything. Nudge it (the run button) or say it again." });
              sess.thinkCount = 0;
            }
          }
          break;
        }
        case "tool_execution_start": {
          runHadAction = true;
          const a = m.args ?? {};
          let preview = "";
          if (m.toolName === "bash") preview = String(a.command ?? "").replace(/\s+/g, " ").trim().slice(0, 120);
          else if (a.path) preview = String(a.path).split("/").slice(-2).join("/");
          else if (a.command) preview = String(a.command).slice(0, 120);
          push(sess, { type: "tool", tid: m.toolCallId, name: m.toolName, preview, phase: "start" });
          break;
        }
        case "tool_execution_end":
          push(sess, { type: "tool", tid: m.toolCallId, name: m.toolName, phase: "end", ok: !m.isError });
          break;
        case "agent_start":
          sess.rpcBusy = true; sess.busy = true; currentReply = ""; runHadAction = false;
          push(sess, { type: "status", text: "thinking" });
          sess.thinkCount = 0;
          break;
        case "agent_end": {
          sess.rpcBusy = false; sess.busy = false;
          push(sess, { type: "done", text: currentReply.slice(-4000) });
          currentReply = "";
          takeScreenshot(sess).catch(() => {});
          // stall guard: the model occasionally returns empty completions;
          // nudge exactly once, then hand it back to the user
          if (!runHadAction) {
            emptyStreak++;
            if (emptyStreak === 1) {
              push(sess, { type: "status", text: "the model went quiet — nudging once" });
              sess.rpcBusy = sess.busy = true;
              rpcSend(sess, { type: "prompt", message: "continue — finish what you were doing", streamingBehavior: "followUp" });
            } else if (emptyStreak > 2) {
              push(sess, { type: "error", text: "model returned empty runs — send a message to nudge it" });
            }
          } else emptyStreak = 0;
          break;
        }
        default: break;
      }
    }
  });
  child.stderr.on("data", (d) => {
    const s = d.toString().trim();
    if (s) push(sess, { type: "status", text: "pi: " + s.split("\n")[0].slice(0, 160) });
  });
  child.on("exit", (code) => {
    sess.pi = null; sess.rpcBusy = false; sess.busy = false;
    if (Date.now() - born < 2000 && resume) {
      push(sess, { type: "status", text: "no earlier session here — starting fresh" });
      attachPi(sess, false).catch(() => {});
      return;
    }
    if (sess.phase !== "error") {
      sess.phase = "error";
      push(sess, { type: "error", text: "pi stopped — restart slappd or hit restart in the app" });
    }
  });
  push(sess, { type: "status", text: `pi attached — ${mdl ? `${mdl.provider}/${mdl.id}` : "snail-top 256k"} · ${sess.thinking === null ? "flash (no thinking)" : (sess.thinking ?? "medium")} thinking` });
}

function rpcSend(sess, cmd) {
  try { sess.pi?.stdin?.write(JSON.stringify(cmd) + "\n"); } catch {}
}

async function sendPrompt(sess, text, image = null) {
  try {
    const raw = String(text ?? "").trim();
    if (!raw && !image) throw new Error("empty prompt");
    // the cap: how many agents may be working at once. an agent already
    // mid-run can keep talking (follow-ups queue); a NEW run waits its turn.
    // the words still land in the chat — then the refusal under them.
    if (!sess.busy && !sess.launcher) {
      const n = workingCount();
      if (n >= maxSessions) {
        push(sess, { type: "user", text: raw, hasImage: !!image });
        push(sess, { type: "error", text:
          `you've hit the cap — ${n} agents are already working (max ${maxSessions}). wait for one to finish, or raise the cap in settings → sessions.` });
        log(`${sess.slug}: prompt refused — ${n}/${maxSessions} working`);
        return;
      }
    }

    // Context prefix — orient the agent before it acts. Built by slappContext().
    let notePath = null;
    if (image?.imageB64) {
      notePath = path.join(sess.dir, ".slapp", `note-${Date.now()}.png`);
      try { fs.writeFileSync(notePath, Buffer.from(image.imageB64, "base64")); } catch { notePath = null; }
    }
    // the context counter rides with the message: first word → full
    // orientation, every 10th → reminder, otherwise bare words
    const seen = sess.ctxCount ?? 0;
    sess.ctxCount = seen + 1;
    persistSessions();
    const ctx = slappPrefix(sess, seen, notePath, image?.plain);
    const full = ctx ? `${ctx}\n\n${raw || "(no caption — see the attached annotated screenshot)"}`
                     : (raw || "(no caption — see the attached annotated screenshot)");

    // THE REAL THING: type into the living pane — the actual pi TUI you'd
    // type at on the Mac. The tail (mapPiEntry) single-sources the user
    // event and the whole play-by-play from pi's own session log.
    if (!sess.herdr?.paneId) { try { await herdrTab(sess); } catch {} }
    if (sess.herdr?.paneId) {
      sess.busy = true; sess.rpcBusy = true;
      paneSend(sess, full.replace(/\s*\n\s*/g, " "));  // one line — Return submits
      return;
    }

    // headless fallback, only when herdr is truly unreachable
    if (!sess.pi) throw new Error("pi session not attached");
    push(sess, { type: "user", text: raw, hasImage: !!image });
    const cmd = { type: "prompt", message: full };
    if (sess.rpcBusy) cmd.streamingBehavior = "followUp"; // mid-run → queue it
    if (image?.imageB64)
      // pi's ImageContent is FLAT ({type,data,mimeType}) — a nested source:{}
      // shape silently becomes data:undefined and 400s.
      cmd.images = [{ type: "image", data: image.imageB64, mimeType: image.mediaType || "image/jpeg" }];
    rpcSend(sess, cmd);
    sess.busy = true;
  } catch (e) {
    push(sess, { type: "error", text: "couldn't send: " + String(e?.message ?? e).slice(0, 160) });
    sess.busy = false; sess.rpcBusy = false;
  }
}

// ── voice ───────────────────────────────────────────────────────────────────
// painterly hues — the same Cells palette the phone uses (Design.swift):
// BigInt djb2 over utf8 bytes, &* 33 &+ byte, mod 8
const CELL_HUES = [0.53, 0.58, 0.40, 0.19, 0.08, 0.97, 0.14, 0.45];
const CELL_SATS = [0.62, 0.55, 0.58, 0.85, 0.95, 0.78, 0.88, 0.50];
function cellsColor(slug) {
  let h = 5381n;
  for (const b of Buffer.from(slug, "utf8")) h = (h * 33n + BigInt(b)) & 0xFFFFFFFFFFFFFFFFn;
  const i = Number(h % BigInt(CELL_HUES.length));
  return { hue: CELL_HUES[i], sat: CELL_SATS[i] };
}

// ── the nanny: fleet transitions + state ──
// notable fleet events, newest first — the launch agent reads these at each
// babysit check, and /api/fleet carries them for anything else watching
let fleetNotes = [];
function fleetNote(slug, text) {
  fleetNotes.unshift({ t: Date.now(), slug, text });
  if (fleetNotes.length > 40) fleetNotes.length = 40;
}

function fleetRow(sx) {
  const last = sx.log[sx.log.length - 1];
  return {
    slug: sx.slug, name: sx.name, busy: !!sx.busy, phase: sx.phase, asleep: !!sx.asleep,
    kind: sx.kind ?? "ios", babysit: !!sx.babysitTimer, building: !!sx.building,
    model: sx.model ? `${sx.model.provider}/${sx.model.id}` : null,
    lastActivityAgeS: sx.lastActivity ? Math.max(0, Math.round((Date.now() - sx.lastActivity) / 1000)) : null,
    lastLine: (() => {
      const t = last ? String(last.text ?? last.preview ?? "") : "";
      if (/(--model|--thinking|\.jsonl)/.test(t) || /^\s*$/.test(t)) return null;
      return `${last.type}: ${t.slice(-140)}`;
    })(),
    watch: (sx.watchTasks || []).map(t => ({ goal: String(t.goal || "").slice(0, 120), endsInMin: Math.max(0, Math.round((t.endsAt - Date.now()) / 60000)) })),
  };
}

async function transcribe(file) {
  if (SNAIL_KEY) {
    try {
      return await transcribeSnail(file);
    } catch (e) {
      console.log("[voice] snail-api dictate failed, using local whisper:",
        String(e?.message ?? e).slice(0, 200));
    }
  }
  return transcribeLocal(file);
}

async function transcribeSnail(file) {
  const buf = await fsp.readFile(file);
  const boundary = "----slappd" + randomUUID().replace(/-/g, "");
  const body = Buffer.concat([
    Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="voice.wav"\r\nContent-Type: audio/wav\r\n\r\n`),
    buf,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  const res = await fetch(`${SNAIL_API}/v1/audio/dictate`, {
    method: "POST",
    headers: { "Authorization": `Bearer ${SNAIL_KEY}`,
               "Content-Type": `multipart/form-data; boundary=${boundary}` },
    body,
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const j = await res.json();
  const text = (j.text || "").trim();
  if (!text) throw new Error("no speech found in audio");
  return text;
}

async function transcribeLocal(file) {
  const id = randomUUID().slice(0, 8);
  const outDir = path.join(os.tmpdir(), "slappd-voice");
  await fsp.mkdir(outDir, { recursive: true });
  const r = await run(MLX_WHISPER, [file, "--model", WHISPER_MODEL,
    "--output-format", "json", "--output-dir", outDir, "--output-name", id]);
  if (r.code) throw new Error("whisper failed: " + r.stderr.slice(0, 300));
  const j = JSON.parse(await fsp.readFile(path.join(outDir, `${id}.json`), "utf8"));
  const text = (j.text ?? (j.segments ?? []).map(s => s.text).join(" ") ?? "").trim();
  if (!text) throw new Error("no speech found in audio");
  return text;
}

// ── http ────────────────────────────────────────────────────────────────────
function readBody(req, limit = 25 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    req.on("data", (c) => { size += c.length; if (size > limit) { reject(new Error("body too large")); req.destroy(); } else chunks.push(c); });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

const json = (res, code, obj) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };

function slappContext(sess, notePath = null, plain = false) {
  const age = sess.lastShotAt ? `${Math.max(0, Math.round((Date.now() - sess.lastShotAt) / 1000))}s ago` : null;
  const screen = fs.existsSync(sess.screenPath)
    ? `a screenshot of what the user is looking at sits at ${sess.screenPath}${age ? ` (taken ${age})` : ""} — READ it to see their screen.`
    : "";
  const note = notePath
    ? `the user attached an image${plain ? "" : " with markup marks (circles/arrows)"} — it is saved at ${notePath}, and is also embedded with this message; READ the file or image to see exactly what they sent`
    : "no attachment";
  return `[slapp · you are "${sess.name}", a live session on this Mac, driven from a phone over Tailscale — words arrive as they're typed. ` +
    `project dir: ${sess.dir} · repo: ${sess.repo ?? "none"}. ` +
    `you can deliver media in this chat: save an image or audio file under the project dir and mention its path in your reply — the phone shows it as a photo or playable audio. ` +
    (screen ? screen + " " : "") + note + "]";
}

// the context the model gets with each word — the FULL orientation lands
// once at the start of a conversation, then just a reminder every 10th
// message; anything more is cloud in the context. `seen` = messages already
// sent before this one.
function slappPrefix(sess, seen, notePath = null, plain = false) {
  if (seen === 0) return slappContext(sess, notePath, plain);
  if (seen % 10 === 0) return "[slapp · reminder]";
  return null;
}

async function createSession(req, res) {
  const body = JSON.parse((await readBody(req, 1e6)).toString() || "{}");

  // model + reasoning per session, chosen by whoever creates it (the
  // launcher picks per task; humans pick in the app). workers default to
  // the fleet (snail-top 256k, medium); the launcher defaults to NextMac131.
  const modelPick = body.model ? String(body.model).split("/") : null;
  const thinkingPick = body.thinking === null || body.thinking === "none" ? null
    : body.thinking ? String(body.thinking) : undefined;

  // bind a session to an EXISTING project folder — no scaffold, no new repo.
  // this is how the whole pipeline (voice, builds, real-watch installs)
  // ports onto projects born outside slapp. {existing: "<project>"}
  if (body.existing) {
    const raw = String(body.existing);
    const dir = raw.startsWith("/") ? raw : path.join(BASE_DIR, raw);
    if (!fs.existsSync(dir)) return json(res, 404, { error: `no folder at ${dir}` });
    const name = String(body.name || path.basename(dir)).trim();
    let slug = slugify(path.basename(dir));
    // a live claim of slapp's own repo is slapp itself — one pencil, the
    // one the app's this-session button already opens
    if (body.live && slug === "slapp" && sessions.has("slapp-itself")) slug = "slapp-itself";
    let sess = sessions.get(slug);
    if (!sess) {
      sess = newSess(name, body.kind === "watch" ? "watch" : "ios", slug);
      if (!sess) return json(res, 409, { error: "that project already has a session" });
      sess.dir = dir;
      sessions.set(slug, sess);
    }
    if (body.live && body.live.port) {
      // LIVE: the claimant is a real pi session running the slapp extension
      // (/slapp in the CLI). It stays the one and only runtime — the daemon
      // keeps no pane, spawns no pi; phone words relay to it, its replies
      // stream back out through the tail following its session file.
      sess.dir = dir;
      if (slug !== "slapp-itself") sess.name = name;   // keep the familiar name
      sess.live = { port: Number(body.live.port) || 0, token: String(body.live.token || "") };
      if (modelPick) sess.model = { provider: modelPick[0], id: modelPick[1] };
      if (thinkingPick !== undefined) sess.thinking = thinkingPick;
      sess.asleep = false; sess.phase = "ready"; sess.busy = false; sess.rpcBusy = false;
      if (sess.pi) { try { sess.pi.kill(); } catch {} sess.pi = null; }
      persistSessions();
      json(res, 200, { slug: sess.slug, name: sess.name, dir: sess.dir, live: true });
      (async () => {
        try {
          bridgeSync(sess.slug, sess.name).catch(() => {});   // the pencil
          if (sess.tail) { clearInterval(sess.tailTimer); sess.tail = null; }
          startTail(sess);
          push(sess, { type: "status", text: "wired to your desk session — words from the phone land in that conversation, its replies stream back here" });
          log(`${sess.slug}: LIVE — relay to :${sess.live.port} (the human's own pi session)`);
        } catch (e) { log(`${sess.slug}: live bind failed: ${e?.message ?? e}`); }
      })();
      return;
    }
    if (!sess.pi && !sess.herdr?.paneId) {
      if (modelPick) sess.model = { provider: modelPick[0], id: modelPick[1] };
      if (thinkingPick !== undefined) sess.thinking = thinkingPick;
    }
    bridgeSync(sess.slug, sess.name).catch(() => {});   // (re-)bind heals a lost pencil
    json(res, 200, { slug: sess.slug, name: sess.name, dir: sess.dir, kind: sess.kind });
    (async () => {
      try {
        if (fs.existsSync(path.join(dir, ".git"))) {
          const r = await run("git", ["remote", "get-url", "origin"], { cwd: dir });
          if (!r.code) sess.repo = r.stdout.trim();
        }
        push(sess, { type: "status", text: `bound to existing project ${path.basename(dir)} — no scaffold, your repo, your rules` });
        bridgeSync(sess.slug, sess.name).catch(() => {});   // the pencil must exist the moment it's bound
        herdrTab(sess);
        await attachPi(sess);
        sess.phase = "ready";
        push(sess, { type: "status", text: "existing project attached — talk to change it, build to ship it" });
      } catch (e) {
        sess.phase = "error";
        push(sess, { type: "error", text: String(e?.message ?? e).slice(0, 300) });
      }
    })().catch(() => {});
    return;
  }

  // THE LAUNCHER — the session whose job is sessions. It owns the skills
  // (consolidate, improve, alter), launches workers with the right skills,
  // model, and reasoning per task, and babysits on request. One, idempotent.
  if (body.launcher) {
    const existing = sessions.get("launcher");
    if (existing) return json(res, 200, { slug: existing.slug, name: existing.name, dir: existing.dir, kind: existing.kind, model: "snail-api/NextMac131" });
    const dir = path.join(BASE_DIR, "launcher");
    fs.mkdirSync(path.join(dir, ".slapp"), { recursive: true });
    fs.writeFileSync(path.join(dir, "AGENTS.md"), LAUNCHER_CHARTER());
    const sess = newSess("launcher", "ios", "launcher");
    if (!sess) return json(res, 409, { error: "launcher already exists" });
    sess.dir = dir;
    sess.model = { provider: "snail-api", id: "NextMac131" }; // the picker's MacFast131 — fast launcher brain
    sess.thinking = null;                                     // flash model: no thinking tax
    sess.launcher = true;
    json(res, 200, { slug: sess.slug, name: sess.name, dir: sess.dir, kind: sess.kind, model: "snail-api/NextMac131" });
    (async () => {
      try {
        push(sess, { type: "status", text: "the launcher is awake — skills are its ledger, sessions its crew" });
        herdrTab(sess);
        bridgeSync(sess.slug, sess.name).catch(() => {});
        await attachPi(sess);
        sess.phase = "ready";
        push(sess, { type: "status", text: "ready — name a mission and it ships a crewed session" });
      } catch (e) {
        sess.phase = "error";
        push(sess, { type: "error", text: String(e?.message ?? e).slice(0, 300) });
      }
    })().catch(() => {});
    return;
  }

  // the meta door: a session bound to slapp's own source — this conversation,
  // through the app. exists once, idempotent, no scaffold, no new repo.
  if (body.self) {
    // the live desk session (if claimed) IS this session — the button opens
    // the conversation the human is actually sitting in
    const liveSelf = [...sessions.values()].find(x => x.live?.port && x.dir === (process.env.SLAPP_SELF_DIR || path.join(BASE_DIR, "Slapp")));
    if (liveSelf) return json(res, 200, { slug: liveSelf.slug, name: liveSelf.name, dir: liveSelf.dir, kind: liveSelf.kind, live: true });
    const existing = sessions.get("slapp-itself");
    if (existing) {
      // heal the idempotent door: a meta session without its bridge channel
      // (or token) repairs itself here instead of showing ghosts on the phone
      if (!existing.bridgeToken) {
        existing.bridgeToken = randomUUID().replace(/-/g, "");
        persistSessions();
        bridgeSync(existing.slug, existing.name).catch(() => {});
      }
      // the pin: slapp itself is ONE conversation — same session id every
      // time, so phone words always land in the same line, never a random
      // project session grabbed by blind -c
      if (!existing.selfSessionId) {
        existing.selfSessionId = randomUUID();
        persistSessions();
      }
      return json(res, 200, { slug: existing.slug, name: existing.name, dir: existing.dir, kind: existing.kind });
    }
    const dir = process.env.SLAPP_SELF_DIR || path.join(BASE_DIR, "Slapp");
    if (!fs.existsSync(dir)) return json(res, 500, { error: "slapp's own folder not found" });
    const sess = newSess("slapp, itself", "ios", "slapp-itself");
    if (!sess) return json(res, 409, { error: "slapp itself already exists" });
    sess.dir = dir; // override: live in the source repo
    sess.self = true; // no canvas, no simulator — it IS the builder
    sess.selfSessionId = randomUUID(); // the pin — one conversation, forever
    json(res, 200, { slug: sess.slug, name: sess.name, dir: sess.dir, kind: sess.kind });
    (async () => {
      try {
        push(sess, { type: "status", text: "opening slapp's own source" });
        sess.repo = "https://github.com/Snail3D/Slapp";
        sess.bridgeToken = sess.bridgeToken || randomUUID().replace(/-/g, "");
        persistSessions();
        bridgeSync(sess.slug, sess.name).catch(() => {});
        herdrTab(sess);
        await attachPi(sess);
        sess.phase = "ready";
        push(sess, { type: "status", text: "this is the conversation that builds slapp itself — talk" });
        if (body.prompt) sendPrompt(sess, String(body.prompt));
      } catch (e) {
        sess.phase = "error";
        push(sess, { type: "error", text: String(e?.message ?? e).slice(0, 400) });
      }
    })().catch(() => {});
    return;
  }

  const name = String(body.name || "").trim();
  if (!name) return json(res, 400, { error: "Give it a name first." });
  const kind = body.kind === "watch" ? "watch" : "ios";
  const sess = newSess(name, kind);
  if (!sess) return json(res, 409, { error: `You already have an app called "${name}". Pick a slightly different name.` });
  json(res, 200, { slug: sess.slug, name: sess.name, dir: sess.dir, kind: sess.kind });

  // the whole "automatic when it starts" flow — in the background
  (async () => {
    try {
      push(sess, { type: "status", text: `opening folder ${path.basename(sess.dir)}` });
      await scaffoldProject(sess);
      herdrTab(sess); // best-effort, not awaited to completion
      await attachPi(sess);
      await buildAndLaunch(sess);
      if (body.prompt) sendPrompt(sess, String(body.prompt));
    } catch (e) {
      sess.phase = "error";
      push(sess, { type: "error", text: String(e?.message ?? e).slice(0, 400) });
    }
  })().catch(() => {});
}

async function sse(req, res, sess) {
  // no CORS wildcard: native clients ignore CORS, but a browser tab could
  // otherwise read session transcripts from any origin
  res.writeHead(200, {
    "content-type": "text/event-stream", "cache-control": "no-cache",
    connection: "keep-alive",
  });
  res.write(`data: ${JSON.stringify({ type: "hello", slug: sess.slug, phase: sess.phase, busy: sess.busy })}\n\n`);
  for (const ev of sess.log.slice(-100)) res.write(`data: ${JSON.stringify(ev)}\n\n`);
  const client = { res };
  sess.clients.add(client);
  herdrTab(sess); // opening a session on the phone (re)attaches its live space
  req.on("close", () => sess.clients.delete(client));
}

const server = http.createServer(async (req, res) => {
  try {
    const u = new URL(req.url, `http://127.0.0.1:${PORT}`);
    const p = u.pathname;
    const t0 = Date.now();
    res.on("finish", () => log(`${req.method} ${p} → ${res.statusCode} (${Date.now() - t0}ms)`));
    if (TOKEN) {
      const supplied = req.headers["x-slapp-token"] ?? u.searchParams.get("token") ?? "";
      if (!tokenOk(supplied)) return json(res, 401, { error: "This Mac is locked. Put the same SLAPP_TOKEN into Slapp's settings." });
    }
    // browsers always send Origin on cross-origin POSTs; native apps never do.
    // blocking mismatched origins stops drive-by prompts from random web pages.
    if (req.method === "POST" && req.headers.origin) {
      let sameOrigin = false;
      try { sameOrigin = new URL(req.headers.origin).host === req.headers.host; } catch {}
      if (!sameOrigin) return json(res, 403, { error: "cross-origin posts are blocked" });
    }
    if (req.method === "GET" && p === "/api/models") {
      try {
        sharedModelRuntime ??= await ModelRuntime.create();
        const avail = await sharedModelRuntime.getAvailable();
        const list = avail
          .filter(m => m.provider && m.id)
          .map(m => ({ provider: m.provider, id: m.id, name: m.name ?? m.id }));
        return json(res, 200, list);
      } catch (e) { return json(res, 500, { error: String(e?.message ?? e).slice(0, 200) }); }
    }
    if (req.method === "GET" && p === "/api/health")
      return json(res, 200, { ok: true, version: 2, secured: !!TOKEN,
        maxSessions, active: workingCount(),
        sessions: [...sessions.values()].map(s => ({ slug: s.slug, busy: s.busy, phase: s.phase, asleep: !!s.asleep })) });
    if (req.method === "GET" && p === "/api/context") {
      // the starting context for a session — the pane's /slapp injects this
      const cwd = u.searchParams.get("cwd") ?? "";
      const sess = [...sessions.values()].find(x => cwd && (x.dir === cwd || cwd.startsWith(x.dir + path.sep)));
      if (!sess) return json(res, 404, { error: "no session lives here" });
      return json(res, 200, { context: slappContext(sess) });
    }
    if (req.method === "POST" && p === "/api/live") {
      // loopback only — this is the pane pi TUIs whispering their thinking
      if (!req.socket.remoteAddress?.endsWith("127.0.0.1")) return json(res, 403, { error: "local only" });
      let body = {};
      try { body = JSON.parse((await readBody(req, 1e5)).toString() || "{}"); } catch {}
      const cwd = String(body.cwd || "");
      const sess = [...sessions.values()].find(x => cwd && (x.dir === cwd || cwd.startsWith(x.dir + path.sep)));
      if (!sess) { log(`[live] no session for cwd: ${JSON.stringify(cwd)}`); return json(res, 404, { error: "no session lives here" }); }
      if (body.type === "thinking" && body.text) {
        push(sess, { type: "thinking", text: String(body.text).slice(-1400) });
      } else if (body.type === "tool" && body.preview) {
        push(sess, { type: "tool", preview: String(body.preview).slice(0, 110), phase: "start" });
      }
      return json(res, 200, { ok: true });
    }
    if (req.method === "POST" && p === "/api/pairwindow") {
      // the phone lost its bridge identity — open the bridge's pairing
      // window so its next re-register knock lands (app asks automatically
      // during a heal)
      try {
        const r = await fetch(`${SLAPP_BRIDGE}/devices/pair`, { method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${await bridgeAuth()}` },
          body: JSON.stringify({ window_s: 300 }) });
        log(`pairing window opened on the bridge (${r.status})`);
        return json(res, r.status === 200 ? 200 : 502, { ok: r.status === 200 });
      } catch { return json(res, 502, { ok: false, error: "bridge unreachable" }); }
    }
    if (req.method === "POST" && p === "/api/maxsessions") {
      let body = {};
      try { body = JSON.parse((await readBody(req, 1e4)).toString() || "{}"); } catch {}
      const n = Number(body.n);
      if (!Number.isInteger(n) || n < 1 || n > 12) return json(res, 400, { error: "pick a number from 1 to 12" });
      maxSessions = n; persistMaxSessions();
      log(`cap set: ${n} working slots`);
      return json(res, 200, { ok: true, maxSessions });
    }
    if (req.method === "GET" && p === "/api/sessions")
      return json(res, 200, [...sessions.values()].map(s => ({
        slug: s.slug, name: s.name, dir: s.dir, repo: s.repo, createdAt: s.createdAt,
        busy: s.busy, phase: s.phase, kind: s.kind ?? "ios", hasScreen: fs.existsSync(s.screenPath),
        last: s.log.length ? s.log[s.log.length - 1] : null,
      })));
    if (req.method === "POST" && p === "/api/session") return createSession(req, res);

    // ── the share card: a public, tasteful page for an app you built ──
    const sm = p.match(/^\/s\/([\w-]+)$/);
    if (req.method === "GET" && sm) {
      const sess = sessions.get(sm[1]);
      if (!sess) { res.writeHead(404); return res.end("not found"); }
      const shot = fs.existsSync(sess.screenPath)
        ? `<img src="/api/session/${sess.slug}/screen" alt="${esc(sess.name)}">`
        : `<div class="noimg">canvas warming up</div>`;
      res.writeHead(200, { "content-type": "text/html" });
      return res.end(`<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>${esc(sess.name)} — built with Slapp</title>
<meta property="og:title" content="${esc(sess.name)}">
<meta property="og:description" content="Built by voice with Slapp — talk, and it's on your phone.">
<style>
  :root{--bg:#07070a;--fg:#f5f1e3;--mut:#8f8e8a;--lime:#c7f04d}
  *{box-sizing:border-box;margin:0}
  body{background:var(--bg);color:var(--fg);font:16px/1.5 Georgia,serif;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:40px 20px}
  .card{max-width:420px;width:100%;text-align:center}
  img,.noimg{width:100%;border-radius:28px;border:1px solid #ffffff22;display:block;box-shadow:0 24px 80px #c7f04d22}
  .noimg{padding:80px 0;color:var(--mut);font-style:normal;font:14px ui-monospace,monospace}
  h1{font-size:34px;margin:28px 0 6px;font-weight:700}
  .slug{font:13px ui-monospace,monospace;color:var(--mut)}
  .made{margin-top:36px;font:14px ui-monospace,monospace;color:var(--mut)}
  .made b{color:var(--lime);font-weight:600}
</style>
<div class="card">
  ${shot}
  <h1>${esc(sess.name)}</h1>
  <div class="slug">${esc(sess.slug)}</div>
  <div class="made">built by voice with <b>slapp.</b></div>
</div>`);
    }
    // ── transcribe without a session: the wrist talks, a new app is born ──
    const vm = p.match(/^\/api\/voice$/);
    if (req.method === "POST" && vm) {
      const fmt = (u.searchParams.get("format") || "m4a").replace(/[^a-z0-9]/gi, "");
      try {
        const buf = await readBody(req);
        const file = path.join(os.tmpdir(), `slappd-voice-${randomUUID().slice(0, 8)}.${fmt}`);
        await fsp.writeFile(file, buf);
        try {
          const transcript = await transcribe(file);
          return json(res, 200, { transcript });
        } finally { fsp.unlink(file).catch(() => {}); }
      } catch (e) {
        return json(res, 500, { error: String(e?.message ?? e).slice(0, 300) });
      }
    }
    // media road: serve a file from inside a session's project dir so the
    // phone can show photos and play audio the agent made
    const fm = p.match(/^\/api\/session\/([^/]+)\/file$/);
    if (fm && req.method === "GET") {
      const sess = sessions.get(fm[1]);
      const u = new URL(req.url, "http://x");
      const rel = u.searchParams.get("p") || "";
      if (!sess) { res.writeHead(404); return res.end("{}"); }
      const abs = path.resolve(sess.dir, rel);
      // readable roads: the session's own dir, plus the bridge's photo cache
      // (phone captures live there — the channel history references them)
      const roads = [path.resolve(sess.dir), path.join(os.homedir(), ".hermes-supabot", "cache", "images")];
      if (!roads.some(b => abs.toString().startsWith(b + path.sep))) { log(`[file] 403 escape: rel=${JSON.stringify(rel)}`); res.writeHead(403); return res.end("{}"); }
      const ext = path.extname(abs).toLowerCase();
      const types = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                      ".gif": "image/gif", ".webp": "image/webp", ".mp3": "audio/mpeg",
                      ".wav": "audio/wav", ".ogg": "audio/ogg", ".m4a": "audio/mp4",
                      ".flac": "audio/flac", ".aac": "audio/aac" };
      if (!types[ext] || !fs.existsSync(abs)) { res.writeHead(404); return res.end("{}"); }
      res.writeHead(200, { "Content-Type": types[ext] });
      fs.createReadStream(abs).pipe(res);
      return;
    }

    // the file road: a phone drops a file into the session's inbox, where
    // the agent (a real pi TUI in the project dir) can open and work with it
    const um = p.match(/^\/api\/session\/([^/]+)\/upload$/);
    if (um && req.method === "POST") {
      const sess = sessions.get(um[1]);
      if (!sess) return json(res, 404, { error: "no such session" });
      const raw = u.searchParams.get("filename") || "file.bin";
      const safe = raw.replace(/[^\w.\- ()]/g, "_").slice(-120);
      const dir = path.join(sess.dir, ".slapp", "inbox");
      await fsp.mkdir(dir, { recursive: true });
      const dest = path.join(dir, `${Date.now()}-${safe}`);
      // size cap: an unbounded pipe could fill the disk
      let size = 0, over = false;
      req.on("data", (c) => { size += c.length; if (size > MAX_UPLOAD) { over = true; req.destroy(); } });
      const ws = fs.createWriteStream(dest);
      req.pipe(ws);
      await new Promise((r) => { ws.on("finish", r); ws.on("error", r); req.on("error", r); });
      if (over) { fsp.unlink(dest).catch(() => {}); return json(res, 413, { error: "file too big" }); }
      log(`${sess.slug}: file landed in the inbox — ${safe}`);
      return json(res, 200, { ok: true, path: dest });
    }
    if (p === "/api/search" && req.method === "GET")
      return searchAllSessions((u.searchParams.get("q") || "").trim().toLowerCase(), res);

    // ── the button install page: how to wire the Action Buttons ──
    if (p === "/shortcut" && req.method === "GET") {
      const tsIp = (Object.values(os.networkInterfaces()).flat().find(i => i && i.family === "IPv4" && i.address.startsWith("100.")) || {}).address || "<your-macs-tailscale-ip>";
      const url = `http://${tsIp}:8123/api/launcher/say`;
      res.writeHead(200, { "content-type": "text/html" });
      return res.end(`<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>the button — slapp</title>
<style>
  body{background:#f4f0e6;color:#17150f;font:17px/1.55 Georgia,serif;max-width:620px;margin:0 auto;padding:40px 22px}
  h1{font-size:30px;margin:0 0 4px} h2{font-size:19px;margin:30px 0 6px}
  .url{font:13px/1.4 ui-monospace,monospace;background:#17150f;color:#c7f04d;padding:12px 14px;border-radius:12px;word-break:break-all;user-select:all}
  ol{padding-left:22px} li{margin:10px 0} .k{font:13px ui-monospace,monospace;background:#e6e0d0;padding:2px 7px;border-radius:6px}
  .note{color:#6b6555;font-size:14px}
</style>
<h1>the button</h1>
<p>Hold the Action Button, say a sentence, and the launch agent on this Mac hears it — from any app, from the wrist, from across the house. Its reply lands back on your phone as a notification.</p>
<h2>One-time setup, on the iPhone</h2>
<ol>
  <li>Open the <span class="k">Shortcuts</span> app → <span class="k">+</span> (new shortcut).</li>
  <li>Add action: <span class="k">Dictate Text</span>.</li>
  <li>Add action: <span class="k">Get Contents of URL</span> — paste this URL:<div class="url">${url}</div></li>
  <li>Set the method to <span class="k">POST</span>. Headers: leave alone. Body: <span class="k">JSON</span> — add a field named <span class="k">text</span> and set its value to <span class="k">Dictated Text</span>.</li>
  <li>Add action: <span class="k">Show Result</span> (so you see the reply confirmation).</li>
  <li>Name it <span class="k">slapp</span> and tap done.</li>
</ol>
<h2>Wire the Action Button</h2>
<ol>
  <li>Settings → <span class="k">Action Button</span> → choose <span class="k">Shortcut</span> → pick <span class="k">slapp</span>.</li>
  <li>On the Watch Ultra: Watch app → <span class="k">Action Button</span> → <span class="k">Shortcut</span> → <span class="k">slapp</span> (the shortcut syncs to the wrist automatically).</li>
</ol>
<h2>Use it</h2>
<p>Press the Action Button, speak, stop. The words fly to this Mac, the launch agent hears them mid-sentence, and it manages the fleet with them — start an app, check a build, wake a sleeper. Its answer arrives as a notification on whichever screen you're near.</p>
<p class="note">The button door is ${url} — anything that can POST text there talks to the launch agent. Guard it like a door: keep Tailscale on.</p>
`);
    }

    // ── the nanny's eyes: one call, the whole fleet ──
    if (p === "/api/fleet" && req.method === "GET") {
      const rows = [...sessions.values()].map(fleetRow);
      return json(res, 200, {
        now: Date.now(),
        counts: { total: rows.length, working: rows.filter(r => r.busy).length, asleep: rows.filter(r => r.asleep).length },
        sessions: rows,
        notes: fleetNotes.slice(0, Number(u.searchParams.get("notes") || 12)),
        actions: { say: "/api/launcher/say", restart: "/api/session/<slug>/restart", wake: "/api/session/<slug>/wake", prompt: "/api/session/<slug>/prompt" },
      });
    }

    // ── the button door: the Action Button (phone or wrist) talks here ──
    if (p === "/api/launcher/say" && req.method === "POST") {
      let text = "";
      const ct = String(req.headers["content-type"] || "");
      if (ct.includes("json")) {
        let b = {}; try { b = JSON.parse((await readBody(req, 1e5)).toString() || "{}"); } catch {}
        text = String(b.text ?? "").trim();
      } else {
        text = (await readBody(req, 1e5)).toString().trim();
      }
      if (!text) return json(res, 400, { error: "say something" });
      const launcher = sessions.get("launcher");
      if (!launcher) return json(res, 404, { error: "no launcher session on this Mac" });
      log(`[button] → launcher: ${text.slice(0, 90)}`);
      sendPrompt(launcher, text);
      return json(res, 200, { ok: true, note: "the launch agent heard you — its reply lands on your phone" });
    }
    const m = p.match(/^\/api\/session\/([^/]+)\/(events|log|prompt|voice|screen|restart|abort|model|tts|delete|build|babysit|slapp|monocle|watch|search|open|wake|reveal)$/);
    if (m) {
      const sess = sessions.get(m[1]);
      if (!sess) return json(res, 404, { error: "no such session" });
      const what = m[2];
      if (what === "restart" && req.method === "POST") {
        // fresh pi session, same project — for when the chat history is poisoned
        try { sess.pi?.kill("SIGTERM"); } catch {}
        sess.pi = null; sess.busy = false; sess.phase = "restoring"; sess.log = [];
        attachPi(sess).catch((e) => push(sess, { type: "error", text: "restart failed: " + String(e?.message ?? e).slice(0, 200) }));
        return json(res, 200, { restarted: true });
      }
      if (what === "model" && req.method === "POST") {
        const body = JSON.parse((await readBody(req, 1e6)).toString() || "{}");
        sharedModelRuntime ??= await ModelRuntime.create();
        const model = sharedModelRuntime.getModel(String(body.provider ?? ""), String(body.id ?? ""));
        if (!model) return json(res, 400, { error: "unknown model" });
        sess.model = { provider: body.provider, id: body.id };
        if (sess.pi) rpcSend(sess, { type: "set_model", provider: body.provider, modelId: body.id });
        persistSessions();
        push(sess, { type: "status", text: `model switched to ${model.name ?? body.id}` });
        return json(res, 200, { ok: true, model: model.name ?? body.id });
      }
      if (what === "abort" && req.method === "POST") {
        if (sess.busy || sess.pi) {
          if (sess.herdr?.paneId) {
            paneSend(sess, "", "Escape");
          } else {
            rpcSend(sess, { type: "abort" });
          }
          push(sess, { type: "status", text: "stopping — user asked to abort" });
          return json(res, 200, { aborting: true });
        }
        return json(res, 200, { aborting: false });
      }
      if ((what === "slapp" || what === "monocle") && req.method === "POST") {
        // the bridge fires its transcript here — authenticated by the channel's
        // own token, which this daemon minted when it created the channel
        const tok = req.headers["x-slapp-token"] ?? req.headers["x-monocle-token"] ?? "";
        if (!sess.bridgeToken || tok !== sess.bridgeToken) return json(res, 401, { error: "unauthorized" });
        let body = {};
        try { body = JSON.parse((await readBody(req, 3e7)).toString() || "{}"); } catch {}
        const text = String(body.text ?? "").trim();
        const photoPath = String(body.photo ?? "").trim();
        if (!text && !photoPath) return json(res, 400, { error: "no text" });
        sess.bridgeCtx = { device: String(body.device || "monocle"), channel: String(body.channel || "main") };
        json(res, 200, { ok: true });   // reply fast — the bridge is waiting
        if (photoPath && fs.existsSync(photoPath)) {
          // a photo from the phone: same road as dragging a screenshot into
          // pi. bring it down to what a vision model can actually see
          // (1568px JPEG) and hand it to the session as an attachment.
          const dest = path.join(sess.dir, ".slapp", `photo-${Date.now()}.jpg`);
          await new Promise((r) => {
            const sp = spawn("sips", ["-Z", "1568", "-s", "format", "jpeg",
                                      "-s", "formatOptions", "80", photoPath, "--out", dest]);
            sp.on("close", r); sp.on("error", r);
          });
          const b64 = fs.existsSync(dest) ? fs.readFileSync(dest).toString("base64") : null;
          push(sess, { type: "user", text: text || "(a photo)" });
          if (b64) {
            sendPrompt(sess, text, { imageB64: b64, mediaType: "image/jpeg", plain: true });
          } else {
            sendPrompt(sess, `${text}\n\n(the photo failed to decode — it was at ${photoPath})`);
          }
          return;
        }
        push(sess, { type: "user", text });
        sendPrompt(sess, text);
        return;
      }
      if (what === "watch") {
        if (!sess.launcher) return json(res, 400, { error: "only the launcher keeps a watch" });
        if (req.method === "GET") {
          const now = Date.now();
          return json(res, 200, { watches: (sess.watchTasks || []).map(t => ({
            id: t.id, slug: t.slug, goal: t.goal, hours: t.hours,
            minutesLeft: Math.max(0, Math.round((t.endsAt - now) / 60000)) })) });
        }
        const body = JSON.parse((await readBody(req, 1e6)).toString() || "{}");
        if (body.remove) {
          sess.watchTasks = (sess.watchTasks || []).filter(t => t.id !== body.remove);
          persistSessions();
          push(sess, { type: "status", text: "watch lifted" });
          return json(res, 200, { ok: true });
        }
        const slug = String(body.slug || "");
        const goal = String(body.goal || "").trim();
        const hours = Math.max(0.25, Math.min(24, Number(body.hours) || 2));
        if (!slug || !goal) return json(res, 400, { error: "need a session and a goal" });
        if (!sessions.has(slug)) return json(res, 404, { error: `no session called ${slug}` });
        const task = { id: randomUUID().slice(0, 8), slug, goal, hours, endsAt: Date.now() + hours * 3.6e6 };
        sess.watchTasks = [...(sess.watchTasks || []), task];
        startWatchTimer(sess);
        persistSessions();
        push(sess, { type: "status", text: `watching ${slug} for ${hours}h — goal: ${goal.slice(0, 80)}` });
        return json(res, 200, { ok: true, task });
      }
      if (what === "babysit" && req.method === "POST") {
        if (!sess.launcher) return json(res, 400, { error: "only the launcher babysits" });
        const body = JSON.parse((await readBody(req, 1e5)).toString() || "{}");
        const on = !!body.on;
        const intervalMin = Math.max(2, Math.min(60, Number(body.intervalMin) || 5));
        if (sess.babysitTimer) { clearInterval(sess.babysitTimer); sess.babysitTimer = null; }
        if (!on) { push(sess, { type: "status", text: "babysitting off" }); return json(res, 200, { on: false }); }
        startBabysit(sess, intervalMin);
        push(sess, { type: "status", text: `babysitting on — checking every ${intervalMin} min` });
        json(res, 200, { on: true, intervalMin });
        return;
      }
      if (what === "build" && req.method === "POST") {
        if (sess.building) return json(res, 409, { error: "already building — one at a time" });
        sess.building = true;
        json(res, 200, { building: true });
        (async () => {
          try {
            await buildAndLaunch(sess);
            if (sess.kind !== "watch" || !await findWatchDevice()) sess.phase = "ready";
          } catch (e) {
            sess.phase = "error";
            push(sess, { type: "error", text: String(e?.message ?? e).slice(0, 300) });
          } finally { sess.building = false; }
        })().catch(() => { sess.building = false; });
        return;
      }
      if ((what === "stop" || what === "abort") && req.method === "POST") {
        if (sess.live?.port) {
          const ok = await relayLive(sess, { kind: "stop", device: "phone", ts: Date.now() });
          push(sess, { type: "status", text: ok ? "stopping the run on the Mac" : "the desk session isn't listening" });
          return json(res, 200, { ok });
        }
        paneSend(sess, "", "Escape");
        push(sess, { type: "status", text: "stopping the run" });
        return json(res, 200, { ok: true });
      }
      if (what === "events" && req.method === "GET") return sse(req, res, sess);
      if (what === "log" && req.method === "GET") return json(res, 200, sess.log.slice(-200));
      if (what === "search" && req.method === "GET")
        return searchAllSessions((u.searchParams.get("q") || "").trim().toLowerCase(), res);
      if (what === "wake" && req.method === "POST") {
        log(`${m[1]}: wake request from the pencil`);
        fleetNote(m[1], `${sessions.get(m[1])?.name ?? m[1]} woke up`);
        const s2 = sessions.get(m[1]);
        if (s2?.live?.port) {
          const ok = await relayLive(s2, { kind: "notify", text: "woken from the phone", device: "phone", ts: Date.now() });
          if (ok) { s2.asleep = false; persistSessions(); }
          return json(res, 200, { ok, live: true });
        }
        if (s2?.selfSessionId && s2.herdr?.paneId) {
          // the pin: make the pane run slapp itself's own conversation —
          // a pre-pin pane may still hold a blind -c grab
          await run("herdr", ["pane", "run", s2.herdr.paneId, piTuiCommand(s2)]).catch(() => {});
          if (s2.tail) { s2.tail.file = null; s2.tail.offset = -1; }
          startTail(s2);
        }
        herdrTab(s2).catch(() => {});
        return json(res, 200, { ok: true });
      }
      if (what === "reveal" && req.method === "POST") {
        // bring the session's real herdr tab to the front on the Mac
        (async () => {
          if (!sess.herdr?.tabId) await herdrTab(sess).catch(() => {});
          if (sess.herdr?.tabId) {
            const r = await run("herdr", ["tab", "focus", sess.herdr.tabId]);
            log(`${m[1]}: reveal in herdr → ${r.code === 0 ? "front and center" : "failed"}`);
          }
        })().catch(() => {});
        return json(res, 200, { ok: true });
      }
      if (what === "open" && req.method === "POST") {
        // relaunch a past conversation in this session's real pane
        let body = {};
        try { body = JSON.parse((await readBody(req, 1e5)).toString() || "{}"); } catch {}
        const file = String(body.file || "");
        if (!file || !file.endsWith(".jsonl") || !fs.existsSync(file)) return json(res, 400, { error: "need a session file" });
        sess.sessionFile = file;
        sess.phase = "restoring";
        push(sess, { type: "status", text: "relaunching that conversation in the live space" });
        await herdrTab(sess).catch(() => {});
        if (sess.herdr?.paneId) {
          await run("herdr", ["pane", "send-keys", sess.herdr.paneId, "C-c"]).catch(() => {});
          run("herdr", ["pane", "run", sess.herdr.paneId, piTuiCommand(sess, true)]).catch(() => {});
          if (sess.tail) { sess.tail = null; clearInterval(sess.tailTimer); }
          startTail(sess);
          sess.phase = "ready";
          sess.busy = false; sess.rpcBusy = false;
          return json(res, 200, { ok: true });
        }
        return json(res, 500, { error: "no live space — open the session once first" });
      }
      if (what === "delete" && req.method === "POST") {
        stopLiveTraffic(sess);
        bridgeSync(sess.slug, sess.name, true).catch(() => {}); // tile folds on the phone
        // remove from the mosaic: stop pi, close the herdr tab, forget. The
        // folder survives unless purge — "delete everything" trashes it.
        const purge = u.searchParams.get("purge") === "1";
        try { sess.pi?.kill("SIGTERM"); } catch {}
        for (const p2 of sess.panes) { try { p2.end(); } catch {} }
        sess.panes.clear();
        if (sess.herdr?.tabId) await run("herdr", ["tab", "close", sess.herdr.tabId]);
        sessions.delete(sess.slug);
        persistSessions();
        log(`deleted ${sess.slug}${purge ? " (purged)" : ""}`);
        if (purge) {
          const tr = await run("osascript", ["-e",
            `tell application "Finder" to delete POSIX file ${JSON.stringify(sess.dir)}`]);
          if (tr.code) await fsp.rm(sess.dir, { recursive: true, force: true }).catch(() => {});
        }
        return json(res, 200, { deleted: true, purged: purge });
      }
      if (what === "tts" && req.method === "POST") {
        // the agent talks back: macOS `say` → aiff → m4a (aac)
        const body = JSON.parse((await readBody(req, 1e6)).toString() || "{}");
        const text = String(body.text ?? "").replace(/\s+/g, " ").trim().slice(0, 1200);
        if (!text) return json(res, 400, { error: "nothing to say" });
        const voice = String(process.env.SLAPP_VOICE || "").trim();
        const voiceArgs = voice ? ["-v", voice] : [];
        const rate = String(process.env.SLAPP_VOICE_RATE || "").trim();
        if (rate && /^\d+$/.test(rate)) voiceArgs.push("-r", rate);
        const id = randomUUID().slice(0, 8);
        const aiff = path.join(os.tmpdir(), `slappd-tts-${id}.aiff`);
        const m4a = path.join(os.tmpdir(), `slappd-tts-${id}.m4a`);
        const sp = await run("say", [...voiceArgs, "-o", aiff, text]);
        if (sp.code) return json(res, 500, { error: "speech failed" });
        const cv = await run("afconvert", [aiff, m4a, "-f", "m4af", "-d", "aac"]);
        if (cv.code || !fs.existsSync(m4a)) return json(res, 500, { error: "speech encode failed" });
        const data = await fsp.readFile(m4a);
        fsp.unlink(aiff).catch(() => {}); fsp.unlink(m4a).catch(() => {});
        res.writeHead(200, { "content-type": "audio/mp4", "cache-control": "no-store" });
        return res.end(data);
      }
      if (what === "prompt" && req.method === "POST") {
        // JSON (the phone, with optional annotated image) or plain text (the
        // herdr bridge — terminal lines need no escaping)
        const ctype = String(req.headers["content-type"] || "");
        let text = "", image = null;
        if (ctype.includes("text/plain")) {
          text = (await readBody(req, 1e6)).toString().trim();
        } else {
          const body = JSON.parse((await readBody(req, 30e6)).toString() || "{}");
          text = String(body.text ?? "");
          if (body.imageB64) image = { imageB64: body.imageB64, mediaType: body.mediaType };
        }
        if (!text && !image) return json(res, 400, { error: "empty message" });
        if (sess.live) {
          // the desk session owns this conversation — hand the words over
          const ok = await relayLive(sess, { kind: "capture", mode: "text", text, device: "phone", channel: sess.slug, ts: Date.now() });
          return json(res, ok ? 200 : 503, ok ? { queued: true, live: true } : { error: "the desk session isn't listening — run /slapp there" });
        }
        sendPrompt(sess, text, image);
        return json(res, 200, { queued: true });
      }
      if (what === "voice" && req.method === "POST") {
        const fmt = (u.searchParams.get("format") || "m4a").replace(/[^a-z0-9]/gi, "");
        const buf = await readBody(req);
        const file = path.join(os.tmpdir(), `slappd-voice-${randomUUID().slice(0, 8)}.${fmt}`);
        await fsp.writeFile(file, buf);
        try {
          const transcript = await transcribe(file);
          const clean = transcript.replace(/[^\p{L}\p{N}]/gu, "");
          if (clean.length < 2)
            return json(res, 422, { error: "didn't catch that — hold the mic and speak" });
          sendPrompt(sess, transcript);
          return json(res, 200, { transcript, queued: true });
        } catch (e) {
          return json(res, 500, { error: String(e?.message ?? e).slice(0, 300) });
        } finally { fsp.unlink(file).catch(() => {}); }
      }
      if (what === "screen" && req.method === "GET") {
        if (sess.self) return json(res, 404, { error: "the builder has no canvas — it is the canvas" });
        // capture ONLY when someone is watching this session — then the
        // foreground is enforced and the frame is honest. Background polls
        // (mosaic thumbs, wrist icons) serve the last honest frame instead of
        // screenshotting whatever else is frontmost on the shared sim.
        const watching = sess.clients.size > 0;
        const stale = !fs.existsSync(sess.screenPath) ||
          (Date.now() - fs.statSync(sess.screenPath).mtimeMs) > 4000;
        if (watching && (u.searchParams.get("fresh") === "1" || stale)) {
          try {
            const simId = await simIdFor(sess);
            const bundle = `com.snail3d.${sess.slug}`;
            if (simForeground.get(simId) !== bundle) {
              const lr = await run("xcrun", ["simctl", "launch", simId, bundle]);
              if (!lr.code) {
                simForeground.set(simId, bundle);
                await new Promise(r => setTimeout(r, 1600)); // let it render
              }
            }
          } catch {}
          await takeScreenshot(sess);
        }
        if (!fs.existsSync(sess.screenPath)) return json(res, 404, { error: "no screen yet" });
        // tiny icons for the wrist: ?w=120 serves a sips-downscaled copy
        const wantW = parseInt(u.searchParams.get("w") || "0", 10);
        if (wantW > 0 && wantW < 800) {
          const small = path.join(os.tmpdir(), `slapp-icon-${sess.slug}-${wantW}.png`);
          if (!fs.existsSync(small) || fs.statSync(small).mtimeMs < fs.statSync(sess.screenPath).mtimeMs) {
            const sr = await run("sips", ["-Z", String(wantW), sess.screenPath, "--out", small]);
            if (sr.code) return json(res, 500, { error: "icon resize failed" });
          }
          const smallData = await fsp.readFile(small);
          res.writeHead(200, { "content-type": "image/png", "cache-control": "no-store" });
          return res.end(smallData);
        }
        const data = await fsp.readFile(sess.screenPath);
        res.writeHead(200, { "content-type": "image/png", "cache-control": "no-store" });
        return res.end(data);
      }
    }
    if (req.method === "GET" && (p === "/" || p === "/index.html")) {
      const rows = [...sessions.values()].map(s => `
        <a class="row" href="/api/session/${s.slug}/log">
          <span class="name">${esc(s.name)}</span>
          <span class="meta">${esc(s.slug)} · ${s.busy ? "<b class=lime>building</b>" : esc(s.phase)}${s.repo ? " · <span class=ok>repo</span>" : ""}</span>
        </a>`).join("");
      res.writeHead(200, { "content-type": "text/html" });
      return res.end(`<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>slappd</title><style>
  :root{--bg:#0b0b0e;--fg:#f5f1e3;--mut:#9d9d99;--lime:#c7f04d}
  *{box-sizing:border-box;margin:0}
  body{background:radial-gradient(1200px 500px at 50% -100px,#c7f04d14,transparent),var(--bg);color:var(--fg);
       font:15px/1.5 ui-monospace,monospace;padding:48px 24px;max-width:640px;margin:auto}
  .brand{font:700 34px/1 Georgia,serif}.brand i{color:var(--lime);font-style:normal}
  .sub{color:var(--mut);margin:10px 0 36px}
  .row{display:flex;justify-content:space-between;gap:12px;padding:14px 18px;border:1px solid #ffffff1c;
       border-radius:14px;text-decoration:none;color:var(--fg);margin-bottom:10px;
       background:#ffffff08;transition:border-color .15s}
  .row:hover{border-color:#c7f04d66}
  .name{font-family:Georgia,serif;font-size:17px}
  .meta{color:var(--mut);font-size:12px}.lime{color:var(--lime)}.ok{color:var(--lime);opacity:.7}
  .none{color:var(--mut);border:1px dashed #ffffff22;border-radius:14px;padding:26px;text-align:center}
  h2{font:400 11px ui-monospace,monospace;color:var(--mut);letter-spacing:.2em;margin:0 0 14px}
</style>
<p class=brand>slapp<i>.</i></p>
<p class=sub>the daemon is up · projects land in “custom stuff - do not delete” · everything runs on local models</p>
<h2>SESSIONS</h2>
${rows || `<div class=none>no sessions yet — say the word from the phone</div>`}`);
    }
    json(res, 404, { error: "not found" });
  } catch (e) {
    try { json(res, 500, { error: String(e?.message ?? e).slice(0, 300) }); } catch {}
  }
});

let bonjour = null;
process.on("exit", () => { try { bonjour?.kill(); } catch {} });
// graceful shutdown: launchd sends SIGTERM; default death orphaned pi children
let shuttingDown = false;
function shutdown(sig) {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`${sig} — stopping pi children, panes, and the door`);
  for (const s of sessions.values()) {
    try { s.pi?.kill("SIGTERM"); } catch {}
    for (const p of s.panes) { try { p.end(); } catch {} }
  }
  try { bonjour?.kill(); } catch {}
  try { server.close(() => process.exit(0)); } catch {}
  setTimeout(() => process.exit(0), 2000).unref();
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// ── the herdr door ────────────────────────────────────────────────────────
// Raw TCP on :8124. The pane client connects, says {hello:slug}, and receives
// the exact event stream the phone sees; every line it sends becomes a prompt
// in the SAME session. One pi run, two doors, zero drift.
const PANE_PORT = Number(process.env.SLAPP_PANE_PORT || 8124);
net.createServer((socket) => {
  let sess = null, buf = "";
  socket.on("data", (d) => {
    buf += d.toString();
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (!line) continue;
      let msg; try { msg = JSON.parse(line); } catch { continue; }
      if (msg.hello) {
        if (TOKEN && msg.token !== TOKEN) { socket.write(JSON.stringify({ type: "error", text: "bad token" }) + "\n"); socket.end(); return; }
        sess = sessions.get(String(msg.hello));
        if (!sess) { socket.write(JSON.stringify({ type: "error", text: "no such session" }) + "\n"); socket.end(); return; }
        sess.panes.add(socket);
        socket.write(JSON.stringify({ type: "hello", slug: sess.slug, phase: sess.phase, busy: sess.busy }) + "\n");
        for (const ev of sess.log.slice(-80)) socket.write(JSON.stringify(ev) + "\n");
      } else if (msg.prompt && sess) {
        try { sendPrompt(sess, String(msg.prompt)); }
        catch (e) { socket.write(JSON.stringify({ type: "error", text: String(e?.message ?? e) }) + "\n"); }
      }
    }
  });
  const drop = () => { if (sess) sess.panes.delete(socket); sess = null; };
  socket.on("close", drop);
  socket.on("error", drop);
}).listen(PANE_PORT, "127.0.0.1", () => log(`herdr door on 127.0.0.1:${PANE_PORT}`))
  .on("error", (e) => log(`herdr door unavailable: ${e?.message ?? e}`));

server.on("error", (e) => {
  if (e?.code === "EADDRINUSE") {
    console.error(`[slappd] port ${PORT} is already in use — another slappd is probably running. Quit it first or set SLAPP_PORT.`);
    process.exit(1);
  }
  console.error("[slappd] server error:", e?.message ?? e);
});
server.listen(PORT, HOST, async () => {
  const shownHost = (HOST === "::" || HOST === "0.0.0.0") ? "<all-interfaces>" : HOST;
  log(`listening on http://${shownHost}:${PORT} · projects under ${BASE_DIR}`);
  if (!TOKEN && HOST !== "127.0.0.1" && HOST !== "::1")
    log("WARNING: no SLAPP_TOKEN — anyone on your networks can run commands on this Mac. Set SLAPP_TOKEN and put the same value in Slapp's settings.");
  await restoreSessions();

  // the slapp sweep: every channel moves from the monocle door to the slapp
  // door — retire the old webhook, register the new one, same token
  for (const [slug, sx] of sessions) {
    if (!sx.bridgeToken) continue;
    const hdrs = { "Content-Type": "application/json", Authorization: `Bearer ${await bridgeAuth()}` };
    await fetch(`${SLAPP_BRIDGE}/channels/sync`, { method: "POST", headers: hdrs,
      body: JSON.stringify({ name: sx.name, webhook: `http://127.0.0.1:8123/api/session/${slug}/monocle`, remove: true }) }).catch(() => {});
    await fetch(`${SLAPP_BRIDGE}/channels/sync`, { method: "POST", headers: hdrs,
      body: JSON.stringify({ name: sx.name, webhook: `http://127.0.0.1:8123/api/session/${slug}/slapp`, webhook_token: sx.bridgeToken }) }).catch(() => {});
  }

  // the herdr handshake: if the human closes a session's space/tab in herdr,
  // the session dies everywhere — daemon, bridge channel, phone tile
  setInterval(() => {
    for (const [slug, sx] of [...sessions]) {
      if (!sx.herdr?.tabId || sx.phase === "restoring") continue;
      run("herdr", ["tab", "get", sx.herdr.tabId]).then(async (r) => {
        if (r.code === 0) return;
        if (sx.asleep) return;   // already marked — tell the pencil once
        sx.asleep = true;
        persistSessions();
        log(`${slug}: its space closed in herdr — asleep, safe on the pencil`);
        fleetNote(slug, `${sx.name} went to sleep — its space closed in herdr`);
        bridgeSay(sx, "its space on the Mac just closed — the conversation is safe. tap zzz on the pencil to wake it back up.").catch(() => {});
      }).catch(() => {});
    }
  }, 20 * 1000).unref?.();
  // adopt a live desk session after a daemon restart: the extension leaves
  // its port + token (0600) in ~/.cache/slapp/pi-latest.json
  (async () => {
    try {
      const lf = JSON.parse(await fsp.readFile(path.join(os.homedir(), ".cache/slapp/pi-latest.json"), "utf8").catch(() => "{}"));
      if (lf.port && lf.token && lf.cwd) {
        try { process.kill(lf.pid, 0); } catch { return; }   // listener gone — nothing to adopt
        const hit = [...sessions.values()].find(x => path.resolve(x.dir) === path.resolve(lf.cwd));
        if (hit) {
          hit.live = { port: lf.port, token: lf.token };
          hit.asleep = false; hit.phase = "ready"; hit.busy = false;
          persistSessions();
          if (hit.tail) { clearInterval(hit.tailTimer); hit.tail = null; }
          startTail(hit);
          log(`${hit.slug}: adopted live desk session on :${lf.port} (daemon restart healed)`);
        }
      }
    } catch {}
  })();

  // advertise so any surface — phone, ipad, watch — can find this Mac
  // without anyone typing an IP. restarts used to pile up zombies: clear first.
  await run("pkill", ["-f", "dns-sd -R slappd"]).catch(() => {});
  bonjour = spawn("dns-sd", ["-R", "slappd", "_slapp._tcp", "local", String(PORT)],
    { stdio: "ignore", detached: false });
  bonjour.on("error", () => log("bonjour advertise failed (discovery off)"));
});
