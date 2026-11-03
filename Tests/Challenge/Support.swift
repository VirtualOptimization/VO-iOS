import Foundation

// Editing payload used by the real networking/state-machine tests without RealityKit.
// Room layout models are extracted from the production source by the test script.
struct FurniturePoseEdit {
    let identifier: String
    let center: [Float]
    let rotation: [Float]
}
