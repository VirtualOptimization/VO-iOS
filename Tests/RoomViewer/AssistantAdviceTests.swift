import Foundation
import simd

@main
struct AssistantAdviceTests {
    static func object(_ id: String, category: String, name: String? = nil,
                       dimensions: [Double]? = [0.8, 0.7, 0.6], yaw: Double = 0) -> [String: Any] {
        var item: [String: Any] = [
            "identifier": id, "category": category,
            "transform": [[cos(yaw), 0, -sin(yaw), 0], [0, 1, 0, 0],
                          [sin(yaw), 0, cos(yaw), 0], [0, 0.35, 0, 1]]
        ]
        item["display_name"] = name
        item["dimensions"] = dimensions
        return item
    }

    static func room(_ objects: [[String: Any]], width: Double = 2, depth: Double = 2,
                     door: Bool = false) throws -> RoomDataPayload {
        let floor: [String: Any] = ["center": [0, 0, 0], "dimensions": [width, depth],
            "transform": [[1, 0, 0, 0], [0, 0, -1, 0], [0, 1, 0, 0], [0, 0, 0, 1]]]
        let entry: [String: Any] = ["center": [0, 0, 0], "dimensions": [0.8, 2],
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 1, 0, 1]]]
        return try JSONDecoder().decode(RoomDataPayload.self, from: JSONSerialization.data(withJSONObject: [
            "objects": objects, "floors": [floor], "doors": door ? [entry] : []
        ]))
    }

    static func main() throws {
        let furnished = try room([object("table", category: "table")])
        let placement = RoomFitCalculator.suggestPlacement(in: furnished, widthCm: 40, depthCm: 40)
        precondition(placement.fits && placement.summary.contains("책상·테이블 근처"))
        precondition(!placement.summary.contains("방 중심") && !placement.summary.contains("지점"))
        precondition(placement.summary.contains("확인"), "A floor fit must not promise safe circulation")

        let narrow = try room([], width: 1, depth: 2)
        let rotated = RoomFitCalculator.suggestPlacement(in: narrow, widthCm: 180, depthCm: 80)
        precondition(rotated.fits && rotated.summary.contains("돌려"))
        let invalid = RoomFitCalculator.suggestPlacement(in: narrow, widthCm: .infinity, depthCm: 50)
        precondition(!invalid.fits && invalid.summary.contains("가로와 깊이"))
        let unknownSize = try room([object("unknown", category: "storage", dimensions: nil)])
        precondition(!RoomFitCalculator.suggestPlacement(in: unknownSize, widthCm: 40, depthCm: 40).fits)

        let blocked = try room([object("bed", category: "bed", dimensions: [2, 0.7, 2], yaw: .pi / 2)])
        precondition(!RoomFitCalculator.suggestPlacement(in: blocked, widthCm: 80, depthCm: 60).fits)
        let emptied = RoomDataPayload(objects: [], walls: blocked.walls, floors: blocked.floors,
                                      doors: blocked.doors, windows: blocked.windows)
        precondition(RoomFitCalculator.suggestPlacement(in: emptied, widthCm: 80, depthCm: 60).fits)
        let entry = try room([], width: 1, depth: 1, door: true)
        precondition(!RoomFitCalculator.suggestPlacement(in: entry, widthCm: 30, depthCm: 30).fits)

        let duplicates = try room([object("a", category: "table"), object("b", category: "table")])
        let ambiguous = RoomFitCalculator.simulateWithout(in: duplicates, query: "책상 숨겨줘")
        precondition(!ambiguous.matched && ambiguous.identifier == nil)
        let named = try room([object("custom", category: "custom", name: "내 책장")])
        let hidden = RoomFitCalculator.simulateWithout(in: named, query: "내 책장 숨겨줘")
        precondition(hidden.matched && hidden.identifier == "custom")
        precondition(!hidden.summary.contains("㎡") && !hidden.summary.contains("%"))
        precondition(hidden.toolSummary.contains("크기"))
        let sofa = try room([object("sofa", category: "sofa")])
        precondition(RoomFitCalculator.simulateWithout(in: sofa, query: "소파 빼줘").summary.contains("소파를"))
        let nested = try room([object("chair", category: "chair"), object("table", category: "table")])
        precondition(RoomFitCalculator.simulateWithout(in: nested, query: "의자 빼줘").summary.contains("전체가 새 빈자리"))
        precondition(RoomFitCalculator.reviewLayout(in: named).contains("내 책장 1개"))

        precondition(FurnitureChatCommand.classify("책상 빼줘") == .hide)
        precondition(FurnitureChatCommand.classify("원래대로 돌려줘") == .restore)
        for question in ["책상 빼지 마", "책상을 빼면 소파가 들어갈까?", "책장을 빼는 게 나을까?", "책상은 빼지 않아도 될까?"] {
            precondition(FurnitureChatCommand.classify(question) == .none, "Do not silently hide furniture: \(question)")
        }
        print("PASS: landmark advice without scanner coordinates, rotated fit, missing sizes, door caution, hidden-layout recalculation, named/ambiguous furniture, non-inflated space claims, negated and compound requests")
    }
}
