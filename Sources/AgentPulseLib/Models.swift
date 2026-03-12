import Foundation

// MARK: - JSON Models

public struct Session: Codable {
    public var directory: String?
    public var name: String
    public var status: String
    public var updatedAt: TimeInterval
    public var startedAt: TimeInterval?
    public var summary: String?
    public var sequenceNum: Int?
    public var pid: Int?
    public var symbol: String?
    public var activity: String?
    public var tty: String?
    public var lastMessage: String?

    public enum CodingKeys: String, CodingKey {
        case directory
        case name
        case status
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case summary
        case sequenceNum = "sequence_num"
        case pid
        case symbol
        case activity
        case tty
        case lastMessage = "last_message"
    }

    public init(directory: String? = nil, name: String, status: String, updatedAt: TimeInterval, startedAt: TimeInterval? = nil, summary: String? = nil, sequenceNum: Int? = nil, pid: Int? = nil, symbol: String? = nil, activity: String? = nil, tty: String? = nil, lastMessage: String? = nil) {
        self.directory = directory
        self.name = name
        self.status = status
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.summary = summary
        self.sequenceNum = sequenceNum
        self.pid = pid
        self.symbol = symbol
        self.activity = activity
        self.tty = tty
        self.lastMessage = lastMessage
    }
}

public struct Settings: Codable {
    public var soundEnabled: Bool
    public var notificationsEnabled: Bool
    public var waitingSound: String
    public var doneSound: String
    public var firstRunComplete: Bool
    public var pinnedSessions: [String]
    public var maxVisibleSessions: Int
    public var autoClearAfterMinutes: Int

    public static let availableSounds = ["Glass", "Purr", "Tink", "Pop", "Bottle", "Ping", "Sosumi"]

    public enum CodingKeys: String, CodingKey {
        case soundEnabled = "sound_enabled"
        case notificationsEnabled = "notifications_enabled"
        case waitingSound = "waiting_sound"
        case doneSound = "done_sound"
        case firstRunComplete = "first_run_complete"
        case pinnedSessions = "pinned_sessions"
        case maxVisibleSessions = "max_visible_sessions"
        case autoClearAfterMinutes = "auto_clear_after_minutes"
    }

    public init(soundEnabled: Bool = true, notificationsEnabled: Bool = true, waitingSound: String = "Purr", doneSound: String = "Glass", firstRunComplete: Bool = false, pinnedSessions: [String] = [], maxVisibleSessions: Int = 5, autoClearAfterMinutes: Int = 5) {
        self.soundEnabled = soundEnabled
        self.notificationsEnabled = notificationsEnabled
        self.waitingSound = waitingSound
        self.doneSound = doneSound
        self.firstRunComplete = firstRunComplete
        self.pinnedSessions = pinnedSessions
        self.maxVisibleSessions = maxVisibleSessions
        self.autoClearAfterMinutes = autoClearAfterMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        waitingSound = try container.decodeIfPresent(String.self, forKey: .waitingSound) ?? "Purr"
        doneSound = try container.decodeIfPresent(String.self, forKey: .doneSound) ?? "Glass"
        firstRunComplete = try container.decodeIfPresent(Bool.self, forKey: .firstRunComplete) ?? false
        pinnedSessions = try container.decodeIfPresent([String].self, forKey: .pinnedSessions) ?? []
        maxVisibleSessions = try container.decodeIfPresent(Int.self, forKey: .maxVisibleSessions) ?? 5
        autoClearAfterMinutes = try container.decodeIfPresent(Int.self, forKey: .autoClearAfterMinutes) ?? 5
    }
}

public struct SymbolPool: Codable {
    public static let defaultSymbols: [String] = [
        "◆", "●", "▲", "■", "★",
        "♠", "♣", "♥", "♦",
        "✚", "✦", "☀", "☽", "➤", "♪", "♫",
    ]

    public var available: [String]
    public var assigned: [String: String]

    public init(available: [String] = SymbolPool.defaultSymbols, assigned: [String: String] = [:]) {
        self.available = available
        self.assigned = assigned
    }
}

public struct StatusFile: Codable {
    public var sessions: [String: Session]
    public var settings: Settings
    public var symbolPool: SymbolPool

    public enum CodingKeys: String, CodingKey {
        case sessions
        case settings
        case symbolPool = "symbol_pool"
    }

    public init() {
        self.sessions = [:]
        self.settings = Settings()
        self.symbolPool = SymbolPool()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([String: Session].self, forKey: .sessions) ?? [:]
        settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        symbolPool = try container.decodeIfPresent(SymbolPool.self, forKey: .symbolPool) ?? SymbolPool()
    }
}

public struct HistoryEntry: Codable, Equatable {
    public var symbol: String
    public var directory: String
    public var summary: String
    public var sessionId: String
    public var startedAt: TimeInterval
    public var endedAt: TimeInterval
    public var lastMessage: String?

    public enum CodingKeys: String, CodingKey {
        case symbol, directory, summary
        case sessionId = "session_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case lastMessage = "last_message"
    }

    public init(symbol: String, directory: String, summary: String, sessionId: String, startedAt: TimeInterval, endedAt: TimeInterval, lastMessage: String? = nil) {
        self.symbol = symbol
        self.directory = directory
        self.summary = summary
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastMessage = lastMessage
    }
}
