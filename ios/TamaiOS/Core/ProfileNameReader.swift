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
    func read(emu: Emulator, key: String?, spriteURL: URL? = nil, completion: @escaping (NameProbeResult) -> Void) {
        queue.async {
            let start = ProcessInfo.processInfo.systemUptime
            guard let seed = emu.withCore({ tg_name_seed_capture($0) }) ?? nil else {
                DispatchQueue.main.async { completion(NameProbeResult(name: nil, detail: "Could not capture live snapshot")) }; return
            }
            let captureMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let finished = self.process(seed: seed, key: key, start: start, captureMS: captureMS, spriteURL: spriteURL)
            DispatchQueue.main.async { completion(finished) }
        }
    }
    /// Same as `read`, for a device that isn't the one on screen: reads a headless core you own.
    func readNow(handle: OpaquePointer, spriteURL: URL? = nil) -> NameProbeResult {
        let start = ProcessInfo.processInfo.systemUptime
        guard let seed = tg_name_seed_capture(handle) else { return NameProbeResult(name: nil, detail: "Could not capture a snapshot") }
        // a fresh headless copy starts on the home screen, so no backing out is needed (it is tried first)
        return process(seed: seed, key: nil, start: start, captureMS: 0, backsList: [0, 2, 8], budget: 45, spriteURL: spriteURL)
    }
    private func process(seed: OpaquePointer, key: String?, start: Double, captureMS: Double,
                         backsList: [Int] = [8, 4, 2, 0, 12, 1], budget: Double = 20, spriteURL: URL? = nil) -> NameProbeResult {
        defer { tg_name_seed_destroy(seed) }
        let owner = self.text(seed, kind: 0)
        let identity = self.text(seed, kind: 1)
        var result = NameProbeResult(name: nil, detail: "Profile name could not be verified", captureMS: captureMS)
        guard key.map({ $0.hasSuffix("." + identity) }) ?? true, NameRecognitionPolicy.normalized(owner).count >= 2 else {
            result.detail = "Snapshot identity changed or owner header was unavailable"
            return result
        }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        // Every strategy starts from the SAME seed, not the previous strategy's changed state.
        // C backs out toward Home on the disposable copy; OCR rejects incorrect destination pages.
        var lastSprite: UIImage?
        // The best strategy first at a quick pace; if that doesn't produce a name, everything again at the careful pace.
        let plan: [(Int, Bool)] = (backsList.first.map { [($0, true)] } ?? []) + backsList.map { ($0, false) }
        for (backs, fast) in plan {
            if ProcessInfo.processInfo.systemUptime >= deadline { result.detail = "Probe reached its time budget"; break }
            var attemptTrace: [String] = []
            let found = autoreleasepool {
                self.attempt(seed: seed, backs: backs, fast: fast, owner: owner, deadline: deadline, trace: &attemptTrace, sprite: &lastSprite)
            }
            result.trace += attemptTrace
            if let found {
                if let spriteURL, let img = lastSprite, let png = img.pngData() {
                    try? png.write(to: spriteURL, options: .atomic)
                    DispatchQueue.main.async { AppModel.current?.objectWillChange.send() }
                }
                result.name = found; result.detail = "Two matching profile OCR reads with the owner header verified"; break }
        }
        result.workMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        result.trace = Array(result.trace.suffix(12))
        return result
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
    private func tap(_ probe: OpaquePointer, key: Int32, fast: Bool, deadline: Double) -> Bool {
        tg_name_probe_press(probe, key)
        return advance(probe, seconds: fast ? 0.3 : 0.55, deadline: deadline)
    }
    private func attempt(seed: OpaquePointer, backs: Int, fast: Bool, owner: String, deadline: Double, trace: inout [String], sprite: inout UIImage?) -> String? {
        guard let probe = tg_name_probe_from_seed(seed) else { trace.append("Clone creation failed"); return nil }
        defer { tg_name_probe_destroy(probe) }
        guard advance(probe, seconds: backs >= 12 || backs == 1 ? 3.0 : (fast ? 0.2 : 0.35), deadline: deadline) else { return nil }
        for _ in 0..<backs { guard tap(probe, key: 2, fast: fast, deadline: deadline) else { return nil } }
        guard advance(probe, seconds: fast ? 0.8 : 1.25, deadline: deadline) else { return nil }
        for key in [Int32(0), Int32(1), Int32(1)] { guard tap(probe, key: key, fast: fast, deadline: deadline) else { return nil } }
        guard advance(probe, seconds: fast ? 0.25 : 0.35, deadline: deadline) else { return nil }
        let name = agreedProfile(probe, owner: owner, deadline: deadline, trace: &trace)
        if name != nil {
            var rgb = [UInt8](repeating: 0, count: 128 * 128 * 3)
            if rgb.withUnsafeMutableBufferPointer({ tg_name_probe_rgb(probe, $0.baseAddress, $0.count) }) == 1 { sprite = ProfileNameReader.cropSprite(rgb) }
        }
        return name
    }
    /// The Tama's picture on the profile page: the non-white part of the area above its name, on a transparent background.
    static func cropSprite(_ rgb: [UInt8]) -> UIImage? {
        let x0 = 14, x1 = 74, y0 = 34, y1 = 78
        let W = x1 - x0, H = y1 - y0
        func white(_ x: Int, _ y: Int) -> Bool {
            let i = (y * 128 + x) * 3
            return rgb[i] >= 232 && rgb[i + 1] >= 232 && rgb[i + 2] >= 232
        }
        // Background = near-white that connects to the edge of the area. Light parts inside the Tama
        // (face, eye shine) are not connected to the edge, so they stay solid instead of going see-through.
        var bg = [Bool](repeating: false, count: W * H)
        var stack: [Int] = []
        func seed(_ x: Int, _ y: Int) { let k = y * W + x; if !bg[k], white(x0 + x, y0 + y) { bg[k] = true; stack.append(k) } }
        for x in 0..<W { seed(x, 0); seed(x, H - 1) }
        for y in 0..<H { seed(0, y); seed(W - 1, y) }
        while let k = stack.popLast() {
            let x = k % W, y = k / W
            if x > 0 { seed(x - 1, y) }
            if x < W - 1 { seed(x + 1, y) }
            if y > 0 { seed(x, y - 1) }
            if y < H - 1 { seed(x, y + 1) }
        }
        var minX = W, maxX = -1, minY = H, maxY = -1
        for y in 0..<H { for x in 0..<W where !bg[y * W + x] {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX > minX, maxY > minY, maxX - minX < 60, maxY - minY < 44 else { return nil }
        let w = maxX - minX + 1, h = maxY - minY + 1
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w where !bg[(minY + y) * W + (minX + x)] {
            let i = ((y0 + minY + y) * 128 + (x0 + minX + x)) * 3, o = (y * w + x) * 4
            px[o] = rgb[i]; px[o + 1] = rgb[i + 1]; px[o + 2] = rgb[i + 2]; px[o + 3] = 255
        } }
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
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