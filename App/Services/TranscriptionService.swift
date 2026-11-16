import Foundation
import Speech

struct TranscriptCue: Identifiable {
    let id = UUID()
    let startTime: Double
    let endTime: Double
    let text: String
}

actor TranscriptionService {
    static let shared = TranscriptionService()

    private init() {}

    func transcribeVideo(at url: URL, localeIdentifier: String = "pt-BR") async throws -> [TranscriptCue] {
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
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceRecognitionUnavailable
        }

        let videoInfo = try await VideoProcessor.shared.getVideoInfo(for: url)
        let chunkDuration = 45.0
        var allCues: [TranscriptCue] = []
        var chunkStart = 0.0

        while chunkStart < videoInfo.duration {
            let audioURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: audioURL) }

            try await VideoProcessor.shared.extractAudioForTranscription(
                from: url,
                to: audioURL,
                startTime: chunkStart,
                duration: chunkDuration
            )

            let request = SFSpeechURLRecognitionRequest(url: audioURL)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false

            let transcription: SFTranscription = try await withCheckedThrowingContinuation { continuation in
                recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let result, result.isFinal {
                        continuation.resume(returning: result.bestTranscription)
                    }
                }
            }

            allCues.append(contentsOf: Self.makeCues(from: transcription.segments).map {
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

    private static func makeCues(from segments: [SFTranscriptionSegment]) -> [TranscriptCue] {
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

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "A permissão para transcrição foi negada. Ative o Reconhecimento de Fala nos Ajustes."
            case .localeUnavailable:
                return "A transcrição em português do Brasil não está disponível neste dispositivo."
            case .recognizerUnavailable:
                return "O serviço de reconhecimento de fala está indisponível no momento."
            case .onDeviceRecognitionUnavailable:
                return "Este dispositivo não oferece transcrição offline em português."
            case .invalidSubtitleFile:
                return "O arquivo não contém legendas SRT ou VTT válidas."
            }
        }
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
