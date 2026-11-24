import Foundation
import CoreGraphics
import UIKit

struct MotionState {
    var opacity: Double = 1
    var dy: Double = 0
    var scale: Double = 1
    var drawProgress: Double = 1
    var typedFraction: Double = 1
    var countProgress: Double = 1
}

enum MotionMath {
    static func state(for element: MotionElement, at time: Double) -> MotionState {
        var state = MotionState()
        let entranceDuration = element.entrance == .typewriter
            ? max(element.entranceDuration, 0.05 * Double(element.text.count))
            : max(element.entranceDuration, 0.001)
        let entrance = easeOutCubic(clamp((time - element.startTime) / entranceDuration))
        switch element.entrance {
        case .none, .countUp: break
        case .fade:
            state.opacity = entrance
        case .slideUp:
            state.opacity = entrance
            state.dy = (1 - entrance) * 0.08
        case .scale:
            state.opacity = entrance
            state.scale = 0.3 + 0.7 * entrance
        case .draw:
            state.drawProgress = entrance
        case .typewriter:
            state.typedFraction = entrance
        }

        if element.entrance == .countUp {
            state.countProgress = easeOutCubic(clamp((time - element.startTime) / max(element.countDuration, 0.001)))
        }

        if element.exit != .none {
            let exit = easeOutCubic(clamp((element.endTime - time) / max(element.exitDuration, 0.001)))
            switch element.exit {
            case .none, .draw, .countUp, .typewriter: break
            case .fade:
                state.opacity *= exit
            case .slideUp:
                state.opacity *= exit
                state.dy += (1 - exit) * 0.08
            case .scale:
                state.opacity *= exit
                state.scale *= 0.3 + 0.7 * exit
            }
        }
        return state
    }

    static func isStatic(_ element: MotionElement, time: Double) -> Bool {
        guard time >= element.startTime, time < element.endTime else { return false }
        if element.entrance != .none {
            let duration = element.entrance == .typewriter
                ? max(element.entranceDuration, 0.05 * Double(element.text.count))
                : max(element.entranceDuration, 0.001)
            if time < element.startTime + duration { return false }
        }
        if element.entrance == .countUp,
           time < element.startTime + max(element.countDuration, 0.001) {
            return false
        }
        if element.exit != .none,
           time >= element.endTime - max(element.exitDuration, 0.001) {
            return false
        }
        return true
    }

    static func counterText(_ element: MotionElement, progress: Double) -> String {
        let value = element.counterFrom + (element.counterTo - element.counterFrom) * clamp(progress)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = min(2, max(0, element.decimals))
        formatter.maximumFractionDigits = min(2, max(0, element.decimals))
        return element.prefix + (formatter.string(from: NSNumber(value: value)) ?? "\(value)") + element.suffix
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func easeOutCubic(_ value: Double) -> Double {
        1 - pow(1 - value, 3)
    }
}

enum MotionRenderer {
    static func frameRect(_ element: MotionElement, canvasSize: CGSize) -> CGRect {
        let width = max(1, CGFloat(element.widthFraction) * canvasSize.width)
        let height = max(1, CGFloat(element.heightFraction) * canvasSize.height)
        return CGRect(
            x: CGFloat(element.centerX) * canvasSize.width - width / 2,
            y: CGFloat(element.centerY) * canvasSize.height - height / 2,
            width: width,
            height: height
        )
    }

    static func boundingRect(_ element: MotionElement, canvasSize: CGSize) -> CGRect {
        let frame = frameRect(element, canvasSize: canvasSize)
        let radians = CGFloat(element.rotation * .pi / 180)
        let rotated = frame.applying(CGAffineTransform(translationX: -frame.midX, y: -frame.midY))
            .applying(CGAffineTransform(rotationAngle: radians))
            .applying(CGAffineTransform(translationX: frame.midX, y: frame.midY))
        let strokeMargin = CGFloat(element.strokeWidth) * canvasSize.height / 2
        let margin = max(2, strokeMargin + 2)
        let movement = element.entrance == .slideUp || element.exit == .slideUp
            ? canvasSize.height * 0.08
            : 0
        let expanded = rotated.insetBy(dx: -margin, dy: -margin - movement).integral
        return expanded.intersection(CGRect(origin: .zero, size: canvasSize)).integral
    }

    static func draw(_ element: MotionElement, at time: Double, canvasSize: CGSize, in context: CGContext) {
        let state = MotionMath.state(for: element, at: time)
        guard state.opacity > 0.001 else { return }
        let frame = frameRect(element, canvasSize: canvasSize)
        context.saveGState()
        context.setAlpha(CGFloat(min(1, max(0, element.opacity * state.opacity))))
        context.translateBy(
            x: frame.midX,
            y: frame.midY + CGFloat(state.dy) * canvasSize.height
        )
        context.rotate(by: CGFloat(element.rotation * .pi / 180))
        context.scaleBy(x: CGFloat(state.scale), y: CGFloat(state.scale))
        let localRect = CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height)
        switch element.kind {
        case .text:
            drawText(element.text, element: element, state: state, rect: localRect, canvasSize: canvasSize, context: context)
        case .counter:
            drawText(
                MotionMath.counterText(element, progress: state.countProgress),
                element: element,
                state: state,
                rect: localRect,
                canvasSize: canvasSize,
                context: context
            )
        case .shape:
            drawShape(element, state: state, rect: localRect, canvasSize: canvasSize, context: context)
        }
        context.restoreGState()
    }

    private static func drawText(
        _ text: String,
        element: MotionElement,
        state: MotionState,
        rect: CGRect,
        canvasSize: CGSize,
        context: CGContext
    ) {
        let radius = min(rect.width, rect.height) * CGFloat(element.cornerRadius)
        let backgroundPath = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        if let fillColor = element.fillColor {
            context.setFillColor(fillColor.uiColor.cgColor)
            context.addPath(backgroundPath)
            context.fillPath()
        }
        if let strokeColor = element.strokeColor {
            context.setLineWidth(max(1, CGFloat(element.strokeWidth) * canvasSize.height))
            context.setStrokeColor(strokeColor.uiColor.cgColor)
            context.addPath(backgroundPath)
            context.strokePath()
        }
        let visible = element.entrance == .typewriter && state.typedFraction < 1
            ? String(text.prefix(Int(Double(text.count) * state.typedFraction)))
            : text
        guard !visible.isEmpty else { return }
        let fontSize = max(
            8,
            CGFloat(element.fontScale) * max(1, rect.height / CGFloat(max(0.001, element.heightFraction)))
        )
        let font = UIFont.systemFont(ofSize: fontSize, weight: element.isBold ? .bold : .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: visible,
            attributes: [.font: font, .foregroundColor: element.textColor.uiColor, .paragraphStyle: paragraph]
        )
        let textRect = attributed.boundingRect(
            with: CGSize(width: max(1, rect.width - 12), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let fitted = CGRect(
            x: rect.minX + 6,
            y: rect.midY - min(rect.height, textRect.height) / 2,
            width: max(1, rect.width - 12),
            height: min(rect.height, textRect.height)
        )
        UIGraphicsPushContext(context)
        attributed.draw(
            with: fitted,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        UIGraphicsPopContext()
    }

    private static func drawShape(
        _ element: MotionElement,
        state: MotionState,
        rect: CGRect,
        canvasSize: CGSize,
        context: CGContext
    ) {
        let lineWidth = max(1, CGFloat(element.strokeWidth) * canvasSize.height)
        let stroke = (element.strokeColor ?? element.textColor).uiColor.cgColor
        context.saveGState()
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        if element.shape == .line || element.shape == .arrow {
            let progress = CGFloat(min(1, max(0, state.drawProgress)))
            let start = CGPoint(x: rect.minX, y: rect.midY)
            let tip = CGPoint(x: rect.minX + rect.width * progress, y: rect.midY)
            context.setStrokeColor(stroke)
            context.move(to: start)
            context.addLine(to: tip)
            context.strokePath()
            if element.shape == .arrow, progress > 0 {
                let head = max(lineWidth * 3, min(rect.height * 0.55, rect.width * 0.12))
                context.move(to: CGPoint(x: tip.x - head, y: tip.y - head * 0.65))
                context.addLine(to: tip)
                context.addLine(to: CGPoint(x: tip.x - head, y: tip.y + head * 0.65))
                context.strokePath()
            }
            context.restoreGState()
            return
        }
        let fullPath: CGPath
        if element.shape == .circle {
            fullPath = CGPath(ellipseIn: rect, transform: nil)
        } else {
            let radius = min(rect.width, rect.height) * CGFloat(element.cornerRadius)
            fullPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        if state.drawProgress < 1 {
            context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(state.drawProgress), height: rect.height))
        }
        if let fillColor = element.fillColor {
            context.addPath(fullPath)
            context.setFillColor(fillColor.uiColor.cgColor)
            context.fillPath()
        }
        if let strokeColor = element.strokeColor {
            context.addPath(fullPath)
            context.setStrokeColor(strokeColor.uiColor.cgColor)
            context.strokePath()
        }
        context.restoreGState()
    }
}
