import AppKit
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

extension GraphLayout {
  /// How much wider than tall the picture is. Windows are landscape, so the graph is too.
  static let stretch = 1.3

  /// The groups of entries joined to each other by links, biggest first. An entry with no links is
  /// a group of one.
  static func components(nodes: [String], edges: [GraphEdge]) -> [[String]] {
    let ids = nodes.sorted()
    let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    var parent = Array(0..<ids.count)
    func root(_ start: Int) -> Int {
      var i = start
      while parent[i] != i {
        parent[i] = parent[parent[i]]
        i = parent[i]
      }
      return i
    }
    for edge in edges {
      guard let a = index[edge.a], let b = index[edge.b] else { continue }
      let first = root(a), second = root(b)
      if first != second { parent[max(first, second)] = min(first, second) }
    }
    var groups: [Int: [String]] = [:]
    for i in 0..<ids.count { groups[root(i), default: []].append(ids[i]) }
    return groups.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
  }

  /// How far from its middle a cluster of this many entries starts out. Measured against where
  /// real clusters settle, so the starting picture is already close to the finished one.
  static func startingReach(members: Int) -> Double {
    members <= 2 ? GraphSimulation.linkLength / 2 : GraphSimulation.linkLength * 0.6 * Double(members).squareRoot()
  }

  /// Roughly how much room a cluster of this many entries takes, as the radius of a circle.
  static func nominalRadius(members: Int) -> Double {
    startingReach(members: members) * (members <= 2 ? 1 : 1.1) + GraphSimulation.clusterMargin
  }

  /// The radius of the middle region that holds every cluster. Unlinked entries stay outside it.
  /// It depends only on how big the clusters are, not on where they are, so it holds still.
  static func coreRadius(clusterSizes: [Int]) -> Double {
    guard !clusterSizes.isEmpty else { return 0 }
    let half = GraphSimulation.clusterGap / 2
    let area = clusterSizes.reduce(0.0) { $0 + pow(nominalRadius(members: $1) + half, 2) }
    return area.squareRoot() * 1.1 - half
  }

  /// Where everything starts, in points. Each cluster is laid out on its own and the clusters are
  /// then set down with clear space between them, biggest in the middle. Entries with no links go
  /// on rings around the outside, grouped by `groups` so that like sits with like.
  static func arranged(
    nodes: [String], edges: [GraphEdge], groups: [String: Int] = [:], iterations: Int = 300
  ) -> [String: CGPoint] {
    let parts = components(nodes: nodes, edges: edges)
    let clusters = parts.filter { $0.count > 1 }
    let loners = parts.filter { $0.count == 1 }.map { $0[0] }
      .sorted { (groups[$0] ?? 0, $0) < (groups[$1] ?? 0, $1) }
    var placed: [String: CGPoint] = [:]
    var discs: [(x: Double, y: Double, r: Double)] = []

    for members in clusters {
      let inside = Set(members)
      let local: [String: CGPoint]
      let scale = startingReach(members: members.count)
      if members.count == 2 {
        local = [members[0]: CGPoint(x: -1, y: 0), members[1]: CGPoint(x: 1, y: 0)]
      } else {
        local = positions(
          nodes: members,
          // Sorted, so the order links happen to arrive in cannot change the picture.
          edges: edges.filter { inside.contains($0.a) && inside.contains($0.b) }
            .sorted { ($0.a, $0.b) < ($1.a, $1.b) },
          iterations: iterations)
      }
      let radius = nominalRadius(members: members.count)
      // Walk outward along a spiral until the cluster fits without crowding one already placed.
      // The spiral starts from the middle of what is placed so far, weighted by size, so the
      // clusters pack around each other and not all around the first one.
      let weight = discs.reduce(0.0) { $0 + $1.r * $1.r }
      let middle = (
        x: weight > 0 ? discs.reduce(0.0) { $0 + $1.x * $1.r * $1.r } / weight : 0,
        y: weight > 0 ? discs.reduce(0.0) { $0 + $1.y * $1.r * $1.r } / weight : 0
      )
      var centre = middle
      var step = 1
      while !discs.allSatisfy({
        hypot($0.x - centre.x, $0.y - centre.y) >= $0.r + radius + GraphSimulation.clusterGap
      }) {
        let angle = Double(step) * 2.399963
        let reach = 16 * Double(step).squareRoot()
        centre = (middle.x + cos(angle) * reach * stretch, middle.y + sin(angle) * reach)
        step += 1
      }
      discs.append((centre.x, centre.y, radius))
      for id in members {
        let unit = local[id] ?? .zero
        placed[id] = CGPoint(x: centre.x + Double(unit.x) * scale, y: centre.y + Double(unit.y) * scale)
      }
    }
    // Slide the whole pack so its middle is the middle of the picture.
    if let first = discs.first {
      var minX = first.x - first.r, maxX = first.x + first.r, minY = first.y - first.r, maxY = first.y + first.r
      for disc in discs {
        minX = min(minX, disc.x - disc.r)
        maxX = max(maxX, disc.x + disc.r)
        minY = min(minY, disc.y - disc.r)
        maxY = max(maxY, disc.y + disc.r)
      }
      let shift = (x: (minX + maxX) / 2, y: (minY + maxY) / 2)
      discs = discs.map { ($0.x - shift.x, $0.y - shift.y, $0.r) }
      placed = placed.mapValues { CGPoint(x: Double($0.x) - shift.x, y: Double($0.y) - shift.y) }
    }

    guard !loners.isEmpty else { return placed }
    if clusters.isEmpty {
      // Nothing is linked yet: an even spiral, like seeds in a sunflower.
      for (offset, id) in loners.enumerated() {
        let angle = Double(offset) * 2.399963
        let reach = GraphSimulation.lonerSpacing * 0.75 * Double(offset).squareRoot()
        placed[id] = CGPoint(x: cos(angle) * reach * stretch, y: sin(angle) * reach)
      }
      return placed
    }
    let extent = discs.map { hypot($0.x / stretch, $0.y) + $0.r }.max() ?? 0
    let base = max(extent, coreRadius(clusterSizes: clusters.map(\.count))) + GraphSimulation.lonerGap
    var waiting = loners[...]
    var row = 0
    while !waiting.isEmpty {
      let radius = base + Double(row) * GraphSimulation.lonerSpacing
      let around = 2 * Double.pi * radius * (1 + stretch) / 2
      let take = min(max(1, Int(around / GraphSimulation.lonerSpacing)), waiting.count)
      for (offset, id) in waiting.prefix(take).enumerated() {
        let angle = 2 * Double.pi * Double(offset) / Double(take) - Double.pi / 2 + Double(row) * 0.3
        placed[id] = CGPoint(x: cos(angle) * radius * stretch, y: sin(angle) * radius)
      }
      waiting = waiting.dropFirst(take)
      row += 1
    }
    return placed
  }
}

/// The graph in motion. Each entry is a body pushed away from the others and pulled along its
/// links; it keeps moving a little every frame until it comes to rest. Changing the data nudges it
/// awake again, so new dots and lines ease into place instead of jumping.
///
/// Entries joined by links form a cluster. Clusters keep a clear gap between each other, and
/// entries with no links are kept out of the middle, so the sections can be told apart at a glance.
final class GraphSimulation {
  struct Body: Equatable {
    var x: Double
    var y: Double
    var vx = 0.0
    var vy = 0.0
    /// Held by the pointer: forces do not move it.
    var held = false
  }

  /// A cluster as a circle: where it is and how much room it takes.
  struct Disc: Equatable {
    var centre: CGPoint
    var radius: Double
    var count: Int
  }

  /// Natural length of a link, in points.
  static let linkLength = 110.0
  /// Clear space kept between two clusters, edge to edge.
  static let clusterGap = 150.0
  /// Space around a cluster's outermost dots that still counts as the cluster.
  static let clusterMargin = 26.0
  /// Clear space kept between a cluster and an entry with no links.
  static let lonerGap = 100.0
  /// How far apart entries with no links start from each other.
  static let lonerSpacing = 66.0
  static let restingEnergy = 0.02

  // Bodies live in a plain array and links refer to them by position, so a tick is arithmetic on
  // arrays with no dictionary lookups or sorting. That is what keeps large graphs smooth.
  private var ids: [String] = []
  private var index: [String: Int] = [:]
  private var store: [Body] = []
  private var links: [(a: Int, b: Int, strength: Double)] = []
  /// Groups of two or more linked bodies, by position in `store`.
  private var clusters: [[Int]] = []
  /// Bodies with no links.
  private var loners: [Int] = []
  private var coreRadius = 0.0
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
    let parts = GraphLayout.components(nodes: ids, edges: edges)
    clusters = parts.filter { $0.count > 1 }.map { $0.compactMap { index[$0] } }
    loners = parts.filter { $0.count == 1 }.compactMap { index[$0[0]] }
    coreRadius = GraphLayout.coreRadius(clusterSizes: clusters.map(\.count))
  }

  /// Brings the simulation in line with the data. Known dots stay where they are; new ones start
  /// beside something they are linked to, so they slide a short way, not across the whole window.
  /// `groups` only decides which unlinked entries start next to each other.
  func sync(nodes: [String], edges: [GraphEdge], groups: [String: Int] = [:]) {
    let key = nodes.sorted().joined(separator: ",") + "|"
      + edges.map { "\($0.a)>\($0.b)>\($0.weight)" }.sorted().joined(separator: ",")
    guard key != signature else { return }
    signature = key
    let wanted = nodes.sorted()

    if store.isEmpty {
      // First sight of the data: start from the arranged layout so nothing flies in from afar.
      // Both this and the settling below cost the square of the number of dots per step, so the
      // number of steps shrinks as the index grows.
      let pairs = max(wanted.count * wanted.count, 1)
      let start = GraphLayout.arranged(
        nodes: wanted, edges: edges, groups: groups, iterations: max(20, min(300, 2_000_000 / pairs)))
      ids = wanted
      index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
      store = ids.map {
        let point = start[$0] ?? .zero
        return Body(x: Double(point.x), y: Double(point.y))
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

    var old: [String: Body] = [:]
    for (id, body) in zip(ids, store) { old[id] = body }
    ids = wanted
    index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    store = ids.map { old[$0] ?? Body(x: 0, y: 0) }
    relink(edges)
    for (offset, id) in ids.enumerated() where old[id] == nil {
      let neighbour = edges.first { $0.a == id || $0.b == id }
        .flatMap { old[$0.a == id ? $0.b : $0.a] }
      let angle = Double(offset) * 2.399963  // the golden angle, so several arrivals fan out
      if let neighbour {
        store[offset] = Body(x: neighbour.x + cos(angle) * 50, y: neighbour.y + sin(angle) * 50)
      } else {
        // Nothing to sit beside: it arrives just outside the clusters, where unlinked entries live.
        let reach = coreRadius > 0 ? coreRadius + Self.lonerGap + 20 : 150
        store[offset] = Body(x: cos(angle) * reach * GraphLayout.stretch, y: sin(angle) * reach)
      }
    }
    holding = store.filter(\.held).count
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

  /// Each cluster as a circle around its dots. A dot being dragged is left out, so pulling one
  /// away does not make its cluster swell and shove the others.
  private func discs() -> [(x: Double, y: Double, r: Double)] {
    clusters.map { members in
      var sumX = 0.0, sumY = 0.0, counted = 0.0
      for i in members where !store[i].held {
        sumX += store[i].x
        sumY += store[i].y
        counted += 1
      }
      guard counted > 0 else { return (store[members[0]].x, store[members[0]].y, Self.clusterMargin) }
      let x = sumX / counted, y = sumY / counted
      var total = 0.0, furthest = 0.0
      for i in members where !store[i].held {
        let squared = pow(store[i].x - x, 2) + pow(store[i].y - y, 2)
        total += squared
        furthest = max(furthest, squared)
      }
      // One straggler does not get to stretch the circle far past where most of the cluster is.
      let reach = min(furthest.squareRoot(), 2.2 * (total / counted).squareRoot())
      return (x, y, reach + Self.clusterMargin)
    }
  }

  /// The clusters as circles, for drawing a backdrop behind each.
  var clusterDiscs: [Disc] {
    zip(discs(), clusters).map { Disc(centre: CGPoint(x: $0.x, y: $0.y), radius: $0.r, count: $1.count) }
  }

  /// One sixtieth of a second of physics.
  func tick() {
    guard !isAtRest else { return }
    let count = store.count
    var fx = [Double](repeating: 0, count: count)
    var fy = [Double](repeating: 0, count: count)

    // Every pair of dots pushes apart, so no two sit on top of each other.
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
          let push = 7000 / squared
          fx[i] += dx / distance * push
          fy[i] += dy / distance * push
          fx[j] -= dx / distance * push
          fy[j] -= dy / distance * push
        }
      }
    }
    // Links pull their two ends to a comfortable distance.
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
    // Two clusters closer than the gap push each other away, each moving as one piece.
    let discs = discs()
    if discs.count > 1 {
      for a in 0..<(discs.count - 1) {
        for b in (a + 1)..<discs.count {
          var dx = discs[a].x - discs[b].x
          let dy = discs[a].y - discs[b].y
          if dx == 0 && dy == 0 { dx = 1 }
          let distance = (dx * dx + dy * dy).squareRoot()
          let overlap = discs[a].r + discs[b].r + Self.clusterGap - distance
          guard overlap > 0 else { continue }
          let push = min(overlap * 0.06, 12)
          for i in clusters[a] {
            fx[i] += dx / distance * push
            fy[i] += dy / distance * push
          }
          for i in clusters[b] {
            fx[i] -= dx / distance * push
            fy[i] -= dy / distance * push
          }
        }
      }
    }
    // Entries with no links are kept out of the middle, where the clusters are, and out of any
    // cluster they wander into.
    let stretch = GraphLayout.stretch
    for i in loners {
      if coreRadius > 0 {
        let reach = (pow(store[i].x / stretch, 2) + pow(store[i].y, 2)).squareRoot()
        let inside = coreRadius + Self.lonerGap - reach
        if inside > 0 {
          let push = min(inside * 0.15, 14)
          if reach < 1 {
            fx[i] += push
          } else {
            fx[i] += store[i].x / (stretch * stretch) / reach * push
            fy[i] += store[i].y / reach * push
          }
        }
      }
      for disc in discs {
        let dx = store[i].x - disc.x
        let dy = store[i].y - disc.y
        let distance = max((dx * dx + dy * dy).squareRoot(), 0.01)
        let overlap = disc.r + Self.lonerGap - distance
        guard overlap > 0 else { continue }
        let push = min(overlap * 0.1, 12)
        fx[i] += dx / distance * push
        fy[i] += dy / distance * push
      }
    }
    for i in 0..<count where !store[i].held {
      // A light pull to the middle keeps everything on the page. It is weaker sideways, so the
      // picture settles wider than it is tall.
      let ax = fx[i] - store[i].x * 0.008 / (stretch * stretch)
      let ay = fy[i] - store[i].y * 0.008
      store[i].vx = min(max((store[i].vx + ax * energy) * 0.80, -40), 40)
      store[i].vy = min(max((store[i].vy + ay * energy) * 0.80, -40), 40)
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

/// Everything about the graph that is not drawing: what is shown, where the view is looking, and
/// what the pointer is doing. Pointer events come in as plain points, so the whole of clicking,
/// dragging and linking can be driven and checked without a window.
final class GraphController: ObservableObject {
  /// How far the pointer must travel before a press counts as a drag and not a click.
  static let dragThreshold: CGFloat = 4
  /// The plus handle is easier to hit than it looks.
  static let plusReach: CGFloat = 16
  static let zoomRange: ClosedRange<CGFloat> = 0.12...4

  enum Pointer: Equatable { case arrow, hand, grabbing, link }

  private enum Target: Equatable {
    /// The plus handle of the selected dot.
    case plus(from: String)
    /// A dot, and how far from its centre it was grabbed.
    case node(String, grab: CGSize)
    /// One dot of a selected group: every dot in the group, and how far each is from the pointer.
    case group(String, offsets: [String: CGSize])
    case empty(pan: CGSize)
    /// Empty space with Shift held: a box is drawn, and what was selected before it.
    case box(keeping: Set<String>)
    /// A click while a link is waiting for its other end.
    case linkEnd
  }

  private struct Press: Equatable {
    let start: CGPoint
    let target: Target
    /// Shift or Command was held: the click adds to the selection, or takes away from it.
    var extending = false
    var moved = false
  }

  let simulation = GraphSimulation()
  private(set) var entities: [Entity] = []
  private(set) var edges: [GraphEdge] = []
  private(set) var neighbours: [String: Set<String>] = [:]
  /// The best-connected entry of each sizeable cluster. Its name is always shown, so a cluster can
  /// be recognised even when zoomed far out.
  private(set) var hubs: Set<String> = []
  private var byID: [String: Entity] = [:]
  private var labelSizes: [String: CGSize] = [:]

  /// Every selected dot. One is the usual case; more than one is a group.
  private(set) var selected: Set<String> = []
  /// The dot the plus sits beside. In a group it is the one most recently clicked.
  private(set) var anchor: String?
  /// The selected dot when exactly one is, for the panel beside the graph.
  var selection: String? { selected.count == 1 ? selected.first : nil }
  /// The box being drawn to select a group, while one is.
  private(set) var selectionBox: CGRect?
  private var onSelect: (Set<String>) -> Void = { _ in }
  private var onLink: (String, String) -> Void = { _, _ in }

  private(set) var size: CGSize = .zero
  private(set) var zoom: CGFloat = 1
  private(set) var pan: CGSize = .zero
  /// Set once the user pans or zooms. Until then the view keeps everything in frame by itself.
  private(set) var userMoved = false
  private var placed = false

  private(set) var hovered: String?
  private var press: Press?
  /// The dot a link is being drawn from, while one is.
  private(set) var linkFrom: String?
  private(set) var linkEnd: CGPoint?
  /// The dot the link would join if the pointer were let go now.
  private(set) var linkTarget: String?
  /// True when the plus was clicked, not dragged: the next click on a dot completes the link.
  private(set) var linkArmed = false
  /// The dots being dragged about, while any are.
  private(set) var dragged: Set<String> = []

  /// False once nothing is moving, which stops the per-frame redraw.
  @Published private(set) var animating = true

  // MARK: Data

  /// Takes in the latest data. Called while the view is being rebuilt, so it must not publish.
  func update(
    entities: [Entity], edges: [GraphEdge], selected: Set<String>,
    onSelect: @escaping (Set<String>) -> Void, onLink: @escaping (String, String) -> Void
  ) {
    self.onSelect = onSelect
    self.onLink = onLink
    let chosenElsewhere = self.selected != selected
    if chosenElsewhere {
      self.selected = selected
      if anchor.map({ !selected.contains($0) }) ?? true { anchor = selected.sorted().first }
      if linkFrom != anchor { endLink() }
    }
    defer {
      // An entry picked somewhere other than the graph (just added, or opened from the panel) may
      // be out of sight. If it is, the view goes back to showing everything.
      if chosenElsewhere, userMoved, size.width > 0, let anchor, let spot = screenPosition(of: anchor),
        !CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 24).contains(spot)
      {
        userMoved = false
      }
    }
    guard entities != self.entities || edges != self.edges else { return }
    self.entities = entities
    self.edges = edges
    byID = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var near: [String: Set<String>] = [:]
    for edge in edges where byID[edge.a] != nil && byID[edge.b] != nil && edge.a != edge.b {
      near[edge.a, default: []].insert(edge.b)
      near[edge.b, default: []].insert(edge.a)
    }
    neighbours = near
    hubs = Set(
      GraphLayout.components(nodes: entities.map(\.id), edges: edges).filter { $0.count >= 3 }
        .compactMap { members in
          members.max { first, second in
            let a = (near[first]?.count ?? 0, byID[first]?.seenCount ?? 0)
            let b = (near[second]?.count ?? 0, byID[second]?.seenCount ?? 0)
            return a != b ? a < b : first > second
          }
        })
    let order = Dictionary(uniqueKeysWithValues: EntityKind.allCases.enumerated().map { ($1, $0) })
    simulation.sync(
      nodes: entities.map(\.id), edges: edges,
      groups: Dictionary(entities.map { ($0.id, order[$0.kind] ?? 0) }, uniquingKeysWith: { first, _ in first }))
    if let hovered, byID[hovered] == nil { self.hovered = nil }
    if let linkFrom, byID[linkFrom] == nil { endLink() }
  }

  func entity(_ id: String) -> Entity? { byID[id] }

  // MARK: The view

  /// One frame: moves the physics on and, unless the user has taken over the view, keeps
  /// everything in frame. Called while drawing, so it must not publish.
  func frame(at date: Date, size: CGSize) {
    self.size = size
    simulation.step(to: date)
    follow()
  }

  /// The zoom and offset that bring the whole graph into view, with room for names at the edges.
  private func fitting() -> (zoom: CGFloat, pan: CGSize) {
    let bounds = simulation.bounds
    let wide = max(size.width - 260, 80)
    let tall = max(size.height - 120, 80)
    let scale = min(wide / max(bounds.width, 1), tall / max(bounds.height, 1))
    return (
      min(max(scale, Self.zoomRange.lowerBound), 1.2), CGSize(width: -bounds.midX, height: -bounds.midY)
    )
  }

  private var viewIsSettled: Bool {
    guard !userMoved, size.width > 0, !entities.isEmpty else { return true }
    let goal = fitting()
    return abs(goal.zoom - zoom) < 0.002 && abs(goal.pan.width - pan.width) < 0.5
      && abs(goal.pan.height - pan.height) < 0.5
  }

  private func follow() {
    guard !userMoved, press == nil, size.width > 0, size.height > 0, !entities.isEmpty else { return }
    let goal = fitting()
    // While frames are coming, ease toward the fit. When they are not, there is only this one
    // drawing, so go straight there.
    if !placed || !animating || viewIsSettled {
      zoom = goal.zoom
      pan = goal.pan
      placed = true
      return
    }
    zoom += (goal.zoom - zoom) * 0.18
    pan.width += (goal.pan.width - pan.width) * 0.18
    pan.height += (goal.pan.height - pan.height) * 0.18
  }

  func screen(_ world: CGPoint) -> CGPoint {
    CGPoint(
      x: size.width / 2 + (world.x + pan.width) * zoom,
      y: size.height / 2 + (world.y + pan.height) * zoom)
  }

  func world(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: (point.x - size.width / 2) / zoom - pan.width,
      y: (point.y - size.height / 2) / zoom - pan.height)
  }

  func screenPosition(of id: String) -> CGPoint? {
    simulation.position(of: id).map(screen)
  }

  /// A dot's radius on screen. Dots shrink and grow with the zoom, but only within limits, so they
  /// stay easy to hit zoomed out and do not balloon zoomed in.
  func dotRadius(_ entity: Entity) -> CGFloat {
    (5 + CGFloat(min(entity.seenCount, 8)) * 0.7) * min(max(zoom, 0.6), 1.6)
  }

  /// The dot under a point, if any: the nearest one within reach.
  func node(at point: CGPoint, slack: CGFloat = 8, excluding: String? = nil) -> String? {
    var best: (id: String, distance: CGFloat)?
    for entity in entities where entity.id != excluding {
      guard let centre = screenPosition(of: entity.id) else { continue }
      let distance = hypot(centre.x - point.x, centre.y - point.y)
      if distance <= dotRadius(entity) + slack, distance < best?.distance ?? .infinity {
        best = (entity.id, distance)
      }
    }
    return best?.id
  }

  /// Where the plus handle sits: just up and to the right of the selected dot, or in a group the
  /// one most recently clicked. There is none while that dot is being dragged about.
  var plusCentre: CGPoint? {
    guard let anchor, selected.contains(anchor), !dragged.contains(anchor), selectionBox == nil,
      let entity = byID[anchor], let centre = screenPosition(of: anchor)
    else { return nil }
    let offset = (dotRadius(entity) + 17) * 0.7071
    return CGPoint(x: centre.x + offset, y: centre.y - offset)
  }

  func isOnPlus(_ point: CGPoint) -> Bool {
    guard let centre = plusCentre else { return false }
    return hypot(centre.x - point.x, centre.y - point.y) <= Self.plusReach
  }

  /// Measured once per name: asking the drawing system every frame is what made large graphs stutter.
  func labelSize(_ name: String) -> CGSize {
    if let known = labelSizes[name] { return known }
    let measured = (name as NSString).size(withAttributes: [
      .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    ])
    let size = CGSize(width: ceil(measured.width), height: ceil(measured.height))
    labelSizes[name] = size
    return size
  }

  /// A line to show while a link is being made, for the hint above the graph.
  var hint: String? {
    guard let linkFrom, let single = byID[linkFrom]?.name else { return nil }
    let name = selected.count > 1 ? "these \(selected.count)" : single
    if let linkTarget, let other = byID[linkTarget]?.name {
      let pair = selected.count > 1 ? "\(name) to \(other)" : "\(name) and \(other)"
      return linkArmed ? "Click to link \(pair)" : "Let go to link \(pair)"
    }
    return linkArmed ? "Click another dot to link it to \(name). Esc cancels." : "Drop on another dot to link it to \(name)"
  }

  // MARK: The pointer

  private func changed() { objectWillChange.send() }

  /// Starts the per-frame redraw. The physics is only stirred when something in it changed.
  func wake(physics: Bool = true) {
    if physics { simulation.wake() }
    if !animating { animating = true }
  }

  /// Stops the per-frame redraw once nothing is moving. Called from a timer, never while drawing.
  func restIfSettled() {
    if animating, simulation.isAtRest, press == nil, viewIsSettled { animating = false }
  }

  private func endLink() {
    linkFrom = nil
    linkEnd = nil
    linkTarget = nil
    linkArmed = false
  }

  private func select(_ ids: Set<String>, anchor newAnchor: String? = nil) {
    anchor = newAnchor.flatMap { ids.contains($0) ? $0 : nil }
      ?? anchor.flatMap { ids.contains($0) ? $0 : nil } ?? ids.sorted().first
    guard ids != selected else { return }
    selected = ids
    onSelect(ids)
  }

  /// Every dot not in the selection that a link from it could end on.
  private func linkTarget(at point: CGPoint) -> String? {
    var best: (id: String, distance: CGFloat)?
    for entity in entities where !selected.contains(entity.id) {
      guard let centre = screenPosition(of: entity.id) else { continue }
      let distance = hypot(centre.x - point.x, centre.y - point.y)
      if distance <= dotRadius(entity) + 16, distance < best?.distance ?? .infinity {
        best = (entity.id, distance)
      }
    }
    return best?.id
  }

  /// Links every selected dot to `target`.
  private func linkSelection(to target: String) {
    for id in selected.sorted() where id != target { onLink(id, target) }
  }

  /// Selects everything, as Command-A does.
  func selectAll() {
    select(Set(entities.map(\.id)))
    changed()
  }

  func pointer(at point: CGPoint) -> Pointer {
    if let press, press.moved {
      switch press.target {
      case .plus, .linkEnd, .box: return .link
      case .node, .group, .empty: return .grabbing
      }
    }
    if linkFrom != nil { return .link }
    if isOnPlus(point) { return .link }
    return node(at: point) == nil ? .arrow : .hand
  }

  /// `extending` is Shift or Command: clicks then add to the selection or take away from it, and
  /// a drag on empty space draws a box to select with.
  func pointerDown(at point: CGPoint, extending: Bool = false) {
    if linkArmed, linkFrom != nil {
      press = Press(start: point, target: .linkEnd)
    } else if let anchor, isOnPlus(point) {
      press = Press(start: point, target: .plus(from: anchor))
    } else if let id = node(at: point), let centre = simulation.position(of: id) {
      let grabbed = world(point)
      if selected.count > 1, selected.contains(id), !extending {
        // Dragging one dot of a group moves the whole group.
        var offsets: [String: CGSize] = [:]
        for member in selected {
          guard let place = simulation.position(of: member) else { continue }
          offsets[member] = CGSize(width: grabbed.x - place.x, height: grabbed.y - place.y)
        }
        press = Press(start: point, target: .group(id, offsets: offsets))
      } else {
        press = Press(
          start: point, target: .node(id, grab: CGSize(width: grabbed.x - centre.x, height: grabbed.y - centre.y)),
          extending: extending)
      }
    } else if extending {
      press = Press(start: point, target: .box(keeping: selected), extending: true)
    } else {
      press = Press(start: point, target: .empty(pan: pan))
    }
  }

  func pointerDragged(to point: CGPoint) {
    guard var held = press else { return }
    if !held.moved {
      guard hypot(point.x - held.start.x, point.y - held.start.y) >= Self.dragThreshold else { return }
      held.moved = true
      press = held
    }
    switch held.target {
    case .plus(let from):
      linkFrom = from
      linkArmed = false
      linkEnd = point
      linkTarget = linkTarget(at: point)
    case .linkEnd:
      linkEnd = point
      linkTarget = linkTarget(at: point)
    case .node(let id, let grab):
      let at = world(point)
      dragged = [id]
      simulation.hold(id, at: CGPoint(x: at.x - grab.width, y: at.y - grab.height))
      wake()
    case .group(_, let offsets):
      let at = world(point)
      dragged = Set(offsets.keys)
      for (id, offset) in offsets {
        simulation.hold(id, at: CGPoint(x: at.x - offset.width, y: at.y - offset.height))
      }
      wake()
    case .box(let keeping):
      let box = CGRect(
        x: min(held.start.x, point.x), y: min(held.start.y, point.y),
        width: abs(point.x - held.start.x), height: abs(point.y - held.start.y))
      selectionBox = box
      let inside = entities.filter { entity in screenPosition(of: entity.id).map(box.contains) ?? false }
      select(keeping.union(inside.map(\.id)))
    case .empty(let start):
      userMoved = true
      pan = CGSize(
        width: start.width + (point.x - held.start.x) / zoom,
        height: start.height + (point.y - held.start.y) / zoom)
    }
    changed()
  }

  func pointerUp(at point: CGPoint, clicks: Int = 1) {
    guard let held = press else { return }
    press = nil
    switch held.target {
    case .plus(let from):
      if held.moved {
        let target = linkTarget(at: point)
        endLink()
        if let target { linkSelection(to: target) }
      } else if linkFrom == from {
        // A second click on the plus puts it away again.
        endLink()
      } else {
        // A click on the plus, with no drag: the link now follows the pointer until the next click.
        linkFrom = from
        linkArmed = true
        linkEnd = point
        linkTarget = nil
      }
    case .linkEnd:
      let target = linkTarget(at: point)
      endLink()
      if let target { linkSelection(to: target) }
    case .node(let id, _):
      if held.moved {
        dragged = []
        simulation.release(id)
        wake()
      } else if held.extending {
        // Shift-click: in if it was out, out if it was in.
        select(selected.symmetricDifference([id]), anchor: id)
      } else {
        select([id], anchor: id)
      }
    case .group(let id, let offsets):
      if held.moved {
        dragged = []
        for member in offsets.keys { simulation.release(member) }
        wake()
      } else {
        // A plain click on one dot of a group picks just that dot.
        select([id], anchor: id)
      }
    case .box:
      selectionBox = nil
    case .empty:
      if !held.moved {
        if clicks >= 2 {
          fit()
        } else {
          select([])
        }
      }
    }
    hovered = node(at: point)
    changed()
  }

  func pointerMoved(to point: CGPoint) {
    let over = node(at: point)
    var dirty = over != hovered
    hovered = over
    if linkArmed, linkFrom != nil {
      linkEnd = point
      linkTarget = linkTarget(at: point)
      dirty = true
    }
    if dirty { changed() }
  }

  func pointerExited() {
    guard hovered != nil else { return }
    hovered = nil
    changed()
  }

  /// Esc: gives up on a link that is being made, or failing that lets go of a group.
  @discardableResult
  func cancel() -> Bool {
    guard linkFrom != nil else {
      guard selected.count > 1, press == nil else { return false }
      select([])
      changed()
      return true
    }
    if case .plus = press?.target { press = nil }
    if case .linkEnd = press?.target { press = nil }
    endLink()
    changed()
    return true
  }

  /// Zooms by `factor`, keeping whatever is under `point` under it.
  func zoom(by factor: CGFloat, about point: CGPoint) {
    guard size.width > 0, factor.isFinite, factor > 0 else { return }
    let anchor = world(point)
    zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    pan = CGSize(
      width: (point.x - size.width / 2) / zoom - anchor.x,
      height: (point.y - size.height / 2) / zoom - anchor.y)
    userMoved = true
    placed = true
    changed()
  }

  /// Two-finger scrolling moves the view; with Command held, or from a mouse wheel, it zooms.
  func scrolled(by delta: CGSize, at point: CGPoint, zooming: Bool, precise: Bool = true) {
    if zooming {
      zoom(by: exp(delta.height * (precise ? 0.01 : 0.08)), about: point)
    } else {
      pan = CGSize(width: pan.width + delta.width / zoom, height: pan.height + delta.height / zoom)
      userMoved = true
      placed = true
      changed()
    }
  }

  /// Brings everything back into view, and lets the view look after itself again.
  func fit() {
    userMoved = false
    wake(physics: false)
    changed()
  }
}

/// A plain AppKit view laid over the graph to receive the mouse. SwiftUI's own drag gesture cannot
/// be used here: the window moves when its background is dragged, and to the window a SwiftUI
/// drawing is background, so the drag moved the window and never reached the graph. A view can
/// opt out of that, which this one does.
struct GraphPointerSurface: NSViewRepresentable {
  let controller: GraphController

  final class Surface: NSView {
    var controller: GraphController?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(
        NSTrackingArea(
          rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
          owner: self))
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func showPointer(at point: CGPoint) {
      switch controller?.pointer(at: point) ?? .arrow {
      case .arrow: NSCursor.arrow.set()
      case .hand: NSCursor.pointingHand.set()
      case .grabbing: NSCursor.closedHand.set()
      case .link: NSCursor.crosshair.set()
      }
    }

    override func mouseDown(with event: NSEvent) {
      // Taking the keyboard ends any typing in the field above, and lets Esc cancel a link.
      window?.makeFirstResponder(self)
      controller?.pointerDown(
        at: point(event), extending: !event.modifierFlags.intersection([.shift, .command]).isEmpty)
    }

    override func mouseDragged(with event: NSEvent) {
      controller?.pointerDragged(to: point(event))
      showPointer(at: point(event))
    }

    override func mouseUp(with event: NSEvent) {
      controller?.pointerUp(at: point(event), clicks: event.clickCount)
      showPointer(at: point(event))
    }

    override func mouseMoved(with event: NSEvent) {
      controller?.pointerMoved(to: point(event))
      showPointer(at: point(event))
    }

    override func mouseExited(with event: NSEvent) {
      controller?.pointerExited()
      NSCursor.arrow.set()
    }

    override func scrollWheel(with event: NSEvent) {
      let precise = event.hasPreciseScrollingDeltas
      controller?.scrolled(
        by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), at: point(event),
        zooming: event.modifierFlags.contains(.command) || !precise, precise: precise)
    }

    override func magnify(with event: NSEvent) {
      controller?.zoom(by: 1 + event.magnification, about: point(event))
    }

    override func keyDown(with event: NSEvent) {
      // 53 is Esc.
      if event.keyCode == 53, controller?.cancel() == true { return }
      if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
        controller?.selectAll()
        return
      }
      super.keyDown(with: event)
    }
  }

  func makeNSView(context: Context) -> Surface {
    let view = Surface()
    view.controller = controller
    return view
  }

  func updateNSView(_ view: Surface, context: Context) {
    view.controller = controller
  }
}

struct GraphCanvas: View {
  let entities: [Entity]
  let edges: [GraphEdge]
  /// Every selected entry: one as a rule, several when a group is picked.
  @Binding var selected: Set<String>
  var onLink: (String, String) -> Void = { _, _ in }
  /// A controller set up by the caller, to draw one particular moment. The view keeps its own otherwise.
  var prepared: GraphController? = nil

  @Environment(\.renderingPreview) private var preview
  @StateObject private var own = GraphController()

  var body: some View {
    let controller = prepared ?? own
    let _ = controller.update(
      entities: entities, edges: edges, selected: selected, onSelect: { selected = $0 }, onLink: onLink)

    TimelineView(.animation(paused: !controller.animating)) { timeline in
      Canvas { context, size in
        controller.frame(at: timeline.date, size: size)
        draw(&context, controller)
      }
    }
    .overlay {
      if !preview { GraphPointerSurface(controller: controller) }
    }
    .clipped()
    // Any change to the data wakes the animation; it sleeps again once the dots stop moving.
    .onChange(of: edges) { controller.wake() }
    .onChange(of: entities.map(\.id)) { controller.wake() }
    .task(id: controller.animating) {
      guard controller.animating, !preview else { return }
      while !Task.isCancelled, controller.animating {
        try? await Task.sleep(nanoseconds: 400_000_000)
        controller.restIfSettled()
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
      .allowsHitTesting(false)
    }
    .overlay(alignment: .bottomTrailing) {
      Button {
        controller.fit()
      } label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
      }
      .buttonStyle(GlassButtonStyle(kind: .icon))
      .help("Fit everything in view")
      .accessibilityLabel("Fit everything in view")
      .padding(10)
    }
    .overlay(alignment: .top) {
      if let hint = controller.hint {
        Text(hint)
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(Glass.ink)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Capsule().fill(Color.black.opacity(0.45)))
          .overlay(Capsule().strokeBorder(Glass.hairline))
          .padding(10)
          .allowsHitTesting(false)
      }
    }
  }

  private func draw(_ context: inout GraphicsContext, _ graph: GraphController) {
    let selected = graph.selected
    let hovered = graph.hovered
    let linking = graph.linkFrom != nil
    // Selecting dims everything the selection is not linked to. While a link is being made
    // nothing is dimmed, because any dot may be where it ends.
    let focus: Set<String> = linking ? [] : selected
    let near = focus.reduce(into: focus) { $0.formUnion(graph.neighbours[$1] ?? []) }
    let warm = hovered.map { (graph.neighbours[$0] ?? []).union([$0]) } ?? []
    let zoom = graph.zoom
    let frame = CGRect(origin: .zero, size: graph.size).insetBy(dx: 4, dy: 4)

    // A faint backdrop behind each cluster of three or more shows where one ends and the next begins.
    for disc in graph.simulation.clusterDiscs where disc.count >= 3 {
      let centre = graph.screen(disc.centre)
      let reach = CGFloat(disc.radius + 10) * zoom
      let circle = Path(
        ellipseIn: CGRect(x: centre.x - reach, y: centre.y - reach, width: reach * 2, height: reach * 2))
      context.fill(circle, with: .color(Color.white.opacity(0.035)))
      context.stroke(circle, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
    }

    for edge in graph.edges {
      guard let a = graph.screenPosition(of: edge.a), let b = graph.screenPosition(of: edge.b) else { continue }
      let lit =
        focus.contains(edge.a) || focus.contains(edge.b)
        || (hovered != nil && (edge.a == hovered || edge.b == hovered))
      var path = Path()
      path.move(to: a)
      path.addLine(to: b)
      context.stroke(
        path, with: .color(Color.white.opacity(lit ? 0.62 : (focus.isEmpty ? 0.24 : 0.08))),
        lineWidth: lit ? 1.4 : 1)
    }

    // The link being made: a dashed line to the pointer, which turns solid and snaps to a dot
    // once it is close enough to join it.
    let target = graph.linkTarget.flatMap(graph.screenPosition)
    if graph.linkFrom != nil, let end = target ?? graph.linkEnd {
      // One line from every selected dot: a group is linked all at once.
      var path = Path()
      for start in selected.sorted().compactMap(graph.screenPosition) {
        path.move(to: start)
        path.addLine(to: end)
      }
      context.stroke(
        path, with: .color(target == nil ? Color.white.opacity(0.8) : Glass.mint),
        style: StrokeStyle(lineWidth: target == nil ? 1.4 : 2, lineCap: .round, dash: target == nil ? [5, 5] : []))
    }

    // Dots and the plus handle count as taken space, so no name is written across them.
    var taken: [CGRect] = graph.entities.compactMap { entity in
      graph.screenPosition(of: entity.id).map {
        let dot = graph.dotRadius(entity)
        return CGRect(x: $0.x - dot, y: $0.y - dot, width: dot * 2, height: dot * 2)
      }
    }
    let plus = linking && !graph.linkArmed ? nil : graph.plusCentre
    if let plus { taken.append(CGRect(x: plus.x - 12, y: plus.y - 12, width: 24, height: 24)) }

    func rank(_ entity: Entity) -> Int {
      if selected.contains(entity.id) || entity.id == hovered || entity.id == graph.linkTarget { return 3 }
      if near.contains(entity.id) || warm.contains(entity.id) { return 2 }
      return graph.hubs.contains(entity.id) ? 1 : 0
    }
    // The names that matter most are placed first; one that would land on another is left out, so
    // names never pile on top of each other.
    let ordered = graph.entities.sorted {
      let first = (rank($0), $0.seenCount), second = (rank($1), $1.seenCount)
      return first != second ? first > second : $0.id < $1.id
    }
    for entity in ordered {
      guard let centre = graph.screenPosition(of: entity.id) else { continue }
      let importance = rank(entity)
      let dimmed = !focus.isEmpty && !near.contains(entity.id) && importance < 3
      let swell: CGFloat = entity.id == hovered || entity.id == graph.linkTarget ? 1.2 : 1
      let dot = graph.dotRadius(entity) * swell
      context.fill(
        Path(ellipseIn: CGRect(x: centre.x - dot, y: centre.y - dot, width: dot * 2, height: dot * 2)),
        with: .color(entity.kind.tone.opacity(dimmed ? 0.22 : 0.95)))
      if selected.contains(entity.id) || entity.id == graph.linkTarget {
        let ring = dot + 4
        context.stroke(
          Path(ellipseIn: CGRect(x: centre.x - ring, y: centre.y - ring, width: ring * 2, height: ring * 2)),
          with: .color(entity.id == graph.linkTarget ? Glass.mint : Color.white.opacity(0.9)), lineWidth: 1.5)
      }

      // Zoomed far out, only the names that matter are shown.
      guard importance > 0 || zoom >= 0.3 else { continue }
      let name = entity.name.count > 24 ? String(entity.name.prefix(23)) + "…" : entity.name
      let measured = graph.labelSize(name)
      // Under the dot if there is room, otherwise above it or to either side.
      let spots = [
        CGRect(x: centre.x - measured.width / 2, y: centre.y + dot + 4, width: measured.width, height: measured.height),
        CGRect(x: centre.x - measured.width / 2, y: centre.y - dot - 4 - measured.height, width: measured.width, height: measured.height),
        CGRect(x: centre.x + dot + 6, y: centre.y - measured.height / 2, width: measured.width, height: measured.height),
        CGRect(x: centre.x - dot - 6 - measured.width, y: centre.y - measured.height / 2, width: measured.width, height: measured.height),
      ]
      func isClear(_ spot: CGRect) -> Bool { !taken.contains { $0.insetBy(dx: -4, dy: -2).intersects(spot) } }
      // A spot that keeps the whole name inside the graph is preferred to one that cuts it off.
      let free = spots.first { frame.contains($0) && isClear($0) } ?? spots.first(where: isClear)
      // A name that matters is always shown, in whichever spot covers least of what is already
      // there; any other is dropped when nowhere is free.
      func covered(_ spot: CGRect) -> CGFloat {
        taken.reduce(0) { total, other in
          let shared = other.intersection(spot)
          return total + (shared.isNull ? 0 : shared.width * shared.height)
        }
      }
      let forced = importance >= 2 ? spots.min { covered($0) < covered($1) } : nil
      guard let box = free ?? forced else { continue }
      taken.append(box)
      context.draw(
        Text(name)
          .font(.system(size: 10.5, weight: importance >= 3 || importance == 1 ? .semibold : .regular))
          .foregroundColor(Color.white.opacity(dimmed ? 0.28 : (importance > 0 ? 0.96 : 0.72))),
        at: CGPoint(x: box.midX, y: box.midY))
    }

    // The box being dragged out to select a group.
    if let box = graph.selectionBox {
      let shape = Path(roundedRect: box, cornerRadius: 3)
      context.fill(shape, with: .color(Color.white.opacity(0.07)))
      context.stroke(shape, with: .color(Color.white.opacity(0.55)), lineWidth: 1)
    }

    // The plus handle on the selected dot: drag it onto another dot to link the two.
    if let plus {
      let disc = CGRect(x: plus.x - 10, y: plus.y - 10, width: 20, height: 20)
      context.fill(Path(ellipseIn: disc), with: .color(graph.linkArmed ? Glass.mint : Color.white.opacity(0.96)))
      var cross = Path()
      cross.move(to: CGPoint(x: plus.x - 4.5, y: plus.y))
      cross.addLine(to: CGPoint(x: plus.x + 4.5, y: plus.y))
      cross.move(to: CGPoint(x: plus.x, y: plus.y - 4.5))
      cross.addLine(to: CGPoint(x: plus.x, y: plus.y + 4.5))
      context.stroke(cross, with: .color(Color(white: 0.08)), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
    }
  }
}
