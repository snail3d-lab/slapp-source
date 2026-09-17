#!/usr/bin/env node
// herdr pane client — the real thing, not a window-dressing.
// Connects to slappd's herdr door and shows the session's live event stream,
// pi-styled. What you type joins the SAME pi session the phone talks to.
import net from "node:net";
import readline from "node:readline";

const SLUG = process.argv[2];
const PORT = process.env.SLAPP_PANE_PORT || 8124;
const TOKEN = process.env.SLAPP_PANE_TOKEN || "";
if (!SLUG) { console.error("usage: herdr-pane.mjs <slug>"); process.exit(1); }

const dim = s => `\x1b[90m${s}\x1b[0m`, lime = s => `\x1b[1;38;5;154m${s}\x1b[0m`,
      green = s => `\x1b[38;5;114m${s}\x1b[0m`, red = s => `\x1b[91m${s}\x1b[0m`,
      bold = s => `\x1b[1m${s}\x1b[0m`, white = s => `\x1b[38;5;252m${s}\x1b[0m`;
const toolStart = new Map();

const sock = net.connect(PORT, "127.0.0.1");
sock.on("connect", () => {
  sock.write(JSON.stringify({ hello: SLUG, token: TOKEN }) + "\n");
});

let buf = "";
sock.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (line.trim()) handle(line);
  }
});

function handle(line) {
  let ev; try { ev = JSON.parse(line); } catch { return; }
  switch (ev.type) {
    case "hello":
      console.log(dim(`── slapp · ${ev.slug} · ${ev.busy ? "working" : "idle"} ── type a line + Enter to join this session`));
      break;
    case "user":
      console.log(`\n${lime("❯ you")}\n${white(String(ev.text || "(a photo)").trim())}`);
      break;
    case "done":
      if (ev.text) console.log(`\n${dim("◆ slapp")}\n${dim(String(ev.text).replace(/\s*\n+\s*/g, " ").trim().slice(0, 2000))}`);
      break;
    case "tool":
      if (ev.phase === "start") {
        toolStart.set(ev.tid, Date.now());
        console.log(`  ${green("$")} ${bold(String(ev.preview || ev.name || "").slice(0, 120))}`);
      } else {
        const t0 = ev.tid ? toolStart.get(ev.tid) : null;
        if (ev.tid) toolStart.delete(ev.tid);
        const dur = t0 ? `${((Date.now() - t0) / 1000).toFixed(1)}s` : (ev.name || "tool");
        console.log(ev.ok === false ? `  ${red("✗ " + (ev.name || "tool") + " failed")}` : `  ${dim("✓ " + dur)}`);
      }
      break;
    case "error":
      console.log(red("!! " + ev.text));
      if (String(ev.text).includes("no such session")) process.exit(0); // session deleted → pane goes home quietly
      break;
    case "status":
      if (ev.text && ev.text !== "thinking" && !String(ev.text).startsWith("screenshot failed"))
        console.log(dim("· " + ev.text));
      break;
    default: break;
  }
}

sock.on("error", () => {
  console.error(red("!! lost slappd — reopen the session on your phone to relight this tab"));
  process.exit(1);
});
sock.on("close", () => {
  console.log(dim("· slappd went away — this tab relights when the session opens again"));
  process.exit(0);
});

// your typing joins the same session
readline.createInterface({ input: process.stdin, terminal: true, prompt: "" }).on("line", (l) => {
  const t = l.trim();
  if (!t) return;
  sock.write(JSON.stringify({ prompt: t }) + "\n");
  console.log(dim("   ↗ sent"));
});
