import Foundation
import Speech
import AVFoundation

struct TranscriptCue: Identifiable {
    let id = UUID()
    let startTime: Double
    let endTime: Double
    let text: String
    var words: [TranscriptWord] = []
}

actor TranscriptionService {
    static let shared = TranscriptionService()

    private init() {}

    func transcribeVideo(at url: URL, localeIdentifier: String = "pt-BR", allowServer: Bool = false) async throws -> [TranscriptCue] {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authorization == .authorized else {
            throw TranscriptionError.permissionDenied
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw TranscriptionError.localeUnavailable
        }
        guard recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw TranscriptionError.noSpeechDetected }

        // Prefer the offline model; Apple's server is only used when the user opts in.
        var modes: [Bool] = []
        if recognizer.supportsOnDeviceRecognition { modes.append(true) }
        if allowServer { modes.append(false) }
        guard !modes.isEmpty else { throw TranscriptionError.onDeviceRecognitionUnavailable }

        let audioTrackIndex = try await VideoProcessor.shared.bestAudioTrackIndex(
            from: url,
            duration: duration,
            languageCode: localeIdentifier
        )
        return try await transcribe(url: url, duration: duration, recognizer: recognizer, modes: modes, audioTrackIndex: audioTrackIndex)
    }

    private func transcribe(url: URL, duration: Double, recognizer: SFSpeechRecognizer, modes: [Bool], audioTrackIndex: Int) async throws -> [TranscriptCue] {
        let chunkDuration = 30.0
        let overlap = 0.75
        var allCues: [TranscriptCue] = []
        var chunkStart = 0.0
        var lastError: Error?

        while chunkStart < duration {
            let leadingOverlap = chunkStart > 0 ? overlap : 0
            let trailingOverlap = chunkStart + chunkDuration < duration ? overlap : 0
            let extractStart = chunkStart - leadingOverlap
            let extractDuration = chunkDuration + leadingOverlap + trailingOverlap
            let audioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: audioURL) }

            try await VideoProcessor.shared.extractAudioForTranscription(
                from: url,
                to: audioURL,
                startTime: extractStart,
                duration: extractDuration,
                audioTrackIndex: audioTrackIndex
            )

            var segments: [SFTranscriptionSegment] = []
            var chunkError: Error?
            for onDevice in modes where segments.isEmpty {
                do {
                    segments = try await recognizeFile(audioURL: audioURL, recognizer: recognizer, onDevice: onDevice)
                } catch {
                    chunkError = error
                    do {
                        segments = try await recognizeBuffered(audioURL: audioURL, recognizer: recognizer, onDevice: onDevice)
                    } catch {
                        chunkError = error
                    }
                }
            }
            if let chunkError, !Self.isNoSpeechError(chunkError) {
                lastError = chunkError
            }

            let ownedStart = leadingOverlap
            let ownedEnd = ownedStart + min(chunkDuration, duration - chunkStart)
            let untimed = segments.allSatisfy { $0.timestamp == 0 && $0.duration == 0 }
            let ownedSegments = untimed ? segments : segments.filter {
                let midpoint = $0.timestamp + $0.duration / 2
                return midpoint >= ownedStart && midpoint < ownedEnd
            }
            let localDuration = untimed ? ownedEnd - ownedStart : extractDuration
            let timeOffset = untimed ? chunkStart : extractStart
            allCues.append(contentsOf: Self.makeCues(from: ownedSegments, chunkDuration: localDuration).map {
                TranscriptCue(
                    startTime: $0.startTime + timeOffset,
                    endTime: $0.endTime + timeOffset,
                    text: $0.text,
                    words: $0.words.map { TranscriptWord(text: $0.text, start: $0.start + timeOffset, end: $0.end + timeOffset) }
                )
            })
            chunkStart += chunkDuration
        }
        if allCues.isEmpty {
            if let lastError, !Self.isNoSpeechError(lastError) { throw lastError }
            throw TranscriptionError.noSpeechDetected
        }
        return allCues
    }

    private func recognizeFile(audioURL: URL, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> [SFTranscriptionSegment] {
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        configure(request, onDevice: onDevice)
        return try await recognize(request: request, recognizer: recognizer)
    }

    /// Feeds decoded PCM to the recognizer. Silent chunks ("No speech detected") return no segments
    /// instead of failing the whole transcription, and the last partial result is kept if the
    /// recognizer ends with an error after already hearing words.
    private func recognizeBuffered(audioURL: URL, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> [SFTranscriptionSegment] {
        let file = try AVAudioFile(forReading: audioURL)
        let request = SFSpeechAudioBufferRecognitionRequest()
        configure(request, onDevice: onDevice)
        let state = RecognitionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SFTranscriptionSegment], Error>) in
                state.continuation = continuation
                state.task = recognizer.recognitionTask(with: request) { result, error in
                    Self.handle(result: result, error: error, state: state)
                }
                do {
                    try Self.appendSpeechBuffers(from: file, to: request)
                    request.endAudio()
                } catch {
                    state.finish(.failure(error))
                }
            }
        } onCancel: {
            state.task?.cancel()
            state.finish(.failure(CancellationError()))
        }
    }

    private func configure(_ request: SFSpeechRecognitionRequest, onDevice: Bool) {
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
    }

    private func recognize(request: SFSpeechRecognitionRequest, recognizer: SFSpeechRecognizer) async throws -> [SFTranscriptionSegment] {
        let state = RecognitionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SFTranscriptionSegment], Error>) in
                state.continuation = continuation
                state.task = recognizer.recognitionTask(with: request) { result, error in
                    Self.handle(result: result, error: error, state: state)
                }
            }
        } onCancel: {
            state.task?.cancel()
            state.finish(.failure(CancellationError()))
        }
    }

    nonisolated private static func handle(result: SFSpeechRecognitionResult?, error: Error?, state: RecognitionState) {
        if let result {
            let segments = result.bestTranscription.segments
            if result.isFinal {
                state.finish(.success(state.collect(final: segments)))
                return
            }
            // Since iOS 16 the transcription restarts after each pause; the result that
            // closes an utterance carries metadata, so keep it before the text resets.
            if result.speechRecognitionMetadata != nil {
                state.commit(segments)
            } else {
                state.update(partial: segments)
            }
        }
        if let error {
            let collected = state.collect(final: nil)
            if !collected.isEmpty {
                state.finish(.success(collected))
            } else if isNoSpeechError(error) {
                state.finish(.success([]))
            } else {
                state.finish(.failure(error))
            }
        }
    }

    nonisolated private static func appendSpeechBuffers(from file: AVAudioFile, to request: SFSpeechAudioBufferRecognitionRequest) throws {
        let inputFormat = file.processingFormat
        guard file.length > 0,
              file.length <= AVAudioFramePosition(AVAudioFrameCount.max),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
        try file.read(into: input)
        guard input.frameLength > 0 else { return }
        guard let inputData = input.floatChannelData else {
            request.append(input)
            return
        }

        var sumSquares = 0.0
        var sampleCount = 0
        let channelCount = Int(inputFormat.channelCount)
        for channel in 0..<channelCount {
            let samples = inputData[channel]
            for frame in 0..<Int(input.frameLength) {
                let value = Double(samples[frame])
                sumSquares += value * value
            }
            sampleCount += Int(input.frameLength)
        }
        let rms = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        let gain = Float(min(3.0, max(1.0, rms > 0.001 ? 0.12 / rms : 1.0)))

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return }
        let frameCapacity: AVAudioFrameCount = 8192
        var position: AVAudioFrameCount = 0
        while position < input.frameLength {
            let frameCount = min(frameCapacity, input.frameLength - position)
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { break }
            output.frameLength = frameCount
            guard let outputSamples = output.floatChannelData?[0] else { break }
            for offset in 0..<Int(frameCount) {
                let frame = Int(position) + offset
                var mixed = Float(0)
                for channel in 0..<channelCount {
                    mixed += inputData[channel][frame]
                }
                outputSamples[offset] = max(-0.98, min(0.98, mixed / Float(channelCount) * gain))
            }
            request.append(output)
            position += frameCount
        }
    }

    nonisolated private static func isNoSpeechError(_ error: Error) -> Bool {
        if let transcriptionError = error as? TranscriptionError, case .noSpeechDetected = transcriptionError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == "kAFAssistantErrorDomain" && [203, 1110].contains(nsError.code)
    }

    private static func makeCues(from segments: [SFTranscriptionSegment], chunkDuration: Double) -> [TranscriptCue] {
        guard !segments.isEmpty else { return [] }
        // Partial results can lack timings; spread the words over the chunk in that case.
        if segments.allSatisfy({ $0.timestamp == 0 && $0.duration == 0 }) {
            let text = segments.map(\.substring).joined(separator: " ")
            return [TranscriptCue(startTime: 0, endTime: chunkDuration, text: text, words: TranscriptWord.spread(text, from: 0, to: chunkDuration))]
        }
        var cues: [TranscriptCue] = []
        var words: [String] = []
        var timed: [TranscriptWord] = []
        var cueStart: Double?
        var cueEnd = 0.0

        for segment in segments {
            if cueStart == nil {
                cueStart = segment.timestamp
            }
            words.append(segment.substring)
            cueEnd = segment.timestamp + segment.duration
            timed.append(TranscriptWord(text: segment.substring, start: segment.timestamp, end: cueEnd))

            let endsSentence = segment.substring.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) != nil
            if cueEnd - (cueStart ?? cueEnd) >= 4 || endsSentence {
                cues.append(TranscriptCue(startTime: cueStart ?? segment.timestamp, endTime: cueEnd, text: words.joined(separator: " "), words: timed))
                words = []
                timed = []
                cueStart = nil
            }
        }

        if let cueStart, !words.isEmpty {
            cues.append(TranscriptCue(startTime: cueStart, endTime: cueEnd, text: words.joined(separator: " "), words: timed))
        }
        return cues
    }

    enum TranscriptionError: LocalizedError {
        case permissionDenied
        case localeUnavailable
        case recognizerUnavailable
        case onDeviceRecognitionUnavailable
        case invalidSubtitleFile
        case noSpeechDetected

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "A permissão para transcrição foi negada. Ative o Reconhecimento de Fala nos Ajustes."
            case .localeUnavailable:
                return "A transcrição em português do Brasil não está disponível neste dispositivo."
            case .recognizerUnavailable:
                return "O serviço de reconhecimento de fala está indisponível no momento."
            case .onDeviceRecognitionUnavailable:
                return "Este dispositivo não oferece transcrição offline para esse idioma. Ative “Usar servidor da Apple” para transcrever online."
            case .invalidSubtitleFile:
                return "O arquivo não contém legendas SRT ou VTT válidas."
            case .noSpeechDetected:
                return "Nenhuma fala foi reconhecida. Confira se o vídeo tem fala audível e se o idioma escolhido está correto."
            }
        }
    }
}

private final class RecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<[SFTranscriptionSegment], Error>?
    var task: SFSpeechRecognitionTask?
    private var committed: [SFTranscriptionSegment] = []
    private var latest: [SFTranscriptionSegment] = []

    func commit(_ segments: [SFTranscriptionSegment]) {
        lock.lock()
        defer { lock.unlock() }
        // The same utterance can arrive twice (metadata result, then final); repeated words
        // spoken later have a different start time and are kept.
        for segment in segments {
            let alreadyCommitted = committed.contains {
                $0.substring == segment.substring && abs($0.timestamp - segment.timestamp) < 0.05
            }
            if !alreadyCommitted {
                committed.append(segment)
            }
        }
        latest = []
    }

    /// Commits the previous partial when the recognizer silently starts a new utterance.
    func update(partial segments: [SFTranscriptionSegment]) {
        lock.lock()
        let restarted = !latest.isEmpty
            && segments.count < latest.count
            && segments.first?.substring != latest.first?.substring
        let previous = latest
        latest = segments
        lock.unlock()
        if restarted {
            commit(previous)
            lock.lock()
            latest = segments
            lock.unlock()
        }
    }

    func collect(final segments: [SFTranscriptionSegment]?) -> [SFTranscriptionSegment] {
        if let segments {
            commit(segments)
        } else {
            lock.lock()
            let pending = latest
            lock.unlock()
            commit(pending)
        }
        lock.lock()
        defer { lock.unlock() }
        return committed
    }

    func finish(_ result: Result<[SFTranscriptionSegment], Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

enum SubtitleFile {
    static func parse(_ text: String) throws -> [TranscriptCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [TranscriptCue] = []

        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[timingIndex].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = parseTime(times[0]),
                  let end = parseTime(times[1].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""),
                  end > start else {
                continue
            }

            let caption = lines.dropFirst(timingIndex + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty {
                cues.append(TranscriptCue(startTime: start, endTime: end, text: caption))
            }
        }

        guard !cues.isEmpty else {
            throw TranscriptionService.TranscriptionError.invalidSubtitleFile
        }
        return cues
    }

    static func srt(from cues: [TranscriptCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(formatTime(cue.startTime)) --> \(formatTime(cue.endTime))\n\(cue.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    private static func parseTime(_ value: String) -> Double? {
        let timestamp = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = timestamp.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let seconds = Double(String(parts[parts.count - 1])) ?? -1
        let minutes = Double(String(parts[parts.count - 2])) ?? -1
        let hours = parts.count == 3 ? (Double(String(parts[0])) ?? -1) : 0
        guard hours.isFinite, minutes.isFinite, seconds.isFinite,
              hours >= 0, minutes >= 0, seconds >= 0, seconds < 60 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func formatTime(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let wholeSeconds = (milliseconds % 60_000) / 1000
        let remainder = milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, wholeSeconds, remainder)
    }
}

extension TranscriptWord {
    /// Estimated timings: spreads the words of `text` over a range in proportion to their length.
    static func spread(_ text: String, from start: Double, to end: Double) -> [TranscriptWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = Double(tokens.reduce(0) { $0 + $1.count + 1 })
        guard total > 0, end > start else { return [] }
        var cursor = start
        return tokens.map { token in
            let length = (end - start) * Double(token.count + 1) / total
            defer { cursor += length }
            return TranscriptWord(text: token, start: cursor, end: cursor + length)
        }
    }
}
