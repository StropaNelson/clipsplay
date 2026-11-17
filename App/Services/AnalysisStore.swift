import Foundation

/// Persists the reusable analysis index outside Project.json so large indexes
/// can be regenerated without rewriting timeline edits.
actor AnalysisStore {
    static let shared = AnalysisStore()

    private let fileManager = FileManager.default
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("ClipStudio_Analysis", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(projectID: UUID) -> ContentAnalysis? {
        let url = fileURL(projectID: projectID)
        guard let data = try? Data(contentsOf: url),
              let analysis = try? decoder.decode(ContentAnalysis.self, from: data),
              analysis.projectID == projectID else { return nil }
        return analysis
    }

    func load(projectID: UUID, sourceSignature: String) -> ContentAnalysis? {
        guard let analysis = load(projectID: projectID),
              analysis.sourceSignature == sourceSignature else { return nil }
        return analysis
    }

    func save(_ analysis: ContentAnalysis) throws {
        let url = fileURL(projectID: analysis.projectID)
        let data = try encoder.encode(analysis)
        try data.write(to: url, options: .atomic)
    }

    func invalidate(projectID: UUID) {
        try? fileManager.removeItem(at: fileURL(projectID: projectID))
    }

    private func fileURL(projectID: UUID) -> URL {
        directory.appendingPathComponent("\(projectID.uuidString).analysis.json")
    }
}
