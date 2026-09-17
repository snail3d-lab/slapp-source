import Foundation
import SwiftUI
import os

/// The whole app's state machine: channels grid + per-channel hold-to-talk +
/// play-by-play. idle → recording → uploading → sent/failed, per channel.
@MainActor
final class CaptureModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case uploading
        case sent(String)
        case failed(String)
    }

    private static let log = Logger(subsystem: "com.snail3d.slapp", category: "capture")

    @Published var phase: Phase = .idle
    @Published var level: Double = 0
    @Published var elapsed: TimeInterval = 0
    @Published var channels: [Channel] = []
    @Published var channelsLoaded = false
    /// plain words for the empty paper: why there's nothing here yet
    @Published var connectionNote: String?
    private var healing = false               // one repair loop at a time
    /// plain words when a send goes wrong (the line moved, the road is down)
    @Published var sendNote: String?
    @Published var recordingChannel: String? = nil   // channel currently held
    @Published var asleepSlugs: Set<String> = []     // herdr space closed on the Mac — safe, asleep

    private let recorder = Recorder()
    private var startedAt: Date?
    private var micAllowed = false
    private var activeChannel: String?

    static let maxRecordSeconds: TimeInterval = 600   // runaway guard only — holds are yours

    var canStart: Bool {
        switch phase {
        case .idle, .sent, .failed: return true
        default: return false
        }
    }

    var client: BridgeClient {
        BridgeClient(config: BridgeConfig(), deviceID: DeviceIdentity.id, token: Keychain.get())
    }

    init() {
        recorder.onLevel = { [weak self] lvl in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.level = lvl
                if let t0 = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(t0)
                }
                if self.elapsed >= Self.maxRecordSeconds {
                    self.pressUp()
                }
            }
        }
    }

    /// Ask once up front so the first hold starts instantly.
    func ensureMicPermission() {
        guard !micAllowed else { return }
        Recorder.requestMicPermission { granted in
            Task { @MainActor in self.micAllowed = granted }
        }
    }

    lazy var slapp = SlappClient(bridgeHost: BridgeConfig().host)

    func slug(for channel: Channel) -> String? {
        for s in asleepSlugs where isSessionWebhook(channel.webhook, slug: s) { return s }
        return nil
    }

    func reveal(_ slug: String) async {
        _ = await slapp.reveal(slug)
    }

    func wake(_ slug: String) async {
        let (ok, note) = await slapp.wake(slug)
        if !ok, let note {
            // the Mac said no, in plain words — say it on the box
            connectionNote = note
            Haptics.play(.warning)
            Task { try? await Task.sleep(nanoseconds: 7_000_000_000); if connectionNote == note { connectionNote = nil } }
            return
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)   // give the tab a beat to open
        await refreshChannels()
    }

    // MARK: - Channels

    func refreshChannels() async {
        do {
            var fresh = try await client.channels()
            // the shifting previews: recent lines per channel, fetched cheaply
            for i in fresh.indices {
                fresh[i].previews = (try? await client.history(channel: fresh[i].id, n: 3)) ?? []
            }
            channels = fresh
            channelsLoaded = true
            connectionNote = nil
            // who's asleep on the Mac (herdr tab closed)? cheap sidecar check
            if let sl = try? await slapp.asleepSlugs() { asleepSlugs = sl }
        } catch BridgeError.http(let code, _) where code == 401 {
            Self.log.error("channels 401 — healing identity")
            connectionNote = "re-pairing with the Mac…"
            healIfRejected(401)
        } catch {
            // leave the old list; first failure before any load → empty grid retries on appear
            Self.log.error("channels fetch failed: \(error.localizedDescription)")
            if !channelsLoaded { connectionNote = "can't reach the Mac — is Tailscale on?" }
        }
    }

    func renameChannel(_ id: String, to name: String) async {
        _ = try? await client.renameChannel(id, name: name)
        await refreshChannels()
    }

    // MARK: - Hold to talk (per channel)

    func pressDown(channel: String?) {
        guard canStart else { return }
        guard micAllowed else {
            phase = .failed("Mic permission denied")
            return
        }
        do {
            try recorder.start()
        } catch {
            Self.log.error("mic start failed: \(error.localizedDescription)")
            phase = .failed("Mic error")
            return
        }
        activeChannel = channel
        recordingChannel = channel ?? "main"
        startedAt = Date()
        level = 0
        elapsed = 0
        phase = .recording
        Haptics.tick()
    }

    /// A touch that never became a talk: discard the recording, go quiet.
    func cancelHold() {
        guard phase == .recording else { return }
        _ = recorder.stop()
        activeChannel = nil
        recordingChannel = nil
        phase = .idle
        level = 0
        Haptics.tick()
    }

    func pressUp() {
        guard phase == .recording else { return }
        Haptics.tick()
        let channel = activeChannel
        activeChannel = nil
        recordingChannel = nil
        guard let wav = recorder.stop() else {
            Self.log.error("recorded wav missing — back to idle")
            phase = .idle
            return
        }
        Self.log.info("recording stopped: \(wav.count) bytes, \(self.elapsed, format: .fixed(precision: 1))s")
        phase = .uploading
        let ch = channel
        Task {
            do {
                let res = try await client.capture(audio: wav, channel: ch)
                phase = .sent(res.cid)
                Haptics.play(.success)
                await refreshChannels()
            } catch {
                Self.log.error("capture failed: \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
                Haptics.play(.warning)
            }
        }
    }

    /// A photo into a channel — the bridge hands it to the session's eyes.
    func sendPhoto(_ data: Data, channel: String?, caption: String = "") async -> Bool {
        do {
            _ = try await client.capture(audio: nil, photo: data, channel: channel, text: caption.isEmpty ? nil : caption)
            await refreshChannels()
            return true
        } catch {
            Self.log.error("photo send failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Typed input from a channel's keyboard bar.
    func sendText(_ text: String, channel: String?) async -> Bool {
        do {
            _ = try await client.sendText(text, channel: channel)
            sendNote = nil
            await refreshChannels()
            return true
        } catch BridgeError.http(let code, _) where code == 404 {
            // the line moved while the app slept — fetch the fresh list,
            // say so in plain words
            Self.log.error("text send 404 — channel moved, refreshing list")
            sendNote = "this line moved — try again"
            await refreshChannels()
            return false
        } catch {
            Self.log.error("text send failed: \(error.localizedDescription)")
            sendNote = "couldn't send — is Tailscale on?"
            return false
        }
    }

    // MARK: - Channel management

    func addChannel(name: String, kind: String, webhook: String?) async -> Bool {
        do {
            _ = try await client.createChannel(name: name, kind: kind, webhook: webhook)
            await refreshChannels()
            return true
        } catch {
            Self.log.error("add channel failed: \(error.localizedDescription)")
            return false
        }
    }

    func removeChannel(_ id: String) async {
        // a slappd session's tile IS the session: deleting it deletes the
        // live space in herdr too (bridge channel + daemon session)
        if let ch = channels.first(where: { $0.id == id }),
           let slug = ch.webhook.split(separator: "/").dropLast().last {
            _ = await SlappClient(bridgeHost: BridgeConfig().host).deleteSession(String(slug))
        }
        _ = try? await client.deleteChannel(id)
        await refreshChannels()
    }


    /// Silent pairing attempt on launch — succeeds only while a pairing
    /// window is open on the bridge.
    /// self-healing: a dead token (fresh install, wiped registry) re-pairs
    func healIfRejected(_ status: Int) {
        guard status == 401 else { return }
        // one repair at a time — every 401 used to spawn its own 10-minute
        // knock loop (13k requests in a day); a healing flag gates it now
        guard !healing else { return }
        healing = true
        // the Mac opens the bridge's pairing window for us — then knock
        Task {
            await slapp.openPairWindow()
            pairIfPossible()
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            healing = false
        }
        Keychain.clear()
    }

    func pairIfPossible() {
        guard Keychain.get() == nil else { return }
        let c = client
        Task {
            // pairing windows are short; keep knocking for 10 minutes —
            // the Mac holds windows open during heal seasons
            for _ in 0..<40 {
                if Keychain.get() != nil { return }
                if let token = try? await c.register() {
                    Keychain.set(token)
                    connectionNote = nil
                    await refreshChannels()
                    return
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
            if !channelsLoaded { connectionNote = "couldn't pair — open Slapp again, or tap settings → pair" }
        }
    }
}
