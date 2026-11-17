import Foundation

/// A planned episode boundary in sequence time, tagged with why it was chosen.
struct EpisodeCut: Hashable {
    enum Kind: String {
        case sourceBoundary = "junção de vídeos"
        case sentenceEnd = "fim de frase"
        case pause = "pausa"
        case quiet = "silêncio"
        case exact = "tempo exato"
    }

    var time: Double
    var kind: Kind
}

/// Splits the whole source sequence into sequential, gap-free episodes.
/// Pure and synchronous so it can be unit-tested; audio/word data is optional.
enum EpisodePlanner {
    /// Sensible episode length for the target format and total duration.
    static func suggestedLength(totalDuration: Double, format: AspectRatio, sourceIsPortrait: Bool) -> Double {
        let vertical = format == .portrait9_16 || format == .portrait4_5 || format == .portrait3_4
            || format == .square1_1 || (format == .original && sourceIsPortrait)
        var length: Double
        if vertical {
            length = 60
        } else if totalDuration <= 360 {
            length = 60
        } else if totalDuration <= 1200 {
            length = 180
        } else {
            length = 300
        }
        if episodeCount(totalDuration: totalDuration, targetLength: length) > 30 {
            length = totalDuration / 30
        }
        return max(5, length)
    }

    /// Balanced part count: 5:12 at 60 s target → 5 parts of ~62 s (no sliver).
    static func episodeCount(totalDuration: Double, targetLength: Double) -> Int {
        guard totalDuration > 0, targetLength > 0 else { return 1 }
        return max(1, min(50, Int((totalDuration / targetLength).rounded())))
    }

    /// Evenly spaced cut times for `count` parts.
    static func idealCuts(totalDuration: Double, count: Int) -> [Double] {
        guard count > 1, totalDuration > 0 else { return [] }
        return (1..<count).map { Double($0) * totalDuration / Double(count) }
    }

    /// Snaps each ideal cut to the best nearby natural boundary:
    /// source-clip joins > sentence ends > word pauses > quiet audio points > exact time.
    static func snappedCuts(
        ideal: [Double],
        totalDuration: Double,
        words: [TranscriptWord],
        quietPoints: [Double],
        hardBoundaries: [Double],
        tolerance: Double = 10
    ) -> [EpisodeCut] {
        let sortedWords = words.sorted { $0.start < $1.start }
        let target = ideal.isEmpty ? totalDuration : totalDuration / Double(ideal.count + 1)
        let minSpacing = max(5, target * 0.5)

        var result: [EpisodeCut] = []
        var previous = 0.0
        for idealCut in ideal {
            var best: (time: Double, kind: EpisodeCut.Kind, score: Double)?

            func consider(_ time: Double, _ kind: EpisodeCut.Kind, _ base: Double) {
                let distance = abs(time - idealCut)
                guard distance <= tolerance else { return }
                let score = base - 0.6 * distance / tolerance
                if best == nil || score > best!.score {
                    best = (time, kind, score)
                }
            }

            for boundary in hardBoundaries {
                consider(boundary, .sourceBoundary, 3.0)
            }
            for index in 1..<max(1, sortedWords.count) {
                let gap = sortedWords[index].start - sortedWords[index - 1].end
                guard gap >= 0.25 else { continue }
                let midpoint = sortedWords[index - 1].end + gap / 2
                let punctuated = sortedWords[index - 1].text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?…")) != nil
                consider(midpoint, punctuated ? .sentenceEnd : .pause, min(gap, 2) / 2 + (punctuated ? 1.0 : 0))
            }
            for point in quietPoints {
                consider(point, .quiet, 0.8)
            }

            var candidate: EpisodeCut
            if let best = best {
                candidate = EpisodeCut(time: best.time, kind: best.kind)
            } else {
                var time = idealCut
                if let inside = sortedWords.first(where: { time > $0.start && time < $0.end }) {
                    time = inside.end
                }
                candidate = EpisodeCut(time: time, kind: .exact)
            }

            if candidate.time <= previous + minSpacing || candidate.time >= totalDuration - minSpacing {
                candidate = EpisodeCut(time: idealCut, kind: .exact)
                if let inside = sortedWords.first(where: { candidate.time > $0.start && candidate.time < $0.end }) {
                    candidate.time = inside.end
                }
            }
            result.append(candidate)
            previous = candidate.time
        }
        return result
    }
}
