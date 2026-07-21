import SwiftUI

/// The non-drag door into merging, mirroring the web's picker: search your
/// timeline and inbox, tick what belongs together, continue to the merge
/// sheet. Selecting exactly one already-merged entry absorbs everything
/// into it; two merged entries are refused (split one apart first).
struct MergePickerSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Title of the item/activity the picker was opened from.
    let baseLabel: String
    /// The base inbox item id (when opened from the review sheet).
    var baseItemId: Int?
    /// The base activity id (when opened from an activity).
    var baseActivityId: Int?
    /// The base is itself a merged entry — everything absorbs into it.
    var baseIsMerged = false
    /// Appraisal period to offer candidates from (nil = current).
    var periodId: Int?
    var onConfirm: (MergeSeed) -> Void

    @State private var candidates: MergeCandidates?
    @State private var loadError: String?
    @State private var query = ""
    @State private var activityIds: Set<Int> = []
    @State private var itemIds: Set<Int> = []

    private func matches(_ title: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || title.localizedCaseInsensitiveContains(needle)
    }

    private var activities: [MergeCandidates.ActivityCandidate] {
        (candidates?.activities ?? []).filter { $0.id != baseActivityId && matches($0.title) }
    }

    private var items: [MergeCandidates.InboxCandidate] {
        (candidates?.inboxItems ?? []).filter { $0.id != baseItemId && matches($0.title) }
    }

    private var selectedParents: [MergeCandidates.ActivityCandidate] {
        (candidates?.activities ?? []).filter { $0.merged == true && activityIds.contains($0.id) }
    }

    private var tooManyParents: Bool {
        selectedParents.count + (baseIsMerged ? 1 : 0) > 1
    }

    private var total: Int { activityIds.count + itemIds.count }

    var body: some View {
        VStack(spacing: 12) {
            Capsule()
                .fill(PaperInk.ink.opacity(0.2))
                .frame(width: 40, height: 4)
                .padding(.top, 10)

            HStack {
                Text("Merge “\(baseLabel)” with…")
                    .display(20)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 16)

            TextField("Search your timeline and inbox…", text: $query)
                .font(PaperInk.sans(14))
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(PaperInk.ink.opacity(0.35), lineWidth: 1.5))
                .padding(.horizontal, 16)

            if let loadError {
                Text(loadError)
                    .font(PaperInk.sans(12, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }

            if candidates == nil && loadError == nil {
                Spacer()
                ProgressView("Looking through your evidence…")
                    .font(PaperInk.sans(13))
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !activities.isEmpty {
                            section("On your timeline") {
                                ForEach(activities) { candidate in
                                    candidateRow(
                                        title: candidate.title,
                                        meta: [candidate.startsOn, candidate.cpdPoints.map { "\(InboxView.points($0)) pts" }]
                                            .compactMap(\.self).joined(separator: " · "),
                                        merged: candidate.merged == true,
                                        selected: activityIds.contains(candidate.id)
                                    ) { toggle(&activityIds, candidate.id) }
                                }
                            }
                        }

                        if !items.isEmpty {
                            section("In your inbox") {
                                ForEach(items) { candidate in
                                    candidateRow(
                                        title: candidate.title,
                                        meta: [candidate.sourceLabel, candidate.startsOn]
                                            .compactMap(\.self).joined(separator: " · "),
                                        merged: false,
                                        selected: itemIds.contains(candidate.id)
                                    ) { toggle(&itemIds, candidate.id) }
                                }
                            }
                        }

                        if activities.isEmpty && items.isEmpty {
                            Text(query.isEmpty
                                ? "Nothing else to merge with."
                                : "Nothing matches your search.")
                                .font(PaperInk.sans(13))
                                .foregroundStyle(PaperInk.stone500)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }

            footer
        }
        .background(.white)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task {
            do {
                candidates = try await session.api.mergeCandidates(periodId: periodId)
            } catch where !error.isCancellation {
                loadError = error.localizedDescription
            } catch {}
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if tooManyParents {
                Text("two merged entries can't merge — split one first")
                    .font(PaperInk.hand(17))
                    .foregroundStyle(.red)
                    .tilt(-1)
            }
            HStack(spacing: 14) {
                Button("Continue — merge \(total + 1)") { confirm() }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .disabled(total == 0 || tooManyParents)

                Spacer()

                Button("Cancel") { dismiss() }
                    .font(PaperInk.sans(14, weight: .bold))
                    .foregroundStyle(PaperInk.stone600)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private func confirm() {
        let target: Int? = baseIsMerged
            ? baseActivityId
            : selectedParents.first?.id

        var mergedActivityIds = Array(activityIds.filter { $0 != target })
        if let baseActivityId, baseActivityId != target {
            mergedActivityIds.append(baseActivityId)
        }

        var mergedItemIds = Array(itemIds)
        if let baseItemId {
            mergedItemIds.append(baseItemId)
        }

        let seed = MergeSeed(
            activityIds: mergedActivityIds,
            inboxItemIds: mergedItemIds,
            intoActivityId: target
        )
        dismiss()
        onConfirm(seed)
    }

    private func section(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            content()
        }
    }

    private func candidateRow(title: String, meta: String, merged: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? PaperInk.brand : PaperInk.stone400)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(PaperInk.sans(13, weight: .semibold))
                            .foregroundStyle(PaperInk.ink)
                            .lineLimit(1)
                        if merged {
                            Image(systemName: "square.stack")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(PaperInk.brandDark)
                        }
                    }
                    if !meta.isEmpty {
                        Text(meta)
                            .font(PaperInk.sans(11))
                            .foregroundStyle(PaperInk.stone500)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}
