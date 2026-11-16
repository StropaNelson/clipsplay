import Foundation
import AVFoundation

@MainActor
final class NarrationRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var elapsed: Double = 0
    @Published var level: Float = 0
    @Published var recordedURL: URL?
    @Published var recordedDuration: Double = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func start() async {
        errorMessage = nil
        stopPlayback()
        guard await requestPermission() else {
            errorMessage = "Permita o acesso ao microfone em Ajustes para gravar narrações."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            discard()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("narracao_\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                errorMessage = "Não foi possível iniciar a gravação."
                return
            }
            self.recorder = recorder
            isRecording = true
            elapsed = 0
            startTimer()
        } catch {
            errorMessage = "Erro ao iniciar a gravação: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let recorder else { return }
        recordedDuration = recorder.currentTime
        recorder.stop()
        recordedURL = recorder.url
        self.recorder = nil
        isRecording = false
        level = 0
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }
        guard let recordedURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: recordedURL)
            player.play()
            self.player = player
            isPlaying = true
            startTimer()
        } catch {
            errorMessage = "Erro ao reproduzir: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        if !isRecording {
            timer?.invalidate()
            timer = nil
        }
    }

    func discard() {
        stopPlayback()
        if let recordedURL {
            try? FileManager.default.removeItem(at: recordedURL)
        }
        recordedURL = nil
        recordedDuration = 0
        elapsed = 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        if let recorder, recorder.isRecording {
            recorder.updateMeters()
            elapsed = recorder.currentTime
            let power = recorder.averagePower(forChannel: 0)
            level = max(0, min(1, (power + 50) / 50))
        } else if let player {
            elapsed = player.currentTime
            if !player.isPlaying {
                stopPlayback()
            }
        }
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
