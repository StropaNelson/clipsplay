import Foundation
import NaturalLanguage
import UIKit

/// A user-reviewable transcript correction produced entirely on device.
struct TranscriptCorrection: Identifiable {
    enum Kind: String {
        case spelling = "Ortografia"
        case semantic = "Semântica"
        case ai = "IA"
    }

    let id = UUID()
    let original: String
    let replacement: String
    let time: Double
    let kind: Kind
}

struct TranscriptCorrectionResult: Identifiable {
    let id = UUID()
    let words: [TranscriptWord]
    let srt: String
    let corrections: [TranscriptCorrection]

    var changed: Bool { !corrections.isEmpty }
}

/// Conservative local correction: spelling comes from UITextChecker, while the
/// semantic pass only normalizes shorthand, capitalization and punctuation.
/// It never rewrites whole sentences or deletes spoken words.
@MainActor
final class TranscriptCorrectionService {
    static let shared = TranscriptCorrectionService()

    private init() {}

    func correct(words: [TranscriptWord], localeIdentifier: String, vocabulary: [String] = []) -> TranscriptCorrectionResult {
        let sorted = words.sorted { $0.start < $1.start }
        let checker = UITextChecker()
        let language = Self.checkerLanguage(for: localeIdentifier)
        let terms = Self.cleanVocabulary(vocabulary)
        var working = sorted
        var corrections = applyVocabularyPhrases(&working, terms: terms)
        let singleTerms = terms.filter { !$0.contains(" ") }
        let foldedTerms = Dictionary(singleTerms.map { (Self.folded($0), $0) }, uniquingKeysWith: { first, _ in first })
        var corrected: [TranscriptWord] = []

        for word in working {
            let replacement = correctedText(
                for: word.text,
                checker: checker,
                language: language,
                vocabulary: foldedTerms,
                vocabularyTerms: singleTerms
            )
            if replacement.text != word.text {
                corrections.append(TranscriptCorrection(
                    original: word.text,
                    replacement: replacement.text,
                    time: word.start,
                    kind: replacement.kind ?? .spelling
                ))
            }
            var updated = word
            updated.text = replacement.text
            corrected.append(contentsOf: expanded(updated))
        }

        let semantic = applySemanticCorrections(corrected)
        let cues = Self.cues(from: semantic.words)
        return TranscriptCorrectionResult(
            words: semantic.words,
            srt: SubtitleFile.srt(from: cues),
            corrections: corrections + semantic.corrections
        )
    }

    private func correctedText(
        for token: String,
        checker: UITextChecker,
        language: String?,
        vocabulary: [String: String],
        vocabularyTerms: [String]
    ) -> (text: String, kind: TranscriptCorrection.Kind?) {
        let coreRange = token.range(of: Self.corePattern, options: .regularExpression)
        guard let range = coreRange else { return (token, nil) }

        let prefix = String(token[..<range.lowerBound])
        let suffix = String(token[range.upperBound...])
        let core = String(token[range])
        let normalized = Self.normalized(core)

        if let term = vocabulary[Self.folded(core)] {
            guard term != core else { return (token, nil) }
            return (prefix + styled(term, like: core) + suffix, .semantic)
        }
        if let replacement = Self.semanticReplacements[normalized] {
            return (prefix + styled(replacement, like: core) + suffix, .semantic)
        }

        guard let language = language, normalized.count >= 3 else { return (token, nil) }
        let fullRange = NSRange(core.startIndex..<core.endIndex, in: core)
        let misspelled = checker.rangeOfMisspelledWord(
            in: core,
            range: fullRange,
            startingAt: 0,
            wrap: false,
            language: language
        )
        if misspelled.location != NSNotFound, core.count >= 5,
           let term = Self.nearestVocabularyTerm(to: core, terms: vocabularyTerms) {
            return (prefix + styled(term, like: core) + suffix, .semantic)
        }
        guard misspelled.location != NSNotFound,
              let guess = checker.guesses(forWordRange: misspelled, in: core, language: language)?.first,
              safeReplacement(guess, for: core) else { return (token, nil) }
        return (prefix + styled(guess, like: core) + suffix, .spelling)
    }

    private func safeReplacement(_ candidate: String, for original: String) -> Bool {
        let normalizedCandidate = Self.normalized(candidate)
        let normalizedOriginal = Self.normalized(original)
        guard !normalizedCandidate.isEmpty, normalizedCandidate != normalizedOriginal else { return false }
        if normalizedCandidate.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            == normalizedOriginal.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) {
            return true
        }
        if candidate.contains(" ") { return true }
        return abs(candidate.count - original.count) <= max(3, original.count / 2)
    }

    private func styled(_ replacement: String, like original: String) -> String {
        if original.count > 1, original == original.uppercased() {
            return replacement.uppercased()
        }
        if let first = original.first, String(first) == String(first).uppercased(), String(first) != String(first).lowercased() {
            return Self.capitalizeFirstLetter(replacement)
        }
        return replacement
    }

    private func expanded(_ word: TranscriptWord) -> [TranscriptWord] {
        let pieces = word.text.split(whereSeparator: \.isWhitespace)
        guard pieces.count > 1 else { return [word] }
        return TranscriptWord.spread(word.text, from: word.start, to: word.end)
    }

    private func applySemanticCorrections(_ input: [TranscriptWord]) -> (words: [TranscriptWord], corrections: [TranscriptCorrection]) {
        var words = input
        var corrections: [TranscriptCorrection] = []

        for index in words.indices {
            let startsSentence = index == 0 || words[index - 1].text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) != nil
            guard startsSentence else { continue }
            let original = words[index].text
            let capitalized = Self.capitalizeFirstLetter(original)
            if capitalized != original {
                words[index].text = capitalized
                corrections.append(TranscriptCorrection(original: original, replacement: capitalized, time: words[index].start, kind: .semantic))
            }
        }

        let plain = words.map(\.text).joined(separator: " ")
        var spans: [(index: Int, range: Range<String.Index>)] = []
        var cursor = plain.startIndex
        for index in words.indices {
            let end = plain.index(cursor, offsetBy: words[index].text.count)
            spans.append((index, cursor..<end))
            cursor = end < plain.endIndex ? plain.index(after: end) : end
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = plain
        tagger.enumerateTags(
            in: plain.startIndex..<plain.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, tokenRange in
            guard tag == .personalName || tag == .placeName || tag == .organizationName else { return true }
            for span in spans where span.range.lowerBound < tokenRange.upperBound && tokenRange.lowerBound < span.range.upperBound {
                let original = words[span.index].text
                let capitalized = Self.capitalizeFirstLetter(original)
                if capitalized != original {
                    words[span.index].text = capitalized
                    corrections.append(TranscriptCorrection(original: original, replacement: capitalized, time: words[span.index].start, kind: .semantic))
                }
            }
            return true
        }
        return (words, corrections)
    }

    private static func cues(from words: [TranscriptWord]) -> [TranscriptCue] {
        var cues: [TranscriptCue] = []
        var current: [TranscriptWord] = []
        for word in words {
            if let last = current.last,
               word.start - last.end > 0.65
                || current.count >= 14
                || last.text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) != nil {
                cues.append(cue(from: current))
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { cues.append(cue(from: current)) }
        return cues
    }

    private static func cue(from words: [TranscriptWord]) -> TranscriptCue {
        TranscriptCue(
            startTime: words.first?.start ?? 0,
            endTime: words.last?.end ?? 0,
            text: cleanText(words.map(\.text).joined(separator: " ")),
            words: words
        )
    }

    private static func cleanText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizeFirstLetter(_ text: String) -> String {
        var characters = Array(text)
        for index in characters.indices where characters[index].isLetter {
            characters[index] = Character(String(characters[index]).uppercased())
            break
        }
        return String(characters)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
    }

    private static func checkerLanguage(for localeIdentifier: String) -> String? {
        let underscored = localeIdentifier.replacingOccurrences(of: "-", with: "_")
        let languageCode = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? "pt"
        let candidates = [underscored, languageCode, "pt_BR", "pt", "en_US", "en"]
        let available = UITextChecker.availableLanguages
        if available.isEmpty { return candidates.first }
        return candidates.first { available.contains($0) }
    }

    /// Multi-word vocabulary terms ("Final Cut") match consecutive token sequences
    /// only when they fold to the same words; the tokens are then recased to the
    /// vocabulary spelling without any fuzzy matching.
    private func applyVocabularyPhrases(_ words: inout [TranscriptWord], terms: [String]) -> [TranscriptCorrection] {
        var corrections: [TranscriptCorrection] = []
        let phrases = terms.compactMap { term -> [String]? in
            let parts = term.split(whereSeparator: \.isWhitespace).map(String.init)
            return parts.count > 1 ? parts : nil
        }
        guard !phrases.isEmpty else { return corrections }

        var index = 0
        while index < words.count {
            var matched = false
            for parts in phrases where index + parts.count <= words.count {
                let matches = parts.indices.allSatisfy { offset in
                    Self.folded(Self.coreText(of: words[index + offset].text)) == Self.folded(parts[offset])
                }
                guard matches else { continue }
                for offset in parts.indices {
                    let word = words[index + offset]
                    guard let range = word.text.range(of: Self.corePattern, options: .regularExpression) else { continue }
                    let updated = String(word.text[..<range.lowerBound]) + parts[offset] + String(word.text[range.upperBound...])
                    if updated != word.text {
                        corrections.append(TranscriptCorrection(original: word.text, replacement: updated, time: word.start, kind: .semantic))
                        words[index + offset].text = updated
                    }
                }
                index += parts.count
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        return corrections
    }

    private static func nearestVocabularyTerm(to core: String, terms: [String]) -> String? {
        let foldedCore = folded(core)
        let limit = core.count >= 8 ? 2 : 1
        var best: (term: String, distance: Int)?
        for term in terms {
            let distance = levenshtein(foldedCore, folded(term))
            guard distance <= limit else { continue }
            if best == nil || distance < best!.distance {
                best = (term, distance)
            }
        }
        return best?.term
    }

    private static func cleanVocabulary(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = folded(trimmed)
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func coreText(of token: String) -> String {
        guard let range = token.range(of: corePattern, options: .regularExpression) else { return token }
        return String(token[range])
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let lhs = Array(a)
        let rhs = Array(b)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// Merges a transcript revised by an external AI with the original cues/word timings.
    /// When the cue count is unchanged the original timings are kept (AI timestamps may
    /// drift); a different count means the AI restructured the text and its timings are used.
    nonisolated static func mergePastedTranscript(_ pasted: String, original originalCues: [TranscriptCue], words: [TranscriptWord]) throws -> TranscriptCorrectionResult {
        let cleaned = pasted
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
        let parsed = try SubtitleFile.parse(cleaned)
        let keepOriginalTimings = parsed.count == originalCues.count

        var resultCues: [TranscriptCue] = []
        var corrections: [TranscriptCorrection] = []

        for (index, cue) in parsed.enumerated() {
            let start = keepOriginalTimings ? originalCues[index].startTime : cue.startTime
            let end = keepOriginalTimings ? originalCues[index].endTime : cue.endTime
            let original = originalCues.indices.contains(index) ? originalCues[index] : nil
            let cueWords = words.filter { $0.start >= start - 0.05 && $0.start < end }
            let newText = cue.text
            let changed = collapsedText(newText) != collapsedText(original?.text ?? "")

            let mergedWords: [TranscriptWord]
            if !changed && !cueWords.isEmpty {
                mergedWords = cueWords
            } else {
                let tokens = newText.split(whereSeparator: \.isWhitespace).map(String.init)
                if !cueWords.isEmpty && tokens.count == cueWords.count {
                    mergedWords = zip(cueWords, tokens).map { word, token in
                        TranscriptWord(text: token, start: word.start, end: word.end)
                    }
                } else {
                    mergedWords = TranscriptWord.spread(newText, from: start, to: end)
                }
            }

            resultCues.append(TranscriptCue(startTime: start, endTime: end, text: newText, words: mergedWords))
            if changed {
                corrections.append(TranscriptCorrection(
                    original: original?.text ?? "",
                    replacement: newText,
                    time: start,
                    kind: .ai
                ))
            }
        }

        return TranscriptCorrectionResult(
            words: resultCues.flatMap(\.words),
            srt: SubtitleFile.srt(from: resultCues),
            corrections: corrections
        )
    }

    nonisolated private static func collapsedText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    nonisolated private static func normalizedText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let corePattern = #"[\p{L}\p{N}][\p{L}\p{N}'’\-]*"#
    private static let semanticReplacements: [String: String] = [
        "vc": "você",
        "vcs": "vocês",
        "pq": "porque",
        "tb": "também",
        "tbm": "também",
        "blz": "beleza",
        "oq": "o que",
        "q": "que",
        "mt": "muito",
        "mto": "muito",
        "mtd": "muito",
        "obg": "obrigado",
        "obgda": "obrigada",
        "dps": "depois",
        "td": "tudo",
        "tds": "todos",
        "agr": "agora",
        "cmg": "comigo",
        "ctg": "contigo"
    ]
}
