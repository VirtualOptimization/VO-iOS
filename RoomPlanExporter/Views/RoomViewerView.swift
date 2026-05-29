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

    @State private var usdzURL: URL? = nil
    @State private var isGenerating = true

    var body: some View {
        ZStack {
            if isGenerating {
                VStack(spacing: 16) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(1.5)
                    Text("방 모델 생성 중...").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                RealityKitRoomView(
                    capturedRoom: capturedRoom,
                    usdzURL: usdzURL,
                    optimizedObjects: optimizedObjects
                )
                .ignoresSafeArea()
            }
        }
        .task { await generateUSDZ() }
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

        // USDZ로 초기 씬 렌더링
        // (usdzURL은 RoomViewerView의 generateUSDZ 완료 후 RealityKitRoomView가 생성되므로 항상 설정됨)
        if let url = usdzURL {
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
        for s in room.walls   { anchor.addChild(makeSurface(s, color: UIColor(white: 0.97, alpha: 1.0), depth: 0.04)) }
        for s in room.floors  { anchor.addChild(makeSurface(s, color: UIColor(red: 0.91, green: 0.87, blue: 0.80, alpha: 1.0), depth: 0.01)) }
        for s in room.doors   { anchor.addChild(makeSurface(s, color: UIColor(red: 0.75, green: 0.63, blue: 0.50, alpha: 1.0), depth: 0.04)) }
        for s in room.windows { anchor.addChild(makeSurface(s, color: UIColor(red: 0.70, green: 0.85, blue: 0.95, alpha: 0.4), depth: 0.02)) }
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
        for s in roomData.walls  ?? [] { anchor.addChild(makeSurface(s, color: UIColor(white: 0.97, alpha: 1.0), depth: 0.04)) }
        for s in roomData.floors ?? [] { anchor.addChild(makeSurface(s, color: UIColor(red: 0.91, green: 0.87, blue: 0.80, alpha: 1.0), depth: 0.01)) }
        for s in roomData.doors  ?? [] { anchor.addChild(makeSurface(s, color: UIColor(red: 0.75, green: 0.63, blue: 0.50, alpha: 1.0), depth: 0.04)) }

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
            // 카탈로그 모델은 bounds 보정 후 적용
            let bounds = entity.visualBounds(relativeTo: entity)
            let bSize  = bounds.max - bounds.min
            if let dims = obj.dimensions, dims.count >= 3,
               bSize.x > 0.001, bSize.y > 0.001, bSize.z > 0.001 {
                let scale = SIMD3<Float>(dims[0] / bSize.x, dims[1] / bSize.y, dims[2] / bSize.z)
                entity.scale = scale
                let center  = (bounds.max + bounds.min) / 2
                let pos     = SIMD3(mat.columns.3.x, mat.columns.3.y, mat.columns.3.z)
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
        var mat = SimpleMaterial()
        mat.color = .init(tint: color); mat.roughness = 0.9; mat.metallic = 0.0
        let d = s.dimensions
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
// 서버가 반환하는 usdz_url (presigned S3) 을 다운로드 → RealityKit으로 렌더링.
// 핀치/회전/팬 제스처로 뷰 조작 가능.

struct FurnitureRealityKitView: UIViewRepresentable {
    let detail: RoomVersionDetail

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

        // ── JSON 다운로드 ──────────────────────────────────────────────────────
        guard let dataURLString = detail.dataUrl,
              let dataURL = URL(string: dataURLString) else {
            print("⚠️ data_url 없음")
            return
        }

        let payload: RoomDataPayload
        do {
            let (jsonData, _) = try await URLSession.shared.data(from: dataURL)
            payload = try JSONDecoder().decode(RoomDataPayload.self, from: jsonData)
            print("✅ JSON 파싱 완료: 오브젝트 \(payload.objects.count)개")
        } catch {
            print("❌ data_url 파싱 실패: \(error)")
            return
        }

        // ── 씬 AABB 계산 → anchor 이동으로 카메라 중앙 정렬 ──────────────────
        // RoomPlan 좌표는 스캔 시작 위치 기준이므로 origin과 멀 수 있음.
        // anchor.position을 역방향 이동해 씬 중심을 world origin(카메라가 바라보는 점)에 맞춤.
        var allPos: [SIMD3<Float>] = []
        for w in payload.walls   ?? [] { if let t = w.simdTransform   { allPos.append(t.columns.3.xyz) } }
        for f in payload.floors  ?? [] { if let t = f.simdTransform   { allPos.append(t.columns.3.xyz) } }
        for o in payload.objects       {
            let c = o.center
            if c.count >= 3 { allPos.append(SIMD3(c[0], c[1], c[2])) }
        }

        if !allPos.isEmpty {
            let xs = allPos.map(\.x), zs = allPos.map(\.z), ys = allPos.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!
            let minZ = zs.min()!, maxZ = zs.max()!
            let minY = ys.min()!

            // XZ 중심 → origin, 바닥(minY) → Y=0
            let cx = (minX + maxX) / 2
            let cz = (minZ + maxZ) / 2
            anchor.position = SIMD3(-cx, -minY, -cz)
            print("📐 씬 센터링: offset(\(-cx), \(-minY), \(-cz))")

            // 방 크기에 맞게 카메라 거리 조정 (최소 4m, 최대 14m)
            let roomSize = max(maxX - minX, maxZ - minZ)
            let dist = min(max(roomSize * 0.75 + 2.5, 4.0), 14.0)
            coordinator.camera?.position = SIMD3(0, dist, dist)
            coordinator.camera?.look(at: .zero, from: SIMD3(0, dist, dist), relativeTo: nil)
            print("📷 카메라 거리: \(dist)m (방 크기 \(String(format: "%.1f", roomSize))m)")
        }

        // ── 방 구조 (벽/바닥/문) ──────────────────────────────────────────────
        for wall in payload.walls ?? [] {
            anchor.addChild(makeSurfaceBox(surface: wall,
                                           color: UIColor(white: 0.93, alpha: 1.0),
                                           depth: 0.12))
        }
        for floor in payload.floors ?? [] {
            anchor.addChild(makeSurfaceBox(surface: floor,
                                           color: UIColor(red: 0.88, green: 0.84, blue: 0.78, alpha: 1.0),
                                           depth: 0.02))
        }
        for door in payload.doors ?? [] {
            anchor.addChild(makeSurfaceBox(surface: door,
                                           color: UIColor(red: 0.75, green: 0.63, blue: 0.50, alpha: 1.0),
                                           depth: 0.05))
        }

        // ── 가구 배치 ──────────────────────────────────────────────────────────
        let modelUrls = detail.modelUrls ?? [:]
        print("📦 model_urls 키: \(Array(modelUrls.keys))")
        for obj in payload.objects {
            guard let matrix = obj.simdTransform else { continue }
            let worldPos = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)

            if let fileName = obj.modelFileName,
               let presignedURL = modelUrls[fileName] {
                do {
                    let loaded = try await downloadAndLoad(from: presignedURL)

                    // USDC 모델의 intrinsic 스케일이 meters와 다를 수 있음
                    // → visual bounds를 재서 obj.dimensions(meters) 기준으로 강제 스케일링
                    let bounds = loaded.visualBounds(relativeTo: loaded)
                    let bSize  = bounds.max - bounds.min
                    let dims   = obj.dimensions ?? []

                    if dims.count >= 3,
                       bSize.x > 0.001, bSize.y > 0.001, bSize.z > 0.001 {
                        let scale  = SIMD3<Float>(dims[0] / bSize.x,
                                                  dims[1] / bSize.y,
                                                  dims[2] / bSize.z)
                        let pivot  = (bounds.max + bounds.min) / 2   // 모델 로컬 center
                        loaded.scale       = scale
                        loaded.position    = worldPos - pivot * scale // pivot을 worldPos로
                        loaded.orientation = simd_quatf(matrix)
                        print("  ✅ \(obj.category) (\(fileName)) bounds:\(bSize) → scale:\(scale)")
                    } else {
                        // bounds 계산 실패 시 raw transform 적용
                        loaded.transform = Transform(matrix: matrix)
                        print("  ✅ \(obj.category) (\(fileName)) bounds zero → raw transform")
                    }
                    anchor.addChild(loaded)
                } catch {
                    print("  ❌ \(obj.category) (\(fileName)) 로드 실패: \(error) → 박스 폴백")
                    let box = makeFallbackBox(for: obj)
                    box.transform = Transform(matrix: matrix)
                    anchor.addChild(box)
                }
            } else {
                print("  📦 \(obj.category): model_urls 없음 → 박스 폴백")
                let box = makeFallbackBox(for: obj)
                box.transform = Transform(matrix: matrix)
                anchor.addChild(box)
            }
        }
    }

    /// 벽/바닥/문 박스 (RoomSurface transform 적용)
    private func makeSurfaceBox(surface: RoomDataPayload.RoomSurface,
                                color: UIColor,
                                depth: Float) -> ModelEntity {
        var mat = SimpleMaterial()
        mat.color = .init(tint: color)
        mat.roughness = 0.9
        let dims = surface.dimensions
        let w = dims.count > 0 ? dims[0] : 1.0
        let h = dims.count > 1 ? dims[1] : 1.0
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
        case "bed":          return UIColor(red: 0.90, green: 0.55, blue: 0.65, alpha: 1.0)  // 분홍
        case "sofa":         return UIColor(red: 0.45, green: 0.65, blue: 0.85, alpha: 1.0)  // 파랑
        case "chair":        return UIColor(red: 0.45, green: 0.65, blue: 0.85, alpha: 1.0)  // 파랑
        case "table":        return UIColor(red: 0.55, green: 0.75, blue: 0.60, alpha: 1.0)  // 초록 (배경과 구분)
        case "storage":      return UIColor(red: 0.70, green: 0.55, blue: 0.80, alpha: 1.0)  // 보라
        case "television":   return UIColor(red: 0.40, green: 0.40, blue: 0.45, alpha: 1.0)  // 진회색
        case "refrigerator": return UIColor(red: 0.88, green: 0.90, blue: 0.92, alpha: 1.0)
        default:             return UIColor(red: 0.85, green: 0.82, blue: 0.78, alpha: 1.0)
        }
    }

    /// presigned URL → 로컬 임시 파일(.usdz/.usdc) → Entity 로드
    @MainActor
    private func downloadAndLoad(from urlString: String) async throws -> Entity {
        guard let remoteURL = URL(string: urlString) else { throw URLError(.badURL) }
        let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
        // presigned URL 쿼리스트링을 제거한 뒤 확장자 추출
        let cleanPath = remoteURL.deletingQuery().pathExtension
        let ext = cleanPath.isEmpty ? "usdz" : cleanPath
        let destURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return try Entity.loadSync(contentsOf: destURL)
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

// MARK: - SIMD 헬퍼

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

// MARK: - URL 헬퍼

private extension URL {
    /// 쿼리스트링 없이 path만 있는 URL 반환 (presigned URL 확장자 추출용)
    func deletingQuery() -> URL {
        var comps = URLComponents(url: self, resolvingAgainstBaseURL: false) ?? URLComponents()
        comps.query = nil
        comps.fragment = nil
        return comps.url ?? self
    }
}
