import SwiftUI

struct OuAllerView: View {
    @EnvironmentObject var store: DataStore
    @State private var detail: (spot: String, index: Int)?
    @State private var detente: PresentationDetent = .large
    var body: some View {
        NavigationStack {
            List {
                if let sc = store.scoring {
                    ForEach(sc.resume) { j in
                        Section {
                            ForEach(Array(j.classement.prefix(5))) { c in
                                Button { ouvrir(c, j) } label: { ligne(c) }.buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text(j.jour).font(.headline).foregroundStyle(Color.accent)
                                Text("large \(Fmt.n(j.large.H)) m · \(Fmt.n(j.large.T, 0)) s · \(Fmt.rose(j.large.dir))").font(.caption).foregroundStyle(Color.sourdine)
                            }.textCase(nil)
                        }
                    }
                } else {
                    Text(store.statut.isEmpty ? "Chargement…" : store.statut)
                }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Color.fond)
            .navigationTitle("Où aller ?")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { ReglagesView() } label: { Image(systemName: "gearshape") } } }
            .onAppear { ouvrirSiDemande() }
            .onChange(of: store.dates.count) { _ in ouvrirSiDemande() }
            .sheet(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
                if let d = detail {
                    SpotDetailView(spotId: d.spot, indexHeure: d.index)
                        .presentationDetents([.large, .medium], selection: $detente).presentationDragIndicator(.visible)
                }
            }
        }
    }
    func ligne(_ c: Classement) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%.1f", c.score)).font(.title3.bold()).foregroundStyle(Color.note(c.score)).frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.nom).font(.subheadline.weight(.semibold))
                Text("\(c.creneau) · \(Fmt.n(c.H_b)) m · tube \(c.tube ?? 0) · puiss. \(Fmt.n(c.puissance)) · \(c.vent ?? "")").font(.caption).foregroundStyle(Color.sourdine)
                if let e = c.explication, e != "conditions dans la fenêtre du spot" { Text(e).font(.caption2).italic().foregroundStyle(Color.sourdine) }
            }
        }.padding(.vertical, 2)
    }
    /// Crochet pour les captures automatisées : SIMCTL_CHILD_SPOT=graviere (SIMCTL_CHILD_DANS_H=24 : dans 24 h)
    func ouvrirSiDemande() {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["SPOT"], detail == nil, !store.dates.isEmpty else { return }
        let now = Date().addingTimeInterval(3600 * (Double(env["DANS_H"] ?? "") ?? 0))
        let i = store.dates.enumerated().min { abs($0.element.timeIntervalSince(now)) < abs($1.element.timeIntervalSince(now)) }?.offset ?? 0
        detail = (id, i)
    }

    func ouvrir(_ c: Classement, _ j: ResumeJour) {
        // heure = début du créneau ("07h–11h" -> 7)
        let h = Int(c.creneau.split(separator: "h").first ?? "9") ?? 9
        let jour = Fmt.date(j.date + "T12:00")
        if let i = store.indexHeure(jour: jour, heure: h) { detail = (c.spot, i) }
    }
}

struct ReglagesView: View {
    @EnvironmentObject var store: DataStore
    var body: some View {
        Form {
            Section("Serveur de données") {
                TextField("http://192.168.1.10:8765", text: $store.baseURL).keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                Text("Adresse du Mac qui exécute ./serve.sh (ou d'un hébergement). Dans le simulateur : http://127.0.0.1:8765").font(.caption).foregroundStyle(Color.sourdine)
                Button { Task { await store.charger() } } label: { HStack { Text("Mettre à jour maintenant"); if store.enCours { Spacer(); ProgressView() } } }
                Text(store.statut).font(.caption).foregroundStyle(Color.sourdine)
            }
            Section("À propos") {
                Text("Bancs de sable landais : Sentinel-2 + réfraction du Gouf + Open-Meteo. Les paramètres par spot (fenêtres de taille, marée, pente) sont dans config/zone.yaml côté pipeline.").font(.caption)
            }
        }.navigationTitle("Réglages").scrollContentBackground(.hidden).background(Color.fond)
    }
}
