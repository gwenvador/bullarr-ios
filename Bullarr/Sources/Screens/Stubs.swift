import SwiftUI

// Écran volontairement en stub : l'upscaling natif (ncnn/Vulkan) n'est pas porté sur iOS.

struct UpscalingScreen: View {
    @Environment(\.bullColors) private var cs
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Upscaling des pages").font(.title3.bold())
                Text("L'amélioration des pages basse définition (Real-CUGAN/Real-ESRGAN) n'est pas disponible dans cette version iOS.")
                    .foregroundColor(cs.muted)
            }
            .padding(16)
        }
    }
}
