import SwiftUI

@main
struct BancsSurfApp: App {
    @StateObject private var store = DataStore()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .task { await store.charger() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: DataStore
    // Onglet initial surchargeable pour les captures automatisées : SIMCTL_CHILD_ONGLET=2
    @State private var onglet: Int = Int(ProcessInfo.processInfo.environment["ONGLET"] ?? "") ?? 0
    var body: some View {
        TabView(selection: $onglet) {
            CarteView().tabItem { Label("Carte", systemImage: "map") }.tag(0)
            OuAllerView().tabItem { Label("Où aller", systemImage: "figure.surfing") }.tag(1)
            LaNordView().tabItem { Label("La Nord", systemImage: "arrow.up.right.circle") }.tag(2)
            PrevisionsView().tabItem { Label("Prévisions", systemImage: "water.waves") }.tag(3)
            SpotsEtScenesView().tabItem { Label("Webcams", systemImage: "video") }.tag(4)
        }
        .tint(.accent)
    }
}
