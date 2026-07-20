import SwiftUI

/// The web's merge modal as a native sheet: combined points with the
/// breakdown, date span, per-file keep choices, per-item PII decisions and
/// the full editable entry — one reflection, on the combined whole. The
/// deterministic preview seeds the form instantly; the AI-combined
/// reflections arrive asynchronously with a one-tap undo.
struct MergeSheetView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    let initialSeed: MergeSeed
    var onMerged: () -> Void

    @State private var seed: MergeSeed = MergeSeed()
    @State private var preview: MergePreview?
    @State private var loadError: String?

    // Combined entry fields
    @State private var title = ""
    @State private var typeSlug = ""
    @State private var points = ""
    @State private var startsOn = ""
    @State private var endsOn = ""
    @State private var organisation = ""
    @State private var summary = ""
    @State private var reflection: [String: String] = [:]
    @State private var talk = ReflectionTalkState()
    @State private var categorySlugs: Set<String> = []
    @State private var domainCodes: Set<String> = []
    @State private var projectIds: Set<Int> = []
    @State private var attributeCodes: [String] = []
    @State private var confirmingSave = false

    // The AI-drafted combined entry (title/type/org/details/reflections)
    private enum AiState { case pending, applied, undone, failed }
    private struct DraftSnapshot {
        var title: String
        var typeSlug: String
        var organisation: String
        var summary: String
        var reflection: [String: String]
    }

    @State private var aiState: AiState = .pending
    @State private var aiDraft: MergeDraft?
    @State private var preAiSnapshot: DraftSnapshot?

    @State private var isWorking = false
    @State private var errorMessage: String?

    private var reference: Reference? { session.reference }

    private var gatedSources: [MergePreview.Source] {
        (preview?.sources ?? []).filter { $0.piiGate == true }
    }

    var body: some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(PaperInk.ink.opacity(0.2))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            HStack(spacing: 6) {
                Text("Merge \(preview?.sources.count ?? 0) into one").display(22)
                Sparkle(size: 14)
                Spacer()
            }
            .padding(.horizontal, 16)

            if let loadError {
                Text(loadError)
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            if preview == nil && loadError == nil {
                Spacer()
                ProgressView("Gathering the pieces…")
                    .font(PaperInk.sans(13))
                Spacer()
            } else if preview != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("One entry replaces these — they're kept underneath and can be split apart again any time.")
                            .font(PaperInk.sans(12))
                            .foregroundStyle(PaperInk.stone500)

                        sourcesList
                        fields
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)

                footer
            }
        }
        .background(.white)
        .task {
            seed = initialSeed
            await session.loadReference()
            await loadPreview()
            await loadDraft()
        }
        .sheet(isPresented: $confirmingSave) {
            ApproveConfirmSheet(
                files: keepableFiles,
                flags: gatedSources.flatMap { source in
                    (source.piiFlags ?? []).map {
                        SensitiveFlag(type: $0.type, excerpt: nil)
                    }
                },
                flagLocation: !gatedSources.isEmpty && keepableFiles.isEmpty
                    ? "the merged items' text"
                    : nil,
                verb: "Merge",
                isWorking: isWorking,
                onConfirm: { keepIds, piiAck in
                    submitMerge(keepIds: keepIds, piiAcks: piiAck ? gatedSources.map(\.id) : [])
                },
                onRemoveInfo: !gatedSources.isEmpty && keepableFiles.isEmpty
                    ? { removeInfoAndMerge() }
                    : nil,
                onCancel: { confirmingSave = false }
            )
        }
    }

    // MARK: Sources

    private var sourcesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(preview?.sources ?? []) { source in
                HStack(spacing: 8) {
                    Image(systemName: source.kind == "activity" ? "calendar" : "tray")
                        .font(.system(size: 11))
                        .foregroundStyle(PaperInk.stone400)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.title)
                            .font(PaperInk.sans(13, weight: .semibold))
                            .lineLimit(1)
                        Text(sourceMeta(source))
                            .font(PaperInk.sans(10, weight: .semibold))
                            .foregroundStyle(PaperInk.stone500)
                    }

                    Spacer(minLength: 4)

                    if source.isTarget != true, (preview?.sources.count ?? 0) > 2 {
                        Button {
                            removeSource(source)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(PaperInk.stone400)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(PaperInk.ink, lineWidth: 1.5))
                .rowTilt(seed: source.id)
            }

            if let breakdown = preview?.defaults.pointsBreakdown, breakdown.count > 1 {
                Text("\(breakdown.map(InboxView.points).joined(separator: " + ")) points — trim if it double-counts")
                    .font(PaperInk.hand(18))
                    .foregroundStyle(PaperInk.stone500)
                    .tilt(-1.5)
                    .padding(.top, 2)
            }
        }
    }

    private func sourceMeta(_ source: MergePreview.Source) -> String {
        var bits: [String] = []
        if let label = source.source { bits.append(label.replacingOccurrences(of: "_", with: " ")) }
        else { bits.append(source.isTarget == true ? "merged entry" : "timeline") }
        if let date = source.startsOn { bits.append(TimelineView.shortDate(date)) }
        if let pts = source.cpdPoints { bits.append("\(InboxView.points(pts)) pts") }
        return bits.joined(separator: " · ").uppercased()
    }

    private func removeSource(_ source: MergePreview.Source) {
        if source.kind == "activity" {
            seed.activityIds.removeAll { $0 == source.id }
        } else {
            seed.inboxItemIds.removeAll { $0 == source.id }
        }

        let remaining = seed.activityIds.count + seed.inboxItemIds.count + (seed.intoActivityId == nil ? 0 : 1)
        if remaining < 2 {
            dismiss()
            return
        }
        Task { await loadPreview() }
    }

    // MARK: Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            labelled("Title") {
                TextField("Title", text: $title, axis: .vertical)
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(text: "Type")
                    Menu {
                        ForEach(reference?.activityTypes ?? []) { type in
                            Button(type.name) { typeSlug = type.slug }
                        }
                    } label: {
                        HStack {
                            Text(typeName).font(PaperInk.sans(14)).foregroundStyle(PaperInk.ink)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(PaperInk.stone500)
                        }
                        .boxed()
                    }
                }
                labelled("CPD points") {
                    TextField("1", text: $points)
                        .keyboardType(.decimalPad)
                }
                .frame(width: 100)
            }

            HStack(alignment: .top, spacing: 10) {
                labelled("From") {
                    TextField("YYYY-MM-DD", text: $startsOn)
                }
                labelled("To") {
                    TextField("YYYY-MM-DD", text: $endsOn)
                }
            }

            labelled("Summary") {
                TextField("What happened?", text: $summary, axis: .vertical)
                    .lineLimit(3 ... 8)
            }

            aiBanner

            ReflectionStepView(
                prompts: reference?.reflectionPrompts ?? [],
                answers: $reflection,
                assistContext: "Title: \(title)\nSummary: \(summary)",
                talk: $talk
            )

            if let categories = reference?.categories, !categories.isEmpty {
                chipPicker("Categories", items: categories.map { ($0.slug, $0.name) }, selection: $categorySlugs)
            }
            if let domains = reference?.domains, !domains.isEmpty {
                chipPicker("Domains", items: domains.map { ($0.code, "\($0.code) · \($0.name)") }, selection: $domainCodes)
            }
            if let projects = reference?.projects, !projects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "Projects")
                    FlowLayout(spacing: 8) {
                        ForEach(projects) { project in
                            toggleChip(project.title, isOn: projectIds.contains(project.id)) {
                                toggle(&projectIds, project.id)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Keepable files across all sources, attributed to their entry.
    private var keepableFiles: [ConfirmFile] {
        guard preview?.retention == "ask" || preview?.retention == nil else { return [] }

        return (preview?.sources ?? []).flatMap { source in
            source.attachments
                .filter { $0.keepable == true }
                .map { ConfirmFile(id: $0.id, name: $0.name ?? "File \($0.id)", from: source.title) }
        }
    }

    @ViewBuilder
    private var aiBanner: some View {
        switch aiState {
        case .pending:
            HStack(spacing: 6) {
                Sparkle(size: 12)
                ProgressView().controlSize(.mini)
                Text("AI is drafting the combined entry…")
                    .font(PaperInk.sans(12))
                    .foregroundStyle(PaperInk.stone600)
            }
        case .applied:
            HStack(spacing: 6) {
                Sparkle(size: 12)
                Text("Title, details and reflections drafted by AI — edit below, or")
                    .font(PaperInk.sans(12))
                    .foregroundStyle(PaperInk.stone600)
                Button("undo") { undoAi() }
                    .font(PaperInk.sans(12, weight: .bold))
                    .foregroundStyle(PaperInk.brandDark)
            }
        case .undone:
            HStack(spacing: 6) {
                Text("Back to the stitched-together originals —")
                    .font(PaperInk.sans(12))
                    .foregroundStyle(PaperInk.stone500)
                Button("re-apply the AI combine") { redoAi() }
                    .font(PaperInk.sans(12, weight: .bold))
                    .foregroundStyle(PaperInk.brandDark)
            }
        case .failed:
            EmptyView()
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
            HStack(spacing: 14) {
                Button(isWorking ? "Merging…" : "Merge into one entry") { mergeTapped() }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .disabled(isWorking || title.isEmpty || typeSlug.isEmpty)

                Button("Cancel") { dismiss() }
                    .font(PaperInk.sans(14, weight: .bold))
                    .foregroundStyle(PaperInk.stone600)
                    .disabled(isWorking)

                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    // MARK: Helpers

    private var typeName: String {
        reference?.activityTypes.first { $0.slug == typeSlug }?.name ?? "Choose…"
    }

    private func labelled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: label)
            content()
                .font(PaperInk.sans(14))
                .boxed()
        }
    }

    private func chipPicker(_ label: String, items: [(key: String, name: String)], selection: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: label)
            FlowLayout(spacing: 8) {
                ForEach(items, id: \.key) { item in
                    toggleChip(item.name, isOn: selection.wrappedValue.contains(item.key)) {
                        toggle(&selection.wrappedValue, item.key)
                    }
                }
            }
        }
    }

    private func toggleChip(_ text: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(PaperInk.sans(12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isOn ? PaperInk.tint : .white)
                .foregroundStyle(isOn ? PaperInk.brandDark : PaperInk.stone600)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        isOn ? PaperInk.brandDark : PaperInk.stone400,
                        style: isOn ? StrokeStyle(lineWidth: 1.5) : StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    // MARK: Data

    private func loadPreview() async {
        do {
            let fresh = try await session.api.mergePreview(seed: seed)
            preview = fresh
            loadError = nil
            seedFields(from: fresh)
        } catch where !error.isCancellation {
            loadError = error.localizedDescription
        } catch {}
    }

    /// Seed once; source removals refetch the preview but keep user edits.
    private func seedFields(from preview: MergePreview) {
        guard title.isEmpty else { return }

        let defaults = preview.defaults
        title = defaults.title ?? ""
        typeSlug = defaults.activityTypeSlug ?? ""
        if let cpd = defaults.cpdPoints { points = InboxView.points(cpd) }
        startsOn = defaults.startsOn ?? ""
        endsOn = defaults.endsOn ?? ""
        organisation = defaults.organisation ?? ""
        summary = defaults.details ?? ""
        attributeCodes = defaults.attributeCodes ?? []
        categorySlugs = Set(defaults.categorySlugs ?? [])
        domainCodes = Set(defaults.domainCodes ?? [])
        projectIds = Set(defaults.projectIds ?? [])

        if reflection.isEmpty {
            reflection = defaults.reflection ?? [:]
        }

        // The AI draft already landed — apply it now.
        if aiState == .pending, let draft = aiDraft {
            applyDraft(draft)
        }
    }

    private func loadDraft() async {
        do {
            let draft = try await session.api.mergeDraft(seed: initialSeed)
            guard !draft.isEmpty else {
                if aiState == .pending { aiState = .failed }
                return
            }
            aiDraft = draft
            if preview != nil, aiState == .pending {
                applyDraft(draft)
            }
        } catch {
            if aiState == .pending { aiState = .failed }
        }
    }

    /// AI values layer OVER the deterministic defaults: anything the draft
    /// left empty keeps its stitched-together starting value.
    private func applyDraft(_ draft: MergeDraft) {
        preAiSnapshot = DraftSnapshot(
            title: title, typeSlug: typeSlug, organisation: organisation,
            summary: summary, reflection: reflection
        )
        if let value = draft.title, !value.isEmpty { title = value }
        if let value = draft.activityTypeSlug, !value.isEmpty { typeSlug = value }
        if let value = draft.organisation, !value.isEmpty { organisation = value }
        if let value = draft.details, !value.isEmpty { summary = value }
        reflection = reflection.merging(draft.reflection ?? [:]) { _, ai in ai }
        aiState = .applied
    }

    private func undoAi() {
        if let snapshot = preAiSnapshot {
            title = snapshot.title
            typeSlug = snapshot.typeSlug
            organisation = snapshot.organisation
            summary = snapshot.summary
            reflection = snapshot.reflection
        }
        aiState = .undone
    }

    private func redoAi() {
        if let draft = aiDraft { applyDraft(draft) }
    }

    /// Merge → the confirm sheet when a sensitive-info flag or keep-file
    /// question is waiting; straight through otherwise.
    private func mergeTapped() {
        if !gatedSources.isEmpty || !keepableFiles.isEmpty {
            confirmingSave = true
            return
        }
        submitMerge(keepIds: [], piiAcks: [])
    }

    /// Text-only sensitive info: scrub every gated source server-side,
    /// then merge with nothing to acknowledge.
    private func removeInfoAndMerge() {
        isWorking = true
        Task {
            do {
                for source in gatedSources {
                    _ = try await session.api.removePii(id: source.id)
                }
                submitMerge(keepIds: [], piiAcks: [])
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
                confirmingSave = false
            }
        }
    }

    private func submitMerge(keepIds: [Int], piiAcks: [Int]) {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let payload = MergePayload(
                    seed: seed,
                    title: title,
                    activityTypeSlug: typeSlug,
                    startsOn: startsOn.isEmpty ? nil : startsOn,
                    endsOn: endsOn.isEmpty ? nil : endsOn,
                    organisation: organisation.isEmpty ? nil : organisation,
                    cpdPoints: Double(points.replacingOccurrences(of: ",", with: ".")) ?? 0,
                    details: summary.isEmpty ? nil : summary,
                    reflection: reflection.isEmpty ? nil : reflection,
                    categorySlugs: Array(categorySlugs),
                    domainCodes: Array(domainCodes),
                    attributeCodes: attributeCodes,
                    projectIds: Array(projectIds),
                    keepAttachmentIds: keepIds,
                    piiAcks: piiAcks
                )
                _ = try await session.api.merge(payload: payload)
                onMerged()
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
