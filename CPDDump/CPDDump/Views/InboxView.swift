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

    func bin(_ item: InboxItem, _ session: Session) async {
        items.removeAll { $0.id == item.id }
        try? await session.api.dismiss(id: item.id)
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
    @State private var doodleCeiling: CGFloat = 0
    @State private var binCandidate: InboxItem?
    @State private var discardCandidate: UploadQueue.Pending?

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

            statsLine
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
        VStack(alignment: .leading, spacing: 2) {
            Text("Inbox").display(32)
            if let since = model.stats?.period?.startsOn {
                Text("since \(Self.longDate(since))")
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(PaperInk.stone500)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 8)
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
        HStack(spacing: 8) {
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

            if !item.attachments.isEmpty {
                Image(systemName: "paperclip")
                    .font(.system(size: 11))
                    .foregroundStyle(PaperInk.stone400)
            }

            switch item.status {
            case .ready: Pill(text: "Review")
            case .failed: Chip(text: "Failed", background: .red.opacity(0.12), foreground: .red)
            default: EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PaperInk.ink, lineWidth: 2))
        .stickerShadow()
        .rowTilt(seed: item.id)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.status == .ready { onReview(item) }
        }
        .contextMenu {
            if item.status == .ready {
                Button("Review") { onReview(item) }
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

    private var statsLine: some View {
        Group {
            if let stats = model.stats?.stats {
                (Text("\(stats.activities) \(stats.activities == 1 ? "activity" : "activities") · ")
                    + Text(Self.points(stats.points)).foregroundColor(PaperInk.brand).fontWeight(.heavy)
                    + Text(" CPD points · ")
                    + Text("\(stats.awaiting)").foregroundColor(PaperInk.brand).fontWeight(.heavy)
                    + Text(" awaiting approval"))
                    .font(PaperInk.sans(12))
                    .foregroundStyle(PaperInk.stone600)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(PaperInk.paperAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
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
