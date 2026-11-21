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
