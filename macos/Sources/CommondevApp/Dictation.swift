import AVFoundation
import Speech
import SwiftUI

@MainActor
final class Dictation: ObservableObject {
    enum State {
        case idle, requestingAccess, recording, finishing
    }

    @Published private(set) var state: State = .idle

    private var recordingID: UUID?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var finishTimeout: Task<Void, Never>?

    func start(language: String, onText: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        guard state == .idle else { return }
        // The unbundled SwiftPM executable has no privacy usage descriptions.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            onError("Для диктовки запустите собранное приложение commondev (.app).")
            return
        }
        let id = UUID()
        recordingID = id
        state = .requestingAccess
        Task { [weak self] in
            let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self, self.recordingID == id else { return }
            guard microphoneAllowed else {
                self.cancel()
                onError("Разрешите commondev доступ к микрофону в системных настройках macOS.")
                return
            }
            let authorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
            guard self.recordingID == id else { return }
            guard authorized else {
                self.cancel()
                onError("Разрешите commondev распознавать речь в системных настройках macOS.")
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
                self.cancel()
                onError("Распознавание речи на выбранном языке сейчас недоступно.")
                return
            }
            self.record(recognizer: recognizer, id: id, onText: onText, onError: onError)
        }
    }

    private func record(recognizer: SFSpeechRecognizer, id: UUID,
                        onText: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            cancel()
            onError("macOS не нашла доступный микрофон.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        self.engine = engine
        self.request = request
        self.recognizer = recognizer
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.recordingID == id else { return }
                if let text, !text.isEmpty { onText(text) }
                if let message {
                    let wasRecording = self.state == .recording
                    self.cancel()
                    if wasRecording { onError("Диктовка прервалась. \(message)") }
                } else if isFinal {
                    self.cancel()
                }
            }
        }
        do {
            try engine.start()
            state = .recording
        } catch {
            cancel()
            onError("Не удалось включить микрофон. \(error.localizedDescription)")
        }
    }

    func finish() {
        guard state == .recording else { return }
        let id = recordingID
        state = .finishing
        releaseMicrophone()
        request?.endAudio()
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, self?.recordingID == id else { return }
            self?.cancel()
        }
    }

    func cancel() {
        recordingID = nil
        finishTimeout?.cancel()
        finishTimeout = nil
        releaseMicrophone()
        recognition?.cancel()
        recognition = nil
        recognizer = nil
        request = nil
        state = .idle
    }

    private func releaseMicrophone() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }
}
