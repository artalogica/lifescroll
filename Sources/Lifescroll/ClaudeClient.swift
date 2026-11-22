import Foundation
import Security

/// Holds the API key in memory so the analyzer can read it from any thread without touching the Keychain.
final class KeyBox: @unchecked Sendable {
  static let shared = KeyBox()
  private let lock = NSLock()
  private var stored: String?

  var value: String? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      stored = newValue
      lock.unlock()
    }
  }
}

enum Keychain {
  static let service = "local.lifescroll.Lifescroll"
  static let account = "anthropic-api-key"

  private static var base: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  static func read() -> String? {
    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  static func save(_ value: String) -> Bool {
    delete()
    var query = base
    query[kSecValueData as String] = Data(value.utf8)
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
  }

  static func delete() {
    SecItemDelete(base as CFDictionary)
  }
}

struct ClaudeResponse: Equatable {
  let text: String
  let inputTokens: Int
  let outputTokens: Int
}

enum ClaudeError: LocalizedError, Equatable {
  case missingKey
  case http(Int, String)
  case refusal(String)
  case truncated
  case noText
  case network(String)

  var errorDescription: String? {
    switch self {
    case .missingKey: return "No Claude API key saved. Add one in Settings."
    case .http(let status, let message): return "Claude API error \(status): \(message)"
    case .refusal(let category):
      return "Claude declined this request (\(category.isEmpty ? "no category given" : category))."
    case .truncated: return "Claude's reply was cut off before it finished."
    case .noText: return "Claude returned no text."
    case .network(let message): return "Network problem reaching Claude: \(message)"
    }
  }
}

/// Raw HTTP to the Messages API. Swift has no official Anthropic SDK, so requests are built by hand.
struct ClaudeClient: Sendable {
  static let haiku = "claude-haiku-5-5"
  static let sonnet = "claude-sonnet-5-5"
  static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
  static let apiVersion = "2026-10-21"
  static let fallbackBeta = "server-side-fallback-2026-07-01"

  var keyProvider: @Sendable () -> String? = { KeyBox.shared.value }

  /// Sonnet 5.5 can decline a request outright; server-side fallback lets the API retry on another model.
  /// Haiku 5.5 has no server-side fallback.
  static func usesFallback(_ model: String) -> Bool { model == sonnet }

  /// The request body. Always asks for JSON that matches `schema`, so replies can be decoded directly.
  /// No sampling parameters: this API version rejects them.
  static func body(
    model: String, system: String, content: [[String: Any]], schema: [String: Any], effort: String,
    maxTokens: Int = 16000
  ) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "max_tokens": maxTokens,
      "system": system,
      "messages": [["role": "user", "content": content]],
      "output_config": [
        "effort": effort,
        "format": ["type": "json_schema", "schema": schema],
      ],
    ]
    if usesFallback(model) { body["fallbacks"] = "default" }
    return body
  }

  static func request(model: String, apiKey: String, body: Data) -> URLRequest {
    var request = URLRequest(url: endpoint, timeoutInterval: 180)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
    if usesFallback(model) {
      request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
    }
    return request
  }

  /// Reads a Messages API reply. Text is collected by block type, because a reply can begin with thinking blocks.
  static func parse(data: Data, status: Int) throws -> ClaudeResponse {
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    guard status == 200 else {
      let message = (object["error"] as? [String: Any])?["message"] as? String
      throw ClaudeError.http(status, message ?? String(data: data.prefix(300), encoding: .utf8) ?? "")
    }
    let stopReason = object["stop_reason"] as? String
    if stopReason == "refusal" {
      let category = (object["stop_details"] as? [String: Any])?["category"] as? String
      throw ClaudeError.refusal(category ?? "")
    }
    if stopReason == "max_tokens" { throw ClaudeError.truncated }

    let blocks = object["content"] as? [[String: Any]] ?? []
    let text = blocks.filter { $0["type"] as? String == "text" }
      .compactMap { $0["text"] as? String }.joined()
    guard !text.isEmpty else { throw ClaudeError.noText }

    let usage = object["usage"] as? [String: Any] ?? [:]
    let input =
      (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
      + (usage["cache_creation_input_tokens"] as? Int ?? 0)
    return ClaudeResponse(
      text: text, inputTokens: input, outputTokens: usage["output_tokens"] as? Int ?? 0)
  }

  static func isRetryable(_ status: Int) -> Bool {
    status == 408 || status == 409 || status == 429 || status >= 500
  }

  func complete(
    model: String, system: String, content: [[String: Any]], schema: [String: Any], effort: String
  ) async throws -> ClaudeResponse {
    guard let apiKey = keyProvider(), !apiKey.isEmpty else { throw ClaudeError.missingKey }
    let payload = try JSONSerialization.data(
      withJSONObject: Self.body(
        model: model, system: system, content: content, schema: schema, effort: effort))
    let request = Self.request(model: model, apiKey: apiKey, body: payload)

    var lastError: ClaudeError = .network("no attempt made")
    for attempt in 0..<3 {
      if attempt > 0 {
        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 2_000_000_000))
      }
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if Self.isRetryable(status) {
          lastError = Self.errorFrom(data: data, status: status)
          continue
        }
        return try Self.parse(data: data, status: status)
      } catch let error as ClaudeError {
        throw error
      } catch {
        lastError = .network(error.localizedDescription)
      }
    }
    throw lastError
  }

  // MARK: Web search

  /// One page Claude's web search turned up.
  struct WebResult: Equatable {
    let url: String
    let title: String
  }

  struct WebSearchOutcome: Equatable {
    var results: [WebResult] = []
    var inputTokens = 0
    var outputTokens = 0
    /// Searches Claude actually ran. Each is billed separately from tokens.
    var searches = 0
  }

  /// A request that lets Claude search the web itself. The search runs on Anthropic's side; the
  /// pages it finds come back as result blocks alongside whatever Claude writes.
  static func webSearchBody(
    model: String, system: String, messages: [[String: Any]], maxUses: Int
  ) -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "max_tokens": 16000,
      "system": system,
      "messages": messages,
      // The basic search tool returns every page found as a result block in the reply, which is
      // what `webResults` reads. The newer variant filters results inside a code step, where they
      // would not be visible here.
      "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": maxUses]],
      "output_config": ["effort": "low"],
    ]
    if usesFallback(model) { body["fallbacks"] = "default" }
    return body
  }

  /// The pages found, read from the search result blocks. Links are taken from what the search
  /// returned, never from text the model wrote. A failed search arrives as an error object where
  /// the list would be, and is skipped.
  static func webResults(in content: [[String: Any]]) -> [WebResult] {
    var seen = Set<String>()
    var results: [WebResult] = []
    func add(_ url: String?, _ title: String?) {
      guard let url, !url.isEmpty, seen.insert(url).inserted else { return }
      results.append(WebResult(url: url, title: title ?? ""))
    }
    for block in content {
      if block["type"] as? String == "web_search_tool_result",
        let items = block["content"] as? [[String: Any]]
      {
        for item in items where item["type"] as? String == "web_search_result" {
          add(item["url"] as? String, item["title"] as? String)
        }
      }
      // Pages Claude cited in its answer carry the same link and title.
      if block["type"] as? String == "text", let citations = block["citations"] as? [[String: Any]] {
        for citation in citations { add(citation["url"] as? String, citation["title"] as? String) }
      }
    }
    return results
  }

  /// Sends one request body, retrying rate limits and server errors, and returns the decoded reply.
  private func post(_ body: [String: Any], model: String, apiKey: String) async throws -> [String: Any] {
    let request = Self.request(
      model: model, apiKey: apiKey, body: try JSONSerialization.data(withJSONObject: body))
    var lastError: ClaudeError = .network("no attempt made")
    for attempt in 0..<3 {
      if attempt > 0 {
        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 2_000_000_000))
      }
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 200 { return object }
        let message = (object["error"] as? [String: Any])?["message"] as? String ?? ""
        lastError = .http(status, message)
        if !Self.isRetryable(status) { throw lastError }
      } catch let error as ClaudeError {
        throw error
      } catch {
        lastError = .network(error.localizedDescription)
      }
    }
    throw lastError
  }

  /// Asks Claude to search the web and returns the pages it found. A long search can pause partway
  /// (`pause_turn`); it is resumed by sending the reply so far straight back.
  func webSearch(model: String, system: String, prompt: String, maxUses: Int) async throws -> WebSearchOutcome {
    guard let apiKey = keyProvider(), !apiKey.isEmpty else { throw ClaudeError.missingKey }
    var messages: [[String: Any]] = [["role": "user", "content": prompt]]
    var outcome = WebSearchOutcome()
    for _ in 0..<4 {
      let reply = try await post(
        Self.webSearchBody(model: model, system: system, messages: messages, maxUses: maxUses),
        model: model, apiKey: apiKey)
      let content = reply["content"] as? [[String: Any]] ?? []
      for result in Self.webResults(in: content) where !outcome.results.contains(result) {
        outcome.results.append(result)
      }
      let usage = reply["usage"] as? [String: Any] ?? [:]
      outcome.inputTokens += usage["input_tokens"] as? Int ?? 0
      outcome.outputTokens += usage["output_tokens"] as? Int ?? 0
      outcome.searches += (usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int ?? 0

      let stopReason = reply["stop_reason"] as? String
      if stopReason == "refusal" {
        let category = (reply["stop_details"] as? [String: Any])?["category"] as? String
        throw ClaudeError.refusal(category ?? "")
      }
      guard stopReason == "pause_turn" else { break }
      messages.append(["role": "assistant", "content": content])
    }
    return outcome
  }

  private static func errorFrom(data: Data, status: Int) -> ClaudeError {
    do {
      _ = try parse(data: data, status: status)
      return .http(status, "")
    } catch let error as ClaudeError {
      return error
    } catch {
      return .http(status, "")
    }
  }
}
