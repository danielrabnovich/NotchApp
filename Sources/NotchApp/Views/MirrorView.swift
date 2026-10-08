import AVFoundation
import SwiftUI

/// A mirrored camera preview for a quick look before a call. The camera only runs while this
/// view is on screen, so the green light goes off as soon as the mirror closes.
struct MirrorView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch access {
                case .authorized:
                    CameraPreview()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                case .notDetermined:
                    message("Show yourself before a call", button: "Allow Camera") {
                        AVCaptureDevice.requestAccess(for: .video) { granted in
                            DispatchQueue.main.async { access = granted ? .authorized : .denied }
                        }
                    }
                default:
                    message("Camera access is off for NotchApp", button: "Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { viewModel.mirror = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(8)
            .help("Close mirror")
        }
    }

    private func message(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "web.camera").font(.system(size: 24))
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
    }
}

private struct CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewView { PreviewView() }
    func updateNSView(_ nsView: PreviewView, context: Context) {}
    static func dismantleNSView(_ nsView: PreviewView, coordinator: ()) { nsView.stop() }
}

private final class PreviewView: NSView {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.notchapp.mirror")
    private let preview: AVCaptureVideoPreviewLayer

    override init(frame: NSRect) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
        let session = self.session
        let preview = self.preview
        queue.async {
            session.beginConfiguration()
            session.sessionPreset = .high
            if let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
            session.startRunning()
            DispatchQueue.main.async {
                // Mirror it, like looking in a mirror.
                if let connection = preview.connection, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
    }

    func stop() {
        let session = self.session
        queue.async { session.stopRunning() }
    }
}
