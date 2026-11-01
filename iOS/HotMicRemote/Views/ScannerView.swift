import SessionKit
import SwiftUI
import VisionKit

/// Full-screen QR scanner. Only Hot Mic invites count: the camera will read any code it sees.
struct ScannerSheet: View {
    var onInvite: (JoinInvite) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var wrongCode = false

    private var scannerReady: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if scannerReady {
                QRScanner(onInvite: onInvite, onWrongCode: { wrongCode = true })
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(wrongCode ? "That's not a Hot Mic code." : "Point at the QR code in Hot Mic on the Mac.")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.black.opacity(0.55)))
                    Button("Cancel") { dismiss() }
                        .buttonStyle(BigButtonStyle())
                }
                .padding(20)
            } else {
                unavailable
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "camera.fill").font(.system(size: 44)).foregroundStyle(Color.flame)
            Text("Can't scan here").font(.title2.bold()).foregroundStyle(Color.ink)
            Text(DataScannerViewController.isSupported
                 ? "Hot Mic needs the camera to read the code. Allow it in Settings › Hot Mic, or point the iPhone Camera app at the code instead."
                 : "This device can't scan codes. Point an iPhone's Camera app at the code, or join from Nearby.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.inkSoft)
            Spacer()
            Button("Close") { dismiss() }.buttonStyle(BigButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper.ignoresSafeArea())
    }
}

/// VisionKit's live scanner, QR codes only.
struct QRScanner: UIViewControllerRepresentable {
    var onInvite: (JoinInvite) -> Void
    var onWrongCode: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced,
                                                recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    /// Scanning can only start once the view is on screen.
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: QRScanner
        private var done = false

        init(parent: QRScanner) { self.parent = parent }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            check(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            check([item])
        }

        private func check(_ items: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                guard case let .barcode(code) = item, let text = code.payloadStringValue else { continue }
                if let url = URL(string: text), let invite = JoinInvite(url: url) {
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    parent.onInvite(invite)
                    return
                }
                parent.onWrongCode()
            }
        }
    }
}
