import ARKit
import Combine
import RealityKit
import SwiftUI
import MMTCore

/// Camera view with the picked bird's direction drawn into the scene: a marker floating
/// out in the world where it was heard, and a 3D arrow just in front of the camera that
/// swings towards it. ARKit's `.gravityAndHeading` alignment puts true north on -z, so a
/// compass bearing maps straight into the AR scene.
///
/// When several species have been heard and none is picked yet, a grid of the birds with
/// photos is shown first.
struct ARDirectionView: View {
    @Bindable var tracker: DirectionTracker

    private var selected: BirdSighting? { tracker.selectedSighting }
    private var needsPick: Bool { selected == nil && tracker.sightings.count > 1 }

    var body: some View {
        ARSceneView(target: selected?.worldVector, label: selected?.species.commonName)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                if !tracker.sightings.isEmpty && !needsPick {
                    BirdStrip(sightings: tracker.sightings, selected: tracker.selectedSpeciesIndex) {
                        tracker.selectedSpeciesIndex = $0.id
                    }
                    .padding(.top, 8)
                }
            }
            .overlay(alignment: .bottom) { if !needsPick { hud } }
            .overlay {
                if needsPick {
                    BirdGridView(sightings: tracker.sightings) { tracker.selectedSpeciesIndex = $0.id }
                        .transition(.opacity)
                }
            }
            .animation(.default, value: needsPick)
    }

    private var hud: some View {
        Group {
            if let error = tracker.error {
                Text(error)
            } else if let selected, let world = selected.worldVector {
                let bearing = SpatialGeometry.compassBearing(world)
                let elevation = SpatialGeometry.elevation(world)
                VStack(spacing: 2) {
                    Text(selected.species.commonName).font(.headline)
                    Text(String(format: "%@ %.0f°  ·  %.0f° %@", compassName(bearing), bearing,
                                abs(elevation), elevation >= 0 ? "up" : "down"))
                        .monospacedDigit()
                    Text("heard \(selected.lastHeard, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let selected {
                Text("\(selected.species.commonName): direction unclear, waiting for it to sing again")
            } else {
                Text("Listening for birds…")
            }
        }
        .font(.callout.weight(.medium))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func compassName(_ bearing: Double) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((bearing + 22.5) / 45) % 8]
    }
}

private struct ARSceneView: UIViewRepresentable {
    /// World vector (x north, y west, z up), or nil when nothing has been heard yet.
    var target: SIMD3<Double>?
    var label: String?

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
        context.coordinator.setLabel(label ?? "Bird")
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        view.session.pause()
    }

    @MainActor
    final class Coordinator {
        var targetPosition: SIMD3<Float>?

        private let marker = Entity()
        private let arrow = Entity()
        private let billboard = Entity()
        private var label: ModelEntity?
        private var labelText = ""
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
            billboard.components.set(BillboardComponent())
            billboard.addChild(ring)
            setLabel("Bird")

            marker.addChild(core)
            marker.addChild(billboard)
        }

        /// Shows `text` above the marker, always facing the camera.
        func setLabel(_ text: String) {
            guard text != labelText else { return }
            labelText = text
            label?.removeFromParent()
            let entity = ModelEntity(mesh: .generateText(text, extrusionDepth: 0.01,
                                                         font: .systemFont(ofSize: 0.3, weight: .bold),
                                                         alignment: .center),
                                     materials: [UnlitMaterial(color: .white)])
            let bounds = entity.visualBounds(relativeTo: nil)
            entity.position = [-bounds.center.x, 0.55, 0]
            billboard.addChild(entity)
            label = entity
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
