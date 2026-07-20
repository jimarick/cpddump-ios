import SwiftUI

/// The web's three-step review wizard (Details / Reflection / Categorise)
/// as a native bottom sheet: editable title up top, linear Next/Back with a
/// "N of 3" counter, and every sensitive-info / keep-file decision deferred
/// to the "Before this is saved" confirm sheet — the form itself carries no
/// warning banners.
struct ReviewSheetView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    let item: InboxItem
    var onResolved: () -> Void
    /// Present the merge sheet seeded with this item + its suggested matches.
    var onMergeInstead: ((MergeSeed) -> Void)?

    enum Step: Int, CaseIterable {
        case details, reflection, categorise
    }

    @State private var step: Step = .details

    // Details
    @State private var title = ""
    @State private var typeSlug = ""
    @State private var points = ""
    @State private var startsOn: Date = .now
    @State private var hasDate = false
    @State private var endsOn: Date = .now
    /// No input any more (parity with the web) but MUST stay in the payload:
    /// the AI-extracted value still feeds exports and merges.
    @State private var organisation = ""
    @State private var summary = ""

    // Reflection: answers keyed by prompt key
    @State private var reflection: [String: String] = [:]
    @State private var talk = ReflectionTalkState()

    // Categorise
    @State private var categorySlugs: Set<String> = []
    @State private var domainCodes: Set<String> = []
    @State private var projectIds: Set<Int> = []

    @State private var confirmingSave = false
    @State private var confirmingBin = false
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
                    if let suggestions = item.mergeSuggestions, !suggestions.isEmpty, onMergeInstead != nil {
                        mergeSuggestionBox(suggestions)
                    }

                    switch step {
                    case .details: detailsStep
                    case .reflection: ReflectionStepView(
                        prompts: reference?.reflectionPrompts ?? [],
                        answers: $reflection,
                        assistContext: assistContext,
                        talk: $talk,
                        reflectionSource: item.aiAnalysis?.reflectionSource
                    )
                    case .categorise: categoriseStep
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
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Binned means deleted — the draft and any files are gone for good.")
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
            } else {
                TextField("Untitled evidence", text: $title, axis: .vertical)
                    .font(PaperInk.display(21))
                    .lineLimit(1 ... 3)
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

    // MARK: Steps

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if item.status == .failed {
                Text(item.failureReason ?? "Analysis failed. You can retry, or fill the details in manually.")
                    .font(PaperInk.sans(13))
                    .foregroundStyle(PaperInk.stone600)
            }

            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Dates")
                if hasDate {
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
                } else {
                    Button("Add a date") {
                        hasDate = true
                        endsOn = startsOn
                    }
                    .font(PaperInk.sans(13, weight: .semibold))
                    .foregroundStyle(PaperInk.brandDark)
                    .padding(.vertical, 8)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Points")
                TextField("1", text: $points)
                    .keyboardType(.decimalPad)
                    .font(PaperInk.sans(14))
                    .boxed()
                    .frame(width: 110)
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

            labelled("Details") {
                TextField("What happened, in your own words?", text: $summary, axis: .vertical)
                    .lineLimit(4 ... 10)
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

    private var categoriseStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let categories = reference?.categories, !categories.isEmpty {
                chipPicker("Categories", items: categories.map { ($0.slug, $0.name) }, selection: $categorySlugs)
            }
            if let domains = reference?.domains, !domains.isEmpty {
                chipPicker("Domains", items: domains.map { ($0.code, "\($0.code) · \($0.name)") }, selection: $domainCodes)
            }

            sparkline("The AI pre-ticked its suggestions — adjust freely.")
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
                    Group {
                        if step != .details {
                            Button("Back") {
                                withAnimation(.snappy) {
                                    step = Step(rawValue: step.rawValue - 1) ?? .details
                                }
                            }
                            .buttonStyle(InkButtonStyle(prominent: true))
                            .disabled(isWorking)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Bin it", role: .destructive) { confirmingBin = true }
                        .font(PaperInk.sans(14, weight: .bold))
                        .foregroundStyle(.red)
                        .disabled(isWorking)
                        .frame(maxWidth: .infinity)

                    Group {
                        if step != .categorise {
                            Button("Next") {
                                withAnimation(.snappy) {
                                    step = Step(rawValue: step.rawValue + 1) ?? .categorise
                                }
                            }
                            .buttonStyle(InkButtonStyle(prominent: true))
                            .disabled(isWorking)
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

    private var typeName: String {
        reference?.activityTypes.first { $0.slug == typeSlug }?.name ?? "Choose…"
    }

    private var projectName: String {
        guard let id = projectIds.first else { return "None" }
        return reference?.projects.first { $0.id == id }?.title ?? "None"
    }

    private var assistContext: String {
        "Title: \(title)\nSummary: \(summary)"
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

    private func seedFromAnalysis() {
        guard let analysis else { return }
        guard title.isEmpty else { return } // already seeded

        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"

        title = analysis.title ?? item.displayTitle
        typeSlug = analysis.activityTypeSlug ?? ""
        if let cpd = analysis.cpdPoints {
            points = InboxView.points(cpd)
        }
        if let iso = analysis.startsOn, let date = parser.date(from: iso) {
            startsOn = date
            hasDate = true
        }
        endsOn = analysis.endsOn.flatMap { parser.date(from: $0) } ?? startsOn
        organisation = analysis.organisation ?? ""
        summary = analysis.summary ?? ""
        reflection = (analysis.reflectionDraft ?? [:]).compactMapValues { $0 }
        categorySlugs = Set(analysis.categorySlugs ?? [])
        domainCodes = Set(analysis.domainCodes ?? [])
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
                    startsOn: hasDate ? formatter.string(from: startsOn) : nil,
                    endsOn: hasDate && endsOn > startsOn ? formatter.string(from: endsOn) : nil,
                    organisation: organisation.isEmpty ? nil : organisation,
                    cpdPoints: Double(points.replacingOccurrences(of: ",", with: ".")) ?? 0,
                    summary: summary.isEmpty ? nil : summary,
                    reflectionDraft: reflection.isEmpty ? nil : reflection,
                    categorySlugs: Array(categorySlugs),
                    domainCodes: Array(domainCodes),
                    attributeCodes: analysis?.attributeCodes,
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

    private func bin() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await session.api.dismiss(id: item.id)
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
