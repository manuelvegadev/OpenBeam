//
//  CameraController.swift
//  Open Beam
//
//  AVCaptureSession setup and video frame delivery.
//

import AVFoundation

final class CameraController: NSObject, @unchecked Sendable {

    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "com.openbeam.capture", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?
    private(set) var currentDeviceID: String?

    var onFrame: ((CVPixelBuffer) -> Void)?

    static var availableCameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
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
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
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
