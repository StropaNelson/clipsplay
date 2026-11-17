import Foundation

/// Pure geometry/opacity math for burned-in overlays, shared by the compositor
/// and unit-testable without UIKit. Offsets are in Core Image space (y up):
/// a positive `dy` moves the overlay UP on screen.
enum OverlayMath {
    /// Linear ramp in/out at the overlay edges: fade window is 0.2 s, capped at
    /// 25% of the duration (same timing as the old CA visibility keyframes).
    static func visibilityFade(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        let fade = min(0.2 / duration, 0.25) * duration
        guard fade > 0 else { return 1 }
        let alpha = min(elapsed / fade, (duration - elapsed) / fade)
        return min(1, max(0, alpha))
    }

    struct AnimationState {
        var opacity: Double
        /// Vertical offset in CI space (positive = up on screen).
        var dy: Double
        var scale: Double
    }

    /// Combined entrance (0.4 s) + exit (0.35 s) transform for a text overlay,
    /// matching the editor preview timing.
    static func animationState(
        entrance: TextAnimationStyle?,
        exit: TextAnimationStyle?,
        startTime: Double,
        duration: Double,
        time: Double,
        renderHeight: Double
    ) -> AnimationState {
        var state = AnimationState(opacity: 1, dy: 0, scale: 1)
        if let entrance = entrance, entrance != .none {
            let progress = min(1, max(0, (time - startTime) / 0.4))
            applyEntrance(entrance, progress: progress, height: renderHeight, to: &state)
        }
        if let exit = exit, exit != .none {
            let progress = min(1, max(0, (startTime + duration - time) / 0.35))
            applyExit(exit, progress: progress, height: renderHeight, to: &state)
        }
        state.opacity = min(1, max(0, state.opacity))
        return state
    }

    private static func applyEntrance(_ style: TextAnimationStyle, progress: Double,
                                      height: Double, to state: inout AnimationState) {
        let remaining = 1 - progress
        if style != .none { state.opacity *= progress }
        switch style {
        case .fade, .typewriter:
            break
        case .slide:
            state.dy -= remaining * height * 0.15
        case .pop:
            state.scale *= 0.2 + 0.8 * progress
        case .bounce:
            state.dy += remaining * height * 0.25
        case .none:
            break
        }
    }

    private static func applyExit(_ style: TextAnimationStyle, progress: Double,
                                  height: Double, to state: inout AnimationState) {
        let gone = 1 - progress
        if style != .none { state.opacity *= progress }
        switch style {
        case .fade, .typewriter:
            break
        case .slide:
            state.dy -= gone * height * 0.15
        case .pop:
            state.scale *= 1 - 0.8 * gone
        case .bounce:
            state.dy += gone * height * 0.25
        case .none:
            break
        }
    }

    /// Top-left normalized point → Core Image point (bottom-left origin).
    static func ciPoint(x: Double, y: Double, width: Double, height: Double) -> (x: Double, y: Double) {
        (x * width, (1 - y) * height)
    }
}
