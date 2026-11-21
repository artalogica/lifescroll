import Foundation

// The slow loop's thinking: Haiku 5.5 reads screenshots, Sonnet 5.5 decides what that means for the task list.

enum Schema {
  static func object(_ properties: [String: Any]) -> [String: Any] {
    [
      "type": "object", "properties": properties, "required": properties.keys.sorted(),
      "additionalProperties": false,
    ]
  }

  static func string(_ description: String) -> [String: Any] {
    ["type": "string", "description": description]
  }

  static func choice(_ values: [String], _ description: String) -> [String: Any] {
    ["type": "string", "enum": values, "description": description]
  }

  static func array(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }

  static let extraction: [String: Any] = object([
    "summary": string("One to three sentences on what the user was doing in this period."),
    "activities": array(
      object([
        "app": string("App name."),
        "title": string("Window or page title."),
        "description": string("What they were doing there, one sentence."),
        "category": choice(
          ["work", "study", "communication", "entertainment", "social", "browsing", "other"],
          "Best-fitting category."),
      ])),
    "commitments": array(
      object([
        "title": string("Short imperative title, e.g. 'Reply to Maya about Friday's demo'."),
        "detail": string("One or two sentences of context."),
        "evidence": string("What on screen shows this, quoted or described briefly."),
        "source_app": string("App it was seen in."),
        "url": string("Full http(s) link to it if one is visible in the address bar, otherwise empty."),
        "deadline": string("ISO 8601 date or date-time if a deadline is visible, otherwise empty."),
        "waiting_person": string("Name of whoever is waiting on the user, otherwise empty."),
        "confidence": choice(["low", "medium", "high"], "How sure you are this is a real open task."),
        "is_users_own": ["type": "boolean", "description": "True only if it is the user's own job to do."],
        "project": string("The project it belongs to, named exactly as in entities, otherwise empty."),
      ])),
    "entities": array(
      object([
        "name": string("The name as written on screen."),
        "kind": choice(["project", "person", "document", "topic"], "What kind of thing it is."),
        "context": string("One sentence on what the user was doing with it in this period."),
      ])),
    "completions": array(
      object([
        "description": string("What the user visibly finished."),
        "evidence": string("What on screen shows it was finished."),
      ])),
    "content": array(
      object([
        "title": string("Title of the video, paper, article or post."),
        "source": string("Site, channel or author."),
        "url": string("Link if visible, otherwise empty."),
        "kind": choice(["video", "paper", "article", "post", "other"], "Kind of content."),
        "topic": string("Topic in a few words."),
      ])),
  ])

  static let merge: [String: Any] = object([
    "operations": array(
      object([
        "op": choice(["create", "update", "complete", "ignore"], "What to do."),
        "task_id": string("Id of the existing task for update and complete, otherwise empty."),
        "title": string("Imperative, specific, under 60 characters."),
        "detail": string("One or two sentences of context for picking it up cold."),
        "why": string("The card's one line, addressed to the user as 'you', under 90 characters."),
        "deadline": string("ISO 8601 local date or date-time, or empty."),
        "waiting_person": string("Who is waiting, or empty."),
        "url": string("Link to the task if known, or empty."),
        "source_app": string("App the task lives in, or empty."),
        "importance": ["type": "number", "description": "0 to 1."],
        "est_minutes": ["type": "integer", "description": "Honest guess at minutes of work."],
        "reason": string("One short sentence on why you chose this operation."),
        "project": string("Name of the project the task belongs to, or empty."),
      ]))
  ])

  static let entities: [String: Any] = object([
    "decisions": array(
      object([
        "mention": string("The new name, copied exactly as given."),
        "kind": choice(["project", "person", "document", "topic"], "The kind it was given with."),
        "decision": choice(["same_as", "new", "ignore"], "What to do with the name."),
        "entity_id": string("Id of the existing entry for same_as, otherwise empty."),
        "name": string("Clean canonical name for a new entry, otherwise empty."),
        "summary": string("One sentence describing a new entry, otherwise empty."),
        "reason": string("One short sentence on why."),
      ]))
  ])
}

enum Prompts {
  static let extraction = """
    You are the reading step of Lifescroll, a personal menu bar app. It watches one person's Mac so it \
    can remind them of things they saw and meant to do, and learn what they like. You get a few \
    screenshots from about ten minutes of their screen, in time order, plus a log of which apps and \
    windows were in front.

    Report what you can actually see. Later steps trust your output without seeing the screenshots, so \
    do not guess at text you cannot read; leave fields empty instead.

    commitments: things on screen that ask the user themself to act and that they have not visibly done \
    yet. Examples: an assignment with a due date, a message or email asking them something, a form left \
    half-filled, a failing build they walked away from, anything saying "reply by" or "submit by". \
    Resolve a written deadline such as "Friday 5pm" to a date using the current time you are given. Set \
    is_users_own to false for someone else's job, generic advice in an article or video, adverts, and \
    to-do items in a document that is clearly not theirs. Use confidence "high" only when both the \
    request and the user's ownership are visible.

    completions: things the user visibly finished in these frames, such as a submission confirmation, \
    a sent reply, a merged pull request or a ticked-off item.

    content: videos, papers, articles or posts the user was actually watching or reading, not ones \
    merely listed in a feed.

    entities: the specific things this period's work was about, so the app can connect tasks and \
    activity over time. Use "project" for an ongoing piece of work such as a course assignment, a code \
    repository or an app being built; "person" for someone the user is talking or working with; \
    "document" for a particular file, doc, paper or page they worked in; "topic" for a subject they \
    were studying or reading about. Use each name as written on screen. Leave out the apps and \
    websites themselves, and people who only appear as authors or presenters of content. When a \
    commitment belongs to one of the projects, put that project's name in the commitment's project field.

    Never copy passwords, card numbers, keys or one-time codes into any field.
    """

  static let entities = """
    You maintain the index of projects, people, documents and topics for Lifescroll, a personal app \
    that watches one person's Mac to keep track of their work. A smaller model named things it saw on \
    their screen. Some of those names are not in the index yet. Decide what each new name is.

    You receive the existing entries and the new names, each with its kind and a sentence of context.

    For each new name choose one decision:
    - same_as: it is another name for an existing entry of the same kind. Typical cases are a course \
    code and the course written out, a repository folder and the project's title, a nickname and a \
    full name, or a file name and the document's title. Give that entry's id.
    - new: it is a distinct thing that matters to this person's work or life and is likely to come up \
    again. Give a clean canonical name and a one-sentence summary.
    - ignore: it is generic or a one-off, such as a website's or app's name, a public figure in a \
    video, a label from a user interface, or something too vague to be one thing.

    For people, index only those the user actually deals with, such as classmates, teammates, \
    instructors and friends, not authors of things they read.

    Be conservative. A small index of real things is more useful than a large one full of noise, and \
    a wrong same_as merges two things that are hard to separate later.
    """

  static let merge = """
    You keep one person's task list for Lifescroll, a menu bar app that shows them one card at a time \
    saying what to do next. A smaller model has read their screen and reported commitments it saw and \
    things they finished. Decide how each report changes the list.

    You receive the current time, the open tasks, tasks they recently finished or dismissed, the new \
    commitments, and the completions.

    For each new commitment choose one operation:
    - update: it is the same underlying task as an open one, even if worded differently or seen in a \
    different app. Give that task's id. Change title, detail or deadline only when the new sighting \
    adds information; otherwise repeat the existing values.
    - create: it is new and is the user's own to do.
    - ignore: it matches something they already finished or dismissed (dismissed means they said \
    "never", so do not bring it back), it is not really theirs, it is too vague to act on, or it is \
    trivial.

    For each completion that matches an open task, emit complete with that task's id. A completion \
    that matches nothing needs no operation.

    Fields:
    - title: imperative and specific, under 60 characters.
    - detail: one or two sentences someone would need to pick the task up cold.
    - why: the card's single line answering "why this, why now". Address the user as "you", keep it \
    under 90 characters, and make it concrete: a deadline, who is waiting, how long it has sat. Never \
    guilt-trip.
    - importance: 0 to 1, how much it would cost them not to do this, ignoring how close the deadline \
    is, because the app adds urgency itself. Around 0.9 for graded work or something blocking another \
    person, 0.5 for ordinary obligations, 0.2 for nice-to-haves.
    - est_minutes: your honest guess.
    - deadline: ISO 8601 local date or date-time, or empty.
    - project: the project the task belongs to, copied from the commitment's project or the open \
    task's existing project. Leave it empty when there is none; do not invent one.

    Be conservative about creating tasks. A wrong card costs the user's trust more than a missed one.
    """
}

struct AnalysisOutcome: Equatable {
  var windows = 0
  var tally = MergeTally()
  var error: String?
}

actor Analyzer {
  static let window: TimeInterval = 600
  static let maxFramesPerWindow = 12
  static let staleAfter: TimeInterval = 6 * 3600

  let store: Store
  let client: ClaudeClient
  let sampleInterval: TimeInterval

  init(store: Store, client: ClaudeClient = ClaudeClient(), sampleInterval: TimeInterval = 5) {
    self.store = store
    self.client = client
    self.sampleInterval = sampleInterval
  }

  static func timestamp(_ date: Date, format: String = "EEE yyyy-MM-dd HH:mm") -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    return formatter.string(from: date)
  }

  /// Splits pending frames into the next ten-minute window, or nil if it is not ready yet.
  static func nextWindow(pending: [FrameRecord], now: Date, force: Bool) -> [FrameRecord]? {
    guard let first = pending.first else { return nil }
    let end = first.ts.addingTimeInterval(window)
    if !force && now < end { return nil }
    return pending.filter { $0.ts <= end }
  }

  /// Reads up to three windows of screenshots, then merges anything found into the task list.
  func run(now: Date, force: Bool) async -> AnalysisOutcome {
    var outcome = AnalysisOutcome()
    do {
      while outcome.windows < 3 {
        let pending = store.pendingFrames()
        let stale = pending.filter { now.timeIntervalSince($0.ts) > Self.staleAfter }
        if !stale.isEmpty { store.markAnalyzed(stale.map(\.id)) }
        let fresh = pending.filter { now.timeIntervalSince($0.ts) <= Self.staleAfter }
        guard let batch = Self.nextWindow(pending: fresh, now: now, force: force) else { break }
        try await read(batch, now: now)
        store.markAnalyzed(batch.map(\.id))
        outcome.windows += 1
      }
      // Index entities before merging tasks, so a new task can link to a project named in the same reading.
      for observation in store.observationsNeedingEntities() {
        try await index(observation.extraction, observationID: observation.id, at: observation.end, now: now)
        store.markEntitiesDone(observation.id)
      }
      for observation in store.unmergedObservations() {
        let tally = try await merge(observation.extraction, now: now)
        store.markMerged(observation.id)
        outcome.tally.created += tally.created
        outcome.tally.updated += tally.updated
        outcome.tally.completed += tally.completed
        outcome.tally.ignored += tally.ignored
      }
    } catch {
      outcome.error = error.localizedDescription
    }
    return outcome
  }

  /// Builds the message content for one window: a caption and image per key frame, then the window log.
  nonisolated func extractionContent(for batch: [FrameRecord], now: Date) -> [[String: Any]] {
    var content: [[String: Any]] = []
    for frame in FrameMath.keyFrames(batch, max: Self.maxFramesPerWindow) {
      guard let data = FileManager.default.contents(atPath: frame.path) else { continue }
      content.append([
        "type": "text",
        "text": "Screenshot at \(Self.timestamp(frame.ts, format: "HH:mm:ss")), front window: \(frame.app) — \(frame.title)",
      ])
      content.append([
        "type": "image",
        "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()],
      ])
    }
    guard !content.isEmpty, let first = batch.first, let last = batch.last else { return [] }

    let spans = store.activitySummary(from: first.ts, to: last.ts, sampleInterval: sampleInterval)
    let log = spans.map { "- \($0.app) — \($0.title): \($0.seconds)s" }.joined(separator: "\n")
    content.append([
      "type": "text",
      "text": """
        Current local time: \(Self.timestamp(now)) (\(TimeZone.current.identifier)).
        This period ran from \(Self.timestamp(first.ts, format: "HH:mm")) to \(Self.timestamp(last.ts, format: "HH:mm")).

        Front-window log for the period, longest first:
        \(log.isEmpty ? "(none recorded)" : log)

        Report what you see as JSON.
        """,
    ])
    return content
  }

  private func read(_ batch: [FrameRecord], now: Date) async throws {
    let content = extractionContent(for: batch, now: now)
    guard !content.isEmpty, let first = batch.first, let last = batch.last else { return }
    let response = try await client.complete(
      model: ClaudeClient.haiku, system: Prompts.extraction, content: content,
      schema: Schema.extraction, effort: "low")
    store.addUsage(
      model: ClaudeClient.haiku, input: response.inputTokens, output: response.outputTokens, now: now)
    let extraction = try JSONCoding.decoder.decode(Extraction.self, from: Data(response.text.utf8))
    store.addObservation(start: first.ts, end: last.ts, extraction: extraction)
  }

  // MARK: Entities

  /// Names in a reading that are not in the index under any name or alias. Only these cost a Sonnet call.
  nonisolated func unknownMentions(_ extraction: Extraction) -> [Extraction.Mention] {
    EntityMatching.distinct(extraction.entities ?? [])
      .filter { store.matchEntity(kind: $0.kind, name: $0.mention.name) == nil }
      .map(\.mention)
  }

  /// The JSON handed to Sonnet to decide what the unknown names are.
  nonisolated func entityInput(unknown: [Extraction.Mention]) -> String? {
    guard !unknown.isEmpty else { return nil }
    let payload: [String: Any] = [
      "existing_entries": store.entities(limit: 200).map { entity -> [String: Any] in
        [
          "id": entity.id, "kind": entity.kind.rawValue, "name": entity.name,
          "other_names": entity.aliases, "summary": entity.summary,
        ]
      },
      "new_names": unknown.map { ["name": $0.name, "kind": $0.kind, "context": $0.context] },
    ]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func index(_ extraction: Extraction, observationID: Int64, at date: Date, now: Date) async throws {
    let mentions = extraction.entities ?? []
    guard !mentions.isEmpty else { return }
    let unknown = unknownMentions(extraction)
    if let input = entityInput(unknown: unknown) {
      let response = try await client.complete(
        model: ClaudeClient.sonnet, system: Prompts.entities,
        content: [["type": "text", "text": input]], schema: Schema.entities, effort: "medium")
      store.addUsage(
        model: ClaudeClient.sonnet, input: response.inputTokens, output: response.outputTokens, now: now)
      let result = try JSONCoding.decoder.decode(EntityDecisions.self, from: Data(response.text.utf8))
      EntityResolution.apply(result.decisions, asked: unknown, to: store, now: date)
    }
    EntityResolution.recordSightings(mentions, observationID: observationID, at: date, in: store)
  }

  // MARK: Tasks

  /// The JSON handed to the merging model, or nil when there is nothing for it to decide.
  nonisolated func mergeInput(_ extraction: Extraction, now: Date) -> String? {
    let open = store.tasks(status: .open)
    let commitments = extraction.actionableCommitments
    let completions = open.isEmpty ? [] : extraction.completions
    guard !commitments.isEmpty || !completions.isEmpty else { return nil }

    let closed = store.recentlyClosed(since: now.addingTimeInterval(-14 * 86_400))
    let payload: [String: Any] = [
      "now": "\(Self.timestamp(now)) (\(TimeZone.current.identifier))",
      "open_tasks": open.map { task -> [String: Any] in
        [
          "id": task.id, "title": task.title, "detail": task.detail,
          "deadline": task.deadline.map { Self.timestamp($0, format: "yyyy-MM-dd'T'HH:mm") } ?? "",
          "waiting_person": task.waitingPerson, "seen_count": task.seenCount,
          "first_seen": Self.timestamp(task.firstSeen),
          "project": store.entity(id: task.projectID)?.name ?? "",
        ]
      },
      "recently_closed_tasks": closed.map {
        ["id": $0.id, "title": $0.title, "status": $0.status == .done ? "finished" : "dismissed"]
      },
      "commitments": commitments.map { item -> [String: Any] in
        [
          "title": item.title, "detail": item.detail, "evidence": item.evidence,
          "source_app": item.sourceApp, "url": item.url, "deadline": item.deadline,
          "waiting_person": item.waitingPerson, "confidence": item.confidence,
          "project": item.project ?? "",
        ]
      },
      "completions": completions.map { ["description": $0.description, "evidence": $0.evidence] },
    ]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func merge(_ extraction: Extraction, now: Date) async throws -> MergeTally {
    guard let input = mergeInput(extraction, now: now) else { return MergeTally() }
    let response = try await client.complete(
      model: ClaudeClient.sonnet, system: Prompts.merge,
      content: [["type": "text", "text": input]], schema: Schema.merge, effort: "medium")
    store.addUsage(
      model: ClaudeClient.sonnet, input: response.inputTokens, output: response.outputTokens, now: now)
    let result = try JSONCoding.decoder.decode(MergeResult.self, from: Data(response.text.utf8))
    return TaskMerging.apply(result.operations, to: store, now: now)
  }
}
