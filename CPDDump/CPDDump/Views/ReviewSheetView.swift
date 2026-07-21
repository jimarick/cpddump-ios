import SwiftUI

/// The web's four-step review wizard (The facts / Your notes / Details &
/// reflections / Takeaways) as a native bottom sheet: editable title up
/// top, linear Next/Back with a "N of 4" counter. Next out of the notes
/// step runs the one AI pass (compose-review) that shapes the notes into
/// prose, reflections and takeaways — and files categories silently.
/// Every sensitive-info / keep-file decision is deferred to the "Before
/// this is saved" confirm sheet — the form itself carries no warning
/// banners.
struct ReviewSheetView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    let item: InboxItem
    var onResolved: () -> Void
    /// Present the merge sheet seeded with this item + its suggested matches.
    var onMergeInstead: ((MergeSeed) -> Void)?

    enum Step: Int, CaseIterable {
        case facts, notes, reflect, takeaways
    }

    @State private var step: Step = .facts

    // Step 1 — the facts
    @State private var title = ""
    @State private var typeSlug = ""
    @State private var points = ""
    @State private var startsOn: Date = .now
    @State private var endsOn: Date = .now
    @State private var organisation = ""

    // Step 2 — the user's own words, verbatim; submitted as source_notes
    @State private var sourceNotes = ""
    /// What the last AI pass composed from (the import analysis already
    /// covered the seeded value) — Next skips the call when nothing changed.
    @State private var composedNotes = ""
    @State private var recorder = DictationRecorder()
    @State private var transcribing = false

    // Step 3 — details prose + reflection answers keyed by prompt key
    @State private var summary = ""
    @State private var reflection: [String: String] = [:]
    @State private var composing = false

    // Step 4 — takeaways: per-card selection. Everything starts
    // deselected; only selected cards survive approval.
    @State private var nuggets: [Takeaway] = []
    @State private var actions: [Takeaway] = []
    @State private var selectedTakeawayIds: Set<String> = []
    @State private var editingTakeawayId: String?
    @State private var addingKind: String?
    @State private var newTakeawayText = ""

    // Filed silently — seeded by the analysis, replaced by each compose pass
    @State private var categorySlugs: Set<String> = []
    @State private var domainCodes: Set<String> = []
    @State private var attributeCodes: [String] = []
    @State private var projectIds: Set<Int> = []

    @State private var confirmingSave = false
    @State private var confirmingBin = false
    @State private var showingPicker = false
    @State private var previewFile: PreviewFile?
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var analysis: AiAnalysis? { item.aiAnalysis }
    private var reference: Reference? { session.reference }

    private var keepableFiles: [AttachmentRef] {
        item.attachments.filter { $0.purged != true }
    }

    private var asksAboutFiles: Bool {
        session.user?.asksAboutAttachments ?? true && !keepableFiles.isEmpty
    }

    var body: some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(PaperInk.ink.opacity(0.2))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Merging is a facts-page decision — later steps stay focused.
                    if step == .facts, let suggestions = item.mergeSuggestions, !suggestions.isEmpty, onMergeInstead != nil {
                        mergeSuggestionBox(suggestions)
                    }

                    switch step {
                    case .facts: factsStep
                    case .notes: notesStep
                    case .reflect: reflectStep
                    case .takeaways: takeawaysStep
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)

            footer
        }
        .background(.white)
        .task {
            await session.loadReference()
            seedFromAnalysis()
        }
        .confirmationDialog(
            "Bin “\(title.isEmpty ? item.displayTitle : title)”?",
            isPresented: $confirmingBin,
            titleVisibility: .visible
        ) {
            Button("Bin it", role: .destructive) { bin() }
            if item.source == "email" || item.source == "calendar" {
                Button("Bin & never show items like this", role: .destructive) {
                    bin(neverAgain: true)
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Binned means deleted — the draft and any files are gone for good.")
        }
        .sheet(isPresented: $showingPicker) {
            MergePickerSheet(
                baseLabel: title.isEmpty ? item.displayTitle : title,
                baseItemId: item.id
            ) { seed in
                onMergeInstead?(seed)
                dismiss()
            }
        }
        .sheet(item: $previewFile) { file in
            AttachmentQuickLook(url: file.url)
        }
        .sheet(isPresented: $confirmingSave) {
            ApproveConfirmSheet(
                files: asksAboutFiles
                    ? keepableFiles.map { ConfirmFile(id: $0.id, name: $0.name ?? "Attachment \($0.id)") }
                    : [],
                flags: item.piiGate == true
                    ? (item.aiWarnings?.piiFlags ?? []).map {
                        SensitiveFlag(type: $0.type, excerpt: $0.excerpt.isEmpty ? nil : $0.excerpt)
                    }
                    : [],
                flagLocation: item.piiGate == true && !keepableFiles.isEmpty && !asksAboutFiles
                    ? "an attached file"
                    : nil,
                verb: "Approve",
                isWorking: isWorking,
                onConfirm: { keepIds, piiAck in
                    submitApprove(keepIds: keepIds, piiAck: piiAck)
                },
                onRemoveInfo: item.piiGate == true && keepableFiles.isEmpty
                    ? { removeInfoAndApprove() }
                    : nil,
                onCancel: { confirmingSave = false }
            )
        }
    }

    // MARK: Header — editable title + step counter, as on the web

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if item.status == .failed {
                Text("Analysis failed").display(22)
            } else if step == .facts {
                // Only the facts page edits the title — later pages carry
                // their own heading so the body stays uncluttered.
                TextField("Untitled evidence", text: $title, axis: .vertical)
                    .font(PaperInk.display(21))
                    .lineLimit(1 ... 3)
            } else {
                Text(stepTitle)
                    .display(21)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if item.status != .failed {
                Text("\(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(PaperInk.stone400)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
    }

    private var stepTitle: String {
        switch step {
        case .facts: title
        case .notes, .reflect: "Your notes & reflections"
        case .takeaways: "Key takeaways"
        }
    }

    // MARK: Steps

    /// Step 1: just the facts — title (in the header), dates, points, type,
    /// organisation. The prose lives on step 3 now.
    private var factsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if item.status == .failed {
                Text(item.failureReason ?? "Analysis failed. You can retry, or fill the details in manually.")
                    .font(PaperInk.sans(13))
                    .foregroundStyle(PaperInk.stone600)
            }

            // One field per line, matching the web's single-column facts page.
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Dates")
                HStack(spacing: 6) {
                    DatePicker("", selection: $startsOn, displayedComponents: .date)
                        .labelsHidden()
                    Text("→").foregroundStyle(PaperInk.stone400)
                    DatePicker("", selection: $endsOn, displayedComponents: .date)
                        .labelsHidden()
                    Spacer(minLength: 0)
                }
                .onChange(of: startsOn) {
                    if endsOn < startsOn { endsOn = startsOn }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Type")
                Menu {
                    ForEach(reference?.activityTypes ?? []) { type in
                        Button(type.name) { typeSlug = type.slug }
                    }
                } label: {
                    menuLabel(typeName)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Project / goal")
                Menu {
                    Button("None") { projectIds = [] }
                    ForEach(reference?.projects ?? []) { project in
                        Button(project.title) { projectIds = [project.id] }
                    }
                } label: {
                    menuLabel(projectName)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    FieldLabel(text: "CPD points")
                    CpdPointsInfoButton()
                }
                TextField("1", text: $points)
                    .keyboardType(.decimalPad)
                    .font(PaperInk.sans(14))
                    .boxed()
            }

            // No Organisation input (parity with the web facts page) — the
            // AI-extracted value still rides in the compose/approve
            // payloads untouched.

            if !item.attachments.isEmpty {
                AttachmentChips(attachments: item.attachments, preview: $previewFile)
            }

            if onMergeInstead != nil {
                Button {
                    showingPicker = true
                } label: {
                    Text("Merge with another entry…")
                        .font(PaperInk.sans(12, weight: .semibold))
                        .foregroundStyle(PaperInk.stone500)
                        .underline(true, pattern: .dash)
                }
                .buttonStyle(.plain)
            }

            sparkline(confidenceNote)
        }
    }

    private var confidenceNote: String {
        if let confidence = analysis?.confidence {
            return "Drafted from your \(item.sourceLabel.lowercased()) (AI confidence \(Int(confidence * 100))%) — edit anything."
        }
        return "Drafted from your \(item.sourceLabel.lowercased()) — edit anything."
    }

    /// "Looks like something you already have" — accepting jumps straight to
    /// the merge sheet, where the existing entry's reflection is pre-filled
    /// and the user reflects once, on the combined whole. Ignorable; it
    /// simply appears again next time a match exists.
    private func mergeSuggestionBox(_ suggestions: [MergeSuggestion]) -> some View {
        HStack(spacing: 8) {
            Sparkle(size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text("Looks like “\(suggestions[0].title)”")
                    .font(PaperInk.sans(12.5, weight: .bold))
                    .lineLimit(1)
                if suggestions.count > 1 {
                    Text("+\(suggestions.count - 1) more")
                        .font(PaperInk.sans(11))
                        .foregroundStyle(PaperInk.stone500)
                }
            }
            Spacer(minLength: 4)
            Button("Merge instead") {
                let activities = suggestions.filter { $0.kind == "activity" }
                let target = activities.first { $0.merged == true }

                onMergeInstead?(MergeSeed(
                    activityIds: activities.filter { $0.id != target?.id }.map(\.id),
                    inboxItemIds: [item.id] + suggestions.filter { $0.kind == "inbox" }.map(\.id),
                    intoActivityId: target?.id
                ))
                dismiss()
            }
            .font(PaperInk.sans(12, weight: .bold))
            .foregroundStyle(PaperInk.brandDark)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperInk.tint.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(PaperInk.brand.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
    }

    /// Step 2: the user's own words, verbatim and editable — this exact
    /// text is what approval submits as `source_notes`.
    private var notesStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom) {
                    FieldLabel(text: "Your notes")
                    Spacer()
                    Button {
                        toggleNotesDictation()
                    } label: {
                        Image(systemName: isNotesRecording ? "stop.circle.fill" : "mic.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(isNotesRecording ? .red : PaperInk.stone500)
                    }
                    .disabled(transcribing)
                }
                // A big, inviting canvas — reserve most of the step for it
                // so a long paste or dictation feels at home.
                TextField(
                    "What happened, what you took away, what you'd do differently…",
                    text: $sourceNotes,
                    axis: .vertical
                )
                .lineLimit(26 ... 60)
                .font(PaperInk.sans(14))
                .boxed()
                if transcribing {
                    Text("Tidying up…")
                        .font(PaperInk.sans(11))
                        .foregroundStyle(PaperInk.stone500)
                } else if isNotesRecording {
                    Text("Listening — tap to stop.")
                        .font(PaperInk.sans(11))
                        .foregroundStyle(PaperInk.stone500)
                }
            }

            HStack(alignment: .top, spacing: 6) {
                Text("Dictate or type — AI will turn this into reflections and key takeaways in the next step")
                    .font(PaperInk.hand(20))
                    .foregroundStyle(PaperInk.brandDark)
                    .tilt(-1)
                // From the end of the note, curving up into the notes box:
                // tail by the last words, arrowhead pointing up at the box.
                ScribbleArrow()
                    .scaleEffect(y: -1)
                    .offset(y: -14)
                Spacer(minLength: 0)
            }
        }
    }

    private var isNotesRecording: Bool {
        recorder.isRecording
    }

    /// Same dictation pattern as everywhere else: short AAC clip →
    /// ai/transcribe → transcript appends to whatever's typed already.
    private func toggleNotesDictation() {
        errorMessage = nil
        if recorder.isRecording {
            guard let fileURL = recorder.stop() else { return }
            transcribing = true
            Task {
                defer { transcribing = false }
                do {
                    let text = try await session.api.transcribe(audioFile: fileURL)
                    sourceNotes = sourceNotes.isEmpty ? text : sourceNotes + " " + text
                } catch {
                    errorMessage = error.localizedDescription
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        } else {
            Task {
                if await recorder.start(key: "notes") == false {
                    errorMessage = "Microphone access is needed to dictate — enable it in Settings."
                }
            }
        }
    }

    /// Step 3: the ≤2-sentence prose plus the profession's reflection
    /// boxes — or the AI working state while compose-review runs.
    @ViewBuilder
    private var reflectStep: some View {
        if composing {
            ComposeWorkingView(skeletonCount: min((reference?.reflectionPrompts.count ?? 3) + 1, 5))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                // Tall boxes throughout — writing spaces, not glance fields.
                labelled("Details") {
                    TextField("What happened, in a sentence or two", text: $summary, axis: .vertical)
                        .lineLimit(7 ... 20)
                }

                // Boxes only — the notes step supersedes the talk-first capture.
                ReflectionStepView(
                    prompts: reference?.reflectionPrompts ?? [],
                    answers: $reflection,
                    assistContext: assistContext,
                    talk: .constant(ReflectionTalkState(dismissed: true)),
                    boxLineLimit: 7 ... 20
                )
            }
        }
    }

    /// Step 4: the AI's suggestions as a selectable pinboard grid. All
    /// cards start deselected; tapping selects (kind-coloured border +
    /// check badge). Only selected cards survive approval — the rest are
    /// discarded.
    private var takeawaysStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Select the ones you want to store")
                        .font(PaperInk.sans(15.5, weight: .bold))
                        .foregroundStyle(PaperInk.ink)
                    Text("They're fed back to you as notifications and weekly recaps to reinforce your learning. Anything left unselected is discarded when you approve.")
                        .font(PaperInk.sans(12.5))
                        .foregroundStyle(PaperInk.stone500)
                }

                Spacer(minLength: 4)

                selectAllButton
            }
            // Breathing room at the scroll edge so the outline button's
            // border and shadow aren't clipped at the top.
            .padding(.top, 4)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                ForEach($nuggets) { $item in
                    takeawayCard(
                        $item,
                        isAction: false,
                        index: nuggets.firstIndex { $0.id == item.id } ?? 0
                    )
                }
                ForEach($actions) { $item in
                    takeawayCard(
                        $item,
                        isAction: true,
                        index: nuggets.count + (actions.firstIndex { $0.id == item.id } ?? 0)
                    )
                }
                addCard
            }
        }
    }

    private var allTakeawayIds: Set<String> {
        Set(nuggets.map(\.id) + actions.map(\.id))
    }

    private var selectAllButton: some View {
        let all = allTakeawayIds
        let allSelected = !all.isEmpty && all.isSubset(of: selectedTakeawayIds)

        return Button(allSelected ? "Deselect all" : "Select all") {
            withAnimation(.snappy) {
                selectedTakeawayIds = allSelected ? [] : all
            }
        }
        .font(PaperInk.sans(12, weight: .bold))
        .foregroundStyle(PaperInk.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(PaperInk.ink, lineWidth: 1.5))
        .buttonStyle(.plain)
        .disabled(all.isEmpty)
    }

    /// Alternating pinboard tilts, like the tray rows.
    private static let cardTilts: [Double] = [-0.7, 0.5, -0.4, 0.8, -0.6]

    /// One square-ish card: tap to select/deselect, pencil to edit in
    /// place (confirming with cleared text deletes it).
    private func takeawayCard(_ item: Binding<Takeaway>, isAction: Bool, index: Int) -> some View {
        let id = item.wrappedValue.id
        let selected = selectedTakeawayIds.contains(id)
        let editing = editingTakeawayId == id
        let kindColor = isAction ? PaperInk.brand : PaperInk.ink

        return Group {
            if editing {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("", text: item.text, axis: .vertical)
                        .font(PaperInk.sans(12.5))
                        .lineLimit(2 ... 5)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button {
                            commitEdit(item, isAction: isAction)
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(PaperInk.brandDark)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text(item.wrappedValue.text)
                    .font(PaperInk.sans(12.5))
                    .foregroundStyle(selected ? PaperInk.ink : PaperInk.stone500)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy) { toggleTakeawaySelection(id) }
                    }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity, alignment: .topLeading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? kindColor : PaperInk.stone400, lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) {
            if selected && !editing {
                ZStack {
                    Circle().fill(kindColor).frame(width: 18, height: 18)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                .offset(x: 6, y: -6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !editing {
                Button {
                    editingTakeawayId = id
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(PaperInk.stone400)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
        }
        .stickerShadow(offset: selected ? 3 : 0, opacity: selected ? 0.14 : 0)
        .tilt(Self.cardTilts[index % Self.cardTilts.count])
    }

    private func toggleTakeawaySelection(_ id: String) {
        if selectedTakeawayIds.contains(id) {
            selectedTakeawayIds.remove(id)
        } else {
            selectedTakeawayIds.insert(id)
        }
    }

    /// The dotted ＋ card at the end of the grid — becomes an inline editor
    /// with a tiny nugget/action pill toggle; new items arrive selected.
    @ViewBuilder
    private var addCard: some View {
        if let kind = addingKind {
            let isAction = kind == "action"
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    addingKind = isAction ? "nugget" : "action"
                } label: {
                    Text(kind)
                        .font(PaperInk.sans(10, weight: .heavy))
                        .textCase(.uppercase)
                        .kerning(0.5)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(isAction ? PaperInk.tint : PaperInk.paperAlt)
                        .foregroundStyle(isAction ? PaperInk.brandDark : PaperInk.ink)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(isAction ? PaperInk.brand : PaperInk.ink, lineWidth: 1.5))
                }
                .buttonStyle(.plain)

                TextField(
                    isAction ? "Something to chase" : "Something to remember",
                    text: $newTakeawayText,
                    axis: .vertical
                )
                .font(PaperInk.sans(12.5))
                .lineLimit(2 ... 4)
                .onSubmit { commitNewTakeaway() }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Button {
                        commitNewTakeaway()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(PaperInk.brandDark)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity, alignment: .topLeading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isAction ? PaperInk.brand : PaperInk.ink, lineWidth: 2)
            )
        } else {
            Button {
                addingKind = "nugget"
                newTakeawayText = ""
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(PaperInk.stone500)
                    .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(PaperInk.stone400, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a takeaway")
        }
    }

    private func commitEdit(_ item: Binding<Takeaway>, isAction: Bool) {
        editingTakeawayId = nil
        if item.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remove(item.wrappedValue, isAction: isAction)
        }
    }

    private func remove(_ item: Takeaway, isAction: Bool) {
        selectedTakeawayIds.remove(item.id)
        if isAction {
            actions.removeAll { $0.id == item.id }
        } else {
            nuggets.removeAll { $0.id == item.id }
        }
    }

    private func commitNewTakeaway() {
        let text = newTakeawayText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            addingKind = nil
            newTakeawayText = ""
        }
        guard !text.isEmpty else { return }
        let item = Takeaway(id: UUID().uuidString, text: text)
        // The server caps each list at 15 — don't build an unapprovable wall.
        if addingKind == "action" {
            guard actions.count < 15 else { return }
            actions.append(item)
        } else {
            guard nuggets.count < 15 else { return }
            nuggets.append(item)
        }
        // Adding something yourself is selecting it.
        selectedTakeawayIds.insert(item.id)
    }

    // MARK: The AI pass — Next out of the notes step

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(.snappy) { step = next }
        if next == .reflect { composeIfNeeded() }
    }

    /// Compose only when the notes exist and changed since the last pass —
    /// the import analysis already covered the seeded value.
    private func composeIfNeeded() {
        let notes = sourceNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty, notes != composedNotes else { return }
        composing = true
        errorMessage = nil
        Task {
            defer { composing = false }
            do {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let composed = try await session.api.composeReview(
                    notes: notes,
                    title: title.isEmpty ? nil : title,
                    activityTypeSlug: typeSlug.isEmpty ? nil : typeSlug,
                    startsOn: formatter.string(from: startsOn),
                    organisation: organisation.isEmpty ? nil : organisation,
                    cpdPoints: Double(points.replacingOccurrences(of: ",", with: "."))
                )
                if let details = composed.details { summary = details }
                if let draft = composed.reflection {
                    for prompt in reference?.reflectionPrompts ?? [] {
                        reflection[prompt.key] = (draft[prompt.key] ?? nil) ?? ""
                    }
                }
                if let fresh = composed.nuggets { nuggets = fresh }
                if let fresh = composed.actions { actions = fresh }
                if composed.nuggets != nil || composed.actions != nil {
                    // Fresh suggestions — selection starts over.
                    selectedTakeawayIds = []
                }
                // Filed silently — the wizard has no categorisation page.
                if let slugs = composed.categorySlugs { categorySlugs = Set(slugs) }
                if let codes = composed.domainCodes { domainCodes = Set(codes) }
                if let codes = composed.attributeCodes { attributeCodes = codes }
                composedNotes = notes
            } catch {
                // The boxes reveal themselves with their previous values.
                errorMessage = error.localizedDescription
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if item.status == .failed {
                HStack(spacing: 14) {
                    Button("Retry analysis") { retry() }
                        .buttonStyle(InkButtonStyle(prominent: true))
                        .disabled(isWorking)
                    Button("Bin it", role: .destructive) { bin() }
                        .font(PaperInk.sans(14, weight: .bold))
                        .foregroundStyle(.red)
                        .disabled(isWorking)
                    Spacer()
                }
            } else {
                HStack(spacing: 10) {
                    // First page: the bin sits leading. Later pages: Back
                    // takes the leading slot and the bin moves to the middle.
                    Group {
                        if step != .facts {
                            Button("Back") {
                                withAnimation(.snappy) {
                                    step = Step(rawValue: step.rawValue - 1) ?? .facts
                                }
                            }
                            .buttonStyle(InkButtonStyle(prominent: true))
                            .disabled(isWorking || composing)
                        } else {
                            binButton
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Group {
                        if step != .facts {
                            binButton
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Group {
                        if step != .takeaways {
                            Button("Next") { advance() }
                                .buttonStyle(InkButtonStyle(prominent: true))
                                .disabled(isWorking || composing)
                        } else {
                            Button(isWorking ? "Approving…" : "Approve") { approveTapped() }
                                .buttonStyle(InkButtonStyle(prominent: true))
                                .disabled(isWorking || title.isEmpty || typeSlug.isEmpty)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    // MARK: Bits

    /// The hand-drawn bin, full-strength red — always behind a confirm.
    private var binButton: some View {
        Button { confirmingBin = true } label: {
            DoodleGlyph(spec: DoodleGlyphs.bin, opacity: 1, tint: .red)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel("Bin it")
    }

    private var typeName: String {
        reference?.activityTypes.first { $0.slug == typeSlug }?.name ?? "Choose…"
    }

    private var projectName: String {
        guard let id = projectIds.first else { return "None" }
        return reference?.projects.first { $0.id == id }?.title ?? "None"
    }

    private var assistContext: String {
        var parts = ["Title: \(title)", "Summary: \(summary)"]
        let notes = sourceNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("The user's own notes:\n\(notes)") }
        return String(parts.joined(separator: "\n").prefix(4000))
    }

    private func menuLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(PaperInk.sans(14))
                .foregroundStyle(PaperInk.ink)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10))
                .foregroundStyle(PaperInk.stone500)
        }
        .boxed()
    }

    private func labelled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: label)
            content()
                .font(PaperInk.sans(14))
                .boxed()
        }
    }

    private func sparkline(_ text: String) -> some View {
        HStack(spacing: 5) {
            Sparkle(size: 12)
            Text(text).font(PaperInk.sans(11)).foregroundStyle(PaperInk.stone500)
        }
    }

    // MARK: Data

    private func seedFromAnalysis() {
        guard title.isEmpty else { return } // already seeded

        // Step 2 seeds VERBATIM from the user's own words: debrief notes,
        // or the analyst's extraction of them (email commentary, voice
        // transcript). The import analysis already composed from these,
        // so the seeded value starts out "already composed".
        if case .string(let notes)? = item.rawPayload?["notes"], !notes.isEmpty {
            sourceNotes = notes
        } else if let userNotes = item.aiAnalysis?.userNotes, !userNotes.isEmpty {
            sourceNotes = userNotes
        }
        composedNotes = sourceNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let analysis else { return }

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"

        title = analysis.title ?? item.displayTitle
        typeSlug = analysis.activityTypeSlug ?? ""
        if let cpd = analysis.cpdPoints {
            points = InboxView.points(cpd)
        }
        if let iso = analysis.startsOn, let date = parser.date(from: iso) {
            startsOn = date
        }
        endsOn = analysis.endsOn.flatMap { parser.date(from: $0) } ?? startsOn
        organisation = analysis.organisation ?? ""
        summary = analysis.summary ?? ""
        // Pre-rename items only have the old flat strings — promote them.
        nuggets = analysis.nuggets
            ?? (analysis.suggestedLearningPoints ?? []).map { Takeaway(id: UUID().uuidString, text: $0) }
        actions = analysis.actions ?? []
        reflection = (analysis.reflectionDraft ?? [:]).compactMapValues { $0 }
        categorySlugs = Set(analysis.categorySlugs ?? [])
        domainCodes = Set(analysis.domainCodes ?? [])
        attributeCodes = analysis.attributeCodes ?? []
        projectIds = Set(analysis.suggestedProjectIds ?? [])
    }

    /// Approve → the confirm sheet when a sensitive-info flag or keep-file
    /// question is waiting; straight through otherwise.
    private func approveTapped() {
        if item.piiGate == true || asksAboutFiles {
            confirmingSave = true
            return
        }
        submitApprove(keepIds: [], piiAck: false)
    }

    /// Text-only sensitive info: scrub it server-side, then approve.
    private func removeInfoAndApprove() {
        isWorking = true
        Task {
            do {
                _ = try await session.api.removePii(id: item.id)
                submitApprove(keepIds: [], piiAck: false)
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
                confirmingSave = false
            }
        }
    }

    private func submitApprove(keepIds: [Int], piiAck: Bool) {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let payload = ApprovePayload(
                    title: title,
                    activityTypeSlug: typeSlug,
                    startsOn: formatter.string(from: startsOn),
                    endsOn: endsOn > startsOn ? formatter.string(from: endsOn) : nil,
                    organisation: organisation.isEmpty ? nil : organisation,
                    cpdPoints: Double(points.replacingOccurrences(of: ",", with: ".")) ?? 0,
                    summary: summary.isEmpty ? nil : summary,
                    // Only what was selected on the grid — explicit empty
                    // arrays when nothing is, so nothing is kept.
                    nuggets: nuggets.filter { selectedTakeawayIds.contains($0.id) },
                    actions: actions.filter { selectedTakeawayIds.contains($0.id) },
                    sourceNotes: sourceNotes.isEmpty ? nil : sourceNotes,
                    reflectionDraft: reflection.isEmpty ? nil : reflection,
                    // Filed silently — categories never surface in the wizard.
                    categorySlugs: Array(categorySlugs),
                    domainCodes: Array(domainCodes),
                    attributeCodes: attributeCodes,
                    projectIds: Array(projectIds),
                    linkedActivityIds: nil,
                    keepAttachmentIds: keepIds,
                    piiAck: item.piiGate == true ? piiAck : nil
                )
                try await session.api.approve(id: item.id, payload: payload)
                onResolved()
                dismiss()
            } catch let error as APIError where error.status == 404 {
                // Hard-deleted elsewhere (binned on the web) — nothing to approve.
                onResolved()
                dismiss()
            } catch let error as APIError where error.fieldErrors["pii"] != nil {
                confirmingSave = false
                errorMessage = error.fieldErrors["pii"]?.first ?? error.message
            } catch {
                confirmingSave = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func retry() {
        isWorking = true
        Task {
            defer { isWorking = false }
            try? await session.api.retry(id: item.id)
            onResolved()
            dismiss()
        }
    }

    private func bin(neverAgain: Bool = false) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await session.api.dismiss(
                    id: item.id,
                    neverAgainTitle: neverAgain ? item.displayTitle : nil
                )
                onResolved()
                dismiss()
            } catch let error as APIError where error.status == 404 {
                // Already hard-deleted — same outcome the user wanted.
                onResolved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// The between-steps AI working state: a pulsing sparkle with orbiting
/// dots, cycling status lines, a reassurance subline, and skeleton bars
/// where the boxes are about to appear. Honours Reduce Motion by holding
/// everything still (the status text still steps through its lines).
private struct ComposeWorkingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var skeletonCount: Int

    @State private var lineIndex = 0
    @State private var pulsing = false
    @State private var orbiting = false
    @State private var shimmering = false

    private static let lines = [
        "Reading your notes…",
        "Shaping your reflections…",
        "Panning for nuggets…",
    ]

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(0 ..< 3, id: \.self) { index in
                    Circle()
                        .fill(PaperInk.brand.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .offset(y: -24)
                        .rotationEffect(.degrees(Double(index) * 120 + (orbiting ? 360 : 0)))
                }
                Sparkle(size: 26)
                    .scaleEffect(pulsing ? 1.15 : 0.85)
            }
            .frame(width: 60, height: 60)

            Text(Self.lines[lineIndex])
                .font(PaperInk.sans(14, weight: .bold))
                .foregroundStyle(PaperInk.ink)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: lineIndex)

            Text("Your words stay yours — the AI only tidies and files.")
                .font(PaperInk.sans(12))
                .foregroundStyle(PaperInk.stone500)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                ForEach(0 ..< skeletonCount, id: \.self) { index in
                    skeletonBar(trailing: [0, 46, 90, 24, 70][index % 5])
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                orbiting = true
            }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                shimmering = true
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                lineIndex = (lineIndex + 1) % Self.lines.count
            }
        }
    }

    private func skeletonBar(trailing: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(PaperInk.paperAlt)
            .frame(height: 13)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.7), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geometry.size.width / 2.5)
                        .offset(x: shimmering ? geometry.size.width : -geometry.size.width / 2.5)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.trailing, trailing)
    }
}

private extension View {
    func boxed() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(PaperInk.ink.opacity(0.35), lineWidth: 1.5))
    }
}

/// Simple wrapping layout for chip pickers.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(proposal: proposal, subviews: subviews).positions
        for (subview, position) in zip(subviews, positions) {
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }
        return (CGSize(width: totalWidth, height: y + rowHeight), positions)
    }
}
