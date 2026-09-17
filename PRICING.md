# Slapp — pricing decision record (sept 5, 2026)

The call: **free download, one-week trial, $20.00 one-time unlock.** App (iOS)
stays private; the backend stays MIT. That's the whole design. The reasoning,
so future-us doesn't relitigate it.

## Why this shape

- **The flywheel is the product plan.** Word of mouth → friend tries it free
  for a week → likes it or doesn't → buys or doesn't → tells someone. Every
  pricing choice below serves that cycle. Metering, credits, and hard gates
  all starve it.
- **Slapp runs on the user's machine.** No server cost per user in the base
  product, so a subscription would be rent charged on their own hardware —
  the review shape "great app, why am I renting it?" One-time purchase is
  the honest price for a thing you ship. (If we ever add a relay or
  server-side voice/quota, revisit: service costs justify recurring money.)
- **$20.00 exactly, not $19.99.** Round number reads as confident. Set the
  exact price in App Store Connect. Enroll in the Small Business Program
  before first sale — 15% cut, ~$17 net per copy.
- **Free download, not paid upfront.** Paid apps from unknown developers get
  ~no downloads; there's also no native trial on paid upfront apps. The week
  of trial only exists if the download is free and frictionless.

## The trial, precisely

- **Starts at first successful daemon pairing**, not download or install.
  Days spent fighting Xcode and gh are setup, not usage — don't burn the
  week on them. (Trial that dies during setup reads as a scam; it isn't one.)
- **7 days**, then the $20 unlock (non-consumable IAP, restorable).
- **Honesty-box enforcement.** Trial state lives client-side with a daemon-
  side flag so a Settings toggle can't reset it, but nothing stronger. The
  terminal/herdr door is free forever and the server is MIT — anyone
  determined was never a customer. Locks here would cost the product's
  character to save money it can't protect anyway.
- **Expiry is not a lockout.** History, archives, and the pencil box stay
  readable. Plain-words message at the gate, something like: "this week's
  sessions worked well? the unlock is $20. your chats, pencils and repos are
  yours either way — and the terminal door stays free." That message is the
  marketing page; write it well.

## Free forever (the floor)

- The herdr/terminal door into any session.
- The MIT server (and any client someone wants to write against the public
  protocol).
- Read-only access after trial expiry.
- BYOK: paste your own model key, no account, nothing metered.

## Known costs of this choice (accepted)

- **App Review demo.** Reviewers won't set up a Mac to test. We owe one of:
  a shared demo daemon we run (seeded projects, read-mostly), or a no-Mac
  demo mode. **First engineering item** — the pricing plan ships or dies on
  it.
- **Setup = 1-star generator.** Pairing (Find my Mac, token, Tailscale) must
  be a smooth five-minute path, or buyers blame the app for the setup.
  Happy's reviews are all "rough edges," never "price" — the polish bar is
  the actual competitive moat.
- **Clones.** Closed app source doesn't stop UI clones, and public protocol
  invites custom clients. Accepted: they clone screenshots, not the haptics,
  the voice loop, or the pacing. Ship fast, keep the taste edge.
- **No enforced gate.** A determined free-rider can bypass everything via
  the terminal door. Accepted as a feature (funnel), not a bug.

## Distribution notes

- `/s/<slug>` share cards carry a discreet "Built with Slapp" line — every
  app the tool builds is a top-of-funnel ad.
- Expect Working-Copy-shaped revenue: modest, durable, honest. The bigger
  payoff is validating the niche and funding the infra. If weekly actives
  ever outgrow one demo Mac, that's the trigger to revisit the service tier
  (relay / hosted Mac) — a separate decision with its own record.

## Open items

- [ ] Demo story for App Review (shared demo daemon vs demo mode)
- [ ] Trial-state plumbing: state.json flag + client gate + restore flow
- [ ] The expiry message, in Slapp's voice, tested on a novice
- [ ] Small Business Program enrollment (before first sale)
- [ ] Listing copy leads with the experience (voice-first, canvas, annotate,
      haptics) — guideline 4.2 wants a product, not a remote terminal