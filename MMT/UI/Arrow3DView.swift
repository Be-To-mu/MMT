import Combine
import RealityKit
import SwiftUI

/// A 3D arrow pivoting about the centre of the view. `direction` is in the device frame
/// (x right edge, y top edge, z out of the screen), which matches RealityKit's axes for
/// a camera looking into the screen, so the arrow can point anywhere: up, down, left,
/// right, into the screen (away from you) or out of it (towards you).
struct Arrow3DView: UIViewRepresentable {
    var direction: SIMD3<Float>?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.clear)
        view.backgroundColor = .clear
        context.coordinator.install(in: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.direction = direction
    }

    @MainActor
    final class Coordinator {
        var direction: SIMD3<Float>?
        private let arrow = ArrowEntity.make()
        private var updates: (any Cancellable)?

        func install(in view: ARView) {
            let root = AnchorEntity(world: .zero)
            arrow.scale = SIMD3(repeating: 3)
            arrow.isEnabled = false
            root.addChild(arrow)

            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 40
            camera.position = [0, 0, 1.6]
            root.addChild(camera)

            let light = DirectionalLight()
            light.light.intensity = 3000
            light.look(at: .zero, from: [0.5, 1, 1.5], relativeTo: nil)
            root.addChild(light)

            view.scene.addAnchor(root)
            updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                self?.update(dt: Float(event.deltaTime))
            }
        }

        private func update(dt: Float) {
            guard let direction, simd_length(direction) > 0 else {
                arrow.isEnabled = false
                return
            }
            let wanted = simd_quatf(from: [0, 0, -1], to: simd_normalize(direction))
            if !arrow.isEnabled {
                arrow.orientation = wanted
                arrow.isEnabled = true
            }
            arrow.orientation = simd_slerp(arrow.orientation, wanted, min(1, dt * 10))
        }
    }
}
