import RealityKit
import UIKit

/// A 3D arrow centred on its own origin and pointing along -z, so it can swing freely
/// about its middle: `orientation = simd_quatf(from: [0, 0, -1], to: direction)`.
@MainActor
enum ArrowEntity {
    static let length: Float = 0.2

    static func make() -> Entity {
        let arrow = Entity()
        let body = SimpleMaterial(color: .systemYellow, roughness: 0.3, isMetallic: false)
        let tail = SimpleMaterial(color: .systemOrange, roughness: 0.5, isMetallic: false)

        let headLength = length * 0.35
        let shaftLength = length - headLength
        // Shaft runs from +length/2 (tail) towards the head; cylinders and cones are built along +y.
        let shaft = ModelEntity(mesh: .generateCylinder(height: shaftLength, radius: length * 0.06),
                                materials: [body])
        shaft.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        shaft.position = [0, 0, length / 2 - shaftLength / 2]

        let head = ModelEntity(mesh: .generateCone(height: headLength, radius: length * 0.16),
                               materials: [body])
        head.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        head.position = [0, 0, -length / 2 + headLength / 2]

        // A darker tail cap, so you can tell "pointing at me" from "pointing away".
        let cap = ModelEntity(mesh: .generateSphere(radius: length * 0.09), materials: [tail])
        cap.position = [0, 0, length / 2]

        arrow.addChild(shaft)
        arrow.addChild(head)
        arrow.addChild(cap)
        return arrow
    }
}
