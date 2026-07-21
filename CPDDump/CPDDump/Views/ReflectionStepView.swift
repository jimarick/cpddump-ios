import SwiftUI
import AVFoundation

/// Cross-step state for the talk-first reflection capture. Owned by the
/// presenting sheet (which outlives step switches), never by the step
/// itself — a dictated ramble must survive leaving and revisiting the step.
struct ReflectionTalkState {
    var ramble = ""
    /// True once the per-prompt boxes have been shown — the capture box
    /// never comes back mid-edit after that.
    var dismissed = false
    /// True once the ramble has been AI-shaped into the boxes.
    var shaped = false
}

/// Step 2 of the review wizard, mirroring the web. Talk-first when every
/// answer is empty: one capture box, the profession's questions stated up
/// front, a big mic, and "shape into reflections" (→ /ai/reflection-draft).
/// Otherwise one editable answer per prompt, each with dictation
/// (mic → /ai/transcribe) and the ✦ sparkle button (→ /ai/text-assist).
struct ReflectionStepView: View {
    @Environment(Session.self) private var session

    var prompts: [Reference.ReflectionPrompt]
    @Binding var answers: [String: String]
    var assistContext: String
    @Binding var talk: ReflectionTalkState
    /// Vertical size of each answer box — the review wizard passes a
    /// taller range so the boxes read as writing spaces.
    var boxLineLimit: ClosedRange<Int> = 3 ... 10

    @State private var busyKey: String?
    @State private var recorder = DictationRecorder()
    @State private var errorMessage: String?
    @State private var typing = false
    @State private var shaping = false

    private var allEmpty: Bool {
        prompts.allSatisfy { (answers[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var talkMode: Bool {
        !talk.dismissed && !prompts.isEmpty && allEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if prompts.isEmpty {
                Text("No reflection prompts for your profession — skip ahead.")
                    .font(PaperInk.sans(13))
                    .foregroundStyle(PaperInk.stone500)
            }

            if talkMode {
                talkFirstCapture
            } else {
                boxesContent
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Talk-first capture

    private var talkFirstCapture: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldLabel(text: "Reflection")
            Text("Talk it through.")
                .font(PaperInk.display(24))
                .foregroundStyle(PaperInk.ink)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(prompts.enumerated()), id: \.element.key) { index, prompt in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(PaperInk.display(14))
                            .foregroundStyle(PaperInk.brand)
                        Text(prompt.label)
                            .font(PaperInk.sans(14))
                            .foregroundStyle(PaperInk.stone600)
                    }
                }
            }

            if talk.ramble.isEmpty && !typing {
                emptyCaptureBox
            } else {
                rambleBox
            }

            Button {
                talk.dismissed = true
            } label: {
                Text("or fill in the \(prompts.count) boxes yourself")
                    .font(PaperInk.sans(12))
                    .foregroundStyle(PaperInk.stone500)
                    .underline(true, pattern: .dash)
            }
            .disabled(shaping)
        }
    }

    private var isTalkRecording: Bool {
        recorder.isRecording && recorder.activeKey == Self.rambleKey
    }

    private var emptyCaptureBox: some View {
        VStack(spacing: 12) {
            Button {
                toggleTalkDictation()
            } label: {
                Image(systemName: isTalkRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(isTalkRecording ? .red : PaperInk.brand)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(PaperInk.ink, lineWidth: 2))
                    .stickerShadow(offset: 3, opacity: 1)
            }
            .disabled(busyKey == Self.rambleKey)

            if busyKey == Self.rambleKey {
                Text("Tidying up…")
                    .font(PaperInk.sans(12.5))
                    .foregroundStyle(PaperInk.stone500)
            } else if isTalkRecording {
                Text("Listening — tap to stop.")
                    .font(PaperInk.sans(12.5))
                    .foregroundStyle(PaperInk.stone500)
            } else {
                VStack(spacing: 2) {
                    Text("**Tap to talk** — a minute of honest rambling is plenty.")
                        .font(PaperInk.sans(13))
                        .foregroundStyle(PaperInk.stone500)
                    Button("Typing works too") { typing = true }
                        .font(PaperInk.sans(12))
                        .foregroundStyle(PaperInk.stone500)
                        .underline(true, pattern: .dash)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 340)
        .padding(20)
        .background(PaperInk.paper)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(PaperInk.stone400, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
        )
    }

    private var rambleBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                "Why you picked it, what you took away, what might change…",
                text: $talk.ramble,
                axis: .vertical
            )
            .font(PaperInk.sans(14))
            .lineLimit(5 ... 14)

            HStack(spacing: 12) {
                Button {
                    shapeRamble()
                } label: {
                    HStack(spacing: 6) {
                        if shaping {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Sparkle(size: 13)
                        }
                        Text("Shape into \(prompts.count) reflections")
                    }
                }
                .buttonStyle(InkButtonStyle(prominent: true))
                .disabled(shaping || talk.ramble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    toggleTalkDictation()
                } label: {
                    Image(systemName: isTalkRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(isTalkRecording ? .red : PaperInk.stone500)
                }
                .disabled(shaping || busyKey == Self.rambleKey)
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PaperInk.ink, lineWidth: 2))
    }

    private static let rambleKey = "_ramble"

    private func toggleTalkDictation() {
        errorMessage = nil
        if recorder.isRecording {
            guard let fileURL = recorder.stop() else { return }
            busyKey = Self.rambleKey
            Task {
                defer { busyKey = nil }
                do {
                    let text = try await session.api.transcribe(audioFile: fileURL)
                    talk.ramble = talk.ramble.isEmpty ? text : talk.ramble + " " + text
                } catch {
                    errorMessage = error.localizedDescription
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        } else {
            Task {
                if await recorder.start(key: Self.rambleKey) == false {
                    errorMessage = "Microphone access is needed to dictate — enable it in Settings."
                }
            }
        }
    }

    private func shapeRamble() {
        shaping = true
        errorMessage = nil
        Task {
            defer { shaping = false }
            do {
                let draft = try await session.api.reflectionDraft(
                    text: talk.ramble,
                    context: assistContext
                )
                for prompt in prompts {
                    answers[prompt.key] = (draft[prompt.key] ?? nil) ?? ""
                }
                talk.shaped = true
                talk.dismissed = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Per-prompt boxes

    /// Only the explicit shape action gets feedback — analyst provenance
    /// banners are gone (the notes step makes provenance obvious).
    private var provenance: String? {
        talk.shaped ? "Shaped from your dictation — edit anything, or tap a sparkle to redo one box." : nil
    }

    private var boxesContent: some View {
        Group {
            if let provenance {
                HStack(alignment: .top, spacing: 7) {
                    Sparkle(size: 11)
                    Text(provenance)
                        .font(PaperInk.sans(12))
                        .foregroundStyle(PaperInk.brandDark)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PaperInk.pale)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(PaperInk.brand, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
            }

            ForEach(prompts) { prompt in
                promptField(prompt)
            }

            Text("Dictate your ramble, then let the sparkle tidy it into prose")
                .font(PaperInk.hand(19))
                .foregroundStyle(PaperInk.brandDark)
                .tilt(-1)
        }
        .onAppear { talk.dismissed = true }
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
                .lineLimit(boxLineLimit)
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

    /// Grounding for a per-box sparkle redraft: the activity context, the
    /// other boxes' answers, and the original ramble — so a regenerate
    /// stays consistent with (and true to) the rest of the reflection.
    private func boxContext(excluding key: String) -> String {
        var parts = [assistContext]
        for prompt in prompts where prompt.key != key {
            let answer = (answers[prompt.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty { parts.append("\(prompt.label): \(answer)") }
        }
        let ramble = talk.ramble.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ramble.isEmpty { parts.append("The user's own reflection notes:\n\(ramble)") }
        return String(parts.joined(separator: "\n").prefix(4000))
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
                    context: boxContext(excluding: prompt.key)
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
