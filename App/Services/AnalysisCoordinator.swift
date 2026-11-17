import Foundation

enum AnalysisStage: String, Codable, CaseIterable, Identifiable {
    case preparing = "Preparando"
    case transcribing = "Transcrevendo"
    case detectingScenes = "Analisando cenas"
    case indexing = "Organizando índice"
    case completed = "Concluído"
    case failed = "Falhou"

    var id: String { rawValue }
}

struct AnalysisProgress {
    let stage: AnalysisStage
    let message: String
    let fraction: Double
}

/// Coordinates all local analysis once, then saves a reusable index. A failed
/// optional step is recorded as a warning so the rest of the index remains usable.
actor AnalysisCoordinator {
    static let shared = AnalysisCoordinator()

    private let store = AnalysisStore.shared
    private let transcription = TranscriptionService.shared
    private let visualAnalysis = VisualAnalysisService.shared

    private init() {}

    func cachedAnalysis(for project: Project, localeIdentifier: String? = nil) async -> ContentAnalysis? {
        guard let cached = await store.load(projectID: project.id, sourceSignature: sourceSignature(for: project)),
              reusable(cached, for: project),
              localeIdentifier == nil || cached.transcriptionLocale == nil || cached.transcriptionLocale == localeIdentifier else { return nil }
        return cached
    }

    func needsAnalysis(for project: Project, localeIdentifier: String? = nil) async -> Bool {
        await cachedAnalysis(for: project, localeIdentifier: localeIdentifier) == nil
    }

    func invalidate(projectID: UUID) async {
        await store.invalidate(projectID: projectID)
    }

    func analyze(
        project: Project,
        request: AutomationRequest,
        progress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async -> ContentAnalysis {
        let signature = sourceSignature(for: project)
        let stored = await store.load(projectID: project.id)
        let sourceChanged = stored != nil && stored?.sourceSignature != signature
        let matchingStored = sourceChanged ? nil : stored
        var projectMatchesStored = false
        if let stored = stored {
            let transcriptMatches = project.transcriptSRT == nil || project.transcriptSRT == stored.transcriptSRT
            let wordsMatch = project.transcriptWords == nil || project.transcriptWords == stored.transcriptWords
            projectMatchesStored = transcriptMatches && wordsMatch
        }
        var staleLocale = false
        if let matchingStored = matchingStored {
            staleLocale = matchingStored.transcriptionLocale != nil
                && matchingStored.transcriptionLocale != request.localeIdentifier
                && projectMatchesStored
        }
        if let cached = matchingStored, reusable(cached, for: project), !staleLocale {
            progress(AnalysisProgress(stage: .completed, message: "Análise reutilizada.", fraction: 1))
            return cached
        }
        let cached = matchingStored

        var warnings: [String] = []
        let sourceDuration = project.sequenceSourceDuration
        let sourceClips = project.sourceClips
        let transcriptCoversSequence = project.transcriptSequenceDuration.map {
            abs($0 - sourceDuration) < 0.5
        } ?? (sourceClips.count <= 1)
        let discardProjectTranscript = sourceChanged || staleLocale || !transcriptCoversSequence
        if !transcriptCoversSequence, project.transcriptSRT != nil || project.transcriptWords != nil {
            warnings.append("A transcrição salva cobria outra sequência de vídeos e não foi reutilizada.")
        }
        var transcriptSRT = discardProjectTranscript ? nil : project.transcriptSRT
        var words = discardProjectTranscript ? [] : (project.transcriptWords ?? [])
        var transcriptionWasGenerated = false
        let transcriptionLocale = cached?.transcriptionLocale
        let cachedSceneCuts = cached?.sceneCuts ?? []
        let transcriptionSources = project.transcriptionSources

        progress(AnalysisProgress(stage: .preparing, message: "Verificando vídeo e índice anterior…", fraction: 0.05))

        if transcriptionSources.count < sourceClips.count {
            warnings.append("Alguns clipes da sequência não foram encontrados e ficaram fora da análise.")
        }
        if transcriptionSources.isEmpty {
            warnings.append("Nenhum clipe da sequência está disponível para transcrição.")
        }

        if let srt = transcriptSRT,
           let cues = try? SubtitleFile.parse(srt) {
            let cueWords = cues.flatMap {
                $0.words.isEmpty ? TranscriptWord.spread($0.text, from: $0.startTime, to: $0.endTime) : $0.words
            }
            let cueText = Self.normalizedTranscriptText(cues.map(\.text).joined(separator: " "))
            let storedText = Self.normalizedTranscriptText(words.map(\.text).joined(separator: " "))
            if words.isEmpty || storedText != cueText {
                words = cueWords
            }
        }

        if words.isEmpty {
            progress(AnalysisProgress(
                stage: .transcribing,
                message: transcriptionSources.count > 1 ? "Transcrevendo \(transcriptionSources.count) vídeos no dispositivo…" : "Transcrevendo no dispositivo…",
                fraction: 0.15
            ))
            do {
                let result = try await transcription.transcribeVideoSequence(
                    transcriptionSources,
                    localeIdentifier: request.localeIdentifier,
                    allowServer: request.allowServerTranscription,
                    contextualStrings: project.transcriptionVocabulary ?? [],
                    progress: { p in
                        progress(AnalysisProgress(
                            stage: .transcribing,
                            message: p.message,
                            fraction: 0.15 + p.fraction * 0.35
                        ))
                    }
                )
                let cues = result.cues
                transcriptSRT = SubtitleFile.srt(from: cues)
                words = cues.flatMap(\.words)
                if words.isEmpty {
                    words = cues.flatMap { TranscriptWord.spread($0.text, from: $0.startTime, to: $0.endTime) }
                }
                warnings.append(contentsOf: result.skippedClips.map { "Transcrição pulada em \($0)" })
                warnings.append(contentsOf: result.warnings)
                transcriptionWasGenerated = true
            } catch {
                transcriptSRT = discardProjectTranscript ? nil : project.transcriptSRT
                warnings.append("Transcrição indisponível: \(Self.describe(error))")
            }
        } else {
            progress(AnalysisProgress(stage: .transcribing, message: "Transcrição reutilizada.", fraction: 0.35))
        }

        if transcriptSRT == nil, !words.isEmpty {
            transcriptSRT = SubtitleFile.srt(from: Self.cues(from: words))
        }

        var sceneCuts = sourceChanged ? [] : (project.sceneCuts ?? cachedSceneCuts)
        if request.analyzeScenes && sceneCuts.isEmpty {
            var detected: [Double] = []
            let clipCount = sourceClips.count
            for (index, clip) in sourceClips.enumerated() {
                progress(AnalysisProgress(
                    stage: .detectingScenes,
                    message: clipCount > 1 ? "Detectando cortes visuais · vídeo \(index + 1) de \(clipCount)" : "Detectando cortes visuais…",
                    fraction: 0.55 + 0.25 * Double(index) / Double(max(1, clipCount))
                ))
                guard let url = project.sourceURL(for: clip) else { continue }
                let cuts = await visualAnalysis.detectSceneCuts(
                    in: url,
                    startTime: clip.startTime,
                    duration: clip.duration
                )
                detected.append(contentsOf: cuts.map { clip.sequenceStartTime + $0 })
            }
            sceneCuts = detected.sorted()
            if sceneCuts.isEmpty {
                warnings.append("Nenhum corte visual forte foi encontrado.")
            }
        } else {
            progress(AnalysisProgress(stage: .detectingScenes, message: "Cenas reutilizadas ou desativadas.", fraction: 0.65))
        }

        progress(AnalysisProgress(stage: .indexing, message: "Detectando pausas, vícios e assuntos…", fraction: 0.82))

        let silences = Self.silenceRanges(words: words, duration: sourceDuration)
        let fillers = Self.fillerMatches(words: words)
        let topics = Self.topicBoundaries(words: words, sceneCuts: sceneCuts)
        let stats = Self.audioStats(words: words, silences: silences, fillers: fillers, duration: sourceDuration)

        var resolvedTranscriptionLocale: String? = nil
        if transcriptSRT != nil {
            if transcriptionWasGenerated {
                resolvedTranscriptionLocale = request.localeIdentifier
            } else if transcriptSRT == cached?.transcriptSRT {
                resolvedTranscriptionLocale = transcriptionLocale
            }
        }

        var analysis = ContentAnalysis(
            projectID: project.id,
            sourceSignature: signature,
            duration: sourceDuration,
            transcriptSRT: transcriptSRT,
            transcriptWords: words,
            sceneCuts: sceneCuts,
            silenceRanges: silences,
            fillerMatches: fillers,
            topicBoundaries: topics,
            audioStats: stats,
            transcriptionLocale: resolvedTranscriptionLocale,
            warnings: warnings
        )

        do {
            try await store.save(analysis)
        } catch {
            analysis.warnings.append("O índice não pôde ser salvo para reutilização: \(Self.describe(error))")
        }

        progress(AnalysisProgress(stage: .completed, message: "Análise concluída.", fraction: 1))
        return analysis
    }

    /// Project transcript/scene data can be edited after analysis; a cache that no
    /// longer matches it must be rebuilt instead of overwriting the user's edits.
    private func reusable(_ analysis: ContentAnalysis, for project: Project) -> Bool {
        if analysis.transcriptWords.isEmpty,
           analysis.warnings.contains(where: { $0.hasPrefix("Transcrição indisponível") }) { return false }
        if let savedDuration = project.transcriptSequenceDuration,
           abs(savedDuration - analysis.duration) > 0.5 { return false }
        if project.transcriptSequenceDuration == nil,
           project.sourceClips.count > 1,
           project.transcriptSRT != nil || project.transcriptWords != nil { return false }
        if let transcript = project.transcriptSRT, transcript != analysis.transcriptSRT { return false }
        if let words = project.transcriptWords, words != analysis.transcriptWords { return false }
        if let sceneCuts = project.sceneCuts, sceneCuts != analysis.sceneCuts { return false }
        return true
    }

    nonisolated func sourceSignature(for project: Project) -> String {
        project.sourceClips.map { clip in
            let url = project.sourceURL(for: clip)
            let attrs = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
            let size = attrs?[.size] as? Int64 ?? -1
            let modified = attrs?[.modificationDate] as? Date ?? .distantPast
            let name = url?.lastPathComponent ?? clip.assetID?.uuidString ?? clip.sourceType.rawValue
            return "\(name)|\(Int(clip.sequenceStartTime * 1000))|\(Int(clip.startTime * 1000))|\(Int(clip.endTime * 1000))|\(size)|\(modified.timeIntervalSince1970)"
        }.joined(separator: "||")
    }

    private static func normalizedTranscriptText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func cues(from words: [TranscriptWord]) -> [TranscriptCue] {
        let sorted = words.sorted { $0.start < $1.start }
        var cues: [TranscriptCue] = []
        var current: [TranscriptWord] = []
        for word in sorted {
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
            text: words.map(\.text).joined(separator: " "),
            words: words
        )
    }

    private static func silenceRanges(words: [TranscriptWord], duration: Double) -> [AnalysisRange] {
        let sorted = words.sorted { $0.start < $1.start }
        var ranges: [AnalysisRange] = []
        if let first = sorted.first, first.start >= 0.8 {
            ranges.append(AnalysisRange(start: 0, end: first.start))
        }
        for index in sorted.indices.dropLast() {
            let next = sorted[index + 1]
            let gap = next.start - sorted[index].end
            if gap >= 0.8 {
                ranges.append(AnalysisRange(start: sorted[index].end, end: next.start))
            }
        }
        if let last = sorted.last, duration - last.end >= 0.8 {
            ranges.append(AnalysisRange(start: last.end, end: duration))
        }
        return ranges
    }

    private static func fillerMatches(words: [TranscriptWord]) -> [TranscriptWord] {
        words.filter { fillerTokens.contains(normalized($0.text)) }
    }

    private static func topicBoundaries(words: [TranscriptWord], sceneCuts: [Double]) -> [TopicBoundary] {
        let sorted = words.sorted { $0.start < $1.start }
        let window = 15
        var result: [TopicBoundary] = []
        for index in sorted.indices.dropFirst() {
            let gap = sorted[index].start - sorted[index - 1].end
            guard gap >= 1.0 else { continue }
            let before = Set(sorted[max(0, index - window)..<index].map { normalized($0.text) }.filter { !$0.isEmpty })
            let after = Set(sorted[index..<min(sorted.count, index + window)].map { normalized($0.text) }.filter { !$0.isEmpty })
            let union = before.union(after).count
            guard union > 0 else { continue }
            let distance = 1 - Double(before.intersection(after).count) / Double(union)
            let sceneBonus = sceneCuts.contains { abs($0 - sorted[index].start) <= 2 } ? 0.08 : 0
            let score = min(1, distance + sceneBonus)
            if distance >= 0.5 {
                result.append(TopicBoundary(
                    time: sorted[index].start,
                    score: score,
                    label: "Pausa de \(String(format: "%.1f", gap))s + mudança de vocabulário"
                ))
            }
        }
        return result
    }

    private static func audioStats(
        words: [TranscriptWord],
        silences: [AnalysisRange],
        fillers: [TranscriptWord],
        duration: Double
    ) -> ContentAudioStats {
        let speechSeconds = words.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let silenceSeconds = silences.reduce(0) { $0 + $1.duration }
        return ContentAudioStats(
            speechCoverage: duration > 0 ? min(1, speechSeconds / duration) : 0,
            averageWordsPerSecond: speechSeconds > 0 ? Double(words.count) / speechSeconds : 0,
            silenceSeconds: silenceSeconds,
            fillerCount: fillers.count
        )
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static let fillerTokens: Set<String> = [
        "é", "eh", "ehh", "éh", "hum", "hm", "hmm", "humm", "ahn", "ah", "ahh", "uh", "uhm", "um", "né", "tipo", "tá"
    ]
}
