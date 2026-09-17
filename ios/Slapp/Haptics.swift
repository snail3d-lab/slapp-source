import UIKit

// The touch vocabulary. Grammar learned from PanHandler:
//   light = small, medium = meaningful, heavy = emphatic,
//   notification = payoff. Rhythms are little songs — haptics as music,
//   never noise. When in doubt, beef it up.

enum Haptics {
    // MARK: - primitives

    static func play(_ kind: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(kind)
    }
    static func tick() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func tap()  { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func thud() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }

    /// the wheel's detent — a soft click as values scroll past
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }

    /// knock knock — a pencil tapped twice on the desk
    static func pencilTap() {
        tick()
        score([(60, tick)])
    }

    /// the plane leaving the pad — decisive press, soft land
    static func write() {
        tap()
        score([(70, tick)])
    }

    /// waking up — three ascending steps onto the landing
    static func rise() {
        tick()
        score([(120, tap), (240, thud), (340, { play(.success) })])
    }

    /// da-na-na-NAAAA! — the item-get when a run finishes (Zelda, via panhandler)
    static func alive() {
        tap()
        score([
            (110, tap),
            (220, thud),
            (300, { thud(); thud() }),   // double tap for emphasis!
            (360, { play(.success) }),
        ])
    }

    /// this one goes to twelve — ascending twelve-beat scale, Success at the top
    static func eleven() {
        var steps: [(Int, () -> Void)] = []
        for i in 0..<12 {
            let ms = i * 45
            let style: UIImpactFeedbackGenerator.FeedbackStyle = i < 5 ? .medium : .heavy
            steps.append((ms, { UIImpactFeedbackGenerator(style: style).impactOccurred() }))
        }
        steps.append((580, { play(.success) }))
        score(steps)
    }

    /// the chorus of Never Gonna Give You Up, in haptics — the rick roll egg.
    /// contour traced by feel: "give you up" rises to Heavy on "up",
    /// "let you down" falls on "down", the desert-you run climbs and lands.
    static func rickRoll() {
        let M = { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        let L = { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        let H = { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
        score([
            // "never gonna give you up"
            (0, L), (140, M), (280, M), (420, M), (560, M), (700, H),
            // "never gonna let you down"
            (1050, L), (1190, M), (1330, M), (1470, M), (1610, M), (1750, M),
            (1890, L), (2030, L),
            // "never gonna run around and desert you"
            (2450, L), (2590, M), (2730, M), (2870, M), (3010, M),
            (3150, M), (3290, M), (3430, H), (3570, H),
            (3700, { play(.success) }),
        ])
    }

    // MARK: - the sequencer
    // every song goes through one door, so a noisy pattern can be thinned
    // out in one place. steps are (ms from now, what to play).

    private static func score(_ steps: [(Int, () -> Void)]) {
        for (ms, hit) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: hit)
        }
    }
}
