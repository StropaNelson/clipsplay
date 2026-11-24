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
        let minimumEntranceDuration: Double = 0.001
        let typewriterCharacterDuration: Double = 0.05 * Double(element.text.count)
        let entranceDuration: Double
        if element.entrance == .typewriter {
            entranceDuration = max(element.entranceDuration, typewriterCharacterDuration)
        } else {
            entranceDuration = max(element.entranceDuration, minimumEntranceDuration)
        }
        let entranceElapsed: Double = time - element.startTime
        let entranceLinearProgress: Double = clamp(entranceElapsed / entranceDuration)
        let entrance: Double = easeOutCubic(entranceLinearProgress)
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
            let countDuration: Double = max(element.countDuration, 0.001)
            let countElapsed: Double = time - element.startTime
            let countLinearProgress: Double = clamp(countElapsed / countDuration)
            state.countProgress = easeOutCubic(countLinearProgress)
        }

        if element.exit != .none {
            let remainingTime: Double = element.endTime - time
            let exitDuration: Double = max(element.exitDuration, 0.001)
            let exitLinearProgress: Double = clamp(remainingTime / exitDuration)
            let exit: Double = easeOutCubic(exitLinearProgress)
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
            let minimumEntranceDuration: Double = 0.001
            let typewriterCharacterDuration: Double = 0.05 * Double(element.text.count)
            let entranceDuration: Double
            if element.entrance == .typewriter {
                entranceDuration = max(element.entranceDuration, typewriterCharacterDuration)
            } else {
                entranceDuration = max(element.entranceDuration, minimumEntranceDuration)
            }
            let entranceEnd: Double = element.startTime + entranceDuration
            if time < entranceEnd { return false }
        }
        if element.entrance == .countUp {
            let countDuration: Double = max(element.countDuration, 0.001)
            let countEnd: Double = element.startTime + countDuration
            if time < countEnd { return false }
        }
        if element.exit != .none {
            let exitDuration: Double = max(element.exitDuration, 0.001)
            let exitStart: Double = element.endTime - exitDuration
            if time >= exitStart { return false }
        }
        return true
    }

    static func counterText(_ element: MotionElement, progress: Double) -> String {
        let progressValue: Double = clamp(progress)
        let valueRange: Double = element.counterTo - element.counterFrom
        let valueOffset: Double = valueRange * progressValue
        let value: Double = element.counterFrom + valueOffset
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.numberStyle = .decimal
        let fractionDigits: Int = min(2, max(0, element.decimals))
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        let formattedValue: String = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        let prefixedValue: String = element.prefix + formattedValue
        return prefixedValue + element.suffix
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func easeOutCubic(_ value: Double) -> Double {
        let inverse: Double = 1 - value
        let cubed: Double = pow(inverse, 3)
        return 1 - cubed
    }
}

enum MotionRenderer {
    static func frameRect(_ element: MotionElement, canvasSize: CGSize) -> CGRect {
        let widthFraction: CGFloat = CGFloat(element.widthFraction)
        let heightFraction: CGFloat = CGFloat(element.heightFraction)
        let width: CGFloat = max(1, widthFraction * canvasSize.width)
        let height: CGFloat = max(1, heightFraction * canvasSize.height)
        let centerX: CGFloat = CGFloat(element.centerX) * canvasSize.width
        let centerY: CGFloat = CGFloat(element.centerY) * canvasSize.height
        let originX: CGFloat = centerX - width / 2
        let originY: CGFloat = centerY - height / 2
        return CGRect(
            x: originX,
            y: originY,
            width: width,
            height: height
        )
    }

    static func boundingRect(_ element: MotionElement, canvasSize: CGSize) -> CGRect {
        let frame = frameRect(element, canvasSize: canvasSize)
        let rotationDegrees: CGFloat = CGFloat(element.rotation)
        let radians: CGFloat = rotationDegrees * .pi / 180
        let toOrigin = CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
        let rotate = CGAffineTransform(rotationAngle: radians)
        let toCenter = CGAffineTransform(translationX: frame.midX, y: frame.midY)
        let rotated = frame.applying(toOrigin).applying(rotate).applying(toCenter)
        let strokeFraction: CGFloat = CGFloat(element.strokeWidth)
        let strokeMargin: CGFloat = strokeFraction * canvasSize.height / 2
        let margin: CGFloat = max(2, strokeMargin + 2)
        let movesVertically: Bool = element.entrance == .slideUp || element.exit == .slideUp
        let movement: CGFloat = movesVertically ? canvasSize.height * 0.08 : 0
        let verticalMargin: CGFloat = margin + movement
        let expanded = rotated.insetBy(dx: -margin, dy: -verticalMargin).integral
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        return expanded.intersection(canvasRect).integral
    }

    static func draw(_ element: MotionElement, at time: Double, canvasSize: CGSize, in context: CGContext) {
        let state = MotionMath.state(for: element, at: time)
        guard state.opacity > 0.001 else { return }
        let frame = frameRect(element, canvasSize: canvasSize)
        context.saveGState()
        let combinedOpacity: Double = element.opacity * state.opacity
        let clampedOpacity: Double = min(1, max(0, combinedOpacity))
        context.setAlpha(CGFloat(clampedOpacity))
        let verticalOffset: CGFloat = CGFloat(state.dy) * canvasSize.height
        let centerY: CGFloat = frame.midY + verticalOffset
        context.translateBy(
            x: frame.midX,
            y: centerY
        )
        let rotationDegrees: CGFloat = CGFloat(element.rotation)
        let rotationRadians: CGFloat = rotationDegrees * .pi / 180
        context.rotate(by: rotationRadians)
        let scale: CGFloat = CGFloat(state.scale)
        context.scaleBy(x: scale, y: scale)
        let localWidth: CGFloat = frame.width
        let localHeight: CGFloat = frame.height
        let localOriginX: CGFloat = -localWidth / 2
        let localOriginY: CGFloat = -localHeight / 2
        let localRect = CGRect(x: localOriginX, y: localOriginY, width: localWidth, height: localHeight)
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
        let shortSide: CGFloat = min(rect.width, rect.height)
        let radiusFraction: CGFloat = CGFloat(element.cornerRadius)
        let radius: CGFloat = shortSide * radiusFraction
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
            let strokeFraction: CGFloat = CGFloat(element.strokeWidth)
            let strokeWidth: CGFloat = strokeFraction * canvasSize.height
            context.setLineWidth(max(1, strokeWidth))
            context.setStrokeColor(strokeColor.uiColor.cgColor)
            context.addPath(backgroundPath)
            context.strokePath()
        }
        let isTyping: Bool = element.entrance == .typewriter && state.typedFraction < 1
        let typedCount: Int = Int(Double(text.count) * state.typedFraction)
        let visible: String = isTyping ? String(text.prefix(typedCount)) : text
        guard !visible.isEmpty else { return }
        let heightFraction: CGFloat = CGFloat(max(0.001, element.heightFraction))
        let canvasHeight: CGFloat = max(1, rect.height / heightFraction)
        let fontScale: CGFloat = CGFloat(element.fontScale)
        let scaledFontSize: CGFloat = fontScale * canvasHeight
        let fontSize: CGFloat = max(8, scaledFontSize)
        let font = UIFont.systemFont(ofSize: fontSize, weight: element.isBold ? .bold : .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: visible,
            attributes: [.font: font, .foregroundColor: element.textColor.uiColor, .paragraphStyle: paragraph]
        )
        let horizontalInset: CGFloat = 12
        let availableWidth: CGFloat = max(1, rect.width - horizontalInset)
        let textSize = CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        let textRect = attributed.boundingRect(
            with: textSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let fittedHeight: CGFloat = min(rect.height, textRect.height)
        let fittedY: CGFloat = rect.midY - fittedHeight / 2
        let fitted = CGRect(
            x: rect.minX + 6,
            y: fittedY,
            width: availableWidth,
            height: fittedHeight
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
        let strokeFraction: CGFloat = CGFloat(element.strokeWidth)
        let requestedLineWidth: CGFloat = strokeFraction * canvasSize.height
        let lineWidth: CGFloat = max(1, requestedLineWidth)
        let stroke = (element.strokeColor ?? element.textColor).uiColor.cgColor
        context.saveGState()
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        if element.shape == .line || element.shape == .arrow {
            let clampedProgress: Double = min(1, max(0, state.drawProgress))
            let progress: CGFloat = CGFloat(clampedProgress)
            let start = CGPoint(x: rect.minX, y: rect.midY)
            let progressWidth: CGFloat = rect.width * progress
            let tipX: CGFloat = rect.minX + progressWidth
            let tip = CGPoint(x: tipX, y: rect.midY)
            context.setStrokeColor(stroke)
            context.move(to: start)
            context.addLine(to: tip)
            context.strokePath()
            if element.shape == .arrow, progress > 0 {
                let minimumHead: CGFloat = lineWidth * 3
                let heightHead: CGFloat = rect.height * 0.55
                let widthHead: CGFloat = rect.width * 0.12
                let head: CGFloat = max(minimumHead, min(heightHead, widthHead))
                let headVerticalOffset: CGFloat = head * 0.65
                let upperHeadY: CGFloat = tip.y - headVerticalOffset
                let lowerHeadY: CGFloat = tip.y + headVerticalOffset
                let headStartX: CGFloat = tip.x - head
                context.move(to: CGPoint(x: headStartX, y: upperHeadY))
                context.addLine(to: tip)
                context.addLine(to: CGPoint(x: headStartX, y: lowerHeadY))
                context.strokePath()
            }
            context.restoreGState()
            return
        }
        let fullPath: CGPath
        if element.shape == .circle {
            fullPath = CGPath(ellipseIn: rect, transform: nil)
        } else {
            let shortSide: CGFloat = min(rect.width, rect.height)
            let radiusFraction: CGFloat = CGFloat(element.cornerRadius)
            let radius: CGFloat = shortSide * radiusFraction
            fullPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        if state.drawProgress < 1 {
            let progress: CGFloat = CGFloat(state.drawProgress)
            let clipWidth: CGFloat = rect.width * progress
            let clipRect = CGRect(x: rect.minX, y: rect.minY, width: clipWidth, height: rect.height)
            context.clip(to: clipRect)
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
