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
    var estimatedDistance: Float = 0
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
    private let maxBufferFrames = 15
    
    // Yeşil Kutu Oranı: %20 - %80 arası (İdeal genişlik)
    private let roiStart: Double = 0.20
    private let roiEnd: Double = 0.80

    func setupARView(_ view: ARView) {
        self.arView = view
        view.session.delegate = self
        let config = ARWorldTrackingConfiguration()
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
        if on { try? device.setTorchModeOn(level: 0.1) }
        device.unlockForConfiguration()
    }

    func setBaseline() {
        // Sadece mesafe uygunsa baseline al
        if debug.estimatedDistance < 0.28 || debug.estimatedDistance > 0.45 {
            guidanceMessage = "Hata: Mesafe 35cm olmalı!"
            return
        }
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
        guard let depthData = frame.sceneDepth else { return }
        let dist = getCenterDistance(from: depthData.depthMap)
        debug.estimatedDistance = dist
        
        // Mesafe rehberi (Kullanıcıya 35cm'ye yönlendirir)
        updateGuidance(dist: dist)
        
        let depthMap = extractROI(from: depthData.depthMap)
        
        if currentState == .capturingBaseline {
            depthFramesBuffer.append(depthMap)
            if depthFramesBuffer.count >= maxBufferFrames {
                baselineDepthMap = averageDepthBuffer()
                isBaselineSet = true
                currentState = .baselineReady
                guidanceMessage = "Zemin Tamam. Objeyi Koyun."
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
        let sX = Int(Double(width) * roiStart), eX = Int(Double(width) * roiEnd)
        let sY = Int(Double(height) * roiStart), eY = Int(Double(height) * roiEnd)
        
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
        guard let baseline = baselineDepthMap, let depthData = frame.sceneDepth else { return }
        
        let depthWidth = Float(CVPixelBufferGetWidth(depthData.depthMap))
        let imageRes = frame.camera.imageResolution
        let scaleX = depthWidth / Float(imageRes.width)
        let fx = frame.camera.intrinsics[0][0] * scaleX
        let fy = frame.camera.intrinsics[1][1] * scaleX

        // 1. Önce tüm farkları hesapla ve gürültüden temizle
        var validDiffs: [Float] = []
        for i in 0..<currentDepth.count {
            let d = baseline[i] - currentDepth[i]
            // Sadece 5mm'den büyük farkları ciddiye al (Masa pürüzlerini eler)
            if d > 0.005 { validDiffs.append(d) }
        }
        
        guard !validDiffs.isEmpty else {
            DispatchQueue.main.async { self.guidanceMessage = "Obje algılanamadı!" }; return
        }

        // 2. Max yüksekliği bul (AirPods için yaklaşık 21-22mm olmalı)
        let maxH = validDiffs.max() ?? 0
        
        var totalAreaM2: Double = 0
        var objectPixels: [Float] = []

        // 3. --- KRİTİK FİLTRE ---
        // Masadaki küçük pürüzleri eliyoruz. Sadece en yüksek noktanın %40'ından daha yüksek
        // ve en az 1cm (0.01m) yüksekliğindeki pikselleri "Alan" olarak sayıyoruz.
        for i in 0..<currentDepth.count {
            let d = baseline[i] - currentDepth[i]
            if d > (maxH * 0.4) && d > 0.008 {
                objectPixels.append(d)
                let z = Double(currentDepth[i])
                let pixelWidthM = z / Double(fx)
                let pixelHeightM = z / Double(fy)
                totalAreaM2 += (pixelWidthM * pixelHeightM)
            }
        }
        
        if objectPixels.count > 50 {
            let area = totalAreaM2 * 10000.0
            let meanH = Double(objectPixels.reduce(0,+) / Float(objectPixels.count)) * 1000.0
            
            DispatchQueue.main.async {
                self.results = MeasurementResult(areaCm2: area, maxHDiffMm: Double(maxH * 1000), meanHDiffMm: meanH)
                self.currentState = .completed
                self.guidanceMessage = "Ölçüm Bitti."
                self.toggleTorch(on: false)
            }
        }
    }

    private func getCenterDistance(from buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let ptr = unsafeBitCast(CVPixelBufferGetBaseAddress(buffer), to: UnsafePointer<Float32>.self)
        return ptr[(height/2) * width + (width/2)]
    }

    private func updateGuidance(dist: Float) {
        if currentState == .completed { return }
        
        let target: Float = 0.35
        let diff = dist - target
        
        if dist < 0.25 {
            guidanceMessage = "Çok Yakın! (Geri Git)"
        } else if dist > 0.45 {
            guidanceMessage = "Çok Uzak! (Yaklaş)"
        } else {
            let cmDiff = Int(abs(diff * 100))
            if cmDiff == 0 {
                guidanceMessage = "Mesafe Mükemmel (35cm)!"
            } else {
                guidanceMessage = "İdeal Mesafedesiniz (~35cm)"
            }
        }
    }
}

// MARK: - UI
struct ContentView: View {
    @StateObject var vm = MeasurementViewModel()
    
    var body: some View {
        ZStack {
            ARContainer(vm: vm).edgesIgnoringSafeArea(.all)
            
            // Yeşil kutu (Kullanıcının beğendiği büyük boy)
            RoundedRectangle(cornerRadius: 20)
                .stroke(vm.isBaselineSet ? Color.green : Color.white.opacity(0.5), lineWidth: 4)
                .frame(width: UIScreen.main.bounds.width * 0.6, height: UIScreen.main.bounds.width * 0.6)
            
            VStack {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Mesafe: \(String(format: "%.2f", vm.debug.estimatedDistance))m")
                        Text(vm.debug.estimatedDistance < 0.30 || vm.debug.estimatedDistance > 0.40 ? "⚠️ Mesafe dışı" : "✅ İdeal mesafe")
                    }
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white).padding()
                    Spacer()
                }
                
                Text(vm.guidanceMessage)
                    .padding().background(Color.black.opacity(0.7)).foregroundColor(.white).cornerRadius(12).padding(.top)
                
                Spacer()
                
                if vm.currentState == .completed {
                    VStack(spacing: 8) {
                        Text("ALAN: \(String(format: "%.1f", vm.results.areaCm2)) cm²").font(.title2).bold()
                        Text("MAX YÜKSEKLİK: \(String(format: "%.1f", vm.results.maxHDiffMm)) mm")
                        Text("ORT. YÜKSEKLİK: \(String(format: "%.1f", vm.results.meanHDiffMm)) mm")
                    }
                    .padding().frame(maxWidth: .infinity).background(Color.blue).foregroundColor(.white).cornerRadius(20).padding()
                }
                
                HStack(spacing: 15) {
                    Button(action: { vm.setBaseline() }) {
                        Text("Zemini Ayarla").bold().frame(maxWidth: .infinity).padding().background(Color.blue).foregroundColor(.white).cornerRadius(12)
                    }
                    Button(action: { vm.scanObject() }) {
                        Text("Objeyi Tara").bold().frame(maxWidth: .infinity).padding().background(vm.isBaselineSet ? Color.orange : Color.gray).foregroundColor(.white).cornerRadius(12)
                    }.disabled(!vm.isBaselineSet)
                    
                    Button(action: { vm.reset() }) {
                        Image(systemName: "arrow.counterclockwise").bold().padding().background(Color.red).foregroundColor(.white).cornerRadius(12)
                    }
                }.padding(.horizontal).padding(.bottom, 40)
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

@main
struct MeasurementApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
        }
    }
}
