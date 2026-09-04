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
                    if let furnitureTint { applyTint(to: model, color: furnitureTint) }
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

// MARK: - 가구를 드래그로 옮길 수 있는 RealityKit 뷰
//
// 스캔 직후 인식된 가구를 손가락으로 눌러 바닥 위에서 옮기거나 탭해서 90도씩 돌릴 수 있는 뷰어.
// RoomResultView(스캔 결과 확인 화면)에서 사용한다.

fileprivate func fallbackColorForCategory(_ category: CapturedRoom.Object.Category) -> UIColor {
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

struct DraggableFurnitureRoomView: UIViewRepresentable {
    let capturedRoom: CapturedRoom

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.environment.background = .color(UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1.0))
        arView.cameraMode = .nonAR
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let camAnchor = AnchorEntity(world: .zero)
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 60
        camera.position = SIMD3(0, 6, 4.5)
        camera.look(at: .zero, from: camera.position, relativeTo: nil)
        camAnchor.addChild(camera)
        arView.scene.addAnchor(camAnchor)

        let lightAnchor = AnchorEntity(world: .zero)
        let dir = DirectionalLight()
        dir.light.intensity = 3000; dir.light.color = .white
        dir.orientation = simd_quatf(angle: -.pi/3, axis: [1, 0, 0])
        lightAnchor.addChild(dir)
        let pt = PointLight()
        pt.light.intensity = 1000; pt.position = [0, 4, 0]
        lightAnchor.addChild(pt)
        arView.scene.addAnchor(lightAnchor)

        let roomAnchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(roomAnchor)
        context.coordinator.arView = arView
        context.coordinator.roomAnchor = roomAnchor

        // 벽 (문/창문 구멍 반영) + 바닥
        for wall in capturedRoom.walls {
            let openings = capturedRoomOpenings(wall: wall, doors: capturedRoom.doors, windows: capturedRoom.windows)
            wallSegments(wallTransform: wall.transform, wallW: wall.dimensions.x, wallH: wall.dimensions.y,
                        openings: openings, color: .white, depth: 0.04)
                .forEach { roomAnchor.addChild($0) }
        }
        for floor in capturedRoom.floors {
            var mat = SimpleMaterial()
            mat.color = .init(tint: .white); mat.roughness = 0.9; mat.metallic = 0.0
            let entity = ModelEntity(
                mesh: .generateBox(width: floor.dimensions.x, height: floor.dimensions.y, depth: 0.01),
                materials: [mat]
            )
            entity.transform = Transform(matrix: floor.transform)
            roomAnchor.addChild(entity)
        }
        // 드래그 시 벽 밖으로 못 나가게 클램프할 기준 (첫 번째 바닥 사각형 기준 — 요철 있는 방은 근사치)
        if let floor = capturedRoom.floors.first {
            context.coordinator.floorTransform = floor.transform
            context.coordinator.floorHalfExtent = SIMD2(floor.dimensions.x / 2, floor.dimensions.y / 2)
        }

        // 가구 (드래그 대상 — "furniture_" 접두사로 히트테스트에서 구분)
        // RoomPlanCatalog 번들의 실제 모델을 시도하고, 실패하면 카테고리 색상 박스로 폴백
        // (loadOptimizedScene과 동일한 방식) — 카탈로그 로딩은 비동기라 Task로 감싼다.
        Task { @MainActor [capturedRoom] in
            let mp = try? CapturedRoom.ModelProvider.load()
            for obj in capturedRoom.objects {
                let t = obj.transform
                let center = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                let rotation = simd_quatf(t)
                let d = obj.dimensions

                var placed: Entity? = nil
                if let mp, let modelURL = try? mp.modelFileURL(for: obj),
                   let model = try? Entity.loadSync(contentsOf: modelURL) {
                    let bounds = model.visualBounds(relativeTo: model)
                    let bSize = bounds.max - bounds.min
                    if bSize.x > 0.001 && bSize.y > 0.001 && bSize.z > 0.001 {
                        model.scale = SIMD3(d.x / bSize.x, d.y / bSize.y, d.z / bSize.z)
                        let centerOffset = (bounds.max + bounds.min) / 2
                        model.position = center - centerOffset * model.scale
                    } else {
                        model.position = center
                    }
                    model.orientation = rotation
                    placed = model
                }

                let entity: Entity
                if let placed {
                    entity = placed
                } else {
                    var mat = SimpleMaterial()
                    mat.color = .init(tint: fallbackColorForCategory(obj.category))
                    mat.roughness = 0.9; mat.metallic = 0.0
                    let box = ModelEntity(
                        mesh: .generateBox(width: d.x, height: d.y, depth: d.z, cornerRadius: 0.03),
                        materials: [mat]
                    )
                    box.transform = Transform(matrix: t)
                    entity = box
                }

                entity.name = "furniture_\(obj.identifier.uuidString)"
                // entity(at:) 히트테스트가 CollisionComponent 기준으로 동작하므로 반드시 생성해줘야 함
                // (카탈로그 모델은 메쉬가 자식 노드에 있을 수 있어 recursive: true)
                entity.generateCollisionShapes(recursive: true)
                roomAnchor.addChild(entity)
            }
        }

        // 1손가락 = 가구 드래그/배경 회전 전용. 손가락 개수를 제한 안 하면 2손가락 회전 제스처와
        // 같은 터치를 두고 경쟁하다 pan이 먼저 가로채서 회전 제스처가 아예 안 먹는 문제가 생김.
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        panGesture.maximumNumberOfTouches = 1
        arView.addGestureRecognizer(panGesture)
        arView.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch)))
        arView.addGestureRecognizer(UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation)))
        arView.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap)))

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    // MARK: - Coordinator (가구 드래그 vs 배경 회전 분기)

    class Coordinator: NSObject {
        weak var arView: ARView?
        var roomAnchor: AnchorEntity?

        /// 바닥 사각형 기준 (드래그 클램프용)
        var floorTransform: simd_float4x4?
        var floorHalfExtent: SIMD2<Float>?

        private var draggedEntity: Entity?
        private var dragPlaneY: Float = 0
        private var dragOffset: SIMD3<Float> = .zero
        private var isOrbiting = false

        private var lastScale: Float = 1
        private var currentScale: Float = 1
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

        /// 가구를 탭하면 그 자리에서 90도씩 회전 (제자리 회전 — 위치는 그대로).
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let arView else { return }
            guard let hit = furnitureRoot(from: arView.entity(at: g.location(in: arView))) else { return }
            hit.orientation *= simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        }

        /// 가구를 눌렀으면 그 가구를 바닥 평면 위에서 드래그, 빈 공간을 눌렀으면 방 전체를 회전.
        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }
            let loc = g.location(in: arView)

            switch g.state {
            case .began:
                if let hit = furnitureRoot(from: arView.entity(at: loc)) {
                    draggedEntity = hit
                    let worldPos = hit.position(relativeTo: nil)
                    dragPlaneY = worldPos.y
                    dragOffset = floorPoint(at: loc, planeY: dragPlaneY, in: arView).map { worldPos - $0 } ?? .zero
                } else {
                    draggedEntity = nil
                    isOrbiting = true
                }
            case .changed:
                if let draggedEntity {
                    if let touchPoint = floorPoint(at: loc, planeY: dragPlaneY, in: arView) {
                        draggedEntity.setPosition(touchPoint + dragOffset, relativeTo: nil)
                        clampEntityToFloor(draggedEntity)
                    }
                } else if isOrbiting {
                    let delta = Float(g.translation(in: arView).x) * 0.005
                    roomAnchor?.orientation *= simd_quatf(angle: delta, axis: [0, 1, 0])
                    g.setTranslation(.zero, in: arView)
                }
            case .ended, .cancelled, .failed:
                draggedEntity = nil
                isOrbiting = false
            default: break
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

        /// 화면 좌표 → 카메라 레이와 y=planeY 수평면의 교점 (월드 좌표)
        private func floorPoint(at location: CGPoint, planeY: Float, in arView: ARView) -> SIMD3<Float>? {
            guard let ray = arView.ray(through: location) else { return nil }
            guard abs(ray.direction.y) > 0.0001 else { return nil }
            let t = (planeY - ray.origin.y) / ray.direction.y
            guard t > 0 else { return nil }
            return ray.origin + ray.direction * t
        }

        /// 엔티티의 실제 렌더링 바운드(카탈로그 모델은 피벗이 중심이 아닐 수 있어 근사 마진 대신 실측)가
        /// 바닥 사각형을 벗어난 만큼 다시 안쪽으로 밀어넣는다 — 그래야 몸체가 벽에 안 걸침.
        private func clampEntityToFloor(_ entity: Entity) {
            guard let floorTransform, let floorHalfExtent else { return }
            let bounds = entity.visualBounds(relativeTo: nil)
            let inv = floorTransform.inverse

            var minLocalX = Float.greatestFiniteMagnitude, maxLocalX = -Float.greatestFiniteMagnitude
            var minLocalY = Float.greatestFiniteMagnitude, maxLocalY = -Float.greatestFiniteMagnitude
            for cx in [bounds.min.x, bounds.max.x] {
                for cy in [bounds.min.y, bounds.max.y] {
                    for cz in [bounds.min.z, bounds.max.z] {
                        let local = inv * SIMD4<Float>(cx, cy, cz, 1)
                        minLocalX = min(minLocalX, local.x); maxLocalX = max(maxLocalX, local.x)
                        minLocalY = min(minLocalY, local.y); maxLocalY = max(maxLocalY, local.y)
                    }
                }
            }

            var dx: Float = 0
            if maxLocalX > floorHalfExtent.x { dx = floorHalfExtent.x - maxLocalX }
            else if minLocalX < -floorHalfExtent.x { dx = -floorHalfExtent.x - minLocalX }
            var dy: Float = 0
            if maxLocalY > floorHalfExtent.y { dy = floorHalfExtent.y - maxLocalY }
            else if minLocalY < -floorHalfExtent.y { dy = -floorHalfExtent.y - minLocalY }
            guard dx != 0 || dy != 0 else { return }

            let worldDelta4 = floorTransform * SIMD4<Float>(dx, dy, 0, 0)   // w=0 → 이동량만 회전, 평행이동 없음
            let worldDelta = SIMD3(worldDelta4.x, worldDelta4.y, worldDelta4.z)
            let currentWorld = entity.position(relativeTo: nil)
            entity.setPosition(currentWorld + worldDelta, relativeTo: nil)
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

        // 2. 로컬에 없으면 서버 카탈로그(usdc_url)에서 다운로드
        if let fileName = obj.modelFileName,
           let remoteURL = await CatalogModelCache.shared.usdcURL(forModelKey: fileName) {
            do {
                let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
                let destURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent(UUID().uuidString + ".usdc")
                try FileManager.default.moveItem(at: tmpURL, to: destURL)
                let model = try Entity.loadSync(contentsOf: destURL)
                applyTransform(to: model, obj: obj)
                print("✅ 서버 카탈로그 모델 로드: \(fileName)")
                return model
            } catch {
                print("⚠️ 서버 카탈로그 로드 실패 (\(fileName)): \(error)")
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

// MARK: - FurnitureRealityKitView (rooms API 버전 상세 기반 3D 뷰어)
//
// B안: capturedRoom이 제공되면 로컬 USDZ를 생성하여 방 shell을 렌더링하고
//       가구는 숨긴 뒤, JSON의 최적화된 가구를 오버레이한다.
// 폴백: capturedRoom이 없으면 JSON 박스 기반 렌더링.

struct FurnitureRealityKitView: UIViewRepresentable {
    let detail: RoomVersionDetail
    var capturedRoom: CapturedRoom? = nil   // B안: 제공 시 로컬 USDZ로 방 shell 렌더링
    var isTransparent: Bool = false         // 투명 모드: 반투명 벽 박스
    var wallColor: UIColor = .white
    var floorColor: UIColor = .white
    /// 카탈로그 모델/박스 폴백 가구에 적용할 색상 (nil이면 원래 색 유지). usdc_url로 로드되는
    /// 사용자 본인의 AI 생성 가구(사진 기반)에는 적용하지 않음 — 실제 촬영 결과와 어긋나 보일 수 있어서.
    var furnitureTint: UIColor? = nil
    /// true면 가구를 탭+드래그로 옮기거나 탭해서 90도씩 돌릴 수 있음 (내 공간 조회 화면 전용).
    /// false(기본값)면 기존과 동일하게 화면 전체가 카메라 조작(회전/줌) 전용.
    var allowsDragging: Bool = false

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
        coord.allowsDragging = allowsDragging
        Task { @MainActor in await buildScene(into: roomAnchor, coordinator: coord) }

        // 제스처
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        // 드래그 모드에서는 1손가락 = 가구 드래그/배경 회전 전용으로 제한 — 안 그러면 2손가락 회전
        // 제스처와 같은 터치를 두고 경쟁하다 pan이 먼저 가로채서 회전이 아예 안 먹는 문제가 생김.
        if allowsDragging { panGesture.maximumNumberOfTouches = 1 }
        arView.addGestureRecognizer(panGesture)
        arView.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator,    action: #selector(Coordinator.handlePinch)))
        arView.addGestureRecognizer(UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation)))
        if allowsDragging {
            arView.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap)))
        }

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
            print("❌ data_url 파싱 실패: \(error) – 방 구조만 표시")
            return
        }

        // 드래그 클램프 기준 바닥 사각형 (capturedRoom 셸이 있으면 그쪽 우선, 없으면 JSON 바닥)
        if allowsDragging {
            if let room = capturedRoom, let floor = room.floors.first {
                coordinator.floorTransform = floor.transform
                coordinator.floorHalfExtent = SIMD2(floor.dimensions.x / 2, floor.dimensions.y / 2)
            } else if let floor = payload.floors?.first, let ft = floor.simdTransform, floor.dimensions.count >= 2 {
                coordinator.floorTransform = ft
                coordinator.floorHalfExtent = SIMD2(floor.dimensions[0] / 2, floor.dimensions[1] / 2)
            }
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

        // ── 가구 배치 ──────────────────────────────────────────────────────────
        for obj in payload.objects {
            guard let matrix = obj.simdTransform else { continue }
            let worldPos = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)

            var placed = false
            var placedEntity: Entity? = nil

            // 1. usdc_url (USER_EDITED 버전: S3 presigned URL)
            if !placed, let urlStr = obj.usdcUrl, let remoteURL = URL(string: urlStr) {
                do {
                    let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
                    let destURL = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent(UUID().uuidString + ".usdc")
                    try FileManager.default.moveItem(at: tmpURL, to: destURL)
                    let loaded = try Entity.loadSync(contentsOf: destURL)
                    applyTransform(to: loaded, matrix: matrix, worldPos: worldPos, obj: obj)
                    anchor.addChild(loaded)
                    placed = true
                    placedEntity = loaded
                    print("  ✅ \(obj.modelFileName ?? "") usdc_url 로드 성공")
                } catch {
                    print("  ⚠️ usdc_url 로드 실패: \(error)")
                }
            }

            // 2. 로컬 RoomPlanCatalog.bundle
            if !placed, let fileName = obj.modelFileName,
               let localURL = findCatalogModel(named: fileName) {
                do {
                    let loaded = try Entity.loadSync(contentsOf: localURL)
                    applyTransform(to: loaded, matrix: matrix, worldPos: worldPos, obj: obj)
                    if let furnitureTint { applyTint(to: loaded, color: furnitureTint) }
                    anchor.addChild(loaded)
                    placed = true
                    placedEntity = loaded
                    print("  ✅ \(obj.category ?? "") (\(fileName)) 로컬 카탈로그 로드 성공")
                } catch {
                    print("  ⚠️ \(obj.category ?? "") (\(fileName)) 로컬 로드 실패: \(error)")
                }
            }

            // 3. 로컬에 없으면 서버 카탈로그(usdc_url)에서 다운로드
            if !placed, let fileName = obj.modelFileName,
               let remoteURL = await CatalogModelCache.shared.usdcURL(forModelKey: fileName) {
                do {
                    let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
                    let destURL = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent(UUID().uuidString + ".usdc")
                    try FileManager.default.moveItem(at: tmpURL, to: destURL)
                    let loaded = try Entity.loadSync(contentsOf: destURL)
                    applyTransform(to: loaded, matrix: matrix, worldPos: worldPos, obj: obj)
                    if let furnitureTint { applyTint(to: loaded, color: furnitureTint) }
                    anchor.addChild(loaded)
                    placed = true
                    placedEntity = loaded
                    print("  ✅ \(obj.category ?? "") (\(fileName)) 서버 카탈로그 로드 성공")
                } catch {
                    print("  ⚠️ \(obj.category ?? "") (\(fileName)) 서버 카탈로그 로드 실패: \(error)")
                }
            }

            // 4. 박스 폴백
            if !placed {
                print("  📦 \(obj.category ?? ""): 박스 폴백")
                let box = makeFallbackBox(for: obj)
                box.transform = Transform(matrix: matrix)
                anchor.addChild(box)
                placedEntity = box
            }

            // 드래그 모드: 히트테스트용 이름 + 콜리전 부여 (카탈로그 모델은 메쉬가 자식 노드일 수 있어 recursive)
            if allowsDragging, let placedEntity {
                placedEntity.name = "furniture_\(obj.identifier)"
                placedEntity.generateCollisionShapes(recursive: true)
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

        if dims.count >= 3, bSize.x > 0.001, bSize.y > 0.001, bSize.z > 0.001 {
            let scale = SIMD3<Float>(dims[0] / bSize.x, dims[1] / bSize.y, dims[2] / bSize.z)
            let pivot = (bounds.max + bounds.min) / 2
            let orientation = simd_quatf(matrix)
            // rotation 적용 후 pivot 오프셋을 보정해야 center가 worldPos에 정확히 놓임
            entity.scale       = scale
            entity.orientation = orientation
            entity.position    = worldPos - orientation.act(pivot * scale)
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

    /// 카테고리별 색상 박스 (배경색과 겹치지 않는 뚜렷한 색상). furnitureTint 있으면 그걸로 통일.
    private func makeFallbackBox(for obj: RoomDataPayload.RoomObject) -> ModelEntity {
        var mat = SimpleMaterial()
        mat.color = .init(tint: furnitureTint ?? colorForCategory(obj.category ?? ""))
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
        var allowsDragging: Bool = false
        /// 바닥 사각형 기준 (드래그 클램프용)
        var floorTransform: simd_float4x4?
        var floorHalfExtent: SIMD2<Float>?

        private var lastScale: Float = 1.0
        private var currentScale: Float = 1.0
        private var lastRotation: Float = 0

        private var draggedEntity: Entity?
        private var dragPlaneY: Float = 0
        private var dragOffset: SIMD3<Float> = .zero
        private var isOrbiting = false

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

        /// 가구를 탭하면 그 자리에서 90도씩 회전 (드래그 모드 전용).
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard allowsDragging, g.state == .ended, let arView else { return }
            guard let hit = furnitureRoot(from: arView.entity(at: g.location(in: arView))) else { return }
            hit.orientation *= simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView else { return }

            guard allowsDragging else {
                // 드래그 모드가 아니면 기존 동작 그대로 — 손가락 하나로 방 전체 회전.
                let delta = Float(g.translation(in: arView).x) * 0.005
                roomAnchor?.orientation *= simd_quatf(angle: delta, axis: [0, 1, 0])
                g.setTranslation(.zero, in: arView)
                return
            }

            // 가구를 눌렀으면 그 가구를 바닥 평면 위에서 드래그, 빈 공간을 눌렀으면 방 전체를 회전.
            let loc = g.location(in: arView)
            switch g.state {
            case .began:
                if let hit = furnitureRoot(from: arView.entity(at: loc)) {
                    draggedEntity = hit
                    let worldPos = hit.position(relativeTo: nil)
                    dragPlaneY = worldPos.y
                    dragOffset = floorPoint(at: loc, planeY: dragPlaneY, in: arView).map { worldPos - $0 } ?? .zero
                } else {
                    draggedEntity = nil
                    isOrbiting = true
                }
            case .changed:
                if let draggedEntity {
                    if let touchPoint = floorPoint(at: loc, planeY: dragPlaneY, in: arView) {
                        draggedEntity.setPosition(touchPoint + dragOffset, relativeTo: nil)
                        clampEntityToFloor(draggedEntity)
                    }
                } else if isOrbiting {
                    let delta = Float(g.translation(in: arView).x) * 0.005
                    roomAnchor?.orientation *= simd_quatf(angle: delta, axis: [0, 1, 0])
                    g.setTranslation(.zero, in: arView)
                }
            case .ended, .cancelled, .failed:
                draggedEntity = nil
                isOrbiting = false
            default: break
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

        /// 화면 좌표 → 카메라 레이와 y=planeY 수평면의 교점 (월드 좌표)
        private func floorPoint(at location: CGPoint, planeY: Float, in arView: ARView) -> SIMD3<Float>? {
            guard let ray = arView.ray(through: location) else { return nil }
            guard abs(ray.direction.y) > 0.0001 else { return nil }
            let t = (planeY - ray.origin.y) / ray.direction.y
            guard t > 0 else { return nil }
            return ray.origin + ray.direction * t
        }

        /// 엔티티의 실제 렌더링 바운드가 바닥 사각형을 벗어난 만큼 다시 안쪽으로 밀어넣는다
        /// — 근사 마진 대신 실측이라 카탈로그 모델의 피벗이 중심이 아니어도 정확함.
        private func clampEntityToFloor(_ entity: Entity) {
            guard let floorTransform, let floorHalfExtent else { return }
            let bounds = entity.visualBounds(relativeTo: nil)
            let inv = floorTransform.inverse

            var minLocalX = Float.greatestFiniteMagnitude, maxLocalX = -Float.greatestFiniteMagnitude
            var minLocalY = Float.greatestFiniteMagnitude, maxLocalY = -Float.greatestFiniteMagnitude
            for cx in [bounds.min.x, bounds.max.x] {
                for cy in [bounds.min.y, bounds.max.y] {
                    for cz in [bounds.min.z, bounds.max.z] {
                        let local = inv * SIMD4<Float>(cx, cy, cz, 1)
                        minLocalX = min(minLocalX, local.x); maxLocalX = max(maxLocalX, local.x)
                        minLocalY = min(minLocalY, local.y); maxLocalY = max(maxLocalY, local.y)
                    }
                }
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
