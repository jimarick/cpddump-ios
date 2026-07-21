import SwiftUI

@Observable
final class TimelineModel {
    var activities: [ActivitySummary] = []
    var period: AppraisalPeriod?
    var stats: StatsResponse.Stats?
    /// nil = the current appraisal year.
    var selectedPeriodId: Int?
    var page = 1
    var lastPage = 1
    var isLoading = false
    var errorMessage: String?

    func load(_ session: Session, reset: Bool = false) async {
        if reset {
            page = 1
        }
        isLoading = true
        do {
            async let statsResponse = session.api.stats(periodId: selectedPeriodId)
            let result = try await session.api.activities(page: page, periodId: selectedPeriodId)
            stats = try? await statsResponse.stats
            period = result.period
            lastPage = result.meta.lastPage
            if page == 1 {
                activities = result.activities
            } else {
                activities.append(contentsOf: result.activities)
            }
            errorMessage = nil
        } catch let error as APIError where error.status == 401 {
            session.handleUnauthorised()
        } catch where !error.isCancellation {
            errorMessage = error.localizedDescription
        } catch {}
        isLoading = false
    }

    func loadMoreIfNeeded(_ session: Session, current: ActivitySummary) async {
        guard current.id == activities.last?.id, page < lastPage, !isLoading else { return }
        page += 1
        await load(session)
    }
}

/// Scroll of approved activities. Since the merge feature, entries can be
/// combined (Select → Merge), split apart, and edited right here.
struct TimelineView: View {
    @Environment(Session.self) private var session
    @Bindable var model: TimelineModel
    /// Owned by MainTabView so the tab bar can step aside while selecting.
    @Binding var selecting: Bool
    /// Present the merge sheet for the chosen entries.
    var onMerge: (MergeSeed) -> Void

    @State private var selectedIds: Set<Int> = []
    /// Programmatic pushes (activity-id deep links from the morning gem).
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header

                Group {
                    if model.activities.isEmpty && model.isLoading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.activities.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }
            }
            .background(PaperInk.paper)
            // The page draws its own header, exactly like the inbox — the
            // system bar (and its glass chrome) only appears on pushed
            // detail screens.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ActivitySummary.self) { activity in
                ActivityDetailView(activityId: activity.id) {
                    Task { await model.load(session, reset: true) }
                }
            }
            // Deep links only carry an id, not a summary.
            .navigationDestination(for: Int.self) { activityId in
                ActivityDetailView(activityId: activityId) {
                    Task { await model.load(session, reset: true) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { mergeBar }
            }
        }
        .task {
            await session.loadReference()
            await model.load(session, reset: true)
        }
        .onAppear { consumeDeepLink() }
        .onChange(of: LaunchActions.shared.openActivityId) {
            consumeDeepLink()
        }
    }

    /// A push (the morning gem) named an activity — go straight to it.
    private func consumeDeepLink() {
        guard let activityId = LaunchActions.shared.openActivityId else { return }
        LaunchActions.shared.openActivityId = nil
        path.append(activityId)
    }

    /// In-content header matching the inbox: big leading title, plain
    /// Select/Done trailing on the same row.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Timeline").display(32)
                periodSwitcher
            }

            Spacer()

            if !model.activities.isEmpty {
                Button(selecting ? "Done" : "Select") {
                    withAnimation(.snappy) {
                        selecting.toggle()
                        selectedIds = []
                    }
                }
                .buttonStyle(.plain)
                .font(PaperInk.sans(13, weight: .bold))
                .foregroundStyle(PaperInk.brandDark)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    /// The appraisal-year label doubles as a switcher — old years stay
    /// one tap away, exactly like the web's dropdown.
    @ViewBuilder
    private var periodSwitcher: some View {
        let periods = session.reference?.periods ?? []

        if periods.count > 1 {
            Menu {
                ForEach(periods) { period in
                    Button {
                        model.selectedPeriodId = period.isCurrent == true ? nil : period.id
                        Task { await model.load(session, reset: true) }
                    } label: {
                        if period.id == model.period?.id {
                            Label(periodTitle(period), systemImage: "checkmark")
                        } else {
                            Text(periodTitle(period))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.period?.label ?? "Year")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .font(PaperInk.sans(12, weight: .semibold))
                .foregroundStyle(PaperInk.stone500)
            }
        } else if let label = model.period?.label {
            Text(label)
                .font(PaperInk.sans(12, weight: .semibold))
                .foregroundStyle(PaperInk.stone500)
        }
    }

    private func periodTitle(_ period: AppraisalPeriod) -> String {
        period.isCurrent == true ? "\(period.label) (current)" : period.label
    }

    /// At most one merged entry can join a stack — it becomes the target.
    private var selectedMergedCount: Int {
        model.activities.filter { selectedIds.contains($0.id) && $0.merged == true }.count
    }

    /// Stands in for the tab bar while selecting: Merge leading, Cancel
    /// trailing, warnings in between.
    private var mergeBar: some View {
        HStack(spacing: 12) {
            Button("Merge \(selectedIds.count) into one") {
                let selected = model.activities.filter { selectedIds.contains($0.id) }
                let target = selected.first { $0.merged == true }

                withAnimation(.snappy) {
                    selecting = false
                    selectedIds = []
                }
                onMerge(MergeSeed(
                    activityIds: selected.filter { $0.id != target?.id }.map(\.id),
                    inboxItemIds: [],
                    intoActivityId: target?.id
                ))
            }
            .buttonStyle(InkButtonStyle(prominent: true))
            .disabled(selectedIds.count < 2 || selectedMergedCount > 1)

            Spacer(minLength: 8)

            if selectedMergedCount > 1 {
                Text("split one first")
                    .font(PaperInk.hand(17))
                    .foregroundStyle(.red)
                    .tilt(-1.5)
            } else if selectedIds.count < 2 {
                Text("tap entries to stack them")
                    .font(PaperInk.hand(17))
                    .foregroundStyle(PaperInk.brandDark)
                    .tilt(-1.5)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button("Cancel") {
                withAnimation(.snappy) {
                    selecting = false
                    selectedIds = []
                }
            }
            .font(PaperInk.sans(14, weight: .bold))
            .foregroundStyle(PaperInk.stone600)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(PaperInk.paper)
        .overlay(alignment: .top) { DashedDivider() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No activities yet").display(22)
            Text("approve something from the pile and it lands here")
                .font(PaperInk.hand(20))
                .foregroundStyle(PaperInk.brandDark)
                .tilt(-1.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(model.activities) { activity in
                    rowOrSelectRow(activity)
                }
            }
            .padding(14)
            // Room so the last rows can scroll clear of the floating pill.
            .padding(.bottom, 76)
        }
        .refreshable { await model.load(session, reset: true) }
        .overlay(alignment: .bottom) {
            if !selecting, let stats = model.stats {
                summaryPill(stats)
            }
        }
    }

    private func summaryPill(_ stats: StatsResponse.Stats) -> some View {
        // Both pages' containers end at the tab bar, so matching the
        // inbox's 26pt lift puts the pills at the same screen height.
        StatsSummaryPill.period(
            stats,
            periodLabel: model.period?.isCurrent == true ? nil : model.period?.label
        )
        .padding(.bottom, 26)
    }

    @ViewBuilder
    private func rowOrSelectRow(_ activity: ActivitySummary) -> some View {
        if selecting {
            Button {
                toggleSelection(activity.id)
            } label: {
                row(activity)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: activity) {
                row(activity)
            }
            .buttonStyle(.plain)
            .task { await model.loadMoreIfNeeded(session, current: activity) }
        }
    }

    private func toggleSelection(_ id: Int) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    private func row(_ activity: ActivitySummary) -> some View {
        let selected = selectedIds.contains(activity.id)

        return HStack(spacing: 10) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(PaperInk.brand)
            }

            RoundedRectangle(cornerRadius: 3)
                .fill(typeColor(activity.type))
                .frame(width: 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title)
                    .font(PaperInk.sans(14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if activity.merged == true {
                        Image(systemName: "square.stack")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(PaperInk.brandDark)
                    }
                    if let date = activity.startsOn {
                        Text(Self.shortDate(date))
                    }
                    Text(activity.type.name)
                    if let organisation = activity.organisation, !organisation.isEmpty {
                        Text(organisation).lineLimit(1)
                    }
                }
                .font(PaperInk.sans(11))
                .foregroundStyle(PaperInk.stone500)
            }

            Spacer(minLength: 4)

            VStack(spacing: 0) {
                Text(InboxView.points(activity.cpdPoints))
                    .font(PaperInk.sans(16, weight: .heavy))
                    .foregroundStyle(PaperInk.brand)
                Text("pts")
                    .font(PaperInk.sans(9, weight: .bold))
                    .foregroundStyle(PaperInk.stone400)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? PaperInk.brand : PaperInk.ink, lineWidth: 2)
        )
        .stickerShadow()
        .rowTilt(seed: activity.id)
    }

    static func shortDate(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// Slim always-visible summary pill — content scrolls behind it. Shared
/// styling for the timeline (period points) and inbox (waiting count).
struct StatsSummaryPill: View {
    var text: Text

    /// Timeline flavour: points + activity count for the viewed year.
    static func period(_ stats: StatsResponse.Stats, periodLabel: String? = nil) -> StatsSummaryPill {
        StatsSummaryPill(text:
            Text(InboxView.points(stats.points)).fontWeight(.heavy).foregroundColor(PaperInk.brand)
                + Text(periodLabel.map { " CPD points in \($0) · " } ?? " CPD points this year · ")
                + Text("\(stats.activities)").fontWeight(.heavy)
                + Text(stats.activities == 1 ? " activity" : " activities"))
    }

    /// Inbox flavour: what's still waiting for review.
    static func awaiting(_ stats: StatsResponse.Stats) -> StatsSummaryPill {
        StatsSummaryPill(text:
            Text("\(stats.awaiting)").fontWeight(.heavy).foregroundColor(PaperInk.brand)
                + Text(stats.awaiting == 1 ? " item waiting for review" : " items waiting for review"))
    }

    var body: some View {
        text
            .font(PaperInk.sans(12.5))
            .foregroundStyle(PaperInk.stone600)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white.opacity(0.94))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(PaperInk.ink, lineWidth: 2))
            .stickerShadow()
            .tilt(-0.5)
            .allowsHitTesting(false)
    }
}

/// Maps the server's category colours to the paper palette.
func typeColor(_ type: ActivityTypeRef) -> Color {
    if let hex = type.color, hex.hasPrefix("#") {
        return Color(hexString: hex)
    }
    switch type.color {
    case "blue": return PaperInk.catBlue
    case "green": return PaperInk.catGreen
    case "purple": return PaperInk.catPurple
    case "orange", "brand": return PaperInk.brand
    default: return PaperInk.stone500
    }
}

struct ActivityDetailView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    let activityId: Int
    /// Called after a split or edit so the timeline list refreshes.
    var onChanged: (() -> Void)?
    @State private var activity: ActivityDetail?
    @State private var errorMessage: String?
    @State private var confirmingSplit = false
    @State private var editing = false
    @State private var showingPicker = false
    @State private var mergeSeed: MergeSeed?
    @State private var confirmingRemoveInfo = false
    @State private var previewFile: PreviewFile?
    @State private var isWorking = false
    @State private var deletingAttachment: AttachmentRef?
    @State private var generatingTakeaways = false
    @State private var takeawaysError: String?
    @State private var showingTakeawaysHelp = false
    /// Flip between the AI write-up and the verbatim debrief notes.
    @State private var showingMyNotes = false

    var body: some View {
        ScrollView {
            if let activity {
                VStack(alignment: .leading, spacing: 16) {
                    header(activity)

                    if !activity.mergedFrom.isEmpty {
                        mergedFromBox(activity)
                    } else if activity.formerlyMerged == true {
                        Text(activity.mergeUnreviewed == true
                            ? "This entry was created from the AI analysis during a merge and later split back out — give its details a once-over."
                            : "This entry was previously part of a merged entry.")
                            .font(PaperInk.sans(12))
                            .foregroundStyle(PaperInk.stone500)
                    }

                    // Entries written from debrief notes carry both voices:
                    // the AI write-up and the user's own words, verbatim.
                    if let notes = activity.sourceNotes, !notes.isEmpty {
                        writeUpToggle
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    if showingMyNotes, let notes = activity.sourceNotes, !notes.isEmpty {
                        section("Original notes") {
                            Text(notes)
                                .font(PaperInk.sans(14))
                                .italic()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        if let details = activity.details, !details.isEmpty {
                            section("Summary") { Text(details).font(PaperInk.sans(14)) }
                        }

                        if let reflection = activity.reflection, !reflection.isEmpty {
                            section("Reflection") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(reflection.keys.sorted(), id: \.self) { key in
                                        if let answer = reflection[key] ?? nil, !answer.isEmpty {
                                            Text(answer).font(PaperInk.sans(14))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if !activity.categories.isEmpty || !activity.domains.isEmpty {
                        section("Filed under") {
                            FlowLayout(spacing: 6) {
                                ForEach(activity.categories, id: \.slug) { Chip(text: $0.name) }
                                ForEach(activity.domains, id: \.code) {
                                    Chip(text: $0.code, background: PaperInk.paperAlt, foreground: PaperInk.stone600)
                                }
                                ForEach(activity.projects) {
                                    Chip(text: $0.title, background: Color(hex: 0xEFE8F9), foreground: Color(hex: 0x7A52AB))
                                }
                            }
                        }
                    }

                    // Takeaways belong to the final version — the
                    // original-notes tab hides them. (showingMyNotes can
                    // only be true when the entry has notes.)
                    if !showingMyNotes {
                        DashedDivider()

                        takeawaysSection(activity)
                    }

                    if !activity.attachments.isEmpty {
                        // Tap to preview; the ✕ deletes (kept files only).
                        section("Attachments") {
                            AttachmentChips(
                                attachments: activity.attachments,
                                preview: $previewFile,
                                onDelete: { deletingAttachment = $0 }
                            )
                        }
                    }

                    actions(activity)

                    Text("your paper trail — tidy it whenever you like")
                        .font(PaperInk.hand(19))
                        .foregroundStyle(PaperInk.brandDark)
                        .tilt(-1.5)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
                .padding(16)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(PaperInk.sans(13))
                    .foregroundStyle(.red)
                    .padding(30)
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .background(PaperInk.paper)
        .toolbar {
            if activity != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { editing = true }
                        .font(PaperInk.sans(13, weight: .bold))
                        .foregroundStyle(PaperInk.brandDark)
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let activity {
                ActivityEditView(activity: activity) { updated in
                    self.activity = updated
                    onChanged?()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
        }
        .sheet(isPresented: $showingPicker) {
            if let activity {
                MergePickerSheet(
                    baseLabel: activity.title,
                    baseActivityId: activity.id,
                    baseIsMerged: !activity.mergedFrom.isEmpty
                ) { seed in
                    mergeSeed = seed
                }
            }
        }
        .sheet(item: $mergeSeed) { seed in
            MergeSheetView(initialSeed: seed) {
                // This entry is now inside the merged one — back to the list.
                onChanged?()
                dismiss()
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $previewFile) { file in
            AttachmentQuickLook(url: file.url)
        }
        .confirmationDialog(
            "Remove personal information?",
            isPresented: $confirmingRemoveInfo,
            titleVisibility: .visible
        ) {
            Button("Remove it", role: .destructive) { removeInfo() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stored files are deleted and identifiers scrubbed from the text — your entry itself is kept.")
        }
        .confirmationDialog(
            "Delete “\(deletingAttachment?.name ?? "this file")”?",
            isPresented: Binding(
                get: { deletingAttachment != nil },
                set: { if !$0 { deletingAttachment = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete file", role: .destructive) {
                if let attachment = deletingAttachment { deleteAttachment(attachment) }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The file is permanently deleted — your written entry is kept.")
        }
        .confirmationDialog(
            "Split “\(activity?.title ?? "this")” back into \(activity?.mergedFrom.count ?? 0) activities?",
            isPresented: $confirmingSplit,
            titleVisibility: .visible
        ) {
            Button("Split it") { split() }
            Button("Keep merged", role: .cancel) {}
        } message: {
            Text("The originals come back exactly as they were — their own points, dates and files. Nothing is deleted.")
        }
        .task {
            do {
                activity = try await session.api.activity(id: activityId)
            } catch let error as APIError where error.status == 404 {
                // Activities are hard-deleted server-side; this one's gone.
                errorMessage = "This activity was deleted — pull the timeline to refresh."
            } catch where !error.isCancellation {
                errorMessage = error.localizedDescription
            } catch {}
        }
    }

    private func mergedFromBox(_ activity: ActivityDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(PaperInk.stone500)
                Text("Merged from \(activity.mergedFrom.count) entries")
                    .font(PaperInk.sans(12, weight: .heavy))
                    .foregroundStyle(PaperInk.stone600)
            }

            ForEach(activity.mergedFrom) { source in
                Text("· \(source.title)\(source.startsOn.map { " — \(TimelineView.shortDate($0))" } ?? "")")
                    .font(PaperInk.sans(12))
                    .foregroundStyle(PaperInk.stone500)
            }

            Button(isWorking ? "Splitting…" : "Split apart…") { confirmingSplit = true }
                .font(PaperInk.sans(12, weight: .bold))
                .foregroundStyle(PaperInk.brandDark)
                .disabled(isWorking)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(PaperInk.stone400, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
    }

    /// Quiet footer actions: merge this entry with others, or the
    /// post-approval personal-information remedy.
    private func actions(_ activity: ActivityDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showingPicker = true
            } label: {
                Text("Merge with another entry…")
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(PaperInk.stone500)
                    .underline(true, pattern: .dash)
            }
            .buttonStyle(.plain)

            if activity.attachments.contains(where: { $0.purged != true })
                || !(activity.reflection ?? [:]).isEmpty
                || !(activity.details ?? "").isEmpty {
                Button {
                    confirmingRemoveInfo = true
                } label: {
                    Text("Spotted personal info in this entry? Remove it")
                        .font(PaperInk.sans(12, weight: .semibold))
                        .foregroundStyle(PaperInk.stone500)
                        .underline(true, pattern: .dash)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            }
        }
        .padding(.top, 4)
    }

    /// Pill segmented toggle between the finished write-up and the
    /// verbatim debrief notes.
    private var writeUpToggle: some View {
        HStack(spacing: 3) {
            writeUpSegment("Final version", active: !showingMyNotes) { showingMyNotes = false }
            writeUpSegment("Original notes", active: showingMyNotes) { showingMyNotes = true }
        }
        .padding(3)
        .background(PaperInk.paperAlt)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(PaperInk.ink.opacity(0.25), lineWidth: 1.5))
    }

    private func writeUpSegment(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Text(label)
                .font(PaperInk.sans(12, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? .white : .clear)
                .foregroundStyle(active ? PaperInk.ink : PaperInk.stone500)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(active ? PaperInk.ink : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    /// Takeaways are opt-in per activity: entries without any get a
    /// "Generate" button; entries with some show them read-only (ticking
    /// and editing live on the Takeaways tab).
    @ViewBuilder
    private func takeawaysSection(_ activity: ActivityDetail) -> some View {
        if activity.nuggets.isEmpty && activity.actions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        generateTakeaways()
                    } label: {
                        HStack(spacing: 6) {
                            if generatingTakeaways {
                                ProgressView().controlSize(.mini).tint(.white)
                            } else {
                                Sparkle(size: 13, color: .white)
                            }
                            Text(generatingTakeaways ? "Panning for nuggets…" : "Generate takeaways")
                        }
                    }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .disabled(generatingTakeaways || isWorking)

                    Button {
                        showingTakeawaysHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(PaperInk.stone400)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What are takeaways?")
                    .alert("Takeaways", isPresented: $showingTakeawaysHelp) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Pulls nuggets and actions from this entry onto your Takeaways wall — fed back to you as morning gems and weekly recaps until you tick them done.")
                    }
                }

                if let takeawaysError {
                    Text(takeawaysError)
                        .font(PaperInk.sans(12, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 2)
        } else {
            section("Takeaways") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(activity.nuggets) { takeawayBullet($0, accent: false) }
                    ForEach(activity.actions) { takeawayBullet($0, accent: true) }
                }
            }
        }
    }

    private func takeawayBullet(_ item: Takeaway, accent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(PaperInk.sans(15, weight: .heavy))
                .foregroundStyle(accent ? PaperInk.brand : PaperInk.ink)
            Text(item.text)
                .font(PaperInk.sans(14))
                .strikethrough(item.done)
                .foregroundStyle(item.done ? PaperInk.stone500 : PaperInk.ink)
        }
    }

    private func generateTakeaways() {
        generatingTakeaways = true
        takeawaysError = nil
        Task {
            defer { generatingTakeaways = false }
            do {
                let lists = try await session.api.generateTakeaways(activityId: activityId)
                activity?.nuggets = lists.nuggets
                activity?.actions = lists.actions
                onChanged?()
            } catch {
                takeawaysError = error.localizedDescription
            }
        }
    }

    private func removeInfo() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                activity = try await session.api.removeActivityPii(id: activityId)
                onChanged?()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func split() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await session.api.unmerge(activityId: activityId)
                onChanged?()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteAttachment(_ attachment: AttachmentRef) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await session.api.deleteAttachment(id: attachment.id)
                activity = try await session.api.activity(id: activityId)
                onChanged?()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func header(_ activity: ActivityDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(activity.title)
                .display(24)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Chip(text: activity.type.name)
                if let date = activity.startsOn {
                    Text(TimelineView.shortDate(date))
                        .font(PaperInk.sans(12))
                        .foregroundStyle(PaperInk.stone500)
                }
                Text("\(InboxView.points(activity.cpdPoints)) pts")
                    .font(PaperInk.sans(12, weight: .heavy))
                    .foregroundStyle(PaperInk.brand)
            }

            if let organisation = activity.organisation, !organisation.isEmpty {
                Text(organisation)
                    .font(PaperInk.sans(13))
                    .foregroundStyle(PaperInk.stone600)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PaperInk.ink, lineWidth: 2))
        .stickerShadow()
        .tilt(-0.4)
    }

    private func section(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            content()
        }
    }
}
