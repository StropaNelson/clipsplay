import Foundation
import SwiftUI

actor ProjectStorage {
    static let shared = ProjectStorage()
    
    private let projectsDirectory: URL
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        projectsDirectory = docs.appendingPathComponent("ClipStudio_Projects", isDirectory: true)
        try? fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }
    
    func listProjects() async throws -> [ProjectSummary] {
        let files = try fileManager.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var summaries: [ProjectSummary] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let project = try decoder.decode(Project.self, from: data)
                let attrs = try fileManager.attributesOfItem(atPath: file.path)
                let size = attrs[.size] as? Int64 ?? 0
                let modDate = attrs[.modificationDate] as? Date ?? Date()
                summaries.append(ProjectSummary(
                    id: project.id,
                    name: project.name,
                    episodeCount: project.episodes.count,
                    sourceDuration: project.sourceVideoDuration,
                    updatedAt: modDate,
                    fileSize: size,
                    fileURL: file
                ))
            } catch {
                print("Failed to decode project \(file): \(error)")
            }
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    func loadProject(id: UUID) async throws -> Project {
        let file = projectsDirectory.appendingPathComponent("\(id.uuidString).json")
        do {
            let data = try Data(contentsOf: file)
            return try decoder.decode(Project.self, from: data)
        } catch {
            // Recover from the last good copy if the main file is missing or damaged.
            guard let backup = try? Data(contentsOf: backupURL(for: id)),
                  let project = try? decoder.decode(Project.self, from: backup) else { throw error }
            return project
        }
    }

    private func backupURL(for id: UUID) -> URL {
        projectsDirectory.appendingPathComponent("\(id.uuidString).backup")
    }
    
    func loadProject(url: URL) async throws -> Project {
        let data = try Data(contentsOf: url)
        return try decoder.decode(Project.self, from: data)
    }
    
    func saveProject(_ project: Project) async throws {
        var project = project
        project.updateTimestamp()
        let file = projectsDirectory.appendingPathComponent("\(project.id.uuidString).json")
        let data = try encoder.encode(project)
        if let previous = try? Data(contentsOf: file),
           (try? decoder.decode(Project.self, from: previous)) != nil {
            try? previous.write(to: backupURL(for: project.id), options: .atomic)
        }
        try data.write(to: file, options: .atomic)
    }
    
    func createProject(_ project: Project) async throws {
        let file = projectsDirectory.appendingPathComponent("\(project.id.uuidString).json")
        let data = try encoder.encode(project)
        try data.write(to: file, options: .atomic)
    }
    
    func duplicateProject(_ project: Project, newName: String) async throws -> Project {
        var copy = project
        copy.id = UUID()
        copy.name = newName
        copy.createdAt = Date()
        copy.updatedAt = Date()
        try await saveProject(copy)
        return copy
    }
    
    func deleteProject(id: UUID) async throws {
        let file = projectsDirectory.appendingPathComponent("\(id.uuidString).json")
        try fileManager.removeItem(at: file)
        try? fileManager.removeItem(at: backupURL(for: id))
    }
    
    func exportProject(_ project: Project, to url: URL) async throws {
        var project = project
        project.updateTimestamp()
        let data = try encoder.encode(project)
        try data.write(to: url, options: .atomic)
    }
    
    func importProject(from url: URL) async throws -> Project {
        let project = try await loadProject(url: url)
        var copy = project
        copy.id = UUID()
        copy.createdAt = Date()
        copy.updatedAt = Date()
        try await saveProject(copy)
        return copy
    }
}

struct ProjectSummary: Identifiable {
    let id: UUID
    let name: String
    let episodeCount: Int
    let sourceDuration: Double
    let updatedAt: Date
    let fileSize: Int64
    let fileURL: URL
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    var formattedDuration: String {
        let h = Int(sourceDuration) / 3600
        let m = (Int(sourceDuration) % 3600) / 60
        let s = Int(sourceDuration) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

extension ProjectStorage {
    func getExportDirectory() -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportDir = docs.appendingPathComponent("ClipStudio_Exportados", isDirectory: true)
        try? fileManager.createDirectory(at: exportDir, withIntermediateDirectories: true)
        return exportDir
    }
    
    func getThumbnailsDirectory() -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let thumbDir = docs.appendingPathComponent("ClipStudio_Thumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        return thumbDir
    }
    
    func getMediaAssetsDirectory() -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mediaDir = docs.appendingPathComponent("ClipStudio_Media", isDirectory: true)
        try? fileManager.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        return mediaDir
    }
}