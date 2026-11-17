import Foundation

/// Reusable, on-device index built once for a source video. It is persisted
/// separately so project edits do not force the media to be analyzed again.
struct ContentAnalysis: Codable, Identifiable {
    var id: UUID
    var version: Int
    var projectID: UUID
    var sourceSignature: String
    var createdAt: Date
    var duration: Double
    var transcriptSRT: String?
    var transcriptWords: [TranscriptWord]
    var sceneCuts: [Double]
    var silenceRanges: [AnalysisRange]
    var fillerMatches: [TranscriptWord]
    var topicBoundaries: [TopicBoundary]
    var audioStats: ContentAudioStats
    var personSamples: [PersonSample]
    var transcriptionLocale: String?
    /// Normalized loudness profile of the sequence at 0.5 s intervals (optional index data).
    var audioEnergy: [Float]?
    var warnings: [String]

    init(
        id: UUID = UUID(),
        version: Int = 1,
        projectID: UUID,
        sourceSignature: String,
        duration: Double,
        transcriptSRT: String? = nil,
        transcriptWords: [TranscriptWord] = [],
        sceneCuts: [Double] = [],
        silenceRanges: [AnalysisRange] = [],
        fillerMatches: [TranscriptWord] = [],
        topicBoundaries: [TopicBoundary] = [],
        audioStats: ContentAudioStats = ContentAudioStats(),
        personSamples: [PersonSample] = [],
        transcriptionLocale: String? = nil,
        audioEnergy: [Float]? = nil,
        warnings: [String] = []
    ) {
        self.id = id
        self.version = version
        self.projectID = projectID
        self.sourceSignature = sourceSignature
        self.createdAt = Date()
        self.duration = duration
        self.transcriptSRT = transcriptSRT
        self.transcriptWords = transcriptWords
        self.sceneCuts = sceneCuts
        self.silenceRanges = silenceRanges
        self.fillerMatches = fillerMatches
        self.topicBoundaries = topicBoundaries
        self.audioStats = audioStats
        self.personSamples = personSamples
        self.transcriptionLocale = transcriptionLocale
        self.audioEnergy = audioEnergy
        self.warnings = warnings
    }
}

struct AnalysisRange: Codable, Hashable {
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
    var closedRange: ClosedRange<Double> { start...end }
}

struct TopicBoundary: Codable, Hashable {
    var time: Double
    var score: Double
    var label: String
}

struct ContentAudioStats: Codable, Hashable {
    var speechCoverage: Double = 0
    var averageWordsPerSecond: Double = 0
    var silenceSeconds: Double = 0
    var fillerCount: Int = 0
}

/// Placeholder for a later local person-tracking pass; persisted now so the
/// analysis format can evolve without changing its envelope again.
struct PersonSample: Codable, Hashable {
    var time: Double
    var centerX: Double
    var centerY: Double
    var confidence: Double
}
