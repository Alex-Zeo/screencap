import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GIFExporter {
    enum ExportError: LocalizedError {
        case emptyRecording, cannotCreate, cannotFinish

        var errorDescription: String? {
            switch self {
            case .emptyRecording: return "The recording contains no video."
            case .cannotCreate: return "Could not create the GIF file."
            case .cannotFinish: return "Could not finish writing the GIF."
            }
        }
    }

    /// Decode one frame at a time off the main actor. Bound size and frame rate for useful GIFs.
    static func export(_ video: URL, to output: URL) async throws -> NSImage {
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 35 else { throw ExportError.emptyRecording }
        return try await Task.detached(priority: .userInitiated) {
            let frameCount = max(2, Int(ceil(duration * 15)))
            let delay = duration / Double(frameCount)
            let partial = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).gif")
            defer { try? FileManager.default.removeItem(at: partial) }
            guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.gif.identifier as CFString,
                                                                     frameCount, nil) else { throw ExportError.cannotCreate }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                                  kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 960, height: 960)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            for frame in 0..<frameCount {
                try Task.checkCancellation()
                try autoreleasepool {
                    let time = CMTime(seconds: Double(frame) * delay, preferredTimescale: 600)
                    let image = try generator.copyCGImage(at: time, actualTime: nil)
                    CGImageDestinationAddImage(destination, image, frameProperties)
                }
            }
            guard CGImageDestinationFinalize(destination) else { throw ExportError.cannotFinish }
            try FileManager.default.moveItem(at: partial, to: output)
            guard let image = NSImage(contentsOf: output) else { throw ExportError.cannotFinish }
            return image
        }.value
    }
}
