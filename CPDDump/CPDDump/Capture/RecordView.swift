import SwiftUI
import AVFoundation

/// Full-screen voice capture. Recording starts the moment it appears —
/// "tap the mic tab, it's already recording".
struct RecordView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    var onDumped: () -> Void

    @State private var recorder = VoiceRecorder()
    @State private var permissionDenied = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Text("Say what happened").display(28)

            Text("ramble freely, dates, what you did and what you took away. the AI tidies it up!")
                .font(PaperInk.hand(20))
                .foregroundStyle(PaperInk.brandDark)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
                .tilt(-1.5)

            if permissionDenied {
                Text("Microphone access is off — enable it in Settings to record.")
                    .font(PaperInk.sans(13, weight: .semibold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            } else {
                waveform

                Text(recorder.elapsedLabel)
                    .font(.system(size: 27, weight: .bold, design: .monospaced))
                    .monospacedDigit()

                recordButton

                if recorder.isPaused {
                    Text("paused — dump it or keep going")
                        .font(PaperInk.hand(19))
                        .foregroundStyle(PaperInk.stone500)
                }
            }

            HStack(spacing: 14) {
                Button("Cancel") {
                    recorder.discard()
                    dismiss()
                }
                .font(PaperInk.sans(14, weight: .semibold))
                .foregroundStyle(PaperInk.stone500)

                Button { dumpIt() } label: {
                    HStack(spacing: 7) {
                        Sparkle(size: 14, color: .white)
                        Text("Dump it")
                    }
                }
                .buttonStyle(InkButtonStyle(prominent: true))
                .disabled(permissionDenied || recorder.elapsed < 1)
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaperInk.paper)
        .task {
            if await recorder.start() == false {
                permissionDenied = true
            }
        }
        .onDisappear { recorder.discard() }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(recorder.levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 3)
                    .fill(PaperInk.brand)
                    .frame(width: 4, height: max(6, level * 54))
            }
        }
        .frame(height: 54)
        .animation(.linear(duration: 0.05), value: recorder.levels)
    }

    private var recordButton: some View {
        Button {
            recorder.togglePause()
        } label: {
            Group {
                if recorder.isPaused {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white)
                        .frame(width: 26, height: 26)
                }
            }
            .frame(width: 84, height: 84)
            .background(PaperInk.brand)
            .clipShape(Circle())
            .overlay(Circle().stroke(PaperInk.ink, lineWidth: 3))
            .stickerShadow(offset: 4, opacity: 1)
            .tilt(-1)
        }
        .buttonStyle(.plain)
    }

    private func dumpIt() {
        guard let fileURL = recorder.finish() else { return }
        UploadQueue.shared.enqueueAudio(fileURL: fileURL, session: session)
        onDumped()
        dismiss()
    }
}

/// AVAudioRecorder wrapper: AAC m4a @ 64 kbps mono (an hour ≈ 28 MB, inside
/// the server's 50 MB cap), metering for the waveform, pause/resume, and
/// interruption handling (calls, Siri).
@Observable
final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private(set) var levels: [CGFloat] = Array(repeating: 0.1, count: 28)
    private(set) var elapsed: TimeInterval = 0
    private(set) var isPaused = false

    var elapsedLabel: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    func start() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try? audioSession.setActive(true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )

        let url = FileManager.default.temporaryDirectory
            .appending(path: "recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]

        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        recorder.isMeteringEnabled = true
        guard recorder.record() else { return false }
        self.recorder = recorder

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // Average power is in dB (-160…0); map ~-50…0 to 0…1.
        let power = recorder.averagePower(forChannel: 0)
        let normalised = max(0, min(1, (CGFloat(power) + 50) / 50))
        levels.removeFirst()
        levels.append(max(0.08, normalised))
    }

    func togglePause() {
        guard let recorder else { return }
        if isPaused {
            recorder.record()
            isPaused = false
        } else {
            recorder.pause()
            isPaused = true
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        if type == .began, !isPaused {
            togglePause()
        }
    }

    /// Stops and returns the file for upload.
    func finish() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        let url = recorder.url
        cleanUp()
        return url
    }

    /// Stops and deletes the file.
    func discard() {
        guard let recorder else { return }
        recorder.stop()
        try? FileManager.default.removeItem(at: recorder.url)
        cleanUp()
    }

    private func cleanUp() {
        recorder = nil
        meterTimer?.invalidate()
        meterTimer = nil
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
