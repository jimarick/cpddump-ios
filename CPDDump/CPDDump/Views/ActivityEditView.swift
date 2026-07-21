import SwiftUI

/// Native activity editing — arrived with the merge feature, so tweaking a
/// combined entry's reflection doesn't need a laptop. Same fields as the
/// review sheet, saved through PUT activities/{id}.
struct ActivityEditView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    let activity: ActivityDetail
    var onSaved: (ActivityDetail) -> Void

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

    @State private var isWorking = false
    @State private var errorMessage: String?

    private var reference: Reference? { session.reference }

    var body: some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(PaperInk.ink.opacity(0.2))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            HStack {
                Text("Edit activity").display(22)
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    labelled("Title") {
                        TextField("Title", text: $title, axis: .vertical)
                    }

                    // Single-column, same order as the review sheet:
                    // Dates, Points, Type, Project, Details. No
                    // Organisation input — the value still rides in the
                    // payload untouched.
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(text: "Dates")
                        HStack(spacing: 6) {
                            TextField("YYYY-MM-DD", text: $startsOn)
                                .font(PaperInk.sans(14))
                                .boxed()
                            Text("→").foregroundStyle(PaperInk.stone400)
                            TextField("YYYY-MM-DD", text: $endsOn)
                                .font(PaperInk.sans(14))
                                .boxed()
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            FieldLabel(text: "Points")
                            CpdPointsInfoButton()
                        }
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
                        TextField("What happened?", text: $summary, axis: .vertical)
                            .lineLimit(4 ... 10)
                    }

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
            seedFields()
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
                Button(isWorking ? "Saving…" : "Save") { save() }
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

    private var projectName: String {
        guard let id = projectIds.first else { return "None" }
        return reference?.projects.first { $0.id == id }?.title ?? "None"
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

    private func seedFields() {
        guard title.isEmpty else { return }
        title = activity.title
        typeSlug = activity.type.slug
        points = InboxView.points(activity.cpdPoints)
        startsOn = activity.startsOn ?? ""
        endsOn = activity.endsOn ?? ""
        organisation = activity.organisation ?? ""
        summary = activity.details ?? ""
        reflection = (activity.reflection ?? [:]).compactMapValues { $0 }
        categorySlugs = Set(activity.categories.map(\.slug))
        domainCodes = Set(activity.domains.map(\.code))
        projectIds = Set(activity.projects.map(\.id))
    }

    private func save() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let payload = UpdateActivityPayload(
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
                    attributeCodes: nil,
                    projectIds: Array(projectIds)
                )
                let updated = try await session.api.updateActivity(id: activity.id, payload: payload)
                onSaved(updated)
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
