import SwiftUI

enum DeckAppearance: String, CaseIterable {
    case system, light, dark
    var title: String { switch self { case .system: "Sistema"; case .light: "Chiaro"; case .dark: "Scuro" } }
    var scheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    var native: NSAppearance? { switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) } }
}

struct DeckAppearanceModifier: ViewModifier {
    @AppStorage("appearance") private var appearance = DeckAppearance.system.rawValue
    var override: DeckAppearance? = nil
    func body(content: Content) -> some View {
        content.preferredColorScheme((override ?? DeckAppearance(rawValue: appearance) ?? .system).scheme)
            .onAppear { apply() }.onChange(of: appearance) { _, _ in apply() }
    }
    private func apply() { NSApp.appearance = (override ?? DeckAppearance(rawValue: appearance) ?? .system).native }
}

extension View {
    func deckAppearance(_ override: DeckAppearance? = nil) -> some View { modifier(DeckAppearanceModifier(override: override)) }
}
