# Slapp — positioning (sept 5, 2026)

**Hyper-specialized, on purpose.** Slapp is not an app builder that also
does everything. It is a voice door into pi, on a Mac you own, that builds
iPhone/Watch apps. The wiring *is* the product; every new connector added
makes it more confusing. So the specialization is defined by what we refuse.

## The bet

Everyone is building a jack-of-all-trades (Rork, Lovable, Replit, Bolt —
connectors to every database, framework, cloud). Crowded, capital-intensive,
and it competes on breadth. Slapp competes on depth of one loop:
talk → agent builds → you watch it happen live → you point at something →
it changes. Small surface, extremely tuned. Small ecstatic audience beats
large indifferent one, and at $20 one-time it only needs the former.

## Lines in the sand

- **Client surfaces: iPhone, iPad, and a Watch companion — three doors,
  one loop.** No Mac app (the terminal door is the Mac door, and it's
  free), no Vision, no Mac-catalyst checkbox padding. iPhone is the door,
  iPad is the cockpit (chat + live canvas side by side, where the
  perspective-road layout breathes), Watch is the pulse: glance that a run
  is done or needs help, tap, talk. Notification intake, quick approve/
  stop, hold-to-talk. It is the same chat loop at the wrist — NOT a
  second app with its own feature list. That is what keeps it inside the
  specialization instead of outside it.
- **One package, one price, all surfaces.** Universal Purchase: a single
  submission carries iPhone, iPad, and the Watch companion; the $20 unlock
  is one purchase that restores everywhere (PRICING.md). The Watch app
  carries no IAP of its own — it rides the iPhone unlock. $20 buys the set
  of doors, not one door.
- **Building *for* Watch stays** — that's specialization, not breadth.
  Nobody else builds watchOS apps by voice from a phone. Combined with the
  Watch companion, the one-liner is the whole niche: *the tool that
  builds Watch apps, from your Watch.* Rork Max builds for Apple platforms
  at $200/mo; nobody else lives *on* them.
- **No connector sprawl.** No Firebase/Supabase/OpenAI-plugin marketplace.
  The agent has shell access and can wire things itself when a project
  needs it; the product doesn't grow a UI per integration.
- **No hosted multi-tenant service by default.** Computing stays on the
  user's Mac. If a hosted tier ever happens (relay, rented Mac), it's a
  separate product with its own decision record — see PRICING.md open items.
- **One machine, one person.** Personal tool, not team software. No orgs,
  no seats, no admin panels.

## Why the backend is open (beyond "they'd copy it anyway")

- Trust: `slappd` is an autonomous agent with shell access. Nobody sane
  runs a closed-source remote shell daemon on their Mac. Openness isn't
  generosity here, it's a security requirement — people will only wire
  this much trust into a thing they can read.
- The visible code/protocol is also what makes the terminal door possible,
  and the terminal door is what keeps the paid app feeling like a gift
  instead of a toll booth (PRICING.md).
- App-UI clones remain possible and accepted. They copy screenshots, not
  the haptics, the voice pacing, or the taste. Our edge is iteration
  speed, not secrecy.

## What would break the bet (watch for these)

- Growing the connector surface to win demos rather than daily use.
- Chasing the no-Mac market through product sprawl instead of (maybe,
  someday) a hosted tier.
- Letting "we could add that" beat "it would make the wiring confusing."