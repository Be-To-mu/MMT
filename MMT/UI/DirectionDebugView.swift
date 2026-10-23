import SwiftUI
import simd
import MMTCore

/// Debug screen: proves FOA capture works and points a 3D arrow at the last loud sound
/// (clap test / axis calibration). The arrow pivots about the centre and can point into
/// or out of the screen, so front/back and up/down are visible whichever way the phone is held.
struct DirectionDebugView: View {
    let tracker: DirectionTracker

    var body: some View {
        VStack(spacing: 24) {
            if let error = tracker.error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            levelMeters

            ZStack {
                Circle().stroke(.secondary.opacity(0.3), lineWidth: 2)
                Arrow3DView(direction: deviceDirection)
                if deviceDirection == nil {
                    Text("Clap or make a sound").foregroundStyle(.secondary)
                }
            }
            .frame(width: 300, height: 300)

            if let est = tracker.lastEstimate, let bearing = tracker.targetBearing,
               let elevation = tracker.targetElevation {
                VStack {
                    Text(String(format: "Device az %.0f°  el %.0f°", est.azimuth, est.elevation))
                    Text(String(format: "Bearing %.0f°  %.0f° %@  spread %.0f°  conf %.2f",
                                bearing, abs(elevation), elevation >= 0 ? "up" : "down",
                                est.spread, est.confidence))
                }
                .font(.footnote.monospaced())
            }
        }
        .padding()
    }

    /// Target in the device frame (x right edge, y top edge, z out of the screen),
    /// recomputed as the phone moves so the arrow stays on the sound.
    private var deviceDirection: SIMD3<Float>? {
        guard let target = tracker.targetWorld else { return nil }
        let d = tracker.heading.deviceToWorld.transpose * target
        return SIMD3(Float(d.x), Float(d.y), Float(d.z))
    }

    private var levelMeters: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(Array(zip(["W", "Y", "Z", "X"], tracker.levels)), id: \.0) { name, level in
                VStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.tint)
                        .frame(width: 28, height: CGFloat(min(1, level * 8)) * 100 + 2)
                    Text(name).font(.caption.monospaced())
                }
            }
        }
        .frame(height: 130, alignment: .bottom)
    }
}
