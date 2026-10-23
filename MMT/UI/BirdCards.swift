import SwiftUI
import MMTCore

/// Wikipedia photo for a species, loaded lazily.
struct BirdPhoto: View {
    let species: BirdSpecies
    @State private var url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "bird").font(.title2).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: species.scientificName) {
            url = await BirdImageService.shared.thumbnail(forScientificName: species.scientificName)
        }
    }
}

/// Full-screen choice shown when more than one species has been heard.
struct BirdGridView: View {
    let sightings: [BirdSighting]
    let onPick: (BirdSighting) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(sightings.count) birds heard")
                    .font(.title2.bold())
                Text("Pick one and the arrow will point to where it was singing.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(sightings) { sighting in
                        Button { onPick(sighting) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                BirdPhoto(species: sighting.species)
                                    .frame(height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(sighting.species.commonName)
                                    .font(.headline).lineLimit(2)
                                Text(sighting.species.scientificName)
                                    .font(.caption).italic().foregroundStyle(.secondary)
                                Text("\(Int(sighting.bestScore * 100))% · \(sighting.lastHeard, format: .relative(presentation: .named))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Photos: Wikipedia · Identification: BirdNET")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .background(.regularMaterial)
    }
}

/// Compact strip of heard birds shown over the camera once one is picked.
struct BirdStrip: View {
    let sightings: [BirdSighting]
    let selected: Int?
    let onPick: (BirdSighting) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sightings) { sighting in
                    Button { onPick(sighting) } label: {
                        HStack(spacing: 8) {
                            BirdPhoto(species: sighting.species)
                                .frame(width: 36, height: 36)
                                .clipShape(Circle())
                            Text(sighting.species.commonName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4)
                        .background(sighting.id == selected ? AnyShapeStyle(.yellow.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial),
                                    in: Capsule())
                        .foregroundStyle(sighting.id == selected ? .black : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}
