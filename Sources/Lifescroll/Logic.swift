import Foundation

// Pure logic with no system dependencies, so `Lifescroll --self-test` can exercise all of it.

// MARK: - Ranking

enum Ranker {
  /// 0...35. Overdue is the maximum; the pull fades with a two-day half-life-ish curve.
  static func urgency(deadline: Date?, now: Date) -> Double {
    guard let deadline else { return 0 }
    let hours = deadline.timeIntervalSince(now) / 3600
    if hours <= 0 { return 35 }
    return 35 * exp(-hours / 48)
  }

  /// The hand-written score. A model trained on the events table is meant to replace this later.
  static func score(_ task: TaskItem, now: Date) -> Double {
    let importance = 40 * min(max(task.importance, 0), 1)
    let seen = 2 * Double(min(task.seenCount, 5))
    let waiting = task.waitingPerson.isEmpty ? 0.0 : 8.0
    let daysSat = min(max(now.timeIntervalSince(task.firstSeen) / 86_400, 0), 5)
    // The user's own picks can outweigh everything inferred: up to ±40, against 35 for a deadline.
    let picks = min(max((task.rating - 1000) / 4, -40), 40)
    return importance + urgency(deadline: task.deadline, now: now) + seen + waiting + daysSat + picks
  }

  /// Open tasks that are not snoozed, most important first.
  static func ranked(_ tasks: [TaskItem], now: Date) -> [TaskItem] {
    tasks
      .filter { $0.status == .open && !$0.isSnoozed(at: now) }
      .sorted { precedes($0, $1, now: now) }
  }

  /// The order tasks are shown in. Anything in progress comes first, whatever its score: the user
  /// has said what they are doing, and that outranks every guess about what matters.
  static func precedes(_ first: TaskItem, _ second: TaskItem, now: Date) -> Bool {
    if first.isInProgress != second.isInProgress { return first.isInProgress }
    return score(first, now: now) > score(second, now: now)
  }

  /// How long a task has been in progress, for its card.
  static func elapsedText(since start: Date, now: Date) -> String {
    let minutes = Int(max(now.timeIntervalSince(start), 0) / 60)
    if minutes < 1 { return "just started" }
    if minutes < 60 { return "\(minutes) min" }
    let hours = minutes / 60
    return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min"
  }

  /// Standard Elo update for one "this matters more" pick.
  static func elo(winner: Double, loser: Double, k: Double = 32) -> (winner: Double, loser: Double) {
    let expected = 1 / (1 + pow(10, (loser - winner) / 400))
    let delta = k * (1 - expected)
    return (winner + delta, loser - delta)
  }

  /// The two neighbouring tasks near the top whose scores are closest: the pick that tells us most.
  static func pairToCompare(_ ranked: [TaskItem], now: Date, among top: Int = 6) -> (TaskItem, TaskItem)? {
    let pool = Array(ranked.prefix(top))
    guard pool.count >= 2 else { return nil }
    var best: (TaskItem, TaskItem)?
    var smallestGap = Double.infinity
    for index in 0..<(pool.count - 1) {
      let gap = abs(score(pool[index], now: now) - score(pool[index + 1], now: now))
      if gap < smallestGap {
        smallestGap = gap
        best = (pool[index], pool[index + 1])
      }
    }
    return best
  }

  /// Whether a deadline has passed. Views ask this, not the wording of `deadlineText`, to decide
  /// how to colour a deadline.
  static func isOverdue(_ deadline: Date?, now: Date) -> Bool {
    guard let deadline else { return false }
    return deadline <= now
  }

  static func deadlineText(_ deadline: Date?, now: Date) -> String? {
    guard let deadline else { return nil }
    let seconds = deadline.timeIntervalSince(now)
    if seconds <= 0 { return "overdue" }
    let hours = seconds / 3600
    if hours < 1 { return "due in \(max(Int(seconds / 60), 1)) min" }
    if hours < 24 { return "due in \(Int(hours.rounded())) h" }
    let days = Int((hours / 24).rounded())
    return days == 1 ? "due tomorrow" : "due in \(days) days"
  }

  /// A fallback "why now" line for tasks the merging model has not written one for.
  static func fallbackWhy(_ task: TaskItem, now: Date) -> String {
    var parts: [String] = []
    if let due = deadlineText(task.deadline, now: now) { parts.append(due.capitalizedFirst) }
    if !task.waitingPerson.isEmpty { parts.append("\(task.waitingPerson) is waiting") }
    if task.seenCount > 1 { parts.append("you've come back to this \(task.seenCount) times") }
    if parts.isEmpty { parts.append("Top of your list right now") }
    return parts.joined(separator: " · ")
  }
}

extension String {
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Lists driven from the keyboard

enum ListNavigation {
  /// The row an arrow key moves to. With nothing chosen, down picks the first row and up the last;
  /// at either end the selection stays where it is.
  static func move(from current: String?, in ids: [String], by step: Int) -> String? {
    guard !ids.isEmpty else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else {
      return step >= 0 ? ids.first : ids.last
    }
    return ids[min(max(index + step, 0), ids.count - 1)]
  }
}

// MARK: - The feed

enum Feed {
  /// The feed is a loop: past the last card is the first again, and before the first is the last.
  static func wrap(_ index: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((index % count) + count) % count
  }

  /// Where the popover should sit after the feed has been rebuilt. It follows the card that was on
  /// screen, so a background refresh cannot slide a different card under the pointer. If that card
  /// is gone (done, dismissed, opened), the position stays put and the next card moves up into it.
  static func position(following id: String?, in feed: [FeedItem], previous: Int) -> Int {
    if let id, let index = feed.firstIndex(where: { $0.id == id }) { return index }
    return min(max(previous, 0), max(feed.count - 1, 0))
  }

  /// Blends tasks and suggestions according to the mode.
  /// - Lock in: tasks only.
  /// - Balanced: one suggestion after every three tasks, so suggestions stay the minority.
  /// - Pure dopamine: three suggestions, then a task, and everything left over after that.
  static func mix(tasks: [TaskItem], suggestions: [Recommendation], mode: Mode) -> [FeedItem] {
    // Whatever the mode, a task in progress opens the feed: it is what the user is in the middle of.
    let underway = tasks.filter(\.isInProgress).map(FeedItem.task)
    let waiting = tasks.filter { !$0.isInProgress }
    let taskItems = waiting.map(FeedItem.task)
    let suggestionItems = suggestions.map(FeedItem.suggestion)
    switch mode {
    case .lockIn:
      return underway + taskItems
    case .balanced:
      // With no tasks at all, a few suggestions keep the feed from being empty.
      let allowed =
        tasks.isEmpty
        ? min(3, suggestions.count) : min(suggestions.count, max(1, (tasks.count + 2) / 3))
      return underway + interleave(taskItems, Array(suggestionItems.prefix(allowed)), every: 3)
    case .dopamine:
      return underway + interleave(suggestionItems, taskItems, every: 3)
    }
  }

  /// `every` items from `main`, then one from `other`, repeating; whatever is left goes on the end.
  static func interleave(_ main: [FeedItem], _ other: [FeedItem], every: Int) -> [FeedItem] {
    var result: [FeedItem] = []
    var mainIndex = 0
    var otherIndex = 0
    while mainIndex < main.count {
      let end = min(mainIndex + max(every, 1), main.count)
      result.append(contentsOf: main[mainIndex..<end])
      mainIndex = end
      if otherIndex < other.count {
        result.append(other[otherIndex])
        otherIndex += 1
      }
    }
    result.append(contentsOf: other[otherIndex...])
    return result
  }
}

enum SuggestionSchedule {
  /// Fewer than this many unopened suggestions means it is worth looking for more.
  static let lowWater = 6
  /// Shortest gap between two successful rounds. A round mostly draws on the bank, and only
  /// searches when the bank is low, so rounds can come fairly often without costing much.
  static let gap: TimeInterval = 45 * 60
  /// How long to wait after any attempt, including a failed one, before trying again.
  static let retryGap: TimeInterval = 20 * 60

  /// Whether it is time to look for more suggestions. Lock in mode never fetches any.
  static func shouldFind(mode: Mode, onHand: Int, lastSuccess: Date?, lastAttempt: Date?, now: Date) -> Bool {
    guard mode != .lockIn, onHand < lowWater else { return false }
    if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryGap { return false }
    if let lastSuccess, now.timeIntervalSince(lastSuccess) < gap { return false }
    return true
  }
}

/// Turns a stream of scroll-wheel or trackpad deltas into "next card" and "previous card" steps.
struct ScrollStepper {
  /// Trackpad travel, in points, that moves one card.
  static let threshold: Double = 30
  /// Shortest gap between two steps, so one swipe does not fly through the whole list.
  static let cooldown: TimeInterval = 0.22

  var accumulated: Double = 0
  var lastStep: Date = .distantPast

  /// Feed one event. Returns 1 for the next card, -1 for the previous one, 0 for no move yet.
  /// `deltaY` is negative when scrolling toward later content, which already respects the
  /// system's natural-scrolling setting.
  mutating func feed(deltaY: Double, precise: Bool, momentum: Bool, now: Date) -> Int {
    // Coasting after the fingers lift is ignored; only deliberate movement counts.
    guard !momentum, deltaY != 0 else { return 0 }
    // A mouse wheel reports whole notches; one notch is one card.
    let delta = precise ? deltaY : deltaY * Self.threshold
    if accumulated != 0, (delta < 0) != (accumulated < 0) { accumulated = 0 }
    accumulated = min(max(accumulated + delta, -Self.threshold), Self.threshold)
    guard abs(accumulated) >= Self.threshold, now.timeIntervalSince(lastStep) >= Self.cooldown
    else { return 0 }
    let step = accumulated < 0 ? 1 : -1
    accumulated = 0
    lastStep = now
    return step
  }

  mutating func gestureEnded() { accumulated = 0 }
}

// MARK: - Nudging

/// Tracks how long the user has been on distracting things and says when to interrupt.
struct NudgeTracker {
  /// Time off the distracting thing before the counter resets. Short tab-outs do not count as stopping.
  static let calmReset: TimeInterval = 90

  var distractedSeconds: TimeInterval = 0
  var calmSeconds: TimeInterval = 0
  var mutedUntil: Date = .distantPast

  /// Feed one sample. Returns true when a nudge should fire now.
  mutating func observe(distracting: Bool, interval: TimeInterval, threshold: TimeInterval?, now: Date) -> Bool {
    if distracting {
      distractedSeconds += interval
      calmSeconds = 0
    } else {
      calmSeconds += interval
      if calmSeconds >= Self.calmReset { distractedSeconds = 0 }
    }
    guard let threshold, distractedSeconds >= threshold, now >= mutedUntil else { return false }
    distractedSeconds = 0
    return true
  }

  mutating func mute(for duration: TimeInterval, now: Date) {
    mutedUntil = now.addingTimeInterval(duration)
    distractedSeconds = 0
  }
}

/// Notices when the screen has stopped changing, using the same comparison that skips repeat screenshots.
/// A still screen is not scrolling, whatever app is in front: a paused video, or an empty chair.
struct StillnessTracker {
  /// How long the screen must stay unchanged before it counts as still.
  static let after: TimeInterval = 120

  private(set) var stillSince: Date?

  mutating func sawChange() { stillSince = nil }

  mutating func sawNoChange(now: Date) {
    if stillSince == nil { stillSince = now }
  }

  /// Call when the screen could not be checked (capture off, a private window in front).
  /// Not knowing is never treated as still.
  mutating func couldNotCheck() { stillSince = nil }

  func isStill(now: Date) -> Bool {
    guard let stillSince else { return false }
    return now.timeIntervalSince(stillSince) >= Self.after
  }
}

enum Keywords {
  static let defaultDistracting =
    "youtube, instagram, tiktok, reddit, twitter, / x, netflix, twitch, facebook, hulu, disney+, bilibili, shorts, reels"
  static let defaultExcluded =
    "1password, bitwarden, lastpass, keychain access, passwords, private browsing, incognito, bank"

  static func parse(_ list: String) -> [String] {
    list.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
  }

  static func matches(_ sample: ActivitySample, _ keywords: [String]) -> Bool {
    let haystack = "\(sample.app) \(sample.title) \(sample.url)".lowercased()
    return keywords.contains { haystack.contains($0) }
  }
}

// MARK: - Frames

enum FrameMath {
  /// Mean absolute difference between two 16×16 grayscale thumbnails, 0...255.
  static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 255 }
    var total = 0
    for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
    return Double(total) / Double(a.count)
  }

  /// Evenly spaced picks that always include the first and last item.
  static func keyFrames<T>(_ items: [T], max count: Int) -> [T] {
    guard count > 0 else { return [] }
    guard items.count > count else { return items }
    guard count > 1 else { return [items[items.count - 1]] }
    let step = Double(items.count - 1) / Double(count - 1)
    return (0..<count).map { items[Int((Double($0) * step).rounded())] }
  }
}

// MARK: - Deadlines

enum DeadlineParser {
  /// Accepts what the models are asked for: an ISO date-time, or a bare date (taken as end of that day).
  static func parse(_ text: String, calendar: Calendar = .current) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: trimmed) { return date }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: trimmed) { return date }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: trimmed) { return date }
    }
    formatter.dateFormat = "yyyy-MM-dd"
    if let day = formatter.date(from: trimmed) {
      return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day)
    }
    return nil
  }
}

// MARK: - The index of projects, people, documents and topics

enum EntityMatching {
  /// Lowercased, punctuation dropped, spaces collapsed: "CS-101: Lab 2" and "cs 101 lab 2" are the same name.
  static func normalize(_ name: String) -> String {
    let characters = name.lowercased().unicodeScalars.map {
      CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
    }
    return String(characters).split(separator: " ").joined(separator: " ")
  }

  /// Matches by name or alias within one kind. This is the free path that avoids a model call.
  static func find(_ name: String, kind: EntityKind, in entities: [Entity]) -> Entity? {
    let key = normalize(name)
    guard !key.isEmpty else { return nil }
    return entities.first { entity in
      entity.kind == kind
        && (normalize(entity.name) == key || entity.aliases.contains { normalize($0) == key })
    }
  }

  /// Words too common to suggest that two names are the same thing.
  static let fillerWords: Set<String> = [
    "the", "a", "an", "of", "and", "for", "to", "in", "on", "with", "my", "new", "notes", "doc", "page",
  ]

  static func words(_ name: String) -> Set<String> {
    Set(normalize(name).split(separator: " ").map(String.init).filter { !fillerWords.contains($0) })
  }

  /// The existing entries worth showing the model when it decides what new names are: those of the
  /// same kind sharing a word or an initialism with a new name, then the most recently seen. Sending
  /// the whole index with every call was most of the day's Sonnet bill.
  static func shortlist(
    for names: [(kind: EntityKind, name: String)], in entities: [Entity], recent: Int = 12, limit: Int = 40
  ) -> [Entity] {
    let asked = names.map { (kind: $0.kind, words: words($0.name), key: normalize($0.name).replacingOccurrences(of: " ", with: "")) }
    func initials(_ name: String) -> String {
      String(normalize(name).split(separator: " ").compactMap(\.first))
    }
    func related(_ entity: Entity) -> Bool {
      let labels = [entity.name] + entity.aliases
      return asked.contains { item in
        guard item.kind == entity.kind else { return false }
        return labels.contains { label in
          let squashed = normalize(label).replacingOccurrences(of: " ", with: "")
          if !words(label).isDisjoint(with: item.words) { return true }
          if item.key.count >= 4, squashed.count >= 4, squashed.contains(item.key) || item.key.contains(squashed) { return true }
          let short = initials(label)
          return short.count >= 2 && (short == item.key || item.words.contains(short))
        }
      }
    }
    var chosen = entities.filter(related)
    if chosen.count > limit { chosen = Array(chosen.prefix(limit)) }
    let have = Set(chosen.map(\.id))
    chosen += entities.filter { !have.contains($0.id) }.prefix(recent)
    return chosen
  }

  /// Mentions with a usable name and kind, one per distinct name.
  static func distinct(_ mentions: [Extraction.Mention]) -> [(kind: EntityKind, mention: Extraction.Mention)] {
    var seen = Set<String>()
    var result: [(kind: EntityKind, mention: Extraction.Mention)] = []
    for mention in mentions {
      guard let kind = EntityKind(rawValue: mention.kind) else { continue }
      let key = "\(kind.rawValue)|\(normalize(mention.name))"
      guard !normalize(mention.name).isEmpty, seen.insert(key).inserted else { continue }
      result.append((kind, mention))
    }
    return result
  }
}

struct EntityTally: Equatable {
  var created = 0
  var aliased = 0
  var ignored = 0
  var skipped = 0
}

enum EntityResolution {
  /// Applies the merging model's decisions about names that were not in the index.
  /// Only names that were actually asked about are acted on, and ids are checked, not trusted.
  @discardableResult
  static func apply(
    _ decisions: [EntityDecisions.Decision], asked: [Extraction.Mention], to store: Store, now: Date
  ) -> EntityTally {
    var tally = EntityTally()
    let askedKeys = Set(asked.map { "\($0.kind)|\(EntityMatching.normalize($0.name))" })

    for decision in decisions {
      let key = "\(decision.kind)|\(EntityMatching.normalize(decision.mention))"
      guard let kind = EntityKind(rawValue: decision.kind), askedKeys.contains(key),
        store.matchEntity(kind: kind, name: decision.mention) == nil
      else {
        tally.skipped += 1
        continue
      }

      switch decision.decision {
      case "same_as":
        guard let target = store.entity(id: decision.entityId), target.kind == kind, !target.ignored
        else {
          tally.skipped += 1
          continue
        }
        store.addAlias(decision.mention, to: target.id)
        tally.aliased += 1

      case "new":
        let proposed = decision.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = proposed.isEmpty ? decision.mention : proposed
        if let existing = store.matchEntity(kind: kind, name: name), !existing.ignored {
          store.addAlias(decision.mention, to: existing.id)
          tally.aliased += 1
        } else {
          let sameName = EntityMatching.normalize(name) == EntityMatching.normalize(decision.mention)
          store.save(
            Entity(
              kind: kind, name: name, aliases: sameName ? [] : [decision.mention],
              summary: decision.summary, firstSeen: now, lastSeen: now))
          tally.created += 1
        }

      case "ignore":
        store.save(
          Entity(kind: kind, name: decision.mention, firstSeen: now, lastSeen: now, ignored: true))
        tally.ignored += 1

      default:
        tally.skipped += 1
      }
    }
    return tally
  }

  /// Records which known entities one reading mentioned. Being seen in the same reading does not
  /// connect two entries: that takes a stated relationship (see `recordRelations`).
  static func recordSightings(
    _ mentions: [Extraction.Mention], observationID: Int64, at date: Date, in store: Store
  ) {
    for (kind, mention) in EntityMatching.distinct(mentions) {
      guard let entity = store.matchEntity(kind: kind, name: mention.name), !entity.ignored
      else { continue }
      store.addSighting(
        entityID: entity.id, observationID: observationID, ts: date, context: mention.context)
    }
  }

  /// Turns the relationships the reading model stated into links. Both ends must be entries in the
  /// index, named among this reading's entities; anything else is dropped, not guessed at.
  /// Returns how many links were made or strengthened.
  @discardableResult
  static func recordRelations(
    _ relations: [Extraction.Relation], mentions: [Extraction.Mention], observationID: Int64,
    at date: Date, in store: Store
  ) -> Int {
    // A relation names its ends as they were written; the mentions say what kind each one is.
    var byName: [String: Entity] = [:]
    for (kind, mention) in EntityMatching.distinct(mentions) {
      if let entity = store.matchEntity(kind: kind, name: mention.name), !entity.ignored {
        byName[EntityMatching.normalize(mention.name)] = entity
      }
    }
    var made = 0
    for relation in relations {
      guard let first = byName[EntityMatching.normalize(relation.from)],
        let second = byName[EntityMatching.normalize(relation.to)],
        !relation.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      if store.link(
        first.id, second.id, how: relation.how, evidence: relation.evidence,
        observationID: observationID, ts: date)
      {
        made += 1
      }
    }
    return made
  }
}

// MARK: - Applying the merging model's decisions

struct MergeTally: Equatable {
  var created = 0
  var updated = 0
  var completed = 0
  var ignored = 0
}

enum TaskMerging {
  /// Applies operations to the store. Unknown task ids are skipped rather than trusted.
  @discardableResult
  static func apply(_ operations: [MergeResult.Operation], to store: Store, now: Date) -> MergeTally {
    var tally = MergeTally()
    for operation in operations {
      // A project name only links when it is already in the index; unknown names are left unlinked.
      let projectID = (operation.project).flatMap { name -> String? in
        guard let project = store.matchEntity(kind: .project, name: name), !project.ignored
        else { return nil }
        return project.id
      }

      switch operation.op {
      case "create":
        let title = operation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { tally.ignored += 1; continue }
        let task = TaskItem(
          title: title, detail: operation.detail, why: operation.why, url: operation.url,
          sourceApp: operation.sourceApp, bundleID: store.bundleID(forApp: operation.sourceApp),
          deadline: DeadlineParser.parse(operation.deadline),
          waitingPerson: operation.waitingPerson,
          importance: min(max(operation.importance, 0), 1),
          estMinutes: max(operation.estMinutes, 0), firstSeen: now, lastSeen: now,
          projectID: projectID ?? "")
        store.save(task)
        store.logEvent("task_created", taskID: task.id, context: ["reason": operation.reason], now: now)
        tally.created += 1

      case "update":
        guard var task = store.task(id: operation.taskId), task.status == .open else {
          tally.ignored += 1
          continue
        }
        if !operation.title.isEmpty { task.title = operation.title }
        if !operation.detail.isEmpty { task.detail = operation.detail }
        if !operation.why.isEmpty { task.why = operation.why }
        if !operation.url.isEmpty { task.url = operation.url }
        if !operation.waitingPerson.isEmpty { task.waitingPerson = operation.waitingPerson }
        if let deadline = DeadlineParser.parse(operation.deadline) { task.deadline = deadline }
        if operation.estMinutes > 0 { task.estMinutes = operation.estMinutes }
        if task.bundleID.isEmpty { task.bundleID = store.bundleID(forApp: operation.sourceApp) }
        if let projectID { task.projectID = projectID }
        task.importance = min(max(operation.importance, 0), 1)
        task.seenCount += 1
        task.lastSeen = now
        store.save(task)
        tally.updated += 1

      case "complete":
        guard var task = store.task(id: operation.taskId), task.status == .open else {
          tally.ignored += 1
          continue
        }
        task.status = .done
        task.lastSeen = now
        store.save(task)
        store.logEvent("auto_done", taskID: task.id, context: ["reason": operation.reason], now: now)
        tally.completed += 1

      default:
        tally.ignored += 1
      }
    }
    return tally
  }
}
