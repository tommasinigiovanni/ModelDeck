import SwiftUI
import ModelDeckCore

@main enum Launcher {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--check-search"), args.indices.contains(index + 1) {
            Task {
                do {
                    let format: HubSearchFormat = args.contains("--gguf") ? .gguf : args.contains("--mlx") ? .mlx : .all
                    let found = try await HuggingFaceCatalog.search(args[index + 1], format: format)
                    let data = try JSONSerialization.data(withJSONObject: ["count": found.count, "repositories": found.prefix(5).map(\.repository)] as [String: Any], options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self)); exit(0)
                } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run(); return
        }
        if let index = args.firstIndex(of: "--check-fit"), args.indices.contains(index + 1) {
            Task {
                do {
                    let model = try await HuggingFaceCatalog.fetch(args[index + 1])
                    let machine = SystemMonitor.machine()
                    let variant = model.variants.first { $0.name.lowercased().contains("q4_k_m") } ?? model.variants.first
                    let estimate = MemoryEstimator.estimate(weights: Double(variant?.bytes ?? 0), profile: model.profile, context: 4096, physicalMemory: Double(machine.memory), metalLimit: machine.unifiedMemory ? machine.metalWorkingSet.map { Double($0) } : nil)
                    let object: [String: Any] = ["repository": model.repository, "variants": model.variants.count, "selected": variant?.name ?? "none", "profile_complete": model.profile.complete, "layers": model.profile.layers, "kv_heads": model.profile.kvHeads, "verdict": estimate.verdict.rawValue, "budget_gib": estimate.budget / gibibyte, "total_gib": (estimate.total ?? estimate.minimum) / gibibyte]
                    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]); print(String(decoding: data, as: UTF8.self)); exit(0)
                } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run(); return
        }
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
                let processes = await ProcessMonitor().sample()
                var object: [String: Any] = ["chip": SystemMonitor.machine().chip, "memory_used": stats.memoryUsed, "memory_total": stats.memoryTotal, "models": inventory.models.count, "claude_windows": ClaudeUsage.read().windows.count]
                object["cpu_percent"] = stats.cpu; object["gpu_percent"] = stats.gpu
                object["process_count"] = processes.count; object["gpu_clients"] = processes.filter(\.gpuClient).count
                do {
                    let usage = try await CodexUsage.read()
                    object["codex_windows"] = usage.windows.map { ["window": $0.title, "used_percent": $0.usedPercent] as [String: Any] }
                    object["menu_bar_title"] = MenuBarSummary.render(options: .load(), snapshot: stats, claude: ClaudeUsage.read(), openAI: usage).title
                }
                catch { object["codex_error"] = error.localizedDescription }
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
                exit(0)
            }
            RunLoop.main.run(); return
        }
        if let index = args.firstIndex(of: "--preview"), args.indices.contains(index + 1) {
            renderPreview(to: URL(fileURLWithPath: args[index + 1])); return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let store = DeckStore()
        if args.contains("--demo") || args.contains("--check-menu") { store.useDemo() }
        let delegate = DeckApplicationDelegate(store: store)
        application.delegate = delegate
        if args.contains("--check-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let result = delegate.checkMenuLifecycle()
                if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys), let output = String(data: data, encoding: .utf8) { print(output) }
                exit(result.values.allSatisfy { $0 } ? 0 : 1)
            }
        }
        withExtendedLifetime(delegate) { application.run() }
    }

    @MainActor private static func renderPreview(to url: URL) {
        _ = NSApplication.shared
        let store = DeckStore(); store.useDemo()
        let section = CommandLine.arguments.contains("--credits") ? "credits" : CommandLine.arguments.contains("--processes") ? "processes" : CommandLine.arguments.contains("--settings") ? "settings" : "overview"
        let theme: DeckAppearance = CommandLine.arguments.contains("--light") ? .light : .dark
        let fit = CommandLine.arguments.contains("--fit")
        if CommandLine.arguments.contains("--menu-bar") {
            let hosting = NSHostingView(rootView: MenuBarLayoutsPreview().environmentObject(store))
            writePreview(hosting, to: url, width: 650, height: 490); return
        }
        if fit { store.machine.memory = UInt64(16 * gibibyte); store.machine.metalWorkingSet = UInt64(12 * gibibyte); store.snapshot.memoryTotal = store.machine.memory; store.snapshot.memoryUsed = UInt64(8 * gibibyte) }
        let content: AnyView = fit ? AnyView(ModelFitView(demonstration: true, demonstrateSearch: CommandLine.arguments.contains("--search"), appearanceOverride: theme).environmentObject(store).environment(\.locale, Locale(identifier: "it_IT"))) : AnyView(Dashboard(initialSection: section, appearanceOverride: theme).environmentObject(store).environment(\.locale, Locale(identifier: "it_IT")))
        let hosting = NSHostingView(rootView: content)
        let height = fit ? 850 : section == "processes" ? 940 : section == "settings" ? 1500 : section == "credits" ? 850 : 1360
        writePreview(hosting, to: url, width: fit ? 840 : 1180, height: CGFloat(height))
    }
    @MainActor private static func writePreview<Content: View>(_ hosting: NSHostingView<Content>, to url: URL, width: CGFloat, height: CGFloat) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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

struct MenuPanel: View {
    @EnvironmentObject var store: DeckStore
    var openDashboard: () -> Void
    var openProcesses: () -> Void
    var openSettings: () -> Void
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
                HStack {
                    Button("Apri cruscotto", action: openDashboard).buttonStyle(.borderedProminent).tint(DeckTheme.mint)
                    Button("Processi", action: openProcesses).buttonStyle(.bordered)
                }
                HStack {
                    Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }.help("Impostazioni")
                    Spacer()
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Esci da ModelDeck")
                }.buttonStyle(.plain).foregroundStyle(DeckTheme.muted)
            }.padding(18)
        }.frame(width: 420, height: 680).background(DeckTheme.background).foregroundStyle(DeckTheme.foreground).deckAppearance().onAppear { store.start() }
    }
    private func mini(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9)).foregroundStyle(DeckTheme.muted)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(DeckTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}
