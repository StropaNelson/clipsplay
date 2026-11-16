import Foundation

enum ProjectOperation: String, CaseIterable, Identifiable, Codable {
    case multiply = "Multiplicar conteúdo"
    case podcast = "Editar podcast"
    case episodes = "Criar episódios"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .multiply: return "rectangle.stack.badge.plus"
        case .podcast: return "mic.and.signal.meter"
        case .episodes: return "film.stack"
        }
    }

    var subtitle: String {
        switch self {
        case .multiply: return "Gere formatos, clipes, legendas e variações de uma gravação."
        case .podcast: return "Transcreva e remova silêncios, repetições e trechos indesejados."
        case .episodes: return "Divida uma gravação longa em episódios estruturados."
        }
    }
}
