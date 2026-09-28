import SwiftUI
import WebKit

/// Toutes les webcams de la zone, du nord au sud, en grand : on voit la mer d'un coup d'œil.
/// Photo du direct rafraîchie chaque minute (ou dernier clip), note du moment des spots filmés ;
/// un toucher ouvre le lecteur ViewSurf.
struct WebcamsView: View {
    @EnvironmentObject var store: DataStore
    @State private var vues: [String: VueWebcam] = [:]
    @State private var ouverte: Webcam?

    var body: some View {
        ScrollViewReader { defil in
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(Webcam.toutes) { w in
                    Button { ouverte = w } label: { carte(w) }.buttonStyle(.plain)
                }
                Text("Images ViewSurf. Direct : photo rafraîchie chaque minute ; plein écran en direct (Capbreton, Hossegor) ou sur le dernier clip horaire de la caméra orientable (Penon, Estagnots).")
                    .font(.caption2).foregroundStyle(Color.sourdine).id("fin")
            }
            .padding()
        }
        .onAppear {
            // Crochet de capture : SIMCTL_CHILD_DEFILER=1 descend en bas de la liste
            if ProcessInfo.processInfo.environment["DEFILER"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { defil.scrollTo("fin", anchor: .bottom) }
            }
            // SIMCTL_CHILD_WEBCAM=prevent ouvre cette webcam en plein écran
            if let id = ProcessInfo.processInfo.environment["WEBCAM"], let w = Webcam.toutes.first(where: { $0.id == id }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { ouverte = w }
            }
        }
        }
        .background(Color.fond)
        .refreshable { await charger() }
        .task {
            while !Task.isCancelled {
                await charger()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .fullScreenCover(item: $ouverte) { w in WebcamPleinEcran(webcam: w, clip: vues[w.id]?.clip) }
    }

    func charger() async {
        await withTaskGroup(of: (String, VueWebcam?).self) { g in
            for w in Webcam.toutes { g.addTask { (w.id, await store.vueWebcam(w)) } }
            for await (id, v) in g { if let v { vues[id] = v } }
        }
    }

    func carte(_ w: Webcam) -> some View {
        let v = vues[w.id]
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let v { Image(uiImage: v.image).resizable().scaledToFill() }
                else { ZStack { Color.panneau; ProgressView() } }
            }
            .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(w.spots, id: \.self) { s in
                        if let n = store.noteMaintenant(s) {
                            Text("\(store.spotsParId[s]?.nom ?? s) \(String(format: "%.1f", n))")
                                .font(.caption2.weight(.bold)).foregroundStyle(Color.fond)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.note(n), in: Capsule())
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(w.nom).font(.title3.weight(.bold)).foregroundStyle(.white)
                    Spacer()
                    Text(fraicheur(w, v)).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(12)
        }
        .overlay(alignment: .topLeading) { badge(w, v).padding(10) }
        .overlay(alignment: .center) {
            Image(systemName: w.lecteurDirect != nil ? "dot.radiowaves.left.and.right" : "play.fill")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(.black.opacity(0.35), in: Circle())
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
    }

    func badge(_ w: Webcam, _ v: VueWebcam?) -> some View {
        let direct = w.direct != nil && !(v?.horsLigne ?? false)
        return HStack(spacing: 5) {
            Circle().fill(direct ? Color.note(0) : Color.sourdine).frame(width: 7, height: 7)
            Text(v?.horsLigne == true ? "HORS LIGNE" : direct ? "DIRECT" : "CLIP").font(.caption2.weight(.heavy)).kerning(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
    }

    /// « il y a 2 min » pour un direct, « clip de 10h » pour un clip.
    func fraicheur(_ w: Webcam, _ v: VueWebcam?) -> String {
        guard let v, let d = v.date else { return "" }
        if w.direct == nil { return "clip de \(Fmt.heure(d))" }
        let min = Int(Date().timeIntervalSince(d) / 60)
        return min < 1 ? "à l'instant" : min < 60 ? "il y a \(min) min" : "à \(Fmt.heureMinute(d))"
    }
}

/// Plein écran : le lecteur ViewSurf, en direct ou sur le dernier clip (Penon, Estagnots).
struct WebcamPleinEcran: View {
    @Environment(\.dismiss) private var fermer
    let webcam: Webcam
    let clip: Int?
    var body: some View {
        NavigationStack {
            PageWeb(url: webcam.lecteur(clip: clip))
                .background(Color.black)
                .navigationTitle(webcam.nom).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Fermer") { fermer() } }
                    ToolbarItem(placement: .topBarTrailing) { Link(destination: webcam.page) { Image(systemName: "safari") } }
                }
        }
    }
}

/// Page ViewSurf dans l'app, vidéo lue en ligne.
struct PageWeb: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: c)
        v.isOpaque = false; v.backgroundColor = .black
        v.load(URLRequest(url: url))
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
