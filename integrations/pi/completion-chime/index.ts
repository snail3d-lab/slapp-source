/**
 * completion-chime — play a sound when the agent finishes a turn.
 *
 * Fires on agent_settled (turn + follow-ups fully done, pi won't continue
 * automatically). macOS only: afplay + a built-in system sound.
 *
 * Config: PI_CHIME_SOUND env — path to any .aiff (or name of a built-in
 * /System/Library/Sounds sound, e.g. "Hero", "Ping", "Blow", "Pop").
 * Set PI_CHIME_SOUND=off to disable without uninstalling.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BUILT_INS = "/System/Library/Sounds";

function soundPath(): string {
  const s = process.env.PI_CHIME_SOUND || "Glass";
  if (s.toLowerCase() === "off") return "";
  return s.includes("/") ? s : `${BUILT_INS}/${s}.aiff`;
}

export default function (pi: ExtensionAPI) {
  pi.on("agent_settled", async (_event, ctx) => {
    if (!ctx.hasUI) return; // print/rpc mode — no one to hear it
    const sound = soundPath();
    if (!sound) return;
    try {
      // fire-and-forget — never block the agent loop on a sound
      pi.exec("afplay", [sound]).catch(() => {});
    } catch { /* afplay missing (not macOS) — stay silent */ }
  });
}
