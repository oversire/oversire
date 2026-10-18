import AVFoundation
import Cocoa
import Speech

// ─── Voice notes ─────────────────────────────────────────────────────────────
// On-device speech to text. No audio is kept or sent.

enum SnapVoiceError: LocalizedError {
    case denied, noOnDevice, mic(String)

    var errorDescription: String? {
        switch self {
        case .denied: return "Voice needs the Microphone and Speech Recognition permissions"
        case .noOnDevice: return "This Mac has no on-device speech model for your language"
        case .mic(let s): return "The microphone did not start: \(s)"
        }
    }
}

final class SnapVoice {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var done: ((Result<String, Error>) -> Void)?
    private var text = ""
    private(set) var isRecording = false

    /// A level from 0 to 1 as 5 bars, for the button title.
    static func bars(_ level: Float) -> String {
        let n = Int((max(0, min(1, level)) * 5).rounded())
        return String(repeating: "▮", count: n) + String(repeating: "▯", count: 5 - n)
    }

    func start(level: @escaping (Float) -> Void, done: @escaping (Result<String, Error>) -> Void) {
        guard !isRecording else { return }
        Self.authorize { [weak self] ok in
            guard let self else { return }
            guard ok else { return done(.failure(SnapVoiceError.denied)) }
            guard let rec = SFSpeechRecognizer(), rec.supportsOnDeviceRecognition, rec.isAvailable else {
                return done(.failure(SnapVoiceError.noOnDevice))
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true
            req.shouldReportPartialResults = true
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
                req.append(buf)
                let l = Self.rms(buf)
                DispatchQueue.main.async { level(l) }
            }
            engine.prepare()
            do { try engine.start() } catch {
                input.removeTap(onBus: 0)
                return done(.failure(SnapVoiceError.mic(error.localizedDescription)))
            }
            request = req
            text = ""
            self.done = done
            isRecording = true
            task = rec.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let r = result { self.text = r.bestTranscription.formattedString }
                    if result?.isFinal == true || error != nil { self.finish(error: result == nil ? error : nil) }
                }
            }
        }
    }

    /// Stops the microphone. The recognizer then gives its final text.
    func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRecording = false
    }

    private func finish(error: Error?) {
        stop()
        task = nil
        request = nil
        let d = done
        done = nil
        if let error, text.isEmpty { d?(.failure(error)) } else { d?(.success(text)) }
    }

    private static func authorize(_ then: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { mic in
            SFSpeechRecognizer.requestAuthorization { s in
                DispatchQueue.main.async { then(mic && s == .authorized) }
            }
        }
    }

    private static func rms(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
        return min(1, sqrt(sum / Float(buf.frameLength)) * 8)
    }
}
