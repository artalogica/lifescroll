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
        "subject": string(
          "What it is about, in two or three plain lowercase words, such as 'robot hands' or 'bread baking'. Copy an existing subject label exactly when it is the same subject."),
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

  /// Finds things one step away from the user's interests.
  static let adjacentSearch = """
    You find things for the suggestions in Lifescroll, a personal menu bar app. Alongside tasks, its \
    feed shows the user things they would enjoy opening. You are given the subjects they have \
    recently been watching and reading about.

    Do not search for those subjects themselves: they already get plenty of that. Search one step \
    away from them. For each search, start from one of their subjects and move sideways: the \
    neighbouring field, the history behind it, the craft or the people behind it, the place it turns \
    up unexpectedly, what else people who love it tend to fall for. Someone into robot hands might \
    enjoy how prosthetic hands are made, how pianists train their fingers, or how octopus arms work.

    Start each search from a different subject of theirs, so the results are spread out. Look for \
    things with some life in them: a well-made video, a long-form essay, a striking project, a talk \
    people recommend. Avoid news roundups and listicles.

    Your searches go to a public search engine. Never search for the user's own name, or the name \
    of a private project, course or company of theirs.

    When you have searched, reply with a short list of the best few things you found.
    """

  /// Finds things with nothing to do with the user's interests.
  static let farSearch = """
    You find things for the suggestions in Lifescroll, a personal menu bar app. Alongside tasks, its \
    feed shows the user things they would enjoy opening. This search is for surprise: things with \
    nothing to do with what they usually read.

    You are given a few fields chosen at random, and the subjects they already follow. Run one \
    search for each field. In each, look for the single most remarkable thing a curious outsider \
    could open and be glad they did: a classic essay, a beautiful explainer, an astonishing story, \
    a documentary or talk people keep recommending years later. It should need no background, and \
    it should be the kind of thing someone forwards to a friend.

    Stay well away from the subjects they already follow, and avoid news, listicles, and anything \
    that reads like homework.

    Your searches go to a public search engine. Never search for the user's own name, or the name \
    of a private project, course or company of theirs.

    When you have searched, reply with a short list of the best few things you found.
    """

  /// Finds things that take a minute or two: the quick, scrollable part of the feed.
  static let shortSearch = """
    You find things for the suggestions in Lifescroll, a personal menu bar app. Alongside tasks, its \
    feed shows the user things they would enjoy opening. This search is for the quick ones: things \
    that take a minute or two and are satisfying straight away, the way a good short video is.

    Look for short videos and clips (under about three minutes: YouTube Shorts, short explainers, \
    a single striking demonstration), short visual pieces (one remarkable image, chart, map or \
    animation with a paragraph), and very short reads (a single good anecdote, a one-screen post). \
    Each should work with no background and pay off quickly.

    You are given some of the subjects they follow and a few fields chosen at random. Run about \
    half your searches on their subjects and half on the fields, so the quick ones are a mix of \
    familiar and new. Adding words such as "short", "in 60 seconds" or "shorts" to a search helps.

    Avoid compilations, reaction videos, clickbait, and anything that is mostly an advertisement.

    Your searches go to a public search engine. Never search for the user's own name, or the name \
    of a private project, course or company of theirs.

    When you have searched, reply with a short list of the best few things you found.
    """

  static let picks = """
    You choose the suggestions for Lifescroll's feed. This is the enjoyable half of the feed: things \
    the user would be glad they opened, not more homework. You are given what they have recently been \
    watching and reading, how they responded to earlier suggestions, what is already waiting in \
    their feed, and candidates from a bank of things found by search.

    Each candidate is marked with a distance. close is about what they are into now. adjacent is one \
    step away from it. far has nothing to do with it and is there for surprise. short is something \
    quick, a clip or a one-screen read, on any subject. A good feed has all four, and the user has \
    said theirs was too much of the same thing and had too little that is quick to flick through.

    Choose up to the number given as choose_up_to, best first, taking candidates from every distance: \
    about a third short ones, and the rest spread evenly over the other three, when the candidates \
    are good enough. Only choose a short candidate if it really is short: a few minutes at most. No two of your choices may be about \
    the same subject, and none may share a subject with something in waiting_in_feed. Never choose \
    anything about a subject in rested_subjects: those have been suggested enough for now, however \
    much the user liked them. Spread your choices across different sites and different kinds.

    For close candidates, prefer what is substantive and well regarded. For adjacent and far ones, \
    prefer what is vivid, surprising and easy to start on over what is thorough: the point is that \
    they open it and are glad, not that it is important.

    Leave out anything like what they said was not for them, anything thin or clickbait, job posts, \
    and near-duplicates. Choosing fewer, or none, is fine when the candidates are weak.

    subject is two or three plain words for what the piece is about. When it is the same subject as \
    one in waiting_in_feed or rested_subjects, copy that label exactly.

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
  static let target = 12
  /// The most web searches Claude may run for one distance in one round. Each search is billed on
  /// top of tokens. A distance is only searched when the bank is running low on it.
  static let maxWebSearches = 3
  /// The three distances a suggestion can be from what the user is already into.
  /// "short" is not a distance but a length: quick things on any subject. It is stocked and
  /// shared out the same way, so it sits in the same list.
  static let distances = ["close", "adjacent", "far", "short"]
  /// Below this many waiting at a distance, the bank is topped up with a search.
  static let bankLow = 12
  /// How many from each distance are put in front of the chooser.
  static let offeredPerDistance = 18
  /// Suggested this many times within `restWindow`, a subject is rested.
  static let wornOutAfter = 3
  static let restWindow: TimeInterval = 10 * 86_400

  /// Fields to go looking in for surprise. A few are drawn at random each time, in code, because
  /// a model asked to "pick something different" tends to pick the same few things.
  static let fields = [
    "deep sea biology", "medieval history", "typography", "architecture", "jazz", "cartography",
    "linguistics", "mountaineering", "food science", "astronomy", "animation", "textiles",
    "urban planning", "chess", "mycology", "shipwrecks", "perfume", "bridges", "puppetry",
    "volcanoes", "cryptic crosswords", "bird migration", "film editing", "clockmaking",
    "ancient trade routes", "sign languages", "glassblowing", "polar exploration", "economics of everyday things",
    "calligraphy", "insects", "sound design", "gardens", "maritime navigation", "paleontology",
    "stage magic", "subway systems", "folk music", "optical illusions", "bookbinding", "weather",
    "ceramics", "the history of numbers", "trees", "espionage history", "dance", "caves",
    "photography", "board game design", "rivers", "the history of medicine", "comics", "tea",
    "lighthouses", "memory and the mind", "deserts", "opera", "knots", "the Silk Road", "spiders",
  ]

  /// How many of each distance a full feed of `target` suggestions should hold.
  nonisolated static func mix(of target: Int) -> [String: Int] {
    // A third are quick ones; the rest are split between close, a step away and far afield.
    let short = target / 3
    let rest = target - short
    let far = max(rest / 4, rest > 2 ? 1 : 0)
    let close = (rest - far + 1) / 2
    return ["close": close, "adjacent": rest - far - close, "far": far, "short": short]
  }

  /// Subjects suggested often enough lately that they get a rest, however well they were received.
  nonisolated static func rested(_ counts: [String: Int]) -> Set<String> {
    Set(counts.filter { $0.value >= wornOutAfter }.keys)
  }

  /// Turns the chooser's ordered picks into the ones that will be shown, keeping the feed varied.
  /// At most two per subject and two per site among everything waiting, nothing on a rested
  /// subject, and each distance held to its share. If that leaves room, the shares are relaxed,
  /// never the other limits.
  nonisolated static func varied(
    _ picks: [PickResult.Pick], candidates: [Candidate], waiting: [Recommendation],
    rested: Set<String>, room: Int, target: Int = Recommender.target
  ) -> [(pick: PickResult.Pick, candidate: Candidate)] {
    let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var subjects: [String: Int] = [:]
    var sites: [String: Int] = [:]
    var reach: [String: Int] = [:]
    for card in waiting {
      let subject = EntityMatching.normalize(card.subject)
      if !subject.isEmpty { subjects[subject, default: 0] += 1 }
      sites[card.source.lowercased(), default: 0] += 1
      reach[card.reach, default: 0] += 1
    }
    let share = mix(of: target)
    var chosen: [(pick: PickResult.Pick, candidate: Candidate)] = []
    var taken = Set<String>()

    for strict in [true, false] {
      for pick in picks where chosen.count < room && !taken.contains(pick.candidateId) {
        guard let candidate = byID[pick.candidateId] else { continue }
        let subject = EntityMatching.normalize(pick.subject ?? "")
        let site = candidate.source.lowercased()
        // Quick things mostly live on a few video sites, so those may appear more often.
        guard !rested.contains(subject), subjects[subject, default: 0] < (subject.isEmpty ? .max : 2),
          sites[site, default: 0] < (candidate.distance == "short" ? 4 : 2)
        else { continue }
        if strict, reach[candidate.distance, default: 0] >= share[candidate.distance, default: 0] { continue }
        // One per subject within a round: two only ever build up across rounds.
        if chosen.contains(where: { !subject.isEmpty && EntityMatching.normalize($0.pick.subject ?? "") == subject }) {
          continue
        }
        taken.insert(pick.candidateId)
        if !subject.isEmpty { subjects[subject, default: 0] += 1 }
        sites[site, default: 0] += 1
        reach[candidate.distance, default: 0] += 1
        chosen.append((pick, candidate))
      }
    }
    return chosen
  }
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

  /// The subjects the user follows, cleaned of anything private-looking. Safe to send to a search.
  nonisolated func subjects(now: Date) -> [String] {
    var seen = Set<String>()
    return (store.interestSignals(since: now.addingTimeInterval(-14 * 86_400)).map(\.topic)
      + store.entities(kind: .topic, limit: 20).map(\.name))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !Self.looksLikeFile($0) && seen.insert($0.lowercased()).inserted }
  }

  /// What the far search is told: the fields to look in, and what to stay away from. It needs no
  /// interests at all, so it works from the first day.
  nonisolated func farPrompt(fields: [String], now: Date) -> String {
    let known = subjects(now: now).prefix(20)
    return """
      Fields for this round, one search each:
      \(fields.map { "- \($0)" }.joined(separator: "\n"))

      Subjects they already follow, to stay away from:
      \(known.isEmpty ? "(none recorded yet)" : known.map { "- \($0)" }.joined(separator: "\n"))
      """
  }

  /// What the search for quick things is told: a few of their subjects and a couple of fields.
  nonisolated func shortPrompt(fields: [String], now: Date) -> String {
    let known = subjects(now: now).prefix(8)
    return """
      Some subjects they follow:
      \(known.isEmpty ? "(none recorded yet)" : known.map { "- \($0)" }.joined(separator: "\n"))

      Fields chosen at random for this round:
      \(fields.map { "- \($0)" }.joined(separator: "\n"))
      """
  }

  nonisolated func picksInput(
    candidates: [Candidate], interests: String?, waiting: [Recommendation] = [],
    rested: Set<String> = [], chooseUpTo: Int = Recommender.target
  ) -> String {
    let payload: [String: Any] = [
      "choose_up_to": chooseUpTo,
      "waiting_in_feed": waiting.map { ["title": $0.title, "subject": $0.subject, "site": $0.source] },
      "rested_subjects": rested.sorted(),
      "interests": interests ?? "Nothing recorded yet.",
      "earlier_suggestions": store.suggestionFeedback().map {
        ["title": $0.title, "response": $0.status == "opened" ? "opened it" : "said not for me"]
      },
      "candidates": candidates.map { candidate -> [String: Any] in
        var entry: [String: Any] = [
          "id": candidate.id, "title": candidate.title, "source": candidate.source,
          "link_host": URL(string: candidate.url)?.host ?? "", "marked": candidate.bucket,
          "distance": candidate.distance,
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

  /// One search by Claude at one distance. Returns what it found, already marked with the distance.
  private func search(distance: String, system: String, prompt: String, now: Date) async throws -> [Candidate] {
    // Every page a search returns is billed as input, around 25,000 tokens a search, and all that is
    // kept is the links. The small model runs the searches; choosing among them stays with Sonnet.
    var model = ClaudeClient.haiku
    var found: ClaudeClient.WebSearchOutcome
    do {
      found = try await client.webSearch(model: model, system: system, prompt: prompt, maxUses: Self.maxWebSearches)
    } catch ClaudeError.missingKey {
      throw ClaudeError.missingKey
    } catch {
      model = ClaudeClient.sonnet
      found = try await client.webSearch(model: model, system: system, prompt: prompt, maxUses: Self.maxWebSearches)
    }
    store.addUsage(model: model, input: found.inputTokens, output: found.outputTokens, now: now)
    store.addWebSearches(found.searches, now: now)
    return CandidateSources.candidates(fromWeb: found.results).map {
      var candidate = $0
      candidate.distance = distance
      candidate.bucket = distance == "close" ? "related" : "explore"
      return candidate
    }
  }

  /// Tops the bank up wherever it is running low. Each distance is searched only when fewer than
  /// `bankLow` are waiting at it, so most rounds search little or not at all.
  func stock(now: Date, fields: [String]? = nil) async throws -> [String] {
    var problems: [String] = []
    let known = webSearchPrompt(now: now)
    for distance in Self.distances where store.bankCount(distance: distance) < Self.bankLow {
      let system: String
      let prompt: String?
      switch distance {
      case "close": (system, prompt) = (Prompts.webSearch, known)
      case "adjacent": (system, prompt) = (Prompts.adjacentSearch, known)
      case "short":
        system = Prompts.shortSearch
        prompt = shortPrompt(fields: Array(Self.fields.shuffled().prefix(2)), now: now)
      default:
        system = Prompts.farSearch
        prompt = farPrompt(fields: fields ?? Array(Self.fields.shuffled().prefix(Self.maxWebSearches)), now: now)
      }
      // Close and adjacent searches start from the user's interests; with none recorded they wait.
      guard let prompt else { continue }
      do {
        let found = try await search(distance: distance, system: system, prompt: prompt, now: now)
        if found.isEmpty { problems.append("the \(distance) search returned no pages") }
        store.bank(found, now: now)
      } catch ClaudeError.missingKey {
        throw ClaudeError.missingKey
      } catch {
        problems.append(error.localizedDescription)
      }
    }
    return problems
  }

  /// Tops the stock of suggestions back up: fills the bank where it is low, then has Sonnet choose
  /// from the bank, and keeps only choices that leave the feed varied.
  func refresh(now: Date) async -> SuggestionOutcome {
    var outcome = SuggestionOutcome()
    store.expireRecommendations(before: now.addingTimeInterval(-7 * 86_400))
    store.pruneBank(before: now.addingTimeInterval(-30 * 86_400))
    let waiting = store.recommendations(status: "new")
    let room = Self.target - waiting.count
    guard room > 0 else { return outcome }

    do {
      let interests = interestsJSON(now: now)
      let webProblems = try await stock(now: now)

      // If Claude's own search brought nothing close, fall back to planned searches of arXiv and
      // Hacker News. The Hacker News front page is fetched either way, as a free source of things
      // a step away.
      var plan: SearchPlan?
      var planProblem: String?
      if let interests, store.bankCount(distance: "close") == 0 {
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
      var gatherProblems: [String] = []
      if plan != nil || store.bankCount(distance: "adjacent") < Self.bankLow {
        let gathered = await gather(plan: plan, now: now)
        gatherProblems = gathered.problems
        store.bank(
          gathered.found.map {
            var candidate = $0
            candidate.distance = candidate.bucket == "explore" ? "adjacent" : "close"
            return candidate
          }, now: now)
      }

      // Offer the chooser an even spread from the bank, a few from each distance in turn.
      let seen = store.seenContent()
      let stocks = Self.distances.map { store.bankCandidates(distance: $0, limit: Self.offeredPerDistance) }
      var offered: [Candidate] = []
      for index in 0..<Self.offeredPerDistance {
        for stock in stocks where index < stock.count { offered.append(stock[index]) }
      }
      let candidates = CandidateSources.clean(
        offered, suggested: store.suggestedURLs(), seenURLs: seen.urls, seenTitles: seen.titles,
        limit: Self.offeredPerDistance * Self.distances.count)
      outcome.candidates = candidates.count
      guard !candidates.isEmpty else {
        outcome.error = webProblems.first ?? planProblem ?? gatherProblems.first
        return outcome
      }

      let rested = Self.rested(store.subjectCounts(since: now.addingTimeInterval(-Self.restWindow)))
      let response = try await client.complete(
        model: ClaudeClient.sonnet, system: Prompts.picks,
        content: [[
          "type": "text",
          "text": picksInput(
            candidates: candidates, interests: interests, waiting: waiting, rested: rested,
            // Asked for more than there is room for, so the variety limits have something to drop.
            chooseUpTo: room * 2),
        ]],
        schema: Schema.picks, effort: "medium")
      store.addUsage(
        model: ClaudeClient.sonnet, input: response.inputTokens, output: response.outputTokens, now: now)
      let result = try JSONCoding.decoder.decode(PickResult.self, from: Data(response.text.utf8))
      let chosen = Self.varied(result.picks, candidates: candidates, waiting: waiting, rested: rested, room: room)
      var used: [String] = []
      for (pick, candidate) in chosen {
        let suggestion = Recommendation(
          title: candidate.title, url: candidate.url, source: candidate.source, kind: pick.kind,
          why: pick.why, bucket: candidate.distance == "close" ? "related" : "explore",
          estMinutes: max(pick.estMinutes, 0), created: now, subject: pick.subject ?? "",
          distance: candidate.distance)
        if store.add(suggestion) {
          outcome.added += 1
          used.append(candidate.url)
        }
      }
      store.markBank(shown: candidates.map(\.url), used: used)
      if let problem = webProblems.first {
        outcome.warning = "One of the web searches did not work (\(problem))."
      }
    } catch {
      outcome.error = error.localizedDescription
    }
    return outcome
  }
}
