import AppKit
import AVFoundation
import Combine
import Speech
import SwiftUI

enum VoiceState { case off, idle, listening, capturing, thinking, speaking }

// MARK: - Pure helpers (unit-testable)

enum WakeWord {
    private static let prefixes: Set<String> = ["hey", "hi", "okay", "ok", "yo", "hello"]

    private static func norm(_ s: Substring) -> String { s.lowercased().filter { $0.isLetter } }

    /// Number of leading tokens used by the wake phrase ("Friday ..." -> 1, "hey Friday ..." -> 2), or nil.
    /// Only an utterance that *starts* with it counts, so "see you Friday" never triggers.
    static func detect(_ text: String) -> Int? {
        let t = text.split(separator: " ").map(norm)
        if t.first == "friday" { return 1 }
        if t.count >= 2, prefixes.contains(t[0]), t[1] == "friday" { return 2 }
        return nil
    }

    static func strip(_ text: String, skip: Int) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        return tokens.count >= skip ? tokens.dropFirst(skip).joined(separator: " ") : ""
    }

    static let endPhrases: Set<String> = ["stop", "never mind", "nevermind", "cancel", "goodbye", "bye", "thanks", "thank you",
                                          "that's all", "thats all", "that is all", "no thanks", "no thank you", "all good"]
}

enum SpeakText {
    /// Plain speakable text: no markdown, links, bullets or code.
    static func clean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*[-•*]\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*#+\s*"#, with: "", options: .regularExpression)
        for c in ["**", "__", "`", "*"] { t = t.replacingOccurrences(of: c, with: "") }
        t = t.replacingOccurrences(of: #"([^.!?:,;])\n+"#, with: "$1. ", options: .regularExpression)   // a line break is a pause
        t = t.replacingOccurrences(of: "\n", with: " ")
        return t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// First complete sentence in `s` (ending in . ! ? followed by space), or nil if none yet.
    static func nextSentence(in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"[.!?]["')\]]*\s+"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) else { return nil }
        let chunk = String(s[..<r.upperBound])
        return chunk.trimmingCharacters(in: .whitespaces).count >= 3 ? chunk : nil
    }
}

private extension AVAudioPCMBuffer {
    func clone() -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        c.frameLength = frameLength
        if let s = floatChannelData, let d = c.floatChannelData {
            for ch in 0..<Int(format.channelCount) { memcpy(d[ch], s[ch], Int(frameLength) * MemoryLayout<Float>.size) }
        }
        return c
    }
}

// MARK: - Microphone + on-device recognition

/// Keeps the mic open and runs a cheap loudness gate. Speech recognition only runs while someone is talking
/// (plus half a second of pre-roll so the first syllable isn't clipped), always on-device.
final class AudioListener {
    enum Mode { case paused, wake, query }

    var onLevel: ((Float) -> Void)?
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    var onWake: ((String) -> Void)?
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private let q = DispatchQueue(label: "friday.audio")
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var mode: Mode = .paused

    // loudness gate (q only)
    private var floorDB: Float = -60
    private var haveFloor = false
    private var loudFrames = 0
    private var inUtterance = false
    private var silence = 0.0
    private var duration = 0.0
    private var wakeFired = false
    private var wakeSkip = 0
    private var loudSeconds = 0.0          // how much of this utterance was actually loud (speech, not room noise)
    private var ring: [AVAudioPCMBuffer] = []
    private var ringSeconds = 0.0
    private var lastLevel = Date.distantPast
    private var utterance = 0
    private var ignoreBelow = 0          // results from cancelled utterances are dropped
    private var lastText = ""
    private var lastTextChange = Date()

    // 16 kHz mono copy of the audio for Whisper
    private var samples: [Float] = []
    private var ring16: [[Float]] = []
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let out16 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var appleFinal: [Int: String] = [:]
    private var observer: NSObjectProtocol?

    static func makeRecognizer() -> SFSpeechRecognizer? {
        for id in [Locale.current.identifier, "en-AU", "en-US"] {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable, r.supportsOnDeviceRecognition { return r }
        }
        return nil
    }

    func start() throws {
        guard let r = Self.makeRecognizer() else {
            throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "On-device speech recognition isn't available. Add the language under System Settings → Keyboard → Dictation."])
        }
        recognizer = r
        do { try startEngine() } catch { q.asyncAfter(deadline: .now() + 1) { self.restartEngine(attempt: 1) } }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.q.async { self?.restartEngine() }          // headphones plugged in, default mic changed, ...
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        // After a device change macOS can briefly report 0 Hz / 0 channels. Installing a tap then raises an Objective-C
        // exception, which Swift cannot catch and which killed the whole app, so refuse and retry instead.
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            throw NSError(domain: "Voice", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone isn't ready yet."])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in      // nil = whatever the device delivers
            guard let self, let copy = buf.clone() else { return }
            self.q.async { self.process(copy) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Restart after a device change, retrying for up to ~20 s while the new device settles.
    private func restartEngine(attempt: Int = 0) {
        engine.stop()
        do { try startEngine() } catch {
            guard attempt < 20 else { return }
            q.asyncAfter(deadline: .now() + 1) { self.restartEngine(attempt: attempt + 1) }
        }
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        q.async { self.cancelUtterance() }
    }

    func setMode(_ m: Mode) {
        q.async {
            self.mode = m
            if m == .paused { self.cancelUtterance() }
            self.loudFrames = 0
        }
    }

    private func cancelUtterance() {
        task?.cancel()
        task = nil
        request = nil
        inUtterance = false
        wakeFired = false
        ring.removeAll()
        ring16.removeAll()
        samples = []
        ringSeconds = 0
        lastText = ""
        utterance += 1
        ignoreBelow = utterance
    }

    // MARK: audio thread work

    private func to16k(_ buf: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || converterInput != buf.format {
            converter = AVAudioConverter(from: buf.format, to: out16)
            converterInput = buf.format
        }
        guard let conv = converter else { return [] }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: out16, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        let frames = Int(buf.frameLength)
        guard frames > 0 else { return }
        let dur = Double(frames) / buf.format.sampleRate
        var sum: Float = 0
        if let ch = buf.floatChannelData?[0] { for i in 0..<frames { sum += ch[i] * ch[i] } }
        let db = 20 * log10(max(sqrt(sum / Float(frames)), 1e-7))

        if Date().timeIntervalSince(lastLevel) > 0.066 {
            lastLevel = Date()
            let level = min(max((db + 55) / 40, 0), 1)
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        guard mode != .paused else { return }

        if !haveFloor { floorDB = db; haveFloor = true }
        if !inUtterance && db < floorDB + 8 { floorDB = floorDB * 0.97 + db * 0.03 }       // adapt to room noise
        let loud = db > max(floorDB + 10, -50)

        let s16 = to16k(buf)
        if !inUtterance {
            ring.append(buf)
            ring16.append(s16)
            ringSeconds += dur
            while ringSeconds > 0.5, let first = ring.first {
                ringSeconds -= Double(first.frameLength) / first.format.sampleRate
                ring.removeFirst()
                if !ring16.isEmpty { ring16.removeFirst() }
            }
            loudFrames = loud ? loudFrames + 1 : 0
            if loudFrames >= 2 { beginUtterance() }
        } else {
            request?.append(buf)
            samples += s16
            duration += dur
            silence = loud ? 0 : silence + dur
            if loud { loudSeconds += dur }
            let endAfter = (mode == .query || wakeFired) ? 1.0 : 0.8
            let stalled = !lastText.isEmpty && Date().timeIntervalSince(lastTextChange) > 1.4   // words stopped coming in
            if silence >= endAfter || stalled || duration > 30 { endUtterance() }
        }
    }

    /// Stop feeding Apple and hand the audio to Whisper for the accurate final transcript.
    private func endUtterance() {
        request?.endAudio()
        inUtterance = false                       // Apple's task keeps running until its own final result arrives
        let id = utterance
        let audio = samples
        samples = []
        DispatchQueue.main.async { self.onSpeechEnd?() }

        let whisper = WhisperServer.shared.ready
        let woke = wakeFired, skip = wakeSkip, modeNow = mode
        // in wake mode only bother Whisper if the utterance already woke us, or it sounds like it began with "Friday"
        let worth = woke || modeNow == .query || WakeWord.soundsLikeWake(lastText)
        let enoughSpeech = loudSeconds >= 0.3
        guard whisper, worth, enoughSpeech, !audio.isEmpty else {
            // nothing worth transcribing: if we were waiting for the user, say so, so the UI doesn't sit on "Thinking…"
            if woke || modeNow == .query { DispatchQueue.main.async { self.onFinal?("") } }
            return
        }
        let seconds = Double(audio.count) / 16000
        Task {
            let text = WhisperFilter.clean(await WhisperServer.shared.transcribe(audio), seconds: seconds)
            self.q.async { self.finishWithWhisper(id, text, woke: woke, skip: skip, mode: modeNow) }
        }
    }

    private func finishWithWhisper(_ id: Int, _ whisperText: String?, woke: Bool, skip: Int, mode modeThen: Mode) {
        let apple = appleFinal.removeValue(forKey: id) ?? ""
        guard id >= ignoreBelow else { return }
        let text = whisperText ?? apple                                  // Whisper failed or heard nothing: use Apple's words
        let consumed = WakeWord.detect(text)

        if modeThen == .wake && !woke {
            // Apple missed the wake word but Whisper heard it: wake late, then submit the rest
            guard let n = consumed else { return }
            let rest = WakeWord.strip(text, skip: n)
            DispatchQueue.main.async { self.onWake?(rest); self.onFinal?(rest) }
            return
        }
        let body = consumed.map { WakeWord.strip(text, skip: $0) } ?? text
        DispatchQueue.main.async { self.onPartial?(body); self.onFinal?(body) }
    }

    private func beginUtterance() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true      // never sends audio to Apple
        req.taskHint = .dictation
        req.contextualStrings = ["Friday", "Hey Friday", "F.R.I.D.A.Y"]
        if #available(macOS 13.0, *) { req.addsPunctuation = false }
        for b in ring { req.append(b) }
        samples = ring16.flatMap { $0 }
        ring.removeAll()
        ring16.removeAll()
        ringSeconds = 0
        request = req
        inUtterance = true
        silence = 0
        duration = 0
        wakeFired = false
        wakeSkip = 0
        loudSeconds = 0
        loudFrames = 0
        lastText = ""
        lastTextChange = Date()
        utterance += 1
        let id = utterance
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.q.async { self?.handle(result, error, id) }
        }
        DispatchQueue.main.async { self.onSpeechStart?() }
    }

    private func handle(_ result: SFSpeechRecognitionResult?, _ error: Error?, _ id: Int) {
        guard id >= ignoreBelow else { return }                      // cancelled utterance
        let text = result?.bestTranscription.formattedString ?? ""
        let final = (result?.isFinal ?? false) || error != nil
        if id == utterance, !text.isEmpty, text != lastText { lastText = text; lastTextChange = Date() }
        // an error can arrive without a result: fall back to the last words we heard instead of losing them
        let full = text.isEmpty && final && id == utterance ? lastText : text

        if mode == .wake, !wakeFired, let skip = WakeWord.detect(full), id == utterance {
            wakeFired = true
            wakeSkip = skip
            let rest = WakeWord.strip(full, skip: skip)
            DispatchQueue.main.async { self.onWake?(rest) }
        }
        if wakeFired || mode == .query {
            var skip = wakeSkip
            if !wakeFired, let s = WakeWord.detect(full) { skip = s }       // follow-up that starts with "Friday ..."
            let body = WakeWord.strip(full, skip: skip)
            DispatchQueue.main.async { self.onPartial?(body) }
            if final {
                if WhisperServer.shared.ready { appleFinal[id] = full }                // Whisper delivers the final text
                else { DispatchQueue.main.async { self.onFinal?(body) } }
            }
        }
        if final, WhisperServer.shared.ready, !(wakeFired || mode == .query) { appleFinal[id] = full }
        if final, id == utterance {
            task = nil
            request = nil
            inUtterance = false
            wakeFired = false
            lastText = ""
        }
    }
}

// MARK: - Wake sound

/// A short rising "zing" synthesised in code: an upward sweep with a bright shimmer on top.
enum Zing {
    private static var player: AVAudioPlayer?
    static let data: Data = {
        let sr = 44100.0, dur = 0.5
        let n = Int(sr * dur)
        var pcm = [Int16](repeating: 0, count: n)
        var phase = 0.0, shimmer = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            let f = 520 * pow(2400.0 / 520.0, min(t / 0.16, 1))               // fast exponential sweep up
            phase += 2 * .pi * f / sr
            shimmer += 2 * .pi * (f * 1.5 + 6) / sr
            let attack = min(t / 0.008, 1)
            let body = exp(-t * 5.5)
            let spark = t > 0.05 ? exp(-(t - 0.05) * 9) : 0                   // delayed high sparkle
            let v = (sin(phase) * 0.7 + sin(phase * 2) * 0.22 + sin(shimmer) * 0.28 * spark) * attack * body
            pcm[i] = Int16(max(-1, min(1, v * 0.55)) * 32767)
        }
        var wav = Data()
        func put<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: MemoryLayout<T>.size)) }
        wav.append("RIFF".data(using: .ascii)!); put(UInt32(36 + n * 2)); wav.append("WAVEfmt ".data(using: .ascii)!)
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(sr)); put(UInt32(sr) * 2); put(UInt16(2)); put(UInt16(16))
        wav.append("data".data(using: .ascii)!); put(UInt32(n * 2))
        pcm.withUnsafeBufferPointer { wav.append(Data(buffer: $0)) }
        return wav
    }()

    @MainActor static func play() {
        player = try? AVAudioPlayer(data: data)
        player?.volume = 0.8
        player?.play()
    }
}

// MARK: - Text to speech

@MainActor
final class SpeechOut: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var pending = 0
    var onIdle: (() -> Void)?
    var isSpeaking: Bool { pending > 0 }

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Best installed English voice: Premium/Enhanced first, then Siri-based ones, in the user's region.
    /// Override with: defaults write com.friday.app voiceName "<voice name>"
    static let voice: AVSpeechSynthesisVoice? = {
        let all = AVSpeechSynthesisVoice.speechVoices()
        if let n = UserDefaults.standard.string(forKey: "voiceName"),
           let v = all.first(where: { $0.name.lowercased() == n.lowercased() || $0.identifier == n }) { return v }
        let region = Locale.current.region?.identifier ?? "US"
        let order = ["Zoe", "Ava", "Allison", "Evan", "Nicky", "Samantha", "Catherine", "Karen", "Aaron", "Gordon"]
        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int, Int) {
            let q = v.quality == .premium ? 3 : (v.quality == .enhanced ? 2 : 1)
            let sameRegion = v.language.hasSuffix("-" + region) ? 1 : 0
            return (-q, -sameRegion, order.firstIndex(of: v.name) ?? 99)
        }
        return all.filter { $0.language.hasPrefix("en") && order.contains($0.name) || $0.quality != .default && $0.language.hasPrefix("en") }
            .min { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    func speak(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice
        u.rate = 0.53
        u.postUtteranceDelay = 0.05
        pending += 1
        synth.speak(u)
    }

    func stop() {
        pending = 0
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.pending > 0 else { return }
            self.pending -= 1
            if self.pending == 0 { self.onIdle?() }
        }
    }
}

// MARK: - Conversation controller

@MainActor
final class VoiceController {
    private enum Phase { case off, wake, query, thinking, speaking }

    private let model: SearchModel
    private let listener = AudioListener()
    private let tts = SpeechOut()
    private var phase = Phase.off
    private var bag = Set<AnyCancellable>()
    private var activity: NSObjectProtocol?

    // current spoken turn
    private var turnActive = false
    private var streamDone = false
    private var spokenMsg: UUID?
    private var spokenCount = 0
    private var apologised = false

    var showAI: () -> Void = {}

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "voiceEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceEnabled") }
    }

    init(model: SearchModel) {
        self.model = model

        listener.onLevel = { [weak self] l in Task { @MainActor in self?.model.voiceLevel = l } }
        listener.onSpeechStart = { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .query else { return }
                self.model.voiceState = .capturing
            }
        }
        listener.onSpeechEnd = { [weak self] in
            Task { @MainActor in
                guard let self, self.phase == .query, self.model.voiceState == .capturing else { return }
                self.model.voiceState = .thinking                  // transcribing the final text
            }
        }
        listener.onWake = { [weak self] rest in Task { @MainActor in self?.wake(rest) } }
        listener.onPartial = { [weak self] t in
            Task { @MainActor in
                guard let self, self.phase == .query else { return }
                self.model.aiInput = t
            }
        }
        listener.onFinal = { [weak self] t in Task { @MainActor in self?.heard(t) } }
        tts.onIdle = { [weak self] in self?.speechIdle() }
        model.$chat.sink { [weak self] chat in self?.chatChanged(chat) }.store(in: &bag)
        // the mic stays live exactly as long as F.R.I.D.A.Y AI is open, however it was opened
        model.$mode.removeDuplicates().sink { [weak self] mode in
            if mode == .ai { self?.aiOpened() } else { self?.aiClosed() }
        }.store(in: &bag)
        model.onVoiceStop = { [weak self] in self?.endConversation() }
    }

    // MARK: lifecycle

    func start() {
        guard Self.enabled, phase == .off else { return }
        Task {
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
            guard mic, speech else {
                model.voiceError = mic ? "Speech Recognition access was denied (System Settings → Privacy & Security)"
                                       : "Microphone access was denied (System Settings → Privacy & Security)"
                model.voiceState = .off
                return
            }
            // accurate local Whisper for the final text; Apple's recogniser still gives the instant wake + live words
            Task {
                let ok = await WhisperServer.shared.start { [weak self] msg in Task { @MainActor in self?.model.voiceEngine = msg } }
                model.voiceEngine = ok ? "Whisper (base.en, on-device)" : "Apple on-device (Whisper unavailable)"
            }
            do { try listener.start() } catch {
                model.voiceError = error.localizedDescription
                model.voiceState = .off
                return
            }
            model.voiceError = nil
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Listening for “Friday”")
            phase = .wake
            listener.setMode(.wake)
            model.voiceState = .idle
        }
    }

    func stop() {
        listener.stop()
        WhisperServer.shared.stop()
        tts.stop()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        phase = .off
        model.voiceState = .off
    }

    /// Speak a one-off message (upgrade ready, etc.) if voice is on.
    func announce(_ text: String) {
        guard phase != .off, !tts.isSpeaking else { return }
        tts.speak(SpeakText.clean(text))
    }

    // MARK: conversation

    /// AI mode opened by keyboard (or any other way): start listening right away, no wake word needed.
    private func aiOpened() {
        guard phase == .wake else { return }
        phase = .query
        listener.setMode(.query)
        model.voiceState = .listening
    }

    private func aiClosed() {
        guard phase != .wake, phase != .off else { return }
        endConversation()
    }

    private func wake(_ rest: String) {
        guard phase == .wake else { return }
        Zing.play()
        phase = .query
        listener.setMode(.query)          // from here on, whatever you say next is the request (no wake word needed)
        showAI()
        model.aiInput = rest
        model.voiceState = .capturing
    }

    private func heard(_ raw: String) {
        guard phase == .query else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {                                    // only "Friday" / noise: just keep listening
            model.voiceState = .listening
            return
        }
        phase = .thinking
        listener.setMode(.paused)
        turnActive = true
        streamDone = false
        spokenMsg = nil
        spokenCount = 0
        apologised = false
        model.voiceState = .thinking
        model.submitVoice(text)
    }

    /// Streams the reply out loud sentence by sentence as it arrives.
    private func chatChanged(_ chat: [ChatMessage]) {
        guard turnActive, let m = chat.last, m.role == "assistant" else { return }
        if spokenMsg != m.id { spokenMsg = m.id; spokenCount = 0 }

        let failed = m.text.hasPrefix("OpenRouter error") || m.text.hasPrefix("Claude Code") || m.text.hasPrefix("Set your OpenRouter")
        if failed {
            if !m.streaming, !apologised {
                apologised = true
                say("Sorry, I couldn't reach the AI service.")
                streamDone = true
            }
            return
        }

        let clean = SpeakText.clean(m.text)
        let rest = String(clean.dropFirst(spokenCount))
        if let sentence = SpeakText.nextSentence(in: rest) {
            say(sentence)
            spokenCount += sentence.count
            chatChanged(chat)                                // there may be more complete sentences waiting
            return
        }
        if !m.streaming {
            let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { say(tail) }
            spokenCount = clean.count
            streamDone = true
            if !tts.isSpeaking { finishTurn() }
        }
    }

    private func say(_ text: String) {
        phase = .speaking
        model.voiceState = .speaking
        tts.speak(text)
    }

    private func speechIdle() {
        if streamDone { finishTurn() }
    }

    /// The reply is done: keep the conversation open for a follow-up without needing the wake word.
    private func finishTurn() {
        guard turnActive else { return }
        turnActive = false
        streamDone = false
        phase = .query
        model.voiceState = .listening
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)          // let the speaker tail die out
            if phase == .query { listener.setMode(.query) }
        }
    }

    /// Back to waiting for "Friday" (Esc, or the AI panel closing).
    func endConversation() {
        tts.stop()
        turnActive = false
        guard phase != .off else { return }
        phase = .wake
        listener.setMode(.wake)
        model.voiceState = .idle
    }
}

// MARK: - UI

struct VoiceIndicator: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        switch model.voiceState {
        case .off:
            EmptyView()
        case .idle:
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").font(.system(size: 11))
                if model.mode == .ai { Text("Say “Friday”").font(.system(size: 12)) }
            }
            .foregroundStyle(Color.secondary.opacity(0.7))
            .help("Listening for “Friday” (on-device)")
        default:
            HStack(spacing: 8) {
                bars
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
        switch model.voiceState {
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        default: return ""
        }
    }

    private var bars: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(model.voiceState == .capturing ? Color.accentColor : Color.primary.opacity(0.55))
                        .frame(width: 3, height: height(i, t))
                }
            }
            .frame(height: 22)
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        let wave = 0.5 + 0.5 * sin(t * 9 + Double(i) * 1.3)
        switch model.voiceState {
        case .capturing: return 4 + 17 * CGFloat(model.voiceLevel) * CGFloat(0.45 + 0.55 * wave)
        case .speaking: return 5 + 13 * CGFloat(wave)
        case .thinking: return 4 + 6 * CGFloat(0.5 + 0.5 * sin(t * 4 + Double(i) * 0.8))
        default: return 5
        }
    }
}
