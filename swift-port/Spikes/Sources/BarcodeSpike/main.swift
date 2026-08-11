// Spike 4: Vision + AVFoundation barcode/ISBN scanning — design sketch.
//
// Replaces webcam.py's OpenCV frame grab + pyzbar decode with native
// AVFoundation capture + Vision barcode detection, dropping the
// opencv-python / pyzbar / numpy dependencies entirely.
//
// IMPORTANT — this target compiles and its logic can be exercised with a
// still image (see `scan(imageAt:)` below), but a *live* camera session
// cannot be validated from this headless SwiftPM CLI in this session:
// AVFoundation camera access is gated by TCC (Info.plist
// NSCameraUsageDescription + a user consent prompt), which only fires
// for a proper signed .app bundle with a UI event loop, not a bare
// command-line tool. Live-camera validation needs to happen in the real
// SwiftUI app shell (Phase 1), on a machine with a camera, with a human
// present to approve the permission prompt and hold up a barcode.
//
// Run with: swift run BarcodeSpike <path-to-test-image>
// (an image containing an EAN-13 barcode, e.g. a photo of a book's
// barcode, to prove the Vision decode path works end to end.)
//
// Validated in Phase 0 by temporarily swapping the symbology to .qr and
// scanning a CoreImage-generated QR code encoding a 13-digit payload —
// there's no CoreImage EAN-13 generator to synthesize a real one headlessly.
// The full pipeline (image load -> CGImage -> VNDetectBarcodesRequest ->
// payload string) round-tripped correctly; only the symbology enum value
// differs for real EAN-13 barcodes, so this exercises the actual risk
// (the Vision API plumbing), not the barcode format itself.

import Foundation
import Vision
import AppKit // for NSImage -> CGImage in the still-image test path

struct ScanError: Error, CustomStringConvertible {
    let description: String
}

/// Mirrors update_isbn()'s validation in main_window.py: only accept
/// 13-digit numeric payloads (EAN-13 / ISBN-13 barcodes).
func isPlausibleISBN13(_ payload: String) -> Bool {
    payload.count == 13 && payload.allSatisfy(\.isNumber)
}

/// Runs Vision barcode detection against a single image, returning the
/// first plausible ISBN-13 payload found (if any). This is the same
/// Vision call a live AVCaptureVideoDataOutput frame handler would make
/// per-frame — proving the detection logic without needing a camera.
func scan(imageAt path: String) throws -> String? {
    guard let nsImage = NSImage(contentsOfFile: path),
          let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw ScanError(description: "could not load image at \(path)")
    }

    let request = VNDetectBarcodesRequest()
    request.symbologies = [.ean13]

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])

    guard let observations = request.results else { return nil }
    for observation in observations {
        guard let payload = observation.payloadStringValue else { continue }
        if isPlausibleISBN13(payload) {
            return payload
        }
    }
    return nil
}

// --- Sketch of the live-capture shape (not exercised here) ---
//
// final class BarcodeScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
//     private let session = AVCaptureSession()
//     private let onISBN: (String) -> Void
//
//     init?(onISBN: @escaping (String) -> Void) {
//         self.onISBN = onISBN
//         super.init()
//         guard let device = AVCaptureDevice.default(for: .video),
//               let input = try? AVCaptureDeviceInput(device: device),
//               session.canAddInput(input) else { return nil }
//         session.addInput(input)
//         let output = AVCaptureVideoDataOutput()
//         output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "barcode.scan"))
//         guard session.canAddOutput(output) else { return nil }
//         session.addOutput(output)
//     }
//
//     func start() { session.startRunning() }
//     func stop() { session.stopRunning() }
//
//     func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
//         guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
//         let request = VNDetectBarcodesRequest { request, _ in
//             guard let results = request.results as? [VNBarcodeObservation] else { return }
//             for r in results {
//                 if let payload = r.payloadStringValue, isPlausibleISBN13(payload) {
//                     DispatchQueue.main.async { self.onISBN(payload) }
//                 }
//             }
//         }
//         request.symbologies = [.ean13]
//         try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
//     }
// }
//
// This needs NSCameraUsageDescription in the app's Info.plist and runs
// on a background queue with results marshalled back to the main actor
// for SwiftUI state updates — straightforward once inside a real app
// target, which is why it's sketched rather than spiked standalone here.

// --- Drive the still-image test path, if an argument was given ---

let args = CommandLine.arguments
if args.count > 1 {
    let path = args[1]
    print("Scanning \(path) for an EAN-13/ISBN barcode ...")
    do {
        if let isbn = try scan(imageAt: path) {
            print("Found plausible ISBN: \(isbn)")
        } else {
            print("No plausible ISBN-13 barcode found in image.")
        }
    } catch {
        print("Error: \(error)")
        exit(1)
    }
} else {
    print("BarcodeSpike: no test image given.")
    print("Usage: swift run BarcodeSpike <path-to-image-with-ean13-barcode>")
    print("(No camera/TCC-gated live capture is exercised in this headless session —")
    print(" see the comment block above for the live-capture design sketch, and")
    print(" README.md for what needs validating in the real app shell.)")
}
