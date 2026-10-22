import SwiftUI
import ARKit
import RealityKit
import UIKit
import simd

/// RoomPlan의 분류 결과와 무관하게 LiDAR 깊이점으로 측정한 새 OBB 가구.
struct MeasuredFurnitureDraft: Identifiable {
    let id: String
    let dimensions: SIMD3<Float>
    let colorHex: String

    init(id: String = "lidar_\(UUID().uuidString.lowercased())",
         dimensions: SIMD3<Float>,
         colorHex: String) {
        self.id = id
        self.dimensions = dimensions
        self.colorHex = colorHex
    }
}

private struct FurnitureColorChoice: Identifiable {
    let id: String
    let name: String
    let color: Color

    static let palette: [FurnitureColorChoice] = [
        .init(id: "#F4F1E8", name: "화이트", color: Color(red: 0.96, green: 0.95, blue: 0.91)),
        .init(id: "#D8C7A7", name: "베이지", color: Color(red: 0.85, green: 0.78, blue: 0.65)),
        .init(id: "#B8875A", name: "우드", color: Color(red: 0.72, green: 0.53, blue: 0.35)),
        .init(id: "#A9ADB4", name: "그레이", color: Color(red: 0.66, green: 0.68, blue: 0.71)),
        .init(id: "#4D5057", name: "차콜", color: Color(red: 0.30, green: 0.31, blue: 0.34)),
        .init(id: "#AFC9ED", name: "블루", color: Color(red: 0.69, green: 0.79, blue: 0.93)),
        .init(id: "#EDB9C7", name: "핑크", color: Color(red: 0.93, green: 0.73, blue: 0.78)),
    ]
}

struct LiDARFurnitureScanView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = LiDARFurnitureScanner()
    @State private var widthCM = ""
    @State private var depthCM = ""
    @State private var heightCM = ""
    @State private var selectedColor = FurnitureColorChoice.palette[2]
    @State private var showEditor = false

    let onAdd: (MeasuredFurnitureDraft) -> Void

    var body: some View {
        ZStack {
            LiDARCameraView(scanner: scanner)
                .ignoresSafeArea()

            if !showEditor {
                scanOverlay
            } else {
                measurementEditor
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: scanner.measurement) { _, measurement in
            guard let measurement else { return }
            widthCM = Self.centimeterText(measurement.dimensions.x)
            heightCM = Self.centimeterText(measurement.dimensions.y)
            depthCM = Self.centimeterText(measurement.dimensions.z)
            withAnimation(.easeInOut(duration: 0.2)) { showEditor = true }
        }
        .onDisappear { scanner.stopSession() }
    }

    private var scanOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                Text("가구 치수 측정")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Color.clear.frame(width: 42, height: 42)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            Spacer()

            RoundedRectangle(cornerRadius: 24)
                .stroke(scanner.isCollecting ? Color.green : Color.white, style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                .frame(width: 270, height: 330)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: scanner.isCollecting ? "viewfinder.circle.fill" : "viewfinder")
                            .font(.system(size: 34, weight: .light))
                        Text(scanner.isCollecting ? "가구를 중심에 두고 천천히 둘러보세요" : "측정할 가구를 이 안에 맞춰주세요")
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .shadow(radius: 5)
                }

            Spacer()

            VStack(spacing: 12) {
                if let error = scanner.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else {
                    Text(scanner.statusText)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                }

                Button {
                    if scanner.isCollecting {
                        scanner.finishMeasurement()
                    } else {
                        scanner.startMeasurement()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if scanner.isProcessing { ProgressView().tint(.white) }
                        Image(systemName: scanner.isCollecting ? "checkmark" : "sensor.tag.radiowaves.forward")
                        Text(scanner.isCollecting ? "측정 완료" : "측정 시작")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(scanner.isCollecting ? Color.green : Color.voBlue, in: Capsule())
                }
                .disabled(!scanner.isSupported || scanner.isProcessing)

                Button("직접 치수 입력") {
                    widthCM = "60"
                    depthCM = "60"
                    heightCM = "60"
                    withAnimation(.easeInOut(duration: 0.2)) { showEditor = true }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .padding(.top, 18)
            .background(.ultraThinMaterial)
        }
    }

    private var measurementEditor: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("측정 결과")
                            .font(.title2.bold())
                        Text("오차가 있으면 숫자를 바로 수정해주세요")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showEditor = false; scanner.resetMeasurement() } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .background(Color(.secondarySystemBackground), in: Circle())
                    }
                }

                HStack(spacing: 10) {
                    dimensionField(title: "가로", text: $widthCM)
                    dimensionField(title: "깊이", text: $depthCM)
                    dimensionField(title: "높이", text: $heightCM)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("박스 색상")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 0) {
                        ForEach(FurnitureColorChoice.palette) { choice in
                            Button {
                                selectedColor = choice
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if selectedColor.id == choice.id {
                                            Circle().stroke(Color.voBlue, lineWidth: 3)
                                                .padding(-4)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.name)
                        }
                    }
                }

                Button("내 방에 추가") { addFurniture() }
                    .buttonStyle(VOFilledButtonStyle())
                    .disabled(parsedDimensions == nil)

                Button("취소") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(24)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 26))
            .padding(.horizontal, 20)
        }
    }

    private func dimensionField(title: String, text: Binding<String>) -> some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.headline.monospacedDigit())
                Text("cm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity)
    }

    private var parsedDimensions: SIMD3<Float>? {
        func meters(_ value: String) -> Float? {
            let normalized = value.replacingOccurrences(of: ",", with: ".")
            guard let centimeters = Float(normalized), centimeters >= 3, centimeters <= 500 else { return nil }
            return centimeters / 100
        }
        guard let width = meters(widthCM), let depth = meters(depthCM), let height = meters(heightCM) else { return nil }
        return SIMD3(width, height, depth)
    }

    private func addFurniture() {
        guard let dimensions = parsedDimensions else { return }
        onAdd(MeasuredFurnitureDraft(dimensions: dimensions, colorHex: selectedColor.id))
        dismiss()
    }

    private static func centimeterText(_ meters: Float) -> String {
        String(format: "%.1f", meters * 100)
            .replacingOccurrences(of: ".0", with: "")
    }
}

// MARK: - ARKit LiDAR point collection

private struct LiDARMeasurement: Equatable {
    let dimensions: SIMD3<Float>
    let pointCount: Int
}

private final class LiDARFurnitureScanner: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var isSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    @Published private(set) var isCollecting = false
    @Published private(set) var isProcessing = false
    @Published private(set) var collectedPointCount = 0
    @Published private(set) var measurement: LiDARMeasurement?
    @Published var errorMessage: String?

    weak var session: ARSession?
    var viewportSize: CGSize = .zero
    var interfaceOrientation: UIInterfaceOrientation = .portrait

    private let lock = NSLock()
    private var points: [SIMD3<Float>] = []
    private var targetSeed: SIMD3<Float>?
    private var lastSampleTime: TimeInterval = 0
    private let maximumPointCount = 70_000

    var statusText: String {
        if !isSupported { return "이 기기는 LiDAR 깊이 측정을 지원하지 않아요" }
        if isProcessing { return "모은 깊이점으로 치수를 계산하고 있어요" }
        if isCollecting { return "수집된 깊이점 \(collectedPointCount.formatted())개" }
        return "벽과 조금 떨어뜨리면 더 정확하게 측정돼요"
    }

    func attach(session: ARSession) {
        self.session = session
        session.delegate = self

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        if isSupported {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func startMeasurement() {
        guard isSupported else {
            errorMessage = "LiDAR가 있는 iPhone 또는 iPad에서 측정할 수 있어요."
            return
        }
        lock.lock()
        points.removeAll(keepingCapacity: true)
        targetSeed = nil
        lastSampleTime = 0
        lock.unlock()
        collectedPointCount = 0
        measurement = nil
        errorMessage = nil
        isCollecting = true
    }

    func finishMeasurement() {
        guard isCollecting else { return }
        isCollecting = false
        isProcessing = true

        lock.lock()
        let snapshot = points
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.makeMeasurement(from: snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false
                switch result {
                case .success(let measurement):
                    self.measurement = measurement
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func resetMeasurement() {
        measurement = nil
        errorMessage = nil
        collectedPointCount = 0
    }

    func stopSession() {
        isCollecting = false
        session?.pause()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isCollecting,
              frame.timestamp - lastSampleTime >= 0.10,
              viewportSize.width > 1,
              viewportSize.height > 1,
              case .normal = frame.camera.trackingState,
              let depthData = frame.smoothedSceneDepth else { return }

        lastSampleTime = frame.timestamp
        let newPoints = sampleTargetPoints(frame: frame, depthData: depthData)
        guard !newPoints.isEmpty else { return }

        lock.lock()
        if targetSeed == nil {
            targetSeed = newPoints[newPoints.count / 2]
        }
        let seed = targetSeed
        let filtered = newPoints.filter { point in
            guard let seed else { return true }
            return simd_distance(point, seed) < 2.5
        }
        let remaining = max(0, maximumPointCount - points.count)
        if remaining > 0 { points.append(contentsOf: filtered.prefix(remaining)) }
        let count = points.count
        lock.unlock()

        DispatchQueue.main.async { [weak self] in self?.collectedPointCount = count }
    }

    private func sampleTargetPoints(frame: ARFrame, depthData: ARDepthData) -> [SIMD3<Float>] {
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let depthValues = depthBase.assumingMemoryBound(to: Float32.self)

        let confidenceValues = confidenceMap.flatMap(CVPixelBufferGetBaseAddress)?.assumingMemoryBound(to: UInt8.self)
        let confidenceStride = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let transform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewportSize).inverted()
        let imageResolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        struct Sample {
            let imagePoint: CGPoint
            let depth: Float
        }
        var samples: [Sample] = []
        var centerDepths: [Float] = []

        // 화면 중앙 가이드와 같은 비율. 뷰 좌표를 카메라 이미지 좌표로 변환해 회전에도 대응한다.
        let columns = 30
        let rows = 28
        for row in 0..<rows {
            for column in 0..<columns {
                let nx = 0.20 + (Float(column) + 0.5) / Float(columns) * 0.60
                let ny = 0.30 + (Float(row) + 0.5) / Float(rows) * 0.40
                let imagePoint = CGPoint(x: CGFloat(nx), y: CGFloat(ny)).applying(transform)
                guard (0..<1).contains(imagePoint.x), (0..<1).contains(imagePoint.y) else { continue }

                let dx = min(max(Int(imagePoint.x * CGFloat(depthWidth)), 0), depthWidth - 1)
                let dy = min(max(Int(imagePoint.y * CGFloat(depthHeight)), 0), depthHeight - 1)
                if let confidenceValues, confidenceValues[dy * confidenceStride + dx] == 0 { continue }
                let depth = depthValues[dy * depthStride + dx]
                guard depth.isFinite, depth > 0.18, depth < 5 else { continue }
                samples.append(Sample(imagePoint: imagePoint, depth: depth))
                if (0.43...0.57).contains(nx), (0.44...0.56).contains(ny) {
                    centerDepths.append(depth)
                }
            }
        }

        guard let targetDepth = Self.percentile(centerDepths, 0.5) else { return [] }
        let minimumDepth = max(0.18, targetDepth - 0.65)
        let maximumDepth = targetDepth + 0.38

        return samples.compactMap { sample in
            guard sample.depth >= minimumDepth, sample.depth <= maximumDepth else { return nil }
            let u = Float(sample.imagePoint.x) * Float(imageResolution.width)
            let v = Float(sample.imagePoint.y) * Float(imageResolution.height)
            let cameraPoint = SIMD4<Float>(
                (u - cx) * sample.depth / fx,
                -(v - cy) * sample.depth / fy,
                -sample.depth,
                1
            )
            let world = frame.camera.transform * cameraPoint
            return SIMD3(world.x, world.y, world.z)
        }
    }

    private enum MeasurementError: LocalizedError {
        case tooFewPoints
        case invalidSize

        var errorDescription: String? {
            switch self {
            case .tooFewPoints:
                return "깊이점이 부족해요. 가구를 중앙에 두고 앞·옆면을 조금 더 천천히 비춰주세요."
            case .invalidSize:
                return "가구와 배경을 분리하지 못했어요. 벽에서 조금 떨어뜨린 뒤 다시 측정해주세요."
            }
        }
    }

    private static func makeMeasurement(from rawPoints: [SIMD3<Float>]) -> Result<LiDARMeasurement, Error> {
        let points = rawPoints.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        guard points.count >= 350 else { return .failure(MeasurementError.tooFewPoints) }

        let yValues = points.map(\.y)
        guard let lowY = percentile(yValues, 0.02),
              let highY = percentile(yValues, 0.98),
              highY - lowY >= 0.03 else { return .failure(MeasurementError.invalidSize) }

        // 바닥면 자체가 폭/깊이를 부풀리지 않도록 최하단 3cm는 수평 치수 계산에서 제외한다.
        let horizontalPoints = points.filter { $0.y > lowY + 0.03 }
        guard horizontalPoints.count >= 200 else { return .failure(MeasurementError.tooFewPoints) }

        let meanX = horizontalPoints.reduce(Float.zero) { $0 + $1.x } / Float(horizontalPoints.count)
        let meanZ = horizontalPoints.reduce(Float.zero) { $0 + $1.z } / Float(horizontalPoints.count)
        var covXX: Float = 0
        var covZZ: Float = 0
        var covXZ: Float = 0
        for point in horizontalPoints {
            let x = point.x - meanX
            let z = point.z - meanZ
            covXX += x * x
            covZZ += z * z
            covXZ += x * z
        }
        let yaw = 0.5 * atan2(2 * covXZ, covXX - covZZ)
        let axisX = SIMD2<Float>(cos(yaw), sin(yaw))
        let axisZ = SIMD2<Float>(-sin(yaw), cos(yaw))
        let projectedX = horizontalPoints.map { dot(SIMD2($0.x - meanX, $0.z - meanZ), axisX) }
        let projectedZ = horizontalPoints.map { dot(SIMD2($0.x - meanX, $0.z - meanZ), axisZ) }

        guard let minX = percentile(projectedX, 0.02), let maxX = percentile(projectedX, 0.98),
              let minZ = percentile(projectedZ, 0.02), let maxZ = percentile(projectedZ, 0.98) else {
            return .failure(MeasurementError.invalidSize)
        }

        var width = maxX - minX
        var depth = maxZ - minZ
        let height = highY - lowY
        // PCA 축의 부호/순서는 임의이므로 UI에서는 긴 수평축을 가로로 통일한다.
        if depth > width { swap(&width, &depth) }
        let dimensions = SIMD3(width, height, depth)
        guard dimensions.x >= 0.03, dimensions.y >= 0.03, dimensions.z >= 0.03,
              dimensions.x <= 5, dimensions.y <= 4, dimensions.z <= 5 else {
            return .failure(MeasurementError.invalidSize)
        }
        return .success(LiDARMeasurement(dimensions: dimensions, pointCount: points.count))
    }

    private static func percentile(_ values: [Float], _ p: Float) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(max(Int(Float(sorted.count - 1) * p), 0), sorted.count - 1)
        return sorted[index]
    }
}

private final class FurnitureScanARView: ARView {
    var onLayout: ((CGSize, UIInterfaceOrientation) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
        onLayout?(bounds.size, orientation)
    }
}

private struct LiDARCameraView: UIViewRepresentable {
    @ObservedObject var scanner: LiDARFurnitureScanner

    func makeUIView(context: Context) -> FurnitureScanARView {
        let view = FurnitureScanARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        view.onLayout = { [weak scanner] size, orientation in
            scanner?.viewportSize = size
            scanner?.interfaceOrientation = orientation
        }
        scanner.attach(session: view.session)
        return view
    }

    func updateUIView(_ uiView: FurnitureScanARView, context: Context) {
        scanner.viewportSize = uiView.bounds.size
        scanner.interfaceOrientation = uiView.window?.windowScene?.interfaceOrientation ?? .portrait
    }
}
