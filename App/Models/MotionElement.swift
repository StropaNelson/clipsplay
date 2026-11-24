import Foundation

enum MotionKind: String, Codable, CaseIterable, Identifiable {
    case text = "Texto"
    case shape = "Forma"
    case counter = "Contador"

    var id: String { rawValue }

    var entranceOptions: [MotionAnimation] {
        switch self {
        case .text: return [.none, .fade, .slideUp, .scale, .typewriter]
        case .shape: return [.none, .fade, .slideUp, .scale, .draw]
        case .counter: return [.none, .fade, .slideUp, .scale, .countUp]
        }
    }

    var exitOptions: [MotionAnimation] { [.none, .fade, .slideUp, .scale] }
}

enum MotionShape: String, Codable, CaseIterable, Identifiable {
    case roundedRect = "Retângulo"
    case circle = "Círculo"
    case line = "Linha"
    case arrow = "Seta"

    var id: String { rawValue }
}

enum MotionAnimation: String, Codable, CaseIterable, Identifiable {
    case none = "Nenhuma"
    case fade = "Aparecer"
    case slideUp = "Deslizar"
    case scale = "Zoom"
    case draw = "Desenhar"
    case countUp = "Contagem"
    case typewriter = "Digitação"

    var id: String { rawValue }
}

struct MotionElement: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: MotionKind
    var startTime: Double
    var duration: Double
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var widthFraction: Double = 0.45
    var heightFraction: Double = 0.18
    var rotation: Double = 0
    var opacity: Double = 1
    var entrance: MotionAnimation = .fade
    var exit: MotionAnimation = .fade
    var entranceDuration: Double = 0.5
    var exitDuration: Double = 0.4
    var text: String = "Título"
    var fontScale: Double = 0.06
    var isBold: Bool = true
    var textColor: RGBAColor = .white
    var fillColor: RGBAColor?
    var strokeColor: RGBAColor?
    var strokeWidth: Double = 0.006
    var cornerRadius: Double = 0.16
    var shape: MotionShape = .roundedRect
    var counterFrom: Double = 0
    var counterTo: Double = 100
    var prefix: String = ""
    var suffix: String = " %"
    var decimals: Int = 0
    var countDuration: Double = 1.5

    var endTime: Double { startTime + duration }

    func isVisible(at time: Double) -> Bool {
        time >= startTime && time < endTime
    }

    static func preset(
        _ kind: MotionKind,
        shape: MotionShape = .roundedRect,
        start: Double,
        duration: Double
    ) -> MotionElement {
        var element = MotionElement(kind: kind, startTime: start, duration: duration)
        switch kind {
        case .text:
            element.text = "Seu título"
            element.widthFraction = 0.72
            element.heightFraction = 0.22
            element.centerY = 0.5
            element.fillColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.62)
        case .counter:
            element.text = ""
            element.widthFraction = 0.62
            element.heightFraction = 0.24
            element.centerY = 0.5
            element.fontScale = 0.12
            element.textColor = RGBAColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)
        case .shape:
            element.shape = shape
            let isLine: Bool = shape == .line || shape == .arrow
            let width: Double = isLine ? 0.58 : 0.36
            let height: Double = isLine ? 0.08 : 0.24
            element.widthFraction = width
            element.heightFraction = height
            let fillColor: RGBAColor? = shape == .roundedRect
                ? RGBAColor(red: 0.16, green: 0.62, blue: 1, alpha: 0.85)
                : nil
            element.fillColor = fillColor
            let strokeColor: RGBAColor = isLine
                ? .white
                : RGBAColor(red: 0.16, green: 0.62, blue: 1, alpha: 1)
            element.strokeColor = strokeColor
        }
        if kind == .shape {
            element.entrance = .draw
            element.exit = .fade
        } else if kind == .counter {
            element.entrance = .countUp
            element.exit = .fade
        } else {
            element.entrance = .fade
            element.exit = .fade
        }
        return element
    }
}
