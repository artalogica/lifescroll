import CoreGraphics
import Foundation
import Vision

// Text-first capture: the Mac reads the words off the screen itself, and the reading model is sent that
// text instead of a picture. A screenshot is only sent for screens with little readable text.

/// Lets a CGImage cross into background work. The image is never changed after capture.
struct ImageBox: @unchecked Sendable {
  let image: CGImage
}

enum ScreenText {
  /// Recognises the text in a screenshot on this Mac, top to bottom. Nothing leaves the machine here.
  static func recognize(_ image: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Language correction "fixes" code, links and names into dictionary words, so it stays off.
    request.usesLanguageCorrection = false
    // Without this only the default language is read, and text in other scripts comes back empty.
    request.automaticallyDetectsLanguage = true
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return ""
    }
    let lines = (request.results ?? []).compactMap { observation -> (row: Int, x: CGFloat, text: String)? in
      guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
      // Bounding boxes are measured from the bottom-left; rows are bucketed so one line of text sorts
      // left to right even when its pieces sit a pixel or two apart vertically.
      return (Int((1 - observation.boundingBox.midY) * 150), observation.boundingBox.minX, text)
    }
    return lines.sorted { ($0.row, $0.x) < ($1.row, $1.x) }.map(\.text).joined(separator: "\n")
  }

  static func recognizeInBackground(_ image: CGImage) async -> String {
    let box = ImageBox(image: image)
    return await Task.detached(priority: .utility) { recognize(box.image) }.value
  }
}

/// Decides which screenshots get their text read. Reading every one would cost battery for little gain.
struct TextSchedule {
  /// Read at least this often while the screen keeps changing.
  static let interval: TimeInterval = 30
  /// A new window is read straight away, but never more often than this.
  static let minimumGap: TimeInterval = 5

  private(set) var lastRead: Date?
  private(set) var lastWindow = ""

  func isDue(window: String, now: Date) -> Bool {
    guard let lastRead else { return true }
    let gap = now.timeIntervalSince(lastRead)
    if gap >= Self.interval { return true }
    return window != lastWindow && gap >= Self.minimumGap
  }

  mutating func didRead(window: String, now: Date) {
    lastRead = now
    lastWindow = window
  }
}

/// Masks things that look like secrets before screen text is stored or sent anywhere.
/// This is a safety net for obvious shapes, not a guarantee.
enum Redactor {
  private static let patterns: [(NSRegularExpression, String)] = [
    (#"\b(?:sk|pk|rk)-[A-Za-z0-9_\-]{16,}"#, "[hidden key]"),
    (#"\b(?:ghp|gho|ghs|ghu|github_pat)_[A-Za-z0-9_]{20,}"#, "[hidden key]"),
    (#"\bAKIA[0-9A-Z]{16}\b"#, "[hidden key]"),
    (#"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#, "[hidden key]"),
    (#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, "[hidden token]"),
  ].compactMap { pattern, replacement in
    (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
  }

  private static let digitRun = try? NSRegularExpression(pattern: #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#)
  private static let longRun = try? NSRegularExpression(pattern: #"\b[A-Za-z0-9+_\-]{40,}={0,2}"#)

  /// Whether a long unbroken run looks like a generated secret, not a name someone wrote.
  /// Secrets mix digits and both cases with few separators; `test_that_the_parser_handles_empty_input`
  /// and `how-to-build-a-consensus-protocol-from-scratch` are words joined by many.
  static func looksGenerated(_ run: Substring) -> Bool {
    let digits = run.filter(\.isNumber).count
    let upper = run.filter(\.isUppercase).count
    let lower = run.filter(\.isLowercase).count
    let separators = run.filter { $0 == "-" || $0 == "_" }.count
    if digits >= 3, upper >= 3, lower >= 3, separators <= 2 { return true }
    // Long hexadecimal strings carry no case mix but are just as machine-made.
    return run.count >= 48 && run.allSatisfy(\.isHexDigit)
  }

  /// The checksum real card numbers satisfy, so ordinary long numbers are left alone.
  static func passesLuhn(_ digits: [Int]) -> Bool {
    guard (13...19).contains(digits.count) else { return false }
    var sum = 0
    for (offset, digit) in digits.reversed().enumerated() {
      if offset % 2 == 1 {
        let doubled = digit * 2
        sum += doubled > 9 ? doubled - 9 : doubled
      } else {
        sum += digit
      }
    }
    return sum % 10 == 0
  }

  static func mask(_ text: String) -> String {
    var result = text
    for (expression, replacement) in patterns {
      result = expression.stringByReplacingMatches(
        in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
    }
    // Replace from the end so earlier ranges stay valid.
    if let longRun {
      for match in longRun.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        if looksGenerated(result[range]) { result.replaceSubrange(range, with: "[hidden token]") }
      }
    }
    guard let digitRun else { return result }
    for match in digitRun.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
      guard let range = Range(match.range, in: result) else { continue }
      let digits = result[range].compactMap(\.wholeNumberValue)
      if passesLuhn(digits) { result.replaceSubrange(range, with: "[hidden card number]") }
    }
    return result
  }
}

/// Screens a few seconds apart share most of their text. Each screen is cut down to the lines that
/// have not already appeared earlier in the same reading, which is where text-first saves tokens.
enum TextCondenser {
  static let perScreenLimit = 4000
  static let totalLimit = 30000

  static func key(_ line: String) -> String {
    line.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// - A line counts as repeated only if the same window already had it. The same words in another
  ///   window (two assignments both "Due Friday") are kept, because there they mean something else.
  /// - A line counts as sent only once it has actually fitted. Lines left out by a size limit stay
  ///   eligible, so a later screen of the same window can still carry them.
  static func condense(
    _ screens: [(window: String, text: String)], perScreen: Int = perScreenLimit,
    total: Int = totalLimit
  ) -> [String] {
    var sentByWindow: [String: Set<String>] = [:]
    var remaining = total
    return screens.map { screen in
      var sent = sentByWindow[screen.window] ?? []
      var fresh: [String] = []
      var used = 0
      var repeated = 0
      var cut = false
      let limit = min(perScreen, max(remaining, 0))
      for line in screen.text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        let lineKey = key(trimmed)
        if sent.contains(lineKey) {
          repeated += 1
          continue
        }
        if cut { continue }
        // One enormous line is shortened, not dropped: dropped, it could never fit on any screen.
        let piece = trimmed.count > perScreen ? String(trimmed.prefix(perScreen)) : trimmed
        let cost = piece.count + (fresh.isEmpty ? 0 : 1)
        guard used + cost <= limit else {
          cut = true
          continue
        }
        fresh.append(piece)
        used += cost
        sent.insert(lineKey)
      }
      sentByWindow[screen.window] = sent
      remaining -= used
      var parts = fresh
      if cut { parts.append("[cut short]") }
      if repeated > 0 { parts.append("[\(repeated) lines unchanged from earlier screens]") }
      return parts.joined(separator: "\n")
    }
  }
}
