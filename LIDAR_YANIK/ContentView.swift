import SwiftUI
import ARKit
import RealityKit
import Combine
import AVFoundation

// MARK: - Models
struct MeasurementResult {
    var areaCm2: Double = 0
    var maxHDiffMm: Double = 0
    var meanHDiffMm: Double = 0
}

struct DebugInfo {
    var isLidarSupported: Bool = false
    var frameCount: Int = 0
    var estimatedDistance: Float = 0
    var stabilityScore: Float = 0
    var maskPixelCount: Int = 0
}

// MARK: - View Model
class MeasurementViewModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var guidanceMessage: String = "Sistem Hazırlanıyor..."
    @Published var results = MeasurementResult()
    @Published var debug = DebugInfo()
    @Published var isBaselineSet = false
    
    enum AppState { case idle, capturingBaseline, baselineReady, scanningObject, completed }
    @Published var currentState: AppState = .idle
    
    private var arView: ARView?
    private var baselineDepthMap: [Float]?
    private var depthFramesBuffer: [[Float]] = []
    private let maxBufferFrames = 10
    private let roiSize: CGFloat = 0.3
    
    func setupARView(_ view: ARView) {
        self.arView = view
        view.session.delegate = self
        
        let config = ARWorldTrackingConfiguration()
        // LiDAR kontrolü için doğru kontrol yöntemi
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = .sceneDepth
            debug.isLidarSupported = true
        }
        
        view.session.run(config)
        toggleTorch(on: true)
    }
    
    func toggleTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        if on { try? device.setTorchModeOn(level: 0.3) }
        device.unlockForConfiguration()
    }

    func setBaseline() {
        currentState = .capturingBaseline
        depthFramesBuffer.removeAll()
    }
    
    func scanObject() {
        guard isBaselineSet else { return }
        currentState = .scanningObject
        depthFramesBuffer.removeAll()
    }
    
    func reset() {
        isBaselineSet = false
        baselineDepthMap = nil
        results = MeasurementResult()
        currentState = .idle
        toggleTorch(on: true)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let dist = getAverageDistance(from: frame)
        debug.estimatedDistance = dist
        
        // Basit stabilite kontrolü
        debug.stabilityScore = (frame.camera.trackingState == .normal) ? 1.0 : 0.0
        
        updateGuidance(dist: dist)
        
        guard let depthData = frame.sceneDepth else { return }
        let depthMap = extractROI(from: depthData.depthMap)
        
        if currentState == .capturingBaseline {
            depthFramesBuffer.append(depthMap)
            debug.frameCount = depthFramesBuffer.count
            if depthFramesBuffer.count >= maxBufferFrames {
                baselineDepthMap = averageDepthBuffer()
                isBaselineSet = true
                currentState = .baselineReady
                guidanceMessage = "Zemin Kaydedildi. Obje Koyun."
            }
        } else if currentState == .scanningObject {
            depthFramesBuffer.append(depthMap)
            if depthFramesBuffer.count >= maxBufferFrames {
                processComparison(currentDepth: averageDepthBuffer(), frame: frame)
            }
        }
    }

    private func extractROI(from buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let ptr = unsafeBitCast(CVPixelBufferGetBaseAddress(buffer), to: UnsafePointer<Float32>.self)
        
        var points: [Float] = []
        let sX = Int(Double(width) * 0.35), eX = Int(Double(width) * 0.65)
        let sY = Int(Double(height) * 0.35), eY = Int(Double(height) * 0.65)
        
        for y in sY..<eY {
            for x in sX..<eX {
                points.append(ptr[y * width + x])
            }
        }
        return points
    }

    private func averageDepthBuffer() -> [Float] {
        guard !depthFramesBuffer.isEmpty else { return [] }
        let count = depthFramesBuffer[0].count
        var averaged = [Float](repeating: 0, count: count)
        for i in 0..<count {
            averaged[i] = depthFramesBuffer.reduce(0) { $0 + $1[i] } / Float(depthFramesBuffer.count)
        }
        return averaged
    }

    private func processComparison(currentDepth: [Float], frame: ARFrame) {
        guard let baseline = baselineDepthMap else { return }
        var diffs: [Float] = []
        
        for i in 0..<currentDepth.count {
            let d = baseline[i] - currentDepth[i]
            if d > 0.005 && d < 0.5 { diffs.append(d) }
        }
        
        if diffs.count > 100 {
            let maxH = Double(diffs.max() ?? 0) * 1000.0
            let meanH = Double(diffs.reduce(0,+) / Float(diffs.count)) * 1000.0
            
            // Alan hesabı (Fiziksel projeksiyon)
            let f = (frame.camera.intrinsics[0][0] + frame.camera.intrinsics[1][1]) / 2.0
            let pixelSizeM = Double(debug.estimatedDistance / Float(f))
            let area = Double(diffs.count) * (pixelSizeM * pixelSizeM) * 10000.0
            
            DispatchQueue.main.async {
                self.results = MeasurementResult(areaCm2: area, maxHDiffMm: maxH, meanHDiffMm: meanH)
                self.currentState = .completed
                self.toggleTorch(on: false)
                self.guidanceMessage = "İşlem Tamam."
            }
        }
    }

    private func getAverageDistance(from frame: ARFrame) -> Float {
        guard let depth = frame.sceneDepth else { return 0 }
        CVPixelBufferLockBaseAddress(depth.depthMap, .readOnly)
        let ptr = unsafeBitCast(CVPixelBufferGetBaseAddress(depth.depthMap), to: UnsafePointer<Float32>.self)
        let val = ptr[CVPixelBufferGetWidth(depth.depthMap)/2 + (CVPixelBufferGetHeight(depth.depthMap)/2 * CVPixelBufferGetWidth(depth.depthMap))]
        CVPixelBufferUnlockBaseAddress(depth.depthMap, .readOnly)
        return val
    }

    private func updateGuidance(dist: Float) {
        if dist > 0 && dist < 0.25 { guidanceMessage = "Çok Yakın!" }
        else if dist > 0.75 { guidanceMessage = "Çok Uzak!" }
        else if !isBaselineSet { guidanceMessage = "Zemin için hazır." }
    }
}

// MARK: - UI
struct ContentView: View {
    @StateObject var vm = MeasurementViewModel()
    
    var body: some View {
        ZStack {
            ARContainer(vm: vm).edgesIgnoringSafeArea(.all)
            
            // ROI Box
            RoundedRectangle(cornerRadius: 12)
                .stroke(vm.isBaselineSet ? Color.green : Color.white, lineWidth: 3)
                .frame(width: 150, height: 150)
            
            VStack {
                HStack {
                    VStack(alignment: .leading) {
                        Text("LiDAR: \(vm.debug.isLidarSupported ? "OK" : "YOK")")
                        Text("Mesafe: \(String(format: "%.2f", vm.debug.estimatedDistance))m")
                    }.font(.system(size: 12, weight: .bold)).foregroundColor(.white).padding()
                    Spacer()
                }
                
                Text(vm.guidanceMessage)
                    .padding().background(Color.black.opacity(0.6)).foregroundColor(.white).cornerRadius(10)
                
                Spacer()
                
                if vm.currentState == .completed {
                    VStack {
                        Text("ALAN: \(String(format: "%.1f", vm.results.areaCm2)) cm²").bold()
                        Text("MAX YÜKSEKLİK: \(String(format: "%.1f", vm.results.maxHDiffMm)) mm")
                        Text("ORT. YÜKSEKLİK: \(String(format: "%.1f", vm.results.meanHDiffMm)) mm")
                    }
                    .padding().background(Color.blue.opacity(0.8)).foregroundColor(.white).cornerRadius(15).padding()
                }
                
                HStack(spacing: 20) {
                    Button("Set Baseline") { vm.setBaseline() }
                        .padding().background(Color.blue).foregroundColor(.white).cornerRadius(10)
                    
                    Button("Scan Object") { vm.scanObject() }
                        .padding().background(vm.isBaselineSet ? Color.orange : Color.gray).foregroundColor(.white).cornerRadius(10)
                        .disabled(!vm.isBaselineSet)
                    
                    Button("Reset") { vm.reset() }
                        .padding().background(Color.red).foregroundColor(.white).cornerRadius(10)
                }.padding(.bottom, 40)
            }
        }
    }
}

struct ARContainer: UIViewRepresentable {
    let vm: MeasurementViewModel
    func makeUIView(context: Context) -> ARView {
        let v = ARView(frame: .zero)
        vm.setupARView(v)
        return v
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

// MARK: - App Entry (Tek Dosya İçin @main)
@main
struct MeasurementApp: App {
    var body: some SwiftUI.Scene { // 'SwiftUI.' ekleyerek karmaşayı çözdük
        WindowGroup {
            ContentView()
        }
    }
}
