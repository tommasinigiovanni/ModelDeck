import SwiftUI
import ModelDeckCore

struct MenuBarSettingsView: View {
    @EnvironmentObject var store: DeckStore
    @AppStorage(MenuBarOptions.defaultsKey) private var rawOptions = MenuBarOptions().encoded
    private var options: MenuBarOptions { .decode(rawOptions) }
    private var summary: MenuBarSummary { .render(options: options, snapshot: store.snapshot, claude: store.claude, openAI: store.codex) }

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Barra dei menu").font(.system(size: 15, weight: .semibold))
                Text("Scegli i valori da affiancare all’icona. Disattivali tutti per mostrare solo l’icona.")
                    .font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
                    ForEach(MenuBarMetric.allCases, id: \.self) { metric in Toggle(metric.title, isOn: metricBinding(metric)).toggleStyle(.checkbox) }
                }.font(.system(size: 11))
                HStack {
                    Text("Valore RAM").frame(width: 115, alignment: .leading)
                    Picker("Valore RAM", selection: optionBinding(\.memoryStyle)) {
                        ForEach(MenuBarMemoryStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().disabled(!options.metrics.contains(.memory))
                }.font(.system(size: 11))
                HStack {
                    Text("Percentuale quote").frame(width: 115, alignment: .leading)
                    Picker("Percentuale quote", selection: optionBinding(\.quotaStyle)) {
                        ForEach(MenuBarQuotaStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }.font(.system(size: 11))
                windowPicker("Finestra Claude", metric: .claude, usage: store.claude, selection: optionBinding(\.claudeWindowID))
                windowPicker("Finestra OpenAI", metric: .openAI, usage: store.codex, selection: optionBinding(\.openAIWindowID))
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up")
                    if !summary.title.isEmpty { Text(summary.title).monospacedDigit() }
                    Spacer(minLength: 0)
                }.font(.system(size: 11, weight: .medium)).padding(12)
                    .background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 9)).help(summary.tooltip)
                    .accessibilityLabel("Anteprima barra dei menu. " + summary.tooltip)
                Text("CL = Claude Code · OA = OpenAI / Codex · h = ore · g = giorni. Quote \(options.quotaStyle == .used ? "utilizzate" : "rimanenti"). * = ultimo dato da aggiornare; — = non disponibile. Le modifiche sono immediate.")
                    .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricBinding(_ metric: MenuBarMetric) -> Binding<Bool> {
        Binding(get: { options.metrics.contains(metric) }, set: { enabled in
            var next = options
            if enabled { next.metrics.insert(metric) } else { next.metrics.remove(metric) }
            rawOptions = next.encoded
        })
    }
    private func optionBinding<T>(_ keyPath: WritableKeyPath<MenuBarOptions, T>) -> Binding<T> {
        Binding(get: { options[keyPath: keyPath] }, set: { value in
            var next = options; next[keyPath: keyPath] = value; rawOptions = next.encoded
        })
    }
    private func windowPicker(_ title: String, metric: MenuBarMetric, usage: SubscriptionUsage, selection: Binding<String>) -> some View {
        let automatic = MenuBarSummary.selectedWindow(in: usage, id: "", provider: metric)
        return HStack {
            Text(title).frame(width: 115, alignment: .leading)
            Picker(title, selection: selection) {
                Text("Automatica" + (automatic.map { " · " + $0.title } ?? "")).tag("")
                ForEach(usage.windows) { window in Text(window.title).tag(window.id) }
                if !selection.wrappedValue.isEmpty, !usage.windows.contains(where: { $0.id == selection.wrappedValue }) {
                    Text("Finestra salvata · in attesa di dati").tag(selection.wrappedValue)
                }
            }.labelsHidden().disabled(!options.metrics.contains(metric))
        }.font(.system(size: 11))
    }
}
