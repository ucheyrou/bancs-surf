import SwiftUI

/// Onglet unique regroupant webcams, liste des spots et scènes Sentinel-2 (5 onglets max sur iPhone).
struct SpotsEtScenesView: View {
    enum Vue: String, CaseIterable { case webcams = "Webcams", spots = "Spots", scenes = "Scènes" }
    @State private var vue: Vue = .webcams
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $vue) { ForEach(Vue.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal).padding(.top, 8).padding(.bottom, 4)
                .background(Color.fond)
            switch vue {
            case .webcams: WebcamsView()
            case .spots: SpotsView()
            case .scenes: ScenesView()
            }
        }
        .background(Color.fond)
    }
}
