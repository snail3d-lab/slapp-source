/**
 * slapp — bridge device captures into this pi session.
 *
 * Each pi session binds its OWN listener on the first free port in
 * 8661-8670, so multiple sessions never collide. `/slapp` connects THIS
 * session (registers its actual port with the bridge — last connect wins),
 * `/slapp disconnect` unhooks, `/slapp <args>` proxies to the CLI.
 * The bound port is also written to ~/.cache/slapp/pi-latest.json so the
 * CLI / dashboard launcher can find the most recent listener.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as http from "node:http";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as crypto from "node:crypto";

const PORT_BASE = 8661;
const PORT_SPAN = 40;   // 40 seats: a dozen sessions + the human's own pi windows
const BRIDGE = (process.env.SLAPP_BRIDGE || process.env.MONOCLE_BRIDGE || loadCliConfig().bridge || "http://127.0.0.1:8651").replace(/\/$/, "");
const LATEST_FILE = path.join(os.homedir(), ".cache/slapp/pi-latest.json");

// This session's webhook secret: minted at startup, registered with the bridge
// alongside our URL, and required on every capture POST — without it anyone on
// the LAN/tailnet could inject fake "device captures" into this session.
const MY_TOKEN = crypto.randomBytes(16).toString("hex");

// Host we advertise to the bridge: loopback when the bridge is local; our
// tailscale/LAN address when it's on another machine (multi-computer).
function advertiseHost(): string {
  let bh = "";
  try { bh = new URL(BRIDGE).hostname; } catch { return "127.0.0.1"; }
  if (bh === "127.0.0.1" || bh === "localhost" || bh === "::1") return "127.0.0.1";
  const wantTailscale = bh.startsWith("100.");
  const ifaces = os.networkInterfaces();
  let lan = "";
  for (const list of Object.values(ifaces)) {
    for (const i of list || []) {
      if (i.internal || i.family !== "IPv4") continue;
      if (i.address.startsWith("100.")) {
        if (wantTailscale) return i.address;
      } else if (!lan) {
        lan = i.address;
      }
    }
  }
  return lan || "127.0.0.1";
}

function loadCliConfig(): any {
  const home = os.homedir();
  for (const p of [path.join(home, ".config/slapp/config.json"), path.join(home, ".config/monocle/config.json")]) {
    try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
  }
  return {};
}

function bridgeAuth(): string {
  if (process.env.BRIDGE_AUTH_TOKEN) return process.env.BRIDGE_AUTH_TOKEN;
  return loadCliConfig().auth_token || "";
}

/**
 * Vision sidecar: when the session model can't see images, photos are
 * described by a vision-capable model (default: gemma4:e4b on the mac-mini
 * ollama) and the description is injected instead. Config: env
 * MONOCLE_VISION_URL/MODEL/KEY or ~/.config/monocle/config.json keys
 * vision_url / vision_model / vision_key.
 */
async function describeImage(photoPath: string): Promise<string> {
  const cfg = loadCliConfig();
  const base = (process.env.SLAPP_VISION_URL || process.env.MONOCLE_VISION_URL || cfg.vision_url || "http://127.0.0.1:11434/v1").replace(/\/$/, "");
  const model = process.env.SLAPP_VISION_MODEL || process.env.MONOCLE_VISION_MODEL || cfg.vision_model || "gemma4:e4b";
  const key = process.env.SLAPP_VISION_KEY || process.env.MONOCLE_VISION_KEY || cfg.vision_key || "ollama";
  const b64 = fs.readFileSync(photoPath).toString("base64");
  const res = await fetch(`${base}/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
    body: JSON.stringify({
      model,
      max_tokens: 600, // reasoning models burn budget before content — leave room
      messages: [{
        role: "user",
        content: [
          { type: "text", text: "Describe this photo in 2-3 plain sentences for someone who cannot see it." },
          { type: "image_url", image_url: { url: `data:image/jpeg;base64,${b64}` } },
        ],
      }],
    }),
    signal: AbortSignal.timeout(90000),
  });
  if (!res.ok) throw new Error(`vision ${res.status}`);
  const data = (await res.json()) as any;
  const text = (data.choices?.[0]?.message?.content || "").trim();
  if (!text) throw new Error("vision returned empty");
  return text;
}

async function setWebhook(url: string, token = ""): Promise<boolean> {
  const auth = bridgeAuth();
  const res = await fetch(`${BRIDGE}/config`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(auth ? { Authorization: `Bearer ${auth}` } : {}),
    },
    body: JSON.stringify(url
      ? { capture_webhook: url, webhook_token: token }
      : { capture_webhook: "", webhook_token: token }),
  });
  const data = (await res.json()) as { ok?: boolean; error?: string; webhook_token_stored?: boolean };
  if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
  return !!data.webhook_token_stored;
}

function formatCapture(p: any): string {
  const dev = p.device || "device";
  const lines: string[] = [];
  if (p.mode === "photo") {
    lines.push(`📷 [slapp:${dev}] photo from the user's device${p.photo ? ` — saved at ${p.photo} (use your read tool to view it)` : ""}`);
  } else if (p.mode === "text") {
    lines.push(`⌨️ [slapp:${dev}] the user typed: "${p.text || ""}"`);
  } else {
    lines.push(`🎙 [slapp:${dev}] the user said: "${p.text || "(no speech detected)"}"`);
  }
  if (p.result === "error") {
    lines.push("", "⚠️ the capture pipeline reported an error on this one.");
  }
  lines.push("", "(Live from the user's slapp device — it is connected to THIS session, not Telegram. Respond to the user directly.)");
  return lines.join("\n");
}

export default function (pi: ExtensionAPI) {
  let server: http.Server | undefined;
  let boundPort = 0;
  // live traffic: this session's thinking, tools, replies — for the phone.
  type TEvent = { type: string; text?: string; preview?: string; name?: string; ok?: boolean; phase?: string; ts: number };
  const trafficBuf: TEvent[] = [];
  const trafficClients = new Set<http.ServerResponse>();
  let lastThinking = 0;

  function broadcast(ev: TEvent) {
    ev.ts = Date.now();
    trafficBuf.push(ev);
    if (trafficBuf.length > 60) trafficBuf.shift();
    const line = `data: ${JSON.stringify(ev)}\n\n`;
    for (const res of trafficClients) { try { res.write(line); } catch { trafficClients.delete(res); } }
  }
  // Reply push-back: captures steer into this session; when the run ends,
  // the final assistant text goes back to the bridge (/say) so the phone
  // app's play-by-play stays live.
  let pendingTargets: { device: string; channel: string }[] = [];
  let runTexts: string[] = [];
  let runActive = false;
  // Enforced only after the bridge confirms it stored our token (old bridges
  // ignore the field and never send the header — don't lock ourselves out).
  let enforceToken = false;
  let weConnected = false;   // this session owns the bridge webhook right now

  function writeLatest(cwd?: string) {
    try {
      fs.mkdirSync(path.dirname(LATEST_FILE), { recursive: true });
      try { fs.chmodSync(LATEST_FILE, 0o600); } catch {}
      fs.writeFileSync(LATEST_FILE, JSON.stringify({ port: boundPort, host: advertiseHost(), pid: process.pid, ts: Date.now(), cwd: cwd || "", token: MY_TOKEN }));
    } catch { /* advisory only */ }
  }

  function makeServer(ctx: any): http.Server {
    return http.createServer((req, res) => {
      if (req.method === "GET" && req.url === "/traffic") {
        res.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        });
        for (const ev of trafficBuf) res.write(`data: ${JSON.stringify(ev)}\n\n`);
        trafficClients.add(res);
        req.on("close", () => trafficClients.delete(res));
        return;
      }
      if (req.method !== "POST" || (req.url !== "/slapp" && req.url !== "/monocle")) {
        res.statusCode = 404;
        res.end();
        return;
      }
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        if (enforceToken && req.headers["x-monocle-token"] !== MY_TOKEN) {
          res.statusCode = 401;
          res.end("bad token");
          return;
        }
        res.statusCode = 200;
        res.end("ok");
        (async () => {
          try {
            const payload = JSON.parse(body);
            const kind = payload.kind || "capture";
            const label = payload.mode === "photo" ? "📷 photo" : "🎙 voice";
            const busy = typeof ctx?.isIdle === "function" ? !ctx.isIdle() : false;

            // kind=notify: QR confirmations/status — toast only, no injection.
            if (kind === "notify") {
              ctx?.ui?.notify?.(`slapp: ${payload.text}`, "info");
              ctx?.ui?.setStatus?.("slapp", `slapp ● :${boundPort} · ${String(payload.text || "").slice(0, 40)}`);
              return;
            }

            // Immediate visible confirmation, mirroring a typed queued message.
            ctx?.ui?.notify?.(`slapp ${label} received${busy ? " — steering into current turn" : ""}`, "info");
            ctx?.ui?.setStatus?.("slapp", `slapp ● :${boundPort} last ${label} ${new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`);

            // kind=stop: the phone's stop button — abort the current run
            if (kind === "stop") {
              ctx?.ui?.notify?.("slapp: stop requested from the phone", "info");
              try { ctx.abort(); } catch { try { pi.abort?.(); } catch {} }
              res.statusCode = 200; res.end("stopped");
              return;
            }
            // kind=say: a QR "say" card — the harness agent answers it here.
            if (kind === "say") {
              pendingTargets.push({ device: String(payload.device || "device"), channel: String(payload.channel || "main") });
              runTexts = [];
              runActive = true;
              const text = `💬 [slapp QR card] the user scanned a "say" card: "${payload.text}"\n\n(Answer them here — the device is connected to THIS session, not Telegram.)`;
              Promise.resolve(pi.sendUserMessage(text, { deliverAs: "steer" }))
                .catch((e: any) => ctx?.ui?.notify?.(`slapp inject failed: ${e?.message || e}`, "error"));
              return;
            }

            pendingTargets.push({ device: String(payload.device || "device"), channel: String(payload.channel || "main") });
            runTexts = [];
            runActive = true;
            const parts: any[] = [{ type: "text", text: formatCapture(payload) }];
            // Attach the photo inline when the active model can see images.
            const modelInput = (ctx?.model as any)?.input;
            const canSee = Array.isArray(modelInput) && modelInput.includes("image");
            if (payload.photo && canSee) {
              try {
                parts.push({
                  type: "image",
                  data: fs.readFileSync(payload.photo).toString("base64"),
                  mimeType: "image/jpeg",
                });
              } catch { /* text part still carries the path */ }
            } else if (payload.photo) {
              // Session model can't see — vision sidecar describes the photo.
              try {
                ctx?.ui?.notify?.("slapp: vision sidecar describing photo…", "info");
                const desc = await describeImage(payload.photo);
                parts[0].text += `\n\n👁 Vision (sidecar): ${desc}`;
              } catch (e: any) {
                parts[0].text += `\n\n(vision sidecar failed: ${e?.message || e} — image at the path above)`;
              }
            }
            // deliverAs "steer": deliver mid-stream (after the current turn's tool
            // calls, before the next LLM call) so slapp messages interrupt/steer
            // the agent instead of queuing behind it.
            Promise.resolve(
              pi.sendUserMessage(parts.length > 1 ? parts : parts[0].text, { deliverAs: "steer" }),
            ).catch((e: any) => ctx?.ui?.notify?.(`slapp inject failed: ${e?.message || e}`, "error"));
          } catch (e: any) {
            ctx?.ui?.notify?.(`slapp: bad webhook payload: ${e?.message || e}`, "error");
          }
        })();
      });
    });
  }

  async function bindListener(ctx: any): Promise<number> {
    if (server) return boundPort;
    for (let port = PORT_BASE; port < PORT_BASE + PORT_SPAN; port++) {
      const s = makeServer(ctx);
      const bound = await new Promise<number>((resolve) => {
        s.once("error", () => resolve(0));
        // 0.0.0.0: reachable from a bridge on another machine (tailnet/LAN).
        // The per-session token is what makes this safe.
        s.listen(port, () => resolve(port));
      });
      if (bound) {
        server = s;
        boundPort = bound;
        writeLatest(ctx?.cwd || "");
        return bound;
      }
    }
    return 0;
  }

  async function syncChannels(url: string, remove: boolean): Promise<void> {
    const auth = bridgeAuth();
    if (!auth) return;
    await fetch(`${BRIDGE}/channels/sync`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${auth}` },
      body: JSON.stringify({ name: "this session", webhook: url, webhook_token: MY_TOKEN, remove }),
    }).catch(() => {});
  }

  async function connect(ctx: any, port: number, auto: boolean): Promise<void> {
    const url = `http://${advertiseHost()}:${port}/slapp`;
    enforceToken = await setWebhook(url, MY_TOKEN);
    await syncChannels(url, false);
    weConnected = true;
    const how = auto ? " (auto)" : "";
    ctx.ui?.setStatus?.("slapp", `slapp ● :${port} connected${how}`);
    ctx.ui?.notify?.(`slapp connected${how} — captures land in THIS session (${url})`, "info");
  }

  async function disconnect(): Promise<void> {
    // The bridge only honors this if our token owns the current webhook —
    // a stale session can't disconnect a newer one.
    try {
      const url = `http://${advertiseHost()}:${boundPort}/slapp`;
      await setWebhook("", MY_TOKEN);
      await syncChannels(url, true);
    } catch { /* best effort */ }
    weConnected = false;
    enforceToken = false;
  }

  pi.on("agent_start", async () => {
    broadcast({ type: "status", text: "run started", ts: 0 });
  });

  pi.on("tool_execution_start", async (event: any) => {
    let args = "";
    try { args = JSON.stringify(event.args ?? {}).slice(0, 90); } catch {}
    broadcast({ type: "tool", preview: `${event.toolName ?? "tool"} ${args}`, phase: "start", ts: 0 });
  });

  pi.on("tool_execution_end", async (event: any) => {
    const err = event.isError ?? event.error != null;
    broadcast({ type: "tool", name: event.toolName ?? "tool", ok: !err, phase: "end", ts: 0 });
  });

  pi.on("message_update", async (event: any) => {
    const ame = event.assistantMessageEvent;
    if (!ame || !String(ame.type || "").includes("thinking")) return;
    const now = Date.now();
    if (now - lastThinking < 1200) return;   // throttle the trace
    lastThinking = now;
    const d = String(ame.delta ?? ame.text ?? "").trim();
    if (d) broadcast({ type: "thinking", text: d.slice(-140), ts: 0 });
  });

  pi.on("message_end", async (event) => {
    const m: any = (event as any).message;
    if (!runActive || m?.role !== "assistant") return;
    const txt = Array.isArray(m.content)
      ? m.content.filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n").trim()
      : (typeof m.content === "string" ? m.content.trim() : "");
    if (txt) runTexts.push(txt);
  });

  pi.on("agent_end", async () => {
    if (!runActive) return;
    runActive = false;
    const text = runTexts.filter(Boolean).pop() || "";
    runTexts = [];
    const targets = pendingTargets;
    pendingTargets = [];
    if (!text || targets.length === 0) return;
    for (const t of targets) {
      fetch(`${BRIDGE}/say`, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...(bridgeAuth() ? { Authorization: `Bearer ${bridgeAuth()}` } : {}) },
        body: JSON.stringify({ device: t.device, channel: t.channel, text }),
      }).catch(() => {});
    }
  });

  pi.on("session_start", async (_event, ctx) => {
    const port = await bindListener(ctx);
    if (!port) return;
    // SLAPP_CONNECT=1 (or legacy MONOCLE_CONNECT) wires THIS
    // session up automatically — voice input switches to the new session
    // without waiting for a manual /monocle.
    if (process.env.SLAPP_CONNECT || process.env.MONOCLE_CONNECT) {
      try {
        await connect(ctx, port, true);
        return;
      } catch (e: any) {
        ctx.ui?.notify?.(`slapp auto-connect failed: ${e?.message || e} — /slapp to retry`, "error");
      }
    }
    ctx.ui?.setStatus?.("slapp", `slapp ○ :${port} (not connected — /slapp to connect)`);
  });

  pi.on("session_shutdown", async (event) => {
    // "quit" and "reload" both tear down this extension instance — release
    // the port so the next instance (or a fresh session) can take it back,
    // and hand captures back to Telegram if WE own the webhook (no more
    // dead-listener black holes after closing a connected session).
    if (event.reason === "quit" || event.reason === "reload") {
      if (weConnected) await disconnect();
      if (server) {
        server.close();
        server = undefined;
      }
    }
  });

  pi.registerCommand("slapp", {
    description: "Connect THIS session to the slapp bridge (captures land here). Args proxy to the slapp CLI.",
    handler: async (args, ctx) => {
      const sub = (args || "").trim();
      try {
        if (!sub) {
          const port = await bindListener(ctx);
          if (!port) {
            ctx.ui.notify(`slapp: no free port in ${PORT_BASE}-${PORT_BASE + PORT_SPAN - 1}`, "error");
            return;
          }
          await connect(ctx, port, false);
          // claim this project with the daemon, LIVE: THIS session stays the
          // only runtime — phone words relay into it (steer), its replies
          // tail back to the phone. Idempotent: re-running /slapp re-binds.
          try {
            const claim = await fetch(`http://127.0.0.1:${process.env.SLAPP_PORT || 8123}/api/session`, {
              method: "POST", headers: { "Content-Type": "application/json" },
              body: JSON.stringify({
                existing: process.cwd(),
                name: (process.cwd().split("/").pop() || "project").trim(),
                live: { port: boundPort, token: MY_TOKEN },
              }),
            });
            if (claim.ok) {
              const cj: any = await claim.json();
              ctx.ui.notify(`slapp: this conversation is on your phone as "${cj.slug}" — talk from anywhere`, "info");
            } else {
              const cj: any = await claim.json().catch(() => ({}));
              ctx.ui.notify(`slapp: phone bind failed — ${cj.error || claim.status}`, "error");
            }
          } catch { /* daemon asleep — captures still connected */ }
          // the starting context: the model learns slapp is on for this
          // session — the same block every phone word arrives with
          try {
            const r = await fetch(`http://127.0.0.1:${process.env.SLAPP_PORT || 8123}/api/context?cwd=${encodeURIComponent(process.cwd())}`);
            if (r.ok) {
              const j: any = await r.json();
              if (j?.context) {
                const msg = `(slapp is now on for this session — starting context follows)\n\n${j.context}`;
                try { await ctx.sendUserMessage(msg); }
                catch { await ctx.sendUserMessage(msg, { deliverAs: "steer" }); }
              }
            }
          } catch { /* daemon asleep — the connect itself still worked */ }
          return;
        }
        if (sub === "disconnect") {
          await disconnect();
          ctx.ui.setStatus?.("slapp", `slapp ○ :${boundPort} (not connected)`);
          ctx.ui.notify("slapp disconnected — captures are back on Telegram", "info");
          return;
        }
        const result = await pi.exec("slapp", sub.split(/\s+/), { timeout: 30000 });
        const out = (result.stdout || result.stderr || "(no output)").trim();
        ctx.ui.notify(out.length > 400 ? out.slice(0, 400) + "…" : out, "info");
      } catch (e: any) {
        ctx.ui.notify(`slapp: ${e?.message || e}`, "error");
      }
    },
  });
  pi.registerCommand("monocle", {
    description: "Connect THIS session to slapp (captures land here). Args proxy to the monocle-hardware CLocle CLI.",
    handler: async (args, ctx) => {
      const sub = (args || "").trim();
      try {
        if (!sub) {
          const port = await bindListener(ctx);
          if (!port) {
            ctx.ui.notify(`slapp: no free port in ${PORT_BASE}-${PORT_BASE + PORT_SPAN - 1}`, "error");
            return;
          }
          await connect(ctx, port, false);
          return;
        }
        if (sub === "disconnect") {
          await disconnect();
          ctx.ui.setStatus?.("slapp", `slapp ○ :${boundPort} (not connected)`);
          ctx.ui.notify("slapp disconnected — captures are back on Telegram", "info");
          return;
        }
        const result = await pi.exec("monocle", sub.split(/\s+/), { timeout: 30000 });
        const out = (result.stdout || result.stderr || "(no output)").trim();
        ctx.ui.notify(out.length > 400 ? out.slice(0, 400) + "…" : out, "info");
      } catch (e: any) {
        ctx.ui.notify(`slapp: ${e?.message || e}`, "error");
      }
    },
  });
}
