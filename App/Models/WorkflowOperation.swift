import Foundation

enum ProjectOperation: String, CaseIterable, Identifiable, Codable {
    case multiply = "Multiplicar conteúdo"
    case speechEdit = "Autoedição por fala"
    case podcast = "Editar podcast"
    case episodes = "Criar episódios"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .multiply: return "rectangle.stack.badge.plus"
        case .speechEdit: return "text.badge.minus"
        case .podcast: return "mic.and.signal.meter"
        case .episodes: return "film.stack"
        }
    }

    var subtitle: String {
        switch self {
        case .multiply: return "Encontre os melhores momentos e gere versões para cada plataforma."
        case .speechEdit: return "Transcreva e corte pausas ou trechos no clipe inteiro, sem gerar saídas."
        case .podcast: return "Transcreva e remova silêncios, repetições e trechos indesejados."
        case .episodes: return "Divida em partes sequenciais com abertura, resumo e fechamento."
        }
    }
}
