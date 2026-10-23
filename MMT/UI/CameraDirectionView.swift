import AVFoundation
import SwiftUI
import simd
import MMTCore

/// Live camera with a 3D arrow at the centre of the screen pointing towards the picked
/// bird. The bird's distance is unknown, so only the phone's orientation matters: the
/// arrow is steered by CoreMotion, not by ARKit, which lets any lens be used.
///
/// When several species have been heard and none is picked yet, a grid of the birds with
/// photos is shown first.
struct CameraDirectionView: View {
    let tracker: DirectionTracker

    private var selected: BirdSighting? { tracker.selectedSighting }
    private var needsPick: Bool { selected == nil && tracker.sightings.count > 1 }

    /// The picked bird's direction in the device frame (x right edge, y top edge, z out
    /// of the screen); the back camera looks along -z.
    private var deviceDirection: SIMD3<Float>? {
        guard let world = selected?.worldVector else { return nil }
        let d = tracker.heading.deviceToWorld.transpose * world
        return SIMD3(Float(d.x), Float(d.y), Float(d.z))
    }

    var body: some View {
        ZStack {
            CameraPreview(session: tracker.captureSession)
                .ignoresSafeArea()
            Arrow3DView(direction: deviceDirection)
                .frame(width: 320, height: 320)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if !tracker.sightings.isEmpty && !needsPick {
                BirdStrip(sightings: tracker.sightings, selected: tracker.selectedSpeciesIndex) {
                    tracker.selectedSpeciesIndex = $0.id
                }
                .padding(.top, 8)
            }
        }
        .overlay(alignment: .bottom) {
            if !needsPick {
                VStack(spacing: 12) {
                    lensPicker
                    hud
                }
                .padding(.bottom, 24)
            }
        }
        .overlay {
            if needsPick {
                BirdGridView(sightings: tracker.sightings) { tracker.selectedSpeciesIndex = $0.id }
                    .transition(.opacity)
            }
        }
        .animation(.default, value: needsPick)
    }

    @ViewBuilder private var lensPicker: some View {
        if tracker.lenses.count > 1 {
            HStack(spacing: 6) {
                ForEach(tracker.lenses) { lens in
                    let isCurrent = lens == tracker.currentLens
                    Button { tracker.select(lens) } label: {
                        Text(lens.label)
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 40, height: 40)
                            .background(isCurrent ? AnyShapeStyle(.yellow.opacity(0.9)) : AnyShapeStyle(.black.opacity(0.35)),
                                        in: Circle())
                            .foregroundStyle(isCurrent ? .black : .white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(.ultraThinMaterial, in: Capsule())
        }
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
    }

    private func compassName(_ bearing: Double) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int((bearing + 22.5) / 45) % 8]
    }
}

/// Full-screen camera preview for the shared capture session, in portrait.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
