import SwiftUI
import ModelDeckCore

struct FitRequest: Identifiable {
    let id = UUID()
    var model: LocalModel?
}

struct ModelFitView: View {
    @EnvironmentObject var store: DeckStore
    @Environment(\.dismiss) private var dismiss
    var localModel: LocalModel? = nil
    var demonstration = false
    var appearanceOverride: DeckAppearance? = nil
    @State private var repository = ""
    @State private var hub: HubModel?
    @State private var variantID = ""
    @State private var profile = AttentionProfile()
    @State private var weightsGiB = 0.0
    @State private var parametersB = 0.0
    @State private var bitsPerWeight = 4.5
    @State private var estimateWeights = false
    @State private var context = 4096
    @State private var sequences = 1
    @State private var precision = KVPrecision.fp16
    @State private var reserveGiB = 4.0
    @State private var extraGiB = 0.0
    @State private var useMetal = true
    @State private var assumeStandard = false
    @State private var loading = false
    @State private var error: String?
    @State private var source = "Inserisci dati manuali o importa i metadati"
    @State private var request: Task<Void, Never>?

    private var weights: Double { estimateWeights ? parametersB * 1_000_000_000 * bitsPerWeight / 8 : weightsGiB * gibibyte }
    private var result: FitEstimate {
        MemoryEstimator.estimate(weights: weights, profile: profile, context: context, sequences: sequences, precision: precision,
                                 physicalMemory: Double(store.machine.memory), metalLimit: useMetal && store.machine.unifiedMemory ? store.machine.metalWorkingSet.map { Double($0) } : nil,
                                 reserve: reserveGiB * gibibyte, extra: extraGiB * gibibyte, assumeStandard: assumeStandard)
    }
    private var verdictColor: Color {
        switch result.verdict { case .fits: DeckTheme.mint; case .tight, .incomplete: DeckTheme.amber; case .tooLarge: .red }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Questo modello sta nel tuo Mac?").font(.system(size: 24, weight: .semibold)).tracking(-0.7)
                    Text("Stima per inferenza · pesi + cache KV + margine del runtime").font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(DeckTheme.muted) }.buttonStyle(.plain).help("Chiudi")
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        StatusPill(text: store.machine.chip)
                        Text("RAM " + MemoryEstimator.gib(Double(store.machine.memory))).font(.system(size: 11))
                        Spacer()
                        if let limit = store.machine.metalWorkingSet, store.machine.unifiedMemory {
                            Text("Budget consigliato Metal " + MemoryEstimator.gib(Double(limit))).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                        }
                    }
                    if store.demo { StatusPill(text: "ANTEPRIMA · DATI FITTIZI", color: DeckTheme.amber) }
                    if let model = localModel {
                        HStack {
                            Image(systemName: "cube.fill").foregroundStyle(DeckTheme.purple)
                            Text(model.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Spacer()
                            Text(DeckFormat.bytes(model.bytes)).font(.system(size: 11, design: .monospaced))
                        }
                    }
                    DeckCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Metadati da Hugging Face").font(.system(size: 14, weight: .semibold))
                            HStack {
                                TextField("autore/modello o https://huggingface.co/autore/modello", text: $repository).textFieldStyle(.roundedBorder).onSubmit { lookup() }
                                Button(loading ? "Caricamento…" : "Importa dati", action: lookup).disabled(loading || repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            if let hub, !hub.variants.isEmpty {
                                Picker("Pesi / quantizzazione", selection: $variantID) {
                                    ForEach(hub.variants) { variant in Text(variant.name + " · " + DeckFormat.bytes(variant.bytes)).tag(variant.id) }
                                }.onChange(of: variantID) { _, _ in applyVariant() }
                            }
                            Text(source).font(.system(size: 10)).foregroundStyle(DeckTheme.muted).textSelection(.enabled)
                            if let error { Text(error).font(.system(size: 11)).foregroundStyle(DeckTheme.amber).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                    DeckCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Dimensione dei pesi").font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Toggle("Stima dai parametri", isOn: $estimateWeights).toggleStyle(.checkbox).font(.system(size: 10))
                            }
                            if estimateWeights {
                                HStack(spacing: 20) {
                                    number("Parametri totali (miliardi)", value: $parametersB)
                                    number("Bit effettivi per peso", value: $bitsPerWeight)
                                }
                                Text("Usa i parametri totali anche per i modelli MoE. 4,5 bit/peso è un’ipotesi modificabile; la dimensione di un file quantizzato reale è preferibile.")
                                    .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                            } else { number("Pesi (GiB) · da file o inserimento manuale", value: $weightsGiB) }
                            HStack(spacing: 20) {
                                integer("Contesto totale (token)", value: $context)
                                Stepper("Sequenze: \(sequences)", value: $sequences, in: 1...8).font(.system(size: 11)).frame(maxWidth: .infinity)
                            }
                            Picker("Cache KV", selection: $precision) { ForEach(KVPrecision.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.font(.system(size: 11))
                            if precision != .fp16 { Text("Cache quantizzata: verifica il supporto del backend e del modello. La stima include i blocchi Q8_0/Q4_0 di llama.cpp.").font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
                            DisclosureGroup("Architettura e margini · \(profile.source)") {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 14) { integer("Layer con cache KV", value: $profile.layers); integer("Teste KV", value: $profile.kvHeads) }
                                    HStack(spacing: 14) { integer("Dimensione testa K", value: $profile.keyDimension); integer("Dimensione testa V", value: $profile.valueDimension) }
                                    HStack(spacing: 14) { number("Riserva macOS (GiB)", value: $reserveGiB); number("Memoria extra (GiB)", value: $extraGiB) }
                                    Toggle("Usa il budget Metal consigliato", isOn: $useMetal).font(.system(size: 11)).disabled(!store.machine.unifiedMemory)
                                    if let caveat = profile.caveat {
                                        Text(caveat).font(.system(size: 11)).foregroundStyle(DeckTheme.amber)
                                        Toggle("Assumi questi parametri come attenzione standard", isOn: $assumeStandard).font(.system(size: 10))
                                    }
                                }.padding(.top, 10)
                            }.font(.system(size: 11))
                        }
                    }
                    DeckCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Image(systemName: result.verdict == .fits ? "checkmark.circle.fill" : result.verdict == .tooLarge ? "xmark.circle.fill" : "questionmark.circle.fill").foregroundStyle(verdictColor)
                                Text(result.verdict.rawValue).font(.system(size: 18, weight: .semibold))
                                Spacer()
                                Text(MemoryEstimator.gib(result.total ?? result.minimum)).font(.system(size: 22, weight: .semibold, design: .rounded))
                            }
                            breakdown
                            HStack {
                                part("Pesi", result.weights, DeckTheme.blue)
                                part("Cache KV", result.kvCache, DeckTheme.purple)
                                part("Runtime / extra", result.runtime, DeckTheme.amber)
                                Spacer()
                                part("Budget modello", result.budget, DeckTheme.mint)
                            }
                            Text(result.note).font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                            if result.verdict == .fits || result.verdict == .tight,
                               localModel?.loaded != true,
                               let total = result.total,
                               total > max(0, Double(store.snapshot.memoryTotal) - Double(store.snapshot.memoryUsed)) {
                                Text("Con il carico attuale potrebbe servire liberare altra RAM, se questo modello non è già caricato.").font(.system(size: 11)).foregroundStyle(DeckTheme.amber)
                            }
                            if result.verdict == .incomplete { Text("Il totale mostrato è parziale o basato su ipotesi non confermate.").font(.system(size: 10)).foregroundStyle(DeckTheme.amber) }
                            Text("Margine runtime: 15% dei pesi, minimo 1 GiB, più la memoria extra. La disponibilità attuale è circa \(MemoryEstimator.gib(max(0, Double(store.snapshot.memoryTotal) - Double(store.snapshot.memoryUsed)))): altre app e modelli caricati condividono la RAM.")
                                .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack {
                        Link("Come si calcola la cache KV", destination: URL(string: "https://huggingface.co/blog/kv-cache-quantization")!)
                        Spacer()
                        Link("Apri il calcolatore ApX", destination: URL(string: "https://apxml.com/tools/vram-calculator")!)
                    }.font(.system(size: 10))
                    Text("Stima per inferenza testuale. Encoder, proiettori e input multimodali vanno aggiunti come memoria extra. Non misura velocità, qualità, compatibilità del software o memoria per fine-tuning.").font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
            }
        }.frame(width: 840, height: 850).background(DeckTheme.background).foregroundStyle(DeckTheme.foreground).tint(DeckTheme.mint).deckAppearance(appearanceOverride)
            .task {
                useMetal = store.machine.unifiedMemory
                reserveGiB = max(2, min(4, Double(store.machine.memory) / gibibyte * 0.25))
                if let model = localModel {
                    weightsGiB = Double(model.bytes) / gibibyte; source = "Dimensione del modello locale · " + model.source.rawValue
                    profile = await Task.detached(priority: .utility) { LocalFitMetadata.read(model) }.value
                    if !profile.complete, model.source == .ollama,
                       let details = try? await LocalFitMetadata.ollama(model: model.name, endpoint: UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434") { profile = details }
                    if let id = try? HuggingFaceCatalog.repositoryID(model.name) { repository = id }
                }
                if demonstration {
                    weightsGiB = 4; profile.layers = 32; profile.kvHeads = 8; profile.keyDimension = 128; profile.valueDimension = 128
                    profile.source = "Dati fittizi"; source = "Modello demo · dati fittizi · nessuna richiesta di rete"
                }
            }.onDisappear { request?.cancel() }
    }

    private var breakdown: some View {
        GeometryReader { geometry in
            let denominator = max(result.budget, result.total ?? result.minimum, 1)
            HStack(spacing: 1) {
                Rectangle().fill(DeckTheme.blue).frame(width: geometry.size.width * result.weights / denominator)
                Rectangle().fill(DeckTheme.purple).frame(width: geometry.size.width * (result.kvCache ?? 0) / denominator)
                Rectangle().fill(DeckTheme.amber).frame(width: geometry.size.width * result.runtime / denominator)
                Spacer(minLength: 0)
            }.background(DeckTheme.subtle.opacity(0.05)).clipShape(Capsule())
        }.frame(height: 9)
    }
    private func part(_ title: String, _ bytes: Double?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 9)).foregroundStyle(DeckTheme.muted); Text(bytes.map(MemoryEstimator.gib) ?? "Da calcolare").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(color) }
    }
    private func number(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(label).font(.system(size: 10)).foregroundStyle(DeckTheme.muted); TextField(label, value: value, format: .number.precision(.fractionLength(0...3))).textFieldStyle(.roundedBorder).labelsHidden() }.frame(maxWidth: .infinity)
    }
    private func integer(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(label).font(.system(size: 10)).foregroundStyle(DeckTheme.muted); TextField(label, value: value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).labelsHidden() }.frame(maxWidth: .infinity)
    }
    private func lookup() {
        guard !loading else { return }; loading = true; error = nil
        request?.cancel()
        request = Task {
            defer { loading = false }
            do {
                let model = try await HuggingFaceCatalog.fetch(repository)
                guard !Task.isCancelled else { return }
                hub = model; profile = model.profile; assumeStandard = false
                parametersB = (model.parameters ?? 0) / 1_000_000_000
                source = "Hugging Face · \(model.repository) · \(model.revision.prefix(10)) · solo metadati"
                if let preferred = model.variants.first(where: { $0.name.lowercased().contains("q4_k_m") }) ?? model.variants.first { variantID = preferred.id; applyVariant() }
                else { weightsGiB = 0; estimateWeights = parametersB > 0; error = "Dimensioni dei pesi non disponibili: scegli parametri/bit o inserisci i GiB manualmente." }
                if !profile.complete { error = "Parametri dell’attenzione incompleti. Apri Architettura e margini per completarli." }
                if let maximum = profile.maxContext { context = min(context, maximum) }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func applyVariant() {
        if let variant = hub?.variants.first(where: { $0.id == variantID }) { weightsGiB = Double(variant.bytes) / gibibyte; estimateWeights = false }
    }
}
