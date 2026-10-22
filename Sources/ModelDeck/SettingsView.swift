import SwiftUI
import ServiceManagement
import ModelDeckCore

struct SettingsView: View {
    @EnvironmentObject var store: DeckStore
    @State private var ollamaURL = UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
    @State private var lmStudioURL = UserDefaults.standard.string(forKey: "lmStudioURL") ?? "http://127.0.0.1:1234"
    @State private var unslothURL = UserDefaults.standard.string(forKey: "unslothURL") ?? "http://127.0.0.1:8888"
    @AppStorage("sampleInterval") private var interval = 2.0
    @AppStorage("appearance") private var appearance = DeckAppearance.system.rawValue
    @State private var token = ""
    @State private var tokenEdited = false
    @State private var unslothToken = ""
    @State private var unslothTokenEdited = false
    @State private var folders: [String] = UserDefaults.standard.stringArray(forKey: "modelFolders") ?? []
    @State private var unslothFolders: [String] = UserDefaults.standard.stringArray(forKey: "unslothFolders") ?? []
    @State private var bridgeInstalled = ClaudeBridge.isInstalled()
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var feedback: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DeckCard {
                HStack {
                    Text("Aspetto").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Picker("Tema", selection: $appearance) {
                        ForEach(DeckAppearance.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented).frame(width: 280, height: 26)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Server locali").font(.system(size: 15, weight: .semibold))
                    field("Ollama", value: $ollamaURL)
                    field("LM Studio", value: $lmStudioURL)
                    field("Unsloth", value: $unslothURL)
                    HStack {
                        Text("Token LM Studio").frame(width: 115, alignment: .leading)
                        SecureField("Opzionale · salvato nel Portachiavi", text: $token).textFieldStyle(.roundedBorder).onChange(of: token) { _, _ in tokenEdited = true }
                    }.font(.system(size: 11))
                    HStack {
                        Text("API key Unsloth").frame(width: 115, alignment: .leading)
                        SecureField("Opzionale · salvata nel Portachiavi", text: $unslothToken).textFieldStyle(.roundedBorder).onChange(of: unslothToken) { _, _ in unslothTokenEdited = true }
                    }.font(.system(size: 11))
                    Text("Sono ammessi solo localhost e indirizzi loopback. Nessuna scansione della rete.")
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                    Button("Salva e verifica") {
                        do {
                            _ = try LocalHTTP.endpoint(ollamaURL); _ = try LocalHTTP.endpoint(lmStudioURL)
                            _ = try LocalHTTP.endpoint(unslothURL)
                            if tokenEdited { try DeckKeychain.save(token); tokenEdited = false }
                            if unslothTokenEdited { try DeckKeychain.save(unslothToken, account: "unsloth"); unslothTokenEdited = false }
                            UserDefaults.standard.set(ollamaURL, forKey: "ollamaURL")
                            UserDefaults.standard.set(lmStudioURL, forKey: "lmStudioURL")
                            UserDefaults.standard.set(unslothURL, forKey: "unslothURL")
                            feedback = "Impostazioni salvate."
                            Task { await store.refreshModels() }
                        } catch { feedback = error.localizedDescription }
                    }.buttonStyle(.bordered)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Cartelle dei modelli").font(.system(size: 15, weight: .semibold))
                    Text("Incluse le cartelle standard di Ollama, LM Studio, Unsloth Studio e la cache Hugging Face condivisa. Aggiungi qui percorsi personalizzati o dischi esterni.")
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                    ForEach(folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(DeckTheme.purple)
                            Text(folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Button { folders.removeAll { $0 == folder }; saveFolders() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Rimuovi cartella dall’inventario")
                        }
                    }
                    ForEach(unslothFolders, id: \.self) { folder in
                        HStack {
                            Text("Unsloth").foregroundStyle(DeckTheme.amber)
                            Text(folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).lineLimit(1)
                            Spacer()
                            Button { unslothFolders.removeAll { $0 == folder }; saveFolders() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }.font(.system(size: 10, design: .monospaced))
                    }
                    HStack {
                        Button("Aggiungi cartella…") { chooseFolder(unsloth: false) }
                        Button("Aggiungi cartella Unsloth…") { chooseFolder(unsloth: true) }
                    }.buttonStyle(.bordered)
                    Text("La cache Hugging Face può essere usata da più applicazioni; i suoi pesi sono raggruppati sotto Unsloth.")
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Quote degli abbonamenti").font(.system(size: 15, weight: .semibold))
                    Text("Codex usa l’account già collegato alla CLI. Accedi con codex login se la quota non compare. Non vengono avviate conversazioni né richieste ai modelli.")
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text("Claude Code aggiorna le quote dopo le risposte. Il collegamento modifica ~/.claude/settings.json, conserva la status line attuale e salva solo percentuali e orari di reset. Il ripristino rimuove il collegamento.")
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(bridgeInstalled ? "Ripristina status line" : "Collega Claude Code") {
                            do {
                                if bridgeInstalled { try ClaudeBridge.uninstall() }
                                else { try ClaudeBridge.install(executable: Bundle.main.executableURL!) }
                                bridgeInstalled = ClaudeBridge.isInstalled()
                                feedback = bridgeInstalled ? "Collegato. Riavvia la sessione Claude Code e invia un messaggio." : "Status line precedente ripristinata."
                            } catch { feedback = error.localizedDescription }
                        }.buttonStyle(.bordered)
                        Link("Documentazione", destination: URL(string: "https://code.claude.com/docs/en/statusline")!).font(.system(size: 11))
                    }
                    Text("Le quote di Codex non rappresentano tutti i limiti dell’app ChatGPT. Non sono costi API né percentuali di contesto.")
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Aggiornamento metriche").font(.system(size: 11)); Spacer()
                        Picker("Intervallo", selection: $interval) { Text("2 secondi").tag(2.0); Text("5 secondi").tag(5.0); Text("10 secondi").tag(10.0) }.labelsHidden().frame(width: 150)
                    }
                    Toggle("Apri all’accesso al Mac", isOn: $loginEnabled).font(.system(size: 11)).onChange(of: loginEnabled) { _, value in
                        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { feedback = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
                    }
                    Text("Modelli: ogni 30 s. Quote Codex: ogni 90 s. La disponibilità della metrica GPU dipende dal Mac; temperature e consumi non vengono stimati.")
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
            }
            if let feedback { Text(feedback).font(.system(size: 12)).foregroundStyle(DeckTheme.amber).textSelection(.enabled) }
        }.tint(DeckTheme.mint)
    }
    private func field(_ label: String, value: Binding<String>) -> some View {
        HStack { Text(label).frame(width: 115, alignment: .leading); TextField("", text: value).textFieldStyle(.roundedBorder) }.font(.system(size: 11))
    }
    private func chooseFolder(unsloth: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            if unsloth { unslothFolders = Array(Set(unslothFolders + panel.urls.map(\.path))).sorted() }
            else { folders = Array(Set(folders + panel.urls.map(\.path))).sorted() }
            saveFolders()
        }
    }
    private func saveFolders() {
        UserDefaults.standard.set(folders, forKey: "modelFolders"); UserDefaults.standard.set(unslothFolders, forKey: "unslothFolders")
        Task { await store.refreshModels() }
    }
}
