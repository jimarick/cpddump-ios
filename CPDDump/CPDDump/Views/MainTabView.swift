import SwiftUI

/// Custom paper tab bar: Inbox | Timeline | Takeaways, with the mic as a
/// floating capture button over the inbox. Settings hides behind the
/// avatar, as on the web.
struct MainTabView: View {
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    enum Tab { case inbox, timeline, takeaways }

    @State private var tab: Tab = .inbox
    @State private var inboxModel = InboxModel()
    @State private var timelineModel = TimelineModel()
    @State private var takeawaysModel = TakeawaysModel()
    @State private var reviewItem: InboxItem?
    @State private var mergeSeed: MergeSeed?
    @State private var showRecorder = false
    @State private var showDumpSheet = false
    @State private var showSettings = false
    // While either page is in selection mode its merge bar replaces the
    // tab bar; the tabs come back on cancel or merge.
    @State private var inboxSelecting = false
    @State private var timelineSelecting = false

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Group {
                switch tab {
                case .inbox:
                    InboxView(
                        model: inboxModel,
                        onReview: { item in openReview(item) },
                        onMerge: { itemIds in
                            mergeSeed = MergeSeed(inboxItemIds: itemIds)
                        },
                        selecting: $inboxSelecting
                    )
                case .timeline:
                    TimelineView(model: timelineModel, selecting: $timelineSelecting) { seed in
                        mergeSeed = seed
                    }
                case .takeaways:
                    TakeawaysView(model: takeawaysModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                // The capture mic floats over the inbox, its centre level
                // with the awaiting pill. Steps aside during selection.
                if tab == .inbox && !inboxSelecting {
                    micFab
                }
            }

            if !(inboxSelecting || timelineSelecting) {
                tabBar
            }
        }
        .background(PaperInk.paper)
        .sheet(item: $reviewItem) { item in
            ReviewSheetView(
                item: item,
                onResolved: {
                    Task { await inboxModel.refresh(session) }
                },
                onMergeInstead: { seed in
                    reviewItem = nil
                    mergeSeed = seed
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $mergeSeed) { seed in
            MergeSheetView(initialSeed: seed) {
                Task {
                    await inboxModel.refresh(session)
                    await timelineModel.load(session, reset: true)
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .fullScreenCover(isPresented: $showRecorder) {
            RecordView {
                tab = .inbox
                Task { await inboxModel.refresh(session) }
            }
        }
        .sheet(isPresented: $showDumpSheet) {
            DumpSheetView {
                tab = .inbox
                Task { await inboxModel.refresh(session) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheetView()
                .presentationDetents([.medium, .large])
        }
        .task {
            UploadQueue.shared.onUploaded = {
                NotificationManager.shared.promptAfterFirstDumpIfNeeded()
                Task { await inboxModel.refresh(session) }
            }
            consumeLaunchAction()
            await session.refreshUser()
        }
        .onChange(of: LaunchActions.shared.wantsRecorder) {
            consumeLaunchAction()
        }
        .onChange(of: LaunchActions.shared.reviewItemId) {
            consumeLaunchAction()
        }
        .onChange(of: LaunchActions.shared.wantsInbox) {
            consumeLaunchAction()
        }
        .onChange(of: LaunchActions.shared.openActivityId) {
            // TimelineView owns consuming the id; we just surface the tab.
            if LaunchActions.shared.openActivityId != nil { tab = .timeline }
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from elsewhere (e.g. after using the share extension):
            // adopt extension uploads and refresh the pile.
            if phase == .active {
                UploadQueue.shared.syncExtensionQueue()
                Task { await inboxModel.refresh(session) }
            }
        }
    }

    /// Intents ("Dump a voice note") and notification deep links.
    private func consumeLaunchAction() {
        if LaunchActions.shared.wantsRecorder {
            LaunchActions.shared.wantsRecorder = false
            showDumpSheet = false
            showRecorder = true
        }
        if LaunchActions.shared.wantsInbox {
            LaunchActions.shared.wantsInbox = false
            tab = .inbox
            Task { await inboxModel.refresh(session) }
        }
        if let itemId = LaunchActions.shared.reviewItemId {
            LaunchActions.shared.reviewItemId = nil
            tab = .inbox
            Task {
                if let item = try? await session.api.inboxItem(id: itemId) {
                    reviewItem = item
                }
                await inboxModel.refresh(session)
            }
        }
        if LaunchActions.shared.openActivityId != nil {
            tab = .timeline
        }
    }

    private func openReview(_ item: InboxItem) {
        Task {
            do {
                // Fetch the detailed item (includes attachment URLs) first.
                reviewItem = try await session.api.inboxItem(id: item.id)
            } catch let error as APIError where error.status == 404 {
                // Hard-deleted elsewhere — reconcile instead of opening a ghost.
                await inboxModel.refresh(session)
            } catch {
                reviewItem = item
            }
        }
    }

    private var topBar: some View {
        HStack {
            Wordmark(size: 25)
            Spacer()
            Button {
                showDumpSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(PaperInk.brandDark)
                    .frame(width: 32, height: 32)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(PaperInk.ink, lineWidth: 2))
            }
            .padding(.trailing, 6)
            Menu {
                if let user = session.user {
                    Text(user.name)
                    if let address = user.dumpAddress {
                        Text(address)
                    }
                }
                Divider()
                Link(destination: session.api.baseURL.appending(path: "ai")) {
                    Label("How we use AI", systemImage: "sparkle")
                }
                Link(destination: session.api.baseURL.appending(path: "privacy")) {
                    Label("Privacy policy", systemImage: "lock")
                }
                Divider()
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button("Sign out", role: .destructive) {
                    Task { await session.signOut() }
                }
            } label: {
                Text(session.user?.initials ?? "•")
                    .font(PaperInk.sans(11, weight: .heavy))
                    .foregroundStyle(PaperInk.brandDark)
                    .frame(width: 32, height: 32)
                    .background(PaperInk.tint)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(PaperInk.ink, lineWidth: 2))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            DashedDivider()
        }
    }

    /// The floating capture mic — same sticker styling as ever, now
    /// hovering bottom-right over the inbox instead of splitting the tabs.
    private var micFab: some View {
        Button {
            showRecorder = true
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(PaperInk.brand)
                .clipShape(Circle())
                .overlay(Circle().stroke(PaperInk.ink, lineWidth: 2.5))
                .stickerShadow(offset: 3, opacity: 1)
                .tilt(-2)
        }
        // Clearly inside the inbox's dotted wall: the tray is inset 14pt
        // from the screen edges, so 32pt leaves an 18pt gap between the
        // circle and both dashed lines — mirrored by the awaiting pill on
        // the left, so the two share a baseline.
        .padding(.trailing, 32)
        .padding(.bottom, 32)
    }

    private var tabBar: some View {
        HStack {
            tabButton("Inbox", symbol: "tray.full", value: .inbox)
                .frame(maxWidth: .infinity)

            tabButton("Timeline", symbol: "calendar", value: .timeline)
                .frame(maxWidth: .infinity)

            tabButton("Takeaways", symbol: "sparkles", value: .takeaways)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(PaperInk.paper)
        .overlay(alignment: .top) {
            DashedDivider()
        }
    }

    private func tabButton(_ label: String, symbol: String, value: Tab) -> some View {
        Button {
            tab = value
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(label).font(PaperInk.sans(10, weight: .bold))
            }
            .foregroundStyle(tab == value ? PaperInk.ink : PaperInk.stone500)
        }
        .buttonStyle(.plain)
    }
}

struct DashedDivider: View {
    var body: some View {
        Line()
            .stroke(PaperInk.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .frame(height: 1.5)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}
