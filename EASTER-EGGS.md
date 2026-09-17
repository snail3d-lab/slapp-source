# Easter eggs.

The law, learned in panhandler and kept here:

- An egg is a gift for the curious, never an ad. Nothing in the UI points at it.
- An egg never blocks function — the real thing still happens underneath.
- Haptics are the voice of an egg. A melody you feel, not a banner you read.
- When in doubt, beef it up. (Every pattern here was "upgraded from Light"
  at least once in panhandler; err strong.)

## Confirmed eggs

### The rick roll (committed — this is the one)

- Trigger: typing "never gonna give you up" (or "rick roll") into any chat
  and sending. The words still send — the egg rides along.
- What you feel: the chorus of *Never Gonna Give You Up*, played in
  haptics on the Taptic Engine — `Haptics.rickRoll()` in Haptics.swift.
  Rhythm and contour of the vocal line: "never gonna give you up" rises
  to Heavy on "up", "never gonna let you down" falls on "down", the
  desert-you run climbs and lands on a Success chime.
- Planned flourish: the outgoing bubble does a single slow wobble and its
  corner hatch pulses chartreuse, once. (Not yet built.)
- Planned, bigger: share-card pages (`/s/<slug>`) for a project whose
  slug contains "rick" serve the full dance. A web egg, not a phone one.

### This one goes to twelve

- Live now: spin the session-cap wheel to 12 and feel an ascending
  twelve-beat scale with a Success at the top — `Haptics.eleven()`,
  ported from panhandler's UnitSelector (where it goes to eleven).
- Spinal Tap homage, untouched.

### The item-get

- Live now: when an agent finishes a run while you're watching the chat,
  you feel `Haptics.alive()` — da-na-na-NAAAA, panhandler's Zelda
  item-get, transposed for slapp. Success chime on the landing.

## The pantry (ideas waiting for their moment)

- **The konami pencil box** — swipe up, up, down, down, left, right, left,
  right on the home mosaic; every pencil does a little wave, top to
  bottom, each with a tick in time.
- **The purring zzz** — long-press the zzz pill instead of tapping it:
  a soft irregular purr pattern, and the pill purrs once more when you
  let go.
- **The pencil that drums** — rub a pencil back and forth rapidly and it
  answers with a tiny drum roll; slow rub stays silent (the reveal).
- **Chartreuse ripple** — tap the alive diamond ◆ on a done line five
  times: one chartreuse ripple blooms across the paper from that point.
- **The eleven egg in the wheel** — spin the cap to exactly 11 and get a
  single very serious Heavy. Twelve gets the scale; eleven gets the
  punchline.
- **Bawk.** — panhandler's chicken (long-press egg, bawk bawk bagawk,
  YouTube). Waiting for a slapp-shaped home; the mic button is sacred,
  so not there.

## Rules for future eggs

1. Findable by play, not by help text.
2. Haptic-first: the body should smile before the eyes do.
3. Once found, repeatable on demand — eggs that fire once are pranks.
4. Never in the watch app. The wrist gets honest haptics only.
