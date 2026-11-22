import Foundation

/// Everything Lifescroll remembers, in one local SQLite file.
final class Store: @unchecked Sendable {
  let db: Database
  let framesDirectory: URL

  static let schema = """
    CREATE TABLE IF NOT EXISTS tasks (
      id TEXT PRIMARY KEY, title TEXT, detail TEXT, why TEXT, url TEXT, source_app TEXT,
      bundle_id TEXT, deadline REAL, waiting_person TEXT, importance REAL, rating REAL,
      est_minutes INTEGER, first_seen REAL, last_seen REAL, seen_count INTEGER, status TEXT,
      snooze_until REAL, origin TEXT);
    CREATE TABLE IF NOT EXISTS activity (
      id INTEGER PRIMARY KEY AUTOINCREMENT, start_ts REAL, end_ts REAL, app TEXT,
      bundle_id TEXT, title TEXT, url TEXT, distracting INTEGER);
    CREATE INDEX IF NOT EXISTS activity_end ON activity(end_ts);
    CREATE TABLE IF NOT EXISTS frames (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, path TEXT, app TEXT, title TEXT,
      analyzed INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS observations (
      id INTEGER PRIMARY KEY AUTOINCREMENT, start_ts REAL, end_ts REAL, summary TEXT,
      json TEXT, merged INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS content_seen (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, title TEXT, source TEXT, url TEXT,
      kind TEXT, topic TEXT);
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, kind TEXT, task_id TEXT,
      other_task_id TEXT, context TEXT);
    CREATE TABLE IF NOT EXISTS usage (
      day TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER,
      PRIMARY KEY (day, model));
    CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS entities (
      id TEXT PRIMARY KEY, kind TEXT, name TEXT, aliases TEXT, summary TEXT, first_seen REAL,
      last_seen REAL, seen_count INTEGER, ignored INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS entity_sightings (
      id INTEGER PRIMARY KEY AUTOINCREMENT, entity_id TEXT, observation_id INTEGER, ts REAL,
      context TEXT);
    CREATE INDEX IF NOT EXISTS sightings_entity ON entity_sightings(entity_id, ts);
    CREATE TABLE IF NOT EXISTS entity_links (
      a_id TEXT, b_id TEXT, weight INTEGER, last_seen REAL, PRIMARY KEY (a_id, b_id));
    CREATE TABLE IF NOT EXISTS recommendations (
      id TEXT PRIMARY KEY, title TEXT, url TEXT UNIQUE, source TEXT, kind TEXT, why TEXT,
      bucket TEXT, est_minutes INTEGER, created REAL, status TEXT);
    """

  init(path: String, framesDirectory: URL) throws {
    db = try Database(path: path)
    self.framesDirectory = framesDirectory
    try db.exec(Self.schema)
    try migrate()
  }

  /// Columns added after the first version. Safe to run on every launch.
  func migrate() throws {
    try addColumnIfMissing("tasks", "project_id", "TEXT DEFAULT ''")
    try addColumnIfMissing("observations", "entities_done", "INTEGER DEFAULT 0")
    try addColumnIfMissing("frames", "text", "TEXT")
    try addColumnIfMissing("tasks", "started_at", "REAL")
    try addColumnIfMissing("tasks", "not_task", "INTEGER DEFAULT 0")
    try addColumnIfMissing("entity_links", "how", "TEXT DEFAULT ''")
    try addColumnIfMissing("entity_links", "evidence", "TEXT DEFAULT ''")
    try addColumnIfMissing("entity_links", "last_observation", "INTEGER DEFAULT 0")
    try addColumnIfMissing("entity_links", "removed", "INTEGER DEFAULT 0")
    // Links used to be made between everything seen in the same ten minutes, which connected
    // unrelated things. Those are cleared once; from here on a link needs a stated relationship.
    if value("links_are_stated") == nil {
      try db.exec("DELETE FROM entity_links")
      setValue("links_are_stated", "1")
    }
  }

  private func addColumnIfMissing(_ table: String, _ column: String, _ definition: String) throws {
    let existing = try db.query("PRAGMA table_info(\(table))").map { $0.string("name") }
    if !existing.contains(column) {
      try db.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }
  }

  static func applicationSupport() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let directory = base.appendingPathComponent("Lifescroll", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func openDefault() throws -> Store {
    let directory = applicationSupport()
    return try Store(
      path: directory.appendingPathComponent("lifescroll.sqlite").path,
      framesDirectory: directory.appendingPathComponent("frames", isDirectory: true))
  }

  static func inMemory() throws -> Store {
    try Store(path: ":memory:", framesDirectory: FileManager.default.temporaryDirectory)
  }

  // MARK: - Tasks

  private func task(from row: DBRow) -> TaskItem {
    TaskItem(
      id: row.string("id"), title: row.string("title"), detail: row.string("detail"),
      why: row.string("why"), url: row.string("url"), sourceApp: row.string("source_app"),
      bundleID: row.string("bundle_id"), deadline: row.date("deadline"),
      waitingPerson: row.string("waiting_person"), importance: row.double("importance"),
      rating: row.double("rating"), estMinutes: row.int("est_minutes"),
      firstSeen: row.date("first_seen") ?? Date(), lastSeen: row.date("last_seen") ?? Date(),
      seenCount: row.int("seen_count"),
      status: TaskStatus(rawValue: row.string("status")) ?? .open,
      snoozeUntil: row.date("snooze_until"), origin: row.string("origin"),
      projectID: row.string("project_id"), startedAt: row.date("started_at"),
      notATask: row.int("not_task") != 0)
  }

  func tasks(projectID: String) -> [TaskItem] {
    let rows = try? db.query(
      "SELECT * FROM tasks WHERE project_id = ? AND status = 'open' ORDER BY last_seen DESC",
      [.text(projectID)])
    return (rows ?? []).map(task(from:))
  }

  func tasks(status: TaskStatus) -> [TaskItem] {
    let rows = (try? db.query(
      "SELECT * FROM tasks WHERE status = ? ORDER BY last_seen DESC", [.text(status.rawValue)]))
    return (rows ?? []).map(task(from:))
  }

  func task(id: String) -> TaskItem? {
    (try? db.query("SELECT * FROM tasks WHERE id = ?", [.text(id)]))?.first.map(task(from:))
  }

  /// Done and dismissed tasks the user touched recently, so the merging model does not bring them back.
  func recentlyClosed(since: Date, limit: Int = 60) -> [TaskItem] {
    let rows = try? db.query(
      "SELECT * FROM tasks WHERE status != 'open' AND last_seen >= ? ORDER BY last_seen DESC LIMIT ?",
      [.date(since), .int(Int64(limit))])
    return (rows ?? []).map(task(from:))
  }

  /// What the user has marked as never having been a task, newest first. Unlike other closed
  /// tasks these are kept as examples however old they are.
  func notTasks(limit: Int = 30) -> [TaskItem] {
    let rows = try? db.query(
      "SELECT * FROM tasks WHERE not_task = 1 ORDER BY last_seen DESC LIMIT ?", [.int(Int64(limit))])
    return (rows ?? []).map(task(from:))
  }

  func save(_ task: TaskItem) {
    _ = try? db.execute(
      """
      INSERT INTO tasks (id, title, detail, why, url, source_app, bundle_id, deadline,
        waiting_person, importance, rating, est_minutes, first_seen, last_seen, seen_count,
        status, snooze_until, origin, project_id, started_at, not_task)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET title = excluded.title, detail = excluded.detail,
        why = excluded.why, url = excluded.url, source_app = excluded.source_app,
        bundle_id = excluded.bundle_id, deadline = excluded.deadline,
        waiting_person = excluded.waiting_person, importance = excluded.importance,
        rating = excluded.rating, est_minutes = excluded.est_minutes,
        last_seen = excluded.last_seen, seen_count = excluded.seen_count,
        status = excluded.status, snooze_until = excluded.snooze_until,
        project_id = excluded.project_id, started_at = excluded.started_at,
        not_task = excluded.not_task
      """,
      [
        .text(task.id), .text(task.title), .text(task.detail), .text(task.why), .text(task.url),
        .text(task.sourceApp), .text(task.bundleID), .date(task.deadline),
        .text(task.waitingPerson), .double(task.importance), .double(task.rating),
        .int(Int64(task.estMinutes)), .date(task.firstSeen), .date(task.lastSeen),
        .int(Int64(task.seenCount)), .text(task.status.rawValue), .date(task.snoozeUntil),
        .text(task.origin), .text(task.projectID), .date(task.startedAt), .bool(task.notATask),
      ])
  }

  // MARK: - Activity (the fast loop)

  /// Extends the last span when the same window is still in front, so an hour in one document is one row.
  func logActivity(_ sample: ActivitySample, distracting: Bool, now: Date, interval: TimeInterval) {
    let stamp = now.timeIntervalSince1970
    if let last = try? db.query(
      "SELECT id, app, title, end_ts FROM activity ORDER BY id DESC LIMIT 1"
    ).first, last.string("app") == sample.app, last.string("title") == sample.title,
      stamp - last.double("end_ts") <= interval * 2.5
    {
      _ = try? db.execute(
        "UPDATE activity SET end_ts = ? WHERE id = ?", [.double(stamp), .int(last.int64("id"))])
      return
    }
    _ = try? db.execute(
      "INSERT INTO activity (start_ts, end_ts, app, bundle_id, title, url, distracting) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [
        .double(stamp), .double(stamp), .text(sample.app), .text(sample.bundleID),
        .text(sample.title), .text(sample.url), .bool(distracting),
      ])
  }

  func activitySummary(from: Date, to: Date, sampleInterval: TimeInterval, limit: Int = 25)
    -> [ActivitySpan]
  {
    let rows = try? db.query(
      """
      SELECT app, title, SUM(end_ts - start_ts) + COUNT(*) * ? AS seconds FROM activity
      WHERE end_ts >= ? AND start_ts <= ? GROUP BY app, title ORDER BY seconds DESC LIMIT ?
      """, [.double(sampleInterval), .date(from), .date(to), .int(Int64(limit))])
    return (rows ?? []).map {
      ActivitySpan(app: $0.string("app"), title: $0.string("title"), seconds: $0.int("seconds"))
    }
  }

  func activityCount() -> Int {
    (try? db.query("SELECT COUNT(*) AS n FROM activity"))?.first?.int("n") ?? 0
  }

  /// The bundle id most recently seen for an app name, so "take me there" can reopen it.
  func bundleID(forApp name: String) -> String {
    guard !name.isEmpty else { return "" }
    let rows = try? db.query(
      "SELECT bundle_id FROM activity WHERE app = ? COLLATE NOCASE AND bundle_id != '' ORDER BY id DESC LIMIT 1",
      [.text(name)])
    return rows?.first?.string("bundle_id") ?? ""
  }

  // MARK: - Frames (the slow loop)

  @discardableResult
  func saveFrame(jpeg: Data, at date: Date, app: String, title: String, text: String? = nil) throws -> String {
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"
    let time = DateFormatter()
    time.dateFormat = "HHmmss"
    let directory = framesDirectory.appendingPathComponent(day.string(from: date), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("\(time.string(from: date)).jpg")
    try jpeg.write(to: file, options: .atomic)
    addFrameRecord(ts: date, path: file.path, app: app, title: title, text: text)
    return file.path
  }

  /// The screen text lives on the frame's row, so it is deleted along with the screenshot.
  func addFrameRecord(ts: Date, path: String, app: String, title: String, text: String? = nil) {
    _ = try? db.execute(
      "INSERT INTO frames (ts, path, app, title, text) VALUES (?, ?, ?, ?, ?)",
      [.date(ts), .text(path), .text(app), .text(title), text.map { .text($0) } ?? .null])
  }

  func pendingFrames(limit: Int = 600) -> [FrameRecord] {
    let rows = try? db.query(
      "SELECT * FROM frames WHERE analyzed = 0 ORDER BY ts ASC LIMIT ?", [.int(Int64(limit))])
    return (rows ?? []).map {
      FrameRecord(
        id: $0.int64("id"), ts: $0.date("ts") ?? Date(), path: $0.string("path"),
        app: $0.string("app"), title: $0.string("title"), text: $0.optionalString("text"))
    }
  }

  func pendingFrameCount() -> Int {
    (try? db.query("SELECT COUNT(*) AS n FROM frames WHERE analyzed = 0"))?.first?.int("n") ?? 0
  }

  /// Marks screenshots as read and drops their screen text, which has no use once the reading is done.
  func markAnalyzed(_ ids: [Int64]) {
    for id in ids {
      _ = try? db.execute("UPDATE frames SET analyzed = 1, text = NULL WHERE id = ?", [.int(id)])
    }
  }

  func framesHoldingText() -> Int {
    (try? db.query("SELECT COUNT(*) AS n FROM frames WHERE text IS NOT NULL"))?.first?.int("n") ?? 0
  }

  /// Folds the write-ahead log back into the main file and empties it, so removed text does not
  /// linger there. Erased rows are already overwritten in the main file (see `Database.init`).
  func compact() {
    _ = try? db.query("PRAGMA wal_checkpoint(TRUNCATE)")
  }

  /// Removes screenshots older than the cutoff, files and rows. Returns how many were removed.
  @discardableResult
  func deleteFrames(before cutoff: Date) -> Int {
    let rows = (try? db.query("SELECT id, path FROM frames WHERE ts < ?", [.date(cutoff)])) ?? []
    for row in rows {
      try? FileManager.default.removeItem(atPath: row.string("path"))
    }
    _ = try? db.execute("DELETE FROM frames WHERE ts < ?", [.date(cutoff)])
    return rows.count
  }

  // MARK: - Observations

  func addObservation(start: Date, end: Date, extraction: Extraction) {
    let json = (try? JSONCoding.encoder.encode(extraction)).flatMap { String(data: $0, encoding: .utf8) }
    _ = try? db.execute(
      "INSERT INTO observations (start_ts, end_ts, summary, json) VALUES (?, ?, ?, ?)",
      [.date(start), .date(end), .text(extraction.summary), .text(json ?? "{}")])
    for item in extraction.content {
      _ = try? db.execute(
        "INSERT INTO content_seen (ts, title, source, url, kind, topic) VALUES (?, ?, ?, ?, ?, ?)",
        [
          .date(end), .text(item.title), .text(item.source), .text(item.url), .text(item.kind),
          .text(item.topic),
        ])
    }
  }

  func unmergedObservations() -> [(id: Int64, extraction: Extraction)] {
    let rows = (try? db.query("SELECT id, json FROM observations WHERE merged = 0 ORDER BY id ASC")) ?? []
    return rows.compactMap { row in
      guard let data = row.string("json").data(using: .utf8),
        let extraction = try? JSONCoding.decoder.decode(Extraction.self, from: data)
      else { return nil }
      return (row.int64("id"), extraction)
    }
  }

  func markMerged(_ id: Int64) {
    _ = try? db.execute("UPDATE observations SET merged = 1 WHERE id = ?", [.int(id)])
  }

  func lastObservation() -> (end: Date, summary: String)? {
    guard let row = try? db.query(
      "SELECT end_ts, summary FROM observations ORDER BY id DESC LIMIT 1"
    ).first, let end = row.date("end_ts") else { return nil }
    return (end, row.string("summary"))
  }

  /// Readings whose projects, people, documents and topics have not been indexed yet.
  func observationsNeedingEntities() -> [(id: Int64, end: Date, extraction: Extraction)] {
    let rows = (try? db.query(
      "SELECT id, end_ts, json FROM observations WHERE entities_done = 0 ORDER BY id ASC")) ?? []
    return rows.compactMap { row in
      guard let data = row.string("json").data(using: .utf8),
        let extraction = try? JSONCoding.decoder.decode(Extraction.self, from: data)
      else { return nil }
      return (row.int64("id"), row.date("end_ts") ?? Date(), extraction)
    }
  }

  func markEntitiesDone(_ id: Int64) {
    _ = try? db.execute("UPDATE observations SET entities_done = 1 WHERE id = ?", [.int(id)])
  }

  func lastObservationID() -> Int64 {
    (try? db.query("SELECT MAX(id) AS id FROM observations"))?.first?.int64("id") ?? 0
  }

  // MARK: - Entities (the knowledge graph)

  private func entity(from row: DBRow) -> Entity? {
    guard let kind = EntityKind(rawValue: row.string("kind")) else { return nil }
    let aliases = (row.string("aliases").data(using: .utf8))
      .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    return Entity(
      id: row.string("id"), kind: kind, name: row.string("name"), aliases: aliases,
      summary: row.string("summary"), firstSeen: row.date("first_seen") ?? Date(),
      lastSeen: row.date("last_seen") ?? Date(), seenCount: row.int("seen_count"),
      ignored: row.int("ignored") == 1)
  }

  func entities(kind: EntityKind? = nil, includeIgnored: Bool = false, limit: Int = 500) -> [Entity] {
    var sql = "SELECT * FROM entities WHERE 1 = 1"
    var params: [DBValue] = []
    if let kind {
      sql += " AND kind = ?"
      params.append(.text(kind.rawValue))
    }
    if !includeIgnored { sql += " AND ignored = 0" }
    sql += " ORDER BY last_seen DESC LIMIT ?"
    params.append(.int(Int64(limit)))
    return ((try? db.query(sql, params)) ?? []).compactMap(entity(from:))
  }

  func entity(id: String) -> Entity? {
    (try? db.query("SELECT * FROM entities WHERE id = ?", [.text(id)]))?.first.flatMap(entity(from:))
  }

  /// Finds a known entry by name or alias, including ignored ones. No model is involved.
  func matchEntity(kind: EntityKind, name: String) -> Entity? {
    EntityMatching.find(name, kind: kind, in: entities(kind: kind, includeIgnored: true, limit: 5000))
  }

  func save(_ entity: Entity) {
    let aliases = (try? JSONEncoder().encode(entity.aliases)).flatMap { String(data: $0, encoding: .utf8) }
    _ = try? db.execute(
      """
      INSERT INTO entities (id, kind, name, aliases, summary, first_seen, last_seen, seen_count, ignored)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET name = excluded.name, aliases = excluded.aliases,
        summary = excluded.summary, last_seen = excluded.last_seen,
        seen_count = excluded.seen_count, ignored = excluded.ignored
      """,
      [
        .text(entity.id), .text(entity.kind.rawValue), .text(entity.name), .text(aliases ?? "[]"),
        .text(entity.summary), .date(entity.firstSeen), .date(entity.lastSeen),
        .int(Int64(entity.seenCount)), .bool(entity.ignored),
      ])
  }

  func addAlias(_ alias: String, to id: String) {
    guard var entity = entity(id: id) else { return }
    let key = EntityMatching.normalize(alias)
    guard !key.isEmpty, EntityMatching.normalize(entity.name) != key,
      !entity.aliases.contains(where: { EntityMatching.normalize($0) == key })
    else { return }
    entity.aliases.append(alias)
    save(entity)
  }

  /// Records that an entity appeared in one reading. One sighting per entity per reading.
  /// Returns false when that sighting was already recorded.
  @discardableResult
  func addSighting(entityID: String, observationID: Int64, ts: Date, context: String) -> Bool {
    let already = (try? db.query(
      "SELECT 1 AS present FROM entity_sightings WHERE entity_id = ? AND observation_id = ? LIMIT 1",
      [.text(entityID), .int(observationID)]))?.isEmpty == false
    guard !already, var entity = entity(id: entityID) else { return false }
    _ = try? db.execute(
      "INSERT INTO entity_sightings (entity_id, observation_id, ts, context) VALUES (?, ?, ?, ?)",
      [.text(entityID), .int(observationID), .date(ts), .text(context)])
    entity.seenCount += 1
    entity.lastSeen = max(entity.lastSeen, ts)
    save(entity)
    return true
  }

  func sightings(entityID: String, limit: Int = 30) -> [EntitySighting] {
    let rows = try? db.query(
      "SELECT ts, context FROM entity_sightings WHERE entity_id = ? ORDER BY ts DESC LIMIT ?",
      [.text(entityID), .int(Int64(limit))])
    return (rows ?? []).map {
      EntitySighting(ts: $0.date("ts") ?? Date(), context: $0.string("context"))
    }
  }

  /// Strengthens the link between every pair of entities that appeared in the same reading.
  /// Records one stated relationship between two entries. Stating it again in a later reading
  /// strengthens the link; recording the same reading twice does not.
  /// Returns false when nothing changed.
  @discardableResult
  func link(_ first: String, _ second: String, how: String, evidence: String, observationID: Int64, ts: Date) -> Bool {
    guard first != second else { return false }
    let (a, b) = first < second ? (first, second) : (second, first)
    let existing = try? db.query(
      "SELECT last_observation, removed, evidence FROM entity_links WHERE a_id = ? AND b_id = ?",
      [.text(a), .text(b)]
    ).first
    if let existing {
      // The user removed this link. A reading saying otherwise does not bring it back.
      guard existing.int("removed") == 0 else { return false }
      guard existing.int64("last_observation") != observationID else { return false }
      if existing.string("evidence") == Self.byHandEvidence {
        // A link the user drew keeps its label; the reading only strengthens it.
        _ = try? db.execute(
          "UPDATE entity_links SET weight = weight + 1, last_seen = ?, last_observation = ? WHERE a_id = ? AND b_id = ?",
          [.date(ts), .int(observationID), .text(a), .text(b)])
      } else {
        _ = try? db.execute(
          "UPDATE entity_links SET weight = weight + 1, last_seen = ?, how = ?, evidence = ?, last_observation = ? WHERE a_id = ? AND b_id = ?",
          [.date(ts), .text(how), .text(evidence), .int(observationID), .text(a), .text(b)])
      }
    } else {
      _ = try? db.execute(
        "INSERT INTO entity_links (a_id, b_id, weight, last_seen, how, evidence, last_observation) VALUES (?, ?, 1, ?, ?, ?, ?)",
        [.text(a), .text(b), .date(ts), .text(how), .text(evidence), .int(observationID)])
    }
    return true
  }

  static let handMade = "linked by you"
  static let byHandEvidence = "added by hand"

  /// A link the user drew themselves. It counts for more than one stated by a reading, so the two
  /// entries sit close on the graph. Returns false if they were already linked or are the same entry.
  @discardableResult
  func linkByHand(_ first: String, _ second: String, ts: Date) -> Bool {
    guard first != second else { return false }
    let (a, b) = first < second ? (first, second) : (second, first)
    let existing = try? db.query(
      "SELECT removed FROM entity_links WHERE a_id = ? AND b_id = ?", [.text(a), .text(b)]
    ).first
    if let existing {
      // Already linked: nothing to do. Removed earlier: drawing it again is the user changing their mind.
      guard existing.int("removed") == 1 else { return false }
      _ = try? db.execute(
        "UPDATE entity_links SET removed = 0, weight = 3, last_seen = ?, how = ?, evidence = ? WHERE a_id = ? AND b_id = ?",
        [.date(ts), .text(Self.handMade), .text(Self.byHandEvidence), .text(a), .text(b)])
      return true
    }
    _ = try? db.execute(
      "INSERT INTO entity_links (a_id, b_id, weight, last_seen, how, evidence, last_observation) VALUES (?, ?, 3, ?, ?, ?, 0)",
      [.text(a), .text(b), .date(ts), .text(Self.handMade), .text(Self.byHandEvidence)])
    return true
  }

  /// Takes a link away and remembers that the user did, so no later reading puts it back.
  func removeLink(_ first: String, _ second: String) {
    let (a, b) = first < second ? (first, second) : (second, first)
    _ = try? db.execute(
      "UPDATE entity_links SET removed = 1 WHERE a_id = ? AND b_id = ?", [.text(a), .text(b)])
  }

  /// Every link between two entries that are both still in the index.
  func allLinks() -> [GraphEdge] {
    let rows = try? db.query(
      """
      SELECT l.a_id, l.b_id, l.weight, l.how FROM entity_links l
      JOIN entities a ON a.id = l.a_id AND a.ignored = 0
      JOIN entities b ON b.id = l.b_id AND b.ignored = 0
      WHERE l.removed = 0
      """)
    return (rows ?? []).map {
      GraphEdge(a: $0.string("a_id"), b: $0.string("b_id"), weight: $0.int("weight"), how: $0.string("how"))
    }
  }

  func links(entityID: String, limit: Int = 20) -> [EntityLink] {
    let rows = try? db.query(
      """
      SELECT CASE WHEN a_id = ? THEN b_id ELSE a_id END AS other, weight, how FROM entity_links
      WHERE (a_id = ? OR b_id = ?) AND removed = 0 ORDER BY weight DESC, last_seen DESC LIMIT ?
      """, [.text(entityID), .text(entityID), .text(entityID), .int(Int64(limit))])
    return (rows ?? []).compactMap { row in
      guard let other = entity(id: row.string("other")), !other.ignored else { return nil }
      return EntityLink(entity: other, weight: row.int("weight"), how: row.string("how"))
    }
  }

  // MARK: - Suggestions

  private func recommendation(from row: DBRow) -> Recommendation {
    Recommendation(
      id: row.string("id"), title: row.string("title"), url: row.string("url"),
      source: row.string("source"), kind: row.string("kind"), why: row.string("why"),
      bucket: row.string("bucket"), estMinutes: row.int("est_minutes"),
      created: row.date("created") ?? Date(), status: row.string("status"))
  }

  /// Adds a suggestion unless one with the same link was ever stored. Returns whether it was added.
  @discardableResult
  func add(_ suggestion: Recommendation) -> Bool {
    let before = recommendationCount()
    _ = try? db.execute(
      """
      INSERT OR IGNORE INTO recommendations (id, title, url, source, kind, why, bucket,
        est_minutes, created, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(suggestion.id), .text(suggestion.title), .text(suggestion.url),
        .text(suggestion.source), .text(suggestion.kind), .text(suggestion.why),
        .text(suggestion.bucket), .int(Int64(suggestion.estMinutes)), .date(suggestion.created),
        .text(suggestion.status),
      ])
    return recommendationCount() > before
  }

  private func recommendationCount() -> Int {
    (try? db.query("SELECT COUNT(*) AS n FROM recommendations"))?.first?.int("n") ?? 0
  }

  func recommendations(status: String, limit: Int = 50) -> [Recommendation] {
    let rows = try? db.query(
      "SELECT * FROM recommendations WHERE status = ? ORDER BY created DESC, rowid ASC LIMIT ?",
      [.text(status), .int(Int64(limit))])
    return (rows ?? []).map(recommendation(from:))
  }

  func setRecommendationStatus(_ id: String, _ status: String) {
    _ = try? db.execute(
      "UPDATE recommendations SET status = ? WHERE id = ?", [.text(status), .text(id)])
  }

  /// Every link ever suggested, whatever happened to it, so nothing is suggested twice.
  func suggestedURLs() -> Set<String> {
    Set(((try? db.query("SELECT url FROM recommendations")) ?? []).map { $0.string("url") })
  }

  /// What the user opened and what they said was not for them, newest first.
  func suggestionFeedback(limit: Int = 30) -> [(title: String, status: String)] {
    let rows = try? db.query(
      "SELECT title, status FROM recommendations WHERE status IN ('opened', 'dismissed') ORDER BY created DESC LIMIT ?",
      [.int(Int64(limit))])
    return (rows ?? []).map { ($0.string("title"), $0.string("status")) }
  }

  /// Unopened suggestions older than the cutoff stop being shown.
  func expireRecommendations(before cutoff: Date) {
    _ = try? db.execute(
      "UPDATE recommendations SET status = 'expired' WHERE status = 'new' AND created < ?",
      [.date(cutoff)])
  }

  /// What the user has recently watched and read, newest first.
  func interestSignals(since: Date, limit: Int = 40) -> [InterestSignal] {
    let rows = try? db.query(
      "SELECT title, topic, kind, source FROM content_seen WHERE ts >= ? ORDER BY id DESC LIMIT ?",
      [.date(since), .int(Int64(limit))])
    return (rows ?? []).map {
      InterestSignal(
        title: $0.string("title"), topic: $0.string("topic"), kind: $0.string("kind"),
        source: $0.string("source"))
    }
  }

  /// The sites, channels and accounts the user has recently been reading and watching, most recent
  /// first. These steer where suggestions are looked for.
  func usedSources(since: Date, limit: Int = 20) -> [String] {
    let rows = try? db.query(
      "SELECT source, MAX(id) AS latest FROM content_seen WHERE ts >= ? AND source != '' GROUP BY source ORDER BY latest DESC LIMIT ?",
      [.date(since), .int(Int64(limit))])
    return (rows ?? []).map { $0.string("source") }
  }

  /// Links and titles of things the user has already seen, so they are not suggested back to them.
  func seenContent() -> (urls: Set<String>, titles: Set<String>) {
    let rows = (try? db.query("SELECT url, title FROM content_seen")) ?? []
    return (
      Set(rows.map { $0.string("url") }.filter { !$0.isEmpty }),
      Set(rows.map { EntityMatching.normalize($0.string("title")) }.filter { !$0.isEmpty })
    )
  }

  // MARK: - Events (the training log)

  /// Every card shown and every response is a row here. This is the data a personal ranker learns from.
  func logEvent(_ kind: String, taskID: String = "", otherTaskID: String = "", context: [String: String] = [:], now: Date = Date()) {
    let json = (try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]))
      .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    _ = try? db.execute(
      "INSERT INTO events (ts, kind, task_id, other_task_id, context) VALUES (?, ?, ?, ?, ?)",
      [.date(now), .text(kind), .text(taskID), .text(otherTaskID), .text(json)])
  }

  func eventCount(kind: String) -> Int {
    (try? db.query("SELECT COUNT(*) AS n FROM events WHERE kind = ?", [.text(kind)]))?.first?.int("n") ?? 0
  }

  // MARK: - Usage and settings

  static func dayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  func addUsage(model: String, input: Int, output: Int, now: Date = Date()) {
    _ = try? db.execute(
      """
      INSERT INTO usage (day, model, input_tokens, output_tokens) VALUES (?, ?, ?, ?)
      ON CONFLICT(day, model) DO UPDATE SET input_tokens = input_tokens + excluded.input_tokens,
        output_tokens = output_tokens + excluded.output_tokens
      """, [.text(Self.dayKey(now)), .text(model), .int(Int64(input)), .int(Int64(output))])
  }

  /// Web searches are billed per search, not per token, so they are counted under their own name.
  func addWebSearches(_ count: Int, now: Date = Date()) {
    guard count > 0 else { return }
    addUsage(model: "web searches", input: count, output: 0, now: now)
  }

  func usage(on date: Date) -> [UsageRow] {
    let rows = try? db.query(
      "SELECT model, input_tokens, output_tokens FROM usage WHERE day = ? ORDER BY model",
      [.text(Self.dayKey(date))])
    return (rows ?? []).map {
      UsageRow(
        model: $0.string("model"), inputTokens: $0.int("input_tokens"),
        outputTokens: $0.int("output_tokens"))
    }
  }

  func value(_ key: String) -> String? {
    (try? db.query("SELECT value FROM kv WHERE key = ?", [.text(key)]))?.first?.string("value")
  }

  func setValue(_ key: String, _ value: String) {
    _ = try? db.execute(
      "INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [.text(key), .text(value)])
  }
}
