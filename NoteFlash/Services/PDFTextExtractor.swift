import Foundation
import PDFKit
import UIKit
import Vision

nonisolated enum PDFTextExtractor {
    struct Result: Sendable {
        let text: String
        let pageCount: Int
        let recognizedPageCount: Int
    }

    /// PDFs up to this size are sent to Claude as documents, so scanned pages,
    /// tables, and diagrams are read too. (The API caps requests at 32 MB after base64.)
    static let maxDocumentBytes = 22 * 1024 * 1024

    /// Pages with less selectable text than this are treated as scans and run through OCR.
    private static let minimumPageText = 25

    static func pageCount(of data: Data) -> Int? {
        PDFDocument(data: data)?.pageCount
    }

    /// Extracts the PDF's text, using on-device text recognition for scanned pages.
    @concurrent
    static func extract(from data: Data) async -> Result? {
        guard let document = PDFDocument(data: data) else { return nil }
        var pages: [String] = []
        var recognized = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count < minimumPageText, let scanned = await recognizeText(on: page), scanned.count > text.count {
                text = scanned
                recognized += 1
            }
            if !text.isEmpty { pages.append(text) }
        }
        return Result(text: pages.joined(separator: "\n\n"), pageCount: document.pageCount, recognizedPageCount: recognized)
    }

    private static func recognizeText(on page: PDFPage) async -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let longestSide = max(bounds.width, bounds.height)
        guard longestSide > 0 else { return nil }
        let scale = min(2200 / longestSide, 3)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let image = page.thumbnail(of: size, for: .mediaBox).cgImage else { return nil }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: image) else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
