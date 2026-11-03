import Foundation
import simd

/// Deterministic evidence for the assistant. Replies describe usable choices rather than scanner coordinates.
enum RoomFitCalculator {
    struct PlacementResult {
        let fits: Bool
        let summary: String
    }
    struct SimulationResult {
        let matched: Bool
        let identifier: String?
        let summary: String
        var measurementNote: String? = nil
        var toolSummary: String { summary + (measurementNote.map { " 참고 정보: " + $0 } ?? "") }
    }

    private struct Footprint {
        let object: RoomDataPayload.RoomObject
        let corners: [SIMD2<Float>]
        var center: SIMD2<Float> { corners.reduce(.zero, +) / 4 }
    }

    static func furnitureName(_ object: RoomDataPayload.RoomObject) -> String {
        if let name = object.displayName, !name.isEmpty { return name }
        switch object.category?.lowercased() {
        case "bed": return "침대"
        case "table", "desk": return "책상·테이블"
        case "chair": return "의자"
        case "sofa": return "소파"
        case "storage": return "수납장"
        case "television": return "TV"
        case "refrigerator": return "냉장고"
        case "washerdryer": return "세탁기"
        case "custom": return "추가 가구"
        default: return "가구"
        }
    }

    private static func footprint(_ object: RoomDataPayload.RoomObject,
                                  floorInverse: simd_float4x4) -> Footprint? {
        guard let transform = object.simdTransform, let dimensions = object.dimensions,
              dimensions.count >= 3, dimensions.allSatisfy({ $0.isFinite && $0 > 0 }),
              transform.columns.3.x.isFinite, transform.columns.3.y.isFinite,
              transform.columns.3.z.isFinite else { return nil }
        let corners = [SIMD2<Float>(-1, -1), [1, -1], [1, 1], [-1, 1]].map { sign -> SIMD2<Float> in
            let point = floorInverse * transform * SIMD4(sign.x * dimensions[0] / 2, 0,
                                                        sign.y * dimensions[2] / 2, 1)
            return SIMD2(point.x, point.y)
        }
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return Footprint(object: object, corners: corners)
    }

    private static func overlaps(_ first: [SIMD2<Float>], _ second: [SIMD2<Float>]) -> Bool {
        for polygon in [first, second] {
            for i in polygon.indices {
                let edge = polygon[(i + 1) % polygon.count] - polygon[i]
                guard length(edge) > 0.0001 else { continue }
                let axis = normalize(SIMD2(-edge.y, edge.x))
                let a = first.map { dot($0, axis) }, b = second.map { dot($0, axis) }
                if a.max()! <= b.min()! + 0.001 || b.max()! <= a.min()! + 0.001 { return false }
            }
        }
        return true
    }

    private static func floorGeometry(_ room: RoomDataPayload) -> (simd_float4x4, SIMD2<Float>)? {
        guard let floor = room.floors?.first, let transform = floor.simdTransform,
              floor.dimensions.count >= 2,
              floor.dimensions.prefix(2).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 30 }),
              transform.determinant.isFinite, abs(transform.determinant) > 0.0001 else { return nil }
        return (transform.inverse, SIMD2(floor.dimensions[0], floor.dimensions[1]) / 2)
    }

    static func suggestPlacement(in room: RoomDataPayload, widthCm: Double, depthCm: Double) -> PlacementResult {
        guard widthCm.isFinite, depthCm.isFinite, widthCm >= 3, depthCm >= 3,
              widthCm <= 500, depthCm <= 500 else {
            return PlacementResult(fits: false, summary: "놓으려는 가구의 가로와 깊이를 cm로 알려주세요. 두 치수가 있어야 자리가 있는지 확인할 수 있어요.")
        }
        guard let (inverse, halfFloor) = floorGeometry(room) else {
            return PlacementResult(fits: false, summary: "바닥 정보가 부족해서 놓을 자리를 확인하기 어려워요. 가구의 가로·깊이와 놓고 싶은 곳을 알려주시면 확인할 점부터 안내할게요.")
        }
        let obstacles = room.objects.compactMap { footprint($0, floorInverse: inverse) }
        guard obstacles.count == room.objects.count else {
            return PlacementResult(fits: false, summary: "일부 가구의 크기 정보가 빠져 있어 들어간다고 확답하기 어려워요. 놓고 싶은 자리의 빈 폭과 깊이를 먼저 확인해주세요.")
        }
        // Keep candidates away from detected door centres. Door swing and walking routes
        // cannot be proven from this floor-footprint check and are explicitly left to the user.
        let doors = (room.doors ?? []).compactMap { door -> SIMD2<Float>? in
            guard let transform = door.simdTransform else { return nil }
            let point = inverse * transform.columns.3
            return SIMD2(point.x, point.y)
        }
        let original = SIMD2(Float(widthCm / 200), Float(depthCm / 200))
        let orientations = original.x == original.y ? [original] : [original, SIMD2(original.y, original.x)]
        for (orientation, half) in orientations.enumerated() {
            guard half.x <= halfFloor.x, half.y <= halfFloor.y else { continue }
            let step = max(Float(0.1), max(halfFloor.x, halfFloor.y) / 30)
            var x = -halfFloor.x + half.x
            while x <= halfFloor.x - half.x + 0.001 {
                var y = -halfFloor.y + half.y
                while y <= halfFloor.y - half.y + 0.001 {
                    let center = SIMD2(x, y)
                    let corners = [center + SIMD2(-half.x, -half.y), center + SIMD2(half.x, -half.y),
                                   center + SIMD2(half.x, half.y), center + SIMD2(-half.x, half.y)]
                    let nearDoor = doors.contains { door in
                        let difference = door - center
                        let delta = SIMD2(abs(difference.x), abs(difference.y)) - half
                        return length(SIMD2(max(delta.x, 0), max(delta.y, 0))) < 0.6
                    }
                    if !nearDoor && !obstacles.contains(where: { overlaps(corners, $0.corners) }) {
                        let closest = obstacles.min { distance($0.center, center) < distance($1.center, center) }
                        let nearest = closest.flatMap { distance($0.center, center) < 2 ? $0 : nil }
                        let edgeDistance = min(halfFloor.x - abs(x) - half.x, halfFloor.y - abs(y) - half.y)
                        let location = nearest.map { "\(furnitureName($0.object)) 근처의 \(edgeDistance < 0.25 ? "방 가장자리 쪽" : "빈자리")" }
                            ?? "방 가장자리 쪽"
                        let rotation = orientation == 1 ? "가구를 옆으로 돌려 놓으면 " : ""
                        return PlacementResult(fits: true, summary: "\(rotation)\(location)에 놓을 후보 공간이 있어요. 가로 \(Int(widthCm)) × 깊이 \(Int(depthCm))cm 기준으로 기존 가구의 바닥 범위와 겹치지 않는 자리예요. 스캔 기준의 대략적인 확인이므로 문을 열고 지나다닐 여유는 실제로 확인해주세요. 화면의 가구를 옮긴 것은 아니에요.")
                    }
                    y += step
                }
                x += step
            }
        }
        return PlacementResult(fits: false, summary: "지금 배치에서는 가로 \(Int(widthCm)) × 깊이 \(Int(depthCm))cm 가구를 놓을 후보 자리를 찾지 못했어요. 더 작은 크기로 비교하거나, 덜 쓰는 가구 하나를 잠깐 숨긴 뒤 다시 확인해볼 수 있어요. 스캔 범위와 간격 단위로 찾은 결과라 불가능하다고 단정할 수는 없어요.")
    }

    private static let categoryKeywords: [(words: [String], categories: Set<String>)] = [
        (["책상", "테이블", "탁자"], ["table", "desk"]),
        (["의자"], ["chair"]), (["침대"], ["bed"]), (["소파", "쇼파"], ["sofa"]),
        (["옷장", "수납", "선반", "책장", "장롱"], ["storage"]),
        (["티비", "티브이", "텔레비전", "tv"], ["television"]), (["냉장고"], ["refrigerator"])
    ]

    static func simulateWithout(in room: RoomDataPayload, query: String) -> SimulationResult {
        let normalized = query.lowercased().replacingOccurrences(of: " ", with: "")
        let named = room.objects.filter { object in
            guard let name = object.displayName?.lowercased().replacingOccurrences(of: " ", with: ""), !name.isEmpty else { return false }
            return normalized.contains(name)
        }
        let categories = categoryKeywords.first { $0.words.contains(where: normalized.contains) }?.categories ?? []
        let candidates = named.isEmpty ? room.objects.filter { categories.contains($0.category?.lowercased() ?? "") } : named
        guard candidates.count == 1, let matched = candidates.first else {
            let message = candidates.count > 1
                ? "같은 종류의 가구가 여러 개 있어요. 이름을 붙여서 어떤 가구를 숨길지 알려주세요. 아직 화면은 바꾸지 않았어요."
                : "말씀하신 가구를 찾지 못했어요. 화면에 표시된 가구 이름으로 다시 알려주세요."
            return SimulationResult(matched: false, identifier: nil, summary: message)
        }
        let name = furnitureName(matched)
        let last = name.unicodeScalars.last?.value ?? 0
        let particle = (0xAC00...0xD7A3).contains(last) && (last - 0xAC00) % 28 != 0 ? "을" : "를"
        var summary = "\(name)\(particle) 잠깐 숨겼어요. 저장된 배치는 그대로예요."
        var measurement: String?
        if let d = matched.dimensions, d.count >= 3, d[0].isFinite, d[2].isFinite,
           d[0] > 0, d[2] > 0, d[0] <= 30, d[2] <= 30 {
            measurement = "가구 바닥 크기는 가로 약 \(Int(d[0] * 100)) × 깊이 \(Int(d[2] * 100))cm. 실제로 새로 확보되는 빈 면적과는 다름. 사용자가 크기를 물을 때만 안내."
        }
        if let (inverse, _) = floorGeometry(room), let target = footprint(matched, floorInverse: inverse),
           room.objects.filter({ $0.identifier != matched.identifier }).compactMap({ footprint($0, floorInverse: inverse) })
            .contains(where: { overlaps(target.corners, $0.corners) }) {
            summary += " 다른 가구와 겹친 부분이 있어서 이 크기 전체가 새 빈자리가 되는 건 아니에요."
        } else {
            summary += " 비워둔 자리의 모습이 더 편한지 화면에서 비교해보세요."
        }
        return SimulationResult(matched: true, identifier: matched.identifier, summary: summary, measurementNote: measurement)
    }

    static func reviewLayout(in room: RoomDataPayload) -> String {
        guard !room.objects.isEmpty else { return "현재 불러온 배치에 가구 정보가 없어요. 실제 배치를 판단하지 말고 사용자의 목적과 놓고 싶은 가구를 먼저 물어보세요." }
        let inventory = Dictionary(grouping: room.objects, by: furnitureName)
            .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.count)개" }.joined(separator: ", ")
        var facts = "현재 배치에서 확인된 가구: \(inventory)."
        if let (inverse, _) = floorGeometry(room) {
            let objects = room.objects.compactMap { footprint($0, floorInverse: inverse) }
            let nearDoors = (room.doors ?? []).flatMap { door -> [String] in
                guard let transform = door.simdTransform else { return [] }
                let point = inverse * transform.columns.3
                return objects.filter { footprint in
                    let xs = footprint.corners.map(\.x), ys = footprint.corners.map(\.y)
                    let dx = max(xs.min()! - point.x, point.x - xs.max()!, 0)
                    let dy = max(ys.min()! - point.y, point.y - ys.max()!, 0)
                    return sqrt(dx * dx + dy * dy) < 0.6
                }.map { furnitureName($0.object) }
            }
            if !nearDoors.isEmpty {
                facts += " 문 가까이에 있는 가구: \(Set(nearDoors).sorted().joined(separator: ", ")). 실제 문 여닫기와 통행에 불편한지는 확인이 필요하며 막혔다고 단정하면 안 돼요."
            }
        }
        return facts + " 통로 폭, 문이 열리는 방향, 서랍 여닫는 범위, 채광은 이 정보만으로 판정할 수 없어요. 사용자가 원하는 변화에 맞춰 위 가구 중 확인할 대상 하나와 실행할 다음 단계 하나를 제안하세요. 가구를 더 넣는 질문에는 가로·깊이를 확인하고 suggest_placement로 검증하세요. 화면을 자동으로 옮겼다고 말하지 마세요."
    }
}
