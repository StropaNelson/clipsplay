import Foundation

/// What the user wants back from the AI: new outputs, or edits to existing episodes.
enum ClipBriefScope: String, Codable {
    case outputs
    case editExisting
}

/// Builds the `.clipbrief` package handed to an external AI. Everything stays on
/// device; only this JSON (no media) is shared by the user.
enum ClipBriefBuilder {
    /// Word gaps this wide count as pauses (mirrors AnalysisCoordinator's silences).
    private static let pauseGap: Double = 0.8
    /// Same boundary rule as HookFinder: sentence-final punctuation or a >=0.6 s gap.
    private static let sentenceGap: Double = 0.6
    private static let sentenceFinals: Set<Character> = [".", "?", "!", "…"]

    static func ms(_ seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    static func episodeStateID(forIndex index: Int) -> String {
        "ep_\(index + 1)"
    }

    // MARK: - Build

    static func build(
        project: Project,
        analysis: ContentAnalysis?,
        scope: ClipBriefScope,
        includeTranscript: Bool = true,
        includeVocabulary: Bool = true
    ) -> ClipBrief {
        let words = project.transcriptWords ?? analysis?.transcriptWords ?? []
        let sceneCuts = project.sceneCuts ?? analysis?.sceneCuts ?? []
        let duration = project.sequenceSourceDuration
        let oriented = project.sourceVideoNaturalSize.cgSize
            .applying(project.sourceVideoTransform.cgAffineTransform)

        var transcript: [ClipBriefSentence] = []
        var hooks: [ClipBriefHook] = []
        if includeTranscript {
            transcript = sentences(from: words)
            hooks = HookFinder.suggest(
                words: words,
                duration: duration,
                purpose: .opening,
                limit: 10
            ).map { suggestion in
                ClipBriefHook(
                    in_ms: ms(suggestion.start),
                    out_ms: ms(suggestion.end),
                    text: suggestion.text,
                    score: (suggestion.score * 100).rounded() / 100
                )
            }
        }

        return ClipBrief(
            generated_at: ISO8601DateFormatter().string(from: Date()),
            project_name: project.name,
            source: ClipBriefSource(
                duration_ms: ms(duration),
                width: Int(abs(oriented.width).rounded()),
                height: Int(abs(oriented.height).rounded()),
                source_clip_count: project.sourceClips.count
            ),
            transcript: transcript,
            pauses: pauses(words: words, silences: analysis?.silenceRanges ?? []),
            scene_cuts: sceneCuts.map(ms),
            topics: (analysis?.topicBoundaries ?? []).map {
                ClipBriefTopic(time_ms: ms($0.time), label: $0.label)
            },
            hooks: hooks,
            energy_peaks: energyPeaks(analysis?.audioEnergy ?? []),
            vocabulary: includeVocabulary ? (project.transcriptionVocabulary ?? []) : [],
            assets: project.mediaAssets.map(assetBrief),
            episodes_state: scope == .editExisting ? episodeStates(project: project) : nil,
            capabilities: ClipBriefCapabilities(
                plan_version: ClipPlanContract.planVersion,
                scope: scope == .editExisting ? "editExisting" : "outputs",
                max_outputs: ClipPlanContract.maxOutputs,
                max_operations: ClipPlanContract.maxOperations,
                time_unit: "ms",
                formats: ClipPlanContract.formats,
                caption_styles: ClipPlanContract.captionStyles,
                text_positions: ClipPlanContract.textPositions,
                text_styles: ClipPlanContract.textStyles,
                text_colors: ClipPlanContract.textColors,
                transition_styles: ClipPlanContract.transitionStyles,
                operation_kinds: ClipPlanContract.operationKinds,
                operations_executable: true
            )
        )
    }

    static func encode(_ brief: ClipBrief) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(brief),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func encode(_ plan: ClipPlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(plan),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// The validator context matching what the brief described: episodes and
    /// assets renumbered exactly like `build` does.
    static func validationContext(project: Project, analysis: ContentAnalysis? = nil) -> ClipPlanValidator.Context {
        ClipPlanValidator.Context(
            duration_ms: ms(project.sequenceSourceDuration),
            assets: project.mediaAssets.map(assetBrief),
            episodes: episodeStates(project: project),
            hasTranscript: !(project.transcriptWords ?? analysis?.transcriptWords ?? []).isEmpty
                || project.transcriptSRT != nil
        )
    }

    static func assetBrief(_ asset: MediaAsset) -> ClipBriefAsset {
        ClipBriefAsset(
            id: asset.id.uuidString,
            name: asset.name,
            type: assetTypeName(asset.type),
            duration_ms: ms(asset.duration)
        )
    }

    static func briefFileName(project: Project) -> String {
        let safe = project.name.replacingOccurrences(of: "/", with: "-")
        return "\(safe)_brief.clipbrief"
    }

    // MARK: - Transcript sentences

    /// Groups words into sentences on sentence-final punctuation or a >=0.6 s
    /// gap — the same boundary rule as HookFinder.
    static func sentences(from words: [TranscriptWord]) -> [ClipBriefSentence] {
        let sorted = words.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }
        var result: [ClipBriefSentence] = []
        var startIndex = 0
        for index in 0..<sorted.count {
            let isLast = index == sorted.count - 1
            let boundary = isLast
                || isSentenceFinal(sorted[index].text)
                || (sorted[index + 1].start - sorted[index].end) >= sentenceGap
            if boundary {
                let text = sorted[startIndex...index].map(\.text).joined(separator: " ")
                result.append(ClipBriefSentence(
                    id: "s_\(result.count + 1)",
                    in_ms: ms(sorted[startIndex].start),
                    out_ms: ms(sorted[index].end),
                    text: text
                ))
                startIndex = index + 1
            }
        }
        return result
    }

    private static func isSentenceFinal(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceFinals.contains(last)
    }

    // MARK: - Pauses

    /// Analysis silence ranges merged with long word-gaps (deduped, sorted).
    static func pauses(words: [TranscriptWord], silences: [AnalysisRange]) -> [ClipBriefRange] {
        var ranges = silences.map { $0.start...$0.end }
        let sorted = words.sorted { $0.start < $1.start }
        for index in sorted.indices.dropLast() {
            let gap = sorted[index + 1].start - sorted[index].end
            if gap >= pauseGap {
                ranges.append(sorted[index].end...sorted[index + 1].start)
            }
        }
        return merge(ranges).map {
            ClipBriefRange(in_ms: ms($0.lowerBound), out_ms: ms($0.upperBound))
        }
    }

    private static func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
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

    // MARK: - Energy peaks

    /// Strongest local maxima of the 0.5 s average-energy profile, as in/out
    /// windows. `> left && >= right` picks the first bucket of a plateau.
    static func energyPeaks(_ energy: [Float], interval: Double = 0.5, limit: Int = 8) -> [ClipBriefRange] {
        guard !energy.isEmpty else { return [] }
        var peaks: [(index: Int, value: Float)] = []
        for index in energy.indices {
            let value = energy[index]
            let left = index > 0 ? energy[index - 1] : -1
            let right = index < energy.count - 1 ? energy[index + 1] : -1
            if value > 0 && value > left && value >= right {
                peaks.append((index, value))
            }
        }
        if peaks.isEmpty, let index = energy.indices.max(by: { energy[$0] < energy[$1] }), energy[index] > 0 {
            peaks.append((index, energy[index]))
        }
        return peaks
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { item in
                ClipBriefRange(
                    in_ms: ms(Double(item.index) * interval),
                    out_ms: ms(Double(item.index + 1) * interval)
                )
            }
            .sorted { $0.in_ms < $1.in_ms }
    }

    // MARK: - Episode state

    /// Snapshot of every episode's storyline/texts/audio with the stable ids
    /// that ClipPlan operations reference (ep_N, seg_N, txt_N, aud_N).
    static func episodeStates(project: Project) -> [ClipBriefEpisodeState] {
        project.episodes.enumerated().map { index, episode in
            let segments = episode.storyline().enumerated().map { itemIndex, item -> ClipBriefSegmentState in
                let clip = item.segment
                // Main clips are addressed in source-sequence ms; vinhetas are
                // addressed inside their own asset.
                let inSeconds = item.track == .main
                    ? clip.sequenceStartTime + clip.startTime
                    : clip.startTime
                let outSeconds = item.track == .main
                    ? clip.sequenceStartTime + clip.endTime
                    : clip.endTime
                return ClipBriefSegmentState(
                    id: "seg_\(itemIndex + 1)",
                    track: trackName(item.track),
                    source_in_ms: ms(inSeconds),
                    source_out_ms: ms(outSeconds)
                )
            }
            let texts = episode.textOverlays.enumerated().map { itemIndex, overlay -> ClipBriefTextState in
                ClipBriefTextState(
                    id: "txt_\(itemIndex + 1)",
                    text: overlay.text,
                    start_ms: ms(overlay.startTime),
                    duration_ms: ms(overlay.duration)
                )
            }
            let audio = episode.resolvedAudioClips(global: project.globalAudioClips)
                .enumerated()
                .map { itemIndex, clip -> ClipBriefAudioState in
                    ClipBriefAudioState(
                        id: "aud_\(itemIndex + 1)",
                        asset_id: clip.assetID.uuidString,
                        kind: audioKindName(clip.kind),
                        volume: Double(clip.volume),
                        start_ms: ms(clip.timelineStart),
                        end_ms: ms(clip.endTime)
                    )
                }
            return ClipBriefEpisodeState(
                episode_id: episodeStateID(forIndex: index),
                title: episode.title,
                segments: segments,
                texts: texts,
                audio: audio
            )
        }
    }

    static func trackName(_ track: TrackType) -> String {
        switch track {
        case .intro: return "intro"
        case .recap: return "recap"
        case .main: return "main"
        case .outro: return "outro"
        case .audio: return "audio"
        case .overlay: return "overlay"
        }
    }

    static func audioKindName(_ kind: AudioClipKind) -> String {
        switch kind {
        case .music: return "music"
        case .narration: return "narration"
        case .videoSound: return "videoSound"
        }
    }

    static func assetTypeName(_ type: AssetType) -> String {
        switch type {
        case .video: return "video"
        case .audio: return "audio"
        case .image: return "image"
        }
    }
}
