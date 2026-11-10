import Foundation
import Vision
import ImageIO

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
var results: [[String: Any]] = []
for row in source["runs"] as? [[String: Any]] ?? [] {
    let observations = row["observations"] as? [[String: Any]] ?? []
    var samples: [[String: Any]] = []
    for (index, item) in observations.enumerated() {
        let action = item["action"] as? Int ?? -1
        guard action % 5 == 0 || item["phase"] != nil || index == observations.count - 1 else { continue }
        var sample: [String: Any] = ["action": action, "frame_fnv32": item["frame_fnv32"] ?? "unknown"]
        for key in ["phase", "target_seconds_after_wake", "interval_completed", "tick_error", "asleep", "dark_return", "stage_raw", "view_raw", "mode_raw", "radio_setup_done", "call_chain"] {
            if let value = item[key] { sample[key] = value }
        }
        do {
            guard let path = item["frame_file"] as? String,
                  let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw NSError(domain: "FixtureOCR", code: 1) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            sample["lines"] = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }.compactMap { observation -> [String: Any]? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return ["text": String(candidate.string.prefix(80)), "confidence": Double(candidate.confidence)]
            }
        } catch { sample["error"] = String(describing: error) }
        samples.append(sample)
    }
    results.append(["firmware": row["firmware"] ?? "unknown", "plan": row["plan"] ?? "unknown", "samples": samples])
}
let report: [String: Any] = ["scope": "OCR observations from fresh CI-only frames; recognition may be wrong and is not firmware-state proof", "runs": results]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
