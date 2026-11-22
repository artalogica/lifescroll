#if DEBUG
import AppKit
import SwiftUI

// `Lifescroll --render-ui <folder>` draws the interface to PNG files over a light and a dark backdrop,
// using made-up sample data. Debug builds only: none of this, including the sample data, is compiled
// into the app that `scripts/build-app.sh` produces. It is how the look can be checked without running the app, and in
// particular how legibility over a pale wallpaper is checked.

/// A stand-in wallpaper. The light one is deliberately pale and busy: the hard case for glass.
struct SampleWallpaper: View {
  let light: Bool

  var body: some View {
    ZStack {
      LinearGradient(
        colors: light
          ? [Color(red: 0.99, green: 0.95, blue: 0.90), Color(red: 0.97, green: 0.80, blue: 0.76), Color(red: 0.80, green: 0.87, blue: 0.96)]
          : [Color(red: 0.09, green: 0.13, blue: 0.16), Color(red: 0.20, green: 0.24, blue: 0.27), Color(red: 0.05, green: 0.06, blue: 0.08)],
        startPoint: .top, endPoint: .bottom)
      GeometryReader { proxy in
        let width = proxy.size.width
        let height = proxy.size.height
        Circle()
          .fill(light ? Color.white : Color(red: 0.55, green: 0.60, blue: 0.62))
          .frame(width: width * 0.55)
          .position(x: width * 0.78, y: height * 0.22)
        Ellipse()
          .fill(light ? Color(red: 0.86, green: 0.52, blue: 0.44) : Color(red: 0.02, green: 0.03, blue: 0.04))
          .frame(width: width * 0.9, height: height * 0.45)
          .position(x: width * 0.25, y: height * 0.95)
      }
    }
  }
}

/// Places a panel on a wallpaper the way the window server would: the area behind it blurred.
struct PreviewStage<Content: View>: View {
  let light: Bool
  let size: CGSize
  var corner: CGFloat = 14
  /// Draws the close, minimise and zoom buttons where a real window puts them, so a heading that
  /// would collide with them shows up in the picture.
  var windowButtons = false
  @ViewBuilder let content: () -> Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    ZStack {
      SampleWallpaper(light: light)
      content()
        .environment(\.renderingPreview, true)
        .background {
          ZStack {
            SampleWallpaper(light: light)
              .frame(width: size.width, height: size.height)
              .blur(radius: 36)
            // The system blur material darkens what it blurs; this stands in for that.
            Color.black.opacity(0.22)
          }
        }
        .overlay(alignment: .topLeading) {
          if windowButtons {
            HStack(spacing: 8) {
              Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
              Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
              Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.26))
            }
            .frame(width: 52, height: 12)
            .padding(.leading, 13)
            .padding(.top, 8)
          }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .background { shape.fill(Color.black.opacity(0.35)).blur(radius: 26).offset(y: 14) }
    }
    .frame(width: size.width, height: size.height)
  }
}

@MainActor
enum UIPreview {
  /// A model over an in-memory store filled with invented tasks, suggestions and index entries.
  static func sampleModel() -> AppModel? {
    guard let store = try? Store.inMemory() else { return nil }
    let now = Date()

    let project = Entity(
      kind: .project, name: "Systems project", aliases: ["p3-raft"],
      summary: "Course project: a replicated key-value store built on Raft.",
      firstSeen: now.addingTimeInterval(-6 * 86_400), lastSeen: now)
    let person = Entity(
      kind: .person, name: "Maya Chen", summary: "Project partner.",
      firstSeen: now.addingTimeInterval(-5 * 86_400), lastSeen: now)
    let paper = Entity(
      kind: .document, name: "In Search of an Understandable Consensus Algorithm",
      aliases: ["Raft paper"], summary: "The Raft paper.",
      firstSeen: now.addingTimeInterval(-4 * 86_400), lastSeen: now)
    let topic = Entity(
      kind: .topic, name: "Consensus protocols", firstSeen: now.addingTimeInterval(-4 * 86_400),
      lastSeen: now)
    [project, person, paper, topic].forEach(store.save)

    let notes: [(Entity, [String])] = [
      (project, ["Debugged leader election after a network partition.", "Wrote the log-replication tests.", "Read the checkpoint rubric."]),
      (person, ["Messaged about splitting the checkpoint work."]),
      (paper, ["Reread section 5 on leader election."]),
      (topic, ["Watched a talk on consensus failure modes."]),
    ]
    for reading in 1...3 {
      let when = now.addingTimeInterval(Double(-reading) * 3600)
      for (entity, contexts) in notes where reading <= contexts.count || entity.id == project.id {
        store.addSighting(
          entityID: entity.id, observationID: Int64(reading), ts: when,
          context: contexts[min(reading - 1, contexts.count - 1)])
      }
    }

    // A second, unrelated group, so the graph has two clusters to pull apart.
    let app = Entity(kind: .project, name: "Menu bar app", firstSeen: now, lastSeen: now, seenCount: 5)
    let friend = Entity(kind: .person, name: "Sam Ortiz", firstSeen: now, lastSeen: now, seenCount: 2)
    let glass = Entity(kind: .topic, name: "Glass interfaces", firstSeen: now, lastSeen: now, seenCount: 2)
    let notesDoc = Entity(kind: .document, name: "Design notes", firstSeen: now, lastSeen: now, seenCount: 1)
    let alone = Entity(kind: .topic, name: "Longitude problem", firstSeen: now, lastSeen: now, seenCount: 1)
    [app, friend, glass, notesDoc, alone].forEach(store.save)
    // Entries with no links yet, which is how most of a young index looks.
    let unlinked: [(EntityKind, String)] = [
      (.person, "Priya Raman"), (.person, "Leo Fischer"), (.project, "Reading group"),
      (.project, "Apartment search"), (.document, "Lease draft"), (.document, "Lecture 14 slides"),
      (.topic, "Type design"), (.topic, "Sourdough"), (.person, "Noor Haddad"), (.document, "Trip budget"),
    ]
    for (kind, name) in unlinked {
      store.save(Entity(kind: kind, name: name, firstSeen: now, lastSeen: now, seenCount: 1))
    }

    let stated: [(Entity, Entity, String)] = [
      (person, project, "works on"), (paper, project, "is the basis of"), (paper, topic, "is about"),
      (topic, project, "is used in"), (friend, app, "is testing"), (glass, app, "is the look of"),
      (notesDoc, app, "belongs to"), (notesDoc, glass, "is about"),
    ]
    for (index, relation) in stated.enumerated() {
      store.link(
        relation.0.id, relation.1.id, how: relation.2, evidence: "sample", observationID: Int64(index + 1),
        ts: now)
    }
    store.link(person.id, project.id, how: "works on", evidence: "sample", observationID: 99, ts: now)

    store.save(
      TaskItem(
        title: "Submit the systems project checkpoint",
        detail: "Log replication passes locally; the partition test still fails on rejoin.",
        why: "Due Friday at 5pm, and you've opened the handout four times this week.",
        url: "https://example.edu/systems/checkpoint", sourceApp: "Safari",
        deadline: now.addingTimeInterval(2 * 86_400 + 3600), importance: 0.92, estMinutes: 90,
        firstSeen: now.addingTimeInterval(-3 * 86_400), lastSeen: now, seenCount: 4,
        projectID: project.id))
    store.save(
      TaskItem(
        title: "Reply to Maya about the demo slot",
        detail: "She asked whether Thursday 2pm or Friday 10am works.",
        why: "Maya asked yesterday and is waiting on you to book the room.", sourceApp: "Messages",
        bundleID: "com.apple.MobileSMS", waitingPerson: "Maya", importance: 0.7, estMinutes: 5,
        firstSeen: now.addingTimeInterval(-86_400), lastSeen: now, seenCount: 2,
        projectID: project.id))
    store.save(
      TaskItem(
        title: "Finish the reading response for seminar",
        why: "You stopped two paragraphs in on Tuesday.", sourceApp: "Pages",
        bundleID: "com.apple.iWork.Pages", deadline: now.addingTimeInterval(5 * 86_400),
        importance: 0.5, estMinutes: 40, firstSeen: now.addingTimeInterval(-2 * 86_400),
        lastSeen: now))
    store.save(
      TaskItem(
        title: "Renew the library books", importance: 0.25, estMinutes: 5,
        firstSeen: now.addingTimeInterval(-86_400), lastSeen: now, origin: "manual"))

    store.add(
      Recommendation(
        title: "Paxos vs Raft: have we reached consensus on distributed consensus?",
        url: "https://arxiv.org/abs/2004.05074", source: "arXiv", kind: "paper",
        why: "Sets the protocol you've been debugging beside the one it replaced.",
        bucket: "related", estMinutes: 25, created: now))
    store.add(
      Recommendation(
        title: "How a 17th-century clockmaker solved the longitude problem",
        url: "https://example.com/longitude", source: "Hacker News", kind: "article",
        why: "Nothing to do with your week, which is the point. A good twenty minutes.",
        bucket: "explore", estMinutes: 20, created: now.addingTimeInterval(-60)))

    store.addObservation(
      start: now.addingTimeInterval(-780), end: now.addingTimeInterval(-180),
      extraction: Extraction(
        summary: "Working on the systems project.", activities: [], commitments: [],
        completions: [], content: []))

    let model = AppModel(store: store)
    model.hasAPIKey = true
    model.screenPermission = true
    model.accessibilityPermission = true
    model.mode = .balanced
    model.reload()
    return model
  }

  /// Draws the Projects window from a database file, to see how a real index lays out. Point it
  /// at a copy: opening a file brings it up to this build's schema.
  static func renderGraph(database: String, to url: URL) -> Bool {
    guard let store = try? Store(path: database, framesDirectory: FileManager.default.temporaryDirectory)
    else { return false }
    let model = AppModel(store: store)
    model.reload()
    let view = PreviewStage(light: false, size: CGSize(width: 1260, height: 860), windowButtons: true) {
      GraphView().frame(width: 1100, height: 700).environmentObject(model)
    }
    return write(view, to: url)
  }

  private static func write<Content: View>(_ view: Content, to url: URL) -> Bool {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return false }
    return (try? png.write(to: url)) != nil
  }

  /// Draws each screen and returns the names of the files written.
  static func render(to directory: URL) -> [String] {
    guard let model = sampleModel() else { return [] }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var written: [String] = []

    func shot<Content: View>(
      _ name: String, light: Bool, size: CGSize, window: Bool = false, @ViewBuilder _ content: () -> Content
    ) {
      let panel = content().environmentObject(model)
      let view = PreviewStage(light: light, size: size, windowButtons: window) { panel }
      if write(view, to: directory.appendingPathComponent(name)) { written.append(name) }
    }

    let popoverStage = CGSize(width: 520, height: 520)
    let tasksStage = CGSize(width: 800, height: 700)
    model.cardIndex = 0
    shot("popover-task-light.png", light: true, size: popoverStage) { PopoverView() }
    shot("popover-task-dark.png", light: false, size: popoverStage) { PopoverView() }

    if let index = model.feed.firstIndex(where: { if case .suggestion = $0 { return true } else { return false } }) {
      model.cardIndex = index
      shot("popover-suggestion-light.png", light: true, size: popoverStage) { PopoverView() }
      shot("popover-suggestion-dark.png", light: false, size: popoverStage) { PopoverView() }
    }

    if var underway = model.ranked.dropFirst().first {
      // Set straight in the store. `model.start` would also open the task's app, which a preview
      // must never do.
      underway.startedAt = Date().addingTimeInterval(-25 * 60)
      model.store.save(underway)
      model.reload()
      model.cardIndex = 0
      shot("popover-in-progress-light.png", light: true, size: popoverStage) { PopoverView() }
      shot("tasks-in-progress-dark.png", light: false, size: tasksStage, window: true) {
        TaskListView().frame(width: 640, height: 540)
      }
      underway.startedAt = nil
      model.store.save(underway)
      model.reload()
    }

    model.cardIndex = 0
    model.offerComparison()
    shot("popover-compare-light.png", light: true, size: popoverStage) { PopoverView() }
    model.skipComparison()

    model.hasAPIKey = false
    model.lastError = "Claude API error 401: invalid x-api-key"
    shot("popover-setup-light.png", light: true, size: CGSize(width: 520, height: 620)) { PopoverView() }
    model.hasAPIKey = true
    model.lastError = nil

    shot("tasks-light.png", light: true, size: tasksStage, window: true) {
      TaskListView().frame(width: 640, height: 540)
    }
    shot("tasks-dark.png", light: false, size: tasksStage, window: true) {
      TaskListView().frame(width: 640, height: 540)
    }

    let project = model.entities(.project).first { $0.name == "Systems project" }?.id
    let graphStage = CGSize(width: 1260, height: 860)
    shot("graph-light.png", light: true, size: graphStage, window: true) {
      GraphView().frame(width: 1100, height: 700)
    }
    shot("graph-selected-dark.png", light: false, size: graphStage, window: true) {
      GraphView(selection: project).frame(width: 1100, height: 700)
    }
    // A link caught halfway: drawn once so the graph knows its size, then the pointer presses the
    // plus and drags it to another dot, exactly as the mouse would, and it is drawn again.
    let linking = GraphController()
    for pass in 0..<2 {
      shot("graph-linking-dark.png", light: false, size: graphStage, window: true) {
        GraphView(selection: project, preparedGraph: linking).frame(width: 1100, height: 700)
      }
      if pass == 0, let plus = linking.plusCentre,
        let other = model.graph().entities.first(where: { $0.name == "Sam Ortiz" }),
        let end = linking.screenPosition(of: other.id)
      {
        linking.pointerDown(at: plus)
        linking.pointerDragged(to: CGPoint(x: (plus.x + end.x) / 2, y: (plus.y + end.y) / 2))
        linking.pointerDragged(to: CGPoint(x: end.x + 5, y: end.y - 4))
      }
    }
    shot("projects-light.png", light: true, size: graphStage, window: true) {
      GraphView(selection: project, showsGraph: false).frame(width: 1100, height: 700)
    }
    return written
  }
}
#endif
