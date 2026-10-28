//
//  RoomViewerView.swift
//  RoomPlanExporter
//
//  Created by Jung Hyun Han on 4/8/26.
//  Copyright © 2026 Apple. All rights reserved.
//

import SwiftUI
import RealityKit
import RoomPlan
import Combine
import CryptoKit

// MARK: - General V-O asset reuse

actor FurnitureAssetFiles {
    static let shared = FurnitureAssetFiles()
    private var inFlight: [String: Task<URL, Error>] = [:]
    private let session: URLSession
    private let directory: URL
    private var cleaned = false

    init(session: URLSession = .shared, directory: URL? = nil) {
        self.session = session
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VOFurnitureAssets", isDirectory: true)
    }

    /// Signed S3 URLs change on each visit; the object path and optional version ID identify the asset.
    nonisolated static func cacheKey(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        if (parts.host ?? "").contains(".s3.") || (parts.host ?? "").contains(".s3-") {
            parts.queryItems = parts.queryItems?.filter { $0.name == "versionId" }
            if parts.queryItems?.isEmpty == true { parts.query = nil }
        }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    func file(for url: URL, fileExtension: String) async throws -> URL {
        if !cleaned {
            cleaned = true
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(date) >= 86_400 {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        let key = Self.cacheKey(url) + "." + fileExtension
        if let pending = inFlight[key] { return try await pending.value }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent(digest).appendingPathExtension(fileExtension)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let date = attributes[.modificationDate] as? Date,
           let size = attributes[.size] as? NSNumber, size.intValue > 0,
           Date().timeIntervalSince(date) < 86_400 {
            return destination
        }
        let session = session
        let directory = directory
        let download = Task<URL, Error> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (temporary, response) = try await session.download(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        }
        inFlight[key] = download
        defer { inFlight[key] = nil }
        return try await download.value
    }

    func invalidate(_ url: URL, fileExtension: String) {
        let key = Self.cacheKey(url) + "." + fileExtension
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(digest).appendingPathExtension(fileExtension))
    }

    func prefetch(_ urls: [URL]) async {
        var seen = Set<String>()
        var iterator = urls.filter { seen.insert(Self.cacheKey($0)).inserted }.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                guard let url = iterator.next() else { break }
                group.addTask { _ = try? await self.file(for: url, fileExtension: "usdz") }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let url = iterator.next() else { group.cancelAll(); break }
                group.addTask { _ = try? await self.file(for: url, fileExtension: "usdz") }
            }
        }
    }
}

@MainActor
private final class FurnitureModelTemplates {
    static let shared = FurnitureModelTemplates()
    private let models = NSCache<NSString, Entity>()
    private var pending: [String: Task<Entity, Error>] = [:]

    init() { models.countLimit = 24 }

    func load(_ url: URL, fileExtension: String) async throws -> Entity {
        let key = FurnitureAssetFiles.cacheKey(url) + "." + fileExtension
        if let cached = models.object(forKey: key as NSString) { return cached.clone(recursive: true) }
        if let pending = pending[key] { return try await pending.value.clone(recursive: true) }
        let task = Task<Entity, Error> { @MainActor in
            let file = try await FurnitureAssetFiles.shared.file(for: url, fileExtension: fileExtension)
            do {
                for try await model in Entity.loadAsync(contentsOf: file).values { return model }
            } catch {
                await FurnitureAssetFiles.shared.invalidate(url, fileExtension: fileExtension)
                throw error
            }
            throw URLError(.cannotDecodeContentData)
        }
        pending[key] = task
        defer { pending[key] = nil }
        let model = try await task.value
        models.setObject(model, forKey: key as NSString)
        return model.clone(recursive: true)
    }

    func loadLocal(_ url: URL) async throws -> Entity {
        let key = "local:" + url.path
        if let model = models.object(forKey: key as NSString) { return model.clone(recursive: true) }
        if let task = pending[key] { return try await task.value.clone(recursive: true) }
        let task = Task<Entity, Error> { @MainActor in
            for try await model in Entity.loadAsync(contentsOf: url).values { return model }
            throw URLError(.cannotDecodeContentData)
        }
        pending[key] = task
        defer { pending[key] = nil }
        let model = try await task.value
        models.setObject(model, forKey: key as NSString)
        return model.clone(recursive: true)
    }
}

// MARK: - Furniture names and floor-calibrated centimetre rulers

struct RoomGuideItem {
    let id: String
    let title: String
    let worldPoint: SIMD3<Float>
    let selected: Bool
    var sizeText: String? = nil
}

final class RoomGuideOverlay: UIView {
    weak var arView: ARView?
    weak var roomAnchor: AnchorEntity?
    var items: (() -> [RoomGuideItem])?
    var floorY: (() -> Float)?
    private var displayLink: CADisplayLink?
    private var labels: [String: UILabel] = [:]
    private let rulerWidth: CGFloat = 20
    private var lastCameraPosition = SIMD3<Float>(repeating: .nan)
    private var lastCameraRotation = SIMD4<Float>(repeating: .nan)
    private var lastRoomPosition = SIMD3<Float>(repeating: .nan)
    private var lastSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stop()
        if window != nil {
            let link = CADisplayLink(target: self, selector: #selector(refresh))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }
    func stop() { displayLink?.invalidate(); displayLink = nil }

    static func furnitureName(category: String, height: Float) -> String {
        switch category.lowercased() {
        case "bed": return "침대"
        case "table", "desk": return "책상·테이블"
        case "chair": return "의자"
        case "sofa": return "소파"
        case "storage": return height >= 1.2 ? "옷장·수납장" : "서랍장·수납장"
        case "television": return "TV"
        case "refrigerator": return "냉장고"
        case "washerdryer": return "세탁기"
        case "custom": return "추가 가구"
        default: return "가구"
        }
    }

    @objc private func refresh() {
        guard let arView, bounds.width > 0 else { return }
        let current = (items?() ?? []).sorted { $0.id < $1.id }
        let identifiers = Set(current.map(\.id))
        for id in Set(labels.keys).subtracting(identifiers) { labels.removeValue(forKey: id)?.removeFromSuperview() }
        var occupied: [CGRect] = []
        for item in current.sorted(by: { $0.selected && !$1.selected }) {
            let label = labels[item.id] ?? {
                let label = UILabel()
                label.font = .systemFont(ofSize: 10, weight: .medium)
                label.layer.cornerRadius = 4
                label.clipsToBounds = true
                label.textAlignment = .center
                addSubview(label)
                labels[item.id] = label
                return label
            }()
            guard let point = arView.project(item.worldPoint), point.x.isFinite, point.y.isFinite,
                  point.x >= rulerWidth, point.x < bounds.width, point.y >= rulerWidth, point.y < bounds.height else {
                label.isHidden = true
                continue
            }
            label.text = "  \(item.title)\(item.selected ? item.sizeText.map { " · " + $0 } ?? "" : "")  "
            label.textColor = item.selected ? .black : .label
            label.backgroundColor = item.selected ? (UIColor(named: "voBlue") ?? .systemBlue) : UIColor.systemBackground.withAlphaComponent(0.72)
            label.sizeToFit()
            var frame = CGRect(x: max(rulerWidth + 4, min(point.x - label.bounds.width / 2, bounds.width - label.bounds.width - 4)),
                               y: max(rulerWidth + 6, point.y - 20), width: label.bounds.width, height: 18)
            for _ in 0..<3 where occupied.contains(where: { $0.intersects(frame.insetBy(dx: -2, dy: -2)) }) {
                frame.origin.y = max(rulerWidth + 6, frame.origin.y - 20)
            }
            label.frame = frame
            label.isHidden = false
            occupied.append(frame)
        }
        let camera = arView.cameraTransform
        let roomPosition = roomAnchor?.position(relativeTo: nil) ?? .zero
        if lastCameraPosition != camera.translation || lastCameraRotation != camera.rotation.vector
            || lastRoomPosition != roomPosition || lastSize != bounds.size {
            lastCameraPosition = camera.translation
            lastCameraRotation = camera.rotation.vector
            lastRoomPosition = roomPosition
            lastSize = bounds.size
            setNeedsDisplay()
        }
    }

    /// Intersect each screen ray with the actual room floor. No assumed pixels-to-centimetres ratio.
    private func floorPoint(at point: CGPoint) -> SIMD3<Float>? {
        guard let arView, let roomAnchor, let ray = arView.ray(through: point) else { return nil }
        let origin = roomAnchor.convert(position: ray.origin, from: nil)
        let direction = roomAnchor.convert(direction: ray.direction, from: nil)
        guard abs(direction.y) > 0.0001 else { return nil }
        let distance = ((floorY?() ?? 0) - origin.y) / direction.y
        guard distance > 0, distance < 100 else { return nil }
        return origin + direction * distance
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 0.8).setFill()
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: rulerWidth))
        context.fill(CGRect(x: 0, y: 0, width: rulerWidth, height: bounds.height))
        drawRuler(horizontal: true, context: context)
        drawRuler(horizontal: false, context: context)
        ("cm" as NSString).draw(at: CGPoint(x: 2, y: 4), withAttributes: [.font: UIFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: UIColor.secondaryLabel])
    }

    private func drawRuler(horizontal: Bool, context: CGContext) {
        let end = horizontal ? bounds.width : bounds.height
        guard end > 60 else { return }
        let samples: [(CGFloat, SIMD3<Float>)] = stride(from: Double(rulerWidth + 10), through: Double(end - 8), by: 12).compactMap {
            let value = CGFloat($0)
            return floorPoint(at: horizontal ? CGPoint(x: value, y: rulerWidth) : CGPoint(x: rulerWidth, y: value)).map { (value, $0) }
        }
        guard let first = samples.first, let last = samples.last, samples.count > 1 else { return }
        let axis = abs(last.1.x - first.1.x) >= abs(last.1.z - first.1.z) ? 0 : 2
        let coordinates = samples.map { Double($0.1[axis]) }
        guard let low = coordinates.min(), let high = coordinates.max(), high - low > 0.01 else { return }
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10]
        let step = steps.first { (high - low) / $0 < 80 } ?? 10
        let start = Int(ceil(low / step)), finish = Int(floor(high / step))
        guard finish >= start, finish - start < 200 else { return }
        context.setStrokeColor(UIColor.secondaryLabel.cgColor)
        context.setLineWidth(0.7)
        var lastLabel: CGFloat = -.greatestFiniteMagnitude
        for index in start...finish {
            let target = Double(index) * step
            var matchingSegment: Int?
            for candidate in 0..<(samples.count - 1) {
                let a = coordinates[candidate]
                let b = coordinates[candidate + 1]
                if target >= min(a, b), target <= max(a, b), abs(b - a) > 0.0001 {
                    matchingSegment = candidate
                    break
                }
            }
            guard let segment = matchingSegment else { continue }
            let fraction = (target - coordinates[segment]) / (coordinates[segment + 1] - coordinates[segment])
            let position = samples[segment].0 + CGFloat(fraction) * (samples[segment + 1].0 - samples[segment].0)
            let major = index % 5 == 0
            let length: CGFloat = major ? 7 : 3
            context.move(to: horizontal ? CGPoint(x: position, y: rulerWidth) : CGPoint(x: rulerWidth, y: position))
            context.addLine(to: horizontal ? CGPoint(x: position, y: rulerWidth - length) : CGPoint(x: rulerWidth - length, y: position))
            context.strokePath()
            if major, abs(position - lastLabel) > 35 {
                let value = String(format: "%.0f", target * 100)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular), .foregroundColor: UIColor.label
                ]
                if !horizontal, position - (value as NSString).size(withAttributes: attributes).width < rulerWidth + 4 { continue }
                if horizontal {
                    (value as NSString).draw(at: CGPoint(x: position + 2, y: 2), withAttributes: attributes)
                } else {
                    context.saveGState()
                    context.translateBy(x: 2, y: position - 2)
                    context.rotate(by: -.pi / 2)
                    (value as NSString).draw(at: .zero, withAttributes: attributes)
                    context.restoreGState()
                }
                lastLabel = position
            }
        }
    }
}

/// LiDAR로 인식한 벽의 공통 표시색.
/// #17233D를 반투명으로 사용해 흰색 벽 대신 모든 공간 화면에서 동일하게 보이게 한다.
private let roomWallNavy = UIColor(
    red: 23.0 / 255.0,
    green: 35.0 / 255.0,
    blue: 61.0 / 255.0,
    alpha: 0.72
)

/// 모든 공간 뷰어가 같은 카메라 조작 방식을 쓰도록 하는 공통 컨트롤러.
/// 방 엔티티는 움직이지 않고 카메라만 원점을 중심으로 회전·기울기·줌을 변경한다.
final class RoomOrbitCamera {
    weak var camera: PerspectiveCamera?
    private var yaw: Float = 0
    private var pitch: Float = .pi / 4
    private var distance: Float = 8
    private var pinchStartDistance: Float = 8

    func attach(_ camera: PerspectiveCamera) {
        self.camera = camera
        syncFromCamera()
    }

    func setPosition(_ position: SIMD3<Float>) {
        guard let camera else { return }
        camera.position = position
        camera.look(at: .zero, from: position, relativeTo: nil)
        syncFromCamera()
    }

    func setPose(yaw: Float, pitch: Float, distance: Float) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        apply()
    }

    func syncFromCamera() {
        guard let position = camera?.position else { return }
        let newDistance = max(length(position), 0.001)
        distance = newDistance
        pitch = asin(min(max(position.y / newDistance, -1), 1))
        yaw = atan2(position.x, position.z)
        pinchStartDistance = distance
    }

    func pan(_ translation: CGPoint) {
        yaw -= Float(translation.x) * 0.006
        let proposedPitch = pitch + Float(translation.y) * 0.004
        let minimumPitch: Float = .pi * 0.16
        let maximumPitch: Float = .pi * 0.47
        pitch = min(max(proposedPitch, minimumPitch), maximumPitch)
        apply()
    }

    func pinchBegan() {
        pinchStartDistance = distance
    }

    func pinch(scale: CGFloat) {
        distance = min(max(pinchStartDistance / Float(scale), 2.5), 30)
        apply()
    }

    func rotate(by angle: Float) {
        yaw -= angle
        apply()
    }

    private func apply() {
        guard let camera else { return }
        let horizontal = cos(pitch) * distance
        let position = SIMD3<Float>(sin(yaw) * horizontal,
                                    sin(pitch) * distance,
                                    cos(yaw) * horizontal)
        camera.position = position
        camera.look(at: .zero, from: position, relativeTo: nil)
    }
}

extension CapturedRoom.ModelProvider {
    enum CatalogError: LocalizedError {
        case cannotFindCatalog
        var errorDescription: String? { "Cannot Find Catalog" }
    }
    static func load() throws -> CapturedRoom.ModelProvider {
        guard let url = Bundle.main.url(forResource: "RoomPlanCatalog", withExtension: "bundle") else {
            throw CatalogError.cannotFindCatalog
        }
        return try RoomPlanCatalog.load(at: url)
    }
}

// MARK: - Entity 로딩 헬퍼
//
// @available(*, noasync) 우회: non-async @MainActor 타입 메서드 안에서 load를 호출.
// - async 컨텍스트에서 loadSync를 '호출'하는 것은 허용 (loadSync 자체가 noasync가 아님).
// - loadSync 내부에서 ModelEntity.load를 호출하는 시점의 스코프는 non-async → OK.
// - iOS 18+ async init은 배포 타겟 제한으로 사용 불가.

private extension Entity {
    @MainActor
    static func loadSync(contentsOf url: URL) throws -> Entity {
        try ModelEntity.load(contentsOf: url)
    }
}

// MARK: - OptimizedObject

struct OptimizedObject: Identifiable {
    var id: UUID { identifier }
    let identifier: UUID
    let category: String
    let center: SIMD3<Float>
    let rotation: simd_quatf
}

// MARK: - RoomViewerView (3D 뷰어 전용)

struct RoomViewerView: View {

    let capturedRoom: CapturedRoom
    var serverModels: [UUID: URL]? = nil
    var optimizedObjects: [OptimizedObject]? = nil
    var isTransparent: Bool = false
    var wallColor: UIColor = roomWallNavy
    var floorColor: UIColor = .white
    var furnitureTint: UIColor? = nil
    /// true면 기본 모드에서도 Apple이 구워낸 USDZ 대신, 벽/바닥/가구를 따로 그리는
    /// 렌더러(투시 모드와 동일)를 사용 — wallColor/floorColor/furnitureTint가 전부 반영됨.
    var colorCustomizable: Bool = false

    @State private var usdzURL: URL? = nil
    @State private var isGenerating = true

    private var usesProceduralRenderer: Bool { isTransparent || colorCustomizable }

    var body: some View {
        ZStack {
            if isGenerating && !usesProceduralRenderer {
                VStack(spacing: 16) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(1.5)
                    Text("방 모델 생성 중...").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                RealityKitRoomView(
                    capturedRoom: capturedRoom,
                    serverModels: serverModels,
                    usdzURL: usesProceduralRenderer ? nil : usdzURL,
                    optimizedObjects: optimizedObjects,
                    isTransparent: isTransparent,
                    useCatalogRenderer: usesProceduralRenderer,
                    wallColor: wallColor,
                    floorColor: floorColor,
                    furnitureTint: furnitureTint
                )
                .ignoresSafeArea()
            }
        }
        .task {
            if usesProceduralRenderer { isGenerating = false; return }
            await generateUSDZ()
        }
    }

    // MARK: - USDZ 생성 (시각화용)

    private func generateUSDZ() async {
        isGenerating = true
        defer { isGenerating = false }

        let tmp = URL(filePath: NSTemporaryDirectory()).appending(path: "RoomViewer")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let outputURL = tmp.appending(path: "Room.usdz")
        try? FileManager.default.removeItem(at: outputURL)

        do {
            let mp = try CapturedRoom.ModelProvider.load()
            try capturedRoom.export(to: outputURL, modelProvider: mp, exportOptions: .model)
            await MainActor.run { usdzURL = outputURL }
            print("✅ USDZ 생성 완료")
        } catch {
            print("⚠️ ModelProvider 실패: \(error) → 기본 메쉬")
            try? capturedRoom.export(to: outputURL, exportOptions: [.parametric, .mesh])
            await MainActor.run { usdzURL = outputURL }
        }
    }
}

// MARK: - RealityKit 뷰

struct RealityKitRoomView: UIViewRepresentable {

    let capturedRoom: CapturedRoom
    var serverModels: [UUID: URL]? = nil
    var usdzURL: URL?
    var optimizedObjects: [OptimizedObject]?
    var isTransparent: Bool = false
    /// true면 isTransparent와 무관하게 카탈로그/색상 커스터마이즈 가능한 렌더러 사용
    var useCatalogRenderer: Bool = false
    var wallColor: UIColor = roomWallNavy
    var floorColor: UIColor = .white
    var furnitureTint: UIColor? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.environment.background = .color(UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1.0))
        arView.cameraMode = .nonAR
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // 카메라 설정
        let camAnchor = AnchorEntity(world: .zero)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 60
        camera.position = SIMD3(0, 5, 5)
        camera.look(at: .zero, from: camera.position, relativeTo: nil)
        camAnchor.addChild(camera)
        arView.scene.addAnchor(camAnchor)
        context.coordinator.orbitCamera.attach(camera)

        setupLighting(in: arView)

        let roomAnchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(roomAnchor)
        context.coordinator.roomAnchor = roomAnchor
        context.coordinator.arView = arView

        let overlay = RoomGuideOverlay()
        overlay.arView = arView
        overlay.roomAnchor = roomAnchor
        let coord = context.coordinator
        overlay.items = { [weak coord, weak roomAnchor] in
            guard let coord, let roomAnchor else { return [] }
            return coord.guideObjects.map { item in
                RoomGuideItem(id: item.id, title: item.title,
                    worldPoint: roomAnchor.convert(position: item.worldPoint, to: nil), selected: false)
            }
        }
        overlay.floorY = { capturedRoom.floors.first?.transform.columns.3.y ?? 0 }
        overlay.frame = arView.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(overlay)
        coord.guideOverlay = overlay
        coord.guideObjects = capturedRoom.objects.map { object in
            let center = object.transform.columns.3.xyz
            return RoomGuideItem(id: object.identifier.uuidString,
                title: RoomGuideOverlay.furnitureName(category: String(describing: object.category), height: object.dimensions.y),
                worldPoint: center + SIMD3(0, object.dimensions.y / 2 + 0.06, 0), selected: false)
        }

        if isTransparent || useCatalogRenderer {
            coord.sceneTask = Task { @MainActor in
                let opts = capturedRoom.objects.map { obj in
                    OptimizedObject(
                        identifier: obj.identifier,
                        category: String(describing: obj.category),
                        center: SIMD3(obj.transform.columns.3.x, obj.transform.columns.3.y, obj.transform.columns.3.z),
                        rotation: simd_quatf(obj.transform)
                    )
                }
                await loadOptimizedScene(capturedRoom, objects: opts, into: roomAnchor)
            }
        } else if let url = usdzURL {
            coord.sceneTask = Task { await loadUSDZ(url: url, into: roomAnchor) }
        } else {
            renderScene(capturedRoom, in: roomAnchor)
        }

        setupGestures(in: arView, coordinator: context.coordinator)
        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        guard let optimizedObjects,
              let roomAnchor = context.coordinator.roomAnchor,
              !context.coordinator.hasAppliedOptimization else { return }

        context.coordinator.hasAppliedOptimization = true
        context.coordinator.sceneTask?.cancel()
        context.coordinator.guideObjects = optimizedObjects.compactMap { object in
            guard let original = capturedRoom.objects.first(where: { $0.identifier == object.identifier }) else { return nil }
            return RoomGuideItem(id: object.identifier.uuidString,
                title: RoomGuideOverlay.furnitureName(category: object.category, height: original.dimensions.y),
                worldPoint: object.center + SIMD3(0, original.dimensions.y / 2 + 0.06, 0), selected: false)
        }
        context.coordinator.sceneTask = Task { @MainActor in
            roomAnchor.children.removeAll()
            await loadOptimizedScene(capturedRoom, objects: optimizedObjects, into: roomAnchor)
        }
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.sceneTask?.cancel()
        coordinator.guideOverlay?.stop()
    }

    // MARK: - USDZ 로드

    @MainActor
    private func loadUSDZ(url: URL, into anchor: AnchorEntity) async {
        do {
            // This generated room file reuses its path for different scans; do not cache it by URL.
            let entity = try Entity.loadSync(contentsOf: url)
            guard !Task.isCancelled else { return }
            anchor.addChild(entity)
            // Apple USDZ의 바닥 재질을 선택된 바닥 색으로 덮기
            for s in capturedRoom.floors {
                anchor.addChild(makeSurface(s,
                    color: floorColor,
                    depth: 0.025))
            }
            print("✅ USDZ 로드 완료")
        } catch {
            print("❌ USDZ 로드 실패: \(error) → renderScene 폴백")
            renderScene(capturedRoom, in: anchor)
        }
    }

    // MARK: - 최적화 씬 로드 (카탈로그 USDC 모델 사용)

    @MainActor
    private func loadOptimizedScene(_ room: CapturedRoom, objects: [OptimizedObject], into anchor: AnchorEntity) async {
        // 방 구조(벽/바닥/문/창문)만 먼저 렌더링
        renderSurfaces(room, in: anchor)

        let mp = try? CapturedRoom.ModelProvider.load()
        let remoteModels = serverModels.map { Array($0.values) } ?? []
        let prefetch = Task { await FurnitureAssetFiles.shared.prefetch(remoteModels) }
        defer { prefetch.cancel() }

        for opt in objects {
            guard !Task.isCancelled else { return }
            guard let original = room.objects.first(where: { $0.identifier == opt.identifier }) else { continue }

            var placed = false

            let modelURL = serverModels?[original.identifier]
                ?? (serverModels == nil ? (try? mp?.modelFileURL(for: original)) : nil)
            if let modelURL {
                do {
                    let model: Entity
                    if modelURL.isFileURL {
                        model = try await FurnitureModelTemplates.shared.loadLocal(modelURL)
                    } else {
                        model = try await FurnitureModelTemplates.shared.load(modelURL, fileExtension: "usdz")
                    }
                    guard !Task.isCancelled else { return }

                    // 모델 크기를 원본 dimensions에 맞게 스케일 조정
                    let bounds = model.visualBounds(relativeTo: model)
                    let bSize = bounds.max - bounds.min
                    if bSize.x > 0.001 && bSize.y > 0.001 && bSize.z > 0.001 {
                        let d = original.dimensions
                        model.scale = SIMD3(d.x / bSize.x, d.y / bSize.y, d.z / bSize.z)
                        // pivot이 center가 아닐 경우 offset 보정
                        let centerOffset = (bounds.max + bounds.min) / 2
                        model.position = opt.center - opt.rotation.act(centerOffset * model.scale)
                    } else {
                        model.position = opt.center
                    }
                    model.orientation = opt.rotation
                    if let furnitureTint {
                        applyTint(to: model, color: furnitureTint)
                    } else if serverModels == nil {
                        applyPreviewColor(to: model, color: colorForCategory(original.category))
                    }
                    anchor.addChild(model)
                    placed = true
                    print("✅ 최적화 모델 배치: \(modelURL.lastPathComponent)")
                } catch {
                    print("⚠️ 카탈로그 모델 로드 실패: \(error)")
                }
            }

            // 폴백: OBB 박스 — serverModels가 있어도(서버 모드) 대응 모델이 없는 가구는
            // 카테고리 색상 박스로 대체한다. serverModels == nil 제약을 걸면 서버 모드에서
            // 매칭 안 된 가구가 그냥 통째로 안 보이게 된다(회귀 원인).
            if !placed {
                var mat = SimpleMaterial()
                mat.color = .init(tint: furnitureTint ?? colorForCategory(original.category))
                mat.roughness = 0.9; mat.metallic = 0.0
                let e = original.dimensions
                let entity = ModelEntity(
                    mesh: .generateBox(width: e.x, height: e.y, depth: e.z, cornerRadius: 0.03),
                    materials: [mat]
                )
                entity.position = opt.center
                entity.orientation = opt.rotation
                anchor.addChild(entity)
            }
        }
    }

    // MARK: - 씬 렌더링 (named entities - 최적화 애니메이션용)

    private func renderSurfaces(_ room: CapturedRoom, in anchor: AnchorEntity) {
        let effectiveWallColor = wallColor.withAlphaComponent(
            isTransparent ? 0.58 : wallColor.cgColor.alpha
        )
        for wall in room.walls {
            let openings = capturedRoomOpenings(wall: wall, doors: room.doors, windows: room.windows)
            wallSegments(wallTransform: wall.transform, wallW: wall.dimensions.x, wallH: wall.dimensions.y,
                         openings: openings, color: effectiveWallColor, depth: 0.04)
                .forEach { anchor.addChild($0) }
        }
        for s in room.floors { anchor.addChild(makeSurface(s, color: floorColor, depth: 0.01)) }
    }

    private func renderScene(_ room: CapturedRoom, in anchor: AnchorEntity) {
        renderSurfaces(room, in: anchor)
        for obj in room.objects {
            var mat = SimpleMaterial()
            mat.color = .init(tint: furnitureTint ?? colorForCategory(obj.category))
            mat.roughness = 0.9; mat.metallic = 0.0
            let e = obj.dimensions
            let entity = ModelEntity(
                mesh: .generateBox(width: e.x, height: e.y, depth: e.z, cornerRadius: 0.03),
                materials: [mat]
            )
            entity.transform = Transform(matrix: obj.transform)
            entity.name = "furniture_\(obj.identifier.uuidString)"
            anchor.addChild(entity)
        }
    }

    private func makeSurface(_ s: CapturedRoom.Surface, color: UIColor, depth: Float) -> ModelEntity {
        var mat = SimpleMaterial()
        mat.color = .init(tint: color); mat.roughness = 0.9; mat.metallic = 0.0
        let entity = ModelEntity(
            mesh: .generateBox(width: s.dimensions.x, height: s.dimensions.y, depth: depth),
            materials: [mat]
        )
        entity.transform = Transform(matrix: s.transform)
        return entity
    }

    // MARK: - 조명

    private func setupLighting(in arView: ARView) {
        let anchor = AnchorEntity(world: .zero)
        let dir = DirectionalLight()
        dir.light.intensity = 3000; dir.light.color = .white
        dir.shadow = DirectionalLightComponent.Shadow(maximumDistance: 10)
        dir.orientation = simd_quatf(angle: -.pi/3, axis: [1, 0, 0])
        anchor.addChild(dir)
        let pt = PointLight()
        pt.light.intensity = 1000; pt.position = [0, 4, 0]
        anchor.addChild(pt)
        arView.scene.addAnchor(anchor)
    }

    // MARK: - 제스처

    private func setupGestures(in arView: ARView, coordinator: Coordinator) {
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch))
        let rotation = UIRotationGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleRotation))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan))
        pan.maximumNumberOfTouches = 2
        [pinch, rotation, pan].forEach {
            $0.delegate = coordinator
            arView.addGestureRecognizer($0)
        }
    }

    // MARK: - 카테고리별 색상

    private func colorForCategory(_ category: CapturedRoom.Object.Category) -> UIColor {
        switch category {
        case .chair:        return UIColor(red: 0.72, green: 0.83, blue: 0.90, alpha: 1.0)
        case .sofa:         return UIColor(red: 0.72, green: 0.83, blue: 0.90, alpha: 1.0)
        case .table:        return UIColor(red: 0.88, green: 0.82, blue: 0.72, alpha: 1.0)
        case .bed:          return UIColor(red: 0.95, green: 0.80, blue: 0.83, alpha: 1.0)
        case .storage:      return UIColor(red: 0.78, green: 0.82, blue: 0.76, alpha: 1.0)
        case .television:   return UIColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)
        case .refrigerator: return UIColor(red: 0.88, green: 0.90, blue: 0.92, alpha: 1.0)
        case .washerDryer:  return UIColor(red: 0.82, green: 0.88, blue: 0.92, alpha: 1.0)
        default:            return UIColor(red: 0.80, green: 0.78, blue: 0.75, alpha: 1.0)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var arView: ARView?
        var roomAnchor: AnchorEntity?
        var hasAppliedOptimization: Bool = false
        var sceneTask: Task<Void, Never>?
        var guideOverlay: RoomGuideOverlay?
        var guideObjects: [RoomGuideItem] = []
        let orbitCamera = RoomOrbitCamera()
        private var lastRotation: Float = 0

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { orbitCamera.pinchBegan() }
            orbitCamera.pinch(scale: g.scale)
        }

        @objc func handleRotation(_ g: UIRotationGestureRecognizer) {
            if g.state == .began { lastRotation = 0 }
            let delta = Float(g.rotation) - lastRotation
            lastRotation = Float(g.rotation)
            orbitCamera.rotate(by: delta)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            orbitCamera.pan(g.translation(in: arView))
            g.setTranslation(.zero, in: arView)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - JSON 데이터 기반 RealityKit 뷰 (공간 조회용)
//
// room_data.json / room_data.roomplan_optimized.json을 파싱한 RoomDataPayload를 받아
// 벽·바닥·가구를 RealityKit 엔티티로 직접 렌더링한다.
// 가구: modelFileName이 있으면 카탈로그 번들에서 로드, 없으면 카테고리별 색상 박스 폴백.

struct JsonRealityKitView: UIViewRepresentable {
    let roomData: RoomDataPayload

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.environment.background = .color(UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1.0))
        arView.cameraMode = .nonAR
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // 카메라
        let camAnchor = AnchorEntity(world: .zero)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 60
        camera.position = SIMD3(0, 5, 5)
        camera.look(at: .zero, from: camera.position, relativeTo: nil)
        camAnchor.addChild(camera)
        arView.scene.addAnchor(camAnchor)
        context.coordinator.orbitCamera.attach(camera)

        // 조명
        let lightAnchor = AnchorEntity(world: .zero)
        let dir = DirectionalLight()
        dir.light.intensity = 3000; dir.light.color = .white
        dir.shadow = DirectionalLightComponent.Shadow(maximumDistance: 10)
        dir.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0])
        lightAnchor.addChild(dir)
        let pt = PointLight(); pt.light.intensity = 1000; pt.position = [0, 4, 0]
        lightAnchor.addChild(pt)
        arView.scene.addAnchor(lightAnchor)

        // 씬 앵커
        let roomAnchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(roomAnchor)
        context.coordinator.roomAnchor = roomAnchor
        context.coordinator.arView    = arView

        // 씬 빌드
        Task { @MainActor in await buildScene(into: roomAnchor) }

        // 제스처
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch))
        let rotation = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        pan.maximumNumberOfTouches = 2
        [pinch, rotation, pan].forEach {
            $0.delegate = context.coordinator
            arView.addGestureRecognizer($0)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    // MARK: 씬 구성

    @MainActor
    private func buildScene(into anchor: AnchorEntity) async {
        // 구조물
        // 벽: #17233D 반투명 네이비, 문/창문 스킵 → 자연 간극
        for s in roomData.walls  ?? [] {
            anchor.addChild(makeSurface(s, color: roomWallNavy.withAlphaComponent(0.58), depth: 0.04))
        }
        for s in roomData.floors ?? [] { anchor.addChild(makeSurface(s, color: UIColor.white, depth: 0.01)) }

        // 가구
        for obj in roomData.objects {
            if let entity = await loadFurniture(obj) {
                anchor.addChild(entity)
            }
        }
    }

    /// 가구 엔티티 생성: 오브젝트별 usdz_url(재질 반영) → 로컬 번들 → 색상 박스 순으로 시도
    @MainActor
    private func loadFurniture(_ obj: RoomDataPayload.RoomObject) async -> Entity? {
        // 1. 오브젝트별 usdz_url을 먼저 확인 — 재질/색상이 서버에서 갱신되면 이 경로로만
        // 최신 버전을 받아올 수 있어서, 로컬 번들보다 우선한다.
        // (glb_url도 같이 오지만 RealityKit이 GLB를 못 읽어서(noImporter) 반드시 usdz_url을 써야 함)
        if let urlStr = obj.usdzUrl, let remoteURL = URL(string: urlStr) {
            do {
                let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
                let destURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent(UUID().uuidString + ".usdz")
                try FileManager.default.moveItem(at: tmpURL, to: destURL)
                let model = try Entity.loadSync(contentsOf: destURL)
                applyTransform(to: model, obj: obj)
                print("✅ 서버 usdz_url 모델 로드: \(obj.modelFileName ?? "")")
                return model
            } catch {
                print("⚠️ 서버 usdz_url 로드 실패 (\(obj.modelFileName ?? "")): \(error)")
            }
        }

        // 2. 없거나 실패하면 앱에 내장된 RoomPlanCatalog.bundle로 폴백
        if let fileName = obj.modelFileName,
           let modelURL = findCatalogModel(named: fileName) {
            do {
                let model = try Entity.loadSync(contentsOf: modelURL)
                applyTransform(to: model, obj: obj)
                print("✅ 카탈로그 모델 로드: \(fileName)")
                return model
            } catch {
                print("⚠️ 카탈로그 로드 실패 (\(fileName)): \(error)")
            }
        }

        // 3. 색상 박스 폴백
        var mat = SimpleMaterial()
        mat.color = .init(tint: categoryColor(obj.category ?? ""))
        mat.roughness = 0.9; mat.metallic = 0.0
        let dims = obj.dimensions ?? [0.5, 0.5, 0.5]
        let entity = ModelEntity(
            mesh: .generateBox(
                width:  dims.count >= 1 ? dims[0] : 0.5,
                height: dims.count >= 2 ? dims[1] : 0.5,
                depth:  dims.count >= 3 ? dims[2] : 0.5,
                cornerRadius: 0.03
            ),
            materials: [mat]
        )
        applyTransform(to: entity, obj: obj)
        return entity
    }

    private func applyTransform(to entity: Entity, obj: RoomDataPayload.RoomObject) {
        if let mat = obj.simdTransform {
            let bounds = entity.visualBounds(relativeTo: entity)
            let bSize  = bounds.max - bounds.min
            let pos    = SIMD3<Float>(mat.columns.3.x, mat.columns.3.y, mat.columns.3.z)
            if let dims = obj.dimensions, dims.count >= 3,
               bSize.x > 0.001, bSize.y > 0.001, bSize.z > 0.001 {
                let scale  = SIMD3<Float>(dims[0] / bSize.x, dims[1] / bSize.y, dims[2] / bSize.z)
                let center = (bounds.max + bounds.min) / 2
                entity.scale       = scale
                entity.position    = pos - center * scale
                entity.orientation = simd_quatf(mat)
            } else {
                entity.transform = Transform(matrix: mat)
            }
        } else {
            if let c = obj.center, c.count >= 3 {
                entity.position = SIMD3(c[0], c[1], c[2])
            } else {
                entity.position = .zero
            }
        }
    }

    private func makeSurface(_ s: RoomDataPayload.RoomSurface, color: UIColor, depth: Float) -> ModelEntity {
        let d = s.dimensions
        var mat = SimpleMaterial()
        mat.color = .init(tint: color); mat.roughness = 0.9; mat.metallic = 0.0
        let entity = ModelEntity(
            mesh: .generateBox(width: d.count >= 1 ? d[0] : 1,
                               height: d.count >= 2 ? d[1] : 1,
                               depth: depth),
            materials: [mat]
        )
        if let t = s.simdTransform { entity.transform = Transform(matrix: t) }
        return entity
    }

    /// RoomPlanCatalog.bundle 내에서 파일명으로 모델 URL 검색
    private func findCatalogModel(named fileName: String) -> URL? {
        guard let bundleURL = Bundle.main.url(forResource: "RoomPlanCatalog", withExtension: "bundle"),
              let bundle = Bundle(url: bundleURL) else { return nil }

        let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext  = URL(fileURLWithPath: fileName).pathExtension.isEmpty ? "usdc"
                   : URL(fileURLWithPath: fileName).pathExtension

        // 직접 리소스 조회
        if let url = bundle.url(forResource: name, withExtension: ext) { return url }

        // 번들 내 재귀 탐색 (서브폴더에 있는 경우)
        let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent == fileName { return fileURL }
        }
        return nil
    }

    private func categoryColor(_ cat: String) -> UIColor {
        switch cat.lowercased() {
        case "chair", "sofa":  return UIColor(red: 0.72, green: 0.83, blue: 0.90, alpha: 1.0)
        case "table":          return UIColor(red: 0.88, green: 0.82, blue: 0.72, alpha: 1.0)
        case "bed":            return UIColor(red: 0.95, green: 0.80, blue: 0.83, alpha: 1.0)
        case "storage":        return UIColor(red: 0.78, green: 0.82, blue: 0.76, alpha: 1.0)
        case "television":     return UIColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)
        case "refrigerator":   return UIColor(red: 0.88, green: 0.90, blue: 0.92, alpha: 1.0)
        case "washerdryer":    return UIColor(red: 0.82, green: 0.88, blue: 0.92, alpha: 1.0)
        default:               return UIColor(red: 0.80, green: 0.78, blue: 0.75, alpha: 1.0)
        }
    }

    // MARK: Coordinator
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var arView: ARView?
        var roomAnchor: AnchorEntity?
        let orbitCamera = RoomOrbitCamera()
        private var lastRotation: Float = 0

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { orbitCamera.pinchBegan() }
            orbitCamera.pinch(scale: g.scale)
        }

        @objc func handleRotation(_ g: UIRotationGestureRecognizer) {
            if g.state == .began { lastRotation = 0 }
            let delta = Float(g.rotation) - lastRotation
            lastRotation = Float(g.rotation)
            orbitCamera.rotate(by: delta)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            orbitCamera.pan(g.translation(in: arView))
            g.setTranslation(.zero, in: arView)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - USDZ 전용 RealityKit 뷰 (공간 조회용 – CapturedRoom 불필요)

struct UsdzRealityKitView: UIViewRepresentable {
    let usdzURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.environment.background = .color(UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1.0))
        arView.cameraMode = .nonAR
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // 카메라
        let camAnchor = AnchorEntity(world: .zero)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 60
        camera.position = SIMD3(0, 5, 5)
        camera.look(at: .zero, from: camera.position, relativeTo: nil)
        camAnchor.addChild(camera)
        arView.scene.addAnchor(camAnchor)
        context.coordinator.orbitCamera.attach(camera)

        // 조명
        let lightAnchor = AnchorEntity(world: .zero)
        let dir = DirectionalLight()
        dir.light.intensity = 3000; dir.light.color = .white
        dir.shadow = DirectionalLightComponent.Shadow(maximumDistance: 10)
        dir.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0])
        lightAnchor.addChild(dir)
        let pt = PointLight(); pt.light.intensity = 1000; pt.position = [0, 4, 0]
        lightAnchor.addChild(pt)
        arView.scene.addAnchor(lightAnchor)

        // 씬 앵커
        let roomAnchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(roomAnchor)
        context.coordinator.roomAnchor = roomAnchor
        context.coordinator.arView    = arView

        // USDZ 로드
        Task { @MainActor in
            do {
                let entity = try Entity.loadSync(contentsOf: usdzURL)
                roomAnchor.addChild(entity)
                print("✅ 조회 USDZ 로드 완료")
            } catch {
                print("❌ 조회 USDZ 로드 실패: \(error)")
            }
        }

        // 제스처
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch))
        let rotation = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        pan.maximumNumberOfTouches = 2
        [pinch, rotation, pan].forEach {
            $0.delegate = context.coordinator
            arView.addGestureRecognizer($0)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    // MARK: Coordinator (핀치·회전·팬)
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var arView: ARView?
        var roomAnchor: AnchorEntity?
        let orbitCamera = RoomOrbitCamera()
        private var lastRotation: Float = 0

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { orbitCamera.pinchBegan() }
            orbitCamera.pinch(scale: g.scale)
        }

        @objc func handleRotation(_ g: UIRotationGestureRecognizer) {
            if g.state == .began { lastRotation = 0 }
            let delta = Float(g.rotation) - lastRotation
            lastRotation = Float(g.rotation)
            orbitCamera.rotate(by: delta)
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            orbitCamera.pan(g.translation(in: arView))
            g.setTranslation(.zero, in: arView)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - 가구 편집 핸들바
//
// Planner 5D / IKEA Kreativ처럼 가구 자체를 끌어서 이동하는 방식을 주 조작으로 사용한다.
// 선택하면 아래에는 시야를 가리지 않는 작은 회전 액션 바만 나타난다.

final class FurnitureNudgeHandle: UIView {
    /// 방의 Y축을 기준으로 한 회전 각도(라디안).
    var onRotate: ((Float) -> Void)?

    private let rotateLeftButton = UIButton(type: .system)
    private let instructionLabel = UILabel()
    private let rotateRightButton = UIButton(type: .system)

    private let showsAngleLabels: Bool

    init(showsAngleLabels: Bool = false) {
        self.showsAngleLabels = showsAngleLabels
        let frame = CGRect.zero
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.black.withAlphaComponent(0.40)
        layer.cornerRadius = 28
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor


        configureRotateButton(rotateLeftButton, symbol: "rotate.left", label: "왼쪽으로 90도 회전")
        configureRotateButton(rotateRightButton, symbol: "rotate.right", label: "오른쪽으로 90도 회전")
        rotateLeftButton.addTarget(self, action: #selector(rotateLeftTapped), for: .touchUpInside)
        rotateRightButton.addTarget(self, action: #selector(rotateRightTapped), for: .touchUpInside)

        instructionLabel.text = showsAngleLabels ? "끌어서 이동 · 90°" : "선택됨 · 끌어서 이동"
        instructionLabel.numberOfLines = 1
        instructionLabel.textColor = .white
        instructionLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        instructionLabel.textAlignment = .center
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false

        [rotateLeftButton, instructionLabel, rotateRightButton].forEach(addSubview)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 248),
            heightAnchor.constraint(equalToConstant: 56),

            rotateLeftButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            rotateLeftButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            rotateLeftButton.widthAnchor.constraint(equalToConstant: 44),
            rotateLeftButton.heightAnchor.constraint(equalToConstant: 44),

            instructionLabel.leadingAnchor.constraint(equalTo: rotateLeftButton.trailingAnchor, constant: 8),
            instructionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            rotateRightButton.leadingAnchor.constraint(equalTo: instructionLabel.trailingAnchor, constant: 8),
            rotateRightButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            rotateRightButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            rotateRightButton.widthAnchor.constraint(equalToConstant: 44),
            rotateRightButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func cancelActivePress() {}

    private func configureRotateButton(_ button: UIButton, symbol: String, label: String) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        button.layer.cornerRadius = 22
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = label
        if showsAngleLabels {
            button.setImage(UIImage(systemName: symbol == "rotate.left" ? "arrow.counterclockwise" : "arrow.clockwise",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        }
    }

    @objc private func rotateLeftTapped()  { onRotate?(showsAngleLabels ? .pi / 2 : -.pi / 2) }
    @objc private func rotateRightTapped() { onRotate?(showsAngleLabels ? -.pi / 2 : .pi / 2) }
}

// MARK: - FurnitureRealityKitView (rooms API 버전 상세 기반 3D 뷰어)
//
// B안: capturedRoom이 제공되면 로컬 USDZ를 생성하여 방 shell을 렌더링하고
//       가구는 숨긴 뒤, JSON의 최적화된 가구를 오버레이한다.
// 폴백: capturedRoom이 없으면 JSON 박스 기반 렌더링.

/// 편집 모드에서 옮긴 가구의 새 위치·각도 (서버 ios_objects 형식 그대로)
struct FurniturePoseEdit: Encodable {
    let identifier: String
    let center: [Float]
    let rotation: [Float]
    let dimensions: [Float]?
    let category: String?
    let colorHex: String?
    let operation: String?

    init(identifier: String,
         center: [Float],
         rotation: [Float],
         dimensions: [Float]? = nil,
         category: String? = nil,
         colorHex: String? = nil,
         operation: String? = nil) {
        self.identifier = identifier
        self.center = center
        self.rotation = rotation
        self.dimensions = dimensions
        self.category = category
        self.colorHex = colorHex
        self.operation = operation
    }

    enum CodingKeys: String, CodingKey {
        case identifier, center, rotation, dimensions, category, operation
        case colorHex = "color_hex"
    }
}

/// 3D 뷰 안에서 일어난 편집을 화면(SwiftUI) 쪽에서 꺼내올 수 있게 연결해주는 핸들.
/// RealityKit 좌표를 아는 건 Coordinator뿐이라, 저장 시점에 Coordinator가 계산해서 넘겨준다.
@MainActor
final class FurnitureEditSession: ObservableObject {
    fileprivate var collect: (() -> [FurniturePoseEdit])?
    fileprivate var cancel: (() -> Void)?
    fileprivate var restoreVisibility: (() -> Void)?
    fileprivate var applyHiddenIdentifiers: ((Set<String>) -> Void)?
    fileprivate var addMeasured: ((MeasuredFurnitureDraft) -> Bool)?
    func pendingEdits() -> [FurniturePoseEdit] { collect?() ?? [] }
    func cancelPendingEdits() { cancel?() }
    func restoreFurnitureVisibility() { restoreVisibility?() }
    @discardableResult
    func addMeasuredFurniture(_ draft: MeasuredFurnitureDraft) -> Bool { addMeasured?(draft) ?? false }
    func setHiddenFurnitureIdentifiers(_ identifiers: Set<String>) {
        applyHiddenIdentifiers?(identifiers)
    }
}

struct FurnitureColorLegendItem: Identifiable {
    let id: String
    let title: String
    let color: UIColor
}

struct FurnitureRealityKitView: UIViewRepresentable {
    let detail: RoomVersionDetail
    var capturedRoom: CapturedRoom? = nil   // B안: 제공 시 로컬 USDZ로 방 shell 렌더링
    var isTransparent: Bool = false         // 투명 모드: 반투명 벽 박스
    var allowsLocalFallback: Bool = true
    var onAssetFailure: ((String) -> Void)? = nil
    var onSceneReady: (() -> Void)? = nil
    var onColorLegendReady: (([FurnitureColorLegendItem]) -> Void)? = nil
    /// General V-O viewer only. Challenge keeps its existing presentation and loading path.
    var showsRoomGuides: Bool = false
    var wallColor: UIColor = roomWallNavy
    var floorColor: UIColor = .white
    /// 카탈로그 모델/박스 폴백 가구에 적용할 색상 (nil이면 원래 색 유지). usdc_url로 로드되는
    /// 사용자 본인의 AI 생성 가구(사진 기반)에는 적용하지 않음 — 실제 촬영 결과와 어긋나 보일 수 있어서.
    var furnitureTint: UIColor? = nil
    /// true면 편집 모드 — 가구를 탭해서 선택하고, 빈 바닥을 탭해서 그 자리로 배치하거나
    /// 같은 가구를 다시 탭해서 90도씩 돌릴 수 있음 (내 공간 조회 화면 "가구 편집" 진입 시).
    /// 연속 드래그가 아니라 "최종 위치 한 번만" 검사하는 방식이라 벽 통과 문제가 구조적으로 없음.
    /// false(기본값)면 화면 전체가 카메라 조작(회전/줌) 전용.
    var editMode: Bool = false
    /// AI 배치 상담의 가구 제외 시뮬레이션(F03) 결과 — 여기 포함된 identifier의 가구는
    /// 실제로 3D 뷰에서 숨긴다 (지우는 게 아니라 isEnabled만 끔, 대화가 바뀌면 다시 켜짐).
    var hiddenIdentifiers: Set<String> = []
    /// 편집 모드에서 옮긴 결과를 화면 쪽에서 꺼내가기 위한 연결 고리
    var editSession: FurnitureEditSession? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.environment.background = .color(UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1.0))
        arView.cameraMode = .nonAR
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // 카메라 (초기값 – buildScene 완료 후 방 크기에 맞게 재조정)
        let camAnchor = AnchorEntity(world: .zero)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 60
        camera.position = SIMD3(0, 6, 6)
        camera.look(at: .zero, from: camera.position, relativeTo: nil)
        camAnchor.addChild(camera)
        arView.scene.addAnchor(camAnchor)
        context.coordinator.camera = camera     // 동적 조정용
        context.coordinator.orbitCamera.attach(camera)

        // 조명
        let lightAnchor = AnchorEntity(world: .zero)
        let dir = DirectionalLight()
        dir.light.intensity = 3000; dir.light.color = .white
        dir.shadow = DirectionalLightComponent.Shadow(maximumDistance: 15)
        dir.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0])
        lightAnchor.addChild(dir)
        let pt = PointLight(); pt.light.intensity = 1000; pt.position = [0, 4, 0]
        lightAnchor.addChild(pt)
        arView.scene.addAnchor(lightAnchor)

        // 씬 앵커
        let roomAnchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(roomAnchor)
        context.coordinator.roomAnchor = roomAnchor
        context.coordinator.arView    = arView

        // 씬 빌드 (비동기) – coordinator 전달로 카메라 거리 조정 가능
        let coord = context.coordinator
        coord.setEditMode(editMode)
        editSession?.collect = { [weak coord] in coord?.collectPoseEdits() ?? [] }
        editSession?.cancel = { [weak coord] in coord?.resetFurnitureToBaseline() }
        editSession?.restoreVisibility = { [weak coord] in coord?.showAllFurniture() }
        editSession?.applyHiddenIdentifiers = { [weak coord] identifiers in
            coord?.setHiddenFurnitureIdentifiers(identifiers)
        }
        editSession?.addMeasured = { [weak coord] draft in
            coord?.addMeasuredFurniture(draft) ?? false
        }
        coord.sceneTask = Task { @MainActor in
            await buildScene(into: roomAnchor, coordinator: coord)
        }

        // 제스처 — editMode는 SwiftUI 상태 변경으로 나중에 켜질 수 있고 makeUIView는 다시 안
        // 불리므로, 제스처 자체는 항상 등록해두고 동작 여부는 매번 coordinator.editMode로 판단한다.
        // pan/pinch/rotation은 항상 카메라 전용 — 가구 조작이 더 이상 연속 드래그가 아니라서 경쟁이 없다.
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        panGesture.maximumNumberOfTouches = 1
        panGesture.delegate = context.coordinator
        panGesture.cancelsTouchesInView = false
        arView.addGestureRecognizer(panGesture)
        let cameraPanGesture = UIPanGestureRecognizer(target: context.coordinator,
                                                      action: #selector(Coordinator.handleCameraPan))
        cameraPanGesture.minimumNumberOfTouches = 2
        cameraPanGesture.maximumNumberOfTouches = 2
        cameraPanGesture.delegate = context.coordinator
        cameraPanGesture.cancelsTouchesInView = false
        arView.addGestureRecognizer(cameraPanGesture)
        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator,
                                                    action: #selector(Coordinator.handlePinch))
        pinchGesture.delegate = context.coordinator
        pinchGesture.cancelsTouchesInView = false
        arView.addGestureRecognizer(pinchGesture)
        let rotationGesture = UIRotationGestureRecognizer(target: context.coordinator,
                                                          action: #selector(Coordinator.handleRotation))
        rotationGesture.delegate = context.coordinator
        rotationGesture.cancelsTouchesInView = false
        arView.addGestureRecognizer(rotationGesture)
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tapGesture.delegate = context.coordinator
        tapGesture.cancelsTouchesInView = false
        arView.addGestureRecognizer(tapGesture)

        // 가구 편집 도구 — 방과 가구를 가리지 않도록 선택됐을 때 화면 아래 중앙에 나타난다.
        if showsRoomGuides {
            let overlay = RoomGuideOverlay()
            overlay.arView = arView
            overlay.roomAnchor = roomAnchor
            overlay.items = { [weak coord] in coord?.guideItems() ?? [] }
            overlay.floorY = { [weak coord] in coord?.floorTransform?.columns.3.y ?? 0 }
            overlay.frame = arView.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            arView.addSubview(overlay)
            coord.guideOverlay = overlay
        }
        let handle = FurnitureNudgeHandle(showsAngleLabels: showsRoomGuides)
        handle.isHidden = true
        arView.addSubview(handle)
        NSLayoutConstraint.activate([
            handle.centerXAnchor.constraint(equalTo: arView.centerXAnchor),
            handle.bottomAnchor.constraint(equalTo: arView.safeAreaLayoutGuide.bottomAnchor, constant: -18),
        ])
        handle.onRotate = { [weak coord] angle in coord?.rotateSelectedEntity(by: angle) }
        coord.nudgeHandle = handle

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.editMode != editMode {
            coordinator.setEditMode(editMode)
        }
        // 채팅에서 "이 가구 빼면?" 물어볼 때마다 hiddenIdentifiers가 바뀌고, 여기서 그 가구만
        // 실제로 껐다 켠다 (재생성 없이 바로 반영 — 대화하면서 즉시 확인 가능하게).
        for (id, entity) in coordinator.entitiesByIdentifier {
            entity.isEnabled = !hiddenIdentifiers.contains(id)
        }
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.sceneTask?.cancel()
        coordinator.guideOverlay?.stop()
        coordinator.deselect()
        coordinator.entitiesByIdentifier.removeAll()
        coordinator.identifierByEntity.removeAll()
        coordinator.poseBaseline.removeAll()
        coordinator.newFurnitureIdentifiers.removeAll()
        coordinator.arView = nil
    }

    // MARK: 씬 구성
    // 1) data_url → 가구 배치 JSON
    // 2) JSON walls/floors/doors → 방 구조 박스
    // 3) model_urls USDC → 가구 모델, 없으면 카테고리 색상 박스
    // 4) 씬 전체를 카메라 시야 중앙으로 오도록 anchor 이동 + 카메라 거리 자동 조정

    @MainActor
    private func buildScene(into anchor: AnchorEntity, coordinator: Coordinator) async {

        let effectiveWallColor = wallColor.withAlphaComponent(
            isTransparent ? 0.58 : wallColor.cgColor.alpha
        )

        // ── capturedRoom이 있으면 방 구조 먼저 렌더링 (JSON 결과 기다리지 않음) ──
        if let room = capturedRoom {
            for wall in room.walls {
                let openings = capturedRoomOpenings(wall: wall, doors: room.doors, windows: room.windows)
                wallSegments(wallTransform: wall.transform, wallW: wall.dimensions.x, wallH: wall.dimensions.y,
                             openings: openings, color: effectiveWallColor, depth: 0.04)
                    .forEach { anchor.addChild($0) }
            }
            for floor in room.floors {
                anchor.addChild(makeCapturedSurface(floor, color: floorColor, depth: 0.025))
            }

            // 카메라 거리: capturedRoom 벽 기준
            var allPos = room.walls.compactMap { w -> SIMD3<Float>? in w.transform.columns.3.xyz }
            allPos += room.floors.map { $0.transform.columns.3.xyz }
            adjustCamera(anchor: anchor, coordinator: coordinator, positions: allPos)
        }

        // ── JSON 다운로드 ──────────────────────────────────────────────────────
        guard let dataURLString = detail.effectiveDataUrl,
              let dataURL = URL(string: dataURLString) else {
            onAssetFailure?("서버 원본 공간의 배치 파일이 없습니다.")
            print("⚠️ layout_json_url/data_url 없음 – 방 구조만 표시")
            return
        }

        let payload: RoomDataPayload
        do {
            let (jsonData, _) = try await URLSession.shared.data(from: dataURL)
            payload = try JSONDecoder().decode(RoomDataPayload.self, from: jsonData)
            print("✅ JSON 파싱 완료: 오브젝트 \(payload.objects.count)개")
        } catch {
            onAssetFailure?("서버 공간 데이터를 불러오지 못했습니다.")
            print("❌ data_url 파싱 실패: \(error) – 방 구조만 표시")
            return
        }

        let rawWalls: [(transform: simd_float4x4, halfWidth: Float)]
        if let room = capturedRoom, !room.walls.isEmpty {
            rawWalls = room.walls.map { ($0.transform, $0.dimensions.x / 2) }
        } else {
            rawWalls = (payload.walls ?? []).compactMap { wall in
                guard let t = wall.simdTransform else { return nil }
                let halfWidth = Float(wall.dimensions.count > 0 ? wall.dimensions[0] : 1.0) / 2
                return (t, halfWidth)
            }
        }
        coordinator.wallBarriers = Coordinator.buildWallBarriers(from: rawWalls)

        // 벽 구간 사이 틈(모서리 등)으로 빠져나가는 경우를 잡아주는 2차 안전망 — 바닥 전체를
        // 감싸는 사각형 밖으로는 절대 못 나가게 한다. 벽 클램프만으로 안 잡히는 극단적인 경우 대비.
        if let room = capturedRoom, let floor = room.floors.first {
            coordinator.floorTransform = floor.transform
            coordinator.floorHalfExtent = SIMD2(floor.dimensions.x / 2, floor.dimensions.y / 2)
        } else if let floor = payload.floors?.first, let ft = floor.simdTransform, floor.dimensions.count >= 2 {
            coordinator.floorTransform = ft
            coordinator.floorHalfExtent = SIMD2(floor.dimensions[0] / 2, floor.dimensions[1] / 2)
        }

        // ── capturedRoom이 없을 때만 JSON으로 방 구조 렌더링 ──────────────────
        if capturedRoom == nil {
            var allPos: [SIMD3<Float>] = []
            for w in payload.walls   ?? [] { if let t = w.simdTransform { allPos.append(t.columns.3.xyz) } }
            for f in payload.floors  ?? [] { if let t = f.simdTransform { allPos.append(t.columns.3.xyz) } }
            for o in payload.objects {
                if let c = o.center, c.count >= 3 {
                    allPos.append(SIMD3(c[0], c[1], c[2]))
                } else if let m = o.simdTransform {
                    allPos.append(m.columns.3.xyz)
                }
            }
            adjustCamera(anchor: anchor, coordinator: coordinator, positions: allPos)

            for wall in payload.walls ?? [] {
                guard let wallT = wall.simdTransform else {
                    anchor.addChild(makeSurfaceBox(surface: wall, color: effectiveWallColor, depth: 0.12))
                    continue
                }
                let wallW = wall.dimensions.count > 0 ? wall.dimensions[0] : 1.0
                let wallH = wall.dimensions.count > 1 ? wall.dimensions[1] : 2.4
                let openings = payloadOpenings(wallTransform: wallT, wallW: wallW, wallH: wallH,
                                               doors: payload.doors ?? [], windows: payload.windows ?? [])
                wallSegments(wallTransform: wallT, wallW: wallW, wallH: wallH,
                             openings: openings, color: effectiveWallColor, depth: 0.12)
                    .forEach { anchor.addChild($0) }
            }
            for floor in payload.floors ?? [] {
                anchor.addChild(makeSurfaceBox(surface: floor, color: floorColor, depth: 0.025))
            }
        }

        // layout_json_url 파일의 model_key/usdz_url은 원본엔 아예 없고, 예전에 최적화된 방은
        // 옛날 매핑으로 박제된 값을 그대로 갖고 있어 못 믿는다. ios_objects는 이 요청 시점에
        // 서버가 현재 코드로 새로 계산한 값이라 이걸 identifier로 조회해 우선 사용한다.
        let freshObjectsById = Dictionary(
            (detail.iosObjects ?? []).map { ($0.identifier.lowercased(), $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        // Start at most four downloads at once; identical catalog assets share one request.
        let prefetchTask: Task<Void, Never>? = showsRoomGuides ? Task {
            let urls = payload.objects.compactMap { object -> URL? in
                let fresh = freshObjectsById[object.identifier.lowercased()]
                return (fresh?.usdzUrl ?? detail.catalogUSDZURL(modelKey: fresh?.modelKey ?? object.modelKey,
                    filename: fresh?.modelFileName ?? object.modelFileName) ?? object.usdzUrl).flatMap(URL.init(string:))
            }
            await FurnitureAssetFiles.shared.prefetch(urls)
        } : nil
        defer { prefetchTask?.cancel() }

        // ── 가구 배치 ──────────────────────────────────────────────────────────
        for obj in payload.objects {
            guard !Task.isCancelled else { return }
            guard let matrix = obj.simdTransform else { continue }
            let worldPos = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
            let freshObj = freshObjectsById[obj.identifier.lowercased()]

            var placed = false
            var placedEntity: Entity? = nil

            // Prefer colored USDZ, then legacy USDC. Preserve authored materials.
            let candidates: [(String?, String)] = [
                (freshObj?.usdzUrl, "usdz"),
                (detail.catalogUSDZURL(modelKey: freshObj?.modelKey ?? obj.modelKey,
                                       filename: freshObj?.modelFileName ?? obj.modelFileName), "usdz"),
                (obj.usdzUrl, "usdz"),
                (freshObj?.usdcUrl, "usdc"),
                (obj.usdcUrl, "usdc")
            ]
            var attempted = Set<String>()
            for (candidate, ext) in candidates {
                guard !placed, let value = candidate, !value.isEmpty,
                      attempted.insert(value).inserted, let remoteURL = URL(string: value) else { continue }
                do {
                    let loaded: Entity
                    if showsRoomGuides {
                        loaded = try await FurnitureModelTemplates.shared.load(remoteURL, fileExtension: ext)
                    } else {
                        var request = URLRequest(url: remoteURL)
                        request.cachePolicy = .reloadIgnoringLocalCacheData
                        let (tmpURL, response) = try await URLSession.shared.download(for: request)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                            throw URLError(.badServerResponse)
                        }
                        let destURL = URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent(UUID().uuidString + "." + ext)
                        try FileManager.default.moveItem(at: tmpURL, to: destURL)
                        defer { try? FileManager.default.removeItem(at: destURL) }
                        loaded = try Entity.loadSync(contentsOf: destURL)
                    }
                    guard !Task.isCancelled else { return }
                    applyTransform(to: loaded, matrix: matrix, worldPos: worldPos, obj: obj)
                    anchor.addChild(loaded)
                    placed = true
                    placedEntity = loaded
                    print("✅ 가구 \(obj.identifier): 서버 \(ext) 재질 유지")
                } catch {
                    print("⚠️ 가구 \(obj.identifier): 서버 \(ext) 실패 (\(error.localizedDescription))")
                }
            }

            // 3. 없거나 실패하면 앱에 내장된 RoomPlanCatalog.bundle로 폴백
            // (오프라인에서도 기본 가구는 항상 보이도록)
            if !placed, allowsLocalFallback, let fileName = freshObj?.modelKey ?? obj.modelKey ?? freshObj?.modelFileName ?? obj.modelFileName,
               let localURL = findCatalogModel(named: fileName) {
                do {
                    let loaded: Entity
                    if showsRoomGuides {
                        loaded = try await FurnitureModelTemplates.shared.loadLocal(localURL)
                    } else {
                        loaded = try Entity.loadSync(contentsOf: localURL)
                    }
                    guard !Task.isCancelled else { return }
                    applyTransform(to: loaded, matrix: matrix, worldPos: worldPos, obj: obj)
                    if let furnitureTint {
                        applyTint(to: loaded, color: furnitureTint)
                    } else {
                        applyPreviewColor(to: loaded, color: colorForCategory(obj.category ?? ""))
                    }
                    anchor.addChild(loaded)
                    placed = true
                    placedEntity = loaded
                    print("  ✅ \(obj.category ?? "") (\(fileName)) 로컬 카탈로그 로드 성공")
                } catch {
                    print("  ⚠️ \(obj.category ?? "") (\(fileName)) 로컬 로드 실패: \(error)")
                }
            }

            // 4. 박스 폴백 — allowsLocalFallback 여부와 무관하게 항상 적용한다.
            // allowsLocalFallback=false는 "로컬 흰 카탈로그 모델을 먼저 보여주지 말라"는 뜻이지
            // "대응 모델 없는 가구를 아예 숨기라"는 뜻이 아니다. 서버에 대응 모델이 없는 가구도
            // 카테고리 색상 OBB로는 항상 표시해야 방 전체 미리보기가 빈 자리 없이 완성된다.
            if !placed {
                print("  📦 \(obj.category ?? ""): 박스 폴백")
                let box = makeFallbackBox(for: obj)
                box.transform = Transform(matrix: matrix)
                anchor.addChild(box)
                placedEntity = box
                if !allowsLocalFallback {
                    onAssetFailure?("일부 서버 가구 모델을 불러오지 못했어요. 다시 불러오기를 눌러주세요.")
                }
            }
            // 히트테스트용 이름 + 콜리전 부여 (카탈로그 모델은 메쉬가 자식 노드일 수 있어 recursive) —
            // editMode가 나중에 켜질 수도 있으니 항상 준비해둔다.
            if let placedEntity {
                placedEntity.name = "furniture_\(obj.identifier)"
                placedEntity.generateCollisionShapes(recursive: true)
                // AI 배치 상담의 가구 제외 시뮬레이션이 나중에 켜고 끌 수 있도록 식별자로 등록
                coordinator.entitiesByIdentifier[obj.identifier] = placedEntity
                coordinator.identifierByEntity[ObjectIdentifier(placedEntity)] = obj.identifier
                // 편집 저장 때 "얼마나 움직였는지" 비교할 기준값. applyTransform이 모델 중심을
                // 맞추려고 위치를 pivot만큼 밀어놨을 수 있어서, 그 보정량도 같이 기억해둔다.
                let renderedBounds = placedEntity.visualBounds(relativeTo: anchor)
                let renderedSize = renderedBounds.max - renderedBounds.min
                let rawDimensions = obj.dimensions ?? []
                let collisionDimensions = SIMD3<Float>(
                    rawDimensions.indices.contains(0) && rawDimensions[0] > 0 ? rawDimensions[0] : renderedSize.x,
                    rawDimensions.indices.contains(1) && rawDimensions[1] > 0 ? rawDimensions[1] : renderedSize.y,
                    rawDimensions.indices.contains(2) && rawDimensions[2] > 0 ? rawDimensions[2] : renderedSize.z
                )
                coordinator.poseBaseline[obj.identifier] = Coordinator.PoseBaseline(
                    centerOffset: placedEntity.orientation.inverse.act(worldPos - placedEntity.position),
                    center: worldPos,
                    yaw: Coordinator.serverYaw(of: placedEntity.orientation),
                    transform: placedEntity.transform,
                    dimensions: collisionDimensions,
                    isNew: false,
                    colorHex: obj.colorHex,
                    category: obj.category
                )
                // Preserve server coordinates on load. Wall clamping belongs to
                // explicit user edits; independently pushing objects creates overlaps.
            }
        }
        guard !Task.isCancelled else { return }
        if let onColorLegendReady {
            var seen = Set<String>()
            let items = payload.objects.compactMap { object -> FurnitureColorLegendItem? in
                guard let entity = coordinator.entitiesByIdentifier[object.identifier] else { return nil }
                let category = (object.category ?? "").lowercased()
                let color = representativeColor(of: entity) ?? colorForCategory(category)
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, opacity: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &opacity)
                let isYellowStorage = (0.10...0.19).contains(hue) && saturation > 0.35 && brightness > 0.4
                let title: String
                switch category {
                case "bed": title = "침대"
                case "table": title = "책상·테이블"
                case "chair": title = "의자"
                case "sofa": title = "소파"
                case "storage": title = isYellowStorage ? "서랍장" : "옷장·수납장"
                case "television": title = "TV"
                case "refrigerator": title = "냉장고"
                case "washerdryer": title = "세탁기"
                default: title = "기타 가구"
                }
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                let key = "\(title)-\(Int(red * 255))-\(Int(green * 255))-\(Int(blue * 255))"
                guard seen.insert(key).inserted else { return nil }
                return FurnitureColorLegendItem(id: key, title: title, color: color)
            }
            onColorLegendReady(items)
        }
        if coordinator.poseBaseline.isEmpty {
            onAssetFailure?("편집할 가구가 없어요. 운영자에게 이벤트 배치를 확인해 달라고 알려주세요.")
        } else {
            onSceneReady?()
        }
    }

    /// Prefer the colored body over white bedding or dark legs in multipart models.
    private func representativeColor(of entity: Entity) -> UIColor? {
        var candidates: [UIColor] = []
        func collect(_ node: Entity) {
            if let model = node as? ModelEntity {
                for material in model.model?.materials ?? [] {
                    if let simple = material as? SimpleMaterial, simple.color.texture == nil {
                        candidates.append(simple.color.tint)
                    } else if let pbr = material as? PhysicallyBasedMaterial, pbr.baseColor.texture == nil {
                        candidates.append(pbr.baseColor.tint)
                    }
                }
            }
            for child in node.children { collect(child) }
        }
        func prominence(_ color: UIColor) -> CGFloat {
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return alpha > 0.1 ? saturation * brightness : -1
        }
        collect(entity)
        return candidates.max { prominence($0) < prominence($1) }
    }

    // MARK: - OBB 충돌 해소

    private struct OBB2D {
        var cx: Float
        var cz: Float
        let halfW: Float           // local X 방향 반폭
        let halfD: Float           // local Z 방향 반폭
        let axisX: SIMD2<Float>    // world XZ 평면에서 local X 축
        let axisZ: SIMD2<Float>    // world XZ 평면에서 local Z 축

        var center: SIMD2<Float> { SIMD2(cx, cz) }

        func project(onto axis: SIMD2<Float>) -> ClosedRange<Float> {
            let c = dot(center, axis)
            let r = abs(dot(axisX * halfW, axis)) + abs(dot(axisZ * halfD, axis))
            return (c - r)...(c + r)
        }
    }

    // SAT: 겹치면 MTV 반환 (a를 +방향, b를 -방향으로 밀어낼 벡터), 안 겹치면 nil
    private func satMTV(_ a: OBB2D, _ b: OBB2D) -> SIMD2<Float>? {
        var minOverlap = Float.infinity
        var bestAxis   = SIMD2<Float>.zero

        for axis in [a.axisX, a.axisZ, b.axisX, b.axisZ] {
            let pA = a.project(onto: axis)
            let pB = b.project(onto: axis)
            let overlap = min(pA.upperBound, pB.upperBound) - max(pA.lowerBound, pB.lowerBound)
            if overlap <= 0 { return nil }
            if overlap < minOverlap {
                minOverlap = overlap
                var dir = axis
                if dot(a.center - b.center, axis) < 0 { dir = -dir }
                bestAxis = dir
            }
        }
        return bestAxis * minOverlap
    }

    private func resolveCollisions(_ objects: [RoomDataPayload.RoomObject],
                                   floors: [RoomDataPayload.RoomSurface]? = nil,
                                   walls:  [RoomDataPayload.RoomSurface]? = nil) -> [SIMD3<Float>] {
        var centers: [SIMD3<Float>] = objects.map { obj in
            if let m = obj.simdTransform { return m.columns.3.xyz }
            if let c = obj.center, c.count >= 3 { return SIMD3(c[0], c[1], c[2]) }
            return .zero
        }

        // ── 경계 1: 바닥 직사각형 클램프 ───────────────────────────────
        struct RoomBounds {
            let cx: Float; let cz: Float
            let axX: SIMD2<Float>; let axZ: SIMD2<Float>
            let halfW: Float; let halfD: Float
        }
        let roomBounds: RoomBounds? = {
            guard let f = floors?.first, let ft = f.simdTransform, f.dimensions.count >= 2 else { return nil }
            return RoomBounds(
                cx: ft.columns.3.x, cz: ft.columns.3.z,
                axX: SIMD2(ft.columns.0.x, ft.columns.0.z),
                axZ: SIMD2(ft.columns.1.x, ft.columns.1.z),
                halfW: f.dimensions[0] / 2, halfD: f.dimensions[1] / 2
            )
        }()

        func clampToFloor(_ i: Int) {
            guard let b = roomBounds else { return }
            let d  = objects[i].dimensions ?? []
            let hw = (d.count >= 1 ? d[0] : 0.5) / 2
            let hd = (d.count >= 3 ? d[2] : 0.5) / 2
            let offX = centers[i].x - b.cx; let offZ = centers[i].z - b.cz
            var lx = offX * b.axX.x + offZ * b.axX.y
            var lz = offX * b.axZ.x + offZ * b.axZ.y
            lx = max(-(b.halfW - hw), min(b.halfW - hw, lx))
            lz = max(-(b.halfD - hd), min(b.halfD - hd, lz))
            centers[i].x = b.cx + lx * b.axX.x + lz * b.axZ.x
            centers[i].z = b.cz + lx * b.axX.y + lz * b.axZ.y
        }

        // ── 경계 2: 벽 법선 방향 클램프 ─────────────────────────────────
        // RoomPlan 벽 법선(col2)은 방 안쪽을 향하므로, distFromWall < objRadius 이면 벽 쪽으로 침범
        func clampToWalls(_ i: Int) {
            guard let walls else { return }
            let d  = objects[i].dimensions ?? []
            let hw = (d.count >= 1 ? d[0] : 0.5) / 2
            let hd = (d.count >= 3 ? d[2] : 0.5) / 2
            let objRadius = max(hw, hd)
            for wall in walls {
                guard let wt = wall.simdTransform else { continue }
                let normXZ = SIMD2<Float>(wt.columns.2.x, wt.columns.2.z)
                let nLen   = length(normXZ); guard nLen > 0.001 else { continue }
                let wallNorm = normXZ / nLen
                let wallDir  = SIMD2<Float>(wt.columns.0.x, wt.columns.0.z)
                let wCenterXZ = SIMD2<Float>(wt.columns.3.x, wt.columns.3.z)
                let toObj = SIMD2<Float>(centers[i].x, centers[i].z) - wCenterXZ
                // 벽 측면 범위 밖은 무관
                let wallHalfW = (wall.dimensions.count > 0 ? wall.dimensions[0] : 1.0) / 2
                guard abs(dot(toObj, wallDir)) < wallHalfW + objRadius else { continue }
                // 법선 방향 거리가 objRadius 미만이면 밀어냄
                let distFromWall = dot(toObj, wallNorm)
                if distFromWall < objRadius {
                    let push = objRadius - distFromWall
                    centers[i].x += wallNorm.x * push
                    centers[i].z += wallNorm.y * push
                }
            }
        }

        func makeOBB(_ obj: RoomDataPayload.RoomObject, cx: Float, cz: Float) -> OBB2D? {
            guard let m = obj.simdTransform, let d = obj.dimensions, d.count >= 3 else { return nil }
            let ax = SIMD2<Float>(m.columns.0.x, m.columns.0.z)
            let az = SIMD2<Float>(m.columns.2.x, m.columns.2.z)
            let lenX = length(ax), lenZ = length(az)
            guard lenX > 0.001, lenZ > 0.001 else { return nil }
            return OBB2D(cx: cx, cz: cz, halfW: d[0]/2, halfD: d[2]/2,
                         axisX: ax/lenX, axisZ: az/lenZ)
        }

        // 시작 전 초기 위치도 경계 안으로 정렬
        for i in 0..<objects.count { clampToFloor(i); clampToWalls(i) }

        for _ in 0..<30 {
            var moved = false
            for i in 0..<objects.count {
                for j in (i + 1)..<objects.count {
                    guard let obbA = makeOBB(objects[i], cx: centers[i].x, cz: centers[i].z),
                          let obbB = makeOBB(objects[j], cx: centers[j].x, cz: centers[j].z)
                    else { continue }
                    if let mtv = satMTV(obbA, obbB) {
                        centers[i].x += mtv.x / 2; centers[i].z += mtv.y / 2
                        centers[j].x -= mtv.x / 2; centers[j].z -= mtv.y / 2
                        clampToFloor(i); clampToWalls(i)
                        clampToFloor(j); clampToWalls(j)
                        moved = true
                    }
                }
            }
            if !moved { break }
        }
        return centers
    }

    /// anchor 센터링 + 카메라 거리 조정
    private func adjustCamera(anchor: AnchorEntity, coordinator: Coordinator, positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        let xs = positions.map(\.x), ys = positions.map(\.y), zs = positions.map(\.z)
        let minX = xs.min()!, maxX = xs.max()!
        let minZ = zs.min()!, maxZ = zs.max()!
        let minY = ys.min()!
        anchor.position = SIMD3(-(minX + maxX) / 2, -minY, -(minZ + maxZ) / 2)
        // 중심점만으로 크기를 재면 벽 끝이나 큰 가구의 바깥쪽이 빠져 편집 화면에서 잘릴 수 있다.
        // 실제 렌더링 바운드까지 포함해 여유 있는 카메라 거리를 계산한다.
        let visualBounds = anchor.visualBounds(relativeTo: anchor)
        let visualSize = visualBounds.max - visualBounds.min
        let roomSize = max(max(maxX - minX, maxZ - minZ), max(visualSize.x, visualSize.z))
        let dist = min(max(roomSize * 0.75 + 2.5, 4.0), 14.0)
        coordinator.defaultCameraDistance = dist
        if coordinator.editMode {
            coordinator.applyTopDownCamera(roomSize: roomSize)
        } else {
            coordinator.orbitCamera.setPosition(SIMD3(0, dist, dist))
        }
    }

    /// 모델에 transform 적용 (bounds 스케일링 포함)
    private func applyTransform(to entity: Entity,
                                matrix: simd_float4x4,
                                worldPos: SIMD3<Float>,
                                obj: RoomDataPayload.RoomObject) {
        let bounds = entity.visualBounds(relativeTo: entity)
        let bSize  = bounds.max - bounds.min
        let dims   = obj.dimensions ?? []

        if dims.count >= 3, dims.prefix(3).allSatisfy({ $0.isFinite && $0 > 0 }),
           bSize.x > 0.001, bSize.y > 0.001, bSize.z > 0.001 {
            // Match the optimizer's footprint on every axis. An averaged scale can
            // enlarge width/depth and make a non-overlapping layout appear intersecting.
            let axisScales = SIMD3<Float>(dims[0] / bSize.x, dims[1] / bSize.y, dims[2] / bSize.z)
            let scale = axisScales
            let pivot = (bounds.max + bounds.min) / 2
            let orientation = simd_quatf(matrix)
            // rotation 적용 후 pivot 오프셋을 보정해야 center가 worldPos에 정확히 놓임
            entity.scale       = scale
            entity.orientation = orientation
            entity.position    = worldPos - orientation.act(pivot * scale)
            print("🪵 [디버그] applyTransform cat=\(obj.category ?? "?") worldPos=\(worldPos) bounds.min=\(bounds.min) bounds.max=\(bounds.max) pivot=\(pivot) scale=\(scale) finalPos=\(entity.position) shiftFromWorldPos=\(entity.position - worldPos)")
        } else {
            entity.transform = Transform(matrix: matrix)
        }
    }

    /// RoomPlanCatalog.bundle 내에서 파일명으로 모델 URL 검색
    private func findCatalogModel(named fileName: String) -> URL? {
        guard let bundleURL = Bundle.main.url(forResource: "RoomPlanCatalog", withExtension: "bundle") else { return nil }

        // Full keys disambiguate repeated names in different catalog variants.
        let normalized = fileName.replacingOccurrences(of: "\\", with: "/")
        let basename = (normalized as NSString).lastPathComponent
        var matches: [URL] = []
        let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            if normalized.contains("/"), fileURL.path.hasSuffix("/" + normalized) { return fileURL }
            if fileURL.lastPathComponent == basename { matches.append(fileURL) }
        }
        return matches.count == 1 ? matches.first : nil
    }


    /// CapturedRoom.Surface를 박스 ModelEntity로 변환 (바닥 덮기용)
    private func makeCapturedSurface(_ s: CapturedRoom.Surface, color: UIColor, depth: Float) -> ModelEntity {
        var mat = SimpleMaterial()
        mat.color = .init(tint: color); mat.roughness = 0.9; mat.metallic = 0.0
        let entity = ModelEntity(
            mesh: .generateBox(width: s.dimensions.x, height: s.dimensions.y, depth: depth),
            materials: [mat]
        )
        entity.transform = Transform(matrix: s.transform)
        return entity
    }

    private func makeSurfaceBox(surface: RoomDataPayload.RoomSurface,
                                color: UIColor,
                                depth: Float) -> ModelEntity {
        let dims = surface.dimensions
        let w = dims.count > 0 ? dims[0] : 1.0
        let h = dims.count > 1 ? dims[1] : 1.0
        var mat = SimpleMaterial()
        mat.color = .init(tint: color); mat.roughness = 0.9
        let entity = ModelEntity(
            mesh: .generateBox(size: SIMD3(w, h, depth), cornerRadius: 0.0),
            materials: [mat]
        )
        if let matrix = surface.simdTransform {
            entity.transform = Transform(matrix: matrix)
        }
        return entity
    }

    /// 카테고리별 색상 박스 (배경색과 겹치지 않는 뚜렷한 색상). furnitureTint 있으면 그걸로 통일.
    private func makeFallbackBox(for obj: RoomDataPayload.RoomObject) -> ModelEntity {
        var mat = SimpleMaterial()
        let savedColor = obj.colorHex.flatMap(UIColor.voColor(hex:))
        mat.color = .init(tint: furnitureTint ?? savedColor ?? colorForCategory(obj.category ?? ""))
        mat.roughness = 0.9
        let raw = obj.dimensions ?? []
        let dims = (0..<3).map { index -> Float in
            guard raw.indices.contains(index), raw[index].isFinite, raw[index] > 0 else { return 0.5 }
            return raw[index]
        }
        return ModelEntity(
            mesh: .generateBox(
                size: SIMD3(dims[0], dims[1], dims[2]),
                cornerRadius: 0.03
            ),
            materials: [mat]
        )
    }

    private func colorForCategory(_ category: String) -> UIColor {
        switch category.lowercased() {
        case "bed":          return UIColor(red: 0.95, green: 0.80, blue: 0.83, alpha: 1.0)
        case "sofa", "chair": return UIColor(red: 0.72, green: 0.83, blue: 0.90, alpha: 1.0)
        case "table":        return UIColor(red: 0.88, green: 0.82, blue: 0.72, alpha: 1.0)
        case "storage":      return UIColor(red: 0.78, green: 0.82, blue: 0.76, alpha: 1.0)
        case "television":   return UIColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1.0)
        case "refrigerator": return UIColor(red: 0.88, green: 0.90, blue: 0.92, alpha: 1.0)
        case "washerdryer":  return UIColor(red: 0.82, green: 0.88, blue: 0.92, alpha: 1.0)
        default:             return UIColor(red: 0.80, green: 0.78, blue: 0.75, alpha: 1.0)
        }
    }

    // MARK: Coordinator
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var arView: ARView?
        var roomAnchor: AnchorEntity?
        var camera: PerspectiveCamera?          // 카메라 거리 동적 조정용
        let orbitCamera = RoomOrbitCamera()
        private(set) var editMode: Bool = false
        var defaultCameraDistance: Float = 6
        var sceneTask: Task<Void, Never>?
        /// identifier → 배치된 엔티티. AI 배치 상담의 가구 제외 시뮬레이션이 이걸로 보이기/숨기기 전환
        var entitiesByIdentifier: [String: Entity] = [:]
        var identifierByEntity: [ObjectIdentifier: String] = [:]

        /// 씬을 만들 때의 가구 자세 — 저장할 때 실제로 움직인 가구만 골라내는 기준이 된다.
        struct PoseBaseline {
            /// 엔티티 위치와 가구 중심의 차이 (가구 좌표계 기준이라 회전해도 그대로 쓸 수 있음)
            let centerOffset: SIMD3<Float>
            let center: SIMD3<Float>
            let yaw: Float
            let transform: Transform
            /// 서버가 전달한 RoomPlan OBB 치수. 렌더 모델의 숨은 여백과 무관한 충돌 기준이다.
            let dimensions: SIMD3<Float>
            let isNew: Bool
            let colorHex: String?
            let category: String?
        }
        var poseBaseline: [String: PoseBaseline] = [:]
        var newFurnitureIdentifiers: Set<String> = []

        /// 서버 JSON의 회전 표기(transform 첫 열이 [cos, 0, sin])에 맞춘 yaw 값
        static func serverYaw(of orientation: simd_quatf) -> Float {
            let axis = orientation.act(SIMD3<Float>(1, 0, 0))
            return atan2(axis.z, axis.x)
        }

        /// 처음 위치·각도에서 실제로 바뀐 가구만 서버 형식으로 뽑아낸다.
        func collectPoseEdits() -> [FurniturePoseEdit] {
            var edits: [FurniturePoseEdit] = []
            for (identifier, entity) in entitiesByIdentifier {
                guard let base = poseBaseline[identifier] else { continue }
                let center = entity.position + entity.orientation.act(base.centerOffset)
                let yaw = Self.serverYaw(of: entity.orientation)
                let moved = length(SIMD2(center.x - base.center.x, center.z - base.center.z)) > 0.005
                let turned = abs(atan2(sin(yaw - base.yaw), cos(yaw - base.yaw))) > 0.01
                guard moved || turned || base.isNew else { continue }
                edits.append(FurniturePoseEdit(
                    identifier: identifier,
                    center: [center.x, base.center.y, center.z],
                    rotation: [0, yaw, 0],
                    dimensions: base.isNew ? [base.dimensions.x, base.dimensions.y, base.dimensions.z] : nil,
                    category: base.isNew ? base.category : nil,
                    colorHex: base.isNew ? base.colorHex : nil,
                    operation: base.isNew ? "create" : nil
                ))
            }
            return edits
        }

        func resetFurnitureToBaseline() {
            deselect()
            let addedIdentifiers = newFurnitureIdentifiers
            for (identifier, entity) in entitiesByIdentifier {
                if addedIdentifiers.contains(identifier) {
                    entity.removeFromParent()
                    continue
                }
                if let baseline = poseBaseline[identifier] {
                    entity.transform = baseline.transform
                }
                entity.isEnabled = true
            }
            for identifier in addedIdentifiers {
                entitiesByIdentifier[identifier] = nil
                poseBaseline[identifier] = nil
            }
            identifierByEntity = identifierByEntity.filter { !addedIdentifiers.contains($0.value) }
            newFurnitureIdentifiers.removeAll()
        }

        func showAllFurniture() {
            entitiesByIdentifier.values.forEach { $0.isEnabled = true }
        }

        func setHiddenFurnitureIdentifiers(_ hiddenIdentifiers: Set<String>) {
            for (identifier, entity) in entitiesByIdentifier {
                entity.isEnabled = !hiddenIdentifiers.contains(identifier)
            }
        }

        /// 별도 LiDAR 측정 화면에서 얻은 치수로 새 OBB 가구를 방에 넣는다. 스캔한 실제 공간과
        /// 저장된 방은 서로 다른 AR 좌표계이므로, 측정 화면의 위치는 쓰지 않고 방 안의 비어 있는
        /// 지점을 찾아 배치한다. 이후 사용자가 기존 편집 방식으로 정확한 위치를 정한다.
        func addMeasuredFurniture(_ draft: MeasuredFurnitureDraft) -> Bool {
            guard let roomAnchor,
                  draft.dimensions.x.isFinite, draft.dimensions.y.isFinite, draft.dimensions.z.isFinite,
                  draft.dimensions.x > 0.02, draft.dimensions.y > 0.02, draft.dimensions.z > 0.02 else {
                return false
            }

            deselect()
            var material = SimpleMaterial()
            material.color = .init(tint: UIColor.voColor(hex: draft.colorHex) ?? .systemBrown)
            material.roughness = 0.88
            let entity = ModelEntity(
                mesh: .generateBox(size: draft.dimensions, cornerRadius: 0.035),
                materials: [material]
            )
            entity.name = "furniture_\(draft.id)"
            entity.generateCollisionShapes(recursive: true)
            roomAnchor.addChild(entity)

            let floorY = floorTransform?.columns.3.y ?? 0
            let provisionalCenter = SIMD3<Float>(0, floorY + draft.dimensions.y / 2, 0)
            entity.position = provisionalCenter
            entitiesByIdentifier[draft.id] = entity
            identifierByEntity[ObjectIdentifier(entity)] = draft.id
            newFurnitureIdentifiers.insert(draft.id)
            poseBaseline[draft.id] = PoseBaseline(
                centerOffset: .zero,
                center: provisionalCenter,
                yaw: 0,
                transform: entity.transform,
                dimensions: draft.dimensions,
                isNew: true,
                colorHex: draft.colorHex,
                category: "custom"
            )

            // 바닥 중앙부터 바깥쪽으로 탐색해 다른 가구와 겹치지 않는 첫 지점을 사용한다.
            var candidates: [SIMD3<Float>] = []
            if let floorTransform, let halfExtent = floorHalfExtent {
                let usableX = max(0, halfExtent.x - draft.dimensions.x / 2 - 0.05)
                let usableY = max(0, halfExtent.y - draft.dimensions.z / 2 - 0.05)
                let step: Float = 0.35
                var x = -usableX
                while x <= usableX + 0.001 {
                    var y = -usableY
                    while y <= usableY + 0.001 {
                        let point = floorTransform * SIMD4<Float>(x, y, 0, 1)
                        candidates.append(SIMD3(point.x, floorY + draft.dimensions.y / 2, point.z))
                        y += step
                    }
                    x += step
                }
                candidates.sort {
                    let center = floorTransform.columns.3
                    let lhs = SIMD2($0.x - center.x, $0.z - center.z)
                    let rhs = SIMD2($1.x - center.x, $1.z - center.z)
                    return length_squared(lhs) < length_squared(rhs)
                }
            } else {
                candidates = [provisionalCenter]
            }

            var chosen = provisionalCenter
            for candidate in candidates {
                entity.position = candidate
                clampEntityToWalls(entity)
                if furnitureCollisionScore(for: entity) <= 0.0001 {
                    chosen = entity.position(relativeTo: roomAnchor)
                    break
                }
            }
            entity.position = chosen
            poseBaseline[draft.id] = PoseBaseline(
                centerOffset: .zero,
                center: chosen,
                yaw: 0,
                transform: entity.transform,
                dimensions: draft.dimensions,
                isNew: true,
                colorHex: draft.colorHex,
                category: "custom"
            )
            select(entity)
            return true
        }
        /// 편집 모드에서 선택된 가구를 옮기는 오른쪽 핸들바 — 선택 여부에 따라 보이기/숨기기
        var nudgeHandle: FurnitureNudgeHandle?
        var guideOverlay: RoomGuideOverlay?

        func guideItems() -> [RoomGuideItem] {
            guard let roomAnchor else { return [] }
            return entitiesByIdentifier.compactMap { identifier, entity in
                guard entity.isEnabled, let baseline = poseBaseline[identifier] else { return nil }
                let center = entity.position(relativeTo: roomAnchor) + entity.orientation.act(baseline.centerOffset)
                let point = center + SIMD3<Float>(0, baseline.dimensions.y / 2 + 0.06, 0)
                return RoomGuideItem(id: identifier,
                    title: RoomGuideOverlay.furnitureName(category: baseline.category ?? "", height: baseline.dimensions.y),
                    worldPoint: roomAnchor.convert(position: point, to: nil), selected: entity === selectedEntity,
                    sizeText: String(format: "%.0f × %.0f cm", baseline.dimensions.x * 100, baseline.dimensions.z * 100))
            }
        }

        /// 벽 클램프의 2차 안전망 — 바닥 전체 사각형 (벽 구간 사이 틈으로 빠져나가는 극단적인 경우 대비)
        var floorTransform: simd_float4x4?
        var floorHalfExtent: SIMD2<Float>?

        /// 드래그 클램프용 벽 하나 — 법선은 항상 방 안쪽을 향하도록 미리 보정해둔 값이라
        /// (원본 transform의 축 부호 규칙을 그대로 믿지 않음) clampEntityToWalls에서 부호 걱정 없이 바로 쓸 수 있다.
        struct WallBarrier {
            let center: SIMD3<Float>
            let normal: SIMD3<Float>
            let right: SIMD3<Float>
            let halfWidth: Float
        }
        var wallBarriers: [WallBarrier] = []

        /// 벽들의 중심(centroid)을 향하는 쪽을 "방 안쪽"으로 간주해서 각 벽 법선의 부호를 보정한다.
        /// RoomPlan 원본이든 서버가 재가공한 JSON이든, transform의 +Z가 안쪽/바깥쪽 어느 쪽을
        /// 가리키는지 신뢰하지 않고 실제 방 형태로부터 방향을 직접 도출한다.
        static func buildWallBarriers(from raw: [(transform: simd_float4x4, halfWidth: Float)]) -> [WallBarrier] {
            guard !raw.isEmpty else { return [] }
            let centers = raw.map { SIMD3($0.transform.columns.3.x, $0.transform.columns.3.y, $0.transform.columns.3.z) }
            let centroid = centers.reduce(SIMD3<Float>.zero, +) / Float(centers.count)

            return raw.compactMap { item in
                let rawNormal = SIMD3(item.transform.columns.2.x, item.transform.columns.2.y, item.transform.columns.2.z)
                let rawRight  = SIMD3(item.transform.columns.0.x, item.transform.columns.0.y, item.transform.columns.0.z)
                guard length(rawNormal) > 0.01, length(rawRight) > 0.01 else { return nil }
                let center = SIMD3(item.transform.columns.3.x, item.transform.columns.3.y, item.transform.columns.3.z)
                var normal = normalize(rawNormal)
                if dot(centroid - center, normal) < 0 { normal = -normal }
                return WallBarrier(center: center, normal: normal, right: normalize(rawRight), halfWidth: item.halfWidth)
            }
        }

        private var lastRotation: Float = 0
        private var preEditRoomOrientation: simd_quatf?
        private var preEditRoomScale: SIMD3<Float>?
        private var preEditCameraTransform: Transform?

        /// 편집 중에는 화면과 방 좌표가 서로 달라지지 않도록 방을 원래 축/크기로 고정하고
        /// 카메라를 수직 위보기로 전환한다. 편집을 끝내면 사용자가 보던 시점만 복원한다.
        func setEditMode(_ enabled: Bool) {
            guard editMode != enabled else { return }

            if enabled {
                preEditRoomOrientation = roomAnchor?.orientation
                preEditRoomScale = roomAnchor?.scale
                preEditCameraTransform = camera?.transform
                editMode = true
                deselect()

                if let roomAnchor {
                    roomAnchor.orientation = simd_quatf()
                    roomAnchor.scale = SIMD3(repeating: 1)
                }
                lastRotation = 0
                applyTopDownCamera()
            } else {
                deselect()
                editMode = false
                if let orientation = preEditRoomOrientation {
                    roomAnchor?.orientation = orientation
                }
                if let scale = preEditRoomScale {
                    roomAnchor?.scale = scale
                }
                if let transform = preEditCameraTransform {
                    camera?.transform = transform
                    orbitCamera.syncFromCamera()
                }
                preEditRoomOrientation = nil
                preEditRoomScale = nil
                preEditCameraTransform = nil
                panTarget = .none
                dragPlaneY = nil
                dragOffsetXZ = .zero
            }
        }

        /// 편집용 고정 카메라. 완전 수직보다는 아주 살짝 기울여 가구 높이가 보이게 하고,
        /// 방 가장자리 가구가 잘리지 않도록 일반 보기보다 충분히 높게 배치한다.
        func applyTopDownCamera(roomSize: Float? = nil) {
            let desiredHeight = roomSize.map { $0 * 1.65 + 2.0 } ?? (defaultCameraDistance * 1.6)
            let height = min(max(desiredHeight, 7), 24)
            let pitch: Float = .pi * 0.44
            orbitCamera.setPose(yaw: 0,
                                pitch: pitch,
                                distance: height / max(sin(pitch), 0.01))
        }

        /// 편집 모드에서 현재 선택된 가구 — 탭으로 골라두면 확대 표시되고, 그 상태에서 빈 바닥을
        /// 탭하면 그 자리로 배치된다. 연속 드래그가 아니라 "탭 한 번 = 위치 확정"이라 벽 통과가
        /// 구조적으로 발생하지 않는다 (최종 위치 딱 한 번만 clampEntityToWalls로 검사).
        private var selectedEntity: Entity?
        private var selectedOriginalScale: SIMD3<Float>?
        private var selectionIndicator: Entity?
        private enum PanTarget { case none, camera, furniture }
        private var panTarget: PanTarget = .none
        private var dragPlaneY: Float?
        private var dragOffsetXZ = SIMD2<Float>.zero

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { orbitCamera.pinchBegan() }
            orbitCamera.pinch(scale: g.scale)
        }

        /// 한 손가락은 가구 이동, 두 손가락 드래그는 카메라 시점 변경으로 분리한다.
        @objc func handleCameraPan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            orbitCamera.pan(g.translation(in: arView))
            g.setTranslation(.zero, in: arView)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                if current === arView { break }
                view = current.superview
            }
            return true
        }

        @objc func handleRotation(_ g: UIRotationGestureRecognizer) {
            if g.state == .began { lastRotation = 0 }
            let delta = Float(g.rotation) - lastRotation
            lastRotation = Float(g.rotation)
            if editMode {
                guard let selectedEntity else { return }
                let originalTransform = selectedEntity.transform
                let originalCollision = furnitureCollisionScore(for: selectedEntity)
                selectedEntity.orientation *= simd_quatf(angle: -delta, axis: [0, 1, 0])
                clampEntityToWalls(selectedEntity)
                if !isAcceptableCollisionChange(from: originalCollision,
                                                to: furnitureCollisionScore(for: selectedEntity)) {
                    selectedEntity.transform = originalTransform
                }
                updateSelectionIndicatorTransform()
            } else {
                orbitCamera.rotate(by: delta)
            }
        }

        /// 편집 모드 전용 탭 처리:
        /// - 가구를 탭 → 선택(확대 강조 + 미세 조정 패드 표시).
        /// - 선택된 상태에서 가구가 아닌 곳을 탭 → 선택 해제(핸들바 숨김).
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard editMode, g.state == .ended, let arView else { return }
            let loc = g.location(in: arView)
            let hit = furnitureRoot(from: arView.entity(at: loc))

            if let hit {
                if hit !== selectedEntity { select(hit) }
            } else {
                deselect()
            }
        }

        /// 오른쪽 패드는 작은 거리 조정 전용이다. 직접 드래그보다 감도를 낮춰 벽 근처에서도
        /// 원하는 위치를 세밀하게 맞출 수 있게 한다.
        func nudgeSelectedEntity(by screenDelta: CGPoint) {
            guard let selectedEntity else { return }
            let sensitivity: Float = 0.0035
            let dx = Float(screenDelta.x) * sensitivity
            let dz = Float(screenDelta.y) * sensitivity

            // 편집 화면은 항상 위보기로 고정되므로 화면 오른쪽=+X, 화면 아래=+Z가 된다.
            // 카메라 기울기를 다시 계산하지 않아 조이스틱 방향도 항상 일정하다.
            let worldDelta = SIMD3<Float>(dx, 0, dz)
            let current = selectedEntity.position(relativeTo: nil)
            _ = moveWithFurnitureCollisions(selectedEntity, to: current + worldDelta)
        }

        /// 화면 좌표에서 카메라 ray를 쏴 가구 높이의 수평 평면과 만나는 지점을 구한다.
        /// 화면 이동량을 임의 비율로 환산하지 않기 때문에, 가구가 손가락을 그대로 따라온다.
        private func pointOnDragPlane(at screenPoint: CGPoint, y: Float) -> SIMD3<Float>? {
            guard let ray = arView?.ray(through: screenPoint), abs(ray.direction.y) > 0.0001 else { return nil }
            let distance = (y - ray.origin.y) / ray.direction.y
            guard distance > 0 else { return nil }
            return ray.origin + ray.direction * distance
        }

        private func beginFurnitureDrag(_ entity: Entity, at screenPoint: CGPoint) {
            let worldPosition = entity.position(relativeTo: nil)
            let bounds = entity.visualBounds(relativeTo: nil)
            let planeY = (bounds.min.y + bounds.max.y) / 2
            dragPlaneY = planeY
            if let point = pointOnDragPlane(at: screenPoint, y: planeY) {
                dragOffsetXZ = SIMD2(worldPosition.x - point.x, worldPosition.z - point.z)
            } else {
                dragOffsetXZ = .zero
            }
        }

        private func dragSelectedEntity(to screenPoint: CGPoint) -> Bool {
            guard let selectedEntity,
                  let dragPlaneY,
                  let point = pointOnDragPlane(at: screenPoint, y: dragPlaneY) else { return false }
            var target = selectedEntity.position(relativeTo: nil)
            target.x = point.x + dragOffsetXZ.x
            target.z = point.z + dragOffsetXZ.y
            return moveWithFurnitureCollisions(selectedEntity, to: target)
        }

        func rotateSelectedEntity(by angle: Float) {
            guard let selectedEntity else { return }
            let originalTransform = selectedEntity.transform
            let originalCollision = furnitureCollisionScore(for: selectedEntity)
            selectedEntity.orientation *= simd_quatf(angle: angle, axis: [0, 1, 0])
            clampEntityToWalls(selectedEntity)
            if !isAcceptableCollisionChange(from: originalCollision,
                                            to: furnitureCollisionScore(for: selectedEntity)) {
                selectedEntity.transform = originalTransform
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            updateSelectionIndicatorTransform()
        }

        private func select(_ entity: Entity) {
            deselect()
            selectedEntity = entity
            selectedOriginalScale = entity.scale
            showSelectionIndicator(for: entity)
            nudgeHandle?.isHidden = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        /// 편집 모드를 나가거나 다른 가구를 선택/해제할 때 이전 선택 표시를 원래대로 되돌린다.
        func deselect() {
            if let selectedEntity, let selectedOriginalScale {
                selectedEntity.scale = selectedOriginalScale
            }
            selectedEntity = nil
            selectedOriginalScale = nil
            selectionIndicator?.removeFromParent()
            selectionIndicator = nil
            dragPlaneY = nil
            dragOffsetXZ = .zero
            nudgeHandle?.cancelActivePress()
            nudgeHandle?.isHidden = true
        }

        /// 편집 모드에서는 가구 위에서 시작한 드래그만 가구 이동으로 사용한다. 빈 공간 드래그는
        /// 무시해서 방과 카메라가 움직이지 않으며, 일반 보기일 때만 기존 방 회전을 허용한다.
        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            if g.state == .began {
                if editMode,
                   let hit = furnitureRoot(from: arView.entity(at: g.location(in: arView))) {
                    if hit !== selectedEntity { select(hit) }
                    panTarget = .furniture
                    beginFurnitureDrag(hit, at: g.location(in: arView))
                } else if editMode {
                    panTarget = .none
                } else {
                    panTarget = .camera
                }
            }

            let translation = g.translation(in: arView)
            switch panTarget {
            case .furniture:
                if !dragSelectedEntity(to: g.location(in: arView)) {
                    nudgeSelectedEntity(by: translation)
                }
            case .camera:
                orbitCamera.pan(translation)
            case .none:
                break
            }
            g.setTranslation(.zero, in: arView)

            if g.state == .ended || g.state == .cancelled || g.state == .failed {
                panTarget = .none
                dragPlaneY = nil
                dragOffsetXZ = .zero
            }
        }

        /// 히트테스트로 잡힌 엔티티가 카탈로그 모델의 자식 메쉬일 수 있으므로,
        /// "furniture_" 이름을 가진 조상까지 거슬러 올라가 실제로 옮길 루트 엔티티를 찾는다.
        private func furnitureRoot(from entity: Entity?) -> Entity? {
            var current = entity
            while let e = current {
                if e.name.hasPrefix("furniture_") { return e }
                current = e.parent
            }
            return nil
        }

        /// 실제 렌더링된 벽 평면을 기준으로, 엔티티의 시각적 바운드가 벽 밖으로 나간 만큼 다시
        /// 안쪽으로 밀어넣는다. 바닥을 사각형으로 근사하지 않고 벽 자체를 쓰기 때문에 방이
        /// L자 등 비정형이어도 정확하고, 바닥 데이터가 없는 방에서도(벽은 항상 있으므로) 동작한다.
        func clampEntityToWalls(_ entity: Entity) {
            clampToWallBarriers(entity)
            clampToFloorRectangle(entity)   // 벽 구간 틈 등으로 못 잡은 경우의 2차 안전망
        }

        // MARK: 가구 간 충돌

        /// 목적 위치가 막혀 있으면 X축과 Z축을 따로 시도한다. 게임의 캐릭터 충돌처럼 가구가
        /// 다른 가구를 뚫지는 않되 모서리를 따라 자연스럽게 미끄러질 수 있다.
        private func moveWithFurnitureCollisions(_ entity: Entity,
                                                 to worldTarget: SIMD3<Float>) -> Bool {
            defer { updateSelectionIndicatorTransform() }
            let originalTransform = entity.transform
            let originalWorldPosition = entity.position(relativeTo: nil)
            let originalCollision = furnitureCollisionScore(for: entity)

            if attemptPlacement(entity, from: originalTransform, at: worldTarget,
                                originalCollision: originalCollision) {
                return true
            }

            var xOnly = originalWorldPosition
            xOnly.x = worldTarget.x
            if attemptPlacement(entity, from: originalTransform, at: xOnly,
                                originalCollision: originalCollision) {
                return true
            }

            var zOnly = originalWorldPosition
            zOnly.z = worldTarget.z
            if attemptPlacement(entity, from: originalTransform, at: zOnly,
                                originalCollision: originalCollision) {
                return true
            }

            entity.transform = originalTransform
            return false
        }

        /// 선택 표시를 가구 자식이 아닌 방 앵커의 별도 레이어로 추가한다. 따라서 표시 크기는
        /// 가구 충돌·벽 판정·저장 좌표에 포함되지 않는다.
        private func showSelectionIndicator(for entity: Entity) {
            guard let roomAnchor else { return }
            selectionIndicator?.removeFromParent()

            let bounds = entity.visualBounds(relativeTo: entity)
            let padding: Float = 0.06
            let width = max(bounds.max.x - bounds.min.x + padding * 2, 0.12)
            let depth = max(bounds.max.z - bounds.min.z + padding * 2, 0.12)
            let centerX = (bounds.min.x + bounds.max.x) / 2
            let centerZ = (bounds.min.z + bounds.max.z) / 2
            let floorY = bounds.min.y + 0.018
            let lineThickness: Float = 0.025

            var borderMaterial = SimpleMaterial()
            borderMaterial.color = .init(tint: UIColor.systemBlue.withAlphaComponent(0.95))
            borderMaterial.roughness = 1
            var fillMaterial = SimpleMaterial()
            fillMaterial.color = .init(tint: UIColor.systemBlue.withAlphaComponent(0.16))
            fillMaterial.roughness = 1

            let root = Entity()
            root.name = "selection_indicator"

            let fill = ModelEntity(
                mesh: .generateBox(width: width, height: 0.006, depth: depth),
                materials: [fillMaterial]
            )
            fill.position = SIMD3(centerX, floorY - 0.006, centerZ)
            root.addChild(fill)

            let front = ModelEntity(
                mesh: .generateBox(width: width, height: 0.018, depth: lineThickness),
                materials: [borderMaterial]
            )
            front.position = SIMD3(centerX, floorY, centerZ + depth / 2)
            root.addChild(front)

            let back = front.clone(recursive: true)
            back.position.z = centerZ - depth / 2
            root.addChild(back)

            let left = ModelEntity(
                mesh: .generateBox(width: lineThickness, height: 0.018, depth: depth),
                materials: [borderMaterial]
            )
            left.position = SIMD3(centerX - width / 2, floorY, centerZ)
            root.addChild(left)

            let right = left.clone(recursive: true)
            right.position.x = centerX + width / 2
            root.addChild(right)

            root.transform = Transform(matrix: entity.transformMatrix(relativeTo: roomAnchor))
            roomAnchor.addChild(root)
            selectionIndicator = root
        }

        private func updateSelectionIndicatorTransform() {
            guard let selectedEntity, let selectionIndicator, let roomAnchor else { return }
            selectionIndicator.transform = Transform(
                matrix: selectedEntity.transformMatrix(relativeTo: roomAnchor)
            )
        }

        private func attemptPlacement(_ entity: Entity,
                                      from originalTransform: Transform,
                                      at worldTarget: SIMD3<Float>,
                                      originalCollision: Float) -> Bool {
            entity.transform = originalTransform
            entity.setPosition(worldTarget, relativeTo: nil)
            clampEntityToWalls(entity)
            let newCollision = furnitureCollisionScore(for: entity)
            if isAcceptableCollisionChange(from: originalCollision, to: newCollision) {
                return true
            }
            entity.transform = originalTransform
            return false
        }

        /// 원래 겹치지 않았으면 새 겹침을 금지하고, 서버 결과가 이미 겹쳐 있었다면 겹침이
        /// 줄어드는 방향만 허용해 사용자가 가구를 밖으로 빼낼 수 있게 한다.
        private func isAcceptableCollisionChange(from oldScore: Float, to newScore: Float) -> Bool {
            let epsilon: Float = 0.0001
            if oldScore <= epsilon { return newScore <= epsilon }
            return newScore < oldScore - epsilon
        }

        private func furnitureCollisionScore(for entity: Entity) -> Float {
            guard let roomAnchor, entity.isEnabled else { return 0 }
            let collision = collisionFootprintData(for: entity, relativeTo: roomAnchor)
            var score: Float = 0

            for other in entitiesByIdentifier.values where other !== entity && other.isEnabled {
                let otherCollision = collisionFootprintData(for: other, relativeTo: roomAnchor)
                let verticalGap: Float = 0.01
                guard collision.maxY > otherCollision.minY + verticalGap,
                      otherCollision.maxY > collision.minY + verticalGap else { continue }
                if let penetration = footprintPenetration(collision.corners, otherCollision.corners) {
                    score += penetration
                }
            }
            return score
        }

        private struct CollisionFootprintData {
            let corners: [SIMD2<Float>]
            let minY: Float
            let maxY: Float
        }

        /// 서버의 RoomPlan OBB 치수로 충돌용 발자국을 만든다. 화면 모델의 장식·숨은 여백은
        /// 사용하지 않으며, 벽에 육안상 바로 붙일 수 있도록 각 면에 1cm 접촉 여유를 둔다.
        private func collisionFootprintData(for entity: Entity,
                                            relativeTo roomAnchor: Entity) -> CollisionFootprintData {
            if let identifier = identifierByEntity[ObjectIdentifier(entity)],
               let baseline = poseBaseline[identifier] {
                let orientation = entity.orientation
                let entityPosition = entity.position(relativeTo: roomAnchor)
                let center = entityPosition + orientation.act(baseline.centerOffset)
                let rawAxisX = orientation.act(SIMD3<Float>(1, 0, 0))
                let rawAxisZ = orientation.act(SIMD3<Float>(0, 0, 1))
                let x2 = SIMD2(rawAxisX.x, rawAxisX.z)
                let z2 = SIMD2(rawAxisZ.x, rawAxisZ.z)
                let axisX = length(x2) > 0.001 ? normalize(x2) : SIMD2<Float>(1, 0)
                let axisZ = length(z2) > 0.001 ? normalize(z2) : SIMD2<Float>(0, 1)
                let halfWidth = max(baseline.dimensions.x / 2 - 0.01, 0.01)
                let halfDepth = max(baseline.dimensions.z / 2 - 0.01, 0.01)
                let center2 = SIMD2(center.x, center.z)
                return CollisionFootprintData(
                    corners: [
                        center2 - axisX * halfWidth - axisZ * halfDepth,
                        center2 + axisX * halfWidth - axisZ * halfDepth,
                        center2 + axisX * halfWidth + axisZ * halfDepth,
                        center2 - axisX * halfWidth + axisZ * halfDepth,
                    ],
                    minY: center.y - baseline.dimensions.y / 2,
                    maxY: center.y + baseline.dimensions.y / 2
                )
            }

            // 레거시 데이터에 서버 치수가 없을 때만 렌더 바운드로 폴백한다.
            let bounds = entity.visualBounds(relativeTo: roomAnchor)
            return CollisionFootprintData(
                corners: [
                    SIMD2(bounds.min.x, bounds.min.z),
                    SIMD2(bounds.max.x, bounds.min.z),
                    SIMD2(bounds.max.x, bounds.max.z),
                    SIMD2(bounds.min.x, bounds.max.z),
                ],
                minY: bounds.min.y,
                maxY: bounds.max.y
            )
        }

        /// Separating Axis Theorem으로 두 회전 사각형의 최소 침투량을 계산한다.
        /// 약 1.5cm 이하는 접촉으로 간주해 딱 붙여 배치할 수 있게 한다.
        private func footprintPenetration(_ lhs: [SIMD2<Float>],
                                          _ rhs: [SIMD2<Float>]) -> Float? {
            guard lhs.count == 4, rhs.count == 4 else { return nil }
            let contactTolerance: Float = 0.015
            var minimumPenetration = Float.greatestFiniteMagnitude

            for polygon in [lhs, rhs] {
                for index in polygon.indices {
                    let next = polygon[(index + 1) % polygon.count]
                    let edge = next - polygon[index]
                    guard length(edge) > 0.0001 else { continue }
                    let axis = normalize(SIMD2<Float>(-edge.y, edge.x))
                    let lhsProjection = lhs.map { dot($0, axis) }
                    let rhsProjection = rhs.map { dot($0, axis) }
                    guard let lhsMin = lhsProjection.min(), let lhsMax = lhsProjection.max(),
                          let rhsMin = rhsProjection.min(), let rhsMax = rhsProjection.max() else { continue }
                    let overlap = min(lhsMax, rhsMax) - max(lhsMin, rhsMin)
                    if overlap <= contactTolerance { return nil }
                    minimumPenetration = min(minimumPenetration, overlap - contactTolerance)
                }
            }
            return minimumPenetration.isFinite ? minimumPenetration : nil
        }

        private func clampToWallBarriers(_ entity: Entity) {
            guard !wallBarriers.isEmpty, let roomAnchor else { return }
            // wallBarriers는 서버의 방 로컬 좌표다. 화면 중앙 정렬로 이동한 world 좌표와 섞으면
            // 가구마다 엉뚱한 위치에서 막히므로 가구 바운드와 이동 보정도 방 로컬 좌표로 통일한다.
            let corners = roomLocalCorners(of: entity)

            var totalPush = SIMD3<Float>.zero
            for wall in wallBarriers {
                var worstPenetration: Float = 0   // 가장 깊이 벽을 뚫고 나간 정도 (음수)
                for corner in corners {
                    let rel = corner - wall.center
                    // 벽 구간(가로 범위) 밖이면 이 벽과는 무관 — 여유 30cm는 모서리 근처 오차 보정
                    guard abs(dot(rel, wall.right)) < wall.halfWidth + 0.3 else { continue }
                    let dist = dot(rel, wall.normal)
                    if dist < worstPenetration { worstPenetration = dist }
                }
                if worstPenetration < 0 {
                    totalPush += wall.normal * (-worstPenetration)
                }
            }
            guard totalPush != .zero else { return }
            let current = entity.position(relativeTo: roomAnchor)
            entity.setPosition(current + totalPush, relativeTo: roomAnchor)
        }

        /// 바닥 전체를 감싸는 사각형 밖으로는 절대 못 나가게 하는 안전망. 벽 구간 사이 틈(모서리 등)
        /// 때문에 clampToWallBarriers가 못 잡는 극단적인 경우를 여기서 마지막으로 잡는다.
        private func clampToFloorRectangle(_ entity: Entity) {
            guard let floorTransform, let floorHalfExtent, let roomAnchor else { return }
            let corners = roomLocalCorners(of: entity)
            let inv = floorTransform.inverse

            var minLocalX = Float.greatestFiniteMagnitude, maxLocalX = -Float.greatestFiniteMagnitude
            var minLocalY = Float.greatestFiniteMagnitude, maxLocalY = -Float.greatestFiniteMagnitude
            for c in corners {
                let local = inv * SIMD4<Float>(c.x, c.y, c.z, 1)
                minLocalX = min(minLocalX, local.x); maxLocalX = max(maxLocalX, local.x)
                minLocalY = min(minLocalY, local.y); maxLocalY = max(maxLocalY, local.y)
            }

            var dx: Float = 0
            if maxLocalX > floorHalfExtent.x { dx = floorHalfExtent.x - maxLocalX }
            else if minLocalX < -floorHalfExtent.x { dx = -floorHalfExtent.x - minLocalX }
            var dy: Float = 0
            if maxLocalY > floorHalfExtent.y { dy = floorHalfExtent.y - maxLocalY }
            else if minLocalY < -floorHalfExtent.y { dy = -floorHalfExtent.y - minLocalY }
            guard dx != 0 || dy != 0 else { return }

            let roomDelta4 = floorTransform * SIMD4<Float>(dx, dy, 0, 0)
            let roomDelta = SIMD3(roomDelta4.x, roomDelta4.y, roomDelta4.z)
            let current = entity.position(relativeTo: roomAnchor)
            entity.setPosition(current + roomDelta, relativeTo: roomAnchor)
        }

        private func roomLocalCorners(of entity: Entity) -> [SIMD3<Float>] {
            guard let roomAnchor else { return [] }
            let collision = collisionFootprintData(for: entity, relativeTo: roomAnchor)
            var corners: [SIMD3<Float>] = []
            corners.reserveCapacity(8)
            for point in collision.corners {
                for y in [collision.minY, collision.maxY] {
                    corners.append(SIMD3(point.x, y, point.y))
                }
            }
            return corners
        }
    }
}

private extension UIColor {
    static func voColor(hex: String) -> UIColor? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 벽 세그먼트 분할 헬퍼 (문/창문 실제 구멍 생성)
//
// 각 벽(CapturedRoom.Surface 또는 JSON RoomSurface)에 대해:
// 1) 해당 벽 평면에 속하는 문/창문 개구부를 벽 로컬 좌표로 변환
// 2) 개구부를 피한 박스 세그먼트들을 생성 → 실제 기하학적 구멍

private struct WallOpening {
    let localX: Float        // 벽 중심 기준 로컬 X (폭 방향)
    let localY: Float        // 벽 중심 기준 로컬 Y (높이 방향)
    let width:  Float
    let height: Float
    let isFloorLevel: Bool   // true = 문(바닥까지 내려옴, 창문턱 없음), false = 창문(창문턱 있음)
}

/// CapturedRoom.Surface 기반 – 해당 벽에 속하는 개구부 목록
private func capturedRoomOpenings(wall: CapturedRoom.Surface,
                                   doors: [CapturedRoom.Surface],
                                   windows: [CapturedRoom.Surface]) -> [WallOpening] {
    let wallInv = simd_inverse(wall.transform)
    let W = wall.dimensions.x, H = wall.dimensions.y
    let tol: Float = 0.3
    var result: [WallOpening] = []
    let all: [(CapturedRoom.Surface, Bool)] = doors.map { ($0, true) } + windows.map { ($0, false) }
    for (s, isDoor) in all {
        let lp = wallInv * s.transform.columns.3
        guard abs(lp.z) < tol, abs(lp.x) < W/2 + tol, abs(lp.y) < H/2 + tol else { continue }
        result.append(WallOpening(localX: lp.x, localY: lp.y,
                                  width: s.dimensions.x, height: s.dimensions.y,
                                  isFloorLevel: isDoor))
    }
    return result
}

/// JSON Payload 기반 – 해당 벽에 속하는 개구부 목록
private func payloadOpenings(wallTransform: simd_float4x4,
                              wallW: Float, wallH: Float,
                              doors: [RoomDataPayload.RoomSurface],
                              windows: [RoomDataPayload.RoomSurface]) -> [WallOpening] {
    let wallInv = simd_inverse(wallTransform)
    let tol: Float = 0.3
    var result: [WallOpening] = []
    for door in doors {
        guard let dt = door.simdTransform else { continue }
        let lp = wallInv * dt.columns.3
        guard abs(lp.z) < tol, abs(lp.x) < wallW/2 + tol, abs(lp.y) < wallH/2 + tol else { continue }
        let dW = door.dimensions.count > 0 ? door.dimensions[0] : 0.9
        let dH = door.dimensions.count > 1 ? door.dimensions[1] : 2.1
        result.append(WallOpening(localX: lp.x, localY: lp.y, width: dW, height: dH, isFloorLevel: true))
    }
    for win in windows {
        guard let wt = win.simdTransform else { continue }
        let lp = wallInv * wt.columns.3
        guard abs(lp.z) < tol, abs(lp.x) < wallW/2 + tol, abs(lp.y) < wallH/2 + tol else { continue }
        let wW = win.dimensions.count > 0 ? win.dimensions[0] : 1.0
        let wH = win.dimensions.count > 1 ? win.dimensions[1] : 1.2
        result.append(WallOpening(localX: lp.x, localY: lp.y, width: wW, height: wH, isFloorLevel: false))
    }
    return result
}

/// 개구부를 피해 벽을 분할한 ModelEntity 세그먼트 배열 생성
private func wallSegments(wallTransform: simd_float4x4,
                           wallW: Float, wallH: Float,
                           openings: [WallOpening],
                           color: UIColor,
                           depth: Float) -> [ModelEntity] {
    guard !openings.isEmpty else {
        return [wallBox(lx: 0, ly: 0, w: wallW, h: wallH,
                        wallTransform: wallTransform, color: color, depth: depth)]
    }

    let sorted = openings.sorted { $0.localX - $0.width/2 < $1.localX - $1.width/2 }
    var result: [ModelEntity] = []
    var curX: Float = -wallW/2

    for op in sorted {
        let opL = op.localX - op.width/2
        let opR = op.localX + op.width/2
        let opT = op.localY + op.height/2
        let opB = op.localY - op.height/2

        // 왼쪽 세그먼트 (개구부 왼쪽 전체 높이)
        if opL > curX + 0.01 {
            let sw = opL - curX
            result.append(wallBox(lx: curX + sw/2, ly: 0, w: sw, h: wallH,
                                  wallTransform: wallTransform, color: color, depth: depth))
        }

        // 인방 (개구부 위)
        let lintelH = wallH/2 - opT
        if lintelH > 0.01 {
            result.append(wallBox(lx: op.localX, ly: wallH/2 - lintelH/2,
                                  w: op.width, h: lintelH,
                                  wallTransform: wallTransform, color: color, depth: depth))
        }

        // 창문턱 (창문만 – 문은 바닥까지 열려 있으므로 생략)
        if !op.isFloorLevel {
            let sillH = opB + wallH/2
            if sillH > 0.01 {
                result.append(wallBox(lx: op.localX, ly: -wallH/2 + sillH/2,
                                      w: op.width, h: sillH,
                                      wallTransform: wallTransform, color: color, depth: depth))
            }
        }

        curX = opR
    }

    // 오른쪽 세그먼트
    if curX < wallW/2 - 0.01 {
        let sw = wallW/2 - curX
        result.append(wallBox(lx: curX + sw/2, ly: 0, w: sw, h: wallH,
                              wallTransform: wallTransform, color: color, depth: depth))
    }

    return result
}

/// 벽 로컬 좌표 (lx, ly) 위치의 박스 ModelEntity – 벽 transform 적용
private func wallBox(lx: Float, ly: Float, w: Float, h: Float,
                     wallTransform: simd_float4x4,
                     color: UIColor, depth: Float) -> ModelEntity {
    var mat = SimpleMaterial()
    mat.color = .init(tint: color); mat.roughness = 0.9; mat.metallic = 0.0
    let entity = ModelEntity(mesh: .generateBox(width: w, height: h, depth: depth), materials: [mat])
    // 벽 로컬 (lx, ly, 0) → 월드 위치로 변환, 회전은 벽과 동일
    var t = wallTransform
    t.columns.3 = wallTransform * SIMD4<Float>(lx, ly, 0, 1)
    entity.transform = Transform(matrix: t)
    return entity
}

// MARK: - 머티리얼 헬퍼

/// Only tint untextured white placeholder materials. Authored colors/textures survive.
fileprivate func applyPreviewColor(to entity: Entity, color: UIColor) {
    func isWhite(_ tint: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        return tint.getRed(&r, green: &g, blue: &b, alpha: &a)
            && min(r, g, b) > 0.95 && a > 0.95
    }
    if let model = entity as? ModelEntity, var component = model.model {
        component.materials = component.materials.map { material in
            if var simple = material as? SimpleMaterial,
               simple.color.texture == nil, isWhite(simple.color.tint) {
                simple.color.tint = color
                return simple
            }
            if var pbr = material as? PhysicallyBasedMaterial,
               pbr.baseColor.texture == nil, isWhite(pbr.baseColor.tint) {
                pbr.baseColor.tint = color
                return pbr
            }
            return material
        }
        model.model = component
    }
    for child in entity.children { applyPreviewColor(to: child, color: color) }
}

/// 카탈로그 모델(및 하위 파츠 전부)의 머티리얼을 단색으로 덮어씀
fileprivate func applyTint(to entity: Entity, color: UIColor) {
    if let model = entity as? ModelEntity, var comp = model.model {
        comp.materials = comp.materials.map { _ in
            var mat = SimpleMaterial()
            mat.color = .init(tint: color)
            mat.roughness = 0.9
            mat.metallic = 0.0
            return mat
        }
        model.model = comp
    }
    for child in entity.children {
        applyTint(to: child, color: color)
    }
}

// MARK: - SIMD 헬퍼

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
