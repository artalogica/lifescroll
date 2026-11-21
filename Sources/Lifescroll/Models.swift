import Foundation

enum TaskStatus: String, CaseIterable, Identifiable {
  case open, done, dismissed
  var id: String { rawValue }

  var label: String {
    switch self {
    case .open: return "Open"
    case .done: return "Done"
    case .dismissed: return "Never"
    }
  }
}

struct TaskItem: Identifiable, Equatable {
  var id: String = UUID().uuidString
  var title: String
  var detail: String = ""
  /// The card's one line: why this, why now.
  var why: String = ""
  var url: String = ""
  var sourceApp: String = ""
  var bundleID: String = ""
  var deadline: Date? = nil
  var waitingPerson: String = ""
  /// 0...1, how much it costs to not do this, ignoring how close the deadline is.
  var importance: Double = 0.5
  /// Elo-style rating moved by the "which matters more?" picks.
  var rating: Double = 1000
  var estMinutes: Int = 0
  var firstSeen: Date = Date()
  var lastSeen: Date = Date()
  var seenCount: Int = 1
  var status: TaskStatus = .open
  var snoozeUntil: Date? = nil
  /// "inferred" from the screen, or "manual".
  var origin: String = "inferred"
  /// Id of the project entity this task belongs to, or empty.
  var projectID: String = ""

  /// Only http and https links are ever opened; the link text comes from a model reading the screen.
  var webURL: URL? {
    guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
      scheme == "http" || scheme == "https", parsed.host != nil
    else { return nil }
    return parsed
  }

  var hasDestination: Bool { webURL != nil || !bundleID.isEmpty }

  func isSnoozed(at now: Date) -> Bool {
    guard let until = snoozeUntil else { return false }
    return until > now
  }
}

enum Mode: String, CaseIterable, Identifiable {
  case dopamine, balanced, lockIn
  var id: String { rawValue }

  var label: String {
    switch self {
    case .dopamine: return "Pure dopamine"
    case .balanced: return "Balanced"
    case .lockIn: return "Lock in"
    }
  }

  /// How long on a distracting app before a nudge. Nil means never interrupt.
  var nudgeAfter: TimeInterval? {
    switch self {
    case .dopamine: return nil
    case .balanced: return 20 * 60
    case .lockIn: return 5 * 60
    }
  }

  var explanation: String {
    switch self {
    case .dopamine: return "Never interrupts. The feed is mostly suggestions."
    case .balanced: return "Nudges after 20 minutes of scrolling. A suggestion every few cards."
    case .lockIn: return "Nudges after 5 minutes of scrolling. Tasks only."
    }
  }
}

struct ActivitySample: Equatable {
  var app = ""
  var bundleID = ""
  var title = ""
  var url = ""
}

struct FrameRecord: Equatable {
  let id: Int64
  let ts: Date
  let path: String
  let app: String
  let title: String
}

struct ActivitySpan {
  let app: String
  let title: String
  let seconds: Int
}

struct UsageRow: Identifiable, Equatable {
  let model: String
  let inputTokens: Int
  let outputTokens: Int
  var id: String { model }

  /// Dollars at list price for prompts under 100K tokens.
  var cost: Double {
    let rates: (input: Double, output: Double)
    switch model {
    case ClaudeClient.haiku: rates = (0.10, 0.50)
    case ClaudeClient.sonnet: rates = (2.00, 10.00)
    default: rates = (0, 0)
    }
    return Double(inputTokens) / 1_000_000 * rates.input
      + Double(outputTokens) / 1_000_000 * rates.output
  }
}

// MARK: - What the reading model reports

struct Extraction: Codable, Equatable {
  struct Activity: Codable, Equatable {
    var app: String
    var title: String
    var description: String
    var category: String
  }

  struct Commitment: Codable, Equatable {
    var title: String
    var detail: String
    var evidence: String
    var sourceApp: String
    var url: String
    var deadline: String
    var waitingPerson: String
    var confidence: String
    var isUsersOwn: Bool
    /// Name of the project it belongs to. Optional so readings stored before this field existed still load.
    var project: String?
  }

  /// A project, person, document or topic the reading model saw the user working with.
  struct Mention: Codable, Equatable {
    var name: String
    var kind: String
    var context: String
  }

  struct Completion: Codable, Equatable {
    var description: String
    var evidence: String
  }

  struct ContentSeen: Codable, Equatable {
    var title: String
    var source: String
    var url: String
    var kind: String
    var topic: String
  }

  var summary: String
  var activities: [Activity]
  var commitments: [Commitment]
  var completions: [Completion]
  var content: [ContentSeen]
  /// Optional for the same reason as `Commitment.project`.
  var entities: [Mention]?

  /// What is worth sending to the merging model.
  var actionableCommitments: [Commitment] {
    commitments.filter { $0.isUsersOwn && $0.confidence != "low" }
  }
}

// MARK: - What the merging model decides

struct MergeResult: Codable, Equatable {
  struct Operation: Codable, Equatable {
    var op: String
    var taskId: String
    var title: String
    var detail: String
    var why: String
    var deadline: String
    var waitingPerson: String
    var url: String
    var sourceApp: String
    var importance: Double
    var estMinutes: Int
    var reason: String
    var project: String?
  }

  var operations: [Operation]
}

// MARK: - The index of projects, people, documents and topics

enum EntityKind: String, CaseIterable, Identifiable {
  case project, person, document, topic
  var id: String { rawValue }

  var plural: String {
    switch self {
    case .project: return "Projects"
    case .person: return "People"
    case .document: return "Documents"
    case .topic: return "Topics"
    }
  }

  var icon: String {
    switch self {
    case .project: return "folder"
    case .person: return "person"
    case .document: return "doc.text"
    case .topic: return "lightbulb"
    }
  }
}

struct Entity: Identifiable, Equatable {
  var id: String = UUID().uuidString
  var kind: EntityKind
  var name: String
  /// Other names seen on screen for the same thing.
  var aliases: [String] = []
  var summary: String = ""
  var firstSeen: Date = Date()
  var lastSeen: Date = Date()
  var seenCount: Int = 0
  /// Names judged to be noise are kept, marked ignored, so they are not asked about again.
  var ignored: Bool = false
}

struct EntitySighting: Equatable {
  let ts: Date
  let context: String
}

struct EntityLink: Identifiable, Equatable {
  let entity: Entity
  /// How many readings both appeared in.
  let weight: Int
  var id: String { entity.id }
}

struct EntityDetail {
  let entity: Entity
  let links: [EntityLink]
  let sightings: [EntitySighting]
  let tasks: [TaskItem]
}

/// What the merging model decides about names that are not in the index yet.
struct EntityDecisions: Codable, Equatable {
  struct Decision: Codable, Equatable {
    var mention: String
    var kind: String
    var decision: String
    var entityId: String
    var name: String
    var summary: String
    var reason: String
  }

  var decisions: [Decision]
}

// MARK: - Suggestions (the fun half of the feed)

struct Recommendation: Identifiable, Equatable {
  var id: String = UUID().uuidString
  var title: String
  var url: String
  /// Where it was found: "arXiv" or "Hacker News".
  var source: String
  /// paper, article, video or discussion.
  var kind: String
  /// One line on why the user would like it.
  var why: String
  /// "related" to current interests, or "explore" for something outside them.
  var bucket: String
  var estMinutes: Int = 0
  var created: Date = Date()
  /// new, opened, dismissed or expired.
  var status: String = "new"

  /// Links come from the search services' own results and are still checked before opening.
  var webURL: URL? {
    guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
      scheme == "http" || scheme == "https", parsed.host != nil
    else { return nil }
    return parsed
  }

  var icon: String {
    switch kind {
    case "paper": return "doc.text"
    case "video": return "play.rectangle"
    case "discussion": return "bubble.left.and.bubble.right"
    default: return "newspaper"
    }
  }
}

/// One card in the feed: something to do, or something to enjoy.
enum FeedItem: Identifiable, Equatable {
  case task(TaskItem)
  case suggestion(Recommendation)

  var id: String {
    switch self {
    case .task(let task): return "task-\(task.id)"
    case .suggestion(let suggestion): return "suggestion-\(suggestion.id)"
    }
  }
}

/// Something a search turned up, before Sonnet has decided whether it is worth showing.
struct Candidate: Equatable {
  var id: String = ""
  var title: String
  var url: String
  var source: String
  var snippet: String = ""
  var published: Date? = nil
  var points: Int? = nil
  var bucket: String = "related"
}

/// What the user has been watching and reading, as recorded by the reading step.
struct InterestSignal: Equatable {
  let title: String
  let topic: String
  let kind: String
  let source: String
}

struct SearchPlan: Codable, Equatable {
  var arxivQueries: [String]
  var hnQueries: [String]
  var interestsSummary: String
}

struct PickResult: Codable, Equatable {
  struct Pick: Codable, Equatable {
    var candidateId: String
    var why: String
    var kind: String
    var bucket: String
    var estMinutes: Int
  }

  var picks: [Pick]
}

enum JSONCoding {
  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()
}
