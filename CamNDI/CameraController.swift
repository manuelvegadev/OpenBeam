//
//  CameraController.swift
//  Open Beam
//
//  AVCaptureSession setup and video frame delivery.
//

import AVFoundation

/// Pixel format the capture output emits and NDI sends. UYVY is 4:2:2 packed
/// (2 B/px) and roughly halves the bytes we hand to libndi vs BGRA (4 B/px),
/// which also lets SpeedHQ compress more efficiently on the wire.
enum CameraPixelFormat: String {
    case bgra32
    case uyvy422

    var cvType: OSType {
        switch self {
        case .bgra32:  return kCVPixelFormatType_32BGRA
        case .uyvy422: return kCVPixelFormatType_422YpCbCr8
        }
    }
}

final class CameraController: NSObject, @unchecked Sendable {

    private static let pixelFormatDefaultsKey = "OpenBeam.cameraPixelFormat"

    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "com.openbeam.capture", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?
    private(set) var currentDeviceID: String?

    var onFrame: ((CVPixelBuffer) -> Void)?

    private(set) var pixelFormat: CameraPixelFormat

    override init() {
        let raw = UserDefaults.standard.string(forKey: Self.pixelFormatDefaultsKey)
        self.pixelFormat = raw.flatMap(CameraPixelFormat.init(rawValue:)) ?? .bgra32
        super.init()
    }

    static var availableCameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Switch the emitted pixel format at runtime. Persists the choice and
    /// hot-reloads the running output's videoSettings without tearing down
    /// the session.
    func setPixelFormat(_ new: CameraPixelFormat) {
        guard new != pixelFormat else { return }
        pixelFormat = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.pixelFormatDefaultsKey)

        session.beginConfiguration()
        if let output = session.outputs.first as? AVCaptureVideoDataOutput {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: new.cvType
            ]
        }
        session.commitConfiguration()
        print("[Open Beam] Camera pixel format: \(new.rawValue)")
    }

    func start(deviceID: String? = nil) {
        let device: AVCaptureDevice?
        if let deviceID, let specific = AVCaptureDevice(uniqueID: deviceID) {
            device = specific
        } else {
            device = AVCaptureDevice.default(for: .video)
        }

        guard let device else {
            print("[Open Beam] No camera found")
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        // Remove existing input if any
        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
                currentDeviceID = device.uniqueID
            }
        } catch {
            print("[Open Beam] Camera input error: \(error)")
            session.commitConfiguration()
            return
        }

        // Add output only on first start
        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat.cvType
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: outputQueue)

            if session.canAddOutput(output) {
                session.addOutput(output)
            }
        }

        session.commitConfiguration()

        if !session.isRunning {
            session.startRunning()
        }

        print("[Open Beam] Camera started: \(device.localizedName)")
    }

    func switchCamera(deviceID: String) {
        start(deviceID: deviceID)
    }

    func stop() {
        session.stopRunning()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
