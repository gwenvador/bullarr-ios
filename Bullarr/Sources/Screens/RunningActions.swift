import SwiftUI

/// Actions en cours (suppression, scan, déplacement…) : un bandeau au-dessus de la barre du bas
/// les liste tant qu'elles tournent, pour savoir ce qui se passe avant le message de fin.
/// Portage direct de RunningActions (ItemActions.kt, Android 1.10).
@MainActor
final class RunningActions: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: Int
        let label: String
        let startedAt: Date
    }

    static let shared = RunningActions()

    @Published private(set) var items: [Item] = []
    private var next = 0

    func start(_ label: String) -> Int {
        next += 1
        items.append(Item(id: next, label: label, startedAt: Date()))
        return next
    }

    func end(_ id: Int) {
        items.removeAll { $0.id == id }
    }

    /// Exécute le bloc en l'affichant dans le bandeau.
    func track<T>(_ label: String, _ block: () async throws -> T) async throws -> T {
        let id = start(label)
        defer { end(id) }
        return try await block()
    }
}

/// Bandeau des actions en cours ; une action n'y apparaît qu'au-delà d'une demi-seconde (pas de clignotement).
struct RunningActionsBanner: View {
    @ObservedObject private var actions = RunningActions.shared
    @Environment(\.bullColors) private var cs
    // Horloge : se met à jour tant qu'une action tourne, pour faire apparaître celles qui durent.
    @State private var now = Date()

    private var visible: [RunningActions.Item] {
        actions.items.filter { now.timeIntervalSince($0.startedAt) >= 0.5 }
    }

    var body: some View {
        Group {
            if !visible.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visible) { item in
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.mini).tint(cs.accent)
                            Text("\(item.label)…")
                                .font(.subheadline)
                                .foregroundColor(cs.text)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(cs.secondaryContainer))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .task(id: actions.items.isEmpty) {
            while !actions.items.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                now = Date()
            }
        }
    }
}
