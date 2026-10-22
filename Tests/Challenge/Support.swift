import Foundation

// Minimal shared-view types let the real networking and state machine compile
// and run on macOS without constructing RealityKit or an iOS simulator.
struct RoomVersionDetail: Decodable {
    let dataUrl: String?
    var effectiveDataUrl: String? { dataUrl }
}
struct FurniturePoseEdit {
    let identifier: String
    let center: [Float]
    let rotation: [Float]
}
