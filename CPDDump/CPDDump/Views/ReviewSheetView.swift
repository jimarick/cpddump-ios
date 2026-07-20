import SwiftUI

/// The web's three-step review wizard (Details / Reflection / Categorise)
/// as a native bottom sheet. Edits the AI draft, then approves or bins.
struct ReviewSheetView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    let item: InboxItem
    var onResolved: () -> Void

    enum Step: Int, CaseIterable {
        case details, reflection, categorise

        var label: String {
            switch self {
            case .details: "Details"
            case .reflection: "Reflection"
            case .categorise: "Categorise"
            }
        }
    }

    @State private var step: Step = .details

    // Details
    @State private var title = ""
    @State private var typeSlug = ""
    @State private var points = ""
    @State private var startsOn: Date = .now
    @State private var hasDate = false
    @State private var organisation = ""
    @State private var summary = ""

    // Reflection: answers keyed by prompt key
    @State private var reflection: [String: String] = [:]

    // Categorise
    @State private var categorySlugs: Set<String> = []
    @State private var domainCodes: Set<String> = []
    @State private var projectIds: Set<Int> = []
    // Delete-by-default: files are purged on approval unless kept here.
    @State private var keepAttachmentIds: Set<Int> = []
    // PII gate: flagged patient info requires an explicit decision.
    @State private var piiAcknowledged = false

    @State private var isWorking = false
    @State private var errorMessage: String?

    private var analysis: AiAnalysis? { item.aiAnalysis }
    private var reference: Reference? { session.reference }

    var body: some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(PaperInk.ink.opacity(0.2))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            stepPills

            ScrollView {
                Group {
                    switch step {
                    case .details: detailsStep
                    case .reflection: ReflectionStepView(
                        prompts: reference?.reflectionPrompts ?? [],
                        answers: $reflection,
                        assistContext: assistContext
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
    }

    // MARK: Steps

    private var stepPills: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { candidate in
                let active = candidate == step
                Button {
                    withAnimation(.snappy) { step = candidate }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(candidate.rawValue + 1)")
                            .font(PaperInk.sans(9, weight: .heavy))
                            .foregroundStyle(active ? .white : PaperInk.stone500)
                            .frame(width: 14, height: 14)
                            .background(active ? PaperInk.brand : PaperInk.paperAlt)
                            .clipShape(Circle())
                        Text(candidate.label)
                            .font(PaperInk.sans(11, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(active ? PaperInk.tint : .white)
                    .foregroundStyle(active ? PaperInk.brandDark : PaperInk.stone500)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(
                            active ? PaperInk.ink : PaperInk.stone400,
                            style: active ? StrokeStyle(lineWidth: 1.5) : StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                    )
                    .tilt(active ? -0.5 : 0)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            labelled("What was it?") {
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
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(text: "Date")
                    if hasDate {
                        DatePicker("", selection: $startsOn, displayedComponents: .date)
                            .labelsHidden()
                    } else {
                        Button("Add a date") { hasDate = true }
                            .font(PaperInk.sans(13, weight: .semibold))
                            .foregroundStyle(PaperInk.brandDark)
                    }
                }
                labelled("Organisation") {
                    TextField("Optional", text: $organisation)
                }
            }

            labelled("Summary") {
                TextField("What happened?", text: $summary, axis: .vertical)
                    .lineLimit(3 ... 8)
            }

            if item.piiGate == true {
                piiGateBox
            }

            if let missing = item.aiWarnings?.missingEvidence, !missing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(missing, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(PaperInk.sans(12))
                            .foregroundStyle(PaperInk.brandDark)
                    }
                }
            }

            sparkline("Drafted from your \(item.sourceLabel.lowercased()) — edit anything.")
        }
    }

    /// The approval gate for flagged patient information. Removing the info
    /// itself currently lives on the web; here the user affirms they checked.
    private var piiGateBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Possible patient information", systemImage: "exclamationmark.shield.fill")
                .font(PaperInk.sans(13, weight: .heavy))
                .foregroundStyle(.red)

            if let flags = item.aiWarnings?.piiFlags, !flags.isEmpty {
                ForEach(Array(flags.enumerated()), id: \.offset) { _, flag in
                    Text("\(flag.type.replacingOccurrences(of: "_", with: " ")) · \(flag.severity)")
                        .font(PaperInk.sans(12))
                        .foregroundStyle(PaperInk.stone600)
                }
            }

            Text("Check the details and summary above. To strip the information from stored files, use the web app — or confirm you've checked it:")
                .font(PaperInk.sans(12))
                .foregroundStyle(PaperInk.stone600)

            toggleChip("Keep — I've checked", isOn: piiAcknowledged) {
                piiAcknowledged.toggle()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.red.opacity(0.5), lineWidth: 1.5))
    }

    private var categoriseStep: some View {
        VStack(alignment: .leading, spacing: 18) {
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
            let keepable = item.attachments.filter { $0.purged != true }
            if !keepable.isEmpty, session.user?.asksAboutAttachments ?? true {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "Keep the original file?")
                    Text("Files are deleted once the entry is filed, unless you keep them as evidence.")
                        .font(PaperInk.sans(12))
                        .foregroundStyle(PaperInk.stone500)
                    FlowLayout(spacing: 8) {
                        ForEach(keepable) { attachment in
                            toggleChip(
                                attachment.name ?? "Attachment \(attachment.id)",
                                isOn: keepAttachmentIds.contains(attachment.id)
                            ) {
                                toggle(&keepAttachmentIds, attachment.id)
                            }
                        }
                    }
                }
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
            HStack(spacing: 14) {
                Button(isWorking ? "Approving…" : "Approve") { approve() }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .disabled(
                        isWorking || title.isEmpty || typeSlug.isEmpty
                            || (item.piiGate == true && !piiAcknowledged)
                    )

                Button("Bin it", role: .destructive) { bin() }
                    .font(PaperInk.sans(14, weight: .bold))
                    .foregroundStyle(.red)
                    .disabled(isWorking)

                Spacer()

                if let confidence = analysis?.confidence {
                    Text("AI confidence \(Int(confidence * 100))%")
                        .font(PaperInk.sans(10, weight: .bold))
                        .foregroundStyle(PaperInk.stone500)
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

    private var assistContext: String {
        "Title: \(title)\nSummary: \(summary)"
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

        title = analysis.title ?? item.displayTitle
        typeSlug = analysis.activityTypeSlug ?? ""
        if let cpd = analysis.cpdPoints {
            points = InboxView.points(cpd)
        }
        if let iso = analysis.startsOn {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            if let date = parser.date(from: iso) {
                startsOn = date
                hasDate = true
            }
        }
        organisation = analysis.organisation ?? ""
        summary = analysis.summary ?? ""
        reflection = (analysis.reflectionDraft ?? [:]).compactMapValues { $0 }
        categorySlugs = Set(analysis.categorySlugs ?? [])
        domainCodes = Set(analysis.domainCodes ?? [])
        projectIds = Set(analysis.suggestedProjectIds ?? [])
    }

    private func approve() {
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
                    endsOn: nil,
                    organisation: organisation.isEmpty ? nil : organisation,
                    cpdPoints: Double(points.replacingOccurrences(of: ",", with: ".")) ?? 0,
                    summary: summary.isEmpty ? nil : summary,
                    reflectionDraft: reflection.isEmpty ? nil : reflection,
                    categorySlugs: Array(categorySlugs),
                    domainCodes: Array(domainCodes),
                    attributeCodes: analysis?.attributeCodes,
                    projectIds: Array(projectIds),
                    linkedActivityIds: nil,
                    keepAttachmentIds: Array(keepAttachmentIds),
                    piiAck: item.piiGate == true ? piiAcknowledged : nil
                )
                try await session.api.approve(id: item.id, payload: payload)
                onResolved()
                dismiss()
            } catch let error as APIError where error.status == 404 {
                // Hard-deleted elsewhere (binned on the web) — nothing to approve.
                onResolved()
                dismiss()
            } catch let error as APIError where error.fieldErrors["pii"] != nil {
                errorMessage = error.fieldErrors["pii"]?.first ?? error.message
            } catch {
                errorMessage = error.localizedDescription
            }
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
