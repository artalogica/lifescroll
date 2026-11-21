import AppKit
import SwiftUI

// MARK: - Menu bar popover

struct MenuBarLabel: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Image(systemName: model.menuIcon)
  }
}

/// Reports the window a SwiftUI view ends up in.
struct WindowReader: NSViewRepresentable {
  let onWindow: (NSWindow?) -> Void

  final class ReaderView: NSView {
    var onWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindow?(window)
    }
  }

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onWindow = onWindow
    return view
  }

  func updateNSView(_ view: ReaderView, context: Context) {
    view.onWindow = onWindow
  }
}

/// Listens for trackpad and mouse-wheel scrolling inside the popover only.
/// Scrolling in the other windows is passed through untouched.
final class ScrollMonitor {
  weak var window: NSWindow?
  private var monitor: Any?
  private var stepper = ScrollStepper()

  func start(onStep: @escaping @MainActor (Int) -> Void) {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self, let window = self.window, event.window === window else { return event }
      if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
        self.stepper.gestureEnded()
        return nil
      }
      let step = self.stepper.feed(
        deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas,
        momentum: !event.momentumPhase.isEmpty, now: Date())
      if step != 0 {
        // Local event monitors are always called on the main thread.
        MainActor.assumeIsolated { onStep(step) }
      }
      return nil
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  deinit { stop() }
}

struct PopoverView: View {
  @EnvironmentObject var model: AppModel
  @State private var scrollMonitor = ScrollMonitor()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if !model.setupIssues.isEmpty { SetupBanner() }
      if let pair = model.comparePair {
        CompareCard(pair: pair)
      } else if let item = model.currentItem {
        // A new id makes SwiftUI treat each card as a new view, so it slides in the scroll direction.
        Group {
          switch item {
          case .task(let task): TaskCard(task: task)
          case .suggestion(let suggestion): SuggestionCard(suggestion: suggestion)
          }
        }
        .id(item.id)
        .transition(.push(from: model.scrollStep >= 0 ? .bottom : .top))
      } else {
        EmptyCard()
      }
      if let error = model.lastError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      footer
    }
    .padding(14)
    .frame(width: 360)
    .clipped()
    .background(WindowReader { scrollMonitor.window = $0 })
    .onAppear {
      model.popoverOpened()
      scrollMonitor.start { step in model.scroll(by: step) }
    }
    .onDisappear { scrollMonitor.stop() }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
        ForEach(Mode.allCases) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .help(model.mode.explanation)

      Button {
        model.setPaused(!model.paused)
      } label: {
        Image(systemName: model.paused ? "play.fill" : "pause.fill")
      }
      .help(model.paused ? "Resume watching" : "Pause watching")
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      Text(model.statusLine)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("All tasks") { WindowManager.shared.showTasks() }
        Button("Projects") { WindowManager.shared.showGraph() }
          .help("Projects, people, documents and topics Lifescroll has seen")
        Button("Rank two") { model.offerComparison() }
          .disabled(model.ranked.count < 2)
          .help("Pick which of two tasks matters more")
        Spacer()
        Button {
          WindowManager.shared.showSettings()
        } label: {
          Image(systemName: "gearshape")
        }
        .help("Settings")
        Button {
          NSApp.terminate(nil)
        } label: {
          Image(systemName: "power")
        }
        .help("Quit Lifescroll")
      }
      .controlSize(.small)
    }
  }
}

struct SetupBanner: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(model.setupIssues, id: \.self) { issue in
        Label(issue, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("Open Settings") { WindowManager.shared.showSettings() }
        .controlSize(.small)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
  }
}

struct Chip: View {
  let text: String
  var systemImage: String?

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage { Image(systemName: systemImage) }
      Text(text)
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(.quaternary, in: Capsule())
  }
}

struct TaskCard: View {
  @EnvironmentObject var model: AppModel
  let task: TaskItem

  private var why: String {
    task.why.isEmpty ? Ranker.fallbackWhy(task, now: Date()) : task.why
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("UP NEXT")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(model.cardIndex + 1) of \(model.feed.count)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Text(task.title)
        .font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)

      Text(why)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 6) {
        if let project = model.projectName(for: task) {
          Chip(text: project, systemImage: "folder")
        }
        if let due = Ranker.deadlineText(task.deadline, now: Date()) {
          Chip(text: due, systemImage: "clock")
        }
        if task.estMinutes > 0 { Chip(text: "~\(task.estMinutes) min") }
        if task.seenCount > 1 { Chip(text: "seen \(task.seenCount)×") }
      }

      if task.hasDestination {
        Button {
          model.takeMeThere(task)
        } label: {
          Label("Take me there", systemImage: "arrow.up.forward.app")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .help(task.webURL?.host ?? task.sourceApp)
      }

      HStack(spacing: 6) {
        Button("Done") { model.markDone(task) }
        Button("Not now") { model.notNow(task) }
          .help("Hide for three hours")
        Button("Never") { model.never(task) }
          .help("Dismiss for good")
        Spacer()
        ScrollArrows()
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
  }
}

/// Previous and next. The feed loops, so neither runs out; they only switch off with a single card.
struct ScrollArrows: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    Button {
      model.scroll(by: -1)
    } label: {
      Image(systemName: "chevron.up")
    }
    .disabled(model.feed.count < 2)
    .keyboardShortcut(.upArrow, modifiers: [])
    .help("Previous card")
    Button {
      model.scroll(by: 1)
    } label: {
      Image(systemName: "chevron.down")
    }
    .disabled(model.feed.count < 2)
    .keyboardShortcut(.downArrow, modifiers: [])
    .help("Next card. After the last one, the first comes back.")
  }
}

/// A card for something to enjoy instead of something to do.
struct SuggestionCard: View {
  @EnvironmentObject var model: AppModel
  let suggestion: Recommendation

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(suggestion.bucket == "explore" ? "SOMETHING DIFFERENT" : "YOU MIGHT LIKE")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.purple)
        Spacer()
        Text("\(model.cardIndex + 1) of \(model.feed.count)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Text(suggestion.title)
        .font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)

      if !suggestion.why.isEmpty {
        Text(suggestion.why)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 6) {
        Chip(text: suggestion.kind, systemImage: suggestion.icon)
        Chip(text: suggestion.webURL?.host ?? suggestion.source)
        if suggestion.estMinutes > 0 { Chip(text: "~\(suggestion.estMinutes) min") }
      }

      Button {
        model.openSuggestion(suggestion)
      } label: {
        Label("Open", systemImage: "arrow.up.forward.app")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.purple)
      .controlSize(.large)
      .help(suggestion.url)

      HStack(spacing: 6) {
        Button("Not for me") { model.dismissSuggestion(suggestion) }
          .help("Remove it and show fewer like it")
        Spacer()
        ScrollArrows()
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }
}

struct CompareCard: View {
  @EnvironmentObject var model: AppModel
  let pair: ComparePair

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("WHICH MATTERS MORE RIGHT NOW?")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Skip") { model.skipComparison() }
          .buttonStyle(.link)
          .font(.caption)
      }
      option(pair.a, over: pair.b)
      option(pair.b, over: pair.a)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
  }

  private func option(_ task: TaskItem, over other: TaskItem) -> some View {
    Button {
      model.choose(winner: task, loser: other)
    } label: {
      Text(task.title)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
    .controlSize(.large)
  }
}

struct EmptyCard: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Nothing on your list yet")
        .font(.title3.weight(.semibold))
      Text(
        model.lastSummary.isEmpty
          ? "Lifescroll reads your screen every ten minutes. Tasks appear here once it has seen something you left unfinished."
          : "Last seen: \(model.lastSummary)"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
  }
}

// MARK: - All tasks window

struct TaskListView: View {
  @EnvironmentObject var model: AppModel
  @State private var filter: TaskStatus = .open
  @State private var newTitle = ""
  @State private var groupByProject = false

  /// Tasks keep their overall rank number; grouping only changes which section they sit in.
  private func groups(_ tasks: [TaskItem]) -> [(name: String, rows: [(rank: Int, task: TaskItem)])] {
    var order: [String] = []
    var buckets: [String: [(rank: Int, task: TaskItem)]] = [:]
    for (index, task) in tasks.enumerated() {
      let name = model.projectName(for: task) ?? "No project"
      if buckets[name] == nil { order.append(name) }
      buckets[name, default: []].append((index + 1, task))
    }
    // Projects appear in the order of their highest-ranked task, with unassigned tasks last.
    let named = order.filter { $0 != "No project" }
    return (named + order.filter { $0 == "No project" }).map { ($0, buckets[$0] ?? []) }
  }

  var body: some View {
    // Reading `ranked` keeps this list in step with every change the model makes.
    let _ = model.ranked
    let tasks = model.tasks(for: filter)
    VStack(spacing: 0) {
      HStack {
        Picker("Show", selection: $filter) {
          ForEach(TaskStatus.allCases) { status in
            Text(status.label).tag(status)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Toggle("Group by project", isOn: $groupByProject)
          .toggleStyle(.checkbox)
      }
      .padding(12)

      if tasks.isEmpty {
        Spacer()
        Text(filter == .open ? "No open tasks." : "Nothing here.")
          .foregroundStyle(.secondary)
        Spacer()
      } else if groupByProject {
        List {
          ForEach(groups(tasks), id: \.name) { group in
            Section(group.name) {
              ForEach(group.rows, id: \.task.id) { row in
                TaskRow(task: row.task, rank: filter == .open ? row.rank : nil)
              }
            }
          }
        }
      } else {
        List {
          ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
            TaskRow(task: task, rank: filter == .open ? index + 1 : nil)
          }
        }
      }

      Divider()
      HStack {
        TextField("Add a task by hand", text: $newTitle)
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)
        Button("Add", action: add)
          .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(12)
    }
    .frame(minWidth: 520, minHeight: 420)
  }

  private func add() {
    model.addManualTask(newTitle)
    newTitle = ""
    filter = .open
  }
}

struct TaskRow: View {
  @EnvironmentObject var model: AppModel
  let task: TaskItem
  let rank: Int?

  var body: some View {
    let now = Date()
    // The same "why this, why now" line the card shows. Closed tasks only show one if the model wrote it.
    let why: String? =
      !task.why.isEmpty ? task.why : (task.status == .open ? Ranker.fallbackWhy(task, now: now) : nil)
    HStack(alignment: .top, spacing: 10) {
      if let rank {
        Text("\(rank)")
          .font(.headline.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 26, alignment: .trailing)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(task.title).font(.body.weight(.medium))
        if let why {
          Text(why).font(.callout)
        }
        if !task.detail.isEmpty {
          Text(task.detail).font(.caption).foregroundStyle(.secondary)
        }
        HStack(spacing: 6) {
          if let project = model.projectName(for: task) {
            Chip(text: project, systemImage: "folder")
          }
          if let due = Ranker.deadlineText(task.deadline, now: now) { Chip(text: due) }
          if task.estMinutes > 0 { Chip(text: "~\(task.estMinutes) min") }
          if task.isSnoozed(at: now) { Chip(text: "hidden for now") }
          if task.origin == "manual" { Chip(text: "added by hand") }
          if task.status == .open {
            Chip(text: String(format: "score %.0f", Ranker.score(task, now: now)))
          }
        }
      }
      Spacer()
      if task.status == .open {
        if task.hasDestination {
          Button("Open") { model.takeMeThere(task) }
        }
        Button("Done") { model.markDone(task) }
        Button("Never") { model.never(task) }
      } else {
        Button("Reopen") { model.reopen(task) }
      }
    }
    .controlSize(.small)
    .padding(.vertical, 4)
    .opacity(task.isSnoozed(at: now) ? 0.55 : 1)
  }
}

// MARK: - Projects & people window

enum Relative {
  static func text(_ date: Date, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: now)
  }

  static func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE d MMM, HH:mm"
    return formatter.string(from: date)
  }
}

struct GraphView: View {
  @EnvironmentObject var model: AppModel
  @State private var kind: EntityKind = .project
  @State private var selection: String?

  var body: some View {
    // Reading `ranked` refreshes this window whenever the model reloads.
    let _ = model.ranked
    let entities = model.entities(kind)
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        Picker("Kind", selection: $kind) {
          ForEach(EntityKind.allCases) { kind in
            Text(kind.plural).tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(10)

        if entities.isEmpty {
          Spacer()
          Text("None seen yet.")
            .foregroundStyle(.secondary)
          Spacer()
        } else {
          List(entities, selection: $selection) { entity in
            VStack(alignment: .leading, spacing: 2) {
              Text(entity.name).font(.body.weight(.medium))
              Text("seen \(entity.seenCount)× · \(Relative.text(entity.lastSeen))")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
          }
        }
      }
      .frame(width: 300)

      Divider()

      if let selection, let detail = model.detail(forEntity: selection) {
        EntityDetailView(detail: detail) { self.selection = $0 }
      } else {
        VStack {
          Spacer()
          Text("Lifescroll indexes the projects, people, documents and topics it sees you working with. Pick one to see what it connects to.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 320)
          Spacer()
        }
        .frame(maxWidth: .infinity)
      }
    }
    .frame(minWidth: 760, minHeight: 480)
    .onChange(of: kind) { selection = nil }
  }
}

struct EntityDetailView: View {
  @EnvironmentObject var model: AppModel
  let detail: EntityDetail
  let open: (String) -> Void

  var body: some View {
    let entity = detail.entity
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Label(entity.name, systemImage: entity.kind.icon)
            .font(.title2.weight(.semibold))
          if !entity.summary.isEmpty {
            Text(entity.summary).foregroundStyle(.secondary)
          }
          if !entity.aliases.isEmpty {
            Text("Also seen as: \(entity.aliases.joined(separator: ", "))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text("First seen \(Relative.stamp(entity.firstSeen)) · seen in \(entity.seenCount) readings")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if !detail.tasks.isEmpty {
          section("Open tasks") {
            ForEach(detail.tasks) { task in
              TaskRow(task: task, rank: nil)
            }
          }
        }

        if !detail.links.isEmpty {
          section("Connected to") {
            ForEach(detail.links) { link in
              Button {
                open(link.entity.id)
              } label: {
                HStack {
                  Label(link.entity.name, systemImage: link.entity.kind.icon)
                  Spacer()
                  Text("together \(link.weight)×")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }

        if !detail.sightings.isEmpty {
          section("What you did with it") {
            ForEach(Array(detail.sightings.enumerated()), id: \.offset) { _, sighting in
              VStack(alignment: .leading, spacing: 1) {
                Text(Relative.stamp(sighting.ts))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(sighting.context)
              }
            }
          }
        }

        Button("Remove from index", role: .destructive) { model.removeEntity(entity) }
          .controlSize(.small)
          .help("Hide this entry and stop tracking it")
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      content()
    }
  }
}

// MARK: - Settings window

struct SettingsView: View {
  @EnvironmentObject var model: AppModel
  @State private var keyDraft = ""

  var body: some View {
    Form {
      Section("Claude API key") {
        if model.hasAPIKey {
          HStack {
            Label("A key is saved in your Keychain.", systemImage: "checkmark.seal")
            Spacer()
            Button("Remove") { model.removeAPIKey() }
          }
        } else {
          SecureField("sk-ant-…", text: $keyDraft)
          Button("Save to Keychain") {
            model.saveAPIKey(keyDraft)
            keyDraft = ""
          }
          .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Text("Haiku 5.5 reads the screenshots. Sonnet 5.5 merges and ranks tasks and writes the cards.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Permissions") {
        permissionRow(
          "Screen Recording", granted: model.screenPermission,
          pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) { ScreenCapturer.requestPermission() }
        permissionRow(
          "Accessibility (window titles)", granted: model.accessibilityPermission,
          pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) { ActivityMonitor.requestAccessibilityPermission() }
        Text("After turning Screen Recording on, quit and reopen Lifescroll.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Nudges") {
        ForEach(Mode.allCases) { mode in
          LabeledContent(mode.label, value: mode.explanation)
        }
        TextField("Counts as scrolling", text: $model.distractingKeywords, axis: .vertical)
          .lineLimit(2...4)
        Text("Comma-separated words matched against the app name and window title.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Privacy") {
        TextField("Never capture", text: $model.excludedKeywords, axis: .vertical)
          .lineLimit(2...4)
        Text("Screenshots are skipped while a matching window is in front. Raw screenshots are deleted after three days; everything is stored on this Mac.")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          Button("Save word lists") { model.saveKeywords() }
          Button("Show data folder") {
            NSWorkspace.shared.open(Store.applicationSupport())
          }
        }
      }

      Section("Suggestions") {
        let onHand = model.feed.filter { if case .suggestion = $0 { return true } else { return false } }.count
        Text(
          model.mode == .lockIn
            ? "Lock in mode shows tasks only."
            : "\(onHand) in your feed. Sonnet turns what you watch and read into searches of arXiv and Hacker News, then picks the best few."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        HStack {
          Button(model.findingSuggestions ? "Looking…" : "Find suggestions now") {
            model.suggestionsTick(force: true)
          }
          .disabled(model.findingSuggestions || !model.hasAPIKey || model.mode == .lockIn)
          Text(model.suggestionNote)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text("Searches use general subject words only, never names. Only those words leave your Mac.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Today") {
        if model.usage.isEmpty {
          Text("No Claude calls yet today.").foregroundStyle(.secondary)
        } else {
          ForEach(model.usage) { row in
            LabeledContent(
              row.model,
              value: String(
                format: "%d in · %d out · $%.3f", row.inputTokens, row.outputTokens, row.cost))
          }
          LabeledContent(
            "Estimated total",
            value: String(format: "$%.3f", model.usage.reduce(0) { $0 + $1.cost }))
        }
        HStack {
          Button(model.analyzing ? "Reading…" : "Read my screen now") {
            model.analysisTick(force: true)
          }
          .disabled(model.analyzing || !model.hasAPIKey)
          Text("\(model.pendingFrames) screenshots waiting")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 520, minHeight: 620)
    .onAppear { model.refreshPermissions() }
  }

  private func permissionRow(
    _ name: String, granted: Bool, pane: String, request: @escaping () -> Void
  ) -> some View {
    HStack {
      Label(name, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
        .foregroundStyle(granted ? .green : .secondary)
      Spacer()
      if !granted {
        Button("Ask") { request() }
        Button("Open System Settings") {
          if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        }
      }
    }
  }
}

// MARK: - Windows

/// Plain AppKit windows. A SwiftUI `Window` scene would open itself at launch, which a menu bar app must not do.
@MainActor
final class WindowManager {
  static let shared = WindowManager()
  private var windows: [String: NSWindow] = [:]

  func showTasks() {
    show(id: "tasks", title: "Lifescroll Tasks", size: NSSize(width: 620, height: 520)) {
      TaskListView()
    }
  }

  func showSettings() {
    show(id: "settings", title: "Lifescroll Settings", size: NSSize(width: 560, height: 680)) {
      SettingsView()
    }
  }

  func showGraph() {
    show(id: "graph", title: "Lifescroll Projects & People", size: NSSize(width: 860, height: 560)) {
      GraphView()
    }
  }

  private func show<Content: View>(
    id: String, title: String, size: NSSize, @ViewBuilder content: () -> Content
  ) {
    if windows[id] == nil {
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
        defer: false)
      window.title = title
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: content().environmentObject(AppModel.shared))
      window.center()
      windows[id] = window
    }
    AppModel.shared.reload()
    windows[id]?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
