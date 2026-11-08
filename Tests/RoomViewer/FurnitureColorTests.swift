import Foundation
import simd

@main
struct FurnitureColorTests {
    static func object(_ fields: [String: Any] = [:]) throws -> RoomDataPayload.RoomObject {
        let defaults: [String: Any] = ["identifier": "chair-1", "category": "chair",
            "dimensions": [0.5, 0.8, 0.5],
            "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0.4, 0, 1]]]
        return try JSONDecoder().decode(RoomDataPayload.RoomObject.self,
            from: JSONSerialization.data(withJSONObject: defaults.merging(fields, uniquingKeysWith: { _, new in new })))
    }

    static func detail(displayColor: String) throws -> RoomVersionDetail {
        let data: [String: Any] = ["layout_json_url": "https://example.com/same-layout.json",
            "ios_objects": [["identifier": "chair-1", "category": "chair", "display_color_hex": displayColor,
                "transform": [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0.4, 0, 1]]]]]
        return try JSONDecoder().decode(RoomVersionDetail.self, from: JSONSerialization.data(withJSONObject: data))
    }

    static func main() throws {
        let serverColor = try object(["display_color_hex": "#aabbcc"])
        precondition(FurnitureDisplayColor.resolvedHex(for: serverColor) == "#AABBCC",
                     "The saved server display-color field must not be discarded")
        let measuredBefore = try object(["identifier": "lidar_test", "category": "custom", "color_hex": "#B8875A"])
        let measuredAfter = try object(["identifier": "lidar_test", "category": "custom", "source": "lidar_obb",
                                        "color_hex": "#B8875A", "display_color_hex": "#CCC7BF"])
        precondition(FurnitureDisplayColor.resolvedHex(for: measuredBefore) == FurnitureDisplayColor.resolvedHex(for: measuredAfter),
                     "Saving must not replace the user's chosen color with the server's generic custom color")
        precondition(measuredBefore.isMeasuredFurniture && measuredAfter.isMeasuredFurniture)
        let legacy = try object(["display_color": "#123456"])
        precondition(FurnitureDisplayColor.resolvedHex(for: legacy) == "#123456")

        let stale = try object()
        let fresh = try object(["display_color_hex": "#112233"])
        precondition(FurnitureDisplayColor.resolvedHex(for: stale, fresh: fresh) == "#112233",
                     "Inline response color must reach the fallback renderer even if the static JSON is old")
        precondition(FurnitureDisplayColor.resolvedHex(for: measuredBefore, fresh: fresh) == "#B8875A",
                     "A display fallback must not override an explicit user choice")
        let invalid = try object(["color_hex": "bad", "display_color_hex": "#abcdef"])
        precondition(FurnitureDisplayColor.resolvedHex(for: invalid) == "#ABCDEF")
        precondition(FurnitureDisplayColor.defaultHex(category: "bed") == "#F2CCD4")
        precondition(FurnitureDisplayColor.defaultHex(category: "storage") == "#C7D1C2")

        let photoModel = try object(["identifier": "photo-model", "category": "custom", "source": "photo"])
        precondition(!photoModel.isMeasuredFurniture, "Authored custom/photo meshes must not become measured boxes")
        let oldIDMeasured = try object(["identifier": "uuid", "source": "lidar_obb"])
        precondition(oldIDMeasured.isMeasuredFurniture)
        let first = try detail(displayColor: "#112233")
        let second = try detail(displayColor: "#445566")
        precondition(first.renderingID != second.renderingID, "Changed colors require a scene refresh even with unchanged URLs")
        print("PASS: saved display colors, custom-color priority, static/inline metadata, legacy/invalid colors, stable palette, measured-box identity, authored-model preservation and color refresh identity")
    }
}
