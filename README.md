> **You bought source access.** Read [BUYER.md](BUYER.md) and [LICENSE.md](LICENSE.md) first.

# slapp.

**Talk. It builds.** Voice-first app builder — describe an iPhone or Apple
Watch app out loud and watch a real AI agent write, build, and run it live
while you chat.

Every session **is** a real [Pi](https://github.com/badlogic/pi-mono) coding
session — an actual interactive pi TUI living in its own herdr space on the
Mac. Your phone and your terminal are two doors into the same run: words from
the phone are typed into the TUI, and pi's own session log streams the
play-by-play back. Start on the phone, finish at the Mac, hop back. Zero
drift, by construction. Search past conversations (pi /resume-style) and
relaunch any of them in the live space.

- **Voice-first, both ways** — talk to your builder (whisper in), it talks
  back (TTS out, one-tap mute)
- **Floating chat bubble** — glass overlay with live transcript, tool
  activity, model picker, stop button
- **Live canvas** — the app being built, streamed from its own simulator
  (iPhone or Watch), updating as the agent works
- **watchOS apps** — pick "Watch" and the same voice loop builds for the
  wrist, canvas and all
- **Annotate** — circle it, point at it; the agent sees your marks
- **One tap, one project** — folder, xcodegen template, private GitHub
  repo, and a long-running Pi session, all automatic
- **Live space in herdr** — every session opens a typeable pane on your
  Mac showing the same run (any terminal works too — it's just pi)
- **/slapp, the handshake** — type `/slapp` in any pi session and it lands
  on the phone as a pencil; the session is told its starting context —
  what it is, where the project lives, that the phone is now a door
- **The live mind, live** — the agent's thinking streams token-by-token as
  a single ticker line in the chat; tap it to expand the full trace and
  the chat rides the stream with you
- **Session cap** — a wheel in settings (1 to 12): how many agents may run
  at once. Over it, new runs are declined in plain words — your words stay
  in the chat; waking a sleeping session is always free
- **Media, back at you** — the agent can deliver a picture or an audio
  file into the chat: it saves under the project dir and mentions the
  path; the phone renders it as a photo or playable audio
- **Haptics with a vocabulary** — light, medium, heavy, and little songs:
  the pencil knocks twice when you copy, the plane leaves the pad on
  send, a run finishing plays the item-get, waking a session rises in
  three steps, the wheel clicks under your thumb — and yes, the rick
  roll is in there (see [EASTER-EGGS.md](EASTER-EGGS.md))
- **Easter eggs** — gifts for the curious, never advertised; haptic-first;
  findable by play. The list lives in [EASTER-EGGS.md](EASTER-EGGS.md).
- **Shareable, tastefully** — every app gets a black-card page at
  `/s/<slug>` you can send anywhere
- **Self-healing** — Bonjour discovery (nobody types an IP), in-app
  restart, launchd keepalive, dead-sim guards, delete/archive from the mosaic

### The pencil box (the phone)

- **The pencil bar** — every session is a pastel pencil, tilted, stacked
  like a box of colors; tap one and you're in the chat
- **Chat lives on the pencil** — the chat's whole background is the
  tile's own pastel (tone-on-tone stripe), ink-and-paper bubbles: your
  words on ink, the agent's on white serif. No dark mode anywhere, ever.
  Rows recede down a perspective road as they scroll up — smaller,
  dimmer, leaning their own way. Timestamps sit centered at each bubble's
  foot in small serif; the corner carries a two-stroke hand hatch. No
  titles, no back arrow — the session's name lives in the typing bar,
  and a swipe right takes you home.
- **The wheel** — in settings: the session cap (1 to 12) and an honest
  count — "3 of 4 agents working right now."
- **The one button** — a microphone until you start typing, then it
  morphs into the paper plane. Hold to talk. Double-tap to latch (up to
  20 minutes — feed it audio, think out loud); tap stops and the words
  land in the field to edit, never auto-fired. Hold + swipe left →
  typewriter animation drops the words into the field. Hold + swipe up →
  straight to the agent with a white ripple blooming across the paper.
- **The Kodak** — a hand-drawn camera on the input's left: photo reel,
  take a photo, or **upload a file** — files land in the session's
  `.slapp/inbox` on the Mac and the agent is told exactly where they are
- **Breathing stop** — a gently pulsing stop button in the chat header
  while the agent runs
- **The live mind** — thinking streams into the chat as a single ticker
  line while the agent works; tap it to expand the full trace, scroll up
  to break away, come back to the bottom and it follows again. Tool
  calls land as small paper cards, pi-style.
- **Past conversations** — keyword search across every session's full
  history (mirrors pi /resume); tap a result and it relaunches in the
  live space
- **Sleep, don't kill** — close a session's space in herdr and the
  session goes to sleep, safe on its pencil; a **zzz** pill appears, tap
  it, confirm, and a real pi session relights exactly where it left off
- **Rub the pencil** — travel back and forth along a pencil (about a
  third of its length) and its real herdr tab hops to the front of your
  Mac. Swipe-up-to-send and rub-to-reveal are both settings toggles.
- **Peel, not push** — opening a chat peels the pencil into a full
  sheet, slow and smooth; done sessions pop off the paper with an
  elevation shadow and stay up until you give them the next thing
- **Notifications** — "line is done" and "needs help", per session

## Architecture

```
iPhone (Slapp app) ⇄ slappd (Node daemon) ⇄ pi --mode rpc (one per project)
  mic → m4a ───────→ mlx-whisper → prompt ──→ your model of choice
  canvas ← sim screenshot ←──────┐
  SSE: thinking/tools/replies ←──┤
herdr pane (:8124 door) ─────────┘  same session, typeable, pi-styled
```

The agent is not embedded or emulated — `slappd` spawns the actual `pi` CLI
per project (resumed with `pi -c` across daemon restarts). The phone is a
beautiful door; herdr is the terminal door; pi is the builder.

## Requirements (the daemon's home — a Mac)

- **Node 20+**, **Xcode 16+** with iOS + watchOS simulators, **xcodegen** (`brew install xcodegen`)
- **Pi coding agent** installed and authed (`npm i -g @earendil-works/pi-coding-agent`)
- **gh** CLI logged in (Slapp creates private repos per project)
- **herdr** (optional) for live spaces: `brew`/docs at herdr.dev
- **mlx-whisper** for voice (optional): `pip install mlx-whisper`

## Quick start

```bash
git clone https://github.com/Snail3D/Slapp && cd Slapp/server
npm install
node slappd.mjs               # daemon on :8123 (or install the LaunchAgent below)

cd ../ios && xcodegen generate
xcodebuild -project Slapp.xcodeproj -scheme Slapp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

In the app: **Start something**, name it, pick iPhone or Watch, say what it
should do. Watch the folder appear, the repo get created, the template come up
on the canvas — then just talk to it.

### Permanent daemon (recommended)

```bash
cp scripts/com.snail3d.slappd.plist ~/Library/LaunchAgents/   # edit paths to yours
launchctl load ~/Library/LaunchAgents/com.snail3d.slappd.plist
```

Runs at login, restarts if it crashes, survives reboots. Logs:
`~/Library/Logs/slappd.log`.

### The iPhone app on a real phone

Build for your device (Developer Mode required) and tap **Find my Mac** — the
daemon advertises itself on your network. No IP typing. Away from home? Install
**Tailscale** on both ends and enable "Connect On Demand" so the link never drops.

## Configuration

| Env (daemon) | Default | Does |
|---|---|---|
| `SLAPP_PORT` | `8123` | HTTP port |
| `SLAPP_PANE_PORT` | `8124` | herdr door (raw TCP event stream) |
| `SLAPP_HOST` | all interfaces | bind address (`127.0.0.1` = this Mac only) |
| `SLAPP_RUN_TIMEOUT` | `900` s | hard kill for hung builds / simctl |
| `SLAPP_MAX_UPLOAD` | `256 MB` | file-upload size cap |
| `SLAPP_BASE_DIR` | `~/Desktop/custom stuff - do not delete` | where projects land |
| `SLAPP_GH_OWNER` | `Snail3D` | GitHub org/user for new repos |
| `SLAPP_UDID` | iPhone 17 Pro sim | the canvas simulator |
| `SLAPP_WATCH_UDID` | auto-detect | watch simulator for watch apps |
| `SLAPP_WHISPER` | `~/Library/Python/3.9/bin/mlx_whisper` | transcription binary |
| `SLAPP_VOICE` / `SLAPP_VOICE_RATE` | system default | `say` voice / words-per-minute |
| `SLAPP_HERDR_WS` | focused workspace | where live spaces open |
| `SLAPP_TOKEN` | unset | **require `X-Slapp-Token` on every request** |

## Security — read this

`slappd` runs an **autonomous coding agent with shell access** on your Mac and
will create GitHub repos under your account. It trusts whoever can reach it.

- Keep it on **localhost or a private tailnet** — do not port-forward it.
- Set `SLAPP_TOKEN` and put the same value in the app's settings; the app
  nags you (kindly) when the daemon is unsecured.
- Each project ships its own `AGENTS.md` with guardrails, but the agent can
  run shell commands — that's the point. Treat reachability as trust.
- Share-card pages (`/s/<slug>`) are public to anyone who can reach the
  daemon. That's their job.

## Layout

```
server/slappd.mjs     the daemon: HTTP + SSE + herdr door + pi RPC + whisper + simctl
server/herdr-pane.mjs the pane client: your Mac's door into a session
ios/                  the Slapp app (xcodegen project, SwiftUI)
integrations/pi/      the pi extension (/slapp door) + heartbeat + chime
TODO.md               the honest list: pitfalls, ladder, what still hurts
EASTER-EGGS.md        the eggs: what's live, what's planned, the laws
HANDOFF.md            session-by-session build journal
```

## Status

v1.1 — daily-driver quality on one Mac + one iPhone + one Watch. The roadmap
lives in [TODO.md](TODO.md); the war stories in [HANDOFF.md](HANDOFF.md).

Built with Pi — every line of this project was written by agents talking to
humans.

## License

MIT — see [LICENSE](LICENSE).
