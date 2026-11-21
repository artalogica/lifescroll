import AppKit
import SwiftUI
import UserNotifications

struct ComparePair: Equatable {
  let a: TaskItem
  let b: TaskItem
}

/// Ties the loops, the store and the UI together. Everything here runs on the main actor.
@MainActor
final class AppModel: ObservableObject {
  static let shared = AppModel()

  static let activityInterval: TimeInterval = 5
  static let captureInterval: TimeInterval = 10
  static let frameRetention: TimeInterval = 3 * 86_400
  static let notNowSnooze: TimeInterval = 3 * 3600

  let store: Store
  let analyzer: Analyzer
  let recommender: Recommender

  /// Open tasks in rank order.
  @Published var ranked: [TaskItem] = []
  /// What the popover scrolls through: tasks and suggestions, blended by mode.
  @Published var feed: [FeedItem] = []
  @Published var findingSuggestions = false
  @Published var suggestionNote = ""
  @Published var cardIndex = 0
  /// Direction of the last scroll, so the next card slides in from the right side.
  @Published var scrollStep = 1
  @Published var mode: Mode = .balanced
  @Published var paused = false
  @Published var lastError: String?
  @Published var hasAPIKey = false
  @Published var screenPermission = false
  @Published var accessibilityPermission = false
  @Published var comparePair: ComparePair?
  @Published var usage: [UsageRow] = []
  @Published var current = ActivitySample()
  @Published var analyzing = false
  @Published var pendingFrames = 0
  @Published var lastRead: Date?
  @Published var lastSummary = ""
  @Published var distractingKeywords = Keywords.defaultDistracting
  @Published var excludedKeywords = Keywords.defaultExcluded
  /// Project names by id, for labelling and grouping tasks.
  @Published var projectNames: [String: String] = [:]

  private var tracker = NudgeTracker()
  private var stillness = StillnessTracker()
  private var textSchedule = TextSchedule()
  private var timers: [Timer] = []
  private var lastSignature: [UInt8]?
  private var lastCompare = Date.distantPast
  private var capturing = false
  private var currentHidden = false
  private var started = false
  private var tick = 0

  /// The app uses `shared`, which opens the real database. A store can be passed in to build a model
  /// over sample data, which is how `--render-ui` draws the interface without touching real data.
  init(store injected: Store? = nil) {
    let opened: Store
    if let injected {
      opened = injected
    } else {
      do {
        opened = try Store.openDefault()
      } catch {
        // Keep the app usable even if the file cannot be opened; nothing persists in this case.
        opened = try! Store.inMemory()
        lastError = "Could not open the database, so nothing will be saved: \(error.localizedDescription)"
      }
    }
    store = opened
    analyzer = Analyzer(store: opened, sampleInterval: Self.activityInterval)
    recommender = Recommender(store: opened)
    mode = Mode(rawValue: opened.value("mode") ?? "") ?? .balanced
    paused = opened.value("paused") == "1"
    distractingKeywords = opened.value("distracting") ?? Keywords.defaultDistracting
    excludedKeywords = opened.value("excluded") ?? Keywords.defaultExcluded
  }

  // MARK: - Lifecycle

  func start() {
    guard !started else { return }
    started = true
    loadAPIKey()
    refreshPermissions()
    reload()
    if !screenPermission { ScreenCapturer.requestPermission() }
    Notifier.shared.configure()

    schedule(every: Self.activityInterval) { $0.activityTick() }
    schedule(every: Self.captureInterval) { $0.captureTick() }
    schedule(every: 60) { $0.analysisTick(force: false) }
    schedule(every: 600) { $0.suggestionsTick(force: false) }
    schedule(every: 3600) { $0.maintenance() }
    maintenance()
  }

  private func schedule(every interval: TimeInterval, _ action: @escaping @MainActor (AppModel) -> Void) {
    // The model is a singleton that lives as long as the app, so the timers reach it through `shared`.
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
      Task { @MainActor in action(AppModel.shared) }
    }
    RunLoop.main.add(timer, forMode: .common)
    timers.append(timer)
  }

  func refreshPermissions() {
    screenPermission = ScreenCapturer.hasPermission
    accessibilityPermission = ActivityMonitor.hasAccessibilityPermission
  }

  private func maintenance() {
    store.deleteFrames(before: Date().addingTimeInterval(-Self.frameRetention))
    store.compact()
    pendingFrames = store.pendingFrameCount()
  }

  // MARK: - Settings

  func setMode(_ newMode: Mode) {
    mode = newMode
    store.setValue("mode", newMode.rawValue)
    store.logEvent("mode_changed", context: ["mode": newMode.rawValue])
    // The mode decides how tasks and suggestions are blended, so the feed is rebuilt and shown from
    // the top. The reset comes after the reload, which would otherwise follow the old card.
    reload()
    cardIndex = 0
    suggestionsTick(force: false)
  }

  func setPaused(_ flag: Bool) {
    paused = flag
    store.setValue("paused", flag ? "1" : "0")
  }

  func saveKeywords() {
    store.setValue("distracting", distractingKeywords)
    store.setValue("excluded", excludedKeywords)
  }

  private func loadAPIKey() {
    let key = Keychain.read()
    KeyBox.shared.value = key
    hasAPIKey = !(key ?? "").isEmpty
  }

  func saveAPIKey(_ key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if Keychain.save(trimmed) {
      KeyBox.shared.value = trimmed
      hasAPIKey = true
      lastError = nil
    } else {
      lastError = "Could not save the API key to the Keychain."
    }
  }

  func removeAPIKey() {
    Keychain.delete()
    KeyBox.shared.value = nil
    hasAPIKey = false
  }

  // MARK: - Fast loop

  private func activityTick() {
    tick += 1
    if tick % 6 == 0 { refreshPermissions() }
    guard !paused, !ScreenCapturer.isScreenLocked,
      var sample = ActivityMonitor.currentSample(),
      sample.bundleID != Bundle.main.bundleIdentifier
    else { return }

    let hidden = Keywords.matches(sample, Keywords.parse(excludedKeywords))
    if hidden {
      sample.title = "(hidden)"
      sample.url = ""
    }
    currentHidden = hidden
    current = sample

    let now = Date()
    // A screen that has not changed for two minutes is not scrolling, so it stops feeding the nudge
    // timer; after 90 seconds more the timer resets, the same as switching to something else.
    let distracting =
      !hidden && !stillness.isStill(now: now)
      && Keywords.matches(sample, Keywords.parse(distractingKeywords))
    store.logActivity(sample, distracting: distracting, now: now, interval: Self.activityInterval)
    if tracker.observe(
      distracting: distracting, interval: Self.activityInterval, threshold: mode.nudgeAfter, now: now)
    {
      sendNudge(for: sample, minutes: Int((mode.nudgeAfter ?? 0) / 60))
    }
  }

  // MARK: - Slow loop

  /// Whether the window in front right now matches a "never capture" word. This asks the system
  /// afresh each time; the sample from the 5-second activity loop can be several seconds stale.
  private func frontWindowIsPrivate(_ excluded: [String]) -> Bool {
    guard let front = ActivityMonitor.currentSample() else { return false }
    return Keywords.matches(front, excluded)
  }

  private func captureTick() {
    guard !capturing else { return }
    let excluded = Keywords.parse(excludedKeywords)
    guard !paused, screenPermission, !ScreenCapturer.isScreenLocked, !currentHidden,
      !frontWindowIsPrivate(excluded)
    else {
      stillness.couldNotCheck()
      return
    }
    capturing = true
    let displayID = ScreenCapturer.activeDisplayID()
    // Label the frame with the window in front now. When that is Lifescroll's own popover, which is
    // left out of the picture, keep the last window the activity loop saw.
    let front = ActivityMonitor.currentSample()
    let sample = (front.flatMap { $0.bundleID == Bundle.main.bundleIdentifier ? nil : $0 }) ?? current
    // Text is read from about one screenshot every 30 seconds, and straight away for a new window.
    let window = "\(sample.app)|\(sample.title)"
    let readText = textSchedule.isDue(window: window, now: Date())
    Task {
      defer { capturing = false }
      do {
        let frame = try await ScreenCapturer.capture(displayID: displayID, excluding: excluded)
        // A repeat of the last saved screenshot costs nothing more: no scaling, encoding or reading.
        if let last = lastSignature, FrameMath.difference(last, frame.signature) < 1.5 {
          stillness.sawNoChange(now: Date())
          return
        }
        stillness.sawChange()
        // Something private may have come to the front while the capture was in flight.
        guard !frontWindowIsPrivate(excluded) else { return }
        lastSignature = frame.signature
        let capturedAt = Date()
        var text: String?
        if readText {
          // Recognised on this Mac, off the main thread, and masked before it is stored.
          text = Redactor.mask(await ScreenText.recognizeInBackground(frame.image))
          textSchedule.didRead(window: window, now: capturedAt)
          // Recognition takes a moment; check once more before anything is written.
          guard !frontWindowIsPrivate(excluded) else { return }
        }
        try store.saveFrame(
          jpeg: try ScreenCapturer.encode(frame.image), at: capturedAt, app: sample.app,
          title: sample.title, text: text)
        pendingFrames = store.pendingFrameCount()
      } catch {
        stillness.couldNotCheck()
        lastError = "Screen capture failed: \(error.localizedDescription)"
      }
    }
  }

  func analysisTick(force: Bool) {
    guard !analyzing, hasAPIKey else { return }
    if !force && paused { return }
    analyzing = true
    Task {
      let outcome = await analyzer.run(now: Date(), force: force)
      analyzing = false
      if let error = outcome.error {
        lastError = error
      } else if outcome.windows > 0 {
        lastError = nil
      }
      reload()
      // A fresh reading may have recorded new interests, so this is a good moment to top up.
      if outcome.windows > 0 { suggestionsTick(force: false) }
    }
  }

  // MARK: - Suggestions

  private func storedDate(_ key: String) -> Date? {
    store.value(key).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
  }

  func suggestionsTick(force: Bool) {
    guard !findingSuggestions, hasAPIKey else { return }
    // Lock in never shows suggestions, so even a forced search would be paid for and thrown away.
    guard mode != .lockIn else {
      if force { suggestionNote = "Lock in mode shows tasks only. Switch mode to get suggestions." }
      return
    }
    let now = Date()
    if !force {
      guard !paused,
        SuggestionSchedule.shouldFind(
          mode: mode, onHand: store.recommendations(status: "new").count,
          lastSuccess: storedDate("suggestions_last_success"),
          lastAttempt: storedDate("suggestions_last_attempt"), now: now)
      else { return }
    }
    findingSuggestions = true
    store.setValue("suggestions_last_attempt", String(now.timeIntervalSince1970))
    Task {
      let outcome = await recommender.refresh(now: now)
      findingSuggestions = false
      if let error = outcome.error {
        suggestionNote = "Could not find suggestions: \(error)"
      } else {
        store.setValue("suggestions_last_success", String(now.timeIntervalSince1970))
        suggestionNote =
          outcome.added > 0
          ? "Added \(outcome.added) from \(outcome.candidates) found."
          : (outcome.candidates > 0 ? "Found \(outcome.candidates), none worth showing." : "Nothing new found.")
      }
      reload()
    }
  }

  func openSuggestion(_ suggestion: Recommendation) {
    // Only a link that really opened counts as "opened", because that is fed back as a sign of interest.
    if let url = suggestion.webURL, NSWorkspace.shared.open(url) {
      store.logEvent("suggestion_opened", taskID: suggestion.id, context: context(for: suggestion))
      store.setRecommendationStatus(suggestion.id, "opened")
    } else {
      store.logEvent("suggestion_open_failed", taskID: suggestion.id, context: context(for: suggestion))
      store.setRecommendationStatus(suggestion.id, "expired")
      lastError = "That link could not be opened, so the suggestion was removed."
    }
    reload()
  }

  func dismissSuggestion(_ suggestion: Recommendation) {
    store.logEvent("suggestion_dismissed", taskID: suggestion.id, context: context(for: suggestion))
    store.setRecommendationStatus(suggestion.id, "dismissed")
    reload()
  }

  private func context(for suggestion: Recommendation) -> [String: String] {
    [
      "mode": mode.rawValue, "kind": suggestion.kind, "bucket": suggestion.bucket,
      "source": suggestion.source, "front_app": current.app,
    ]
  }

  /// Records that a card is on screen, or was scrolled past, whichever kind of card it is.
  private func log(_ event: String, _ item: FeedItem, wrapped: Bool = false) {
    switch item {
    case .task(let task):
      var details = context(for: task)
      if wrapped { details["wrapped"] = "1" }
      store.logEvent(event == "shown" ? "card_shown" : "scrolled_past", taskID: task.id, context: details)
    case .suggestion(let suggestion):
      var details = context(for: suggestion)
      if wrapped { details["wrapped"] = "1" }
      store.logEvent(
        event == "shown" ? "suggestion_shown" : "suggestion_scrolled_past", taskID: suggestion.id,
        context: details)
    }
  }

  // MARK: - Cards

  var currentItem: FeedItem? {
    guard feed.indices.contains(cardIndex) else { return feed.first }
    return feed[cardIndex]
  }

  var setupIssues: [String] {
    var issues: [String] = []
    if !screenPermission { issues.append("Screen Recording is off, so nothing is being read.") }
    if !hasAPIKey { issues.append("No Claude API key, so screenshots are saved but not read.") }
    if !accessibilityPermission && !screenPermission {
      issues.append("Accessibility is off, so window titles are missing.")
    }
    return issues
  }

  var statusLine: String {
    if paused { return "Paused" }
    if analyzing { return "Reading your last few minutes…" }
    if !screenPermission { return "Waiting for Screen Recording permission" }
    var parts = ["Watching"]
    if let lastRead {
      let minutes = Int(Date().timeIntervalSince(lastRead) / 60)
      parts.append(minutes < 1 ? "read just now" : "read \(minutes) min ago")
    }
    if pendingFrames > 0 { parts.append("\(pendingFrames) screenshots waiting") }
    if stillness.isStill(now: Date()) { parts.append("screen still, scrolling timer off") }
    return parts.joined(separator: " · ")
  }

  var menuIcon: String {
    if paused { return "pause.circle" }
    if !screenPermission || !hasAPIKey { return "exclamationmark.circle" }
    return "scroll"
  }

  func reload() {
    let now = Date()
    ranked = Ranker.ranked(store.tasks(status: .open), now: now)
    let onScreen = feed.indices.contains(cardIndex) ? feed[cardIndex].id : nil
    feed = Feed.mix(
      tasks: ranked, suggestions: store.recommendations(status: "new"), mode: mode)
    cardIndex = Feed.position(following: onScreen, in: feed, previous: cardIndex)
    usage = store.usage(on: now)
    pendingFrames = store.pendingFrameCount()
    projectNames = Dictionary(
      uniqueKeysWithValues: store.entities(kind: .project).map { ($0.id, $0.name) })
    if let observation = store.lastObservation() {
      lastRead = observation.end
      lastSummary = observation.summary
    }
  }

  func tasks(for status: TaskStatus) -> [TaskItem] {
    guard status == .open else { return store.tasks(status: status) }
    let now = Date()
    return store.tasks(status: .open).sorted { Ranker.score($0, now: now) > Ranker.score($1, now: now) }
  }

  private func context(for task: TaskItem? = nil) -> [String: String] {
    var context = ["mode": mode.rawValue, "front_app": current.app, "front_title": current.title]
    if let task, let position = ranked.firstIndex(where: { $0.id == task.id }) {
      context["position"] = String(position)
      context["score"] = String(format: "%.1f", Ranker.score(task, now: Date()))
    }
    return context
  }

  /// Called when the popover opens: start from the top card and maybe ask for one ranking pick.
  func popoverOpened() {
    reload()
    refreshPermissions()
    cardIndex = 0
    if let item = currentItem { log("shown", item) }
    if comparePair == nil, Date().timeIntervalSince(lastCompare) > 3600 { offerComparison() }
  }

  /// Moves through the feed. It loops, so scrolling past the last card brings the first one back.
  func scroll(by step: Int) {
    guard feed.count > 1, comparePair == nil, feed.indices.contains(cardIndex) else { return }
    let target = cardIndex + step
    let next = Feed.wrap(target, count: feed.count)
    guard next != cardIndex else { return }
    log("scrolled_past", feed[cardIndex], wrapped: !feed.indices.contains(target))
    scrollStep = step
    withAnimation(.easeOut(duration: 0.18)) { cardIndex = next }
    log("shown", feed[next])
  }

  func markDone(_ task: TaskItem) {
    store.logEvent("done", taskID: task.id, context: context(for: task))
    update(task) { $0.status = .done }
  }

  func notNow(_ task: TaskItem) {
    store.logEvent("not_now", taskID: task.id, context: context(for: task))
    update(task) { $0.snoozeUntil = Date().addingTimeInterval(Self.notNowSnooze) }
  }

  func never(_ task: TaskItem) {
    store.logEvent("never", taskID: task.id, context: context(for: task))
    update(task) { $0.status = .dismissed }
  }

  func reopen(_ task: TaskItem) {
    store.logEvent("reopened", taskID: task.id)
    update(task) {
      $0.status = .open
      $0.snoozeUntil = nil
    }
  }

  private func update(_ task: TaskItem, _ change: (inout TaskItem) -> Void) {
    var copy = task
    change(&copy)
    copy.lastSeen = Date()
    store.save(copy)
    reload()
  }

  func addManualTask(_ title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let task = TaskItem(title: trimmed, origin: "manual")
    store.save(task)
    store.logEvent("task_created", taskID: task.id, context: ["reason": "added by hand"])
    reload()
  }

  @discardableResult
  func takeMeThere(_ task: TaskItem) -> Bool {
    store.logEvent("take_me_there", taskID: task.id, context: context(for: task))
    if let url = task.webURL {
      return NSWorkspace.shared.open(url)
    }
    if !task.bundleID.isEmpty,
      let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: task.bundleID)
    {
      NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
      return true
    }
    return false
  }

  // MARK: - Projects, people, documents and topics

  func projectName(for task: TaskItem) -> String? {
    task.projectID.isEmpty ? nil : projectNames[task.projectID]
  }

  func entities(_ kind: EntityKind) -> [Entity] {
    store.entities(kind: kind)
  }

  func detail(forEntity id: String) -> EntityDetail? {
    guard let entity = store.entity(id: id), !entity.ignored else { return nil }
    let now = Date()
    return EntityDetail(
      entity: entity, links: store.links(entityID: id), sightings: store.sightings(entityID: id),
      tasks: entity.kind == .project
        ? store.tasks(projectID: id).sorted { Ranker.score($0, now: now) > Ranker.score($1, now: now) }
        : [])
  }

  /// Hides an entry for good. It stays in the database marked ignored so it is not re-added.
  func removeEntity(_ entity: Entity) {
    var copy = entity
    copy.ignored = true
    store.save(copy)
    store.logEvent("entity_removed", context: ["kind": entity.kind.rawValue, "name": entity.name])
    reload()
  }

  // MARK: - Ranking picks

  func offerComparison() {
    guard let pair = Ranker.pairToCompare(ranked, now: Date()) else {
      comparePair = nil
      return
    }
    comparePair = ComparePair(a: pair.0, b: pair.1)
  }

  func choose(winner: TaskItem, loser: TaskItem) {
    let ratings = Ranker.elo(winner: winner.rating, loser: loser.rating)
    var first = winner
    first.rating = ratings.winner
    var second = loser
    second.rating = ratings.loser
    store.save(first)
    store.save(second)
    store.logEvent("compare", taskID: winner.id, otherTaskID: loser.id, context: context())
    lastCompare = Date()
    comparePair = nil
    reload()
  }

  func skipComparison() {
    lastCompare = Date()
    comparePair = nil
  }

  // MARK: - Nudges

  private func sendNudge(for sample: ActivitySample, minutes: Int) {
    reload()
    let place = sample.app.isEmpty ? "this" : sample.app
    let top = ranked.first
    let title = "\(minutes) min on \(place)"
    let body: String
    if let top {
      let why = top.why.isEmpty ? Ranker.fallbackWhy(top, now: Date()) : top.why
      body = "Next up: \(top.title). \(why)"
    } else {
      body = "Nothing is on your list right now. Still a good moment to look up."
    }
    store.logEvent("nudge_sent", taskID: top?.id ?? "", context: context(for: top))
    Notifier.shared.send(title: title, body: body, taskID: top?.id)
  }

  func handleNudge(action: String, taskID: String?) {
    let now = Date()
    let task = taskID.flatMap { store.task(id: $0) }
    switch action {
    case Notifier.Action.go, UNNotificationDefaultActionIdentifier:
      store.logEvent("nudge_go", taskID: taskID ?? "")
      if let task { takeMeThere(task) }
    case Notifier.Action.snooze:
      store.logEvent("nudge_snooze", taskID: taskID ?? "")
      tracker.mute(for: 10 * 60, now: now)
    case Notifier.Action.onBreak:
      store.logEvent("nudge_break", taskID: taskID ?? "")
      tracker.mute(for: 30 * 60, now: now)
    case Notifier.Action.work:
      store.logEvent("nudge_this_is_work", taskID: taskID ?? "", context: context())
      tracker.mute(for: 60 * 60, now: now)
    default:
      store.logEvent("nudge_dismissed", taskID: taskID ?? "")
    }
  }
}

/// Posts the nudge notification and routes its buttons back to the model.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Notifier()
  static let category = "LIFESCROLL_NUDGE"

  enum Action {
    static let go = "go"
    static let snooze = "snooze"
    static let onBreak = "break"
    static let work = "work"
  }

  /// Notifications only work from a real app bundle, not a bare executable.
  private var available: Bool { Bundle.main.bundleIdentifier != nil }

  func configure() {
    guard available else { return }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let actions = [
      UNNotificationAction(identifier: Action.go, title: "Take me there", options: []),
      UNNotificationAction(identifier: Action.snooze, title: "10 more minutes", options: []),
      UNNotificationAction(identifier: Action.onBreak, title: "I'm on a break", options: []),
      UNNotificationAction(identifier: Action.work, title: "This is work", options: []),
    ]
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.category, actions: actions, intentIdentifiers: [],
        options: [.customDismissAction])
    ])
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func send(title: String, body: String, taskID: String?) {
    guard available else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.categoryIdentifier = Self.category
    if let taskID { content.userInfo = ["task": taskID] }
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let action = response.actionIdentifier
    let taskID = response.notification.request.content.userInfo["task"] as? String
    await MainActor.run { AppModel.shared.handleNudge(action: action, taskID: taskID) }
  }
}
