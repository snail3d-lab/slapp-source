import SwiftUI

/// The one button. A microphone until you start typing — then the paper
/// plane. Hold to talk. Double-tap to latch (up to 20 minutes — feed it
/// audio, think out loud). While latched, one tap stops and the words land
/// in the field for editing; nothing ever auto-fires from a latch.
/// While holding:
///   · release, or swipe left → the words typewrite themselves into the field
///   · swipe up              → straight to the agent, ripple across the paper
struct MicSendButton: View {    var tint: Color
    var size: CGFloat = 54
    @Binding var draft: String
    /// called when the words should go straight to the agent (swipe-up)
    var onSend: () -> Void
    /// called for the ripple when a swipe-up send happens
    var onRipple: () -> Void
    var bridgeHost: String

    @State private var recording = false        // hold-to-talk in progress
    @State private var latched = false          // double-tap constant listen
    @State private var transcribing = false
    @State private var rec = RecBox()
    @State private var err: String?
    @State private var pressStart = Date.distantPast
    @State private var drag: CGSize = .zero
    @State private var lastTap = Date.distantPast
    @State private var tapTask: Task<Void, Never>?
    @State private var latchDeadline: Date?

    /// how long a press must hold before the mic wakes — deliberate, so a
    /// quick tap never means "listen"
    private let holdDelay: TimeInterval = 1.0

    private var active: Bool { recording || latched }

    var body: some View {
        ZStack {
            if transcribing {
                Text("writing your words…")
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.85)))
                    .offset(y: -(size / 2 + 26))
            }
            if latched {
                Text("listening — tap to stop (\(minutesLeft))")
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.85)))
                    .offset(y: -(size / 2 + 26))
            }
            if recording && drag != .zero { swipeGuide }
            if latched {
                // while latched the disc is a plain Button — taps must always
                // stop it, and Buttons deliver where a gesture can go deaf
                buttonVisual
                    .onTapGesture { stopLatch() }
            } else {
                buttonVisual
                    .contentShape(Circle().inset(by: -12))
                    .gesture(holdGesture)
            }
        }
        .onDisappear {
            // leaving the chat never leaves a mic live — words land in the field
            if latched || recording {
                latched = false
                latchDeadline = nil
                if recording { releaseToField(typewriter: false) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: drag)
        // the no-mic rule: silence is said with a slashed mic — no words, no emoji
        .overlay(alignment: .top) {
            if err != nil {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.red.opacity(0.75))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.92)))
                    .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
                    .offset(y: -(size / 2 + 26))
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .onChange(of: err) { e in
            guard e != nil else { return }
            Task { try? await Task.sleep(nanoseconds: 1_800_000_000); err = nil }
        }
    }

    /// the swipe: up = send, left = into the field
    private var swipeGuide: some View {
        VStack(spacing: 6) {
            if drag.height < -14 {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.6))
                    .offset(y: max(-30, drag.height * 0.4))
            }
            Spacer()
            if drag.width < -14 {
                HStack(spacing: 4) {
                    Image(systemName: "text.cursor")
                    Text("edit")
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.7))
                .offset(x: max(-36, drag.width * 0.5))
            }
        }
        .frame(width: 90, height: size + 40)
        .offset(y: -6)
    }

    private var minutesLeft: String {
        guard let dl = latchDeadline else { return "20:00" }
        let m = Int(dl.timeIntervalSinceNow) / 60
        let s = Int(dl.timeIntervalSinceNow) % 60
        return String(format: "%d:%02d", m, s)
    }

    private var button: some View {
        buttonVisual
            .contentShape(Circle().inset(by: -12))
            .gesture(holdGesture)
    }

    private var buttonVisual: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: size, height: size)
            Circle()
                .fill(active ? ChannelColor.alive : (draftHasWords ? Color.black.opacity(0.78) : tint))
                .frame(width: size * 0.82, height: size * 0.78)
                .scaleEffect(1 + (active ? 0.08 + levelPulse : 0))
            if transcribing {
                ProgressView().tint(.white)
            } else {
                Image(systemName: active ? "waveform" : (draftHasWords ? "paperplane.fill" : "mic.fill"))
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(active || draftHasWords ? .white : Color.black.opacity(0.7))
            }
        }
        .animation(.easeOut(duration: 0.08), value: active)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: draftHasWords)
    }

    @State private var levelTimer: Timer?

    /// cheap pulse while recording (level bars live on the pencil already)
    private var levelPulse: CGFloat {
        active ? 0.04 * CGFloat(1 + sin(Date().timeIntervalSince1970 * 6)) : 0
    }

    private var draftHasWords: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - the whole interaction lives in one gesture

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                // the press begins HERE — pressStart is set on first movement,
                // never left at distantPast (that made every tap look like a hold)
                if pressStart == .distantPast { pressStart = Date() }
                drag = v.translation
                let held = Date().timeIntervalSince(pressStart)
                if !recording && !latched && !transcribing && held >= holdDelay {
                    startRecording()
                }
            }
            .onEnded { v in
                drag = .zero
                let elapsed = Date().timeIntervalSince(pressStart)
                pressStart = .distantPast
                let moved = max(abs(v.translation.width), abs(v.translation.height))

                // a held press that recorded — release decides where words go.
                // latched counts as recording, and a plain release (or tap)
                // while latched means STOP — words to the field, latch off
                if recording {
                    if latched {
                        latched = false
                        latchDeadline = nil
                        releaseToField(typewriter: false)
                        return
                    }
                    if v.translation.height < -45 {
                        releaseAndSend()
                    } else if v.translation.width < -45 {
                        releaseToField(typewriter: true)
                    } else {
                        releaseToField(typewriter: false)
                    }
                    return
                }

                // latched but between recordings: any tap stops
                if latched {
                    tapTask?.cancel()
                    finishLatchOrRelease(intoField: true)
                    return
                }

                // a quick tap?
                if elapsed < holdDelay && moved < 12 {
                    // words in the field: the tap IS the send — no waiting
                    if draftHasWords {
                        tapTask?.cancel()
                        singleTap()
                        return
                    }
                    // empty field: double-tap latches the mic until stopped
                    if Date().timeIntervalSince(lastTap) < 0.35 {
                        lastTap = .distantPast
                        tapTask?.cancel()
                        startLatch()
                    } else {
                        lastTap = Date()
                        let t = lastTap
                        tapTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 380_000_000)
                            guard !Task.isCancelled, lastTap == t else { return }
                            // single tap on an empty field — nothing to send,
                            // nothing to say; a gentle knock so it's not dead
                            Haptics.tick()
                        }
                    }
                }
            }
    }

    private func singleTap() {
        if draftHasWords { onSend(); onRipple() }
    }

    private func startLatch() {
        guard !latched else { return }
        latched = true
        latchDeadline = Date().addingTimeInterval(20 * 60)
        startRecording()
        // hard cap at 20 minutes: stop → into the field, never auto-fired
        Task { @MainActor in
            while latched, let dl = latchDeadline, dl.timeIntervalSinceNow > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if latched { finishLatchOrRelease(intoField: true) }
        }
    }

    private func finishLatchOrRelease(intoField: Bool) {
        latched = false
        latchDeadline = nil
        if recording { stopAndTranscribe(typewriter: false, intoField: intoField) }
    }

    /// the latched disc was tapped — stop listening, words to the field
    private func stopLatch() {
        Haptics.tick()
        finishLatchOrRelease(intoField: true)
    }

    private func releaseAndSend() {
        recording = false
        guard let wav = rec.stop() else { return }
        transcribing = true
        Task { @MainActor in
            let text = await transcribe(wav) ?? ""
            transcribing = false
            if text.isEmpty { err = "missed" } else {
                draft = text          // put it in the field so it's in the log
                onSend()
                onRipple()
            }
        }
    }

    private func releaseToField(typewriter: Bool) {
        recording = false
        guard let wav = rec.stop() else { return }
        transcribing = true
        Task { @MainActor in
            let text = await transcribe(wav) ?? ""
            transcribing = false
            if text.isEmpty { err = "missed" } else { land(text, typewriter: typewriter) }
        }
    }

    private func stopAndTranscribe(typewriter: Bool, intoField: Bool) {
        recording = false
        guard let wav = rec.stop() else { return }
        transcribing = true
        Task { @MainActor in
            let text = await transcribe(wav) ?? ""
            transcribing = false
            if text.isEmpty { err = "missed" } else if intoField {
                land(text, typewriter: true)
            }
        }
    }

    /// words landing in the field — typewritten when asked
    private func land(_ text: String, typewriter: Bool) {
        guard !text.isEmpty else { return }
        if !typewriter {
            draft = draft.isEmpty ? text : draft + " " + text
            return
        }
        let base = draft.isEmpty ? "" : draft + " "
        Task { @MainActor in
            draft = base
            for ch in text {
                if Task.isCancelled { break }
                draft.append(ch)   // typewriter: one character at a time
                try? await Task.sleep(nanoseconds: 14_000_000)
            }
        }
    }

    private func startRecording() {
        try? rec.start()
        recording = true
    }

    private func transcribe(_ wav: Data) async -> String? {
        let slapp = SlappClient(bridgeHost: bridgeHost)
        return await slapp.transcribe(wav)
    }
}

/// tiny recorder box — wav, the house format
@MainActor
final class RecBox: ObservableObject {
    private let recorder = Recorder()
    func start() throws { try recorder.start() }
    func stop() -> Data? { recorder.stop() }
}

/// a photo waiting for markup — item-based, so the sheet presents cleanly
struct AnnotateItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

extension UIImage {
    /// bake the EXIF orientation into the pixels — the preview honors the
    /// tag, but compositing and re-encoding don't, so photos came out
    /// sideways after a send. after this, pixels are upright, tag is .up.
    func normalized() -> UIImage {
        guard imageOrientation != .up, let cg = cgImage else { return self }
        let orientation = imageOrientation
        var w = CGFloat(cg.width), h = CGFloat(cg.height)
        let swapped = orientation == .left || orientation == .leftMirrored
                   || orientation == .right || orientation == .rightMirrored
        if swapped { swap(&w, &h) }
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            let c = ctx.cgContext
            switch orientation {
            case .down, .downMirrored:
                c.translateBy(x: w, y: h); c.rotate(by: .pi)
            case .left, .leftMirrored:
                c.translateBy(x: w, y: 0); c.rotate(by: .pi / 2)
            case .right, .rightMirrored:
                c.translateBy(x: 0, y: h); c.rotate(by: -.pi / 2)
            default: break
            }
            switch orientation {
            case .upMirrored, .downMirrored:
                c.translateBy(x: w, y: 0); c.scaleBy(x: -1, y: 1)
            case .leftMirrored, .rightMirrored:
                c.translateBy(x: h, y: 0); c.scaleBy(x: -1, y: 1)
            default: break
            }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
}

/// a white ring that blooms outward across the paper — the send ripple
struct RippleView: View {
    let onDone: () -> Void
    @State private var grown = false
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(grown ? 0 : 0.85), lineWidth: 2.5)
                .scaleEffect(grown ? 1 : 0.02)
            Circle()
                .fill(Color.white.opacity(grown ? 0 : 0.35))
                .scaleEffect(grown ? 1 : 0.02)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { grown = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 950_000_000)
                onDone()
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
