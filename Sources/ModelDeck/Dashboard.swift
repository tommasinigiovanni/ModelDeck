import SwiftUI
import ModelDeckCore

struct Dashboard: View {
    @EnvironmentObject var store: DeckStore
    @State private var section = "overview"
    @State private var processSort = ProcessSort.cpu
    var initialSection = "overview"
    var appearanceOverride: DeckAppearance? = nil
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(DeckTheme.subtle.opacity(0.07)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if section == "settings" { SettingsView().environmentObject(store) }
                    else if section == "credits" { CreditsView() }
                    else if section == "processes" { ProcessList(sort: $processSort) }
                    else {
                        if section == "overview" { overview }
                        if section == "subscriptions" { subscriptions }
                        if section == "overview" || section == "models" {
                            ModelLibrary(limit: section == "overview" ? 5 : nil)
                        }
                    }
                    HStack {
                        if store.demo { Text("ANTEPRIMA · DATI FITTIZI") }
                        Spacer()
                        Text("ModelDeck 0.6.0")
                    }.font(.system(size: 9, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                }.padding(28).frame(maxWidth: 1200)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(DeckTheme.background).foregroundStyle(DeckTheme.foreground)
            .frame(minWidth: 940, minHeight: 680)
            .deckAppearance(appearanceOverride)
            .onAppear { section = initialSection; store.start() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(DeckTheme.mint).font(.system(size: 23))
                Text("ModelDeck").font(.system(size: 18, weight: .semibold)).tracking(-0.6)
            }.padding(.bottom, 6)
            Text("IL TUO SPAZIO AI").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(DeckTheme.muted).padding(.bottom, 34)
            nav("overview", "Panoramica", "rectangle.grid.2x2")
            nav("models", "Modelli locali", "cube.transparent")
            nav("processes", "Processi", "list.bullet.rectangle")
            nav("subscriptions", "Abbonamenti", "chart.bar.xaxis")
            nav("settings", "Impostazioni", "slider.horizontal.3")
            nav("credits", "Crediti", "info.circle")
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "laptopcomputer").font(.system(size: 22)).foregroundStyle(DeckTheme.muted)
                Text(store.machine.chip).font(.system(size: 12, weight: .medium))
                Text("\(DeckFormat.bytes(store.machine.memory)) · \(store.machine.cores) core")
                    .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                StatusPill(text: store.snapshot.thermal)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(DeckTheme.subtle.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        }.padding(20).frame(width: 190).background(.black.opacity(0.12))
    }
    private func nav(_ id: String, _ title: String, _ symbol: String) -> some View {
        Button { section = id } label: {
            HStack(spacing: 10) { Image(systemName: symbol).frame(width: 16); Text(title); Spacer() }
                .font(.system(size: 11, weight: section == id ? .semibold : .regular)).padding(.horizontal, 12).padding(.vertical, 12)
                .foregroundStyle(section == id ? DeckTheme.mint : DeckTheme.muted)
                .background(section == id ? DeckTheme.mint.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).padding(.bottom, 4)
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(section == "credits" ? "Le persone e il progetto." : section == "processes" ? "Chi sta usando il tuo Mac." : section == "models" ? "La tua libreria locale." : section == "subscriptions" ? "Le tue quote, in chiaro." : section == "settings" ? "Tutto al posto giusto." : "Tutto sotto controllo.")
                    .font(.system(size: 29, weight: .semibold)).tracking(-1)
                Text(section == "credits" ? "Autore, codice sorgente e riferimenti." : section == "processes" ? "CPU, memoria e processi GPU. Seleziona un processo per i dettagli." : section == "overview" ? "Il tuo Mac, i tuoi modelli e le quote AI. In un solo posto." : section == "models" ? "Modelli installati, formati e stato di caricamento." : section == "subscriptions" ? "Percentuali utilizzate e prossimi reset di Claude Code e Codex." : "Sorgenti locali e collegamenti ai tuoi strumenti.")
                    .font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                if store.demo { StatusPill(text: "ANTEPRIMA · DATI FITTIZI", color: DeckTheme.amber) }
            }
            Spacer()
            Button { Task { await store.refreshModels(); await store.refreshUsage() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13)).frame(width: 32, height: 32).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).disabled(store.refreshing || store.usageRefreshing).help("Aggiorna modelli e quote")
        }
    }
    private var overview: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                SectionLabel(title: "QUESTO MAC", trailing: "Aggiornamento continuo")
                HStack(alignment: .top, spacing: 12) {
                    MetricCard(title: "CPU", symbol: "cpu", value: DeckFormat.percent(store.snapshot.cpu), detail: "\(store.machine.cores) core · \(store.machine.performanceCores)P + \(store.machine.efficiencyCores)E", color: DeckTheme.blue, history: store.cpuHistory)
                        .onTapGesture { processSort = .cpu; section = "processes" }.help("Mostra i processi ordinati per CPU")
                    MetricCard(title: "MEMORIA", symbol: "memorychip", value: DeckFormat.bytes(store.snapshot.memoryUsed), detail: "\(DeckFormat.percent(store.snapshot.memoryPercent)) di \(DeckFormat.bytes(store.snapshot.memoryTotal)) · swap \(DeckFormat.bytes(store.snapshot.swapUsed))", color: DeckTheme.mint, history: store.memoryHistory)
                        .onTapGesture { processSort = .memory; section = "processes" }.help("Mostra i processi ordinati per memoria")
                    MetricCard(title: "GPU", symbol: "square.3.layers.3d", value: DeckFormat.percent(store.snapshot.gpu), detail: store.snapshot.gpu == nil ? "Metrica non esposta su questo Mac" : "Utilizzo del dispositivo · IOKit", color: DeckTheme.purple, history: store.gpuHistory)
                        .onTapGesture { processSort = .gpu; section = "processes" }.help("Mostra i processi GPU")
                }
                HStack(spacing: 12) {
                    DeckCard {
                        HStack(spacing: 12) {
                            Image(systemName: "internaldrive").foregroundStyle(DeckTheme.amber)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("DISCO DI AVVIO").font(.system(size: 9, weight: .medium)).foregroundStyle(DeckTheme.muted)
                                Text("\(DeckFormat.bytes(store.snapshot.diskAvailable)) liberi").font(.system(size: 13, weight: .medium))
                            }
                            Spacer()
                            if store.snapshot.diskTotal > 0 {
                                Gauge(value: Double(store.snapshot.diskTotal - min(store.snapshot.diskAvailable, store.snapshot.diskTotal)) / Double(store.snapshot.diskTotal)) { EmptyView() }
                                    .gaugeStyle(.accessoryCircularCapacity).tint(DeckTheme.amber).scaleEffect(0.7).frame(width: 35, height: 35).accessibilityLabel("Spazio disco utilizzato")
                            }
                        }
                    }
                    DeckCard {
                        HStack(spacing: 12) {
                            Image(systemName: "network").foregroundStyle(DeckTheme.blue)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("RETE · WI-FI / ETHERNET").font(.system(size: 9, weight: .medium)).foregroundStyle(DeckTheme.muted)
                                HStack(spacing: 12) {
                                    Text("↓ " + DeckFormat.rate(store.snapshot.download)).foregroundStyle(DeckTheme.blue)
                                    Text("↑ " + DeckFormat.rate(store.snapshot.upload)).foregroundStyle(DeckTheme.purple)
                                }.font(.system(size: 12, weight: .medium, design: .monospaced))
                            }; Spacer(minLength: 0)
                        }.frame(height: 35)
                    }
                }
            }
            subscriptions
        }
    }
    private var subscriptions: some View {
        VStack(spacing: 12) {
            SectionLabel(title: "ABBONAMENTI AI", trailing: "Percentuale usata per finestra")
            HStack(alignment: .top, spacing: 12) { UsageCard(usage: store.claude); UsageCard(usage: store.codex) }
        }
    }
}

struct ModelLibrary: View {
    @EnvironmentObject var store: DeckStore
    var limit: Int? = nil
    @State private var filter = "Tutti"
    @State private var query = ""
    @State private var fitRequest: FitRequest?
    var filtered: [LocalModel] {
        store.inventory.models.filter { (filter == "Tutti" || $0.source.rawValue == filter) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                SectionLabel(title: "MODELLI LOCALI", trailing: "\(store.inventory.models.count) modelli · \(DeckFormat.bytes(store.inventory.models.reduce(0) { $0 + $1.bytes })) su disco*")
                Button { fitRequest = FitRequest(model: nil) } label: { Label("Verifica hardware", systemImage: "gauge.with.needle") }.font(.system(size: 10)).buttonStyle(.bordered)
            }
            DeckCard {
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        ForEach(["Tutti"] + ModelSource.allCases.map(\.rawValue), id: \.self) { source in
                            Button { filter = source } label: {
                                Text(source).font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                                    .foregroundStyle(filter == source ? DeckTheme.mint : DeckTheme.muted)
                                    .background(filter == source ? DeckTheme.mint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        Image(systemName: "magnifyingglass").foregroundStyle(DeckTheme.muted)
                        TextField("Cerca un modello", text: $query).textFieldStyle(.plain).font(.system(size: 11)).frame(width: 140)
                    }
                    if filtered.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "cube.transparent").font(.system(size: 30)).foregroundStyle(DeckTheme.muted)
                            Text(store.refreshing ? "Ricerca modelli…" : "Nessun modello trovato").font(.system(size: 14, weight: .medium))
                            Text("Avvia Ollama, LM Studio o Unsloth, oppure aggiungi una cartella nelle impostazioni.")
                                .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 22)
                    } else {
                        ForEach(Array(filtered.prefix(limit ?? Int.max))) { model in
                            HStack(spacing: 12) {
                                Image(systemName: "cube.fill").font(.system(size: 16)).foregroundStyle(model.source == .ollama ? DeckTheme.mint : DeckTheme.purple)
                                    .frame(width: 34, height: 38).background(DeckTheme.subtle.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(model.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(model.name)
                                    Text(([model.source.rawValue, model.format] + [model.parameters, model.quantization, model.context.map { "ctx \($0.formatted())" }].compactMap { $0 }).joined(separator: " · "))
                                        .font(.system(size: 9)).foregroundStyle(DeckTheme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(model.bytes > 0 ? DeckFormat.bytes(model.bytes) : "—").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                                StatusPill(text: model.loaded == true ? "Caricato" : model.loaded == false ? "Su disco" : "Stato ignoto", color: model.loaded == true ? DeckTheme.mint : DeckTheme.muted).frame(width: 85, alignment: .trailing)
                                Button { fitRequest = FitRequest(model: model) } label: { Image(systemName: "gauge.with.needle").foregroundStyle(DeckTheme.blue) }.buttonStyle(.plain).help("Valuta la memoria necessaria per questo modello")
                                if let path = model.path {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([path]) } label: { Image(systemName: "folder").foregroundStyle(DeckTheme.muted) }.buttonStyle(.plain).help("Mostra nel Finder")
                                }
                            }
                            if model.id != Array(filtered.prefix(limit ?? Int.max)).last?.id { Divider().overlay(DeckTheme.subtle.opacity(0.02)) }
                        }
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(store.inventory.runtimes) { runtime in
                            HStack(alignment: .top, spacing: 5) {
                                Circle().fill(runtime.online ? DeckTheme.mint : DeckTheme.muted).frame(width: 4, height: 4).padding(.top, 3)
                                Text(runtime.name + " · " + runtime.detail).font(.system(size: 9)).foregroundStyle(DeckTheme.muted)
                            }
                        }; Spacer(minLength: 0)
                    }
                    Text("* Dimensioni logiche dei pesi, non spazio fisico esclusivo. La memoria unificata è condivisa con la GPU.")
                        .font(.system(size: 9)).foregroundStyle(DeckTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.sheet(item: $fitRequest) { request in ModelFitView(localModel: request.model).environmentObject(store) }
    }
}
