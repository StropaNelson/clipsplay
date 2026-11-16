import Foundation
import Speech
import AVFoundation

struct TranscriptCue: Identifiable {
    let id = UUID()
    let startTime: Double
    let endTime: Double
    let text: String
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

        var lastError: Error?
        for onDevice in modes {
            do {
                let cues = try await transcribe(url: url, duration: duration, recognizer: recognizer, onDevice: onDevice)
                if !cues.isEmpty { return cues }
            } catch {
                lastError = error
            }
        }
        if let lastError, !Self.isNoSpeechError(lastError) { throw lastError }
        throw TranscriptionError.noSpeechDetected
    }

    private func transcribe(url: URL, duration: Double, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> [TranscriptCue] {
        let chunkDuration = 45.0
        var allCues: [TranscriptCue] = []
        var chunkStart = 0.0

        while chunkStart < duration {
            let length = min(chunkDuration, duration - chunkStart)
            let audioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: audioURL) }

            try await VideoProcessor.shared.extractAudioForTranscription(
                from: url,
                to: audioURL,
                startTime: chunkStart,
                duration: length
            )

            let segments = try await recognize(audioURL: audioURL, recognizer: recognizer, onDevice: onDevice)
            allCues.append(contentsOf: Self.makeCues(from: segments, chunkDuration: length).map {
                TranscriptCue(
                    startTime: $0.startTime + chunkStart,
                    endTime: $0.endTime + chunkStart,
                    text: $0.text
                )
            })
            chunkStart += chunkDuration
        }
        return allCues
    }

    /// Feeds decoded PCM to the recognizer. Silent chunks ("No speech detected") return no segments
    /// instead of failing the whole transcription, and the last partial result is kept if the
    /// recognizer ends with an error after already hearing words.
    private func recognize(audioURL: URL, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> [SFTranscriptionSegment] {
        let file = try AVAudioFile(forReading: audioURL)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true

        let format = file.processingFormat
        let frameCapacity: AVAudioFrameCount = 8192
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { break }
            try file.read(into: buffer, frameCount: frameCapacity)
            if buffer.frameLength == 0 { break }
            request.append(buffer)
        }
        request.endAudio()

        let state = RecognitionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SFTranscriptionSegment], Error>) in
                state.continuation = continuation
                state.task = recognizer.recognitionTask(with: request) { result, error in
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
                        } else if Self.isNoSpeechError(error) {
                            state.finish(.success([]))
                        } else {
                            state.finish(.failure(error))
                        }
                    }
                }
            }
        } onCancel: {
            state.task?.cancel()
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
            return [TranscriptCue(startTime: 0, endTime: chunkDuration, text: text)]
        }
        var cues: [TranscriptCue] = []
        var words: [String] = []
        var cueStart: Double?
        var cueEnd = 0.0

        for segment in segments {
            if cueStart == nil {
                cueStart = segment.timestamp
            }
            words.append(segment.substring)
            cueEnd = segment.timestamp + segment.duration

            let endsSentence = segment.substring.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) != nil
            if cueEnd - (cueStart ?? cueEnd) >= 4 || endsSentence {
                cues.append(TranscriptCue(startTime: cueStart ?? segment.timestamp, endTime: cueEnd, text: words.joined(separator: " ")))
                words = []
                cueStart = nil
            }
        }

        if let cueStart, !words.isEmpty {
            cues.append(TranscriptCue(startTime: cueStart, endTime: cueEnd, text: words.joined(separator: " ")))
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
    private var lastCommittedKey = ""
    private var latest: [SFTranscriptionSegment] = []

    private static func text(_ segments: [SFTranscriptionSegment]) -> String {
        segments.map(\.substring).joined(separator: " ")
    }

    func commit(_ segments: [SFTranscriptionSegment]) {
        lock.lock()
        defer { lock.unlock() }
        // The same utterance can arrive twice (metadata result, then final); repeated words
        // spoken later have a different start time and are kept.
        let key = "\(segments.first?.timestamp ?? -1)|\(Self.text(segments))"
        if !segments.isEmpty, key != lastCommittedKey {
            committed.append(contentsOf: segments)
            lastCommittedKey = key
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
