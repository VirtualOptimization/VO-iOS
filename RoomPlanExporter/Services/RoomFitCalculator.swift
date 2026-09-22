import Foundation
import simd

// MARK: - AI 배치 상담의 계산 엔진
//
// suggest_placement / simulate_without tool의 실제 구현부. 전부 결정론적 계산이고
// AI(Claude)는 이 결과를 자연어로 설명만 한다 — 좌표나 면적을 스스로 추정하지 않는다.
// 바닥 로컬 좌표계 변환은 RoomViewerView의 clampEntityToFloor와 동일한 방식(local X = 폭,
// local Y = 깊이, local Z = 법선)을 따른다.

enum RoomFitCalculator {

    struct PlacementResult {
        let fits: Bool
        let summary: String   // Claude에게 tool_result로 돌려줄 설명
    }

    struct SimulationResult {
        let matched: Bool
        let identifier: String?   // 매칭된 가구의 식별자 — 3D 뷰에서 실제로 숨기는 데 사용
        let summary: String
    }

    // MARK: - suggest_placement

    static func suggestPlacement(in room: RoomDataPayload, widthCm: Double, depthCm: Double) -> PlacementResult {
        guard let floor = room.floors?.first, let floorT = floor.simdTransform, floor.dimensions.count >= 2 else {
            return PlacementResult(fits: false, summary: "방 바닥 정보를 찾을 수 없어서 계산할 수 없어요.")
        }
        guard widthCm > 0, depthCm > 0 else {
            return PlacementResult(fits: false, summary: "가구 치수가 올바르지 않아요.")
        }

        let halfW = Float(floor.dimensions[0]) / 2
        let halfD = Float(floor.dimensions[1]) / 2
        let objHalfW = Float(widthCm / 100) / 2
        let objHalfD = Float(depthCm / 100) / 2

        guard objHalfW < halfW, objHalfD < halfD else {
            return PlacementResult(fits: false, summary: "가구가 방보다 커서 어디에도 들어가지 않아요.")
        }

        // 기존 가구를 바닥 로컬 좌표계 기준 axis-aligned 사각형으로 근사
        let inv = floorT.inverse
        let obstacles: [(cx: Float, cz: Float, hw: Float, hd: Float)] = room.objects.compactMap { obj in
            guard let m = obj.simdTransform else { return nil }
            let world = SIMD4<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z, 1)
            let local = inv * world
            let d = obj.dimensions ?? [0.5, 0, 0.5]
            let hw = Float((d.count > 0 ? d[0] : 0.5)) / 2
            let hd = Float((d.count > 2 ? d[2] : 0.5)) / 2
            return (local.x, local.y, hw, hd)
        }

        let step: Float = 0.1
        var x = -halfW + objHalfW
        while x <= halfW - objHalfW {
            var z = -halfD + objHalfD
            while z <= halfD - objHalfD {
                let overlaps = obstacles.contains { ob in
                    abs(x - ob.cx) < (objHalfW + ob.hw) && abs(z - ob.cz) < (objHalfD + ob.hd)
                }
                if !overlaps {
                    let fx = String(format: "%.1f", x)
                    let fz = String(format: "%.1f", z)
                    return PlacementResult(
                        fits: true,
                        summary: "들어가요. 방 중심 기준 가로 \(fx)m, 세로 \(fz)m 지점에 놓으면 기존 가구와 겹치지 않고 벽 밖으로도 안 나가요."
                    )
                }
                z += step
            }
            x += step
        }
        return PlacementResult(
            fits: false,
            summary: "가로 \(Int(widthCm))cm × 세로 \(Int(depthCm))cm 가구가 들어갈 빈 공간이 지금 방에는 없어요."
        )
    }

    // MARK: - simulate_without

    private static let categoryKeywordMap: [(keywords: [String], category: String)] = [
        (["책상", "테이블", "탁자"], "table"),
        (["의자"], "chair"),
        (["침대"], "bed"),
        (["소파"], "sofa"),
        (["옷장", "수납", "선반", "책장", "장롱"], "storage"),
        (["티비", "티브이", "텔레비전", "tv"], "television"),
        (["냉장고"], "refrigerator"),
    ]

    static func simulateWithout(in room: RoomDataPayload, query: String) -> SimulationResult {
        let matchedCategory = categoryKeywordMap.first { pair in
            pair.keywords.contains { query.contains($0) }
        }?.category

        guard let matchedCategory,
              let matched = room.objects.first(where: { $0.category?.lowercased().contains(matchedCategory) == true }),
              let dims = matched.dimensions, dims.count >= 3 else {
            return SimulationResult(matched: false, identifier: nil, summary: "'\(query)'에 해당하는 가구를 방에서 찾지 못했어요.")
        }

        let area = Double(dims[0] * dims[2])
        let floorArea: Double = {
            guard let floor = room.floors?.first, floor.dimensions.count >= 2 else { return 0 }
            return Double(floor.dimensions[0] * floor.dimensions[1])
        }()
        let percent = floorArea > 0 ? area / floorArea * 100 : 0

        let areaText = String(format: "%.1f", area)
        let percentText = String(format: "%.0f", percent)
        return SimulationResult(
            matched: true,
            identifier: matched.identifier,
            summary: "'\(query)'를 빼면 약 \(areaText)㎡ (방 전체의 \(percentText)%)가 확보돼요. 지금 화면에서도 바로 숨겨봤어요."
        )
    }
}
