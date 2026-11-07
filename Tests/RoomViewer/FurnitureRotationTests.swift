import Foundation
import simd

@main
struct FurnitureRotationTests {
    static func main() throws {
        func close(_ first: Float, _ second: Float) -> Bool { abs(first - second) < 0.0001 }
        for angle: Float in [0, .pi / 6, -.pi / 4, .pi / 2] {
            var floor = matrix_identity_float4x4
            // A floor's width axis in room coordinates, including a rotated scan origin.
            floor.columns.0 = SIMD4(cos(angle), 0, sin(angle), 0)
            let initial = FurniturePlacementRotation.initialOrientation(floorTransform: floor)
            let widthAxis = initial.act(SIMD3<Float>(1, 0, 0))
            precondition(close(widthAxis.x, cos(angle)) && close(widthAxis.z, sin(angle)),
                         "New furniture must align with the room floor, not the world origin")
            let yaw = FurniturePlacementRotation.serverYaw(of: initial)
            precondition(close(yaw, angle), "The API yaw must use RoomPlan's sign and radians")
            let pose = FurniturePoseEdit(identifier: "lidar-test", center: [0, 0.5, 0],
                                         rotation: [0, yaw, 0], dimensions: [1, 1, 1], operation: "create")
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pose)) as! [String: Any]
            let rotation = encoded["rotation"] as! [NSNumber]
            precondition(close(rotation[1].floatValue, angle))
        }

        // Explicit user rotation to zero must stay zero even in a rotated room.
        let userOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        let userPose = FurniturePoseEdit(identifier: "lidar-test", center: [0, 0.5, 0],
                                         rotation: [0, FurniturePlacementRotation.serverYaw(of: userOrientation), 0],
                                         dimensions: [1, 1, 1], operation: "create")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(userPose)) as! [String: Any]
        precondition((encoded["rotation"] as! [NSNumber]).map(\.floatValue) == [0, 0, 0],
                     "An intentional 0° must be sent explicitly and never replaced by a default")
        let fallback = FurniturePlacementRotation.initialOrientation(floorTransform: nil)
        precondition(close(FurniturePlacementRotation.serverYaw(of: fallback), 0))
        var invalid = matrix_identity_float4x4
        invalid.columns.0 = .zero
        precondition(close(FurniturePlacementRotation.serverYaw(of:
            FurniturePlacementRotation.initialOrientation(floorTransform: invalid)), 0))
        print("PASS: floor-aligned new furniture, positive/negative rotations, radians/sign, explicit user zero, missing-floor fallback")
    }
}
