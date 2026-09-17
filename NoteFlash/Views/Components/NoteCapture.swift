import SwiftUI
import UIKit
import VisionKit

/// The system document camera: photographs pages of notes, straightening and cropping each one.
struct DocumentScannerView: UIViewControllerRepresentable {
    /// Called with each scanned page as JPEG data, or an empty array if the user cancelled.
    let onFinish: ([Data]) -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([Data]) -> Void

        init(onFinish: @escaping ([Data]) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.85) }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}

/// Small previews of picked photos or scanned pages.
struct ImageThumbnailStrip: View {
    let images: [Data]
    private let maxShown = 12

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.prefix(maxShown).enumerated()), id: \.offset) { _, data in
                    Thumbnail(data: data)
                }
                if images.count > maxShown {
                    Text("+\(images.count - maxShown)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 58)
                        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 6))
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityHidden(true)
    }

    private struct Thumbnail: View {
        let data: Data
        @State private var image: UIImage?

        var body: some View {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 44, height: 58)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .task {
                image = await ImageNotes.thumbnail(of: data, maxPixels: 160)
            }
        }
    }
}
