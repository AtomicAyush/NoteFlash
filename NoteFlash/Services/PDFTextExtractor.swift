import Foundation
import PDFKit
import UIKit
import Vision

nonisolated enum PDFTextExtractor {
    struct Result: Sendable {
        let text: String
        let pageCount: Int
        let recognizedPageCount: Int
        let pages: [NotePage]
    }

    /// PDFs up to this size are sent to Claude as documents, so scanned pages,
    /// tables, and diagrams are read too. (The API caps requests at 32 MB after base64.)
    static let maxDocumentBytes = 22 * 1024 * 1024

    /// Pages with less selectable text than this are treated as scans and run through OCR.
    private static let minimumPageText = 25

    static func pageCount(of data: Data) -> Int? {
        PDFDocument(data: data)?.pageCount
    }

    /// Pages sampled to decide whether typed pages also hold handwriting.
    private static let handwritingSamplePages = 2

    /// Extracts the PDF's text, using on-device text recognition for scanned pages. PDFs from
    /// note-taking apps (or whose first pages show much more text than they contain) are also
    /// checked for handwriting on every page. `onPage` is called with (pages done, total pages).
    @concurrent
    static func extract(from data: Data, onPage: (@Sendable (Int, Int) -> Void)? = nil) async -> Result? {
        guard let document = PDFDocument(data: data) else { return nil }
        let attributes = document.documentAttributes ?? [:]
        var readsHandwriting = RecognizedText.isFromNoteTakingApp(
            creator: attributes[PDFDocumentAttribute.creatorAttribute] as? String,
            producer: attributes[PDFDocumentAttribute.producerAttribute] as? String
        )
        var sampled = 0
        var pages: [NotePage] = []
        var recognized = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let typed = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var text = typed
            var isRecognized = false
            if typed.count < minimumPageText {
                isRecognized = true
                if let scanned = await recognizeText(on: page), scanned.count > typed.count {
                    text = scanned
                    recognized += 1
                }
            } else if readsHandwriting || sampled < handwritingSamplePages {
                sampled += 1
                if let scanned = await recognizeText(on: page) {
                    if !readsHandwriting, RecognizedText.findsMissingText(typed: typed, recognized: scanned) {
                        readsHandwriting = true
                    }
                    if readsHandwriting {
                        isRecognized = true
                        let merged = RecognizedText.merge(typed: typed, recognized: scanned)
                        if merged != typed {
                            text = merged
                            recognized += 1
                        }
                    }
                }
            }
            // Pages that text recognition couldn't read are kept: Apple Intelligence may still read the image.
            if !text.isEmpty || isRecognized {
                pages.append(NotePage(index: index, text: text, isRecognized: isRecognized))
            }
            onPage?(index + 1, document.pageCount)
        }
        return Result(
            text: pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"),
            pageCount: document.pageCount,
            recognizedPageCount: recognized,
            pages: pages
        )
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
        request.automaticallyDetectsLanguage = true
        guard let observations = try? await request.perform(on: image) else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
