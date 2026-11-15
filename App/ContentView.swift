import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()
    
    var body: some View {
        Group {
            if let project = appState.currentProject {
                EditorView(project: project)
            } else {
                HomeView()
                    .environmentObject(appState)
            }
        }
        .onOpenURL { url in
            Task {
                await appState.handleImportedProject(url)
            }
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var currentProject: Project?
    @Published var recentProjects: [ProjectSummary] = []
    
    private let storage = ProjectStorage.shared
    
    init() {
        loadRecentProjects()
    }
    
    func loadRecentProjects() {
        Task {
            do {
                recentProjects = try await storage.listProjects()
            } catch {
                print("Failed to load recent projects: \(error)")
            }
        }
    }
    
    func createNewProject() {
        // Project creation is handled by HomeView -> import video flow
    }
    
    func openProject(_ summary: ProjectSummary) {
        Task {
            do {
                currentProject = try await storage.loadProject(id: summary.id)
            } catch {
                print("Failed to open project: \(error)")
            }
        }
    }
    
    func closeProject() {
        currentProject = nil
    }
    
    func handleImportedProject(_ url: URL) async {
        do {
            currentProject = try await storage.importProject(from: url)
        } catch {
            print("Failed to import project: \(error)")
        }
    }
}