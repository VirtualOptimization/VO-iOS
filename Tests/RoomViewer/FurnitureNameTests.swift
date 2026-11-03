import Foundation
import simd

@main
struct FurnitureNameTests {
    static func main() throws {
        let draft = MeasuredFurnitureDraft(dimensions: [1, 1, 1], colorHex: "#B8875A", displayName: "  내 책장  ")
        precondition(draft.displayName == "내 책장")
        precondition(MeasuredFurnitureDraft(dimensions: [1, 1, 1], colorHex: "#FFFFFF", displayName: " \n").displayName == "추가 가구")
        precondition(MeasuredFurnitureDraft(dimensions: [1, 1, 1], colorHex: "#FFFFFF", displayName: String(repeating: "가", count: 40)).displayName.count == 30)
        let edit = FurniturePoseEdit(identifier: draft.id, center: [0, 0.5, 0], rotation: [0, 0, 0],
                                     dimensions: [1, 1, 1], category: "custom", colorHex: draft.colorHex,
                                     operation: "create", displayName: draft.displayName)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as! [String: Any]
        precondition(encoded["display_name"] as? String == "내 책장")
        precondition(encoded["operation"] as? String == "create", "A named new item must remain a create operation")

        var object: [String: Any] = ["identifier": draft.id, "category": "custom", "display_name": "내 책장",
                                   "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]]
        func decode(_ object: [String: Any]) throws -> RoomDataPayload.RoomObject {
            try JSONDecoder().decode(RoomDataPayload.RoomObject.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let named = try decode(object)
        precondition(named.displayName == "내 책장")
        object.removeValue(forKey: "display_name")
        let legacy = try decode(object)
        precondition(legacy.displayName == nil, "Legacy furniture must still load")
        print("PASS: custom furniture names, whitespace/default/length, create payload metadata, saved-name decoding and legacy compatibility")
    }
}
