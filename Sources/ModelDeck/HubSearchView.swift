import SwiftUI
import ModelDeckCore

struct HubSearchView: View {
    var importing = false
    var onSelect: (String) -> Void
    @State private var query = ""
    @State private var format = HubSearchFormat.all
    @State private var results: [HubSearchResult] = []
    @State private var searching = false
    @State private var searched = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?
    @State private var ticket = UUID()
    private var exactRepository: String? { try? HuggingFaceCatalog.repositoryID(query) }

    init(initialQuery: String = "", importing: Bool = false, demonstration: Bool = false, onSelect: @escaping (String) -> Void) {
        self.importing = importing; self.onSelect = onSelect
        _query = State(initialValue: demonstration ? "qwen" : initialQuery)
        _searched = State(initialValue: demonstration)
        _results = State(initialValue: demonstration ? [
            .init(repository: "demo/Qwen-8B-GGUF", downloads: 125000, format: "GGUF", task: "text-generation"),
            .init(repository: "demo/Qwen-8B-4bit", downloads: 78000, format: "MLX", task: "text-generation"),
            .init(repository: "demo/Qwen-14B", downloads: 43000, format: "transformers", task: "text-generation")
        ] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Nome parziale, autore/modello o link Hugging Face", text: $query)
                    .textFieldStyle(.roundedBorder).onSubmit { submit() }
                    .onChange(of: query) { _, _ in clearSearch() }
                Button(searching ? "Ricerca…" : "Cerca", action: search).disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                Button("Importa ID/link") { if let id = exactRepository { choose(id) } }.disabled(exactRepository == nil || searching)
            }
            HStack {
                Picker("Formato", selection: $format) {
                    ForEach(HubSearchFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 245)
                    .onChange(of: format) { _, _ in if searched || searching { search() } }
                Spacer()
                if importing { ProgressView().controlSize(.small); Text("Importazione metadati…").font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(DeckTheme.amber).fixedSize(horizontal: false, vertical: true) }
            if !results.isEmpty {
                Text("\(results.count) risultati · ordinati per download").font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(results) { model in
                            Button { choose(model.repository) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "cube").foregroundStyle(DeckTheme.purple)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(model.repository).font(.system(size: 12, weight: .medium)).foregroundStyle(DeckTheme.foreground).lineLimit(1)
                                        Text([model.format, model.task, model.gated ? "Accesso riservato" : nil].compactMap { $0 }.joined(separator: " · "))
                                            .font(.system(size: 9)).foregroundStyle(DeckTheme.muted).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    if let downloads = model.downloads {
                                        Label(downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down")
                                            .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).help("Download riportati da Hugging Face")
                                    }
                                    Text("Seleziona").font(.system(size: 10, weight: .medium)).foregroundStyle(DeckTheme.mint)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(DeckTheme.subtle.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Importa i metadati di " + model.repository)
                        }
                    }
                }.frame(height: min(220, CGFloat(results.count) * 58))
            } else if searched && !searching && error == nil {
                Text("Nessun modello trovato. Prova un nome più corto o cambia formato.").font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
            } else if !searching {
                Text("Cerca anche solo “qwen”, “llama” o “gemma”, poi seleziona un risultato. Per un repository preciso usa Importa ID/link.")
                    .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(importing).onDisappear { request?.cancel() }
    }
    private func clearSearch() {
        request?.cancel(); ticket = UUID(); searching = false; searched = false; results = []; error = nil
    }
    private func submit() {
        if query.contains("://"), let id = exactRepository { choose(id) }
        else { search() }
    }
    private func choose(_ id: String) {
        clearSearch(); query = id; onSelect(id)
    }
    private func search() {
        request?.cancel(); let current = UUID(); ticket = current
        let text = query, selectedFormat = format
        searching = true; searched = false; results = []; error = nil
        request = Task {
            defer { if ticket == current { searching = false } }
            do {
                let found = try await HuggingFaceCatalog.search(text, format: selectedFormat)
                guard !Task.isCancelled, ticket == current else { return }
                results = found; searched = true
            } catch {
                guard !Task.isCancelled, ticket == current else { return }
                self.error = error.localizedDescription; searched = true
            }
        }
    }
}
