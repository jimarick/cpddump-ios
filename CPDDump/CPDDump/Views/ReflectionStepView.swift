import SwiftUI
import AVFoundation

/// Step 2 of the review wizard: one editable answer per profession prompt,
/// each with dictation (mic → /ai/transcribe) and the ✦ sparkle button
/// (→ /ai/text-assist), mirroring the web.
struct ReflectionStepView: View {
    @Environment(Session.self) private var session

    var prompts: [Reference.ReflectionPrompt]
    @Binding var answers: [String: String]
    var assistContext: String

    @State private var busyKey: String?
    @State private var recorder = DictationRecorder()
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if prompts.isEmpty {
                Text("No reflection prompts for your profession — skip ahead.")
                    .font(PaperInk.sans(13))
                    .foregroundStyle(PaperInk.stone500)
            }

            ForEach(prompts) { prompt in
                promptField(prompt)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 5) {
                Sparkle(size: 13)
                Text("dictate your ramble, then let the sparkle tidy it into prose")
                    .font(PaperInk.hand(19))
                    .foregroundStyle(PaperInk.brandDark)
                    .tilt(-1)
            }
        }
    }

    private func promptField(_ prompt: Reference.ReflectionPrompt) -> some View {
        let isBusy = busyKey == prompt.key
        let isRecording = recorder.isRecording && recorder.activeKey == prompt.key

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom) {
                FieldLabel(text: prompt.label)
                Spacer()

                Button {
                    toggleDictation(for: prompt.key)
                } label: {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(isRecording ? .red : PaperInk.stone500)
                }
                .disabled(isBusy)

                Button {
                    sparkle(prompt)
                } label: {
                    if isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Sparkle(size: 15)
                    }
                }
                .disabled(isBusy || recorder.isRecording)
            }

            TextField(prompt.question, text: binding(for: prompt.key), axis: .vertical)
                .font(PaperInk.sans(14))
                .lineLimit(3 ... 10)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isRecording ? .red : PaperInk.ink.opacity(0.35), lineWidth: 1.5)
                )
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { answers[key] ?? "" },
            set: { answers[key] = $0 }
        )
    }

    private func toggleDictation(for key: String) {
        errorMessage = nil
        if recorder.isRecording {
            guard let fileURL = recorder.stop() else { return }
            busyKey = key
            Task {
                defer { busyKey = nil }
                do {
                    let text = try await session.api.transcribe(audioFile: fileURL)
                    let existing = answers[key] ?? ""
                    answers[key] = existing.isEmpty ? text : existing + " " + text
                } catch {
                    errorMessage = error.localizedDescription
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        } else {
            Task {
                if await recorder.start(key: key) == false {
                    errorMessage = "Microphone access is needed to dictate — enable it in Settings."
                }
            }
        }
    }

    private func sparkle(_ prompt: Reference.ReflectionPrompt) {
        busyKey = prompt.key
        errorMessage = nil
        Task {
            defer { busyKey = nil }
            do {
                answers[prompt.key] = try await session.api.textAssist(
                    field: prompt.question,
                    text: answers[prompt.key],
                    context: assistContext
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Short-clip dictation recorder: AAC m4a, mono, 64 kbps — matches the
/// transcription endpoint's accepted types and 15 MB cap.
@Observable
final class DictationRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var isRecording = false
    private(set) var activeKey: String?

    func start(key: String) async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appending(path: "dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]

        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else {
            return false
        }
        self.recorder = recorder
        activeKey = key
        isRecording = true
        return true
    }

    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        let url = recorder.url
        self.recorder = nil
        isRecording = false
        activeKey = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }
}
