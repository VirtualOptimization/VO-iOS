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
    var optimizedObjects: [OptimizedObject]? = nil
    var isTransparent: Bool = false

    @State private var usdzURL: URL? = nil
    @State private var isGenerating = true

    var body: some View {
        ZStack {
            if isGenerating && !isTransparent {
                VStack(spacing: 16) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(1.5)
                    Text("방 모델 생성 중...").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                RealityKitRoomView(
                    capturedRoom: capturedRoom,
                    usdzURL: isTransparent ? nil : usdzURL,
                    optimizedObjects: optimizedObjects,
                    isTransparent: isTransparent
                )
                .ignoresSafeArea()
            }
        }
        .task {
            if isTransparent { isGenerating = false; return }
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
    var usdzURL: URL?
    var optimizedObjects: [OptimizedObject]?
    var isTransparent: Bool = false

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

        setupLighting(in: arView)

        let roomAnchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(roomAnchor)
        context.coordinator.roomAnchor = roomAnchor
        context.coordinator.arView = arView

        if isTransparent {
            Task { @MainActor in
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
            Task { await loadUSDZ(url: url, into: roomAnchor) }
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

        Task { @MainActor in
            roomAnchor.children.removeAll()
            await loadOptimizedScene(capturedRoom, objects: optimizedObjects, into: roomAnchor)
        }
    }

    // MARK: - USDZ 로드

    @MainActor
    private func loadUSDZ(url: URL, into anchor: AnchorEntity) async {
        do {
            let entity = try Entity.loadSync(contentsOf: url)
            anchor.addChild(entity)
            // Apple USDZ의 바닥 재질이 흰색이므로 베이지 바닥으로 덮기
            for s in capturedRoom.floors {
                anchor.addChild(makeSurface(s,
                    color: UIColor(red: 0.91, green: 0.87, blue: 0.80, alpha: 1.0),
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

        for opt in objects {
            guard let original = room.objects.first(where: { $0.identifier == opt.identifier }) else { continue }

            var placed = false

            if let mp, let modelURL = try? mp.modelFileURL(for: original) {
                do {
                    let model = try Entity.loadSync(contentsOf: modelURL)

                    // 모델 크기를 원본 dimensions에 맞게 스케일 조정
                    let bounds = model.visualBounds(relativeTo: model)
                    let bSize = bounds.max - bounds.min
                    if bSize.x > 0.001 && bSize.y > 0.001 && bSize.z > 0.001 {
                        let d = original.dimensions
                        model.scale = SIMD3(d.x / bSize.x, d.y / bSize.y, d.z / bSize.z)
                        // pivot이 center가 아닐 경우 offset 보정
                        let centerOffset = (bounds.max + bounds.min) / 2
                        model.position = opt.center - centerOffset * model.scale
                    } else {
                        model.position = opt.center
                    }
                    model.orientation = opt.rotation
                    anchor.addChild(model)
                    placed = true
                    print("✅ 최적화 모델 배치: \(modelURL.lastPathComponent)")
                } catch {
                    print("⚠️ 카탈로그 모델 로드 실패: \(error)")
                }
            }

            // 폴백: OBB 박스
            if !placed {
                var mat = SimpleMaterial()
                mat.color = .init(tint: colorForCategory(original.category))
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
        let alpha: CGFloat = isTransparent ? 0.45 : 1.0
        let wallColor  = UIColor(white: 1.0, alpha: alpha)
        let floorColor = UIColor(red: 0.94, green: 0.92, blue: 0.90, alpha: 1.0)
        for wall in room.walls {
            let openings = capturedRoomOpenings(wall: wall, doors: room.doors, windows: room.windows)
            wallSegments(wallTransform: wall.transform, wallW: wall.dimensions.x, wallH: wall.dimensions.y,
                         openings: openings, color: wallColor, depth: 0.04)
                .forEach { anchor.addChild($0) }
        }
        for s in room.floors { anchor.addChild(makeSurface(s, color: floorColor, depth: 0.01)) }
    }

    private func renderScene(_ room: CapturedRoom, in anchor: AnchorEntity) {
        renderSurfaces(room, in: anchor)
        for obj in room.objects {
            var mat = SimpleMaterial()
            mat.color = .init(tint: colorForCategory(obj.category))
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
        arView.addGestureRecognizer(UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch)))
        arView.addGestureRecognizer(UIRotationGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleRotation)))
        arView.addGestureRecognizer(UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan)))
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

    class Coordinator: NSObject {
        weak var arView: ARView?
        var roomAnchor: AnchorEntity?
        var hasAppliedOptimization: Bool = false
        private var lastScale: Float = 1.0
        private var currentScale: Float = 1.0
        private var lastRotation: Float = 0

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { lastScale = currentScale }
            currentScale = max(0.3, min(6.0, lastScale * Float(g.scale)))
            roomAnchor?.scale = SIMD3(repeating: currentScale)
        }

        @objc func handleRotation(_ g: UIRotationGestureRecognizer) {
            if g.state == .began { lastRotation = 0 }
            let delta = Float(g.rotation) - lastRotation
            lastRotation = Float(g.rotation)
            roomAnchor?.orientation *= simd_quatf(angle: -delta, axis: [0, 1, 0])
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            let delta = Float(g.translation(in: arView).x) * 0.005
            roomAnchor?.orientation *= simd_quatf(angle: delta, axis: [0, 1, 0])
            g.setTranslation(.zero, in: arView)
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
        arView.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator,    action: #selector(Coordinator.handlePinch)))
        arView.addGestureRecognizer(UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation)))
        arView.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator,      action: #selector(Coordinator.handlePan)))

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    // MARK: 씬 구성

    @MainActor
    private func buildScene(into anchor: AnchorEntity) async {
        // 구조물
        // 벽: 반투명 흰색, 문/창문 스킵 → 자연 간극
        for s in roomData.walls  ?? [] { anchor.addChild(makeSurface(s, color: UIColor(white: 1.0, alpha: 0.45), depth: 0.04)) }
        for s in roomData.floors ?? [] { anchor.addChild(makeSurface(s, color: UIColor(red: 0.94, green: 0.92, blue: 0.90, alpha: 1.0), depth: 0.01)) }

        // 가구
        for obj in roomData.objects {
            if let entity = await loadFurniture(obj) {
                anchor.addChild(entity)
            }
        }
    }

    /// 가구 엔티티 생성: 카탈로그 모델 → 색상 박스 순으로 시도
    @MainActor
    private func loadFurniture(_ obj: RoomDataPayload.RoomObject) async -> Entity? {
        // 1. 카탈로그 번들에서 modelFileName으로 로드
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

        // 2. 색상 박스 폴백
        var mat = SimpleMaterial()
        mat.color = .init(tint: categoryColor(obj.category))
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
            let c = obj.center
            entity.position = c.count >= 3 ? SIMD3(c[0], c[1], c[2]) : .zero
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
    class Coordinator: NSObject {
        weak var arView: ARView?
        var roomAnchor: AnchorEntity?
        private var lastScale: Float = 1.0
        private var currentScale: Float = 1.0
        private var lastRotation: Float = 0

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { lastScale = currentScale }
            currentScale = max(0.3, min(6.0, lastScale * Float(g.scale)))
            roomAnchor?.scale = SIMD3(repeating: currentScale)
        }

        @objc func handleRotation(_ g: UIRotationGestureRecognizer) {
            if g.state == .began { lastRotation = 0 }
            let delta = Float(g.rotation) - lastRotation
            lastRotation = Float(g.rotation)
            roomAnchor?.orientation *= simd_quatf(angle: -delta, axis: [0, 1, 0])
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            let delta = Float(g.translation(in: arView).x) * 0.005
            roomAnchor?.orientation *= simd_quatf(angle: delta, axis: [0, 1, 0])
            g.setTranslation(.zero, in: arView)
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

        // 조명
        let lightAnchor = AnchorEntity(world: .zero)
        let dir = DirectionalLight()
        dir.light.intensity = 3000; dir.light.color = .white
        dir.shadow = DirectionalLightComponent.Shadow(maximumDistance: 10)
        dir.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0])
        lightAnchor.addChild(dir)
        let pt = PointLight()
        pt.light.intensity = 1000; pt.position = [0, 4, 0]
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
        arView.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator,    action: #selector(Coordinator.handlePinch)))
        arView.addGestureRecognizer(UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation)))
        arView.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator,      action: #selector(Coordinator.handlePan)))

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    // MARK: Coordinator (핀치·회전·팬)
    class Coordinator: NSObject {
        weak var arView: ARView?
        var roomAnchor: AnchorEntity?
        private var lastScale: Float = 1.0
        private var currentScale: Float = 1.0
        private var lastRotation: Float = 0

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { lastScale = currentScale }
            currentScale = max(0.3, min(6.0, lastScale * Float(g.scale)))
            roomAnchor?.scale = SIMD3(repeating: currentScale)
        }

        @objc func handleRotation(_ g: UIRotationGestureRecognizer) {
            if g.state == .began { lastRotation = 0 }
            let delta = Float(g.rotation) - lastRotation
            lastRotation = Float(g.rotation)
            roomAnchor?.orientation *= simd_quatf(angle: -delta, axis: [0, 1, 0])
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            let delta = Float(g.translation(in: arView).x) * 0.005
            roomAnchor?.orientation *= simd_quatf(angle: delta, axis: [0, 1, 0])
            g.setTranslation(.zero, in: arView)
        }
    }
}

// MARK: - FurnitureRealityKitView (rooms API 버전 상세 기반 3D 뷰어)
//
// B안: capturedRoom이 제공되면 로컬 USDZ를 생성하여 방 shell을 렌더링하고
//       가구는 숨긴 뒤, JSON의 최적화된 가구를 오버레이한다.
// 폴백: capturedRoom이 없으면 JSON 박스 기반 렌더링.

struct FurnitureRealityKitView: UIViewRepresentable {
    let detail: RoomVersionDetail
    var capturedRoom: CapturedRoom? = nil   // B안: 제공 시 로컬 USDZ로 방 shell 렌더링
    var isTransparent: Bool = false         // 투명 모드: 반투명 벽 박스

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
        Task { @MainActor in await buildScene(into: roomAnchor, coordinator: coord) }

        // 제스처
        arView.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator,    action: #selector(Coordinator.handlePinch)))
        arView.addGestureRecognizer(UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation)))
        arView.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator,      action: #selector(Coordinator.handlePan)))

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    // MARK: 씬 구성
    // 1) data_url → 가구 배치 JSON
    // 2) JSON walls/floors/doors → 방 구조 박스
    // 3) model_urls USDC → 가구 모델, 없으면 카테고리 색상 박스
    // 4) 씬 전체를 카메라 시야 중앙으로 오도록 anchor 이동 + 카메라 거리 자동 조정

    @MainActor
    private func buildScene(into anchor: AnchorEntity, coordinator: Coordinator) async {

        let wallAlpha: Float = isTransparent ? 0.35 : 1.0
        let wallColor  = UIColor(white: 1.0, alpha: CGFloat(wallAlpha))
        let floorColor = UIColor(red: 0.94, green: 0.92, blue: 0.90, alpha: 1.0)

        // ── capturedRoom이 있으면 방 구조 먼저 렌더링 (JSON 결과 기다리지 않음) ──
        if let room = capturedRoom {
            for wall in room.walls {
                let openings = capturedRoomOpenings(wall: wall, doors: room.doors, windows: room.windows)
                wallSegments(wallTransform: wall.transform, wallW: wall.dimensions.x, wallH: wall.dimensions.y,
                             openings: openings, color: wallColor, depth: 0.04)
                    .forEach { anchor.addChild($0) }
            }
            for floor in room.floors {
                anchor.addChild(makeCapturedSurface(floor, color: floorColor, depth: 0.01))
            }

            // 카메라 거리: capturedRoom 벽 기준
            var allPos = room.walls.compactMap { w -> SIMD3<Float>? in w.transform.columns.3.xyz }
            allPos += room.floors.map { $0.transform.columns.3.xyz }
            adjustCamera(anchor: anchor, coordinator: coordinator, positions: allPos)
        }

        // ── JSON 다운로드 ──────────────────────────────────────────────────────
        guard let dataURLString = detail.dataUrl,
              let dataURL = URL(string: dataURLString) else {
            print("⚠️ data_url 없음 – 방 구조만 표시")
            return
        }

        let payload: RoomDataPayload
        do {
            let (jsonData, _) = try await URLSession.shared.data(from: dataURL)
            payload = try JSONDecoder().decode(RoomDataPayload.self, from: jsonData)
            print("✅ JSON 파싱 완료: 오브젝트 \(payload.objects.count)개")
        } catch {
            print("❌ data_url 파싱 실패: \(error) – 방 구조만 표시")
            return
        }

        // ── capturedRoom이 없을 때만 JSON으로 방 구조 렌더링 ──────────────────
        if capturedRoom == nil {
            var allPos: [SIMD3<Float>] = []
            for w in payload.walls   ?? [] { if let t = w.simdTransform { allPos.append(t.columns.3.xyz) } }
            for f in payload.floors  ?? [] { if let t = f.simdTransform { allPos.append(t.columns.3.xyz) } }
            for o in payload.objects { let c = o.center; if c.count >= 3 { allPos.append(SIMD3(c[0], c[1], c[2])) } }
            adjustCamera(anchor: anchor, coordinator: coordinator, positions: allPos)

            for wall in payload.walls ?? [] {
                guard let wallT = wall.simdTransform else {
                    anchor.addChild(makeSurfaceBox(surface: wall, color: wallColor, depth: 0.12))
                    continue
                }
                let wallW = wall.dimensions.count > 0 ? wall.dimensions[0] : 1.0
                let wallH = wall.dimensions.count > 1 ? wall.dimensions[1] : 2.4
                let openings = payloadOpenings(wallTransform: wallT, wallW: wallW, wallH: wallH,
                                               doors: payload.doors ?? [], windows: payload.windows ?? [])
                wallSegments(wallTransform: wallT, wallW: wallW, wallH: wallH,
                             openings: openings, color: wallColor, depth: 0.12)
                    .forEach { anchor.addChild($0) }
            }
            for floor in payload.floors ?? [] {
                anchor.addChild(makeSurfaceBox(surface: floor, color: floorColor, depth: 0.02))
            }
        }

        // ── 가구 배치 ──────────────────────────────────────────────────────────
        let modelUrls = detail.modelUrls ?? [:]
        print("📦 model_urls 키: \(Array(modelUrls.keys))")
        for obj in payload.objects {
            guard let matrix = obj.simdTransform else { continue }
            let worldPos = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)

            var placed = false

            // 1. 로컬 RoomPlanCatalog.bundle 우선 로드
            if let fileName = obj.modelFileName,
               let localURL = findCatalogModel(named: fileName) {
                do {
                    let loaded = try Entity.loadSync(contentsOf: localURL)
                    applyTransform(to: loaded, matrix: matrix, worldPos: worldPos, obj: obj)
                    anchor.addChild(loaded)
                    placed = true
                    print("  ✅ \(obj.category) (\(fileName)) 로컬 카탈로그 로드 성공")
                } catch {
                    print("  ⚠️ \(obj.category) (\(fileName)) 로컬 로드 실패: \(error)")
                }
            }

            // 2. 로컬 실패 시 박스 폴백
            if !placed {
                print("  📦 \(obj.category): 박스 폴백")
                let box = makeFallbackBox(for: obj)
                box.transform = Transform(matrix: matrix)
                anchor.addChild(box)
            }
        }
    }

    /// anchor 센터링 + 카메라 거리 조정
    private func adjustCamera(anchor: AnchorEntity, coordinator: Coordinator, positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        let xs = positions.map(\.x), ys = positions.map(\.y), zs = positions.map(\.z)
        let minX = xs.min()!, maxX = xs.max()!
        let minZ = zs.min()!, maxZ = zs.max()!
        let minY = ys.min()!
        anchor.position = SIMD3(-(minX + maxX) / 2, -minY, -(minZ + maxZ) / 2)
        let roomSize = max(maxX - minX, maxZ - minZ)
        let dist = min(max(roomSize * 0.75 + 2.5, 4.0), 14.0)
        coordinator.camera?.position = SIMD3(0, dist, dist)
        coordinator.camera?.look(at: .zero, from: SIMD3(0, dist, dist), relativeTo: nil)
    }

    /// 모델에 transform 적용 (bounds 스케일링 포함)
    private func applyTransform(to entity: Entity,
                                matrix: simd_float4x4,
                                worldPos: SIMD3<Float>,
                                obj: RoomDataPayload.RoomObject) {
        let bounds = entity.visualBounds(relativeTo: entity)
        let bSize  = bounds.max - bounds.min
        let dims   = obj.dimensions ?? []

        if dims.count >= 3, bSize.x > 0.001, bSize.y > 0.001, bSize.z > 0.001 {
            let scale = SIMD3<Float>(dims[0] / bSize.x, dims[1] / bSize.y, dims[2] / bSize.z)
            let pivot = (bounds.max + bounds.min) / 2
            entity.scale       = scale
            entity.position    = worldPos - pivot * scale
            entity.orientation = simd_quatf(matrix)
        } else {
            entity.transform = Transform(matrix: matrix)
        }
    }

    /// RoomPlanCatalog.bundle 내에서 파일명으로 모델 URL 검색
    private func findCatalogModel(named fileName: String) -> URL? {
        guard let bundleURL = Bundle.main.url(forResource: "RoomPlanCatalog", withExtension: "bundle") else { return nil }

        // 번들 내 재귀 탐색
        let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent == fileName { return fileURL }
        }
        return nil
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

    /// 카테고리별 색상 박스 (배경색과 겹치지 않는 뚜렷한 색상)
    private func makeFallbackBox(for obj: RoomDataPayload.RoomObject) -> ModelEntity {
        var mat = SimpleMaterial()
        mat.color = .init(tint: colorForCategory(obj.category))
        mat.roughness = 0.9
        let dims = obj.dimensions ?? [0.5, 0.5, 0.5]
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
        case "bed":          return UIColor(red: 0.88, green: 0.82, blue: 0.85, alpha: 1.0)  // 연한 핑크베이지
        case "sofa", "chair": return UIColor(red: 0.80, green: 0.86, blue: 0.92, alpha: 1.0) // 연한 파랑
        case "table":        return UIColor(red: 0.86, green: 0.84, blue: 0.80, alpha: 1.0)  // 연한 베이지
        case "storage":      return UIColor(red: 0.83, green: 0.83, blue: 0.88, alpha: 1.0)  // 연한 라벤더
        case "television":   return UIColor(red: 0.65, green: 0.65, blue: 0.68, alpha: 1.0)
        case "refrigerator": return UIColor(red: 0.88, green: 0.90, blue: 0.92, alpha: 1.0)
        default:             return UIColor(red: 0.84, green: 0.83, blue: 0.82, alpha: 1.0)
        }
    }

    // MARK: Coordinator
    class Coordinator: NSObject {
        weak var arView: ARView?
        var roomAnchor: AnchorEntity?
        var camera: PerspectiveCamera?          // 카메라 거리 동적 조정용
        private var lastScale: Float = 1.0
        private var currentScale: Float = 1.0
        private var lastRotation: Float = 0

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { lastScale = currentScale }
            currentScale = max(0.3, min(6.0, lastScale * Float(g.scale)))
            roomAnchor?.scale = SIMD3(repeating: currentScale)
        }

        @objc func handleRotation(_ g: UIRotationGestureRecognizer) {
            if g.state == .began { lastRotation = 0 }
            let delta = Float(g.rotation) - lastRotation
            lastRotation = Float(g.rotation)
            roomAnchor?.orientation *= simd_quatf(angle: -delta, axis: [0, 1, 0])
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            let delta = Float(g.translation(in: arView).x) * 0.005
            roomAnchor?.orientation *= simd_quatf(angle: delta, axis: [0, 1, 0])
            g.setTranslation(.zero, in: arView)
        }
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

// MARK: - SIMD 헬퍼

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
