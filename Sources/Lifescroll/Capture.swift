import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

// MARK: - Fast loop: which app and window are in front

enum ActivityMonitor {
  static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

  /// Shows the system's Accessibility prompt. Window titles work without it only once Screen Recording is on.
  static func requestAccessibilityPermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  static func currentSample() -> ActivitySample? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    var sample = ActivitySample(
      app: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "", title: "", url: "")

    let element = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(element, 0.3)
    var windowRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowRef)
      == .success, let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID()
    {
      let window = windowRef as! AXUIElement
      var titleRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success {
        sample.title = titleRef as? String ?? ""
      }
      var documentRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentRef)
        == .success
      {
        sample.url = documentRef as? String ?? ""
      }
    }
    if sample.title.isEmpty { sample.title = fallbackTitle(pid: app.processIdentifier) }
    return sample
  }

  /// Window names from the window server. These are only filled in once Screen Recording is granted.
  private static func fallbackTitle(pid: pid_t) -> String {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return "" }
    for window in windows {
      guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let name = window[kCGWindowName as String] as? String, !name.isEmpty
      else { continue }
      return name
    }
    return ""
  }
}

// MARK: - Slow loop: screenshots

struct CapturedFrame {
  let jpeg: Data
  /// 16×16 grayscale thumbnail used to skip frames where nothing changed.
  let signature: [UInt8]
  let width: Int
  let height: Int
}

enum CaptureError: LocalizedError {
  case noDisplay
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .noDisplay: return "No display to capture."
    case .encodingFailed: return "Could not encode the screenshot."
    }
  }
}

enum ScreenCapturer {
  static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

  /// Shows the system's Screen Recording prompt the first time, and adds the app to the list in Settings.
  static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

  static var isScreenLocked: Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
  }

  /// The display under the mouse pointer, which is the one the user is looking at.
  @MainActor
  static func activeDisplayID() -> CGDirectDisplayID {
    let location = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    return number?.uint32Value ?? CGMainDisplayID()
  }

  /// One downscaled JPEG of a display. 1280 on the long edge keeps each frame near 1,300 input tokens.
  static func capture(displayID: CGDirectDisplayID, maxLongEdge: Int = 1280) async throws -> CapturedFrame {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard
      let display = content.displays.first(where: { $0.displayID == displayID })
        ?? content.displays.first
    else { throw CaptureError.noDisplay }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let pointLongEdge = Double(max(display.width, display.height))
    let pixelLongEdge = pointLongEdge * Double(filter.pointPixelScale)
    let scale = min(Double(maxLongEdge), pixelLongEdge) / pointLongEdge

    let configuration = SCStreamConfiguration()
    configuration.width = max(Int(Double(display.width) * scale), 1)
    configuration.height = max(Int(Double(display.height) * scale), 1)
    configuration.showsCursor = false

    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    else { throw CaptureError.encodingFailed }
    return CapturedFrame(
      jpeg: jpeg, signature: signature(of: image), width: image.width, height: image.height)
  }

  static func signature(of image: CGImage) -> [UInt8] {
    let side = 16
    var pixels = [UInt8](repeating: 0, count: side * side)
    pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      else { return }
      context.interpolationQuality = .low
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    return pixels
  }
}
