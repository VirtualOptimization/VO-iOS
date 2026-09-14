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
    var serverModels: [UUID: URL]? = nil
    var optimizedObjects: [OptimizedObject]? = nil
    var isTransparent: Bool = false
    var wallColor: UIColor = .white
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
    var wallColor: UIColor = .white
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

        setupLighting(in: arView)

        let roomAnchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(roomAnchor)
        context.coordinator.roomAnchor = roomAnchor
        context.coordinator.arView = arView

        if isTransparent || useCatalogRenderer {
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

        for opt in objects {
            guard let original = room.objects.first(where: { $0.identifier == opt.identifier }) else { continue }

            var placed = false

            let modelURL = serverModels?[original.identifier]
                ?? (serverModels == nil ? (try? mp?.modelFileURL(for: original)) : nil)
            if let modelURL {
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

            // 폴백: OBB 박스
            if !placed, serverModels == nil {
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
        let effectiveWallColor = wallColor.withAlphaComponent(isTransparent ? 0.45 : 1.0)
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

// MARK: - 가구 편집 핸들바
//
// 3D 화면을 직접 탭/드래그해서 가구를 옮기면 시점 각도나 히트테스트 정확도에 따라 결과가
// 들쭉날쭉해지기 쉽다. 대신 화면 오른쪽에 고정된 이 패드를 밀면, 민 방향 그대로 가구가
// 움직여서 훨씬 예측 가능하다 — 가구가 선택됐을 때만 나타난다.

final class FurnitureNudgeHandle: UIView {
    /// 이 패드 위에서 드래그한 화면 좌표 델타(pt) — 매 변화마다 호출
    var onMove: ((CGPoint) -> Void)?

    private let knob = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.28)
        layer.cornerRadius = 34
        translatesAutoresizingMaskIntoConstraints = false

        knob.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        knob.layer.cornerRadius = 16
        knob.isUserInteractionEnabled = false
        knob.translatesAutoresizingMaskIntoConstraints = false
        addSubview(knob)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 68),
            heightAnchor.constraint(equalToConstant: 68),
            knob.widthAnchor.constraint(equalToConstant: 32),
            knob.heightAnchor.constraint(equalToConstant: 32),
            knob.centerXAnchor.constraint(equalTo: centerXAnchor),
            knob.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let delta = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        onMove?(delta)
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
    var allowsLocalFallback: Bool = true
    var onAssetFailure: ((String) -> Void)? = nil
    var wallColor: UIColor = .white
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
        coord.editMode = editMode
        Task { @MainActor in await buildScene(into: roomAnchor, coordinator: coord) }

        // 제스처 — editMode는 SwiftUI 상태 변경으로 나중에 켜질 수 있고 makeUIView는 다시 안
        // 불리므로, 제스처 자체는 항상 등록해두고 동작 여부는 매번 coordinator.editMode로 판단한다.
        // pan/pinch/rotation은 항상 카메라 전용 — 가구 조작이 더 이상 연속 드래그가 아니라서 경쟁이 없다.
        arView.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan)))
        arView.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch)))
        arView.addGestureRecognizer(UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation)))
        arView.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap)))

        // 가구 편집 핸들바 — 가구가 선택됐을 때만 오른쪽 중간에 나타남
        let handle = FurnitureNudgeHandle()
        handle.isHidden = true
        arView.addSubview(handle)
        NSLayoutConstraint.activate([
            handle.trailingAnchor.constraint(equalTo: arView.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            handle.centerYAnchor.constraint(equalTo: arView.centerYAnchor),
        ])
        handle.onMove = { [weak coord] delta in coord?.nudgeSelectedEntity(by: delta) }
        coord.nudgeHandle = handle

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.editMode != editMode {
            coordinator.editMode = editMode
            if !editMode {
                coordinator.deselect()   // 편집 모드 나가면 선택 표시(확대 강조) 원복
            }
        }
        // 채팅에서 "이 가구 빼면?" 물어볼 때마다 hiddenIdentifiers가 바뀌고, 여기서 그 가구만
        // 실제로 껐다 켠다 (재생성 없이 바로 반영 — 대화하면서 즉시 확인 가능하게).
        for (id, entity) in coordinator.entitiesByIdentifier {
            entity.isEnabled = !hiddenIdentifiers.contains(id)
        }
    }

    // MARK: 씬 구성
    // 1) data_url → 가구 배치 JSON
    // 2) JSON walls/floors/doors → 방 구조 박스
    // 3) model_urls USDC → 가구 모델, 없으면 카테고리 색상 박스
    // 4) 씬 전체를 카메라 시야 중앙으로 오도록 anchor 이동 + 카메라 거리 자동 조정

    @MainActor
    private func buildScene(into anchor: AnchorEntity, coordinator: Coordinator) async {

        let effectiveWallColor = wallColor.withAlphaComponent(isTransparent ? 0.35 : 1.0)

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
            if let raw = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let firstObj = (raw["objects"] as? [[String: Any]])?.first {
                print("🔍 objects[0] 전체: \(firstObj)")
            }
            payload = try JSONDecoder().decode(RoomDataPayload.self, from: jsonData)
            print("✅ JSON 파싱 완료: 오브젝트 \(payload.objects.count)개")
        } catch {
            onAssetFailure?("서버 공간 데이터를 불러오지 못했습니다.")
            print("❌ data_url 파싱 실패: \(error) – 방 구조만 표시")
            return
        }

        // 🔧 디버그: capturedRoom 없이(JSON만으로) 그리는 경로에서 벽/가구 위치가 실제로
        // 어떻게 어긋나는지 확인하기 위한 임시 로그. 문제 재현되면 이 로그로 벽 좌표 대비
        // 가구 좌표가 room 밖/다른 벽 쪽에 있는지 바로 확인 가능.
        if capturedRoom == nil {
            print("🪵 [디버그] dataURL = \(dataURLString)")
            for (i, wall) in (payload.walls ?? []).enumerated() {
                if let t = wall.simdTransform {
                    let c = t.columns.3
                    print("🪵 [디버그] wall[\(i)] center=(\(c.x), \(c.y), \(c.z)) dims=\(wall.dimensions)")
                } else {
                    print("🪵 [디버그] wall[\(i)] simdTransform 디코딩 실패, dims=\(wall.dimensions)")
                }
            }
            for floor in payload.floors ?? [] {
                if let t = floor.simdTransform {
                    let c = t.columns.3
                    print("🪵 [디버그] floor center=(\(c.x), \(c.y), \(c.z)) dims=\(floor.dimensions)")
                }
            }
            for obj in payload.objects {
                if let t = obj.simdTransform {
                    let c = t.columns.3
                    print("🪵 [디버그] object id=\(obj.identifier) cat=\(obj.category ?? "?") transform.center=(\(c.x), \(c.y), \(c.z)) json.center=\(obj.center ?? [])")
                }
            }
        }

        // 배치 클램프 기준 벽 목록 — editMode가 나중에 켜질 수도 있으니 항상 미리 준비해둔다.
        // 바닥 사각형 근사 대신 실제 렌더링되는 벽 평면을 그대로 써서 방이 직사각형이 아니어도
        // (L자 등) 정확하게 막힌다. capturedRoom 셸이 있으면 그쪽 우선.
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

        // ── 가구 배치 ──────────────────────────────────────────────────────────
        for obj in payload.objects {
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
                    var request = URLRequest(url: remoteURL)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    let (tmpURL, response) = try await URLSession.shared.download(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    let destURL = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent(UUID().uuidString + "." + ext)
                    try FileManager.default.moveItem(at: tmpURL, to: destURL)
                    defer { try? FileManager.default.removeItem(at: destURL) }
                    let loaded = try Entity.loadSync(contentsOf: destURL)
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
                    let loaded = try Entity.loadSync(contentsOf: localURL)
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

            // 4. 박스 폴백
            if !placed, allowsLocalFallback {
                print("  📦 \(obj.category ?? ""): 박스 폴백")
                let box = makeFallbackBox(for: obj)
                box.transform = Transform(matrix: matrix)
                anchor.addChild(box)
                placedEntity = box
            }

            if !placed, !allowsLocalFallback {
                onAssetFailure?("일부 서버 가구 모델을 불러오지 못했어요. 다시 불러오기를 눌러주세요.")
            }
            // 히트테스트용 이름 + 콜리전 부여 (카탈로그 모델은 메쉬가 자식 노드일 수 있어 recursive) —
            // editMode가 나중에 켜질 수도 있으니 항상 준비해둔다.
            if let placedEntity {
                placedEntity.name = "furniture_\(obj.identifier)"
                placedEntity.generateCollisionShapes(recursive: true)
                // AI 배치 상담의 가구 제외 시뮬레이션이 나중에 켜고 끌 수 있도록 식별자로 등록
                coordinator.entitiesByIdentifier[obj.identifier] = placedEntity
                // Preserve server coordinates on load. Wall clamping belongs to
                // explicit user edits; independently pushing objects creates overlaps.
            }
        }
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
        mat.color = .init(tint: furnitureTint ?? colorForCategory(obj.category ?? ""))
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
    class Coordinator: NSObject {
        weak var arView: ARView?
        var roomAnchor: AnchorEntity?
        var camera: PerspectiveCamera?          // 카메라 거리 동적 조정용
        var editMode: Bool = false
        /// identifier → 배치된 엔티티. AI 배치 상담의 가구 제외 시뮬레이션이 이걸로 보이기/숨기기 전환
        var entitiesByIdentifier: [String: Entity] = [:]
        /// 편집 모드에서 선택된 가구를 옮기는 오른쪽 핸들바 — 선택 여부에 따라 보이기/숨기기
        var nudgeHandle: FurnitureNudgeHandle?

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

        private var lastScale: Float = 1.0
        private var currentScale: Float = 1.0
        private var lastRotation: Float = 0

        /// 편집 모드에서 현재 선택된 가구 — 탭으로 골라두면 확대 표시되고, 그 상태에서 빈 바닥을
        /// 탭하면 그 자리로 배치된다. 연속 드래그가 아니라 "탭 한 번 = 위치 확정"이라 벽 통과가
        /// 구조적으로 발생하지 않는다 (최종 위치 딱 한 번만 clampEntityToWalls로 검사).
        private var selectedEntity: Entity?
        private var selectedOriginalScale: SIMD3<Float>?

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

        /// 편집 모드 전용 탭 처리:
        /// - 가구를 탭 → 선택(확대 강조 + 오른쪽 핸들바 표시). 이미 선택된 같은 가구를 다시 탭
        ///   → 제자리 90도 회전.
        /// - 선택된 상태에서 가구가 아닌 곳을 탭 → 선택 해제(핸들바 숨김).
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard editMode, g.state == .ended, let arView else { return }
            let loc = g.location(in: arView)
            let hit = furnitureRoot(from: arView.entity(at: loc))

            if let hit {
                if hit === selectedEntity {
                    hit.orientation *= simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
                } else {
                    select(hit)
                }
            } else {
                deselect()
            }
        }

        /// 오른쪽 핸들바를 민 화면 delta(pt)를 카메라 기준 좌/우·앞/뒤 이동으로 변환해 선택된
        /// 가구를 옮긴다. 3D 화면을 직접 탭/드래그하는 것보다 시점 각도에 안 흔들려서 예측 가능하다.
        func nudgeSelectedEntity(by screenDelta: CGPoint) {
            guard let selectedEntity, let camera else { return }
            let m = camera.transform.matrix
            var right   = SIMD3<Float>(m.columns.0.x, 0, m.columns.0.z)
            var forward = SIMD3<Float>(-m.columns.2.x, 0, -m.columns.2.z)   // 카메라는 -Z 방향을 봄
            if length(right) > 0.001   { right = normalize(right) }
            if length(forward) > 0.001 { forward = normalize(forward) }

            let sensitivity: Float = 0.012
            let dx = Float(screenDelta.x) * sensitivity
            let dz = Float(screenDelta.y) * sensitivity   // 화면 아래로 밀면 카메라 쪽(뒤)으로

            let worldDelta = right * dx - forward * dz
            let current = selectedEntity.position(relativeTo: nil)
            selectedEntity.setPosition(current + worldDelta, relativeTo: nil)
            clampEntityToWalls(selectedEntity)
        }

        private func select(_ entity: Entity) {
            deselect()
            selectedEntity = entity
            selectedOriginalScale = entity.scale
            entity.scale *= 1.08   // 선택 표시 — 살짝 확대
            nudgeHandle?.isHidden = false
        }

        /// 편집 모드를 나가거나 다른 가구를 선택/해제할 때 이전 선택 표시를 원래대로 되돌린다.
        func deselect() {
            if let selectedEntity, let selectedOriginalScale {
                selectedEntity.scale = selectedOriginalScale
            }
            selectedEntity = nil
            selectedOriginalScale = nil
            nudgeHandle?.isHidden = true
        }

        /// 손가락 개수와 무관하게 pan은 항상 카메라 궤도 회전 — 가구 조작이 더 이상 연속
        /// 드래그가 아니라서(탭 한 번으로 배치) 더는 경쟁할 대상이 없다.
        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            let delta = Float(g.translation(in: arView).x) * 0.005
            roomAnchor?.orientation *= simd_quatf(angle: delta, axis: [0, 1, 0])
            g.setTranslation(.zero, in: arView)
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

        private func clampToWallBarriers(_ entity: Entity) {
            guard !wallBarriers.isEmpty else { return }
            let corners = worldCorners(of: entity)

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
            let currentWorld = entity.position(relativeTo: nil)
            entity.setPosition(currentWorld + totalPush, relativeTo: nil)
        }

        /// 바닥 전체를 감싸는 사각형 밖으로는 절대 못 나가게 하는 안전망. 벽 구간 사이 틈(모서리 등)
        /// 때문에 clampToWallBarriers가 못 잡는 극단적인 경우를 여기서 마지막으로 잡는다.
        private func clampToFloorRectangle(_ entity: Entity) {
            guard let floorTransform, let floorHalfExtent else { return }
            let corners = worldCorners(of: entity)
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

            let worldDelta4 = floorTransform * SIMD4<Float>(dx, dy, 0, 0)
            let worldDelta = SIMD3(worldDelta4.x, worldDelta4.y, worldDelta4.z)
            let currentWorld = entity.position(relativeTo: nil)
            entity.setPosition(currentWorld + worldDelta, relativeTo: nil)
        }

        private func worldCorners(of entity: Entity) -> [SIMD3<Float>] {
            let bounds = entity.visualBounds(relativeTo: nil)
            var corners: [SIMD3<Float>] = []
            corners.reserveCapacity(8)
            for x in [bounds.min.x, bounds.max.x] {
                for y in [bounds.min.y, bounds.max.y] {
                    for z in [bounds.min.z, bounds.max.z] {
                        corners.append(SIMD3(x, y, z))
                    }
                }
            }
            return corners
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
