/**
 * slapp-live — the pane's heartbeat to the daemon.
 *
 * The session JSONL only lands at turn end, so the daemon's tail sees the
 * whole thinking trace in one lump. This extension whispers the thinking
 * tail to slappd WHILE it forms — the phone's ticker tape. Loopback POST,
 * throttled to a few updates a second; failures are silent by design.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as http from "node:http";

const PORT = Number(process.env.SLAPP_PORT || 8123);
let lastTail = "";
let lastAt = 0;

function post(body: Record<string, unknown>) {
  const data = JSON.stringify(body);
  const req = http.request(
    {
      host: "127.0.0.1",
      port: PORT,
      path: "/api/live",
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(data),
      },
    },
    () => {}
  );
  req.on("error", () => {});
  req.end(data);
}

export default function (pi: ExtensionAPI) {
  post({ type: "tool", preview: "slapp-live loaded", cwd: process.cwd() });
  pi.on("message_update", async (event) => {
    const msg = event.message as any;
    if (!msg || msg.role !== "assistant" || !Array.isArray(msg.content)) return;
    let think = "";
    for (const c of msg.content) {
      if (c && c.type === "thinking") think += String(c.thinking ?? "");
    }
    think = think.trim();
    if (!think) return;
    const now = Date.now();
    if (now - lastAt < 280) return; // ~3 updates a second at most
    const tail = think.slice(-1400);
    if (tail === lastTail && now - lastAt < 4000) return;
    lastTail = tail;
    lastAt = now;
    post({ type: "thinking", text: tail, cwd: process.cwd() });
  });

  pi.on("tool_execution_start", async (event: any) => {
    const name = String(event?.name ?? event?.toolName ?? "tool");
    post({ type: "tool", preview: name, cwd: process.cwd() });
  });
}
