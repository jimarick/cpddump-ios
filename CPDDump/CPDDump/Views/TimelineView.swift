import SwiftUI

@Observable
final class TimelineModel {
    var activities: [ActivitySummary] = []
    var period: AppraisalPeriod?
    var stats: StatsResponse.Stats?
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
            async let statsResponse = session.api.stats()
            let result = try await session.api.activities(page: page)
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
    /// Present the merge sheet for the chosen entries.
    var onMerge: (MergeSeed) -> Void

    @State private var selecting = false
    @State private var selectedIds: Set<Int> = []

    var body: some View {
        NavigationStack {
            Group {
                if model.activities.isEmpty && model.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.activities.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(PaperInk.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Timeline").display(22)
                        if let label = model.period?.label {
                            Text(label)
                                .font(PaperInk.sans(11, weight: .semibold))
                                .foregroundStyle(PaperInk.stone500)
                        }
                    }
                }
                if !model.activities.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(selecting ? "Done" : "Select") {
                            withAnimation(.snappy) {
                                selecting.toggle()
                                selectedIds = []
                            }
                        }
                        .font(PaperInk.sans(13, weight: .bold))
                        .foregroundStyle(PaperInk.brandDark)
                    }
                }
            }
            .navigationDestination(for: ActivitySummary.self) { activity in
                ActivityDetailView(activityId: activity.id) {
                    Task { await model.load(session, reset: true) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting { mergeBar }
            }
        }
        .task { await model.load(session, reset: true) }
    }

    /// At most one merged entry can join a stack — it becomes the target.
    private var selectedMergedCount: Int {
        model.activities.filter { selectedIds.contains($0.id) && $0.merged == true }.count
    }

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

            Button("Cancel") {
                withAnimation(.snappy) {
                    selecting = false
                    selectedIds = []
                }
            }
            .font(PaperInk.sans(13, weight: .bold))
            .foregroundStyle(PaperInk.stone600)

            Spacer()

            if selectedMergedCount > 1 {
                Text("split one first")
                    .font(PaperInk.hand(17))
                    .foregroundStyle(.red)
                    .tilt(-1.5)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PaperInk.paper)
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
            .padding(.bottom, 44)
        }
        .refreshable { await model.load(session, reset: true) }
        .overlay(alignment: .bottom) {
            if !selecting, let stats = model.stats {
                summaryPill(stats)
            }
        }
    }

    /// Slim always-visible period summary — rows scroll behind it.
    private func summaryPill(_ stats: StatsResponse.Stats) -> some View {
        (Text(InboxView.points(stats.points)).fontWeight(.heavy).foregroundColor(PaperInk.brand)
            + Text(" CPD points this year · ")
            + Text("\(stats.activities)").fontWeight(.heavy)
            + Text(stats.activities == 1 ? " activity" : " activities"))
            .font(PaperInk.sans(12.5))
            .foregroundStyle(PaperInk.stone600)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white.opacity(0.94))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(PaperInk.ink, lineWidth: 2))
            .stickerShadow()
            .tilt(-0.5)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
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
    @State private var isWorking = false
    @State private var deletingAttachment: AttachmentRef?

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

                    if !activity.attachments.isEmpty {
                        section("Attachments") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(activity.attachments) { attachment in
                                    HStack(spacing: 8) {
                                        Label(attachment.name ?? "Attachment", systemImage: attachment.purged == true ? "doc.badge.ellipsis" : "paperclip")
                                            .font(PaperInk.sans(13))
                                            .foregroundStyle(PaperInk.stone600)
                                            .strikethrough(attachment.purged == true, color: PaperInk.stone400)
                                        if attachment.purged == true {
                                            Text("not kept")
                                                .font(PaperInk.sans(11))
                                                .foregroundStyle(PaperInk.stone400)
                                        } else {
                                            Button {
                                                deletingAttachment = attachment
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(PaperInk.stone400)
                                            }
                                            .disabled(isWorking)
                                        }
                                    }
                                }
                            }
                        }
                    }

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
