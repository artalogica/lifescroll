import AppKit
import SwiftUI

@main
enum Entry {
  static func main() {
    if CommandLine.arguments.contains("--self-test") {
      exit(SelfTest.run() ? 0 : 1)
    }
    // `--check-db <path>` opens a database file with this build's schema and reports what is in it.
    // Point it at a copy to confirm an upgrade is safe before running the new build for real.
    if let flag = CommandLine.arguments.firstIndex(of: "--check-db"),
      CommandLine.arguments.indices.contains(flag + 1)
    {
      do {
        let store = try Store(
          path: CommandLine.arguments[flag + 1], framesDirectory: FileManager.default.temporaryDirectory)
        let closed = store.tasks(status: .done).count + store.tasks(status: .dismissed).count
        print("opened and migrated")
        print("tasks: \(store.tasks(status: .open).count) open, \(closed) closed")
        print("readings waiting to be indexed: \(store.observationsNeedingEntities().count)")
        print("readings waiting to be merged: \(store.unmergedObservations().count)")
        print("entities: \(store.entities().count)")
        print("screenshots waiting: \(store.pendingFrameCount())")
        exit(0)
      } catch {
        print("failed: \(error.localizedDescription)")
        exit(1)
      }
    }
    #if DEBUG
    // `--render-ui <folder>` draws the interface to PNG files with sample data, over a light and a
    // dark backdrop. It opens no real data and makes no network calls. Debug builds only.
    if let flag = CommandLine.arguments.firstIndex(of: "--render-ui"),
      CommandLine.arguments.indices.contains(flag + 1)
    {
      let folder = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
      let written = MainActor.assumeIsolated { () -> [String] in
        _ = NSApplication.shared
        return UIPreview.render(to: folder)
      }
      for name in written { print(name) }
      exit(written.isEmpty ? 1 : 0)
    }
    // `--render-graph <database> <png>` draws the Projects window from a database file. Use a copy.
    if let flag = CommandLine.arguments.firstIndex(of: "--render-graph"),
      CommandLine.arguments.indices.contains(flag + 2)
    {
      let done = MainActor.assumeIsolated { () -> Bool in
        _ = NSApplication.shared
        return UIPreview.renderGraph(
          database: CommandLine.arguments[flag + 1], to: URL(fileURLWithPath: CommandLine.arguments[flag + 2]))
      }
      print(done ? "written" : "failed")
      exit(done ? 0 : 1)
    }
    #endif
    // `--ocr-test [count]` reads the text off the newest stored screenshots and reports timing and size.
    // It prints numbers only, never the text itself, and makes no network calls.
    if let flag = CommandLine.arguments.firstIndex(of: "--ocr-test") {
      let count = CommandLine.arguments.indices.contains(flag + 1) ? Int(CommandLine.arguments[flag + 1]) ?? 12 : 12
      let directory = Store.applicationSupport().appendingPathComponent("frames")
      let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "jpg" } ?? [])
        .sorted { $0.path < $1.path }.suffix(count)
      guard !files.isEmpty else {
        print("no stored screenshots found")
        exit(1)
      }
      // Window labels come straight from the database, read-only, so repeats are judged per window
      // the same way a real reading does.
      var labels: [String: String] = [:]
      let databasePath = Store.applicationSupport().appendingPathComponent("lifescroll.sqlite").path
      for row in (try? Database(path: databasePath).query("SELECT path, app, title FROM frames")) ?? [] {
        labels[row.string("path")] = "\(row.string("app"))|\(row.string("title"))"
      }
      var texts: [String] = []
      var windows: [String] = []
      var imageTokens = 0
      var seconds = 0.0
      for file in files {
        guard let data = try? Data(contentsOf: file), let image = NSBitmapImageRep(data: data)?.cgImage
        else { continue }
        let started = Date()
        let text = Redactor.mask(ScreenText.recognize(image))
        seconds += Date().timeIntervalSince(started)
        texts.append(text)
        windows.append(labels[file.path] ?? "")
        // Claude counts an image at roughly one token per 28×28 pixel patch.
        imageTokens += image.width * image.height / 784
      }
      let raw = texts.reduce(0) { $0 + $1.count }
      let condensed = TextCondenser.condense(
        zip(windows, texts).map { (window: $0.0, text: $0.1) }
      ).reduce(0) { $0 + $1.count }
      let pictured = Analyzer.screensToPicture(texts.map(\.count)).count
      print("screenshots read: \(texts.count), \(files.first.map { "\(NSBitmapImageRep(data: (try? Data(contentsOf: $0)) ?? Data())?.pixelsWide ?? 0)" } ?? "?") px wide")
      print(String(format: "recognition time: %.2f s each, %.1f s total", seconds / Double(max(texts.count, 1)), seconds))
      print("text found: \(raw) characters, \(condensed) after dropping repeated lines")
      let perImage = imageTokens / max(texts.count, 1)
      print("distinct windows: \(Set(windows).count)")
      print("screens with little text (screenshot sent as well): \(pictured)")
      print("rough tokens as images: \(imageTokens)")
      print("rough tokens as text: \(condensed * 10 / 32 + pictured * perImage) (about 3.2 characters per token, plus \(pictured) screenshots)")
      exit(0)
    }
    // `--parse-arxiv <file>` reads a saved arXiv reply, to check the parser against the real format.
    if let flag = CommandLine.arguments.firstIndex(of: "--parse-arxiv"),
      CommandLine.arguments.indices.contains(flag + 1)
    {
      let data = FileManager.default.contents(atPath: CommandLine.arguments[flag + 1]) ?? Data()
      let papers = CandidateSources.parseArxiv(data)
      print("papers parsed: \(papers.count)")
      for paper in papers {
        print("  \(paper.title)  <\(paper.url)>  published: \(paper.published != nil)  summary: \(paper.snippet.count) chars")
      }
      exit(papers.isEmpty ? 1 : 0)
    }
    // `--fetch-test "<words>"` runs one real search against arXiv and Hacker News and prints what came back.
    // It makes no Claude calls and touches no stored data.
    if let flag = CommandLine.arguments.firstIndex(of: "--fetch-test"),
      CommandLine.arguments.indices.contains(flag + 1)
    {
      let query = CommandLine.arguments[flag + 1]
      Task.detached {
        let recommender = Recommender(store: try! Store.inMemory())
        let plan = SearchPlan(arxivQueries: [query], hnQueries: [query], interestsSummary: "")
        let gathered = await recommender.gather(plan: plan, now: Date())
        for problem in gathered.problems { print("search failed: \(problem)") }
        let cleaned = CandidateSources.clean(
          gathered.found, suggested: [], seenURLs: [], seenTitles: [])
        for source in ["arXiv", "Hacker News"] {
          let related = cleaned.filter { $0.source == source && $0.bucket == "related" }
          print("\(source), related to \"\(query)\": \(related.count)")
          for candidate in related.prefix(2) { print("  \(candidate.title)  <\(candidate.url)>") }
        }
        let explore = cleaned.filter { $0.bucket == "explore" }
        print("Hacker News front page: \(explore.count)")
        for candidate in explore.prefix(2) { print("  \(candidate.title)  <\(candidate.url)>") }
        let succeeded =
          cleaned.contains { $0.source == "arXiv" } && cleaned.contains { $0.source == "Hacker News" }
        exit(succeeded ? 0 : 1)
      }
      // Keeps the process alive while the searches run; the task above ends it.
      dispatchMain()
    }
    LifescrollApp.main()
  }
}

struct LifescrollApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    MenuBarExtra {
      PopoverView().environmentObject(AppModel.shared)
    } label: {
      MenuBarLabel(model: AppModel.shared)
    }
    .menuBarExtraStyle(.window)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in AppModel.shared.start() }
  }
}
