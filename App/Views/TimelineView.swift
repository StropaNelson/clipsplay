import SwiftUI
import UniformTypeIdentifiers
import AVKit
import AVFoundation
import CoreMedia
import UIKit

extension TrackType {
    var color: Color {
        switch self {
        case .intro: return Color(red: 0.62, green: 0.40, blue: 1.0)
        case .recap: return Color(red: 1.0, green: 0.60, blue: 0.20)
        case .main: return Color(red: 0.16, green: 0.62, blue: 1.0)
        case .outro: return Color(red: 0.20, green: 0.80, blue: 0.50)
        case .audio: return .pink
        case .overlay: return .cyan
        }
    }

    var shortLabel: String {
        switch self {
        case .intro: return "INTRO"
        case .recap: return "RECAP"
        case .main: return "PRINCIPAL"
        case .outro: return "FINAL"
        case .audio: return "ÁUDIO"
        case .overlay: return "TEXTO"
        }
    }

    var icon: String {
        switch self {
        case .intro: return "play.rectangle.on.rectangle"
        case .recap: return "arrow.counterclockwise"
        case .main: return "film"
        case .outro: return "flag.checkered"
        case .audio: return "music.note"
        case .overlay: return "textformat"
        }
    }
}

/// Storyline timeline: ruler, video lane with filmstrip clips, text and audio lanes, playhead and zoom.
struct TimelineView: View {
    let segments: [TimelineSegment]
    let overlays: [TextOverlay]
    let audioClips: [AudioClip]
    let mediaOverlays: [MediaOverlay]
    let markers: [Double]
    let totalDuration: Double
    let currentTime: Double
    let selectedID: UUID?
    let canAddIntro: Bool
    let canAddOutro: Bool
    let sourceURL: (TimelineSegment) -> URL?
    let onSeek: (Double) -> Void
    let onSelect: (UUID?) -> Void
    let onAddIntro: () -> Void
    let onAddOutro: () -> Void
    let onAddText: () -> Void
    let onAddAudio: () -> Void
    let onTransitionTap: (TimelineSegment) -> Void
    let maxSourceTime: (TimelineSegment) -> Double
    let audioURL: (AudioClip) -> URL?
    let audioDuration: (AudioClip) -> Double
    let onTrimSegment: (TimelineSegment, Double, Double) -> Void
    let onMoveOverlay: (UUID, Double, Double) -> Void
    let onMoveAudio: (AudioClip) -> Void
    let onAddOverlay: () -> Void
    let onMoveMediaOverlay: (UUID, Double, Double, Double) -> Void
    let onDropAsset: (UUID, TrackType, Double) -> Void
    let onReorderMain: (UUID, Double) -> Void

    private struct LaneDrag {
        let id: UUID
        let move: Double
        let left: Double
        let right: Double
    }

    @State private var pixelsPerSecond: CGFloat = 20
    @State private var pinchBase: CGFloat?
    @State private var didFit = false
    @State private var laneDrag: LaneDrag?
    @State private var reorderDrag: (id: UUID, offset: CGFloat)?

    private let headerWidth: CGFloat = 64
    private let leadingInset: CGFloat = 76
    private let trailingInset: CGFloat = 140
    private let rulerHeight: CGFloat = 24
    private let clipHeight: CGFloat = 56
    private let laneHeight: CGFloat = 30
    private let laneSpacing: CGFloat = 6
    private let minPPS: CGFloat = 4
    private let maxPPS: CGFloat = 240

    private var safeDuration: Double { max(totalDuration, 0.1) }

    private var videoRows: [[TimelineSegment]] {
        var rows: [[TimelineSegment]] = []
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            var rowIndex = 0
            while rowIndex < rows.count && rows[rowIndex].contains(where: { overlapping($0, segment) }) {
                rowIndex += 1
            }
            if rowIndex == rows.count {
                rows.append([segment])
            } else {
                rows[rowIndex].append(segment)
            }
        }
        return rows.isEmpty ? [[]] : rows
    }

    private func overlapping(_ first: TimelineSegment, _ second: TimelineSegment) -> Bool {
        first.startTime < second.endTime - 0.01 && second.startTime < first.endTime - 0.01
    }

    private var firstVideoSegmentID: UUID? {
        segments.min { $0.startTime < $1.startTime }?.id
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                scrubber
                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        trackHeaders
                        ScrollView(.horizontal, showsIndicators: false) {
                            timelineContent
                        }
                        .simultaneousGesture(pinchGesture)
                    }
                }
                zoomBar(width: geometry.size.width)
            }
            .onAppear {
                guard !didFit else { return }
                didFit = true
                fit(width: geometry.size.width)
            }
            .onChange(of: totalDuration) { _ in
                fit(width: geometry.size.width)
            }
        }
        .background(EditorTheme.timelineBackground)
    }

    private var trackHeaders: some View {
        VStack(spacing: laneSpacing) {
            Color.clear.frame(height: rulerHeight + 4)
            ForEach(videoRows.indices, id: \.self) { row in
                header(
                    icon: "film",
                    title: videoRows.count == 1 ? "Vídeo" : "Vídeo \(row + 1)",
                    height: clipHeight
                )
            }
            header(icon: "waveform", title: "Som", height: laneHeight)
            header(icon: "rectangle.on.rectangle", title: "PiP", height: laneHeight, action: onAddOverlay)
            header(icon: "textformat", title: "Texto", height: laneHeight, action: onAddText)
            ForEach(audioRows.indices, id: \.self) { row in
                let kind = audioRows[row].kind
                let isSingleEmpty = audioRows.count == 1 && audioRows[row].clips.isEmpty
                header(
                    icon: kind.icon,
                    title: audioRows[row].index == 0 ? (isSingleEmpty ? "Áudio" : kind.rawValue) : "",
                    height: laneHeight,
                    action: audioRows[row].index == 0 ? onAddAudio : nil
                )
            }
        }
        .padding(.leading, 6)
        .frame(width: headerWidth + 6)
    }

    @ViewBuilder
    private func header(icon: String, title: String, height: CGFloat, action: (() -> Void)? = nil) -> some View {
        let content = HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .medium))
            if action != nil {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(.white.opacity(0.75))
        .frame(width: headerWidth, height: height)
        .background(EditorTheme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
        if let action = action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var contentWidth: CGFloat {
        leadingInset + CGFloat(safeDuration) * pixelsPerSecond + trailingInset
    }

    private var contentHeight: CGFloat {
        let videoHeight = clipHeight * CGFloat(videoRows.count) + laneSpacing * CGFloat(max(0, videoRows.count - 1))
        return rulerHeight + 4 + videoHeight + laneHeight * CGFloat(3 + audioRows.count) + laneSpacing * CGFloat(3 + videoRows.count + audioRows.count)
    }

    private func xPosition(for time: Double) -> CGFloat {
        leadingInset + CGFloat(time) * pixelsPerSecond
    }

    private func time(at x: CGFloat) -> Double {
        min(safeDuration, max(0, Double((x - leadingInset) / pixelsPerSecond)))
    }

    private var timelineContent: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: laneSpacing) {
                ruler
                ForEach(videoRows.indices, id: \.self) { row in
                    videoLane(for: videoRows[row], rowIndex: row)
                }
                videoAudioLane
                overlayLane
                textLane
                ForEach(audioRows.indices, id: \.self) { row in
                    audioLaneRow(clips: audioRows[row].clips)
                }
            }
            playhead
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        .coordinateSpace(name: "timelineContent")
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers, location in
            handleDrop(providers, at: location)
        }
    }

    /// Media dragged from the library: the lane under the finger picks the track.
    private func handleDrop(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        guard let provider = providers.first else { return false }
        let time = self.time(at: location.x)
        let videoTop = rulerHeight + 4 + laneSpacing
        let videoHeight = clipHeight * CGFloat(videoRows.count) + laneSpacing * CGFloat(max(0, videoRows.count - 1))
        let pipTop = videoTop + videoHeight + laneSpacing + laneHeight + laneSpacing
        let textTop = pipTop + laneHeight + laneSpacing
        let audioTop = textTop + laneHeight + laneSpacing
        let track: TrackType
        if location.y >= audioTop {
            track = .audio
        } else if location.y >= pipTop && location.y < textTop {
            track = .overlay
        } else {
            track = .main
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, let id = UUID(uuidString: text as String) else { return }
            DispatchQueue.main.async { onDropAsset(id, track, time) }
        }
        return true
    }

    private var ruler: some View {
        let pps = pixelsPerSecond
        let inset = leadingInset
        let duration = safeDuration
        let major = majorTickInterval(pps: pps)
        let minorCount = major >= 1 ? 5 : 2
        let markerTimes = markers
        return Canvas { context, size in
            for marker in markerTimes {
                let x = inset + CGFloat(marker) * pps
                var flag = Path()
                flag.move(to: CGPoint(x: x - 5, y: 0))
                flag.addLine(to: CGPoint(x: x + 5, y: 0))
                flag.addLine(to: CGPoint(x: x, y: 8))
                flag.closeSubpath()
                context.fill(flag, with: .color(.orange))
                context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(.orange.opacity(0.6)))
            }
            let minor = major / Double(minorCount)
            var tick = 0
            var t = 0.0
            while t <= duration + 0.0001 {
                let x = inset + CGFloat(t) * pps
                let isMajor = tick % minorCount == 0
                let height: CGFloat = isMajor ? 10 : 5
                let rect = CGRect(x: x, y: size.height - height, width: 1, height: height)
                context.fill(Path(rect), with: .color(.white.opacity(isMajor ? 0.55 : 0.25)))
                if isMajor {
                    context.draw(
                        Text(Self.rulerLabel(t)).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.6)),
                        at: CGPoint(x: x + 3, y: 2),
                        anchor: .topLeading
                    )
                }
                tick += 1
                t = Double(tick) * minor
            }
        }
        .frame(width: contentWidth, height: rulerHeight + 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in onSeek(time(at: value.location.x)) }
        )
    }

    private func videoLane(for row: [TimelineSegment], rowIndex: Int) -> some View {
        let ordered = row.sorted { $0.startTime < $1.startTime }
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: contentWidth, height: clipHeight)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(nil) }

            if canAddIntro && rowIndex == 0 {
                addButton(title: "Intro", systemImage: "plus", action: onAddIntro)
                    .offset(x: 8)
            }

            ForEach(ordered) { segment in
                let drag = laneDrag?.id == segment.id ? laneDrag : nil
                let display = (drag?.move ?? 0) != 0
                    ? slipped(segment, by: drag?.move ?? 0)
                    : trimmed(segment, left: drag?.left ?? 0, right: drag?.right ?? 0)
                let width = max(8, CGFloat(display.duration) * pixelsPerSecond)
                let isSelected = segment.id == selectedID
                let isMainPiece = segment.sourceType == .mainVideo || segment.sourceType == .clipAsset
                let reorderOffset = reorderDrag?.id == segment.id ? reorderDrag?.offset ?? 0 : 0
                TimelineClipView(
                    segment: display,
                    width: width,
                    height: clipHeight,
                    isSelected: isSelected,
                    sourceURL: sourceURL(segment)
                )
                .onTapGesture { onSelect(segment.id) }
                // Selected clip: drag the body to slip (change which part of the source is used).
                .highPriorityGesture(isSelected ? laneGesture(id: segment.id, part: .move) { move, _, _ in
                    let result = slipped(segment, by: move)
                    onTrimSegment(segment, result.sourceStartTime, result.sourceEndTime)
                } : nil)
                // Main pieces: long-press then drag to reorder.
                .gesture(isMainPiece && !isSelected ? reorderGesture(for: segment) : nil)
                .overlay(alignment: .leading) {
                    if isSelected {
                        edgeHandle(height: clipHeight)
                            .gesture(laneGesture(id: segment.id, part: .left) { _, left, right in
                                commitTrim(segment, left: left, right: right)
                            })
                    }
                }
                .overlay(alignment: .trailing) {
                    if isSelected {
                        edgeHandle(height: clipHeight)
                            .gesture(laneGesture(id: segment.id, part: .right, edges: (segment.startTime, segment.startTime + segment.duration)) { _, left, right in
                                commitTrim(segment, left: left, right: right)
                            })
                    }
                }
                .scaleEffect(reorderOffset != 0 ? 1.04 : 1)
                .shadow(color: .black.opacity(reorderOffset != 0 ? 0.6 : 0), radius: 6)
                .offset(x: xPosition(for: segment.startTime) + reorderOffset)
                .zIndex(reorderOffset != 0 ? 1 : 0)
            }

            ForEach(ordered.filter { $0.id != firstVideoSegmentID }) { segment in
                transitionBadge(for: segment)
                    .offset(
                        x: xPosition(for: segment.startTime + segment.overlapIn / 2) - 11,
                        y: clipHeight / 2 - 11
                    )
            }

            if canAddOutro && rowIndex == 0 {
                addButton(title: "Final", systemImage: "plus", action: onAddOutro)
                    .offset(x: xPosition(for: safeDuration) + 10)
            }
        }
        .frame(width: contentWidth, height: clipHeight, alignment: .topLeading)
    }

    private func trimmed(_ segment: TimelineSegment, left: Double, right: Double) -> TimelineSegment {
        var result = segment
        let maxSource = max(maxSourceTime(segment), segment.sourceEndTime)
        result.sourceStartTime = min(max(0, segment.sourceStartTime + left * segment.speed), segment.sourceEndTime - 0.1)
        result.sourceEndTime = min(maxSource, max(result.sourceStartTime + 0.1, segment.sourceEndTime + right * segment.speed))
        result.duration = (result.sourceEndTime - result.sourceStartTime) / segment.speed
        return result
    }

    private func slipped(_ segment: TimelineSegment, by seconds: Double) -> TimelineSegment {
        var result = segment
        let maxSource = max(maxSourceTime(segment), segment.sourceEndTime)
        let length = segment.sourceEndTime - segment.sourceStartTime
        let start = min(max(0, segment.sourceStartTime - seconds * segment.speed), max(0, maxSource - length))
        result.sourceStartTime = start
        result.sourceEndTime = start + length
        return result
    }

    private func reorderGesture(for segment: TimelineSegment) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag) = value {
                    reorderDrag = (segment.id, drag?.translation.width ?? 0)
                }
            }
            .onEnded { value in
                defer { reorderDrag = nil }
                guard case .second(true, let drag) = value, let drag = drag else { return }
                let center = segment.startTime + segment.duration / 2 + Double(drag.translation.width / pixelsPerSecond)
                onReorderMain(segment.id, center)
            }
    }

    private func commitTrim(_ segment: TimelineSegment, left: Double, right: Double) {
        let result = trimmed(segment, left: left, right: right)
        onTrimSegment(segment, result.sourceStartTime, result.sourceEndTime)
    }

    private func transitionBadge(for segment: TimelineSegment) -> some View {
        Button {
            onTransitionTap(segment)
        } label: {
            Image(systemName: segment.transition == .none ? "plus" : segment.transition.icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(segment.transition == .none ? Color.black : Color.white)
                .frame(width: 22, height: 22)
                .background(
                    segment.transition == .none ? Color.white : EditorTheme.accent,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .buttonStyle(.plain)
    }

    /// Waveform of each clip's own audio, aligned under the clip and scaled by its volume.
    private var videoAudioLane: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.03)
                .frame(width: contentWidth, height: laneHeight)
            ForEach(segments) { segment in
                let drag = laneDrag?.id == segment.id ? laneDrag : nil
                let display = trimmed(segment, left: drag?.left ?? 0, right: drag?.right ?? 0)
                WaveformView(
                    url: sourceURL(segment),
                    sourceStart: display.sourceStartTime,
                    sourceDuration: display.duration,
                    color: segment.trackType.color.opacity(0.85),
                    gain: segment.clipVolume
                )
                .frame(width: max(8, CGFloat(display.duration) * pixelsPerSecond), height: laneHeight - 4)
                .background(segment.trackType.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .topTrailing) {
                    if segment.narrationAssetID != nil {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(3)
                    }
                }
                .offset(x: xPosition(for: segment.startTime), y: 2)
                .allowsHitTesting(false)
            }
        }
        .frame(width: contentWidth, height: laneHeight, alignment: .topLeading)
    }

    private var overlayLane: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.03)
                .frame(width: contentWidth, height: laneHeight)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(nil) }
            ForEach(mediaOverlays.sorted { $0.duration > $1.duration }) { overlay in
                let drag = laneDrag?.id == overlay.id ? laneDrag : nil
                let start = max(0, overlay.startTime + (drag?.move ?? 0) + (drag?.left ?? 0))
                let duration = max(0.3, overlay.duration - (drag?.left ?? 0) + (drag?.right ?? 0))
                laneItem(
                    id: overlay.id,
                    title: overlay.name,
                    icon: overlay.isVideo ? "video.fill" : "photo.fill",
                    color: .indigo,
                    start: start,
                    duration: duration,
                    isSelected: overlay.id == selectedID
                ) { move, left, right in
                    onMoveMediaOverlay(overlay.id, move, left, right)
                }
            }
        }
        .frame(width: contentWidth, height: laneHeight, alignment: .topLeading)
    }

    private var textLane: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.03)
                .frame(width: contentWidth, height: laneHeight)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(nil) }
            ForEach(overlays.sorted { $0.duration > $1.duration }) { overlay in
                let drag = laneDrag?.id == overlay.id ? laneDrag : nil
                let start = max(0, overlay.startTime + (drag?.move ?? 0) + (drag?.left ?? 0))
                let duration = max(0.3, overlay.duration - (drag?.left ?? 0) + (drag?.right ?? 0))
                laneItem(
                    id: overlay.id,
                    title: overlay.text,
                    icon: overlay.anchor != nil ? "repeat" : (overlay.isCaption == true ? "captions.bubble" : "textformat"),
                    color: TrackType.overlay.color,
                    start: start,
                    duration: duration,
                    isSelected: overlay.id == selectedID
                ) { move, left, right in
                    let newStart = max(0, overlay.startTime + move + left)
                    let newDuration = max(0.3, overlay.duration - left + right)
                    onMoveOverlay(overlay.id, newStart, newDuration)
                }
            }
        }
        .frame(width: contentWidth, height: laneHeight, alignment: .topLeading)
    }

    /// One row per audio kind, stacking overlapping clips of the same kind onto extra rows.
    private var audioRows: [(kind: AudioClipKind, index: Int, clips: [AudioClip])] {
        var rows: [(AudioClipKind, Int, [AudioClip])] = []
        let ordered = AudioClipKind.allCases.flatMap { kind in
            audioClips.filter { $0.kind == kind }.sorted { $0.timelineStart < $1.timelineStart }
        } + audioClips.filter { !AudioClipKind.allCases.contains($0.kind) }
        for clip in ordered {
            if let rowIndex = rows.indices.first(where: { row in
                rows[row].0 == clip.kind && rows[row].2.allSatisfy { other in
                    clip.timelineStart >= other.timelineStart + other.duration - 0.01
                        || clip.timelineStart + clip.duration <= other.timelineStart + 0.01
                }
            }) {
                rows[rowIndex].2.append(clip)
            } else {
                let kindRows = rows.filter { $0.0 == clip.kind }.count
                rows.append((clip.kind, kindRows, [clip]))
            }
        }
        // Always keep one empty music row so the header's add button stays reachable.
        if rows.isEmpty { return [(.music, 0, [])] }
        return rows.map { ($0.0, $0.1, $0.2) }
    }

    private func audioLaneRow(clips: [AudioClip]) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.03)
                .frame(width: contentWidth, height: laneHeight)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(nil) }
            ForEach(clips.sorted { $0.duration > $1.duration }) { clip in
                let drag = laneDrag?.id == clip.id ? laneDrag : nil
                let edited = Self.adjusted(clip, move: drag?.move ?? 0, left: drag?.left ?? 0, right: drag?.right ?? 0, assetDuration: audioDuration(clip))
                laneItem(
                    id: clip.id,
                    title: clip.name,
                    icon: clip.anchor != nil ? "repeat" : clip.kind.icon,
                    color: clip.kind == .narration ? .orange : .green,
                    start: edited.timelineStart,
                    duration: min(edited.duration, max(0.1, safeDuration - edited.timelineStart)),
                    isSelected: clip.id == selectedID,
                    waveform: (audioURL(clip), edited.sourceStart, edited.duration)
                ) { move, left, right in
                    onMoveAudio(Self.adjusted(clip, move: move, left: left, right: right, assetDuration: audioDuration(clip)))
                }
            }
        }
        .frame(width: contentWidth, height: laneHeight, alignment: .topLeading)
    }

    static func adjusted(_ clip: AudioClip, move: Double, left: Double, right: Double, assetDuration: Double) -> AudioClip {
        var result = clip
        let maxSource = max(assetDuration, clip.sourceEnd)
        let trimStart = min(max(-clip.sourceStart, left), clip.duration - 0.2)
        result.sourceStart = clip.sourceStart + trimStart
        result.timelineStart = max(0, clip.timelineStart + move + trimStart)
        result.sourceEnd = min(maxSource, max(result.sourceStart + 0.2, clip.sourceEnd + right))
        return result
    }

    private func laneItem(
        id: UUID,
        title: String,
        icon: String,
        color: Color,
        start: Double,
        duration: Double,
        isSelected: Bool,
        waveform: (URL?, Double, Double)? = nil,
        onCommit: @escaping (Double, Double, Double) -> Void
    ) -> some View {
        let width = max(10, CGFloat(duration) * pixelsPerSecond)
        let activeDrag = laneDrag?.id == id ? laneDrag : nil
        let edges = (
            start - (activeDrag?.move ?? 0) - (activeDrag?.left ?? 0),
            start + duration - (activeDrag?.move ?? 0) - (activeDrag?.right ?? 0)
        )
        return ZStack(alignment: .leading) {
            color.opacity(0.55)
            if let waveform = waveform {
                WaveformView(url: waveform.0, sourceStart: waveform.1, sourceDuration: waveform.2, color: .white.opacity(0.55))
                    .padding(.vertical, 3)
            }
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                if width > 40 {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, isSelected ? 12 : 5)
            .foregroundStyle(.white)
        }
        .frame(width: width, height: laneHeight - 4, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(id) }
        // Attached before the handle overlays so the handles' own drags aren't overridden.
        .highPriorityGesture(isSelected ? laneGesture(id: id, part: .move, edges: edges, onCommit: onCommit) : nil)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.white : color, lineWidth: isSelected ? 2.5 : 1)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .leading) {
            if isSelected { edgeHandle(height: laneHeight - 4).gesture(laneGesture(id: id, part: .left, edges: edges, onCommit: onCommit)) }
        }
        .overlay(alignment: .trailing) {
            if isSelected { edgeHandle(height: laneHeight - 4).gesture(laneGesture(id: id, part: .right, edges: edges, onCommit: onCommit)) }
        }
        .offset(x: xPosition(for: start), y: 2)
    }

    private enum DragPart { case move, left, right }

    /// Playhead, clip boundaries and markers that dragged edges stick to.
    private var snapPoints: [Double] {
        var points = [0, currentTime] + markers
        for segment in segments {
            points.append(segment.startTime)
            points.append(segment.startTime + segment.duration)
        }
        return points
    }

    private func snapped(_ seconds: Double, part: DragPart, edges: (Double, Double)?) -> Double {
        guard let edges = edges else { return seconds }
        let tolerance = Double(10 / pixelsPerSecond)
        let candidates: [Double]
        switch part {
        case .move: candidates = [edges.0, edges.1]
        case .left: candidates = [edges.0]
        case .right: candidates = [edges.1]
        }
        var best: Double?
        for edge in candidates {
            let moved = edge + seconds
            for point in snapPoints where abs(point - edge) > 0.001 {
                let delta = point - moved
                if abs(delta) < tolerance, abs(delta) < abs(best ?? .infinity) {
                    best = delta
                }
            }
        }
        return seconds + (best ?? 0)
    }

    private func laneGesture(
        id: UUID,
        part: DragPart,
        edges: (Double, Double)? = nil,
        onCommit: @escaping (Double, Double, Double) -> Void
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let seconds = snapped(Double(value.translation.width / pixelsPerSecond), part: part, edges: edges)
                switch part {
                case .move: laneDrag = LaneDrag(id: id, move: seconds, left: 0, right: 0)
                case .left: laneDrag = LaneDrag(id: id, move: 0, left: seconds, right: 0)
                case .right: laneDrag = LaneDrag(id: id, move: 0, left: 0, right: seconds)
                }
            }
            .onEnded { _ in
                guard let drag = laneDrag, drag.id == id else { return }
                laneDrag = nil
                onCommit(drag.move, drag.left, drag.right)
            }
    }

    private func edgeHandle(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: 10, height: height)
            .overlay(
                Capsule().fill(Color.black.opacity(0.6)).frame(width: 2, height: height * 0.4)
            )
            .contentShape(Rectangle().inset(by: -8))
    }

    private func addButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(width: 58, height: clipHeight)
            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var playhead: some View {
        let x = xPosition(for: min(max(currentTime, 0), safeDuration))
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: contentHeight)
                .allowsHitTesting(false)
            // Grab handle on the ruler: drag it to move the playhead.
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white)
                .frame(width: 14, height: 18)
                .frame(width: 36, height: rulerHeight + 4)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineContent"))
                        .onChanged { value in onSeek(time(at: value.location.x)) }
                )
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .frame(width: 36, alignment: .top)
        .offset(x: x - 18)
    }

    /// Always-visible seconds ruler for the whole episode; drag anywhere on it to scrub.
    private var scrubber: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 12
            let width = max(proxy.size.width - inset * 2, 1)
            let duration = safeDuration
            let step = majorTickInterval(pps: width / CGFloat(duration) * 1.2)
            let markerTimes = markers
            let now = min(max(currentTime, 0), duration)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    var t = 0.0
                    while t <= duration + 0.0001 {
                        let x = inset + CGFloat(t / duration) * width
                        context.fill(Path(CGRect(x: x, y: size.height - 8, width: 1, height: 8)), with: .color(.white.opacity(0.4)))
                        context.draw(
                            Text(Self.rulerLabel(t)).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.55)),
                            at: CGPoint(x: x + 3, y: 3),
                            anchor: .topLeading
                        )
                        let half = t + step / 2
                        if half < duration {
                            let hx = inset + CGFloat(half / duration) * width
                            context.fill(Path(CGRect(x: hx, y: size.height - 4, width: 1, height: 4)), with: .color(.white.opacity(0.25)))
                        }
                        t += step
                    }
                    for marker in markerTimes {
                        let x = inset + CGFloat(marker / duration) * width
                        context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.orange.opacity(0.8)))
                    }
                    let px = inset + CGFloat(now / duration) * width
                    context.fill(Path(CGRect(x: inset, y: size.height - 2, width: px - inset, height: 2)), with: .color(EditorTheme.accent))
                    context.fill(Path(roundedRect: CGRect(x: px - 2, y: 0, width: 4, height: size.height), cornerRadius: 2), with: .color(.white))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max((value.location.x - inset) / width, 0), 1)
                        onSeek(Double(fraction) * duration)
                    }
            )
        }
        .frame(height: 26)
        .background(EditorTheme.panelRaised.opacity(0.6))
    }

    private func zoomBar(width: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text("\(Self.rulerLabel(currentTime)) / \(Self.rulerLabel(totalDuration))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Button { zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
            Slider(
                value: Binding(
                    get: { Double(log(pixelsPerSecond)) },
                    set: { pixelsPerSecond = CGFloat(exp($0)) }
                ),
                in: Double(log(minPPS))...Double(log(maxPPS))
            )
            .frame(maxWidth: 160)
            Button { zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { fit(width: width) } label: { Image(systemName: "arrow.left.and.right.square") }
        }
        .font(.system(size: 15))
        .foregroundStyle(.white.opacity(0.8))
        .tint(EditorTheme.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let base = pinchBase ?? pixelsPerSecond
                pinchBase = base
                pixelsPerSecond = clamp(base * scale)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func zoom(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            pixelsPerSecond = clamp(pixelsPerSecond * factor)
        }
    }

    private func fit(width: CGFloat) {
        let available = width - headerWidth - leadingInset - trailingInset
        pixelsPerSecond = clamp(max(available, 120) / CGFloat(safeDuration))
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(maxPPS, max(minPPS, value))
    }

    private func majorTickInterval(pps: CGFloat) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return candidates.first { CGFloat($0) * pps >= 64 } ?? 600
    }

    static func rulerLabel(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct TimelineClipView: View {
    let segment: TimelineSegment
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    let sourceURL: URL?

    var body: some View {
        let color = segment.trackType.color
        ZStack(alignment: .topLeading) {
            FilmstripView(
                url: sourceURL,
                sourceStart: segment.sourceStartTime,
                sourceDuration: max(segment.sourceDuration, 0.1),
                width: width,
                height: height,
                tint: color
            )
            LinearGradient(
                colors: [.black.opacity(0.65), .clear],
                startPoint: .top,
                endPoint: .center
            )
            if width > 44 {
                HStack(spacing: 4) {
                    Text(segment.trackType.shortLabel)
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(color, in: RoundedRectangle(cornerRadius: 3))
                    if width > 110 {
                        Text(TimelineView.rulerLabel(segment.duration))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    }
                }
                .foregroundStyle(.white)
                .padding(5)
            }
            if !segment.isEnabled {
                Color.black.opacity(0.55)
                Image(systemName: "eye.slash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.white : color.opacity(0.9), lineWidth: isSelected ? 3 : 1.5)
        )
        .contentShape(Rectangle())
    }
}

struct FilmstripView: View {
    let url: URL?
    let sourceStart: Double
    let sourceDuration: Double
    let width: CGFloat
    let height: CGFloat
    let tint: Color

    @State private var frames: [Int: UIImage] = [:]

    private var frameCount: Int {
        max(1, min(40, Int((width / (height * 16 / 9)).rounded(.up))))
    }

    var body: some View {
        let count = frameCount
        let frameWidth = width / CGFloat(count)
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                ZStack {
                    tint.opacity(0.35)
                    if let image = frames[index] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: frameWidth, height: height)
                .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .task(id: taskKey(count: count)) {
            await loadFrames(count: count)
        }
    }

    private func taskKey(count: Int) -> String {
        "\(url?.path ?? "")|\(sourceStart)|\(sourceDuration)|\(count)"
    }

    @MainActor
    private func loadFrames(count: Int) async {
        frames = [:]
        guard let url = url else { return }
        for index in 0..<count {
            if Task.isCancelled { return }
            let time = sourceStart + sourceDuration * (Double(index) + 0.5) / Double(count)
            if let image = await ThumbnailProvider.shared.thumbnail(url: url, time: time) {
                frames[index] = image
            }
        }
    }
}

actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private var cache: [String: UIImage] = [:]
    private var generators: [URL: AVAssetImageGenerator] = [:]

    func thumbnail(url: URL, time: Double) -> UIImage? {
        let key = "\(url.path)#\(Int((time * 4).rounded()))"
        if let cached = cache[key] { return cached }
        let generator: AVAssetImageGenerator
        if let existing = generators[url] {
            generator = existing
        } else {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 200)
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            generators[url] = generator
        }
        guard let cgImage = try? generator.copyCGImage(
            at: CMTime(seconds: max(0, time), preferredTimescale: 600),
            actualTime: nil
        ) else { return nil }
        let image = UIImage(cgImage: cgImage)
        if cache.count > 600 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

struct SegmentEditorView: View {
    let segment: TimelineSegment
    let trackType: TrackType
    let project: Project
    let onSave: (TimelineSegment, Bool) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var sourceStartTime: Double
    @State private var sourceEndTime: Double
    @State private var sourceType: SourceType
    @State private var selectedAsset: MediaAsset?
    @State private var transition: TransitionStyle
    @State private var transitionDuration: Double
    @State private var clipVolume: Float
    @State private var audioFadeIn: Double
    @State private var audioFadeOut: Double
    @State private var narrationVolume: Float
    @State private var keepNarration: Bool
    @State private var previewPlayer = AVPlayer()
    @State private var applyToAllEpisodes: Bool

    init(segment: TimelineSegment, trackType: TrackType, project: Project, onSave: @escaping (TimelineSegment, Bool) -> Void, onDelete: (() -> Void)?) {
        _applyToAllEpisodes = State(initialValue: trackType != .main)
        self.segment = segment
        self.trackType = trackType
        self.project = project
        self.onSave = onSave
        self.onDelete = onDelete
        _sourceStartTime = State(initialValue: segment.sourceStartTime)
        _sourceEndTime = State(initialValue: segment.sourceEndTime)
        _sourceType = State(initialValue: segment.sourceType)
        _selectedAsset = State(initialValue: segment.assetID.flatMap { assetID in
            project.mediaAssets.first { $0.id == assetID }
        })
        _transition = State(initialValue: segment.transition)
        _transitionDuration = State(initialValue: segment.transitionDuration)
        _clipVolume = State(initialValue: segment.clipVolume)
        _audioFadeIn = State(initialValue: segment.audioFadeIn)
        _audioFadeOut = State(initialValue: segment.audioFadeOut)
        _narrationVolume = State(initialValue: segment.narrationVolume)
        _keepNarration = State(initialValue: segment.narrationAssetID != nil)
    }

    private var sourceURL: URL? {
        sourceType == .mainVideo ? project.sourceVideoFileURL : selectedAsset?.url
    }

    private func loadPreview() {
        guard let sourceURL = sourceURL else { return }
        previewPlayer.replaceCurrentItem(with: AVPlayerItem(url: sourceURL))
        scrub(to: sourceStartTime)
    }

    private func scrub(to time: Double) {
        previewPlayer.pause()
        previewPlayer.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private var maxSourceTime: Double {
        selectedAsset?.duration ?? project.sourceVideoDuration
    }

    var body: some View {
        NavigationStack {
            Form {
                if trackType != .main {
                    Section("Origem do conteúdo") {
                        Picker("Tipo", selection: $sourceType) {
                            ForEach(availableSourceTypes) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .onChange(of: sourceType) { _ in
                            if let selectedAsset = selectedAsset, !filteredAssets.contains(where: { $0.id == selectedAsset.id }) {
                                self.selectedAsset = nil
                            }
                        }
                        if sourceType != .mainVideo {
                            Picker("Vídeo", selection: $selectedAsset) {
                                Text("Nenhum").tag(nil as MediaAsset?)
                                ForEach(filteredAssets) { asset in
                                    Text(asset.name).tag(asset as MediaAsset?)
                                }
                            }
                        }
                    }
                }

                Section("Corte (trecho usado)") {
                    VideoPlayer(player: previewPlayer)
                        .frame(height: 200)
                    TrimRangeView(
                        url: sourceURL,
                        duration: maxSourceTime,
                        start: $sourceStartTime,
                        end: $sourceEndTime
                    ) { scrub(to: $0) }
                    .padding(.vertical, 4)
                    Button {
                        previewPlayer.seek(to: CMTime(seconds: sourceStartTime, preferredTimescale: 600))
                        previewPlayer.currentItem?.forwardPlaybackEndTime = CMTime(seconds: sourceEndTime, preferredTimescale: 600)
                        previewPlayer.play()
                    } label: {
                        Label("Tocar trecho", systemImage: "play.fill")
                    }
                }
                .onAppear { loadPreview() }
                .onChange(of: selectedAsset) { _ in loadPreview() }
                .onChange(of: sourceType) { _ in loadPreview() }

                Section("Transição de entrada") {
                    Picker("Estilo", selection: $transition) {
                        ForEach(TransitionStyle.allCases) { style in
                            Label(style.rawValue, systemImage: style.icon).tag(style)
                        }
                    }
                    if transition != .none {
                        HStack {
                            Text("Duração")
                            Slider(value: $transitionDuration, in: 0.2...2.0, step: 0.1)
                            Text(String(format: "%.1fs", transitionDuration)).monospacedDigit()
                        }
                    }
                }

                Section("Áudio") {
                    HStack {
                        Image(systemName: clipVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        Slider(value: $clipVolume, in: 0...1)
                        Text("\(Int(clipVolume * 100))%").monospacedDigit().frame(width: 48)
                    }
                    HStack {
                        Text("Fade in")
                        Slider(value: $audioFadeIn, in: 0...5, step: 0.5)
                        Text(String(format: "%.1fs", audioFadeIn)).monospacedDigit()
                    }
                    HStack {
                        Text("Fade out")
                        Slider(value: $audioFadeOut, in: 0...5, step: 0.5)
                        Text(String(format: "%.1fs", audioFadeOut)).monospacedDigit()
                    }
                    if segment.narrationAssetID != nil {
                        Toggle("Manter narração vinculada", isOn: $keepNarration)
                        if keepNarration {
                            HStack {
                                Image(systemName: "mic.fill")
                                Slider(value: $narrationVolume, in: 0...1)
                                Text("\(Int(narrationVolume * 100))%").monospacedDigit().frame(width: 48)
                            }
                        }
                    }
                }

                if trackType != .main {
                    Section {
                        Toggle("Aplicar em todos os episódios", isOn: $applyToAllEpisodes)
                    } footer: {
                        Text("Repete o corte, a transição, o volume e a narração deste clipe em todos os episódios.")
                    }
                }

                if let onDelete = onDelete {
                    Section {
                        Button("Excluir clipe", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Editar \(trackType.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        var updated = segment
                        updated.sourceStartTime = sourceStartTime
                        updated.sourceEndTime = sourceEndTime
                        updated.duration = sourceEndTime - sourceStartTime
                        updated.sourceType = sourceType
                        updated.assetID = sourceType == .mainVideo ? nil : selectedAsset?.id
                        updated.transition = transition
                        updated.transitionDuration = transitionDuration
                        updated.clipVolume = clipVolume
                        updated.audioFadeIn = audioFadeIn
                        updated.audioFadeOut = audioFadeOut
                        updated.narrationVolume = narrationVolume
                        updated.narrationAssetID = keepNarration ? segment.narrationAssetID : nil
                        onSave(updated, applyToAllEpisodes)
                        dismiss()
                    }
                    .disabled(
                        sourceStartTime < 0
                            || sourceEndTime - sourceStartTime < 0.1
                            || (sourceType != .mainVideo && selectedAsset == nil)
                            || sourceEndTime > maxSourceTime + 0.01
                    )
                }
            }
        }
    }

    private var availableSourceTypes: [SourceType] {
        switch trackType {
        case .intro: return [.introAsset, .mainVideo]
        case .recap: return [.recapAsset, .mainVideo]
        case .main: return [.mainVideo, .clipAsset]
        case .outro: return [.outroAsset, .mainVideo]
        case .audio: return [.audioAsset]
        case .overlay: return [.imageAsset]
        }
    }

    private var filteredAssets: [MediaAsset] {
        switch sourceType {
        case .introAsset, .outroAsset, .recapAsset, .clipAsset: return project.mediaAssets.filter { $0.type == .video }
        default: return []
        }
    }
}
