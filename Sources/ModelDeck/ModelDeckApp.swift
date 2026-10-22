import SwiftUI
import ModelDeckCore

@main enum Launcher {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--connect-claude") || args.contains("--disconnect-claude") {
            do {
                if args.contains("--disconnect-claude") { try ClaudeBridge.uninstall(); print("Status line precedente ripristinata.") }
                else {
                    try ClaudeBridge.install(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: args[0]))
                    print("Claude Code collegato. Riavvia la sessione e invia un messaggio per ricevere le quote.")
                }
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.contains("--claude-statusline") {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            try? ClaudeUsage.capture(input)
            if let index = args.firstIndex(of: "--previous"), args.indices.contains(index + 1) {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", args[index + 1]]
                process.standardInput = pipe
                do {
                    try process.run(); try? pipe.fileHandleForWriting.write(contentsOf: input); try? pipe.fileHandleForWriting.close()
                    process.waitUntilExit()
                } catch { print("ModelDeck") }
            } else {
                let usage = ClaudeUsage.read()
                let text = usage.windows.filter { !$0.isExpired }.map { "\($0.title): \(DeckFormat.percent($0.usedPercent))" }.joined(separator: " · ")
                print(text.isEmpty ? "Claude Code" : text)
            }
            return
        }
        if args.contains("--diagnostics") {
            Task {
                let monitor = SystemMonitor()
                _ = await monitor.sample(); try? await Task.sleep(for: .seconds(1))
                let stats = await monitor.sample()
                let inventory = await ModelInventory().scan(ollamaURL: "http://127.0.0.1:11434", lmStudioURL: "http://127.0.0.1:1234", folders: [])
                var object: [String: Any] = ["chip": SystemMonitor.machine().chip, "memory_used": stats.memoryUsed, "memory_total": stats.memoryTotal, "models": inventory.models.count, "claude_windows": ClaudeUsage.read().windows.count]
                object["cpu_percent"] = stats.cpu; object["gpu_percent"] = stats.gpu
                do { let usage = try await CodexUsage.read(); object["codex_windows"] = usage.windows.map { ["window": $0.title, "used_percent": $0.usedPercent] as [String: Any] } }
                catch { object["codex_error"] = error.localizedDescription }
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
                exit(0)
            }
            RunLoop.main.run(); return
        }
        if let index = args.firstIndex(of: "--preview"), args.indices.contains(index + 1) {
            renderPreview(to: URL(fileURLWithPath: args[index + 1])); return
        }
        ModelDeckApp.main()
    }

    @MainActor private static func renderPreview(to url: URL) {
        _ = NSApplication.shared
        let store = DeckStore(); store.useDemo()
        let hosting = NSHostingView(rootView: Dashboard().environmentObject(store).environment(\.locale, Locale(identifier: "it_IT")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 1240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url) }
            }
            exit(0)
        }
        NSApplication.shared.run()
    }
}

struct ModelDeckApp: App {
    @StateObject private var store: DeckStore = {
        let store = DeckStore()
        if CommandLine.arguments.contains("--demo") { store.useDemo() }
        return store
    }()
    var body: some Scene {
        Window("ModelDeck", id: "dashboard") {
            Dashboard().environmentObject(store).environment(\.locale, Locale(identifier: "it_IT"))
        }.defaultSize(width: 1180, height: 1000).windowStyle(.hiddenTitleBar)
        MenuBarExtra { MenuPanel().environmentObject(store).environment(\.locale, Locale(identifier: "it_IT")) } label: { Image(systemName: "square.stack.3d.up") }
            .menuBarExtraStyle(.window)
        Settings { ScrollView { SettingsView().padding(24) }.frame(width: 650, height: 750).environmentObject(store).preferredColorScheme(.dark) }
    }
}

struct MenuPanel: View {
    @EnvironmentObject var store: DeckStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(DeckTheme.mint)
                    Text("ModelDeck").font(.system(size: 16, weight: .semibold)); Spacer()
                    Text(store.machine.chip).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
                HStack(spacing: 10) {
                    mini("CPU", DeckFormat.percent(store.snapshot.cpu), DeckTheme.blue)
                    mini("RAM", DeckFormat.percent(store.snapshot.memoryPercent), DeckTheme.mint)
                    mini("GPU", DeckFormat.percent(store.snapshot.gpu), DeckTheme.purple)
                }
                UsageCard(usage: store.claude, compact: true)
                UsageCard(usage: store.codex, compact: true)
                HStack {
                    Label("\(store.inventory.models.count) modelli locali", systemImage: "cube").font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                    Spacer()
                    if let battery = store.snapshot.battery { Label(DeckFormat.percent(battery), systemImage: store.snapshot.charging ? "battery.100percent.bolt" : "battery.75percent").font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
                }
                Button("Apri cruscotto") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }.buttonStyle(.borderedProminent).tint(DeckTheme.mint).foregroundStyle(.black).frame(maxWidth: .infinity)
                HStack {
                    Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }.help("Impostazioni")
                    Spacer()
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Esci da ModelDeck")
                }.buttonStyle(.plain).foregroundStyle(DeckTheme.muted)
            }.padding(18)
        }.frame(width: 420).frame(maxHeight: 750).background(DeckTheme.background).preferredColorScheme(.dark).onAppear { store.start() }
    }
    private func mini(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9)).foregroundStyle(DeckTheme.muted)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(DeckTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}
