import Foundation

// Suggestions: Sonnet turns what the user has been watching and reading into search queries, arXiv and
// Hacker News are searched directly, and Sonnet picks the few results worth a card.

// MARK: - Sources

/// Reads arXiv's Atom feed.
final class ArxivFeedParser: NSObject, XMLParserDelegate {
  struct Entry: Equatable {
    var id = ""
    var title = ""
    var summary = ""
    var published = ""
  }

  private(set) var entries: [Entry] = []
  private var current: Entry?
  private var text = ""

  static func parse(_ data: Data) -> [Entry] {
    let delegate = ArxivFeedParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.parse()
    return delegate.entries
  }

  private static func collapse(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {
    if elementName == "entry" { current = Entry() }
    text = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    guard current != nil else { return }
    let value = Self.collapse(text)
    switch elementName {
    case "id": current?.id = value
    case "title": current?.title = value
    case "summary": current?.summary = value
    case "published": current?.published = value
    case "entry":
      if let entry = current { entries.append(entry) }
      current = nil
    default: break
    }
  }
}

enum CandidateSources {
  static let userAgent = "Lifescroll/0.1 (personal menu bar app)"

  /// Keeps a query to plain subject words: letters, digits and hyphens, at most six words.
  static func sanitize(_ query: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
    let cleaned = String(query.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
    return cleaned.split(separator: " ").prefix(6).joined(separator: " ")
  }

  static func sanitize(_ queries: [String], max count: Int = 4) -> [String] {
    var seen = Set<String>()
    return queries.map(sanitize).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
      .prefix(count).map { $0 }
  }

  static func arxivURL(query: String, maxResults: Int = 8) -> URL? {
    let words = sanitize(query).split(separator: " ")
    guard !words.isEmpty else { return nil }
    var components = URLComponents(string: "https://export.arxiv.org/api/query")
    components?.queryItems = [
      URLQueryItem(name: "search_query", value: words.map { "all:\($0)" }.joined(separator: " AND ")),
      URLQueryItem(name: "start", value: "0"),
      URLQueryItem(name: "max_results", value: String(maxResults)),
      URLQueryItem(name: "sortBy", value: "relevance"),
      URLQueryItem(name: "sortOrder", value: "descending"),
    ]
    return components?.url
  }

  /// Well-received Hacker News stories from the last year that match a query.
  static func hnSearchURL(query: String, now: Date, minPoints: Int = 50, hits: Int = 8) -> URL? {
    let cleaned = sanitize(query)
    guard !cleaned.isEmpty else { return nil }
    let since = Int(now.addingTimeInterval(-365 * 86_400).timeIntervalSince1970)
    var components = URLComponents(string: "https://hn.algolia.com/api/v1/search")
    components?.queryItems = [
      URLQueryItem(name: "query", value: cleaned),
      URLQueryItem(name: "tags", value: "story"),
      URLQueryItem(name: "numericFilters", value: "points>\(minPoints),created_at_i>\(since)"),
      URLQueryItem(name: "hitsPerPage", value: String(hits)),
    ]
    return components?.url
  }

  /// Today's front page, for suggestions outside the user's current interests.
  static func hnFrontPageURL(hits: Int = 20) -> URL? {
    var components = URLComponents(string: "https://hn.algolia.com/api/v1/search")
    components?.queryItems = [
      URLQueryItem(name: "tags", value: "front_page"),
      URLQueryItem(name: "hitsPerPage", value: String(hits)),
    ]
    return components?.url
  }

  static func parseArxiv(_ data: Data, bucket: String = "related") -> [Candidate] {
    let dates = ISO8601DateFormatter()
    return ArxivFeedParser.parse(data).compactMap { entry in
      guard !entry.title.isEmpty, entry.id.contains("arxiv.org/abs/") else { return nil }
      return Candidate(
        title: entry.title, url: entry.id.replacingOccurrences(of: "http://", with: "https://"),
        source: "arXiv", snippet: String(entry.summary.prefix(320)),
        published: dates.date(from: entry.published), points: nil, bucket: bucket)
    }
  }

  static func parseHN(_ data: Data, bucket: String = "related") -> [Candidate] {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let hits = object["hits"] as? [[String: Any]]
    else { return [] }
    return hits.compactMap { hit in
      guard let title = hit["title"] as? String, !title.isEmpty,
        let id = hit["objectID"] as? String
      else { return nil }
      // Stories without an outside link (Ask HN and the like) point at their discussion page.
      let link = (hit["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? "https://news.ycombinator.com/item?id=\(id)"
      let created = (hit["created_at_i"] as? Double).map { Date(timeIntervalSince1970: $0) }
      return Candidate(
        title: title, url: link, source: "Hacker News",
        snippet: String(((hit["story_text"] as? String) ?? "").prefix(320)), published: created,
        points: hit["points"] as? Int, bucket: bucket)
    }
  }

  /// Turns pages found by Claude's web search into candidates, named by the site they are on.
  static func candidates(fromWeb results: [ClaudeClient.WebResult]) -> [Candidate] {
    results.compactMap { result in
      guard let host = URL(string: result.url)?.host, !result.title.isEmpty else { return nil }
      return Candidate(
        title: result.title, url: result.url,
        source: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }
  }

  static func key(forURL url: String) -> String {
    var key = url.lowercased()
    for prefix in ["https://", "http://", "www."] where key.hasPrefix(prefix) {
      key.removeFirst(prefix.count)
    }
    while key.hasSuffix("/") { key.removeLast() }
    return key
  }

  /// Drops anything unusable, already suggested or already seen, removes repeats, and numbers what is left.
  static func clean(
    _ candidates: [Candidate], suggested: Set<String>, seenURLs: Set<String>, seenTitles: Set<String>,
    limit: Int = 50
  ) -> [Candidate] {
    var taken = Set(suggested.map(key(forURL:))).union(seenURLs.map(key(forURL:)))
    var result: [Candidate] = []
    for candidate in candidates {
      guard let url = URL(string: candidate.url), let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https", url.host != nil,
        !seenTitles.contains(EntityMatching.normalize(candidate.title)),
        taken.insert(key(forURL: candidate.url)).inserted
      else { continue }
      var numbered = candidate
      numbered.id = "c\(result.count + 1)"
      result.append(numbered)
      if result.count >= limit { break }
    }
    return result
  }

  /// Puts "explore" candidates first, capped, so the overall limit cannot squeeze them out.
  /// Related results arrive first and can alone exceed the limit.
  static func reservingExplore(_ candidates: [Candidate], slots: Int = 15) -> [Candidate] {
    let explore = candidates.filter { $0.bucket == "explore" }.prefix(slots)
    return explore + candidates.filter { $0.bucket != "explore" }
  }

  static func fetch(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      throw SearchError(
        message: status == 429
          ? "\(url.host ?? "The search service") is asking for fewer requests right now."
          : "\(url.host ?? "The search service") returned status \(status).",
        rateLimited: status == 429)
    }
    return data
  }
}

struct SearchError: LocalizedError, Equatable {
  let message: String
  /// The service said to slow down. Asking again straight away only extends the limit.
  var rateLimited = false
  var errorDescription: String? { message }
}

// MARK: - Prompts and schemas

extension Schema {
  static let searchPlan: [String: Any] = object([
    "arxiv_queries": array(string("Two to five general subject words for an arXiv search.")),
    "hn_queries": array(string("One to four general subject words for a Hacker News search.")),
    "interests_summary": string("One sentence on what this person is into right now."),
  ])

  static let picks: [String: Any] = object([
    "picks": array(
      object([
        "candidate_id": string("Id of the chosen candidate, copied exactly."),
        "why": string("One line on why they would like it, addressed as 'you', under 90 characters."),
        "kind": choice(["paper", "article", "video", "discussion"], "What it is."),
        "bucket": choice(["related", "explore"], "Close to their interests, or outside them."),
        "est_minutes": ["type": "integer", "description": "Honest guess at minutes to read or watch."],
      ]))
  ])
}

extension Prompts {
  static let searchPlan = """
    You plan the searches behind the suggestions in Lifescroll, a personal menu bar app. Alongside \
    tasks, its feed shows the user things they would enjoy: a good talk, an interesting paper, a \
    sharp essay. You are given what they have recently been watching and reading, and the topics the \
    app has seen them work on.

    Write search queries that would turn up things they would be glad to open. Most queries should sit \
    close to what they are into right now. One or two should be adjacent: something a person with \
    these interests would probably also enjoy, even though it has not come up.

    arxiv_queries are for academic subjects only, up to four. hn_queries are for Hacker News, which \
    surfaces articles, essays, talks and videos, up to four. Leave a list empty when nothing fits it.

    The queries are sent to public search services, so write only general subject words. Never \
    include a person's name, the name of a private project, course or company, or anything else that \
    could identify the user.
    """

  static let webSearch = """
    You find things for the suggestions in Lifescroll, a personal menu bar app. Alongside tasks, its \
    feed shows the user things they would enjoy opening: a video, a thread, a project, an essay, a \
    paper. You are given the subjects they have recently been watching and reading about, and the \
    sites, channels and accounts those came from.

    Search the web for things they would be glad to open. Look where they already spend time, and \
    on the popular places for each interest: video sites, forums and discussion sites, code hosting, \
    newsletters and blogs. Most searches should sit close to what they are into right now; one or \
    two can be adjacent. Run several different searches so the results are not all from one site.

    Your searches go to a public search engine. Public creators and publications they follow are \
    fine to search for. Never search for the user's own name, or the name of a private project, \
    course or company of theirs.

    When you have searched, reply with a short list of the best few things you found.
    """

  static let picks = """
    You choose the suggestions for Lifescroll's feed. This is the enjoyable half of the feed: things \
    the user would be glad they opened, not more homework. You are given what they have recently been \
    watching and reading, how they responded to earlier suggestions, and candidates found by search.

    Choose up to eight candidates. Prefer things that are substantive and well regarded, that fit \
    what they are into, and that differ from each other in topic and kind. If there are good \
    candidates marked explore, include two or three, so the feed is not only more of the same.

    Leave out anything like what they said was not for them, anything thin or clickbait, job posts, \
    and near-duplicates of each other. Choosing fewer than eight, or none, is fine when the candidates \
    are weak.

    For each pick, why is the card's single line: address the user as "you", say concretely what is \
    in it or why it connects to what they have been doing, keep it under 90 characters, and avoid hype. \
    Use kind "video" when the link is to a video, "discussion" when the value is in the comments.
    """
}

// MARK: - The recommender

struct SuggestionOutcome: Equatable {
  var candidates = 0
  var added = 0
  var error: String?
  /// Something that went wrong without stopping the round, such as the web search failing while
  /// the older searches still found things.
  var warning: String?
}

actor Recommender {
  /// How many unopened suggestions to keep on hand.
  static let target = 8
  /// The most web searches Claude may run in one round. Each search is billed on top of tokens.
  static let maxWebSearches = 5
  /// arXiv asks automated clients to leave about three seconds between requests.
  static let arxivPause: UInt64 = 3_000_000_000

  let store: Store
  let client: ClaudeClient

  init(store: Store, client: ClaudeClient = ClaudeClient()) {
    self.store = store
    self.client = client
  }

  /// What Sonnet is told about the user's interests, or nil when nothing has been recorded yet.
  nonisolated func interestsJSON(now: Date) -> String? {
    let signals = store.interestSignals(since: now.addingTimeInterval(-14 * 86_400))
    let topics = store.entities(kind: .topic, limit: 20).map(\.name)
    guard !signals.isEmpty || !topics.isEmpty else { return nil }
    let payload: [String: Any] = [
      "recently_watched_or_read": signals.map {
        ["title": $0.title, "topic": $0.topic, "kind": $0.kind, "source": $0.source]
      },
      "topics_worked_on": topics,
    ]
    return Self.json(payload)
  }

  /// What Claude is given to search from: the interests, and where they were seen.
  /// Whether a name looks like a file, such as `hw7-solutions.tex`. Those are private by nature.
  /// Site names such as `example.com` are not files.
  nonisolated static func looksLikeFile(_ name: String) -> Bool {
    guard !name.contains(" "),
      let dot = name.lastIndex(of: "."), dot != name.startIndex
    else { return false }
    let ending = name[name.index(after: dot)...].lowercased()
    guard (1...5).contains(ending.count), ending.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
    return !["com", "org", "net", "io", "edu", "dev", "ai", "co", "app", "tv", "fm"].contains(ending)
  }

  /// What the web search step is told. Unlike the choosing step, this call can send what it is
  /// given out to a search engine, so it gets subjects and public sources only: never the titles
  /// of what the user had open, which can name private documents, and nothing that looks like a file.
  nonisolated func webSearchPrompt(now: Date) -> String? {
    let since = now.addingTimeInterval(-14 * 86_400)
    var seen = Set<String>()
    let subjects = (store.interestSignals(since: since).map(\.topic) + store.entities(kind: .topic, limit: 20).map(\.name))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !Self.looksLikeFile($0) && seen.insert($0.lowercased()).inserted }
    guard !subjects.isEmpty else { return nil }
    let sources = store.usedSources(since: since).filter { !Self.looksLikeFile($0) }
    return """
      Subjects they have been watching and reading about, most recent first:
      \(subjects.prefix(30).map { "- \($0)" }.joined(separator: "\n"))

      Sites, channels and accounts those came from, most recent first:
      \(sources.isEmpty ? "(none recorded yet)" : sources.map { "- \($0)" }.joined(separator: "\n"))
      """
  }

  nonisolated func picksInput(candidates: [Candidate], interests: String?) -> String {
    let payload: [String: Any] = [
      "interests": interests ?? "Nothing recorded yet.",
      "earlier_suggestions": store.suggestionFeedback().map {
        ["title": $0.title, "response": $0.status == "opened" ? "opened it" : "said not for me"]
      },
      "candidates": candidates.map { candidate -> [String: Any] in
        var entry: [String: Any] = [
          "id": candidate.id, "title": candidate.title, "source": candidate.source,
          "link_host": URL(string: candidate.url)?.host ?? "", "marked": candidate.bucket,
        ]
        if !candidate.snippet.isEmpty { entry["summary"] = candidate.snippet }
        if let points = candidate.points { entry["points"] = points }
        if let published = candidate.published {
          entry["published"] = Analyzer.timestamp(published, format: "yyyy-MM-dd")
        }
        return entry
      },
    ]
    return Self.json(payload) ?? "{}"
  }

  private static func json(_ payload: [String: Any]) -> String? {
    (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
      .flatMap { String(data: $0, encoding: .utf8) }
  }

  /// Stores the chosen candidates. Links always come from the search results, never from the model's reply.
  @discardableResult
  nonisolated static func apply(
    _ picks: [PickResult.Pick], candidates: [Candidate], to store: Store, now: Date, limit: Int
  ) -> Int {
    let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var added = 0
    for pick in picks where added < limit {
      guard let candidate = byID[pick.candidateId] else { continue }
      let suggestion = Recommendation(
        title: candidate.title, url: candidate.url, source: candidate.source, kind: pick.kind,
        why: pick.why, bucket: pick.bucket, estMinutes: max(pick.estMinutes, 0), created: now)
      if store.add(suggestion) { added += 1 }
    }
    return added
  }

  /// Runs the searches for a plan and returns everything found, plus a note for each search that failed.
  /// One failed search does not stop the rest.
  nonisolated func gather(
    plan: SearchPlan?, now: Date, pause: UInt64 = Recommender.arxivPause,
    fetch: @Sendable (URL) async throws -> Data = { try await CandidateSources.fetch($0) }
  ) async -> (found: [Candidate], problems: [String]) {
    var found: [Candidate] = []
    var problems: [String] = []

    enum Attempt {
      case data(Data)
      case rateLimited
      case failed
    }

    func search(_ url: URL, retryAfter retryPause: UInt64? = nil) async -> Attempt {
      do {
        return .data(try await fetch(url))
      } catch let error as SearchError where error.rateLimited {
        // Asked to slow down: do not retry, and let the caller stop asking this service.
        problems.append(error.message)
        return .rateLimited
      } catch {
        // Any other failure gets one slower retry where the caller allows it.
        if let retryPause {
          try? await Task.sleep(nanoseconds: retryPause)
          if let data = try? await fetch(url) { return .data(data) }
        }
        problems.append(error.localizedDescription)
        return .failed
      }
    }

    arxiv: for (index, query) in CandidateSources.sanitize(plan?.arxivQueries ?? []).enumerated() {
      guard let url = CandidateSources.arxivURL(query: query) else { continue }
      if index > 0 { try? await Task.sleep(nanoseconds: pause) }
      switch await search(url, retryAfter: pause * 2) {
      case .data(let data): found += CandidateSources.parseArxiv(data)
      case .rateLimited: break arxiv
      case .failed: continue
      }
    }
    for query in CandidateSources.sanitize(plan?.hnQueries ?? []) {
      guard let url = CandidateSources.hnSearchURL(query: query, now: now) else { continue }
      if case .data(let data) = await search(url) { found += CandidateSources.parseHN(data) }
    }
    if let url = CandidateSources.hnFrontPageURL(), case .data(let data) = await search(url) {
      found += CandidateSources.parseHN(data, bucket: "explore")
    }
    return (found, problems)
  }

  /// Tops the stock of suggestions back up. Two Sonnet calls at most: one to plan, one to choose.
  func refresh(now: Date) async -> SuggestionOutcome {
    var outcome = SuggestionOutcome()
    store.expireRecommendations(before: now.addingTimeInterval(-7 * 86_400))
    let room = Self.target - store.recommendations(status: "new").count
    guard room > 0 else { return outcome }

    do {
      let interests = interestsJSON(now: now)

      // First choice: Claude searches the web itself, steered by where the user already spends time.
      var web: [Candidate] = []
      var webProblem: String?
      if let prompt = webSearchPrompt(now: now) {
        do {
          let found = try await client.webSearch(
            model: ClaudeClient.sonnet, system: Prompts.webSearch, prompt: prompt,
            maxUses: Self.maxWebSearches)
          store.addUsage(
            model: ClaudeClient.sonnet, input: found.inputTokens, output: found.outputTokens, now: now)
          store.addWebSearches(found.searches, now: now)
          web = CandidateSources.candidates(fromWeb: found.results)
          if web.isEmpty {
            webProblem = "the search ran \(found.searches) times but returned no pages"
          }
        } catch ClaudeError.missingKey {
          throw ClaudeError.missingKey
        } catch {
          webProblem = error.localizedDescription
        }
      }

      // Only if that found nothing: the older route of planned searches on arXiv and Hacker News.
      var plan: SearchPlan?
      var planProblem: String?
      if let interests, web.isEmpty {
        // A failed plan only loses the targeted searches; the front page still needs no plan.
        do {
          let response = try await client.complete(
            model: ClaudeClient.sonnet, system: Prompts.searchPlan,
            content: [["type": "text", "text": interests]], schema: Schema.searchPlan, effort: "low")
          store.addUsage(
            model: ClaudeClient.sonnet, input: response.inputTokens, output: response.outputTokens,
            now: now)
          plan = try JSONCoding.decoder.decode(SearchPlan.self, from: Data(response.text.utf8))
        } catch ClaudeError.missingKey {
          throw ClaudeError.missingKey
        } catch {
          planProblem = error.localizedDescription
        }
      }

      let seen = store.seenContent()
      // With no plan this fetches only the Hacker News front page, for picks outside their interests.
      let gathered = await gather(plan: plan, now: now)
      let candidates = CandidateSources.clean(
        CandidateSources.reservingExplore(web + gathered.found), suggested: store.suggestedURLs(),
        seenURLs: seen.urls, seenTitles: seen.titles)
      outcome.candidates = candidates.count
      guard !candidates.isEmpty else {
        // Nothing at all came back: say why, if planning or a search failed.
        outcome.error = webProblem ?? planProblem ?? gathered.problems.first
        return outcome
      }

      let response = try await client.complete(
        model: ClaudeClient.sonnet, system: Prompts.picks,
        content: [["type": "text", "text": picksInput(candidates: candidates, interests: interests)]],
        schema: Schema.picks, effort: "medium")
      store.addUsage(
        model: ClaudeClient.sonnet, input: response.inputTokens, output: response.outputTokens, now: now)
      let result = try JSONCoding.decoder.decode(PickResult.self, from: Data(response.text.utf8))
      outcome.added = Self.apply(result.picks, candidates: candidates, to: store, now: now, limit: room)
      if let webProblem {
        outcome.warning = "Web search did not work (\(webProblem)), so these came from arXiv and Hacker News."
      }
    } catch {
      outcome.error = error.localizedDescription
    }
    return outcome
  }
}
