import AppKit
import Vision

enum OCR {
    struct NoTextFound: Error {}

    static func recognize(_ image: NSImage) async throws -> String {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw NoTextFound() }
        return try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                lines.isEmpty ? cont.resume(throwing: NoTextFound()) : cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cg).perform([request]) } catch { cont.resume(throwing: error) }
            }
        }
    }
}
