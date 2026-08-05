import Foundation

/// Small, local intent matcher used by Melo's Guide, settings search, and Find an
/// Action. It deliberately avoids network calls and machine-learning dependencies:
/// a curated synonym map plus typo-tolerant token matching is predictable, private,
/// and easy to extend alongside new settings.
///
/// Relevance rules, in order of importance:
///
/// 1. **Where a word matches decides almost everything.** A hit in a title is worth
///    far more than one buried in a paragraph of detail text. Weighing every field
///    equally is what made searching "volume" return most of the catalog.
/// 2. **Most of the query must match.** A result that satisfies one word out of
///    three is noise, so anything below `minimumCoverage` scores zero regardless of
///    how strong that single hit was.
/// 3. **Synonyms broaden, they do not promote.** An expanded match is worth a
///    fraction of a literal one, and words that appear in almost every Melo entry
///    are deliberately absent from the synonym map.
nonisolated enum IntentSearch {
    /// Fraction of the user's own words a result must account for. Below this the
    /// result is dropped entirely — this is the main precision control.
    private static let minimumCoverage = 0.5

    /// Synonyms exist to catch the words a person reaches for that Melo does not
    /// use. Groups are intentionally narrow: treating "sound" as equivalent to
    /// "volume" in an app where nearly every entry mentions sound matches
    /// everything, which reads to the user as broken search.
    private static let synonymGroups: [[String]] = [
        ["quiet", "quieter", "lower", "soften", "turn down"],
        ["loud", "louder", "raise", "turn up", "boost"],
        ["mute", "silence", "turn off sound"],
        ["unmute", "restore sound", "turn sound on"],
        ["speaker", "speakers", "output", "play through"],
        ["headphones", "headset", "earbuds", "airpods"],
        ["microphone", "mic", "input"],
        ["route", "routing", "send audio", "where it plays", "play on"],
        ["remember", "preset", "scene", "setup", "saved"],
        ["automatic", "automatically", "automation", "when this happens"],
        ["call", "meeting", "zoom", "facetime", "discord", "huddle"],
        ["duck", "ducking", "lower during calls"],
        ["equalizer", "eq", "tone", "bass", "treble"],
        ["voice", "voices", "speech", "dialogue", "dialog"],
        ["mono", "both ears", "one ear"],
        ["hide", "remove from list", "ignore"],
        ["inactive", "idle", "disappear"],
        ["repair", "fix", "reset", "not working", "broken"],
        ["permission", "allow", "access"],
        ["privacy", "local", "on this mac"],
        ["update", "upgrade", "new version", "download"],
        ["help", "guide", "how do i", "instructions", "tutorial"],
        ["shortcut", "hotkey", "keyboard", "command"],
        ["timer", "sleep", "turn off later", "fade out"],
        ["undo", "go back", "reverse"],
        ["battery", "power", "energy", "unplugged"],
        ["theme", "appearance", "look", "color", "colour"],
        ["menu bar", "status bar", "top bar"],
    ]

    /// Filler words carry no intent but do carry synonym expansions, so leaving them
    /// in meant "how do I mute an app" scored the help topics as highly as the mute
    /// topic. They are stripped from the token pass and kept for phrase matching.
    private static let stopwords: Set<String> = [
        "a", "an", "the", "my", "me", "i", "do", "does", "how", "what", "when",
        "to", "in", "on", "of", "is", "it", "and", "or", "for", "with", "can",
        "please", "melo"
    ]

    private static let groupLookup: [String: Set<String>] = {
        var result: [String: Set<String>] = [:]
        for group in synonymGroups {
            let normalized = Set(group.flatMap { tokens(in: $0) })
            for term in normalized {
                result[term, default: []].formUnion(normalized)
            }
        }
        return result
    }()

    // MARK: - Scoring

    /// Weighted scoring. `title` is what the user is looking at, `keywords` are the
    /// words they might use instead, `body` is supporting prose.
    static func score(
        query: String,
        title: String,
        keywords: [String] = [],
        body: [String] = []
    ) -> Int {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return 1 }

        let normalizedTitle = normalize(title)
        let normalizedKeywords = keywords.map(normalize).filter { !$0.isEmpty }
        let normalizedBody = body.map(normalize).filter { !$0.isEmpty }

        var score = 0

        // Phrase hits, strongest first.
        if normalizedTitle == normalizedQuery {
            score += 1000
        } else if normalizedTitle.hasPrefix(normalizedQuery) {
            score += 600
        } else if normalizedTitle.contains(normalizedQuery) {
            score += 400
        }

        if normalizedKeywords.contains(normalizedQuery) {
            score += 350
        } else if normalizedKeywords.contains(where: { $0.contains(normalizedQuery) }) {
            score += 200
        }

        if normalizedBody.contains(where: { $0.contains(normalizedQuery) }) {
            score += 120
        }

        // Token hits, weighted by where they land.
        let titleTokens = Set(tokens(in: normalizedTitle))
        let keywordTokens = Set(normalizedKeywords.flatMap(tokens(in:)))
        let bodyTokens = Set(normalizedBody.flatMap(tokens(in:)))

        let queryTokens = meaningfulTokens(in: normalizedQuery)
        // A word answered outright counts fully toward coverage; one answered only
        // through a synonym counts half, which is enough for a single-word query
        // like "eq" or "airpods" to survive while still holding multi-word queries
        // to a real standard.
        var coverageCredit = 0.0

        for token in queryTokens {
            let direct = max(
                weight(for: token, in: titleTokens, base: 60),
                max(
                    weight(for: token, in: keywordTokens, base: 40),
                    weight(for: token, in: bodyTokens, base: 15)
                )
            )
            if direct > 0 {
                score += direct
                coverageCredit += 1
                continue
            }

            // Synonyms broaden reach at a fraction of the value.
            var best = 0
            for synonym in groupLookup[token] ?? [] where synonym != token {
                best = max(
                    best,
                    max(
                        weight(for: synonym, in: titleTokens, base: 24),
                        max(
                            weight(for: synonym, in: keywordTokens, base: 16),
                            weight(for: synonym, in: bodyTokens, base: 6)
                        )
                    )
                )
            }
            score += best
            if best > 0 { coverageCredit += 0.5 }
        }

        guard !queryTokens.isEmpty else { return score }

        // Precision gate: a result that accounts for less than half of what the user
        // typed is noise, however strongly it matched that one word.
        let coverage = coverageCredit / Double(queryTokens.count)
        guard coverage >= minimumCoverage else { return 0 }
        score += Int(coverage * 200)

        return score
    }

    /// Compatibility shim for call sites that pass a flat field list. The first
    /// field is treated as the title, the rest as body.
    static func score(query: String, fields: [String], aliases: [String] = []) -> Int {
        score(
            query: query,
            title: fields.first ?? "",
            keywords: aliases,
            body: Array(fields.dropFirst())
        )
    }

    static func matches(query: String, fields: [String], aliases: [String] = []) -> Bool {
        score(query: query, fields: fields, aliases: aliases) > 0
    }

    /// Ranks candidates, drops the weak tail, and caps the list. Showing everything
    /// that scored above zero is why search "found" forty results and still felt
    /// useless; a floor relative to the best hit is what makes a short list honest.
    static func rank<T>(
        _ candidates: [T],
        limit: Int = 8,
        floorFraction: Double = 0.35,
        scoring: (T) -> Int
    ) -> [T] {
        let scored = candidates
            .map { (item: $0, score: scoring($0)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        guard let best = scored.first?.score, best > 0 else { return [] }
        let floor = Int(Double(best) * floorFraction)
        return Array(scored.prefix { $0.score >= floor }.prefix(limit).map(\.item))
    }

    static func containsIntent(_ query: String, any terms: [String]) -> Bool {
        let expanded = expandedTokens(for: normalize(query))
        let target = Set(terms.flatMap { expandedTokens(for: normalize($0)) })
        return !expanded.isDisjoint(with: target)
    }

    /// Reads a volume out of a phrase such as "Spotify to 40%". A bare number is
    /// only accepted when it carries a percent sign or an explicit "to"/"at", so an
    /// app named "Studio 3" is not silently read as a volume.
    static func percentage(in query: String) -> Int? {
        let patterns = [
            #"(?<!\d)(100|[1-9]?\d)\s*%"#,
            #"\b(?:to|at)\s+(100|[1-9]?\d)\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(
                    in: query,
                    range: NSRange(query.startIndex..., in: query)
                  ),
                  let range = Range(match.range(at: 1), in: query),
                  let value = Int(query[range]),
                  (0...100).contains(value) else { continue }
            return value
        }
        return nil
    }

    // MARK: - Matching primitives

    private static func weight(for token: String, in haystack: Set<String>, base: Int) -> Int {
        if haystack.contains(token) { return base }
        // Prefix matching works from two characters, so "eq", "mic", and "hud" —
        // some of the most likely queries in this app — are no longer excluded by
        // the four-character floor the typo matcher needs.
        if token.count >= 2, haystack.contains(where: { $0.hasPrefix(token) }) {
            return Int(Double(base) * 0.8)
        }
        if haystack.contains(where: { fuzzyMatch(token, $0) }) {
            return Int(Double(base) * 0.5)
        }
        return 0
    }

    private static func expandedTokens(for text: String) -> Set<String> {
        let base = Set(tokens(in: text))
        var result = base
        for token in base {
            result.formUnion(groupLookup[token] ?? [])
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"[^a-z0-9%]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(in text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Query tokens with filler words removed. A query made entirely of filler
    /// ("how do I") keeps its words rather than matching nothing at all.
    private static func meaningfulTokens(in text: String) -> [String] {
        let all = tokens(in: text)
        let filtered = all.filter { !stopwords.contains($0) }
        return filtered.isEmpty ? all : filtered
    }

    private static func fuzzyMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.count >= 4, rhs.count >= 4 else { return false }
        if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return true }
        let allowance = (lhs.count > 7 || rhs.count > 7) ? 2 : 1
        return editDistance(lhs, rhs, limit: allowance) <= allowance
    }

    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if abs(a.count - b.count) > limit { return limit + 1 }

        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            var rowMinimum = current[0]
            for (j, cb) in b.enumerated() {
                let cost = ca == cb ? 0 : 1
                current[j + 1] = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + cost
                )
                rowMinimum = min(rowMinimum, current[j + 1])
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
