import Foundation

public struct WatchSelection: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var keywords: [String]
    public var courseID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        keywords: [String],
        courseID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.courseID = courseID
    }
}

public struct WatcherSettings: Codable, Equatable, Sendable {
    public var account = ""
    public var selectedClasses: [WatchSelection] = []
    public var monitoringEnabled = true
    public var registrationWindowOnly = true
    public var activeFromDay = 19
    public var intervalSeconds = 300
    public var notifyOnFirstAvailable = true
    public var launchAtLogin = false
    public var autoRegistrationEnabled = false
    public var autoRegistrationAttemptedCourseID: String?
    public var autoRegistrationAttemptedAt: Date?
    public var autoRegistrationResult: String?

    public static let `default` = WatcherSettings()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case account, selectedClasses, monitoringEnabled, registrationWindowOnly
        case activeFromDay, intervalSeconds, notifyOnFirstAvailable, launchAtLogin
        case autoRegistrationEnabled, autoRegistrationAttemptedCourseID
        case autoRegistrationAttemptedAt, autoRegistrationResult
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        account = try values.decodeIfPresent(String.self, forKey: .account) ?? ""
        selectedClasses = try values.decodeIfPresent(
            [WatchSelection].self,
            forKey: .selectedClasses
        ) ?? []
        monitoringEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .monitoringEnabled
        ) ?? true
        registrationWindowOnly = try values.decodeIfPresent(
            Bool.self,
            forKey: .registrationWindowOnly
        ) ?? true
        activeFromDay = try values.decodeIfPresent(Int.self, forKey: .activeFromDay) ?? 19
        intervalSeconds = try values.decodeIfPresent(
            Int.self,
            forKey: .intervalSeconds
        ) ?? 300
        notifyOnFirstAvailable = try values.decodeIfPresent(
            Bool.self,
            forKey: .notifyOnFirstAvailable
        ) ?? true
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        autoRegistrationEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .autoRegistrationEnabled
        ) ?? false
        autoRegistrationAttemptedCourseID = try values.decodeIfPresent(
            String.self,
            forKey: .autoRegistrationAttemptedCourseID
        )
        autoRegistrationAttemptedAt = try values.decodeIfPresent(
            Date.self,
            forKey: .autoRegistrationAttemptedAt
        )
        autoRegistrationResult = try values.decodeIfPresent(
            String.self,
            forKey: .autoRegistrationResult
        )
    }
}

public struct CourseRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let cells: [String]
    public let actions: [String]
    public let hrefs: [String]

    public init(id: String, cells: [String], actions: [String], hrefs: [String]) {
        self.id = id
        self.cells = cells
        self.actions = actions
        self.hrefs = hrefs
    }

    public var text: String {
        cells.joined(separator: " | ")
    }

    public var searchable: String {
        ([text] + actions + hrefs)
            .joined(separator: " | ")
            .normalizedWhitespace
    }

    public var displayTitle: String {
        let useful = cells.filter { !$0.isEmpty }
        let count = id.hasPrefix("lecture:") ? 3 : 4
        return useful.prefix(count).joined(separator: " · ")
    }

    public var capacityText: String? {
        guard id.hasPrefix("lecture:"), cells.count > 3 else { return nil }
        return cells.dropFirst(3).joined(separator: " · ")
    }
}

public enum CourseAvailability: Equatable, Sendable {
    case available(seats: Int?, reason: String)
    case unavailable(reason: String)
    case unknown(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var shortText: String {
        switch self {
        case let .available(seats, reason):
            return seats.map { "자리 \($0)명" } ?? reason
        case let .unavailable(reason), let .unknown(reason):
            return reason
        }
    }

    public func isNewVacancy(comparedTo previouslyAvailable: Bool?) -> Bool {
        isAvailable && previouslyAvailable != true
    }
}

public enum RegistrationAttemptResult: Equatable, Sendable {
    case noLongerAvailable
    case submittedConfirmed
    case submittedUnverified

    public var finalRequestWasSent: Bool {
        switch self {
        case .noLongerAvailable: return false
        case .submittedConfirmed, .submittedUnverified: return true
        }
    }
}

public struct SelectionStatus: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let availability: CourseAvailability

    public init(id: UUID, name: String, availability: CourseAvailability) {
        self.id = id
        self.name = name
        self.availability = availability
    }
}

public enum ConnectionState: Equatable, Sendable {
    case idle
    case checking
    case connected
    case failed(String)

    public var label: String {
        switch self {
        case .idle: return "대기 중"
        case .checking: return "확인 중"
        case .connected: return "연결됨"
        case .failed: return "오류"
        }
    }
}

extension String {
    public var normalizedWhitespace: String {
        replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
