import Foundation

/// A silence candidate detected from speech gaps and/or audio energy, clipped
/// to the editable source ranges and to the user's trim margin.
struct DetectedPause: Identifiable, Hashable {
    let id: Int
    var rawStart: Double
    var rawEnd: Double
    var start: Double
    var end: Double
    var fromSpeech: Bool

    var duration: Double { end - start }

    enum Kind: String {
        case speech = "fala"
        case audio = "áudio"
    }

    var kind: Kind { fromSpeech ? .speech : .audio }
}

enum PauseDetector {
    /// Detects pauses in global sequence time.
    /// - Parameters:
    ///   - words: transcript words ordered by start; empty means audio-only detection.
    ///   - energy: normalized 0...1 RMS samples covering the whole sequence.
    ///   - interval: seconds per energy sample.
    ///   - totalDuration: global sequence duration in seconds.
    ///   - minPause: minimum candidate length before margins.
    ///   - margin: seconds kept at each edge of a detected pause.
    ///   - coverage: source ranges (global time) that are actually editable.
    static func detect(
        words: [TranscriptWord],
        energy: [Float],
        interval: Double,
        totalDuration: Double,
        minPause: Double,
        margin: Double,
        coverage: [ClosedRange<Double>]
    ) -> [DetectedPause] {
        guard totalDuration > 0, !coverage.isEmpty else { return [] }
        let sortedWords = words.sorted { $0.start < $1.start }

        var candidates: [(start: Double, end: Double, fromSpeech: Bool)] = []

        if !sortedWords.isEmpty {
            if sortedWords[0].start - 0 >= minPause {
                candidates.append((0, sortedWords[0].start, true))
            }
            for index in 1..<sortedWords.count {
                let gapStart = sortedWords[index - 1].end
                let gapEnd = sortedWords[index].start
                if gapEnd - gapStart >= minPause {
                    candidates.append((gapStart, gapEnd, true))
                }
            }
            if totalDuration - sortedWords[sortedWords.count - 1].end >= minPause {
                candidates.append((sortedWords[sortedWords.count - 1].end, totalDuration, true))
            }
        }

        for run in audioQuietRuns(energy: energy, interval: interval,
                                  totalDuration: totalDuration, minPause: minPause) {
            if sortedWords.isEmpty {
                candidates.append((run.lowerBound, run.upperBound, false))
            } else if !sortedWords.contains(where: {
                run.lowerBound < $0.end + 0.05 && run.upperBound > $0.start - 0.05
            }) {
                candidates.append((run.lowerBound, run.upperBound, false))
            }
        }

        candidates.sort { $0.start < $1.start }
        var merged: [(Double, Double, Bool)] = []
        for candidate in candidates where candidate.end - candidate.start >= minPause {
            if let last = merged.last, candidate.start <= last.1 {
                merged[merged.count - 1].1 = max(last.1, candidate.end)
                merged[merged.count - 1].2 = last.2 || candidate.fromSpeech
            } else {
                merged.append((candidate.start, candidate.end, candidate.fromSpeech))
            }
        }

        var pauses: [DetectedPause] = []
        for (rawStart, rawEnd, fromSpeech) in merged {
            let cutStart = rawStart + margin
            let cutEnd = rawEnd - margin
            guard cutEnd > cutStart else { continue }
            for piece in coverage {
                let start = max(cutStart, piece.lowerBound)
                let end = min(cutEnd, piece.upperBound)
                guard end - start >= 0.2 else { continue }
                pauses.append(DetectedPause(
                    id: pauses.count,
                    rawStart: rawStart,
                    rawEnd: rawEnd,
                    start: start,
                    end: end,
                    fromSpeech: fromSpeech
                ))
            }
        }
        return pauses.sorted { $0.start < $1.start }.enumerated().map { index, pause in
            var pause = pause
            pause = DetectedPause(id: index, rawStart: pause.rawStart, rawEnd: pause.rawEnd,
                                  start: pause.start, end: pause.end, fromSpeech: pause.fromSpeech)
            return pause
        }
    }

    /// Runs of consecutive low-energy frames, returned as global time ranges.
    private static func audioQuietRuns(energy: [Float], interval: Double,
                                       totalDuration: Double, minPause: Double) -> [ClosedRange<Double>] {
        guard !energy.isEmpty, interval > 0 else { return [] }
        let sorted = energy.sorted()
        let noise = percentile(sorted, 0.1)
        let speech = percentile(sorted, 0.9)
        let threshold = noise + 0.35 * (speech - noise)

        var runs: [ClosedRange<Double>] = []
        var startIndex: Int?
        for (index, value) in energy.enumerated() {
            if value < threshold {
                if startIndex == nil { startIndex = index }
            } else if let runStart = startIndex {
                appendRun(start: runStart, end: index, energy: energy, interval: interval,
                          totalDuration: totalDuration, minPause: minPause, to: &runs)
                startIndex = nil
            }
        }
        if let runStart = startIndex {
            appendRun(start: runStart, end: energy.count, energy: energy, interval: interval,
                      totalDuration: totalDuration, minPause: minPause, to: &runs)
        }
        return runs
    }

    private static func appendRun(start: Int, end: Int, energy: [Float], interval: Double,
                                  totalDuration: Double, minPause: Double,
                                  to runs: inout [ClosedRange<Double>]) {
        let lower = Double(start) * interval
        let upper = min(Double(end) * interval, totalDuration)
        guard upper - lower >= minPause else { return }
        runs.append(lower...upper)
    }

    private static func percentile(_ sorted: [Float], _ fraction: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let position = Double(sorted.count - 1) * fraction
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let t = Float(position - Double(lower))
        return sorted[lower] * (1 - t) + sorted[upper] * t
    }
}
