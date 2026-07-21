import SwiftUI

@Observable
final class TakeawaysModel {
    var period: AppraisalPeriod?
    var activities: [TakeawayActivity] = []
    var isLoading = false
    var errorMessage: String?

    func load(_ session: Session) async {
        do {
            let response = try await session.api.fetchTakeaways()
            period = response.period
            activities = response.activities
            errorMessage = nil
        } catch let error as APIError where error.status == 401 {
            session.handleUnauthorised()
        } catch where !error.isCancellation {
            errorMessage = error.localizedDescription
        } catch {}
        isLoading = false
    }

    /// Every tick/delete response carries the activity's fresh lists — adopt
    /// them wholesale rather than patching local state by hand.
    func apply(_ lists: TakeawayLists, to activityId: Int) {
        guard let index = activities.firstIndex(where: { $0.id == activityId }) else { return }
        if lists.nuggets.isEmpty && lists.actions.isEmpty {
            // The server only lists activities with at least one takeaway.
            activities.remove(at: index)
        } else {
            activities[index].nuggets = lists.nuggets
            activities[index].actions = lists.actions
        }
    }
}

/// One takeaway flattened out of its activity for the cross-activity lists.
private struct TakeawayEntry: Identifiable {
    var activity: TakeawayActivity
    var item: Takeaway
    var isAction: Bool
    var id: String { item.id }
}

/// The Takeaways tab: everything worth remembering (nuggets) and worth
/// doing (actions) across the current appraisal year, tickable in place.
/// Tapping a row opens its activity's takeaways with a flip to the
/// original debrief notes.
struct TakeawaysView: View {
    @Environment(Session.self) private var session
    @Bindable var model: TakeawaysModel

    @State private var detailActivity: TakeawayActivity?
    @State private var showDone = false
    @State private var workingIds: Set<String> = []

    var body: some View {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PaperInk.paper)
        .task {
            model.isLoading = model.activities.isEmpty
            await model.load(session)
        }
        .sheet(item: $detailActivity) { activity in
            TakeawayActivitySheet(model: model, activityId: activity.id)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Flattened lists

    private var openNuggets: [TakeawayEntry] {
        model.activities.flatMap { activity in
            activity.nuggets.filter { !$0.done }
                .map { TakeawayEntry(activity: activity, item: $0, isAction: false) }
        }
    }

    private var openActions: [TakeawayEntry] {
        model.activities.flatMap { activity in
            activity.actions.filter { !$0.done }
                .map { TakeawayEntry(activity: activity, item: $0, isAction: true) }
        }
    }

    private var doneEntries: [TakeawayEntry] {
        model.activities.flatMap { activity in
            activity.nuggets.filter(\.done)
                .map { TakeawayEntry(activity: activity, item: $0, isAction: false) }
                + activity.actions.filter(\.done)
                .map { TakeawayEntry(activity: activity, item: $0, isAction: true) }
        }
    }

    // MARK: Header — matches the inbox/timeline in-content header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Takeaways").display(32)
                Text(subtitle)
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(PaperInk.stone500)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

    private var subtitle: String {
        var parts = [
            "\(openNuggets.count) \(openNuggets.count == 1 ? "nugget" : "nuggets")",
            "\(openActions.count) \(openActions.count == 1 ? "action" : "actions") open",
        ]
        if let label = model.period?.label { parts.append(label) }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No takeaways yet").display(22)
            Text("approve something with nuggets in it and they collect here")
                .font(PaperInk.hand(20))
                .foregroundStyle(PaperInk.brandDark)
                .multilineTextAlignment(.center)
                .tilt(-1.5)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Lists

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(PaperInk.sans(12, weight: .semibold))
                        .foregroundStyle(.red)
                }

                if !openNuggets.isEmpty {
                    section("Nuggets") {
                        ForEach(openNuggets) { row($0) }
                    }
                }

                if !openActions.isEmpty {
                    section("Actions") {
                        ForEach(openActions) { row($0) }
                    }
                }

                if openNuggets.isEmpty && openActions.isEmpty {
                    Text("all ticked off — nothing left open")
                        .font(PaperInk.hand(20))
                        .foregroundStyle(PaperInk.brandDark)
                        .tilt(-1.5)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }

                if !doneEntries.isEmpty {
                    doneSection
                }
            }
            .padding(14)
        }
        .refreshable { await model.load(session) }
    }

    private func section(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            FieldLabel(text: label)
            content()
        }
    }

    /// Ticked-off takeaways stay reachable (and un-tickable) but collapsed
    /// out of the way.
    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.snappy) { showDone.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(showDone ? 90 : 0))
                    Text("Done (\(doneEntries.count))")
                        .font(PaperInk.sans(10, weight: .heavy))
                        .textCase(.uppercase)
                        .kerning(0.8)
                }
                .foregroundStyle(PaperInk.stone500)
            }
            .buttonStyle(.plain)

            if showDone {
                ForEach(doneEntries) { row($0) }
            }
        }
    }

    private func row(_ entry: TakeawayEntry) -> some View {
        HStack(spacing: 10) {
            if entry.isAction && !entry.item.done {
                RoundedRectangle(cornerRadius: 3)
                    .fill(PaperInk.brand)
                    .frame(width: 6)
            }

            Button {
                setDone(entry, done: !entry.item.done)
            } label: {
                Image(systemName: entry.item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(entry.item.done ? PaperInk.brand : PaperInk.stone400)
            }
            .buttonStyle(.plain)
            .disabled(workingIds.contains(entry.item.id))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.text)
                    .font(PaperInk.sans(13, weight: .semibold))
                    .strikethrough(entry.item.done)
                    .foregroundStyle(entry.item.done ? PaperInk.stone500 : PaperInk.ink)
                    .multilineTextAlignment(.leading)
                Text(entry.activity.title)
                    .font(PaperInk.sans(11))
                    .foregroundStyle(PaperInk.stone500)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PaperInk.ink, lineWidth: 2))
        .stickerShadow()
        .rowTilt(seed: entry.activity.id)
        .contentShape(Rectangle())
        .onTapGesture { detailActivity = entry.activity }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                delete(entry)
            }
        }
    }

    // MARK: Mutations — server state is the truth, local state adopts it

    private func setDone(_ entry: TakeawayEntry, done: Bool) {
        mutate(entry) {
            try await session.api.updateTakeaway(
                activityId: entry.activity.id,
                itemId: entry.item.id,
                done: done
            )
        }
    }

    private func delete(_ entry: TakeawayEntry) {
        mutate(entry) {
            try await session.api.deleteTakeaway(activityId: entry.activity.id, itemId: entry.item.id)
        }
    }

    private func mutate(_ entry: TakeawayEntry, _ operation: @escaping () async throws -> TakeawayLists) {
        guard !workingIds.contains(entry.item.id) else { return }
        workingIds.insert(entry.item.id)
        Task {
            defer { workingIds.remove(entry.item.id) }
            do {
                model.apply(try await operation(), to: entry.activity.id)
            } catch let error as APIError where error.status == 404 {
                // Deleted elsewhere — mirror the server.
                await model.load(session)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

/// One activity's takeaways in a sheet, with a flip to the original debrief
/// notes they were mined from.
struct TakeawayActivitySheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @Bindable var model: TakeawaysModel
    let activityId: Int

    @State private var showingNotes = false
    @State private var workingIds: Set<String> = []
    @State private var errorMessage: String?

    /// Always read fresh from the model so ticks update in place.
    private var activity: TakeawayActivity? {
        model.activities.first { $0.id == activityId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(PaperInk.ink.opacity(0.2))
                .frame(width: 40, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

            if let activity {
                HStack(alignment: .top, spacing: 8) {
                    Text(activity.title)
                        .display(21)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    if activity.hasSourceNotes, activity.sourceNotes != nil {
                        Button(showingNotes ? "Takeaways" : "The notes") {
                            withAnimation(.snappy) { showingNotes.toggle() }
                        }
                        .font(PaperInk.sans(12, weight: .bold))
                        .foregroundStyle(PaperInk.brandDark)
                        .padding(.top, 4)
                    }
                }

                HStack(spacing: 8) {
                    Chip(text: activity.type.name)
                    if let date = activity.startsOn {
                        Text(TimelineView.shortDate(date))
                            .font(PaperInk.sans(12))
                            .foregroundStyle(PaperInk.stone500)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(PaperInk.sans(12, weight: .semibold))
                        .foregroundStyle(.red)
                }

                ScrollView {
                    if showingNotes, let notes = activity.sourceNotes {
                        Text(notes)
                            .font(PaperInk.sans(14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 12)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            if !activity.nuggets.isEmpty {
                                takeawaySection("Nuggets", items: activity.nuggets, accent: false)
                            }
                            if !activity.actions.isEmpty {
                                takeawaySection("Actions", items: activity.actions, accent: true)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                }
            } else {
                // Emptied underneath us (everything deleted) — nothing to show.
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .background(PaperInk.paper)
        .onChange(of: activity == nil) {
            if activity == nil { dismiss() }
        }
    }

    private func takeawaySection(_ label: String, items: [Takeaway], accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: label)
            ForEach(items) { item in
                HStack(spacing: 10) {
                    if accent && !item.done {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(PaperInk.brand)
                            .frame(width: 4)
                    }
                    Button {
                        setDone(item, done: !item.done)
                    } label: {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(item.done ? PaperInk.brand : PaperInk.stone400)
                    }
                    .buttonStyle(.plain)
                    .disabled(workingIds.contains(item.id))

                    Text(item.text)
                        .font(PaperInk.sans(13, weight: .semibold))
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? PaperInk.stone500 : PaperInk.ink)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(PaperInk.ink.opacity(0.35), lineWidth: 1.5))
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        delete(item)
                    }
                }
            }
        }
    }

    private func setDone(_ item: Takeaway, done: Bool) {
        mutate(item) {
            try await session.api.updateTakeaway(activityId: activityId, itemId: item.id, done: done)
        }
    }

    private func delete(_ item: Takeaway) {
        mutate(item) {
            try await session.api.deleteTakeaway(activityId: activityId, itemId: item.id)
        }
    }

    private func mutate(_ item: Takeaway, _ operation: @escaping () async throws -> TakeawayLists) {
        guard !workingIds.contains(item.id) else { return }
        workingIds.insert(item.id)
        Task {
            defer { workingIds.remove(item.id) }
            do {
                model.apply(try await operation(), to: activityId)
            } catch let error as APIError where error.status == 404 {
                await model.load(session)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
