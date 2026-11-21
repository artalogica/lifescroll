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
  /// The capture at full resolution, for reading its text. Never written to disk.
  let image: CGImage
  /// 16×16 grayscale thumbnail used to skip frames where nothing changed.
  let signature: [UInt8]
}

enum CaptureExclusion {
  /// Whether a window must be left out of the picture itself: one of Lifescroll's own, or one whose
  /// app or title matches a "never capture" word. This holds wherever the window sits on screen,
  /// not only when it is in front.
  static func excludes(
    app: String, bundleID: String, title: String, keywords: [String], ownBundleID: String?
  ) -> Bool {
    if let ownBundleID, !ownBundleID.isEmpty, bundleID == ownBundleID { return true }
    return Keywords.matches(ActivitySample(app: app, bundleID: bundleID, title: title, url: ""), keywords)
  }
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

  /// Longest edge captured when the text is going to be read. Small text needs the real pixels.
  static let textLongEdge = 3200

  /// Captures a display at its real pixel size, so small text can be read. Every capture takes the
  /// same path, so the change signature of one frame is comparable with the next. Nothing is scaled
  /// or encoded here: that only happens, in `encode`, once the caller knows the screen changed.
  ///
  /// Windows matching `keywords`, and Lifescroll's own windows, are removed from the picture by the
  /// system before it is taken, so their contents are never read or stored.
  static func capture(
    displayID: CGDirectDisplayID, excluding keywords: [String] = [],
    ownBundleID: String? = Bundle.main.bundleIdentifier
  ) async throws -> CapturedFrame {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard
      let display = content.displays.first(where: { $0.displayID == displayID })
        ?? content.displays.first
    else { throw CaptureError.noDisplay }

    let hidden = content.windows.filter { window in
      CaptureExclusion.excludes(
        app: window.owningApplication?.applicationName ?? "",
        bundleID: window.owningApplication?.bundleIdentifier ?? "", title: window.title ?? "",
        keywords: keywords, ownBundleID: ownBundleID)
    }
    let filter = SCContentFilter(display: display, excludingWindows: hidden)
    let pointLongEdge = Double(max(display.width, display.height))
    let pixelLongEdge = pointLongEdge * Double(filter.pointPixelScale)
    let scale = min(Double(textLongEdge), pixelLongEdge) / pointLongEdge

    let configuration = SCStreamConfiguration()
    configuration.width = max(Int(Double(display.width) * scale), 1)
    configuration.height = max(Int(Double(display.height) * scale), 1)
    configuration.showsCursor = false

    let captured = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    return CapturedFrame(image: captured, signature: signature(of: captured))
  }

  /// The copy that is kept on disk: 1280 on the long edge, about 1,300 input tokens if it is ever
  /// sent as an image. Called only for frames that are going to be saved.
  static func encode(_ image: CGImage, maxLongEdge: Int = 1280) throws -> Data {
    let bitmap = NSBitmapImageRep(cgImage: downscale(image, longEdge: maxLongEdge))
    guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    else { throw CaptureError.encodingFailed }
    return jpeg
  }

  static func downscale(_ image: CGImage, longEdge: Int) -> CGImage {
    let scale = Double(longEdge) / Double(max(image.width, image.height))
    guard scale < 1 else { return image }
    let width = max(Int(Double(image.width) * scale), 1)
    let height = max(Int(Double(image.height) * scale), 1)
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
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
