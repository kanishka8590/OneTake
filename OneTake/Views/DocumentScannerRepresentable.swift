import SwiftUI
import VisionKit

enum DocumentScannerError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        "Document camera scanning is not supported on this device."
    }
}

struct DocumentScannerRepresentable: UIViewControllerRepresentable {
    var onScanCompleted: ([UIImage]) -> Void
    var onCancel: () -> Void
    var onError: ((Error) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onScanCompleted: onScanCompleted,
            onCancel: onCancel,
            onError: onError
        )
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard VNDocumentCameraViewController.isSupported else {
            return UIHostingController(
                rootView: DocumentScannerUnsupportedView(onClose: onCancel)
            )
        }

        let controller = VNDocumentCameraViewController()
        controller.modalPresentationStyle = .fullScreen
        controller.view.backgroundColor = .black
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScanCompleted: ([UIImage]) -> Void
        let onCancel: () -> Void
        let onError: ((Error) -> Void)?
        private var didComplete = false

        init(
            onScanCompleted: @escaping ([UIImage]) -> Void,
            onCancel: @escaping () -> Void,
            onError: ((Error) -> Void)?
        ) {
            self.onScanCompleted = onScanCompleted
            self.onCancel = onCancel
            self.onError = onError
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            guard !didComplete else { return }
            didComplete = true
            let count = scan.pageCount
            var images: [UIImage] = []
            images.reserveCapacity(count)
            for i in 0..<count {
                autoreleasepool {
                    let raw = scan.imageOfPage(at: i)
                    images.append(NoticeOCR.normalizedScanImage(raw, maxDimension: 1800))
                }
            }
            controller.delegate = nil
            DispatchQueue.main.async { [onScanCompleted] in
                onScanCompleted(images)
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            guard !didComplete else { return }
            didComplete = true
            controller.delegate = nil
            DispatchQueue.main.async { [onCancel] in
                onCancel()
            }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            guard !didComplete else { return }
            didComplete = true
            controller.delegate = nil
            DispatchQueue.main.async { [onError, onCancel] in
                if let onError {
                    onError(error)
                } else {
                    onCancel()
                }
            }
        }
    }
}

private struct DocumentScannerUnsupportedView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer()

                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.Colors.accent)

                Text("Document Scanner Unavailable")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("Camera document scanning is not supported on this device. You can import a photo, PDF, or text file instead.")
                    .font(Theme.Typography.bodyRegular)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Button("Close", action: onClose)
                    .primaryCapsuleButton()
                    .padding(.horizontal, 36)
                    .padding(.top, 8)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Colors.canvasBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }
}
