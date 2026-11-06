import Foundation
import PDFKit
import AppKit
import Vision
import CryptoKit

// Offline page index. Original PDFs remain the authority; OCR text is never an answer key.
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let lane = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 0
let lanes = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4])! : 1
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
for (fileIndex, url) in files.enumerated() where fileIndex % lanes == lane {
    let sourceHash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    guard let document = PDFDocument(url: url) else { throw NSError(domain: "UnreadablePDF", code: 1) }
    let directory = output.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest: [String: Any] = ["source": url.path, "sourceSHA256": sourceHash, "pageCount": document.pageCount,
        "ocrOnlyForIndexing": true, "width": 2400, "recognitionLanguages": ["zh-Hans", "en-US"]]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        .write(to: directory.appendingPathComponent("source.json"), options: .atomic)
    for index in 0..<document.pageCount {
        let dest = directory.appendingPathComponent(String(format: "page-%03d.json", index + 1))
        if let data = try? Data(contentsOf: dest), let cached = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           cached["sourceSHA256"] as? String == sourceHash, cached["error"] == nil { continue }
        try autoreleasepool {
            guard let page = document.page(at: index) else { throw NSError(domain: "MissingPDFPage", code: index + 1) }
            let bounds = page.bounds(for: .mediaBox)
            let image = page.thumbnail(of: NSSize(width: 2400, height: 2400 * bounds.height / bounds.width), for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw NSError(domain: "PDFRender", code: index + 1) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            var record: [String: Any] = ["page": index + 1, "sourceSHA256": sourceHash,
                "pixelWidth": cg.width, "pixelHeight": cg.height]
            do {
                try VNImageRequestHandler(cgImage: cg).perform([request])
                let lines: [[String: Any]] = (request.results ?? []).compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let box = observation.boundingBox
                    return ["text": candidate.string, "confidence": candidate.confidence,
                        "box": [box.minX, box.minY, box.width, box.height]]
                }
                record["lines"] = lines
                record["text"] = lines.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } catch { record["error"] = String(describing: error) }
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: dest, options: .atomic)
        }
        print("Indexed \(url.lastPathComponent) \(index + 1)/\(document.pageCount)")
        fflush(stdout)
    }
}
