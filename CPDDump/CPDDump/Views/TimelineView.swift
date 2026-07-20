import SwiftUI

@Observable
final class TimelineModel {
    var activities: [ActivitySummary] = []
    var period: AppraisalPeriod?
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
            let result = try await session.api.activities(page: page)
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

/// Read-only scroll of approved activities. Editing stays on the web.
struct TimelineView: View {
    @Environment(Session.self) private var session
    @Bindable var model: TimelineModel

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
            }
            .navigationDestination(for: ActivitySummary.self) { activity in
                ActivityDetailView(activityId: activity.id)
            }
        }
        .task { await model.load(session, reset: true) }
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
                    NavigationLink(value: activity) {
                        row(activity)
                    }
                    .buttonStyle(.plain)
                    .task { await model.loadMoreIfNeeded(session, current: activity) }
                }
            }
            .padding(14)
        }
        .refreshable { await model.load(session, reset: true) }
    }

    private func row(_ activity: ActivitySummary) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(typeColor(activity.type))
                .frame(width: 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title)
                    .font(PaperInk.sans(14, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
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
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PaperInk.ink, lineWidth: 2))
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

    let activityId: Int
    @State private var activity: ActivityDetail?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            if let activity {
                VStack(alignment: .leading, spacing: 16) {
                    header(activity)

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
                                    Label(attachment.name ?? "Attachment", systemImage: "paperclip")
                                        .font(PaperInk.sans(13))
                                        .foregroundStyle(PaperInk.stone600)
                                }
                            }
                        }
                    }

                    Text("editing lives on the web — this is your paper trail")
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
