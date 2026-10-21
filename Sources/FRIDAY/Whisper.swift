import AVFoundation
import Foundation

/// Local Whisper speech-to-text (whisper.cpp). The bundled `whisper-server` keeps the model in memory and listens on
/// 127.0.0.1 only; audio never leaves the Mac. Used for the accurate final transcript of each utterance.
final class WhisperServer {
    static let shared = WhisperServer()

    static let port = 8178
    static let modelName = "ggml-base.en.bin"
    static let modelURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/FRIDAY/\(modelName)")
    private static let remote = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelName)")!

    private let lock = NSLock()
    private var _ready = false
    private var process: Process?
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return _ready }
    private func setReady(_ v: Bool) { lock.lock(); _ready = v; lock.unlock() }

    static var binary: String? {
        let candidates = [Bundle.main.resourcePath.map { $0 + "/whisper-server" },
                          NSHomeDirectory() + "/Coding/spotai/vendor/whisper.cpp/build/bin/whisper-server"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts (or reuses) the server. `status` reports progress for the menu ("Downloading speech model…").
    func start(status: @escaping (String) -> Void) async -> Bool {
        guard let bin = Self.binary else { status("Whisper not installed"); return false }
        if !FileManager.default.fileExists(atPath: Self.modelURL.path) {
            status("Downloading speech model (148 MB)…")
            try? FileManager.default.createDirectory(at: Self.modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let (tmp, resp) = try? await URLSession.shared.download(from: Self.remote), (resp as? HTTPURLResponse)?.statusCode == 200,
                  (try? FileManager.default.moveItem(at: tmp, to: Self.modelURL)) != nil else { status("Speech model download failed"); return false }
        }
        if await ping() { setReady(true); return true }          // a server from an earlier run is still up

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        let threads = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        p.arguments = ["-m", Self.modelURL.path, "--host", "127.0.0.1", "--port", "\(Self.port)", "-t", "\(threads)",
                       "-l", "en", "-nt", "-nf", "-sns"]          // no timestamps, no slow temperature fallback, no "(music)" tokens
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in self?.setReady(false) }
        guard (try? p.run()) != nil else { status("Couldn't start Whisper"); return false }
        process = p
        for _ in 0..<40 {
            if await ping() { setReady(true); return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        status("Whisper didn't start")
        return false
    }

    func stop() {
        process?.terminate()
        process = nil
        setReady(false)
    }

    private func ping() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/")!)
        req.timeoutInterval = 0.8
        return ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    /// 16 kHz mono float samples -> text (nil on failure).
    func transcribe(_ samples: [Float]) async -> String? {
        guard ready, samples.count > 1600 else { return nil }
        let boundary = "friday-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("temperature", "0.0")
        field("temperature_inc", "0.0")
        field("response_format", "text")
        // no initial prompt on purpose: Whisper parrots prompt text back as "speech" when the audio is quiet
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(Self.wav(samples))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; d.append(Data(bytes: &x, count: MemoryLayout<T>.size)) }
        d.append("RIFF".data(using: .ascii)!); put(UInt32(36 + samples.count * 2)); d.append("WAVEfmt ".data(using: .ascii)!)
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(16000)); put(UInt32(32000)); put(UInt16(2)); put(UInt16(16))
        d.append("data".data(using: .ascii)!); put(UInt32(samples.count * 2))
        for s in samples { put(Int16(max(-1, min(1, s)) * 32767)) }
        return d
    }
}

enum WhisperFilter {
    private static let lone: Set<String> = ["you", "the", "a", "i", "and", "so", "uh", "um", "hmm", "oh"]
    private static let junk: Set<String> = ["you", "thank you", "thanks", "thanks for watching", "thank you for watching", "bye", "bye bye",
                                            "so", "okay", "oh", "uh", "um", "hmm", "the", "i", "a", "and"]

    /// Whisper invents text for noise ("(water splashing)", "Thank you."): drop sound tags and filler-only output.
    static func clean(_ raw: String?, seconds: Double) -> String? {
        guard var t = raw else { return nil }
        t = t.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]|\*[^*]*\*|♪[^♪]*♪|♪"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let plain = t.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
        if lone.contains(plain) { return nil }                       // a lone "you" is never a real request
        if seconds < 1.6, junk.contains(plain) { return nil }
        return t
    }
}

extension WakeWord {
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            prev = cur
        }
        return prev.last ?? 0
    }

    /// "Does this *sound* like it might start with Friday?" Used to decide whether a quiet-mode utterance is worth a
    /// Whisper pass (Apple's recogniser often mishears it: "Priday", "fry day", "Brady").
    static func soundsLikeWake(_ text: String) -> Bool {
        let t = text.lowercased().split(separator: " ").map { $0.filter(\.isLetter) }
        guard !t.isEmpty else { return false }
        var candidates = [t[0]]
        if t.count > 1 { candidates += [t[0] + t[1], t[1]] }
        if t.count > 2 { candidates.append(t[1] + t[2]) }
        return candidates.contains { c in
            c.count >= 3 && (distance(c, "friday") <= 2 || (c.hasPrefix("fr") && distance(c, "friday") <= 3))
        }
    }
}
