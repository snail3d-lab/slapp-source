import AppIntents
import UIKit
import os

/// Bridges App Intents (Action Button / Lock Screen / Back Tap / Shortcuts)
/// to the live CaptureModel. The intent runs inside this app's process, so
/// the shared reference is set on launch and used by every trigger.
@MainActor
enum IntentsCoordinator {
    static weak var model: CaptureModel?

    /// Recent Action Button taps — enables the ESP32-style triple-tap gesture.
    private static var tapTimes: [Date] {
        get { (UserDefaults.standard.array(forKey: "ab_taps") as? [Date]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "ab_taps") }
    }

    static func countTap() -> Int {
        let now = Date()
        tapTimes = (tapTimes + [now]).filter { now.timeIntervalSince($0) < 2.0 }
        return tapTimes.count
    }

    static func resetTaps() { tapTimes = [] }
}

/// The Action Button intent: press to talk, press again to send,
/// press three times quickly to jump into photo mode.
struct SlappTalkIntent: AppIntent {
    static let title: LocalizedStringResource = "Slapp Push"
    static let description = IntentDescription(
        "Press to start talking to your agent. Press again to send. Triple-press for photo mode."
    )
    @MainActor
    func perform() async throws -> some IntentResult {
        let log = Logger(subsystem: "com.snail3d.slapp", category: "intent")
        guard let model = IntentsCoordinator.model else {
            log.error("no live model — app not running")
            return .result()
        }
        if model.phase == .recording {
            model.pressUp()   // second press = send
            IntentsCoordinator.resetTaps()
            return .result()
        }
        _ = IntentsCoordinator.countTap()
        Haptics.tick()
        model.pressDown(channel: nil)   // press = start talking to the main channel
        return .result()
    }
}

/// Standalone "send a photo" trigger — handy for Back Tap or Lock Screen.
struct SlappPhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Slapp Photo"
    static let description = IntentDescription("Open the camera and send a photo (plus a voice note) to your agent.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Haptics.tick()
        IntentsCoordinator.model?.pressDown(channel: nil)
        return .result()
    }
}

/// Stop/discard a recording without sending (escapes accidental captures).
struct SlappCancelIntent: AppIntent {
    static let title: LocalizedStringResource = "Slapp Cancel"
    static let description = IntentDescription("Cancel an in-progress Slapp recording without sending it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentsCoordinator.model?.cancelHold()
        return .result()
    }
}
