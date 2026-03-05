import Foundation
import Flutter
import ARKit
import Vision

class DepthStreamHandler: NSObject, FlutterStreamHandler, ARSessionDelegate {
    private var eventSink: FlutterEventSink?
    private let arSession = ARSession()
    
    // This will hold your YOLO CoreML model
    private var visionModel: VNCoreMLModel?
    
    override init() {
        super.init()
        setupModel()
    }
    
    private func setupModel() {
        // "yolo11n" should match the exact name of your .mlpackage file!
        do {
            let config = MLModelConfiguration()
            let coreMLModel = try yolo11n(configuration: config).model
            visionModel = try VNCoreMLModel(for: coreMLModel)
        } catch {
            print("Failed to load Vision ML model: \(error)")
        }
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = .sceneDepth
        }
        arSession.delegate = self
        arSession.run(configuration)
        
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        arSession.pause()
        return nil
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let sink = eventSink, let visionModel = visionModel else { return }
        
        // 1. Grab the RGB Camera Frame
        let pixelBuffer = frame.capturedImage
        
        // 2. Create a request to run YOLO on this frame
        let request = VNCoreMLRequest(model: visionModel) { [weak self] request, error in
            self?.processYOLOResults(request: request, frame: frame, sink: sink)
        }
        
        // 3. Execute the request (Apple's Neural Engine makes this lightning fast)
        // Orientation .right is standard for portrait iPhone camera feeds
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])
    }
    
    private func processYOLOResults(request: VNRequest, frame: ARFrame, sink: FlutterEventSink) {
        // YOLO outputs VNRecognizedObjectObservation when exported with NMS
        guard let results = request.results as? [VNRecognizedObjectObservation] else { return }
        guard let depthMap = frame.sceneDepth?.depthMap else { return }
        
        for object in results {
            // Get the best label (e.g., "chair")
            guard let topLabel = object.labels.first else { continue }
            
            // Only process objects with a high enough confidence
            if topLabel.confidence < 0.6 { continue }
            
            // Apple Vision coordinates: Origin (0,0) is BOTTOM-LEFT.
            // ARKit Depth map coordinates: Origin (0,0) is TOP-LEFT.
            // We must flip the Y-axis to find the right depth pixel!
            let normalizedX = Float(object.boundingBox.midX)
            let normalizedY = Float(1.0 - object.boundingBox.midY)
            
            // Map the bounding box center to the LiDAR depth map
            if let distanceMeters = getDistance(from: depthMap, atNormalizedX: normalizedX, y: normalizedY) {
                let distanceFeet = distanceMeters * 3.28084
                
                // Send the tiny, lightweight result back to Flutter!
                let data: [String: Any] = [
                    "label": topLabel.identifier,
                    "confidence": topLabel.confidence,
                    "distanceFeet": distanceFeet
                ]
                
                sink(data)
            }
        }
    }
    
    // (This is the exact same distance math function from earlier)
    private func getDistance(from depthMap: CVPixelBuffer, atNormalizedX x: Float, y: Float) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        let pixelX = Int(x * Float(width))
        let pixelY = Int(y * Float(height))
        
        guard pixelX >= 0, pixelX < width, pixelY >= 0, pixelY < height else { return nil }
        
        let baseAddress = CVPixelBufferGetBaseAddress(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let bufferOffset = (pixelY * bytesPerRow) + (pixelX * MemoryLayout<Float32>.stride)
        
        let distanceInMeters = baseAddress!.load(fromByteOffset: bufferOffset, as: Float32.self)
        if distanceInMeters.isNaN || distanceInMeters <= 0.0 { return nil }
        
        return distanceInMeters
    }
}
