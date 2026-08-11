import AVFoundation
import Vision
import Combine

/// Mirrors update_isbn()'s validation in main_window.py: only accept
/// 13-digit numeric payloads (EAN-13 / ISBN-13 barcodes).
public func isPlausibleISBN13(_ payload: String) -> Bool {
    payload.count == 13 && payload.allSatisfy(\.isNumber)
}

public enum CameraAuthorization: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// Live AVFoundation capture + Vision barcode detection, replacing
/// webcam.py's OpenCV frame grab + pyzbar decode — promoting Phase 0's
/// BarcodeSpike design sketch into real, running code.
///
/// Unlike Phase 0's still-image-only validation (there was no way to
/// exercise a live camera from a headless SwiftPM CLI), this is wired
/// into the actual UI and its authorization/error state is real,
/// observable app state, not a doc-comment claim.
@MainActor
public final class CameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published public private(set) var authorization: CameraAuthorization = .notDetermined
    @Published public private(set) var isRunning = false
    @Published public private(set) var lastDetectedISBN: String?
    @Published public private(set) var errorMessage: String?

    public let session = AVCaptureSession()

    private let output = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "camerascanner.frames")
    private let detectionInterval: TimeInterval = 0.3 // throttle Vision calls to ~3/sec

    public override init() {
        super.init()
    }

    /// Requests camera access if needed, then configures and starts the
    /// capture session. Safe to call repeatedly (e.g. from a toggle).
    public func start() {
        Task {
            let granted = await requestAccess()
            guard granted else { return }
            configureSessionIfNeeded()
            guard !session.isRunning else { return }
            // AVCaptureSession.startRunning() is blocking; run it off the
            // main actor so the UI doesn't freeze while the camera spins up.
            await Task.detached(priority: .userInitiated) { [session] in
                session.startRunning()
            }.value
            isRunning = true
            errorMessage = nil
        }
    }

    public func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        isRunning = false
    }

    private func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorization = .authorized
            return true
        case .restricted:
            authorization = .restricted
            return false
        case .denied:
            authorization = .denied
            return false
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorization = granted ? .authorized : .denied
            return granted
        @unknown default:
            authorization = .denied
            return false
        }
    }

    private func configureSessionIfNeeded() {
        guard session.inputs.isEmpty else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(for: .video) else {
            errorMessage = "No camera device available."
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                errorMessage = "Could not add camera input to capture session."
                return
            }
            session.addInput(input)
        } catch {
            errorMessage = "Could not open camera: \(error.localizedDescription)"
            return
        }

        output.setSampleBufferDelegate(self, queue: processingQueue)
        guard session.canAddOutput(output) else {
            errorMessage = "Could not add video output to capture session."
            return
        }
        session.addOutput(output)
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    // `processingQueue` is serial, and this delegate method is only ever
    // invoked on it, so plain mutation of `lastFrameQueueTimestamp` here
    // (a queue-confined, non-@Published var, not touched from anywhere
    // else) is safe without actor hops or locks.
    nonisolated(unsafe) private var lastFrameQueueTimestamp = Date.distantPast

    nonisolated public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Throttle: Vision on every frame at 30fps is wasted work for a
        // barcode that isn't moving; a human holding a book up to a
        // camera doesn't need sub-100ms responsiveness.
        let now = Date()
        guard now.timeIntervalSince(lastFrameQueueTimestamp) >= detectionInterval else { return }
        lastFrameQueueTimestamp = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectBarcodesRequest { [weak self] request, _ in
            guard let results = request.results as? [VNBarcodeObservation] else { return }
            for observation in results {
                guard let payload = observation.payloadStringValue, isPlausibleISBN13(payload) else { continue }
                Task { @MainActor [weak self] in
                    self?.lastDetectedISBN = payload
                }
                break
            }
        }
        request.symbologies = [.ean13]

        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
    }
}
