import Foundation

// Explicit CodingKeys throughout (rather than .convertFromSnakeCase) because
// the strategy also rewrites *dictionary* keys, which corrupts maps like
// reflection_draft whose keys are server-defined slugs.

// MARK: - Auth

struct UserPayload: Codable, Equatable {
    var id: Int
    var name: String
    var email: String
    var onboarded: Bool
    var profession: Profession?
    var dumpAddress: String?
    var period: AppraisalPeriod?
    /// "ask" | "always" | "never" — nil (older cached payloads) means "ask".
    var attachmentRetention: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, onboarded, profession, period
        case dumpAddress = "dump_address"
        case attachmentRetention = "attachment_retention"
    }

    var asksAboutAttachments: Bool {
        (attachmentRetention ?? "ask") == "ask"
    }

    struct Profession: Codable, Equatable {
        var id: Int
        var slug: String
        var name: String
    }

    var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

struct AppraisalPeriod: Codable, Equatable, Identifiable {
    var id: Int
    var label: String
    var startsOn: String?
    var endsOn: String?
    var isCurrent: Bool?

    enum CodingKeys: String, CodingKey {
        case id, label
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case isCurrent = "is_current"
    }
}

struct TokenResponse: Codable {
    var token: String
    var user: UserPayload
}

// MARK: - Inbox

enum InboxStatus: String, Codable {
    case pending, analysing, ready, approved, dismissed, failed
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InboxStatus(rawValue: raw) ?? .unknown
    }

    var isBusy: Bool { self == .pending || self == .analysing }
}

struct InboxItem: Codable, Identifiable {
    var id: Int
    var source: String
    var sourceLabel: String
    var status: InboxStatus
    var rawPayload: [String: JSONValue]?
    var aiAnalysis: AiAnalysis?
    var aiWarnings: AiWarnings?
    var failureReason: String?
    var createdAt: Date
    var attachments: [AttachmentRef]
    /// Server gate: flagged patient info still held in a file or typed text.
    /// Approval then requires an explicit acknowledgement (`pii_ack`).
    var piiGate: Bool?

    enum CodingKeys: String, CodingKey {
        case id, source, status, attachments
        case sourceLabel = "source_label"
        case rawPayload = "raw_payload"
        case aiAnalysis = "ai_analysis"
        case aiWarnings = "ai_warnings"
        case failureReason = "failure_reason"
        case createdAt = "created_at"
        case piiGate = "pii_gate"
    }

    // Lenient decoding: PHP encodes empty maps as JSON arrays ([] not {}),
    // and the AI's JSON is loose — a malformed optional field should never
    // sink the whole inbox.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        source = try container.decode(String.self, forKey: .source)
        sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
        status = try container.decode(InboxStatus.self, forKey: .status)
        rawPayload = try? container.decode([String: JSONValue].self, forKey: .rawPayload)
        aiAnalysis = try? container.decode(AiAnalysis.self, forKey: .aiAnalysis)
        aiWarnings = try? container.decode(AiWarnings.self, forKey: .aiWarnings)
        failureReason = try? container.decode(String.self, forKey: .failureReason)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        attachments = (try? container.decode([AttachmentRef].self, forKey: .attachments)) ?? []
        piiGate = try? container.decode(Bool.self, forKey: .piiGate)
    }

    /// Best display title for a tray row.
    var displayTitle: String {
        if let title = aiAnalysis?.title, !title.isEmpty { return title }
        if case .string(let title)? = rawPayload?["title"], !title.isEmpty { return title }
        if case .string(let subject)? = rawPayload?["subject"], !subject.isEmpty { return subject }
        if case .string(let url)? = rawPayload?["url"], !url.isEmpty { return url }
        return sourceLabel
    }

    /// SF Symbol for the muted source icon.
    var sourceSymbol: String {
        switch source {
        case "voice_note": "mic.fill"
        case "email", "email_attachment": "envelope"
        case "link", "article": "link"
        case "upload": "photo"
        case "calendar": "calendar"
        case "recurring": "repeat"
        default: "square.and.pencil"
        }
    }
}

struct AttachmentRef: Codable, Identifiable {
    var id: Int
    var name: String?
    var mimeType: String?
    /// Absent when the file has been purged from storage.
    var url: String?
    var purged: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, url, purged
        case mimeType = "mime_type"
    }
}

/// The InboxAnalystAgent's extraction — every field optional so a partial
/// or failed analysis still decodes.
struct AiAnalysis: Codable {
    var title: String?
    var activityTypeSlug: String?
    var startsOn: String?
    var endsOn: String?
    var organisation: String?
    var cpdPoints: Double?
    var summary: String?
    var suggestedLearningPoints: [String]?
    var reflectionDraft: [String: String?]?
    var categorySlugs: [String]?
    var domainCodes: [String]?
    var attributeCodes: [String]?
    var suggestedProjectIds: [Int]?
    var possibleDuplicateActivityIds: [Int]?
    var matchedRecurrenceId: Int?
    var confidence: Double?
    var piiFlags: [PiiFlag]?
    var missingEvidence: [String]?

    enum CodingKeys: String, CodingKey {
        case title, organisation, summary, confidence
        case activityTypeSlug = "activity_type_slug"
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case cpdPoints = "cpd_points"
        case suggestedLearningPoints = "suggested_learning_points"
        case reflectionDraft = "reflection_draft"
        case categorySlugs = "category_slugs"
        case domainCodes = "domain_codes"
        case attributeCodes = "attribute_codes"
        case suggestedProjectIds = "suggested_project_ids"
        case possibleDuplicateActivityIds = "possible_duplicate_activity_ids"
        case matchedRecurrenceId = "matched_recurrence_id"
        case piiFlags = "pii_flags"
        case missingEvidence = "missing_evidence"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decode(String.self, forKey: .title)
        activityTypeSlug = try? container.decode(String.self, forKey: .activityTypeSlug)
        startsOn = try? container.decode(String.self, forKey: .startsOn)
        endsOn = try? container.decode(String.self, forKey: .endsOn)
        organisation = try? container.decode(String.self, forKey: .organisation)
        cpdPoints = Self.flexibleNumber(container, .cpdPoints)
        summary = try? container.decode(String.self, forKey: .summary)
        suggestedLearningPoints = try? container.decode([String].self, forKey: .suggestedLearningPoints)
        reflectionDraft = try? container.decode([String: String?].self, forKey: .reflectionDraft)
        categorySlugs = try? container.decode([String].self, forKey: .categorySlugs)
        domainCodes = try? container.decode([String].self, forKey: .domainCodes)
        attributeCodes = try? container.decode([String].self, forKey: .attributeCodes)
        suggestedProjectIds = try? container.decode([Int].self, forKey: .suggestedProjectIds)
        possibleDuplicateActivityIds = try? container.decode([Int].self, forKey: .possibleDuplicateActivityIds)
        matchedRecurrenceId = try? container.decode(Int.self, forKey: .matchedRecurrenceId)
        confidence = Self.flexibleNumber(container, .confidence)
        piiFlags = try? container.decode([PiiFlag].self, forKey: .piiFlags)
        missingEvidence = try? container.decode([String].self, forKey: .missingEvidence)
    }

    /// The model sometimes returns numbers as strings ("1.5").
    private static func flexibleNumber(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let text = try? container.decode(String.self, forKey: key) { return Double(text) }
        return nil
    }

    struct PiiFlag: Codable {
        var type: String
        var excerpt: String
        var severity: String
    }
}

/// Server-side warnings surfaced alongside the analysis.
struct AiWarnings: Codable {
    var piiFlags: [AiAnalysis.PiiFlag]?
    var missingEvidence: [String]?
    var possibleDuplicateActivityIds: [Int]?
    var possibleDuplicateInboxItemIds: [Int]?

    enum CodingKeys: String, CodingKey {
        case piiFlags = "pii_flags"
        case missingEvidence = "missing_evidence"
        case possibleDuplicateActivityIds = "possible_duplicate_activity_ids"
        case possibleDuplicateInboxItemIds = "possible_duplicate_inbox_item_ids"
    }
}

// MARK: - Activities (read-only timeline)

struct ActivitySummary: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var startsOn: String?
    var endsOn: String?
    var cpdPoints: Double
    var organisation: String?
    var type: ActivityTypeRef
    var domains: [String]
    var projects: [String]

    enum CodingKeys: String, CodingKey {
        case id, title, organisation, type, domains, projects
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case cpdPoints = "cpd_points"
    }
}

struct ActivityDetail: Codable, Identifiable {
    var id: Int
    var title: String
    var startsOn: String?
    var endsOn: String?
    var cpdPoints: Double
    var organisation: String?
    var details: String?
    var reflection: [String: String?]?
    var type: ActivityTypeRef
    var categories: [SlugName]
    var domains: [CodeName]
    var projects: [ProjectRef]
    var attachments: [AttachmentRef]

    enum CodingKeys: String, CodingKey {
        case id, title, organisation, details, reflection, type, categories, domains, projects, attachments
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case cpdPoints = "cpd_points"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        startsOn = try? container.decode(String.self, forKey: .startsOn)
        endsOn = try? container.decode(String.self, forKey: .endsOn)
        cpdPoints = (try? container.decode(Double.self, forKey: .cpdPoints)) ?? 0
        organisation = try? container.decode(String.self, forKey: .organisation)
        details = try? container.decode(String.self, forKey: .details)
        reflection = try? container.decode([String: String?].self, forKey: .reflection)
        type = try container.decode(ActivityTypeRef.self, forKey: .type)
        categories = (try? container.decode([SlugName].self, forKey: .categories)) ?? []
        domains = (try? container.decode([CodeName].self, forKey: .domains)) ?? []
        projects = (try? container.decode([ProjectRef].self, forKey: .projects)) ?? []
        attachments = (try? container.decode([AttachmentRef].self, forKey: .attachments)) ?? []
    }
}

struct ActivityTypeRef: Codable, Hashable {
    var slug: String
    var name: String
    var color: String?
    var icon: String?
}

struct SlugName: Codable, Hashable {
    var slug: String
    var name: String
}

struct CodeName: Codable, Hashable {
    var code: String
    var name: String
}

struct ProjectRef: Codable, Hashable, Identifiable {
    var id: Int
    var title: String
}

struct ActivitiesPage: Codable {
    var period: AppraisalPeriod?
    var activities: [ActivitySummary]
    var meta: Meta

    struct Meta: Codable {
        var currentPage: Int
        var lastPage: Int
        var total: Int

        enum CodingKeys: String, CodingKey {
            case total
            case currentPage = "current_page"
            case lastPage = "last_page"
        }
    }
}

// MARK: - Reference & stats

struct Reference: Codable {
    var activityTypes: [ActivityType]
    var categories: [Category]
    var domains: [Domain]
    var reflectionPrompts: [ReflectionPrompt]
    var projects: [Project]
    var periods: [AppraisalPeriod]

    enum CodingKeys: String, CodingKey {
        case categories, domains, projects, periods
        case activityTypes = "activity_types"
        case reflectionPrompts = "reflection_prompts"
    }

    struct ActivityType: Codable, Identifiable, Hashable {
        var id: Int
        var slug: String
        var name: String
        var color: String?
        var icon: String?
    }

    struct Category: Codable, Identifiable, Hashable {
        var id: Int
        var slug: String
        var name: String
    }

    struct Domain: Codable, Identifiable, Hashable {
        var id: Int
        var code: String
        var name: String
    }

    struct ReflectionPrompt: Codable, Identifiable, Hashable {
        var key: String
        var label: String
        var question: String
        var id: String { key }
    }

    struct Project: Codable, Identifiable, Hashable {
        var id: Int
        var title: String
        var kind: String?
    }
}

struct StatsResponse: Codable {
    var period: AppraisalPeriod?
    var stats: Stats

    struct Stats: Codable {
        var activities: Int
        var points: Double
        var awaiting: Int
    }
}

// MARK: - Approve payload

struct ApprovePayload: Codable {
    var title: String
    var activityTypeSlug: String
    var startsOn: String?
    var endsOn: String?
    var organisation: String?
    var cpdPoints: Double
    var summary: String?
    var reflectionDraft: [String: String]?
    var categorySlugs: [String]?
    var domainCodes: [String]?
    var attributeCodes: [String]?
    var projectIds: [Int]?
    var linkedActivityIds: [Int]?
    var keepAttachmentIds: [Int]?
    var piiAck: Bool?

    enum CodingKeys: String, CodingKey {
        case title, organisation, summary
        case activityTypeSlug = "activity_type_slug"
        case startsOn = "starts_on"
        case endsOn = "ends_on"
        case cpdPoints = "cpd_points"
        case reflectionDraft = "reflection_draft"
        case categorySlugs = "category_slugs"
        case domainCodes = "domain_codes"
        case attributeCodes = "attribute_codes"
        case projectIds = "project_ids"
        case linkedActivityIds = "linked_activity_ids"
        case keepAttachmentIds = "keep_attachment_ids"
        case piiAck = "pii_ack"
    }
}

// MARK: - JSON helpers

/// Minimal JSON value for loosely-typed payloads like `raw_payload`.
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
