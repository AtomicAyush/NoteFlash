import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Photos of notes and pages exported as images (from GoodNotes, for example). They're turned
/// into a PDF, one page per image, so they can be viewed, read with text recognition, and sent
/// to Claude like any other PDF.
nonisolated enum ImageNotes {
    /// Longest side kept for each page; enough for text recognition and Claude.
    private static let maxPixels = 2_400

    static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let utType = UTType(type) else { return false }
        return utType.conforms(to: .image) && CGImageSourceGetCount(source) > 0
    }

    @concurrent
    static func makePDF(from images: [Data]) async -> Data? {
        let document = PDFDocument()
        for data in images {
            guard let image = downscaled(data),
                  let page = PDFPage(image: image, options: [.compressionQuality: 0.8]) else { continue }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0 else { return nil }
        return document.dataRepresentation()
    }

    /// A small preview of an image.
    @concurrent
    static func thumbnail(of data: Data, maxPixels: Int) async -> UIImage? {
        downscaled(data, maxPixels: maxPixels)
    }

    private static func downscaled(_ data: Data, maxPixels: Int = maxPixels) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
