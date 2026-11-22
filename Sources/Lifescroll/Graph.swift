import SwiftUI

// The node graph: every entry in the index is a dot, every stated relationship a line, and entries
// that are related pull together into clusters.

enum GraphLayout {
  /// Places nodes so that linked ones sit close and unlinked ones drift apart, by simulating
  /// springs along the links and a push between every pair. The result is in a square from -1 to 1
  /// and is the same every time for the same input.
  static func positions(nodes: [String], edges: [GraphEdge], iterations: Int = 300) -> [String: CGPoint] {
    let ids = nodes.sorted()
    guard ids.count > 1 else { return Dictionary(uniqueKeysWithValues: ids.map { ($0, .zero) }) }
    let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    let count = ids.count

    // Start on a ring, with radii varied by position so nothing begins exactly stacked.
    var x = [Double](repeating: 0, count: count)
    var y = [Double](repeating: 0, count: count)
    for i in 0..<count {
      let angle = 2 * Double.pi * Double(i) / Double(count)
      let radius = 0.5 + 0.5 * Double((i * 37) % 11) / 10
      x[i] = cos(angle) * radius
      y[i] = sin(angle) * radius
    }

    let links = edges.compactMap { edge -> (Int, Int, Double)? in
      guard let a = index[edge.a], let b = index[edge.b], a != b else { return nil }
      return (a, b, 1 + log(Double(max(edge.weight, 1))))
    }
    let spacing = sqrt(4.0 / Double(count))

    for step in 0..<iterations {
      var dx = [Double](repeating: 0, count: count)
      var dy = [Double](repeating: 0, count: count)

      // Every pair pushes apart, more strongly the closer they are.
      for i in 0..<(count - 1) {
        for j in (i + 1)..<count {
          let ox = x[i] - x[j]
          let oy = y[i] - y[j]
          let distance = max((ox * ox + oy * oy).squareRoot(), 0.01)
          let push = spacing * spacing / distance
          dx[i] += ox / distance * push
          dy[i] += oy / distance * push
          dx[j] -= ox / distance * push
          dy[j] -= oy / distance * push
        }
      }
      // Linked pairs pull together, more strongly the more often the link was stated.
      for (a, b, strength) in links {
        let ox = x[a] - x[b]
        let oy = y[a] - y[b]
        let distance = max((ox * ox + oy * oy).squareRoot(), 0.01)
        let pull = distance * distance / spacing * strength
        dx[a] -= ox / distance * pull
        dy[a] -= oy / distance * pull
        dx[b] += ox / distance * pull
        dy[b] += oy / distance * pull
      }
      // A gentle pull to the middle keeps separate clusters on the page.
      for i in 0..<count {
        dx[i] -= x[i] * spacing * 0.9
        dy[i] -= y[i] * spacing * 0.9
      }
      // Moves shrink as the layout settles.
      let limit = 0.25 * (1 - Double(step) / Double(iterations)) + 0.002
      for i in 0..<count {
        let length = max((dx[i] * dx[i] + dy[i] * dy[i]).squareRoot(), 1e-9)
        x[i] += dx[i] / length * min(length, limit)
        y[i] += dy[i] / length * min(length, limit)
      }
    }

    let reach = max((0..<count).map { max(abs(x[$0]), abs(y[$0])) }.max() ?? 1, 1e-9)
    return Dictionary(
      uniqueKeysWithValues: (0..<count).map { (ids[$0], CGPoint(x: x[$0] / reach, y: y[$0] / reach)) })
  }
}

/// The graph in motion. Each entry is a body pushed away from the others and pulled along its
/// links; it keeps moving a little every frame until it comes to rest. Changing the data nudges it
/// awake again, so new dots and lines ease into place instead of jumping.
final class GraphSimulation {
  struct Body: Equatable {
    var x: Double
    var y: Double
    var vx = 0.0
    var vy = 0.0
    /// Held by the pointer: forces do not move it.
    var held = false
  }

  /// Natural length of a link, in points.
  static let linkLength = 96.0
  static let restingEnergy = 0.02

  // Bodies live in a plain array and links refer to them by position, so a tick is arithmetic on
  // arrays with no dictionary lookups or sorting. That is what keeps large graphs smooth.
  private var ids: [String] = []
  private var index: [String: Int] = [:]
  private var store: [Body] = []
  private var links: [(a: Int, b: Int, strength: Double)] = []
  private var signature = ""
  /// How lively the simulation is: 1 when freshly disturbed, falling toward 0 as it settles.
  private(set) var energy = 0.0
  private var lastStep: Date?
  private var holding = 0

  /// The bodies by id. Built on request, for inspection; drawing uses `position(of:)`.
  var bodies: [String: Body] {
    Dictionary(uniqueKeysWithValues: zip(ids, store))
  }

  var isAtRest: Bool { energy < Self.restingEnergy && holding == 0 }

  private func relink(_ edges: [GraphEdge]) {
    links = edges.compactMap { edge in
      guard let a = index[edge.a], let b = index[edge.b], a != b else { return nil }
      return (a, b, 1 + 0.3 * log(Double(max(edge.weight, 1))))
    }
  }

  /// Brings the simulation in line with the data. Known dots stay where they are; new ones start
  /// beside something they are linked to, so they slide a short way, not across the whole window.
  func sync(nodes: [String], edges: [GraphEdge]) {
    let key = nodes.sorted().joined(separator: ",") + "|"
      + edges.map { "\($0.a)>\($0.b)>\($0.weight)" }.sorted().joined(separator: ",")
    guard key != signature else { return }
    signature = key
    let wanted = nodes.sorted()

    if store.isEmpty {
      // First sight of the data: start from the settled layout so nothing flies in from afar.
      // Both this and the settling below cost the square of the number of dots per step, so the
      // number of steps shrinks as the index grows.
      let pairs = max(wanted.count * wanted.count, 1)
      let start = GraphLayout.positions(
        nodes: wanted, edges: edges, iterations: max(20, min(300, 2_000_000 / pairs)))
      let spread = 60.0 * Double(max(wanted.count, 1)).squareRoot() + 40
      ids = wanted
      index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
      store = ids.map {
        let unit = start[$0] ?? .zero
        return Body(x: Double(unit.x) * spread, y: Double(unit.y) * spread)
      }
      relink(edges)
      // Settle before the first frame, so the window opens on a finished picture. Motion is kept
      // for changes the user makes, where it shows what moved. The work is capped so a very large
      // index cannot hold the window up; it finishes settling on screen instead.
      energy = 1
      let budget = max(30, min(600, 4_000_000 / pairs))
      for _ in 0..<budget where !isAtRest { tick() }
      if budget == 600 { energy = 0 }
      return
    }

    var kept: [String: Body] = [:]
    for (id, body) in zip(ids, store) where index[id] != nil { kept[id] = body }
    let old = kept
    var fresh: [Body] = []
    for (offset, id) in wanted.enumerated() {
      if let body = old[id] {
        fresh.append(body)
        continue
      }
      let neighbour = edges.first { $0.a == id || $0.b == id }
        .flatMap { old[$0.a == id ? $0.b : $0.a] }
      let angle = Double(offset) * 2.399963  // the golden angle, so several arrivals fan out
      let radius = neighbour == nil ? 150.0 : 50.0
      fresh.append(
        Body(x: (neighbour?.x ?? 0) + cos(angle) * radius, y: (neighbour?.y ?? 0) + sin(angle) * radius))
    }
    ids = wanted
    index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    store = fresh
    holding = store.filter(\.held).count
    relink(edges)
    energy = max(energy, 0.7)
  }

  func wake() { energy = max(energy, 0.5) }

  /// Advances to `now`, at most a few ticks per frame so a stalled frame cannot fling things about.
  func step(to now: Date) {
    defer { lastStep = now }
    guard let lastStep else { return tick() }
    let ticks = min(max(Int((now.timeIntervalSince(lastStep) * 60).rounded()), 1), 3)
    for _ in 0..<ticks { tick() }
  }

  /// One sixtieth of a second of physics.
  func tick() {
    guard !isAtRest else { return }
    let count = store.count
    var fx = [Double](repeating: 0, count: count)
    var fy = [Double](repeating: 0, count: count)

    if count > 1 {
      for i in 0..<(count - 1) {
        for j in (i + 1)..<count {
          var dx = store[i].x - store[j].x
          var dy = store[i].y - store[j].y
          if dx == 0 && dy == 0 {
            dx = 0.5
            dy = 0.3
          }
          let squared = max(dx * dx + dy * dy, 36)
          let distance = squared.squareRoot()
          let push = 5200 / squared
          fx[i] += dx / distance * push
          fy[i] += dy / distance * push
          fx[j] -= dx / distance * push
          fy[j] -= dy / distance * push
        }
      }
    }
    for link in links {
      let dx = store[link.b].x - store[link.a].x
      let dy = store[link.b].y - store[link.a].y
      let distance = max((dx * dx + dy * dy).squareRoot(), 0.01)
      let pull = (distance - Self.linkLength) * 0.05 * link.strength
      fx[link.a] += dx / distance * pull
      fy[link.a] += dy / distance * pull
      fx[link.b] -= dx / distance * pull
      fy[link.b] -= dy / distance * pull
    }
    for i in 0..<count where !store[i].held {
      // A light pull to the middle keeps separate clusters from wandering off.
      store[i].vx = (store[i].vx + (fx[i] - store[i].x * 0.012) * energy) * 0.80
      store[i].vy = (store[i].vy + (fy[i] - store[i].y * 0.012) * energy) * 0.80
      store[i].x += store[i].vx
      store[i].y += store[i].vy
    }
    energy *= 0.985
  }

  func position(of id: String) -> CGPoint? {
    index[id].map { CGPoint(x: store[$0].x, y: store[$0].y) }
  }

  /// Moves a dot with the pointer. The rest of the graph reacts while it is held.
  func hold(_ id: String, at point: CGPoint) {
    guard let i = index[id] else { return }
    if !store[i].held { holding += 1 }
    store[i] = Body(x: Double(point.x), y: Double(point.y), held: true)
    wake()
  }

  func release(_ id: String) {
    guard let i = index[id], store[i].held else { return }
    store[i].held = false
    holding -= 1
    wake()
  }

  /// The box that contains every dot, for fitting the graph into the window.
  var bounds: CGRect {
    guard let first = store.first else { return .zero }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for body in store {
      minX = min(minX, body.x)
      maxX = max(maxX, body.x)
      minY = min(minY, body.y)
      maxY = max(maxY, body.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}

extension EntityKind {
  /// Kinds are told apart by tone on the graph, where there is no room for an icon and a label each.
  var tone: Color {
    switch self {
    case .project: return Color.white
    case .person: return Glass.mint
    case .document: return Color(white: 0.62)
    case .topic: return Glass.blushRose
    }
  }
}

/// Forwards two-finger scrolling over the graph, which SwiftUI has no gesture for.
final class GraphScrollMonitor {
  weak var window: NSWindow?
  var isOver = false
  /// The graph's current size, kept up to date so the handler never works from an old one.
  var size: CGSize = .zero
  private var monitor: Any?

  func start(onScroll: @escaping (CGSize, Bool) -> Void) {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self, self.isOver, let window = self.window, event.window === window else { return event }
      onScroll(
        CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
        event.modifierFlags.contains(.command))
      return nil
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  deinit { stop() }
}

struct GraphCanvas: View {
  let entities: [Entity]
  let edges: [GraphEdge]
  @Binding var selection: String?
  var onLink: (String, String) -> Void = { _, _ in }

  @Environment(\.renderingPreview) private var preview
  @State private var simulation = GraphSimulation()
  @State private var scrollMonitor = GraphScrollMonitor()
  @State private var zoom: CGFloat = 1
  @State private var settledZoom: CGFloat = 1
  @State private var pan: CGSize = .zero
  @State private var fitted = false
  @State private var hovered: String?
  /// False once the graph has come to rest, which stops the per-frame redraw.
  @State private var animating = true
  @State private var drag: DragKind?
  /// Where the pointer is while a link is being pulled out of the plus handle.
  @State private var linkEnd: CGPoint?

  private enum DragKind: Equatable {
    case pan(start: CGSize)
    case node(String)
    case link(from: String)
  }

  private func radius(_ entity: Entity) -> CGFloat { 5 + CGFloat(min(entity.seenCount, 8)) * 0.7 }

  /// The zoom and offset that bring the whole graph into view.
  private func fitting(_ size: CGSize) -> (zoom: CGFloat, pan: CGSize) {
    let bounds = simulation.bounds
    let wide = max(bounds.width, 1) + 200
    let tall = max(bounds.height, 1) + 150
    return (
      min(max(min(size.width / wide, size.height / tall), 0.3), 1.3),
      CGSize(width: -bounds.midX, height: -bounds.midY)
    )
  }

  /// The view in use: the user's own once they have moved it, and until then a fit of everything.
  private func view(_ size: CGSize) -> (zoom: CGFloat, pan: CGSize) {
    fitted ? (zoom, pan) : fitting(size)
  }

  /// Fixes the view at a fit of everything, once, as soon as the size is known. After that the
  /// view only changes when the user moves it, so dots easing into place do not drag it about.
  private func adopt(_ size: CGSize) {
    guard !fitted, size.width > 0, size.height > 0, !entities.isEmpty else { return }
    let fit = fitting(size)
    zoom = fit.zoom
    settledZoom = fit.zoom
    pan = fit.pan
    fitted = true
  }

  private func screen(_ world: CGPoint, _ size: CGSize) -> CGPoint {
    let view = view(size)
    return CGPoint(
      x: size.width / 2 + (world.x + view.pan.width) * view.zoom,
      y: size.height / 2 + (world.y + view.pan.height) * view.zoom)
  }

  private func world(_ point: CGPoint, _ size: CGSize) -> CGPoint {
    let view = view(size)
    return CGPoint(
      x: (point.x - size.width / 2) / view.zoom - view.pan.width,
      y: (point.y - size.height / 2) / view.zoom - view.pan.height)
  }

  private func node(at point: CGPoint, _ size: CGSize, slack: CGFloat = 8) -> String? {
    entities.compactMap { entity -> (String, CGFloat)? in
      guard let position = simulation.position(of: entity.id) else { return nil }
      let centre = screen(position, size)
      let distance = hypot(centre.x - point.x, centre.y - point.y)
      return distance <= radius(entity) * view(size).zoom + slack ? (entity.id, distance) : nil
    }.min { $0.1 < $1.1 }?.0
  }

  /// Where the plus handle sits: just up and to the right of the selected dot.
  private func plusCentre(_ size: CGSize) -> CGPoint? {
    guard let selection, let entity = entities.first(where: { $0.id == selection }),
      let position = simulation.position(of: selection)
    else { return nil }
    let centre = screen(position, size)
    let offset = radius(entity) * view(size).zoom + 15
    return CGPoint(x: centre.x + offset * 0.72, y: centre.y - offset * 0.72)
  }

  private func isOnPlus(_ point: CGPoint, _ size: CGSize) -> Bool {
    guard let centre = plusCentre(size) else { return false }
    return hypot(centre.x - point.x, centre.y - point.y) <= 13
  }


  var body: some View {
    let _ = simulation.sync(nodes: entities.map(\.id), edges: edges)
    let neighbours: Set<String> = (hovered ?? selection).map { focus in
      Set(edges.compactMap { $0.a == focus ? $0.b : ($0.b == focus ? $0.a : nil) } + [focus])
    } ?? []
    let focus = hovered ?? selection

    GeometryReader { proxy in
      TimelineView(.animation(paused: !animating)) { timeline in
        Canvas { context, size in
          simulation.step(to: timeline.date)
          draw(&context, size, focus: focus, neighbours: neighbours)
        }
      }
      .clipped()
      .contentShape(Rectangle())
      .onAppear {
        scrollMonitor.size = proxy.size
        adopt(proxy.size)
      }
      .onChange(of: proxy.size) { _, size in
        scrollMonitor.size = size
        adopt(size)
      }
      .onContinuousHover { phase in
        switch phase {
        case .active(let point):
          scrollMonitor.isOver = true
          let over = node(at: point, proxy.size)
          if over != hovered { hovered = over }
        case .ended:
          scrollMonitor.isOver = false
          hovered = nil
        }
      }
      .gesture(
        SpatialTapGesture().onEnded { tap in
          // A click on a dot selects it; a click on empty space clears the selection.
          if !isOnPlus(tap.location, proxy.size) { selection = node(at: tap.location, proxy.size) }
        }
      )
      .simultaneousGesture(
        DragGesture(minimumDistance: 3)
          .onChanged { value in
            if drag == nil {
              adopt(proxy.size)
              // What the drag began on decides what it does.
              if let selection, isOnPlus(value.startLocation, proxy.size) {
                drag = .link(from: selection)
              } else if let id = node(at: value.startLocation, proxy.size) {
                drag = .node(id)
              } else {
                drag = .pan(start: pan)
              }
            }
            switch drag {
            case .pan(let start):
              pan = CGSize(
                width: start.width + value.translation.width / zoom,
                height: start.height + value.translation.height / zoom)
            case .node(let id):
              simulation.hold(id, at: world(value.location, proxy.size))
              animating = true
            case .link:
              linkEnd = value.location
            case nil:
              break
            }
          }
          .onEnded { value in
            switch drag {
            case .node(let id):
              simulation.release(id)
              animating = true
            case .link(let from):
              if let target = node(at: value.location, proxy.size, slack: 14), target != from {
                onLink(from, target)
              }
            default:
              break
            }
            drag = nil
            linkEnd = nil
          }
      )
      .simultaneousGesture(
        MagnificationGesture()
          .onChanged {
            adopt(proxy.size)
            zoom = min(max(settledZoom * $0, 0.3), 4)
          }
          .onEnded { _ in settledZoom = zoom }
      )
      .background {
        if !preview { WindowReader { scrollMonitor.window = $0 } }
      }
      .onAppear {
        guard !preview else { return }
        scrollMonitor.start { delta, zooming in
          adopt(scrollMonitor.size)
          if zooming {
            zoom = min(max(zoom * (1 + delta.height * 0.01), 0.3), 4)
            settledZoom = zoom
          } else {
            pan = CGSize(width: pan.width + delta.width / zoom, height: pan.height + delta.height / zoom)
          }
        }
      }
      .onDisappear { scrollMonitor.stop() }
    }
    // Any change to the data wakes the animation; it sleeps again once the dots stop moving.
    .onChange(of: edges) { animating = true }
    .onChange(of: entities.map(\.id)) { animating = true }
    .task(id: animating) {
      guard animating, !preview else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 400_000_000)
        if simulation.isAtRest {
          animating = false
          break
        }
      }
    }
    .overlay(alignment: .bottomLeading) {
      HStack(spacing: 12) {
        ForEach(EntityKind.allCases) { kind in
          HStack(spacing: 5) {
            Circle().fill(kind.tone).frame(width: 7, height: 7)
            Text(kind.plural).font(.system(size: 11)).foregroundStyle(Glass.soft)
          }
        }
      }
      .padding(12)
    }
    .overlay(alignment: .topLeading) {
      if selection != nil {
        Text("Drag the + onto another dot to link them")
          .font(.system(size: 11))
          .foregroundStyle(Glass.faint)
          .padding(12)
      }
    }
  }

  private func draw(
    _ context: inout GraphicsContext, _ size: CGSize, focus: String?, neighbours: Set<String>
  ) {
    for edge in edges {
      guard let a = simulation.position(of: edge.a), let b = simulation.position(of: edge.b) else { continue }
      let lit = focus != nil && (edge.a == focus || edge.b == focus)
      var path = Path()
      path.move(to: screen(a, size))
      path.addLine(to: screen(b, size))
      context.stroke(
        path, with: .color(Color.white.opacity(lit ? 0.6 : (focus == nil ? 0.18 : 0.06))),
        lineWidth: lit ? 1.4 : 1)
    }

    // A link being pulled out of the plus handle.
    if case .link(let from) = drag, let end = linkEnd, let start = simulation.position(of: from) {
      var path = Path()
      path.move(to: screen(start, size))
      path.addLine(to: end)
      context.stroke(
        path, with: .color(Color.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1.4, dash: [4, 4]))
    }

    // Bigger dots are drawn, and labelled, first; a label that would land on one already placed is
    // left out, so names never pile on top of each other.
    let zoom = view(size).zoom
    // Dots and the plus handle count as taken space, so no name is written across them.
    var labelBoxes: [CGRect] = entities.compactMap { entity in
      simulation.position(of: entity.id).map {
        let centre = screen($0, size)
        let dot = radius(entity) * zoom
        return CGRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2)
      }
    }
    if let plus = plusCentre(size) {
      labelBoxes.append(CGRect(x: plus.x - 10, y: plus.y - 10, width: 20, height: 20))
    }
    let ordered = entities.sorted {
      let first = ($0.id == focus ? 2 : (neighbours.contains($0.id) ? 1 : 0), $0.seenCount)
      let second = ($1.id == focus ? 2 : (neighbours.contains($1.id) ? 1 : 0), $1.seenCount)
      return first > second
    }
    for entity in ordered {
      guard let position = simulation.position(of: entity.id) else { continue }
      let centre = screen(position, size)
      let dimmed = focus != nil && !neighbours.contains(entity.id)
      let dot = radius(entity) * zoom * (entity.id == hovered ? 1.15 : 1)
      context.fill(
        Path(ellipseIn: CGRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2)),
        with: .color(entity.kind.tone.opacity(dimmed ? 0.2 : 0.95)))
      if entity.id == selection {
        context.stroke(
          Path(ellipseIn: CGRect(x: centre.x - dot - 4, y: centre.y - dot - 4, width: dot * 2 + 8, height: dot * 2 + 8)),
          with: .color(Color.white.opacity(0.9)), lineWidth: 1.5)
      }

      let important = entity.id == focus || neighbours.contains(entity.id)
      // Zoomed far out, only the names that matter are shown.
      guard important || zoom >= 0.6 else { continue }
      let name = entity.name.count > 26 ? String(entity.name.prefix(25)) + "…" : entity.name
      let text = context.resolve(
        Text(name)
          .font(.system(size: 10.5, weight: entity.id == focus ? .semibold : .regular))
          .foregroundColor(Color.white.opacity(dimmed ? 0.25 : (important ? 0.96 : 0.7))))
      let measured = text.measure(in: CGSize(width: 240, height: 40))
      // Under the dot if there is room, otherwise above it or to either side.
      let spots = [
        CGRect(x: centre.x - measured.width / 2, y: centre.y + dot + 4, width: measured.width, height: measured.height),
        CGRect(x: centre.x - measured.width / 2, y: centre.y - dot - 4 - measured.height, width: measured.width, height: measured.height),
        CGRect(x: centre.x + dot + 6, y: centre.y - measured.height / 2, width: measured.width, height: measured.height),
        CGRect(x: centre.x - dot - 6 - measured.width, y: centre.y - measured.height / 2, width: measured.width, height: measured.height),
      ]
      let free = spots.first { spot in
        !labelBoxes.contains { $0.insetBy(dx: -4, dy: -2).intersects(spot) }
      }
      // A name that matters is always shown; any other is dropped when nowhere is free.
      guard let box = free ?? (important ? spots.first : nil) else { continue }
      labelBoxes.append(box)
      context.draw(text, at: CGPoint(x: box.midX, y: box.midY))
    }

    // The plus handle on the selected dot: drag it onto another dot to link the two.
    if let plus = plusCentre(size) {
      let disc = CGRect(x: plus.x - 9, y: plus.y - 9, width: 18, height: 18)
      context.fill(Path(ellipseIn: disc), with: .color(Color.white.opacity(0.95)))
      var cross = Path()
      cross.move(to: CGPoint(x: plus.x - 4, y: plus.y))
      cross.addLine(to: CGPoint(x: plus.x + 4, y: plus.y))
      cross.move(to: CGPoint(x: plus.x, y: plus.y - 4))
      cross.addLine(to: CGPoint(x: plus.x, y: plus.y + 4))
      context.stroke(cross, with: .color(Color(white: 0.08)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }
  }
}
