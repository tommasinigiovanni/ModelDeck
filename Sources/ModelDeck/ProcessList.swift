import SwiftUI
import ModelDeckCore

struct ProcessList: View {
    @EnvironmentObject var store: DeckStore
    @Binding var sort: ProcessSort
    @State private var query = ""
    @State private var onlyMine = false
    @State private var selection: ProcessIdentity?
    @State private var pending: RunningProcess?
    @State private var force = false
    @State private var error: String?
    private var rows: [RunningProcess] {
        store.processes.filter { (!onlyMine || $0.isMine) && (sort != .gpu || $0.gpuClient) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)) }
            .sorted {
                let a = sort == .cpu ? $0.cpu ?? -1 : sort == .memory ? $0.memory.map { Double($0) } ?? -1 : $0.gpu ?? -1
                let b = sort == .cpu ? $1.cpu ?? -1 : sort == .memory ? $1.memory.map { Double($0) } ?? -1 : $1.gpu ?? -1
                return a == b ? $0.pid < $1.pid : a > b
            }
    }
    private var selected: RunningProcess? { store.processes.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Picker("Ordina per", selection: $sort) { ForEach(ProcessSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 230)
                        Spacer()
                        Toggle("Solo miei", isOn: $onlyMine).toggleStyle(.checkbox).font(.system(size: 11))
                        TextField("Cerca nome o PID", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                    }.frame(height: 28)
                    Text(sort == .gpu ? "Processi con client GPU rilevato. Una connessione non implica attività. Le percentuali compaiono solo se il driver espone contatori validi." : "CPU: 100% equivale a un core. Memoria: RAM residente. I contatori dei processi protetti possono non essere accessibili.")
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("PROCESSO").frame(maxWidth: .infinity, alignment: .leading)
                        Text("PID").frame(width: 52, alignment: .trailing)
                        Text("CPU").frame(width: 65, alignment: .trailing)
                        Text("MEMORIA").frame(width: 90, alignment: .trailing)
                        Text("GPU").frame(width: 85, alignment: .trailing)
                    }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { process in
                                Button { selection = process.id } label: {
                                    HStack {
                                        HStack(spacing: 8) {
                                            Image(systemName: process.gpuClient ? "square.3.layers.3d" : "app").foregroundStyle(process.gpuClient ? DeckTheme.purple : DeckTheme.muted)
                                            Text(process.name).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(process.pid)").frame(width: 52, alignment: .trailing).foregroundStyle(DeckTheme.muted)
                                        Text(DeckFormat.percent(process.cpu)).frame(width: 65, alignment: .trailing)
                                        Text(process.memory.map(DeckFormat.bytes) ?? "—").frame(width: 90, alignment: .trailing)
                                        Text(process.gpu.map { DeckFormat.percent($0) } ?? (process.gpuClient ? "Client" : "—")).frame(width: 85, alignment: .trailing).foregroundStyle(DeckTheme.purple)
                                    }.font(.system(size: 11)).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 9)
                                        .background(selection == process.id ? DeckTheme.mint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if rows.isEmpty { Text(store.processes.isEmpty ? "Lettura processi…" : "Nessun processo corrispondente").font(.system(size: 12)).foregroundStyle(DeckTheme.muted).padding(30) }
                        }
                    }.frame(height: 390)
                    Text("\(rows.count) processi · aggiornamento ogni 3 secondi").font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
            }
            if let process = selected {
                DeckCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(process.name).font(.system(size: 16, weight: .semibold))
                                Text("PID \(process.pid) · UID \(process.userID) · \(process.threads.map(String.init) ?? "—") thread").font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                            }
                            Spacer()
                            Menu("Arresta…") {
                                Button("Termina (SIGTERM)") { force = false; pending = process }
                                Button("Forza arresto (SIGKILL)", role: .destructive) { force = true; pending = process }
                            }.disabled(!process.canTerminate || store.demo)
                        }
                        if let path = process.path { Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted).textSelection(.enabled) }
                        if process.gpuClient, process.gpu == nil { Text("Client GPU rilevato; macOS non espone una percentuale valida per questo processo.").font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
                        if !process.canTerminate { Text("Arresto non disponibile per processi protetti, altri utenti o ModelDeck.").font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }.tint(DeckTheme.mint)
            .confirmationDialog(force ? "Forzare l’arresto del processo?" : "Terminare il processo?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                if let process = pending {
                    Button("\(force ? "Forza arresto" : "Termina") \(process.name) (PID \(process.pid))", role: .destructive) {
                        do { try ProcessMonitor.terminate(process, force: force); error = nil; Task { await store.refreshProcesses() } }
                        catch { self.error = error.localizedDescription }
                        pending = nil
                    }
                }
                Button("Annulla", role: .cancel) { pending = nil }
            } message: { Text("Eventuali modifiche non salvate del processo possono andare perse.") }
            .task {
                if store.demo { selection = store.processes.first?.id }
                while !Task.isCancelled { await store.refreshProcesses(); try? await Task.sleep(for: .seconds(3)) }
            }
    }
}
