import Foundation

/// `Lifescroll --self-test` runs these checks and exits non-zero on any failure.
/// Command Line Tools ship without XCTest, so the checks live in the app itself.
enum SelfTest {
  private static var failures = 0
  private static var passes = 0

  private static func check(_ condition: Bool, _ name: String) {
    if condition {
      passes += 1
    } else {
      failures += 1
      print("FAIL  \(name)")
    }
  }

  static func run() -> Bool {
    ranking()
    feed()
    nudging()
    frames()
    deadlines()
    keywords()
    storage()
    merging()
    claudeRequests()
    claudeReplies()
    decoding()
    analyzerInputs()
    knowledgeGraph()
    print(failures == 0 ? "PASS  \(passes) checks" : "FAILED  \(failures) of \(passes + failures) checks")
    return failures == 0
  }

  private static let now = Date(timeIntervalSince1970: 1_795_000_000)

  private static func ranking() {
    let soon = TaskItem(title: "Due soon", deadline: now.addingTimeInterval(2 * 3600), importance: 0.5, firstSeen: now)
    let someday = TaskItem(title: "Someday", importance: 0.6, firstSeen: now)
    var snoozed = TaskItem(title: "Snoozed", importance: 1, firstSeen: now)
    snoozed.snoozeUntil = now.addingTimeInterval(600)
    var finished = TaskItem(title: "Finished", importance: 1, firstSeen: now)
    finished.status = .done

    let ranked = Ranker.ranked([someday, snoozed, finished, soon], now: now)
    check(ranked.map(\.title) == ["Due soon", "Someday"], "ranking: deadline outranks, snoozed and done are left out")
    check(Ranker.urgency(deadline: now.addingTimeInterval(-60), now: now) == 35, "ranking: overdue is maximum urgency")
    check(Ranker.urgency(deadline: nil, now: now) == 0, "ranking: no deadline, no urgency")

    let ratings = Ranker.elo(winner: 1000, loser: 1000)
    check(abs(ratings.winner - 1016) < 0.001 && abs(ratings.loser - 984) < 0.001, "elo: even match moves 16 points")

    var picked = someday
    picked.rating = ratings.winner + 300
    check(Ranker.score(picked, now: now) > Ranker.score(soon, now: now), "ranking: repeated picks can lift a task past a deadline")

    let pair = Ranker.pairToCompare([soon, someday], now: now)
    check(pair?.0.title == "Due soon" && pair?.1.title == "Someday", "ranking: pair to compare comes from the top")
    check(Ranker.pairToCompare([soon], now: now) == nil, "ranking: no pair with one task")
    check(Ranker.deadlineText(now.addingTimeInterval(5 * 3600), now: now) == "due in 5 h", "ranking: deadline text")
  }

  private static func feed() {
    check(Feed.wrap(7, count: 7) == 0 && Feed.wrap(-1, count: 7) == 6 && Feed.wrap(3, count: 7) == 3, "feed: scrolling past either end comes back round")
    check(Feed.wrap(5, count: 0) == 0 && Feed.wrap(-15, count: 7) == 6, "feed: empty lists and long jumps are safe")

    var trackpad = ScrollStepper()
    let first = trackpad.feed(deltaY: -12, precise: true, momentum: false, now: now)
    let second = trackpad.feed(deltaY: -12, precise: true, momentum: false, now: now)
    let third = trackpad.feed(deltaY: -12, precise: true, momentum: false, now: now)
    check(first == 0 && second == 0 && third == 1, "feed: a trackpad swipe moves one card once it has travelled far enough")
    var coasting = 0
    for _ in 0..<50 { coasting += trackpad.feed(deltaY: -20, precise: true, momentum: true, now: now.addingTimeInterval(1)) }
    check(coasting == 0, "feed: coasting after the fingers lift moves nothing")

    var fast = ScrollStepper()
    var steps = 0
    for tick in 0..<20 { steps += fast.feed(deltaY: -30, precise: true, momentum: false, now: now.addingTimeInterval(Double(tick) * 0.01)) }
    check(steps == 1, "feed: one fast swipe cannot fly through the list")
    check(fast.feed(deltaY: -30, precise: true, momentum: false, now: now.addingTimeInterval(0.5)) == 1, "feed: the next swipe moves again")

    var wheel = ScrollStepper()
    check(wheel.feed(deltaY: -1, precise: false, momentum: false, now: now) == 1, "feed: one mouse-wheel notch down is the next card")
    check(wheel.feed(deltaY: 1, precise: false, momentum: false, now: now.addingTimeInterval(1)) == -1, "feed: one notch up is the previous card")

    var reversed = ScrollStepper()
    _ = reversed.feed(deltaY: -25, precise: true, momentum: false, now: now)
    check(reversed.feed(deltaY: 10, precise: true, momentum: false, now: now) == 0 && reversed.accumulated == 10, "feed: changing direction starts the count again")
    reversed.gestureEnded()
    check(reversed.accumulated == 0, "feed: a finished gesture leaves nothing behind")
  }

  private static func nudging() {
    var tracker = NudgeTracker()
    var fired = 0
    for _ in 0..<59 where tracker.observe(distracting: true, interval: 5, threshold: 300, now: now) { fired += 1 }
    check(fired == 0, "nudge: quiet before the threshold")
    check(tracker.observe(distracting: true, interval: 5, threshold: 300, now: now), "nudge: fires at the threshold")
    check(tracker.distractedSeconds == 0, "nudge: counter restarts after firing")

    var never = NudgeTracker()
    var neverFired = false
    for _ in 0..<1000 where never.observe(distracting: true, interval: 5, threshold: nil, now: now) { neverFired = true }
    check(!neverFired, "nudge: pure dopamine mode never fires")

    var brief = NudgeTracker()
    for _ in 0..<40 { _ = brief.observe(distracting: true, interval: 5, threshold: 300, now: now) }
    for _ in 0..<6 { _ = brief.observe(distracting: false, interval: 5, threshold: 300, now: now) }
    check(brief.distractedSeconds == 200, "nudge: a 30 second tab-out does not reset the count")
    for _ in 0..<18 { _ = brief.observe(distracting: false, interval: 5, threshold: 300, now: now) }
    check(brief.distractedSeconds == 0, "nudge: 90 seconds away resets the count")

    var screen = StillnessTracker()
    check(!screen.isStill(now: now), "stillness: nothing is still before the screen has been checked")
    screen.sawNoChange(now: now)
    screen.sawNoChange(now: now.addingTimeInterval(60))
    check(!screen.isStill(now: now.addingTimeInterval(119)) && screen.isStill(now: now.addingTimeInterval(120)), "stillness: two unchanged minutes count as still, measured from the first unchanged check")
    screen.sawChange()
    check(!screen.isStill(now: now.addingTimeInterval(500)), "stillness: any change on screen ends it")
    screen.sawNoChange(now: now)
    screen.couldNotCheck()
    check(!screen.isStill(now: now.addingTimeInterval(500)), "stillness: not being able to check is never treated as still")

    // A paused video: on a scrolling app, but still. Those samples count as calm and the timer resets.
    var pausedVideo = NudgeTracker()
    var pausedFired = false
    for _ in 0..<50 { _ = pausedVideo.observe(distracting: true, interval: 5, threshold: 300, now: now) }
    for _ in 0..<200 where pausedVideo.observe(distracting: false, interval: 5, threshold: 300, now: now) { pausedFired = true }
    check(!pausedFired && pausedVideo.distractedSeconds == 0, "stillness: a still screen never fires a nudge and clears the timer")

    var muted = NudgeTracker()
    muted.mute(for: 600, now: now)
    var mutedFired = false
    for _ in 0..<100 where muted.observe(distracting: true, interval: 5, threshold: 300, now: now.addingTimeInterval(300)) { mutedFired = true }
    check(!mutedFired, "nudge: muted while snoozed")
    check(muted.observe(distracting: true, interval: 5, threshold: 300, now: now.addingTimeInterval(601)), "nudge: fires again once the snooze ends")
  }

  private static func frames() {
    let picks = FrameMath.keyFrames(Array(0..<60), max: 12)
    check(picks.count == 12 && picks.first == 0 && picks.last == 59, "frames: 12 key frames spanning the window")
    check(zip(picks, picks.dropFirst()).allSatisfy { $0 < $1 }, "frames: key frames are in order without repeats")
    check(FrameMath.keyFrames([1, 2, 3], max: 12) == [1, 2, 3], "frames: short windows are kept whole")
    let flat = [UInt8](repeating: 100, count: 256)
    var changed = flat
    for index in 0..<128 { changed[index] = 140 }
    check(FrameMath.difference(flat, flat) == 0, "frames: identical thumbnails differ by zero")
    check(FrameMath.difference(flat, changed) == 20, "frames: difference is the mean absolute change")
  }

  private static func deadlines() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let endOfDay = DeadlineParser.parse("2026-11-25", calendar: calendar)
    let parts = endOfDay.map { calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
    check(parts?.day == 25 && parts?.hour == 23 && parts?.minute == 59, "deadline: a bare date means end of that day")
    let fivePM = DeadlineParser.parse("2026-11-25T17:00", calendar: calendar)
    check(fivePM.map { calendar.component(.hour, from: $0) } == 17, "deadline: local date-time")
    check(DeadlineParser.parse("2026-11-25T22:00:00Z") == Date(timeIntervalSince1970: 1_795_644_000), "deadline: ISO with zone")
    check(DeadlineParser.parse("") == nil && DeadlineParser.parse("next Friday-ish") == nil, "deadline: empty and unreadable give nil")
  }

  private static func keywords() {
    let words = Keywords.parse(Keywords.defaultDistracting)
    let video = ActivitySample(app: "Google Chrome", bundleID: "", title: "lofi beats - YouTube", url: "")
    let code = ActivitySample(app: "Xcode", bundleID: "", title: "Ranker.swift", url: "")
    check(Keywords.matches(video, words), "keywords: a YouTube tab counts as scrolling")
    check(!Keywords.matches(code, words), "keywords: an editor does not")
    let vault = ActivitySample(app: "1Password", bundleID: "", title: "Vault", url: "")
    check(Keywords.matches(vault, Keywords.parse(Keywords.defaultExcluded)), "keywords: password manager is excluded from capture")
  }

  private static func storage() {
    guard let store = try? Store.inMemory() else { return check(false, "storage: open in-memory store") }

    var task = TaskItem(title: "Write 440 report", deadline: now.addingTimeInterval(3600), importance: 0.9, firstSeen: now, lastSeen: now)
    task.url = "https://example.edu/assignments/3"
    store.save(task)
    check(store.task(id: task.id) == task, "storage: a task reads back unchanged")
    task.status = .dismissed
    store.save(task)
    check(store.tasks(status: .open).isEmpty && store.tasks(status: .dismissed).count == 1, "storage: status changes persist")
    check(store.recentlyClosed(since: now.addingTimeInterval(-60)).map(\.id) == [task.id], "storage: dismissed tasks are remembered")

    let doc = ActivitySample(app: "Pages", bundleID: "com.apple.iWork.Pages", title: "Report", url: "")
    for step in 0..<3 {
      store.logActivity(doc, distracting: false, now: now.addingTimeInterval(Double(step) * 5), interval: 5)
    }
    check(store.activityCount() == 1, "storage: one window in front stays one activity row")
    var other = doc
    other.title = "Notes"
    store.logActivity(other, distracting: false, now: now.addingTimeInterval(15), interval: 5)
    check(store.activityCount() == 2, "storage: a new window starts a new row")
    let summary = store.activitySummary(from: now, to: now.addingTimeInterval(20), sampleInterval: 5)
    check(summary.first?.title == "Report" && summary.first?.seconds == 15, "storage: activity summary adds up time")
    check(store.bundleID(forApp: "pages") == "com.apple.iWork.Pages", "storage: bundle id found by app name")

    store.addFrameRecord(ts: now, path: "/nonexistent/a.jpg", app: "Pages", title: "Report")
    store.addFrameRecord(ts: now.addingTimeInterval(10), path: "/nonexistent/b.jpg", app: "Pages", title: "Report")
    let pending = store.pendingFrames()
    check(pending.count == 2, "storage: frames wait to be read")
    store.markAnalyzed([pending[0].id])
    check(store.pendingFrameCount() == 1, "storage: read frames leave the queue")
    check(store.deleteFrames(before: now.addingTimeInterval(5)) == 1, "storage: old frames are deleted")

    store.addUsage(model: ClaudeClient.haiku, input: 1_000_000, output: 100_000, now: now)
    store.addUsage(model: ClaudeClient.haiku, input: 1_000_000, output: 100_000, now: now)
    let usage = store.usage(on: now)
    check(usage.first?.inputTokens == 2_000_000 && abs((usage.first?.cost ?? 0) - 0.30) < 0.0001, "storage: usage accumulates and prices correctly")

    store.setValue("mode", "lockIn")
    check(store.value("mode") == "lockIn" && store.value("missing") == nil, "storage: settings round-trip")
    store.logEvent("done", taskID: task.id, context: ["mode": "balanced"], now: now)
    check(store.eventCount(kind: "done") == 1, "storage: events are logged")
  }

  private static func operation(_ op: String, id: String = "", title: String = "", why: String = "", deadline: String = "", app: String = "") -> MergeResult.Operation {
    MergeResult.Operation(
      op: op, taskId: id, title: title, detail: "", why: why, deadline: deadline, waitingPerson: "",
      url: "", sourceApp: app, importance: 0.8, estMinutes: 30, reason: "test")
  }

  private static func merging() {
    guard let store = try? Store.inMemory() else { return check(false, "merging: open in-memory store") }
    store.logActivity(ActivitySample(app: "Mail", bundleID: "com.apple.mail", title: "Inbox", url: ""), distracting: false, now: now, interval: 5)

    var tally = TaskMerging.apply([
      operation("create", title: "Reply to Maya", why: "She asked yesterday", deadline: "2026-11-25", app: "Mail"),
      operation("create", title: "   "),
      operation("update", id: "no-such-task", title: "Ghost"),
      operation("ignore"),
    ], to: store, now: now)
    check(tally == MergeTally(created: 1, updated: 0, completed: 0, ignored: 3), "merging: creates real tasks and skips blanks and unknown ids")
    guard let created = store.tasks(status: .open).first else { return check(false, "merging: created task exists") }
    check(created.deadline != nil && created.bundleID == "com.apple.mail" && created.importance == 0.8, "merging: new task carries deadline, app and importance")

    tally = TaskMerging.apply([operation("update", id: created.id, why: "Second time you've opened it")], to: store, now: now.addingTimeInterval(600))
    let updated = store.task(id: created.id)
    check(tally.updated == 1 && updated?.seenCount == 2 && updated?.why == "Second time you've opened it" && updated?.title == "Reply to Maya", "merging: a repeat sighting updates the same task")

    tally = TaskMerging.apply([operation("complete", id: created.id)], to: store, now: now.addingTimeInterval(1200))
    check(tally.completed == 1 && store.task(id: created.id)?.status == .done, "merging: a seen completion closes the task")
    tally = TaskMerging.apply([operation("update", id: created.id, title: "Back again")], to: store, now: now)
    check(tally.ignored == 1 && store.task(id: created.id)?.status == .done, "merging: closed tasks are not reopened")
  }

  /// Structured outputs need every object to forbid extra keys and list all of its keys as required.
  private static func schemaIsStrict(_ schema: [String: Any]) -> Bool {
    if schema["type"] as? String == "object" {
      guard schema["additionalProperties"] as? Bool == false,
        let properties = schema["properties"] as? [String: Any],
        let required = schema["required"] as? [String], Set(required) == Set(properties.keys)
      else { return false }
      return properties.values.allSatisfy { ($0 as? [String: Any]).map(schemaIsStrict) ?? false }
    }
    if schema["type"] as? String == "array" {
      return (schema["items"] as? [String: Any]).map(schemaIsStrict) ?? false
    }
    return schema["type"] is String
  }

  private static func claudeRequests() {
    check(schemaIsStrict(Schema.extraction) && schemaIsStrict(Schema.merge) && schemaIsStrict(Schema.entities), "claude: all three schemas are strict")

    let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "AAAA"]]
    let haiku = ClaudeClient.body(model: ClaudeClient.haiku, system: "s", content: [image], schema: Schema.extraction, effort: "low")
    let sonnet = ClaudeClient.body(model: ClaudeClient.sonnet, system: "s", content: [["type": "text", "text": "{}"]], schema: Schema.merge, effort: "medium")
    check(JSONSerialization.isValidJSONObject(haiku) && JSONSerialization.isValidJSONObject(sonnet), "claude: request bodies serialise to JSON")
    check(haiku["model"] as? String == "claude-haiku-5-5" && sonnet["model"] as? String == "claude-sonnet-5-5", "claude: Haiku reads, Sonnet merges")

    let format = (haiku["output_config"] as? [String: Any])?["format"] as? [String: Any]
    check(format?["type"] as? String == "json_schema" && format?["schema"] != nil, "claude: JSON output is requested through output_config.format")
    check(haiku["temperature"] == nil && haiku["top_p"] == nil && haiku["thinking"] == nil && haiku["tool_choice"] == nil, "claude: no sampling, thinking or forced-tool parameters")
    check(haiku["fallbacks"] == nil && sonnet["fallbacks"] as? String == "default", "claude: fallback only on Sonnet")

    let haikuRequest = ClaudeClient.request(model: ClaudeClient.haiku, apiKey: "test-key", body: Data())
    let sonnetRequest = ClaudeClient.request(model: ClaudeClient.sonnet, apiKey: "test-key", body: Data())
    check(haikuRequest.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21" && haikuRequest.value(forHTTPHeaderField: "x-api-key") == "test-key", "claude: version and key headers")
    check(haikuRequest.value(forHTTPHeaderField: "anthropic-beta") == nil && sonnetRequest.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01", "claude: fallback beta header only on Sonnet")
    check(haikuRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages" && haikuRequest.httpMethod == "POST", "claude: posts to the Messages API")
  }

  private static func claudeReplies() {
    let reply = """
      {"type":"message","model":"claude-haiku-5-5","stop_reason":"end_turn",
       "content":[{"type":"thinking","thinking":"","signature":"x"},{"type":"text","text":"{\\"ok\\":true}"}],
       "usage":{"input_tokens":1200,"output_tokens":80}}
      """
    let parsed = try? ClaudeClient.parse(data: Data(reply.utf8), status: 200)
    check(parsed == ClaudeResponse(text: "{\"ok\":true}", inputTokens: 1200, outputTokens: 80), "claude: text is read past a leading thinking block")

    func failure(_ json: String, status: Int = 200) -> ClaudeError? {
      do {
        _ = try ClaudeClient.parse(data: Data(json.utf8), status: status)
        return nil
      } catch { return error as? ClaudeError }
    }
    check(failure(#"{"stop_reason":"refusal","stop_details":{"category":"general_harms"},"content":[]}"#) == .refusal("general_harms"), "claude: a refusal is reported, not decoded")
    check(failure(#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"{"}]}"#) == .truncated, "claude: a cut-off reply is an error")
    check(failure(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401) == .http(401, "invalid x-api-key"), "claude: API errors carry their message")
    check(ClaudeClient.isRetryable(429) && ClaudeClient.isRetryable(529) && !ClaudeClient.isRetryable(400), "claude: only rate limits and server errors retry")
  }

  private static let extractionFixture = """
    {"summary":"Reading a course page, then watching a talk.",
     "activities":[{"app":"Chrome","title":"15-440 P3","description":"Reading the handout","category":"study"}],
     "commitments":[
       {"title":"Submit P3 checkpoint","detail":"Checkpoint due Friday","evidence":"Due Fri 11:59pm","source_app":"Chrome","url":"https://example.edu/p3","deadline":"2026-11-27T23:59","waiting_person":"","confidence":"high","is_users_own":true},
       {"title":"Try this productivity hack","detail":"From an article","evidence":"Headline","source_app":"Chrome","url":"","deadline":"","waiting_person":"","confidence":"high","is_users_own":false},
       {"title":"Maybe email someone","detail":"Unclear","evidence":"Blurry","source_app":"Mail","url":"","deadline":"","waiting_person":"","confidence":"low","is_users_own":true}],
     "completions":[{"description":"Sent reply to TA","evidence":"Message sent banner"}],
     "content":[{"title":"Raft explained","source":"YouTube","url":"","kind":"video","topic":"distributed consensus"}]}
    """

  private static func decoding() {
    let extraction = try? JSONCoding.decoder.decode(Extraction.self, from: Data(extractionFixture.utf8))
    check(extraction?.commitments.count == 3 && extraction?.content.first?.topic == "distributed consensus", "decoding: the reading model's JSON decodes")
    check(extraction?.actionableCommitments.map(\.title) == ["Submit P3 checkpoint"], "decoding: other people's jobs and low-confidence guesses are dropped")

    let merge = #"{"operations":[{"op":"create","task_id":"","title":"Submit P3 checkpoint","detail":"d","why":"Due Friday night","deadline":"2026-11-27T23:59","waiting_person":"","url":"https://example.edu/p3","source_app":"Chrome","importance":0.9,"est_minutes":120,"reason":"new"}]}"#
    let result = try? JSONCoding.decoder.decode(MergeResult.self, from: Data(merge.utf8))
    check(result?.operations.first?.estMinutes == 120 && result?.operations.first?.taskId == "", "decoding: the merging model's JSON decodes")

    if let extraction, let data = try? JSONCoding.encoder.encode(extraction) {
      check((try? JSONCoding.decoder.decode(Extraction.self, from: data)) == extraction, "decoding: observations survive being stored and reloaded")
    } else {
      check(false, "decoding: observations survive being stored and reloaded")
    }
  }

  private static func analyzerInputs() {
    let frames = (0..<5).map { FrameRecord(id: Int64($0), ts: now.addingTimeInterval(Double($0) * 200), path: "", app: "", title: "") }
    check(Analyzer.nextWindow(pending: frames, now: now.addingTimeInterval(300), force: false) == nil, "analyzer: waits for a full ten minutes")
    check(Analyzer.nextWindow(pending: frames, now: now.addingTimeInterval(601), force: false)?.count == 4, "analyzer: takes one ten-minute window at a time")
    check(Analyzer.nextWindow(pending: frames, now: now.addingTimeInterval(300), force: true)?.count == 4, "analyzer: can be forced early")
    check(Analyzer.nextWindow(pending: [], now: now, force: true) == nil, "analyzer: nothing to do with no frames")

    guard let store = try? Store.inMemory(),
      let extraction = try? JSONCoding.decoder.decode(Extraction.self, from: Data(extractionFixture.utf8))
    else { return check(false, "analyzer: fixtures load") }
    let analyzer = Analyzer(store: store)
    var dismissed = TaskItem(title: "Old thing", firstSeen: now, lastSeen: now)
    dismissed.status = .dismissed
    store.save(dismissed)

    let input = analyzer.mergeInput(extraction, now: now) ?? ""
    check(input.contains("Submit P3 checkpoint") && !input.contains("productivity hack"), "analyzer: only actionable commitments reach Sonnet")
    check(input.contains("Old thing") && input.contains("dismissed"), "analyzer: dismissed tasks are sent so they are not recreated")
    check(!input.contains("Sent reply to TA"), "analyzer: completions are dropped when there are no open tasks to close")

    var quiet = extraction
    quiet.commitments = []
    check(analyzer.mergeInput(quiet, now: now) == nil, "analyzer: Sonnet is not called when nothing changed")
    check(analyzer.extractionContent(for: frames, now: now).isEmpty, "analyzer: no request when the screenshots are gone")
    check(extraction.entities == nil && analyzer.unknownMentions(extraction).isEmpty, "analyzer: readings stored before entities existed still load and need no indexing")
  }

  private static func mention(_ name: String, _ kind: String, _ context: String = "worked on it") -> Extraction.Mention {
    Extraction.Mention(name: name, kind: kind, context: context)
  }

  private static func decision(_ mention: String, _ kind: String, _ choice: String, id: String = "", name: String = "", summary: String = "") -> EntityDecisions.Decision {
    EntityDecisions.Decision(mention: mention, kind: kind, decision: choice, entityId: id, name: name, summary: summary, reason: "test")
  }

  private static func knowledgeGraph() {
    check(EntityMatching.normalize("15-440: P3") == "15 440 p3" && EntityMatching.normalize("  ") == "", "graph: names are normalised")

    guard let store = try? Store.inMemory() else { return check(false, "graph: open in-memory store") }
    check((try? store.migrate()) != nil, "graph: migration can run again safely")

    let project = Entity(kind: .project, name: "15-440 Project 3", aliases: ["p3-raft"], summary: "Raft in Go", firstSeen: now, lastSeen: now)
    store.save(project)
    check(store.entity(id: project.id) == project, "graph: an entry reads back unchanged")
    check(store.matchEntity(kind: .project, name: "15 440 project 3")?.id == project.id, "graph: matches by name without a model")
    check(store.matchEntity(kind: .project, name: "P3 Raft")?.id == project.id, "graph: matches by alias")
    check(store.matchEntity(kind: .topic, name: "15-440 Project 3") == nil, "graph: kinds are kept apart")

    let asked = [mention("440 P3", "project"), mention("Maya Chen", "person"), mention("YouTube", "topic"), mention("Ghost", "project")]
    let tally = EntityResolution.apply([
      decision("440 P3", "project", "same_as", id: project.id),
      decision("Maya Chen", "person", "new", name: "Maya Chen", summary: "Project partner"),
      decision("YouTube", "topic", "ignore"),
      decision("Ghost", "project", "same_as", id: "no-such-id"),
      decision("Never asked", "project", "new", name: "Injected"),
    ], asked: asked, to: store, now: now)
    check(tally == EntityTally(created: 1, aliased: 1, ignored: 1, skipped: 2), "graph: decisions create, alias and ignore; bad ids and unasked names are skipped")
    check(store.entity(id: project.id)?.aliases == ["p3-raft", "440 P3"], "graph: a second name becomes an alias")
    check(store.entities(kind: .topic).isEmpty && store.matchEntity(kind: .topic, name: "youtube")?.ignored == true, "graph: ignored names are remembered but hidden")
    check(store.matchEntity(kind: .project, name: "Injected") == nil, "graph: nothing is created for a name that was not asked about")
    guard let maya = store.matchEntity(kind: .person, name: "maya chen") else { return check(false, "graph: new person exists") }

    let seen = [mention("440 P3", "project", "Debugged leader election"), mention("Maya Chen", "person", "Messaged about the checkpoint"), mention("YouTube", "topic")]
    EntityResolution.recordSightings(seen, observationID: 1, at: now, in: store)
    EntityResolution.recordSightings(seen, observationID: 1, at: now, in: store)
    check(store.entity(id: project.id)?.seenCount == 1, "graph: one sighting per reading, however often it is recorded")
    EntityResolution.recordSightings(seen, observationID: 2, at: now.addingTimeInterval(600), in: store)
    check(store.entity(id: project.id)?.seenCount == 2 && store.sightings(entityID: project.id).first?.context == "Debugged leader election", "graph: sightings keep what you were doing")
    let links = store.links(entityID: project.id)
    check(links.count == 1 && links.first?.entity.id == maya.id && links.first?.weight == 2, "graph: things seen together are linked, and ignored names are not")

    TaskMerging.apply([
      MergeResult.Operation(op: "create", taskId: "", title: "Submit P3 checkpoint", detail: "", why: "", deadline: "", waitingPerson: "", url: "", sourceApp: "", importance: 0.9, estMinutes: 60, reason: "test", project: "440 p3"),
      MergeResult.Operation(op: "create", taskId: "", title: "Buy groceries", detail: "", why: "", deadline: "", waitingPerson: "", url: "", sourceApp: "", importance: 0.3, estMinutes: 30, reason: "test", project: "Unknown project"),
    ], to: store, now: now)
    check(store.tasks(projectID: project.id).map(\.title) == ["Submit P3 checkpoint"], "graph: a task links to its project through an alias")
    check(store.tasks(status: .open).first { $0.title == "Buy groceries" }?.projectID == "", "graph: an unknown project name links to nothing")

    let analyzer = Analyzer(store: store)
    let json = #"{"summary":"s","activities":[],"completions":[],"content":[],"commitments":[{"title":"Submit P3 checkpoint","detail":"d","evidence":"e","source_app":"Chrome","url":"","deadline":"","waiting_person":"","confidence":"high","is_users_own":true,"project":"440 P3"}],"entities":[{"name":"p3-raft","kind":"project","context":"c"},{"name":"Raft paper","kind":"document","context":"Read section 5"},{"name":"raft  PAPER","kind":"document","context":"dup"},{"name":"Thing","kind":"gadget","context":"bad kind"}]}"#
    guard let extraction = try? JSONCoding.decoder.decode(Extraction.self, from: Data(json.utf8)) else { return check(false, "graph: reading with entities decodes") }
    check(extraction.commitments.first?.project == "440 P3" && extraction.entities?.count == 4, "graph: a reading with entities decodes")
    let unknown = analyzer.unknownMentions(extraction)
    check(unknown.map(\.name) == ["Raft paper"], "graph: only names not already known go to Sonnet")
    let input = analyzer.entityInput(unknown: unknown) ?? ""
    check(input.contains("Raft paper") && input.contains("15-440 Project 3") && input.contains(project.id), "graph: Sonnet sees the new name and the existing entries")
    check(!input.contains("YouTube"), "graph: ignored names are not offered as merge targets")
    check(analyzer.entityInput(unknown: []) == nil, "graph: no Sonnet call when every name is known")
    check((analyzer.mergeInput(extraction, now: now) ?? "").contains("\"project\" : \"440 P3\""), "graph: the task merge is told which project a commitment belongs to")

    let decisions = #"{"decisions":[{"mention":"Raft paper","kind":"document","decision":"new","entity_id":"","name":"In Search of an Understandable Consensus Algorithm","summary":"The Raft paper","reason":"r"}]}"#
    let decoded = try? JSONCoding.decoder.decode(EntityDecisions.self, from: Data(decisions.utf8))
    check(decoded?.decisions.first?.entityId == "" && decoded?.decisions.first?.decision == "new", "graph: Sonnet's decisions decode")

    var removed = maya
    removed.ignored = true
    store.save(removed)
    check(store.links(entityID: project.id).isEmpty && store.entities(kind: .person).isEmpty, "graph: a removed entry disappears from lists and links")
  }
}
