import Foundation
import UIKit
import Vision

struct NameProbeResult {
    var name: String?
    var detail: String
    var trace: [String] = []
    var captureMS: Double = 0
    var workMS: Double = 0
}
final class ProfileNameReader {
    static let shared = ProfileNameReader()
    private let queue = DispatchQueue(label: "TamaiOS.disposable-name-reader", qos: .utility)
    func read(emu: Emulator, key: String, completion: @escaping (NameProbeResult) -> Void) {
        queue.async {
            let start = ProcessInfo.processInfo.systemUptime
            let captureStart = start
            guard let seed = emu.withCore({ tg_name_seed_capture($0) }) ?? nil else {
                DispatchQueue.main.async { completion(NameProbeResult(name: nil, detail: "Could not capture live snapshot")) }; return
            }
            let captureMS = (ProcessInfo.processInfo.systemUptime - captureStart) * 1000
            defer { tg_name_seed_destroy(seed) }
            let owner = self.text(seed, kind: 0)
            let identity = self.text(seed, kind: 1)
            var result = NameProbeResult(name: nil, detail: "Profile name could not be verified", captureMS: captureMS)
            guard key.hasSuffix("." + identity), NameRecognitionPolicy.normalized(owner).count >= 2 else {
                result.detail = "Snapshot identity changed or owner header was unavailable"
                let finished = result
                DispatchQueue.main.async { completion(finished) }; return
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            // Every strategy starts from the SAME seed, not the previous strategy's changed state.
            // C backs out toward Home on the disposable copy; OCR rejects incorrect destination pages.
            for backs in [8, 4, 2, 1, 0] {
                if ProcessInfo.processInfo.systemUptime >= deadline { result.detail = "Probe reached its time budget"; break }
                var attemptTrace: [String] = []
                let found = autoreleasepool {
                    self.attempt(seed: seed, backs: backs, owner: owner, deadline: deadline, trace: &attemptTrace)
                }
                result.trace += attemptTrace
                if let found { result.name = found; result.detail = "Two matching profile OCR reads with the owner header verified"; break }
            }
            result.workMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            result.trace = Array(result.trace.suffix(12))
            let finished = result
            DispatchQueue.main.async { completion(finished) }
        }
    }
    private func text(_ seed: OpaquePointer, kind: Int32) -> String {
        var p: UnsafeMutablePointer<UInt8>? = nil
        var n = 0
        tg_name_seed_text(seed, kind, &p, &n)
        guard let p else { return "" }
        defer { tg_free(p, n) }
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }
    private func advance(_ probe: OpaquePointer, seconds: Double, deadline: Double) -> Bool {
        var remaining = seconds
        while remaining > 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            let dt = min(0.05, remaining)
            guard tg_name_probe_step(probe, dt) == 1 else { return false }
            remaining -= dt
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }
    private func tap(_ probe: OpaquePointer, key: Int32, deadline: Double) -> Bool {
        tg_name_probe_press(probe, key)
        return advance(probe, seconds: 0.55, deadline: deadline)
    }
    private func attempt(seed: OpaquePointer, backs: Int, owner: String, deadline: Double, trace: inout [String]) -> String? {
        guard let probe = tg_name_probe_from_seed(seed) else { trace.append("Clone creation failed"); return nil }
        defer { tg_name_probe_destroy(probe) }
        guard advance(probe, seconds: 0.35, deadline: deadline) else { return nil }
        for _ in 0..<backs { guard tap(probe, key: 2, deadline: deadline) else { return nil } }
        guard advance(probe, seconds: 1.25, deadline: deadline) else { return nil }
        for key in [Int32(0), Int32(1), Int32(1)] { guard tap(probe, key: key, deadline: deadline) else { return nil } }
        guard advance(probe, seconds: 0.35, deadline: deadline) else { return nil }
        return agreedProfile(probe, owner: owner, deadline: deadline, trace: &trace)
    }
    private func agreedProfile(_ probe: OpaquePointer, owner: String, deadline: Double, trace: inout [String]) -> String? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        let first = recognizedName(probe, owner: owner, trace: &trace)
        guard first != nil, advance(probe, seconds: 0.25, deadline: deadline) else { return nil }
        let second = recognizedName(probe, owner: owner, trace: &trace)
        return NameRecognitionPolicy.agreed(first, second)
    }
    private func recognizedName(_ probe: OpaquePointer, owner: String, trace: inout [String]) -> String? {
        var rgb = [UInt8](repeating: 0, count: 128 * 128 * 3)
        let ok = rgb.withUnsafeMutableBufferPointer { tg_name_probe_rgb(probe, $0.baseAddress, $0.count) }
        guard ok == 1, let provider = CGDataProvider(data: Data(rgb) as CFData),
              let image = CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 24,
                bytesPerRow: 128 * 3, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let context = CGContext(data: nil, width: 768, height: 768, bitsPerComponent: 8, bytesPerRow: 768 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 768, height: 768))
        guard let enlarged = context.makeImage() else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.customWords = ["Hosinokotchi", "Hoshinokotchi"]
        request.minimumTextHeight = 0.025
        do {
            try VNImageRequestHandler(cgImage: enlarged, options: [:]).perform([request])
            let lines: [ProbeTextLine] = (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return ProbeTextLine(text: candidate.string, confidence: Double(candidate.confidence), midY: Double(observation.boundingBox.midY))
            }
            trace.append("OCR: " + lines.map { $0.text }.joined(separator: " | "))
            return NameRecognitionPolicy.candidate(lines: lines, owner: owner)
        } catch { trace.append("OCR error: " + error.localizedDescription); return nil }
    }
}