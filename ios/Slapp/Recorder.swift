import AVFoundation

/// Records 16 kHz / mono / 16-bit Linear PCM WAV — the exact format the
/// ESP32 fleet sends and the bridge's faster-whisper STT expects.
final class Recorder {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private(set) var fileURL: URL?

    /// Fired ~20x/s while recording on the main run loop, 0...1.
    var onLevel: ((Double) -> Void)?

    static func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission(completion)
    }

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord can be refused on real hardware — degrade, never crash
        do { try session.setCategory(.playAndRecord, mode: .default) }
        catch { try? session.setCategory(.record, mode: .default) }
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("slapp-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.record() else {
            throw NSError(domain: "slapp", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "recorder failed to start"])
        }
        recorder = rec
        fileURL = url

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let rec = self.recorder else { return }
            rec.updateMeters()
            let db = rec.averagePower(forChannel: 0)   // ~-160...0
            let level = max(0.0, min(1.0, (Double(db) + 50) / 50))
            self.onLevel?(level)
        }
    }

    /// Stops recording and returns the WAV bytes (nil on failure / too short).
    func stop() -> Data? {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let url = fileURL else { return nil }
        defer {
            try? FileManager.default.removeItem(at: url)
            fileURL = nil
        }
        guard let data = try? Data(contentsOf: url), data.count > 44 + 320 else { return nil }
        return data
    }
}
