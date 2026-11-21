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
  @Environment(\.renderingPreview) private var preview
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
        Label(error, systemImage: "exclamationmark.circle")
          .font(.system(size: 11))
          .foregroundStyle(Glass.coral)
          .fixedSize(horizontal: false, vertical: true)
      }
      footer
    }
    .padding(14)
    .frame(width: 360)
    .clipped()
    .glassPanel()
    .background {
      if !preview {
        WindowReader { window in
          scrollMonitor.window = window
          // The popover is always dark glass, whatever the system appearance.
          window?.appearance = NSAppearance(named: .darkAqua)
        }
      }
    }
    .onAppear {
      guard !preview else { return }
      model.popoverOpened()
      scrollMonitor.start { step in model.scroll(by: step) }
    }
    .onDisappear { scrollMonitor.stop() }
  }

  private var header: some View {
    HStack(spacing: 8) {
      GlassSegmented(
        options: Mode.allCases.map { ($0, $0.shortLabel) },
        selection: Binding(get: { model.mode }, set: { model.setMode($0) })
      )
      .help("\(model.mode.label). \(model.mode.explanation)")

      Button {
        model.setPaused(!model.paused)
      } label: {
        Image(systemName: model.paused ? "play.fill" : "pause.fill")
      }
      .buttonStyle(GlassButtonStyle(kind: .icon))
      .help(model.paused ? "Resume watching" : "Pause watching")
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(model.statusLine)
        .font(.system(size: 11))
        .foregroundStyle(Glass.faint)
        .padding(.horizontal, 2)
      HStack(spacing: 2) {
        Button("All tasks") { WindowManager.shared.showTasks() }
        Button("Projects") { WindowManager.shared.showGraph() }
          .help("Projects, people, documents and topics Lifescroll has seen")
        Button("Rank two") { model.offerComparison() }
          .disabled(model.ranked.count < 2)
          .help("Pick which of two tasks matters more")
        Spacer()
        HStack(spacing: 6) {
          Button {
            WindowManager.shared.showSettings()
          } label: {
            Image(systemName: "gearshape.fill")
          }
          .help("Settings")
          Button {
            NSApp.terminate(nil)
          } label: {
            Image(systemName: "power")
          }
          .help("Quit Lifescroll")
        }
        .buttonStyle(GlassButtonStyle(kind: .icon))
      }
      .buttonStyle(GlassButtonStyle(kind: .quiet))
      .padding(.leading, -8)
    }
  }
}

struct SetupBanner: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.setupIssues, id: \.self) { issue in
        Label(issue, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12))
          .foregroundStyle(Glass.amber)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("Open Settings") { WindowManager.shared.showSettings() }
        .buttonStyle(GlassButtonStyle(kind: .secondary, compact: true))
    }
    .glassCard(tint: Glass.amber, padding: 12)
  }
}

/// The small line above a card's title: what kind of card it is, and where it sits in the feed.
struct CardHeader: View {
  @EnvironmentObject var model: AppModel
  let label: String
  var color: Color = Glass.soft

  var body: some View {
    HStack {
      Text(label)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
      Spacer()
      if model.feed.count > 1 {
        Text("\(model.cardIndex + 1) of \(model.feed.count)")
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(Glass.faint)
      }
    }
  }
}

struct CardText: View {
  let title: String
  let why: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 18, weight: .semibold))
        .tracking(-0.2)
        .foregroundStyle(Glass.ink)
        .fixedSize(horizontal: false, vertical: true)
      if !why.isEmpty {
        Text(why)
          .font(.system(size: 13))
          .lineSpacing(2)
          .foregroundStyle(Glass.soft)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct TaskCard: View {
  @EnvironmentObject var model: AppModel
  let task: TaskItem

  private var why: String {
    task.why.isEmpty ? Ranker.fallbackWhy(task, now: Date()) : task.why
  }

  var body: some View {
    let now = Date()
    let due = Ranker.deadlineText(task.deadline, now: now)
    VStack(alignment: .leading, spacing: 12) {
      CardHeader(label: "Up next")
      CardText(title: task.title, why: why)

      FlowLayout(spacing: 6) {
        if let project = model.projectName(for: task) {
          Chip(text: project, systemImage: "folder.fill")
        }
        if let due {
          Chip(text: due, systemImage: "clock.fill", color: due == "overdue" ? Glass.coral : Glass.soft)
        }
        if task.estMinutes > 0 { Chip(text: "~\(task.estMinutes) min") }
        if task.seenCount > 1 { Chip(text: "seen \(task.seenCount)×") }
      }

      if task.hasDestination {
        Button {
          model.takeMeThere(task)
        } label: {
          Label("Take me there", systemImage: "arrow.up.forward")
        }
        .buttonStyle(GlassButtonStyle(kind: .primary))
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
      .buttonStyle(GlassButtonStyle(kind: .secondary))
    }
    .glassCard()
  }
}

/// Previous and next. The feed loops, so neither runs out; they only switch off with a single card.
struct ScrollArrows: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    HStack(spacing: 6) {
      Button {
        model.scroll(by: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .keyboardShortcut(.upArrow, modifiers: [])
      .help("Previous card")
      Button {
        model.scroll(by: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .keyboardShortcut(.downArrow, modifiers: [])
      .help("Next card. After the last one, the first comes back.")
    }
    .buttonStyle(GlassButtonStyle(kind: .icon))
    .disabled(model.feed.count < 2)
  }
}

/// A card for something to enjoy instead of something to do. The only place the app uses colour.
struct SuggestionCard: View {
  @EnvironmentObject var model: AppModel
  let suggestion: Recommendation

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CardHeader(
        label: suggestion.bucket == "explore" ? "Something different" : "You might like",
        color: Glass.blushRose)
      CardText(title: suggestion.title, why: suggestion.why)

      FlowLayout(spacing: 6) {
        Chip(text: suggestion.kind, systemImage: suggestion.icon)
        Chip(text: suggestion.webURL?.host ?? suggestion.source)
        if suggestion.estMinutes > 0 { Chip(text: "~\(suggestion.estMinutes) min") }
      }

      Button {
        model.openSuggestion(suggestion)
      } label: {
        Label("Open", systemImage: "arrow.up.forward")
      }
      .buttonStyle(GlassButtonStyle(kind: .primary))
      .help(suggestion.url)

      HStack(spacing: 6) {
        Button("Not for me") { model.dismissSuggestion(suggestion) }
          .buttonStyle(GlassButtonStyle(kind: .secondary))
          .help("Remove it and show fewer like it")
        Spacer()
        ScrollArrows()
      }
    }
    .glassCard(blush: true)
  }
}

struct CompareCard: View {
  @EnvironmentObject var model: AppModel
  let pair: ComparePair

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Which matters more right now?")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Glass.ink)
        Spacer()
        Button("Skip") { model.skipComparison() }
          .buttonStyle(GlassButtonStyle(kind: .quiet))
      }
      Button(pair.a.title) { model.choose(winner: pair.a, loser: pair.b) }
      Button(pair.b.title) { model.choose(winner: pair.b, loser: pair.a) }
    }
    .buttonStyle(GlassButtonStyle(kind: .row))
    .glassCard()
  }
}

struct EmptyCard: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    CardText(
      title: "Nothing on your list yet",
      why: model.lastSummary.isEmpty
        ? "Lifescroll reads your screen every ten minutes. Tasks appear here once it has seen something you left unfinished."
        : "Last seen: \(model.lastSummary)"
    )
    .glassCard()
  }
}

// MARK: - All tasks window

/// The heading at the top of a window, standing in for the hidden title bar.
struct WindowHeading<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 10) {
      Text(title)
        .font(.system(size: 20, weight: .semibold))
        .tracking(-0.3)
        .foregroundStyle(Glass.ink)
      Spacer()
      trailing()
    }
  }
}

/// A pill that is either on or off, for a single setting.
struct GlassToggle: View {
  let label: String
  @Binding var isOn: Bool

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      Label(label, systemImage: isOn ? "checkmark.circle.fill" : "circle")
    }
    .buttonStyle(GlassButtonStyle(kind: .secondary))
  }
}

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
    VStack(alignment: .leading, spacing: 14) {
      WindowHeading(title: "Tasks") {
        GlassToggle(label: "Group by project", isOn: $groupByProject)
        GlassSegmented(options: TaskStatus.allCases.map { ($0, $0.label) }, selection: $filter)
          .frame(width: 210)
      }

      if tasks.isEmpty {
        VStack {
          Spacer()
          Text(filter == .open ? "No open tasks." : "Nothing here.")
            .font(.system(size: 13))
            .foregroundStyle(Glass.faint)
            .frame(maxWidth: .infinity)
          Spacer()
        }
      } else {
        GlassScroll {
          LazyVStack(alignment: .leading, spacing: 8) {
            if groupByProject {
              ForEach(groups(tasks), id: \.name) { group in
                Text(group.name)
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(Glass.soft)
                  .padding(.top, 6)
                  .padding(.leading, 4)
                ForEach(group.rows, id: \.task.id) { row in
                  TaskRow(task: row.task, rank: filter == .open ? row.rank : nil)
                }
              }
            } else {
              ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                TaskRow(task: task, rank: filter == .open ? index + 1 : nil)
              }
            }
          }
        }
      }

      HStack(spacing: 8) {
        GlassField(prompt: "Add a task by hand", text: $newTitle, onSubmit: add)
        Button("Add", action: add)
          .buttonStyle(GlassButtonStyle(kind: .primary))
          .frame(width: 76)
          .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(18)
    .frame(minWidth: 560, minHeight: 440)
    .glassPanel()
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
    let due = Ranker.deadlineText(task.deadline, now: now)
    HStack(alignment: .top, spacing: 12) {
      if let rank {
        Text("\(rank)")
          .font(.system(size: 15, weight: .semibold).monospacedDigit())
          .foregroundStyle(Glass.faint)
          .frame(width: 22, alignment: .trailing)
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(task.title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Glass.ink)
          .fixedSize(horizontal: false, vertical: true)
        if let why {
          Text(why)
            .font(.system(size: 12))
            .foregroundStyle(Glass.soft)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !task.detail.isEmpty {
          Text(task.detail)
            .font(.system(size: 11))
            .foregroundStyle(Glass.faint)
            .fixedSize(horizontal: false, vertical: true)
        }
        FlowLayout(spacing: 6) {
          if let project = model.projectName(for: task) {
            Chip(text: project, systemImage: "folder.fill")
          }
          if let due {
            Chip(text: due, systemImage: "clock.fill", color: due == "overdue" ? Glass.coral : Glass.soft)
          }
          if task.estMinutes > 0 { Chip(text: "~\(task.estMinutes) min") }
          if task.isSnoozed(at: now) { Chip(text: "hidden for now") }
          if task.origin == "manual" { Chip(text: "added by hand") }
          if task.status == .open {
            Chip(text: String(format: "score %.0f", Ranker.score(task, now: now)), color: Glass.faint)
          }
        }
        .padding(.top, 2)
      }
      Spacer(minLength: 8)
      HStack(spacing: 6) {
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
      .buttonStyle(GlassButtonStyle(kind: .secondary, compact: true))
    }
    .glassCard(padding: 12)
    .opacity(task.isSnoozed(at: now) ? 0.55 : 1)
  }
}

// MARK: - Projects & people window

enum Relative {
  static func text(_ date: Date, now: Date = Date()) -> String {
    // The formatter renders the last minute as "in 0s", which reads as a glitch.
    if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
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
  @State var selection: String?

  var body: some View {
    // Reading `ranked` refreshes this window whenever the model reloads.
    let _ = model.ranked
    let entities = model.entities(kind)
    VStack(alignment: .leading, spacing: 14) {
      WindowHeading(title: "Projects and people") {
        GlassSegmented(options: EntityKind.allCases.map { ($0, $0.plural) }, selection: $kind)
          .frame(width: 400)
      }

      HStack(alignment: .top, spacing: 14) {
        Group {
          if entities.isEmpty {
            VStack {
              Spacer()
              Text("None seen yet.")
                .font(.system(size: 13))
                .foregroundStyle(Glass.faint)
                .frame(maxWidth: .infinity)
              Spacer()
            }
          } else {
            GlassScroll {
              LazyVStack(spacing: 4) {
                ForEach(entities) { entity in
                  EntityListRow(entity: entity, selected: selection == entity.id) {
                    selection = entity.id
                  }
                }
              }
            }
          }
        }
        .frame(width: 260)

        Group {
          if let selection, let detail = model.detail(forEntity: selection) {
            EntityDetailView(detail: detail) { self.selection = $0 }
          } else {
            VStack {
              Spacer()
              Text("Lifescroll keeps track of the projects, people, documents and topics it sees you working with. Pick one to see what it connects to.")
                .font(.system(size: 13))
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Glass.faint)
                .frame(maxWidth: 320)
              Spacer()
            }
            .frame(maxWidth: .infinity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(padding: 0)
      }
    }
    .padding(18)
    .frame(minWidth: 780, minHeight: 500)
    .glassPanel()
    .onChange(of: kind) { selection = nil }
  }
}

struct EntityListRow: View {
  let entity: Entity
  let selected: Bool
  let choose: () -> Void

  var body: some View {
    Button(action: choose) {
      HStack(spacing: 10) {
        Image(systemName: entity.kind.icon)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(selected ? Glass.ink : Glass.soft)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(entity.name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Glass.ink)
            .lineLimit(1)
          Text("\(entity.seenCount == 1 ? "Seen once" : "Seen \(entity.seenCount) times"), last \(Relative.text(entity.lastSeen))")
            .font(.system(size: 11))
            .foregroundStyle(Glass.faint)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(Color.white.opacity(selected ? 0.16 : 0.0001))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct EntityDetailView: View {
  @EnvironmentObject var model: AppModel
  let detail: EntityDetail
  let open: (String) -> Void

  var body: some View {
    let entity = detail.entity
    GlassScroll {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 6) {
          Label(entity.name, systemImage: entity.kind.icon)
            .font(.system(size: 20, weight: .semibold))
            .tracking(-0.3)
            .foregroundStyle(Glass.ink)
          if !entity.summary.isEmpty {
            Text(entity.summary)
              .font(.system(size: 13))
              .foregroundStyle(Glass.soft)
          }
          if !entity.aliases.isEmpty {
            Text("Also seen as \(entity.aliases.joined(separator: ", "))")
              .font(.system(size: 11))
              .foregroundStyle(Glass.faint)
          }
          Text("First seen \(Relative.stamp(entity.firstSeen)), in \(entity.seenCount) readings since")
            .font(.system(size: 11))
            .foregroundStyle(Glass.faint)
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
            VStack(spacing: 6) {
              ForEach(detail.links) { link in
                Button {
                  open(link.entity.id)
                } label: {
                  HStack {
                    Label(link.entity.name, systemImage: link.entity.kind.icon)
                    Spacer()
                    Text(link.weight == 1 ? "seen together once" : "seen together \(link.weight) times")
                      .font(.system(size: 11))
                      .foregroundStyle(Glass.faint)
                  }
                }
                .buttonStyle(GlassButtonStyle(kind: .row))
              }
            }
          }
        }

        if !detail.sightings.isEmpty {
          section("What you did with it") {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(Array(detail.sightings.enumerated()), id: \.offset) { _, sighting in
                VStack(alignment: .leading, spacing: 2) {
                  Text(Relative.stamp(sighting.ts))
                    .font(.system(size: 11))
                    .foregroundStyle(Glass.faint)
                  Text(sighting.context)
                    .font(.system(size: 13))
                    .foregroundStyle(Glass.soft)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
            }
          }
        }

        Button("Remove from index") { model.removeEntity(entity) }
          .buttonStyle(GlassButtonStyle(kind: .secondary, compact: true))
          .help("Hide this entry and stop tracking it")
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Glass.soft)
      content()
    }
  }
}

// MARK: - Settings window

struct SettingsView: View {
  @EnvironmentObject var model: AppModel
  @State private var keyDraft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      WindowHeading(title: "Settings") {}
        .padding(.horizontal, 22)
        .padding(.top, 18)
      form
    }
    .frame(minWidth: 540, minHeight: 640)
    .glassPanel()
    .onAppear { model.refreshPermissions() }
  }

  private var form: some View {
    Form {
      Section("Claude API key") {
        if model.hasAPIKey {
          HStack {
            Label("A key is saved in your Keychain.", systemImage: "checkmark.seal.fill")
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
        note("Haiku 5.5 reads your screen. Sonnet 5.5 merges and ranks tasks and writes the cards.")
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
        note("After turning Screen Recording on, quit and reopen Lifescroll.")
      }

      Section("Nudges") {
        ForEach(Mode.allCases) { mode in
          LabeledContent(mode.label, value: mode.explanation)
        }
        TextField("Counts as scrolling", text: $model.distractingKeywords, axis: .vertical)
          .lineLimit(2...4)
        note("Comma-separated words matched against the app name and window title.")
      }

      Section("Privacy") {
        TextField("Never capture", text: $model.excludedKeywords, axis: .vertical)
          .lineLimit(2...4)
        note("Matching windows are cut out of every capture, and nothing is captured while one is in front. Screen text is read on this Mac, and things that look like keys or card numbers are masked. Claude is sent that text, plus a screenshot where a screen had little text. The text is erased once it has been read; screenshots are deleted after three days.")
        HStack {
          Button("Save word lists") { model.saveKeywords() }
          Button("Show data folder") {
            NSWorkspace.shared.open(Store.applicationSupport())
          }
        }
      }

      Section("Suggestions") {
        let onHand = model.feed.filter { if case .suggestion = $0 { return true } else { return false } }.count
        note(
          model.mode == .lockIn
            ? "Lock in mode shows tasks only."
            : "\(onHand) in your feed. Sonnet turns what you watch and read into searches of arXiv and Hacker News, then picks the best few.")
        HStack {
          Button(model.findingSuggestions ? "Looking…" : "Find suggestions now") {
            model.suggestionsTick(force: true)
          }
          .disabled(model.findingSuggestions || !model.hasAPIKey || model.mode == .lockIn)
          note(model.suggestionNote)
        }
        note("Searches use general subject words only, never names. Only those words leave your Mac.")
      }

      Section("Today") {
        if model.usage.isEmpty {
          note("No Claude calls yet today.")
        } else {
          ForEach(model.usage) { row in
            LabeledContent(
              row.model,
              value: String(
                format: "%d in, %d out, $%.3f", row.inputTokens, row.outputTokens, row.cost))
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
          note("\(model.pendingFrames) screenshots waiting")
        }
      }
    }
    .formStyle(.grouped)
    // The form's own backing is dropped so the glass shows through behind its sections.
    .scrollContentBackground(.hidden)
    .buttonStyle(GlassButtonStyle(kind: .secondary))
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(Glass.soft)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func permissionRow(
    _ name: String, granted: Bool, pane: String, request: @escaping () -> Void
  ) -> some View {
    HStack {
      Label(name, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
        .foregroundStyle(granted ? Glass.mint : Glass.soft)
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
    show(id: "tasks", title: "Lifescroll Tasks", size: NSSize(width: 640, height: 540)) {
      TaskListView()
    }
  }

  func showSettings() {
    show(id: "settings", title: "Lifescroll Settings", size: NSSize(width: 560, height: 700)) {
      SettingsView()
    }
  }

  func showGraph() {
    show(id: "graph", title: "Lifescroll Projects and People", size: NSSize(width: 880, height: 580)) {
      GraphView()
    }
  }

  private func show<Content: View>(
    id: String, title: String, size: NSSize, @ViewBuilder content: () -> Content
  ) {
    if windows[id] == nil {
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      // The title still names the window in Mission Control and the Window menu; on screen the
      // glass runs to the top edge and the view draws its own heading.
      window.title = title
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.isOpaque = false
      window.backgroundColor = .clear
      window.appearance = NSAppearance(named: .darkAqua)
      window.isMovableByWindowBackground = true
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
