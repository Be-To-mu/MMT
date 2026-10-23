import ARKit
import Combine
import RealityKit
import SwiftUI
import MMTCore

/// Camera view with the sound's direction drawn into the scene: a marker floating out in
/// the world where the sound came from, and a 3D arrow just in front of the camera that
/// swings towards it. ARKit's `.gravityAndHeading` alignment puts true north on -z, so a
/// compass bearing maps straight into the AR scene.
struct ARDirectionView: View {
    let tracker: DirectionTracker

    var body: some View {
        ARSceneView(target: tracker.targetWorld)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { hud }
    }

    private var hud: some View {
        Group {
            if let error = tracker.error {
                Text(error)
            } else if let bearing = tracker.targetBearing, let elevation = tracker.targetElevation {
                Text(String(format: "%@ %.0f°  ·  %.0f° %@", compassName(bearing), bearing,
                            abs(elevation), elevation >= 0 ? "up" : "down"))
                    .monospacedDigit()
            } else {
                Text("Listening… the arrow appears when a sound is heard")
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 24)
    }

    private func compassName(_ bearing: Double) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((bearing + 22.5) / 45) % 8]
    }
}

private struct ARSceneView: UIViewRepresentable {
    /// World vector (x north, y west, z up), or nil when nothing has been heard yet.
    var target: SIMD3<Double>?

    /// Distance is unknown from one phone, so the marker sits at a fixed range along the bearing.
    static let markerDistance = 12.0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        // Audio comes from our own FOA capture session, not ARKit.
        config.providesAudioData = false
        view.session.run(config)
        context.coordinator.install(in: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.targetPosition = target.map {
            SpatialGeometry.arPosition(world: $0, distance: Self.markerDistance)
        }
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        view.session.pause()
    }

    @MainActor
    final class Coordinator {
        var targetPosition: SIMD3<Float>?

        private let marker = Entity()
        private let arrow = Entity()
        private var updates: (any Cancellable)?
        private var time: Float = 0

        func install(in view: ARView) {
            let world = AnchorEntity(world: .zero)
            buildMarker()
            buildArrow()
            world.addChild(marker)
            world.addChild(arrow)
            marker.isEnabled = false
            arrow.isEnabled = false
            view.scene.addAnchor(world)

            updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self, weak view] event in
                guard let self, let view else { return }
                self.update(camera: view.cameraTransform, dt: Float(event.deltaTime))
            }
        }

        private func update(camera: Transform, dt: Float) {
            guard let target = targetPosition else {
                marker.isEnabled = false
                arrow.isEnabled = false
                return
            }
            time += dt
            marker.isEnabled = true
            arrow.isEnabled = true

            // Marker: out in the world along the bearing, centred on the user, gently pulsing.
            let markerPos = camera.translation + target
            marker.position = simd_mix(marker.position, markerPos, SIMD3(repeating: min(1, dt * 4)))
            marker.scale = SIMD3(repeating: 1 + 0.12 * sin(time * 4))

            // Arrow: fixed in front of the camera, slightly low, pointing at the marker.
            let anchorPoint = camera.matrix * SIMD4<Float>(0, -0.12, -0.6, 1)
            arrow.position = SIMD3(anchorPoint.x, anchorPoint.y, anchorPoint.z)
            let direction = simd_normalize(marker.position - arrow.position)
            let wanted = simd_quatf(from: SIMD3(0, 0, -1), to: direction)
            arrow.orientation = simd_slerp(arrow.orientation, wanted, min(1, dt * 8))
        }

        private func buildMarker() {
            let glow = UnlitMaterial(color: .systemYellow)
            let core = ModelEntity(mesh: .generateSphere(radius: 0.35), materials: [glow])
            let ring = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 0.8),
                                   materials: [UnlitMaterial(color: .systemYellow.withAlphaComponent(0.35))])
            // Face the ring towards the user.
            ring.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            let billboard = Entity()
            billboard.components.set(BillboardComponent())
            billboard.addChild(ring)

            let label = ModelEntity(mesh: .generateText("Sound", extrusionDepth: 0.01,
                                                        font: .systemFont(ofSize: 0.3, weight: .bold),
                                                        alignment: .center),
                                    materials: [UnlitMaterial(color: .white)])
            let bounds = label.visualBounds(relativeTo: nil)
            label.position = [-bounds.extents.x / 2, 0.55, 0]
            billboard.addChild(label)

            marker.addChild(core)
            marker.addChild(billboard)
        }

        private func buildArrow() {
            // Built along -z so orienting it is a single rotation from (0, 0, -1).
            let material = SimpleMaterial(color: .systemYellow, roughness: 0.3, isMetallic: false)
            let shaft = ModelEntity(mesh: .generateCylinder(height: 0.14, radius: 0.012),
                                    materials: [material])
            shaft.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            shaft.position = [0, 0, -0.03]
            let head = ModelEntity(mesh: .generateCone(height: 0.06, radius: 0.03),
                                   materials: [material])
            head.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            head.position = [0, 0, -0.13]
            arrow.addChild(shaft)
            arrow.addChild(head)
        }
    }
}
