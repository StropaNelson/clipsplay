import Foundation

/// Applies a validated ClipPlan to the editor. `outputs` plans become new
/// episodes built from source-sequence ranges (EditorViewModel.applyClipPlan);
/// `operations` plans are executed in place over the existing episodes by
/// EditorViewModel.applyClipPlanOperations. This type keeps the pure pieces
/// (range merging, id parsing, grouping) that both paths share.
enum ClipPlanExecutor {
    /// Message surfaced for a plan with neither outputs nor operations.
    static let emptyPlan =
        "O plano não contém saídas nem operações."

    /// Error surfaced when a plan reaches the executor without passing the
    /// validator (defensive — the import UI always validates first).
    static func validationFailed(_ errors: [String]) -> String {
        "O plano não passou na validação: \(errors.first ?? "erro desconhecido")"
    }

    /// Source-sequence ranges (seconds) of one output, clamped to the sequence
    /// duration, merged, ordered. Pieces <= 0.05 s are dropped (validated plans
    /// never have them; this guards programmatic callers).
    static func mergedSourceRanges(of output: ClipPlanOutput, sequenceDuration: Double) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        for segment in output.segments {
            let start = max(0, min(Double(segment.source_in_ms) / 1000, sequenceDuration))
            let end = max(start, min(Double(segment.source_out_ms) / 1000, sequenceDuration))
            if end - start > 0.05 { ranges.append(start...end) }
        }
        return mergeRanges(ranges)
    }

    /// Approximate duration (seconds) an output occupies on its timeline:
    /// merged segments plus the vinhetas (asset-local).
    static func outputDuration(_ output: ClipPlanOutput, sequenceDuration: Double) -> Double {
        var total = mergedSourceRanges(of: output, sequenceDuration: sequenceDuration)
            .reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        for vinheta in [output.intro, output.outro] {
            if let vinheta = vinheta {
                total += Double(max(0, vinheta.out_ms - vinheta.in_ms)) / 1000
            }
        }
        return total
    }

    // MARK: - operations helpers

    /// Parses a plan id into a zero-based index: "ep_1" → 0, "seg_3" → 2,
    /// "txt_2" → 1, "aud_4" → 3. Returns nil for malformed or out-of-range ids.
    static func planIndex(_ id: String?, prefix: String) -> Int? {
        guard let id = id, id.hasPrefix(prefix + "_") else { return nil }
        guard let number = Int(id.dropFirst(prefix.count + 1)), number >= 1 else { return nil }
        return number - 1
    }

    /// Source-sequence ranges (seconds) of every cut_range op, grouped by
    /// episode target and clamped to the sequence duration.
    static func cutRangesByTarget(_ ops: [ClipPlanOperation], sequenceDuration: Double) -> [String: [ClosedRange<Double>]] {
        var grouped: [String: [ClosedRange<Double>]] = [:]
        for operation in ops where operation.op == "cut_range" {
            guard let inMs = operation.in_ms, let outMs = operation.out_ms else { continue }
            let start = max(0, min(Double(inMs) / 1000, sequenceDuration))
            let end = max(start, min(Double(outMs) / 1000, sequenceDuration))
            guard end - start > 0.05 else { continue }
            grouped[operation.target, default: []].append(start...end)
        }
        return grouped
    }

    /// Minimum pause length (seconds) a remove_silences op asks for;
    /// 0.8 s when the plan leaves min_ms out.
    static func minPauseSeconds(_ operation: ClipPlanOperation) -> Double {
        Double(operation.min_ms ?? 800) / 1000
    }

    /// set_text_style size is a font scale clamped to the readable range.
    static func textFontScale(_ size: Double) -> Double {
        min(0.2, max(0.02, size))
    }

    private static func mergeRanges(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.upperBound > range.lowerBound {
            if let last = result.last, range.lowerBound <= last.upperBound + 0.02 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
