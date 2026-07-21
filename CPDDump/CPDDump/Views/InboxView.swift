import SwiftUI

@Observable
final class InboxModel {
    var items: [InboxItem] = []
    var stats: StatsResponse?
    var isLoading = false
    var errorMessage: String?

    func refresh(_ session: Session) async {
        do {
            async let items = session.api.inboxItems()
            async let stats = session.api.stats()
            self.items = try await items
            self.stats = try? await stats
            errorMessage = nil
            if let awaiting = self.stats?.stats.awaiting {
                NotificationManager.shared.setBadge(awaiting)
            }
        } catch let error as APIError where error.status == 401 {
            session.handleUnauthorised()
        } catch where !error.isCancellation {
            errorMessage = error.localizedDescription
        } catch {}
        isLoading = false
    }

    var anyBusy: Bool { items.contains { $0.status.isBusy } }

    func bin(_ item: InboxItem, _ session: Session, neverAgain: Bool = false) async {
        items.removeAll { $0.id == item.id }
        try? await session.api.dismiss(
            id: item.id,
            neverAgainTitle: neverAgain ? item.displayTitle : nil
        )
        await refresh(session)
    }

    func retry(_ item: InboxItem, _ session: Session) async {
        try? await session.api.retry(id: item.id)
        await refresh(session)
    }
}

private struct TrayContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct InboxView: View {
    @Environment(Session.self) private var session
    @Bindable var model: InboxModel
    var onReview: (InboxItem) -> Void
    /// Present the merge sheet for the selected Ready item ids.
    var onMerge: ([Int]) -> Void
    /// Owned by MainTabView so the tab bar can step aside while selecting.
    @Binding var selecting: Bool
    @State private var doodleCeiling: CGFloat = 0
    @State private var binCandidate: InboxItem?
    @State private var discardCandidate: UploadQueue.Pending?
    @State private var selectedIds: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
            }

            VStack(alignment: .trailing, spacing: -2) {
                Text("don't let it pile up")
                    .font(PaperInk.hand(21))
                    .foregroundStyle(PaperInk.brandDark)
                    .tilt(-2)
                    .padding(.trailing, 42)
                    .overlay(alignment: .topTrailing) {
                        ScribbleArrow().offset(x: -4, y: 8)
                    }
                    .zIndex(1)

                tray
            }
            .padding(.horizontal, 14)
            // Breathing room so the dashed tray edge never touches the
            // tab bar's divider — matches the side margins.
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) {
                if !selecting, let stats = model.stats?.stats {
                    StatsSummaryPill.awaiting(stats)
                        .padding(.bottom, 26)
                }
            }

            if selecting {
                mergeBar
            }
        }
        .background(PaperInk.paper)
        .task {
            model.isLoading = model.items.isEmpty
            await model.refresh(session)
        }
        .task(id: model.anyBusy) {
            // Poll while anything is pending/analysing.
            while model.anyBusy && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await model.refresh(session)
            }
        }
        .confirmationDialog(
            "Bin \"\(binCandidate?.displayTitle ?? "this")\"?",
            isPresented: Binding(
                get: { binCandidate != nil },
                set: { if !$0 { binCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Bin it", role: .destructive) {
                if let item = binCandidate {
                    Task { await model.bin(item, session) }
                }
                binCandidate = nil
            }
            if binCandidate?.source == "email" || binCandidate?.source == "calendar" {
                Button("Bin & never show items like this", role: .destructive) {
                    if let item = binCandidate {
                        Task { await model.bin(item, session, neverAgain: true) }
                    }
                    binCandidate = nil
                }
            }
            Button("Keep it", role: .cancel) { binCandidate = nil }
        }
        .confirmationDialog(
            "Discard \"\(discardCandidate?.label ?? "this")\"? It never reached the server.",
            isPresented: Binding(
                get: { discardCandidate != nil },
                set: { if !$0 { discardCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                if let pending = discardCandidate {
                    UploadQueue.shared.discard(pending)
                }
                discardCandidate = nil
            }
            Button("Keep it", role: .cancel) { discardCandidate = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Inbox").display(32)
                if let since = model.stats?.period?.startsOn {
                    Text("since \(Self.longDate(since))")
                        .font(PaperInk.sans(12, weight: .semibold))
                        .foregroundStyle(PaperInk.stone500)
                }
            }

            Spacer()

            // Selection mode = the app's answer to the web's drag-to-stack.
            if model.items.contains(where: { $0.status == .ready }) {
                Button(selecting ? "Done" : "Select") {
                    withAnimation(.snappy) {
                        selecting.toggle()
                        selectedIds = []
                    }
                }
                .font(PaperInk.sans(13, weight: .bold))
                .foregroundStyle(PaperInk.brandDark)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    /// Stands in for the tab bar while selecting: Merge leading, Cancel
    /// trailing, the nudge in between until there's enough to merge.
    private var mergeBar: some View {
        HStack(spacing: 12) {
            Button("Merge \(selectedIds.count) into one") {
                let ids = Array(selectedIds)
                withAnimation(.snappy) {
                    selecting = false
                    selectedIds = []
                }
                onMerge(ids)
            }
            .buttonStyle(InkButtonStyle(prominent: true))
            .disabled(selectedIds.count < 2)

            Spacer(minLength: 8)

            if selectedIds.count < 2 {
                Text("tap the ready ones to stack them")
                    .font(PaperInk.hand(17))
                    .foregroundStyle(PaperInk.brandDark)
                    .tilt(-1.5)
                    .lineLimit(2)

                Spacer(minLength: 8)
            }

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

    private var tray: some View {
        Tray {
            Group {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.items.isEmpty && UploadQueue.shared.visibleItems.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 9) {
                            ForEach(UploadQueue.shared.visibleItems) { pending in
                                uploadingRow(pending)
                            }
                            ForEach(model.items) { item in
                                row(item)
                            }
                        }
                        .padding(12)
                        // Room so the last rows can scroll clear of the pill.
                        .padding(.bottom, 40)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: TrayContentBottomKey.self,
                                    value: geometry.frame(in: .named("tray")).maxY
                                )
                            }
                        )
                    }
                    .refreshable {
                        UploadQueue.shared.clearFailed()
                        await model.refresh(session)
                    }
                }
            }
            .coordinateSpace(name: "tray")
            .onPreferenceChange(TrayContentBottomKey.self) { doodleCeiling = $0 }
            .overlay {
                DoodleWatermark(ceiling: model.items.isEmpty && UploadQueue.shared.visibleItems.isEmpty ? 0 : doodleCeiling + 6)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Nothing in the pile yet").display(22)
            Text("record a voice note or share something in — the AI does the filing")
                .font(PaperInk.hand(20))
                .foregroundStyle(PaperInk.brandDark)
                .multilineTextAlignment(.center)
                .tilt(-1.5)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func uploadingRow(_ pending: UploadQueue.Pending) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pending.sourceSymbol)
                .font(.system(size: 13))
                .foregroundStyle(PaperInk.stone400)
                .frame(width: 18)

            if pending.failed {
                Text(pending.label)
                    .font(PaperInk.sans(13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Chip(text: pending.failureText, background: .red.opacity(0.12), foreground: .red)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Uploading…")
                        .font(PaperInk.sans(13))
                        .foregroundStyle(PaperInk.stone500)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PaperInk.ink.opacity(pending.failed ? 1 : 0.4), lineWidth: 2))
        .stickerShadow()
        .contextMenu {
            if pending.failed {
                Button("Try again") { UploadQueue.shared.retry(pending, session: session) }
                Button("Discard", role: .destructive) { discardCandidate = pending }
            }
        }
        .swipeReveal(
            onReview: nil,
            binLabel: "Discard",
            onBin: { if pending.failed { discardCandidate = pending } }
        )
    }

    private func row(_ item: InboxItem) -> some View {
        let selectable = item.status == .ready
        let selected = selectedIds.contains(item.id)
        let related = (item.aiWarnings?.possibleRelatedInboxItemIds ?? [])
            + (item.aiWarnings?.possibleDuplicateInboxItemIds ?? [])

        let card = HStack(spacing: 8) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selectable ? PaperInk.brand : PaperInk.stone400.opacity(0.4))
            }

            Image(systemName: item.sourceSymbol)
                .font(.system(size: 13))
                .foregroundStyle(PaperInk.stone400)
                .frame(width: 18)

            if item.status.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("AI is reading this…")
                        .font(PaperInk.sans(13))
                        .foregroundStyle(PaperInk.stone500)
                }
                Spacer(minLength: 0)
            } else {
                Text(item.displayTitle)
                    .font(PaperInk.sans(13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if !related.isEmpty {
                Image(systemName: "link")
                    .font(.system(size: 11))
                    .foregroundStyle(PaperInk.brand)
            }

            if !item.attachments.isEmpty {
                Image(systemName: "paperclip")
                    .font(.system(size: 11))
                    .foregroundStyle(PaperInk.stone400)
            }

            switch item.status {
            case .ready: Pill(text: selecting ? (selected ? "Stacked" : "Stack") : "Review")
            case .failed: Chip(text: "Failed", background: .red.opacity(0.12), foreground: .red)
            default: EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? PaperInk.brand : PaperInk.ink, lineWidth: 2)
        )
        .stickerShadow()
        .rowTilt(seed: item.id)
        .opacity(selecting && !selectable ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting {
                if selectable { toggleSelection(item.id) }
            } else if item.status == .ready {
                onReview(item)
            }
        }

        return Group {
            if selecting {
                card
            } else {
                card
                    .contextMenu {
                        if item.status == .ready {
                            Button("Review") { onReview(item) }
                            Button("Merge with…") {
                                withAnimation(.snappy) {
                                    selecting = true
                                    selectedIds = [item.id]
                                }
                            }
                        }
                        if item.status == .failed {
                            Button("Try again") { Task { await model.retry(item, session) } }
                        }
                        Button("Bin it", role: .destructive) { binCandidate = item }
                    }
                    .swipeReveal(
                        onReview: item.status == .ready ? { onReview(item) } : nil,
                        onBin: { binCandidate = item }
                    )
            }
        }
    }

    private func toggleSelection(_ id: Int) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    static func points(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func longDate(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(iso.prefix(10))) else { return iso }
        return date.formatted(date: .long, time: .omitted)
    }
}

/// Swipe right to review, swipe left to bin — with the action peeking out
/// from under the row so it's obvious what letting go will do. Binning is
/// confirmed by the caller before anything is deleted.
private struct SwipeReveal: ViewModifier {
    var onReview: (() -> Void)?
    var binLabel = "Bin it"
    var onBin: () -> Void

    @State private var offset: CGFloat = 0
    @State private var armed = false

    private let threshold: CGFloat = 70

    func body(content: Content) -> some View {
        ZStack {
            if offset > 0, onReview != nil {
                hint("Review", symbol: "arrow.up.forward.square", color: PaperInk.brandDark, alignment: .leading)
            } else if offset < 0 {
                hint(binLabel, symbol: "trash", color: .red, alignment: .trailing)
            }

            content
                .offset(x: offset)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: armed)
        .gesture(
            DragGesture(minimumDistance: 25)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    var translation = value.translation.width * 0.6
                    if onReview == nil { translation = min(translation, 0) }
                    offset = translation
                    armed = abs(translation) > threshold
                }
                .onEnded { value in
                    defer {
                        withAnimation(.snappy) { offset = 0 }
                        armed = false
                    }
                    guard abs(offset) > threshold else { return }
                    if offset > 0 { onReview?() }
                    if offset < 0 { onBin() }
                }
        )
    }

    private func hint(_ label: String, symbol: String, color: Color, alignment: Alignment) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold))
            Text(label).font(PaperInk.sans(12, weight: .heavy))
        }
        .foregroundStyle(armed ? .white : color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(armed ? color : color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: alignment)
        .animation(.snappy(duration: 0.15), value: armed)
    }
}

extension View {
    func swipeReveal(onReview: (() -> Void)?, binLabel: String = "Bin it", onBin: @escaping () -> Void) -> some View {
        modifier(SwipeReveal(onReview: onReview, binLabel: binLabel, onBin: onBin))
    }
}
