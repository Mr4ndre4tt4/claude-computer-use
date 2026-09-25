import AppKit
import CoreGraphics
import Foundation
import Vision

/// On-device text recognition (Vision framework) for UIs that expose little accessibility:
/// canvases, games, remote desktops, scanned documents. Nothing leaves the Mac.
enum OCR {
    struct Line: Sendable {
        let text: String
        /// Top-left-origin rectangle in the pixels of the image that was recognized.
        let rect: CGRect
        let confidence: Float
    }

    /// The first recognition in a process loads the model (30–80 s on a busy Mac); later ones take
    /// ~0.1 s. Loading starts at launch and the first real request waits for it instead of
    /// starting a second, competing load.
    private static var warmUpTask: Task<Void, Never>?

    static func warmUp() {
        warmUpTask = Task.detached(priority: .utility) {
            let image = NSImage(size: NSSize(width: 160, height: 40))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 160, height: 40).fill()
            ("warm up" as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
            image.unlockFocus()
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                _ = try? await recognizeRaw(cg, languages: ["pt-BR", "en-US"])
            }
        }
    }

    static func recognize(_ image: CGImage, languages: [String] = ["pt-BR", "en-US"], timeout: Double = 120) async throws -> [Line] {
        if let warmUpTask { await warmUpTask.value }
        let lines = try await withThrowingTaskGroup(of: [Line]?.self) { group in
            group.addTask { try await recognizeRaw(image, languages: languages) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let lines else { throw ToolError("Text recognition timed out (the model may still be loading; retry shortly).") }
        // Reading order: rows top to bottom, then left to right.
        return lines.sorted { a, b in
            if abs(a.rect.midY - b.rect.midY) > min(a.rect.height, b.rect.height) * 0.5 { return a.rect.midY < b.rect.midY }
            return a.rect.minX < b.rect.minX
        }
    }

    private static func recognizeRaw(_ image: CGImage, languages: [String]) async throws -> [Line] {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        func toLine(_ text: String, _ box: CGRect, _ confidence: Float) -> Line {
            // Vision boxes are normalized with a bottom-left origin.
            Line(text: text, rect: CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                          width: box.width * width, height: box.height * height),
                 confidence: confidence)
        }
        if #available(macOS 15.0, *) {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
            let observations = try await request.perform(on: image)
            return observations.compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return toLine(candidate.string, observation.boundingBox.cgRect, candidate.confidence)
            }
        }
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return toLine(candidate.string, observation.boundingBox, candidate.confidence)
            }
        }.value
    }
}
