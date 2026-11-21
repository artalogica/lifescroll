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
