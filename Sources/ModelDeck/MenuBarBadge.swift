import AppKit
import CoreText
import SwiftUI
import ModelDeckCore

@MainActor enum MenuBarBadge {
    static func icon() -> NSImage? {
        let icon = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "ModelDeck")
        icon?.isTemplate = true; icon?.size = NSSize(width: 17, height: 18)
        return icon
    }

    /// Vector-backed template image: AppKit renders at the display's scale and menu bar contrast.
    static func image(for summary: MenuBarSummary, height: CGFloat = 22) -> NSImage {
        let height = max(20, min(24, height))
        let nameFont = NSFont.systemFont(ofSize: height >= 22 ? 9.5 : 9, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: height >= 22 ? 9.5 : 9, weight: .semibold)
        func line(_ text: String, font: NSFont) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]) as CFAttributedString)
        }
        let lines = summary.readings.map { (line($0.name, font: nameFont), line($0.value, font: valueFont)) }
        let columns = stride(from: 0, to: lines.count, by: 2).map { Array(lines[$0..<min($0 + 2, lines.count)]) }
        let widths = columns.map { rows -> (CGFloat, CGFloat) in
            (ceil(rows.map { CGFloat(CTLineGetTypographicBounds($0.0, nil, nil, nil)) }.max() ?? 0),
             ceil(rows.map { CGFloat(CTLineGetTypographicBounds($0.1, nil, nil, nil)) }.max() ?? 0))
        }
        let width = 24 + widths.reduce(CGFloat(0)) { $0 + $1.0 + 5 + $1.1 } + CGFloat(max(0, columns.count - 1)) * 10
        let symbol = icon()
        let result = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState(); defer { context.restoreGState() }
            symbol?.draw(in: NSRect(x: 0, y: (height - 18) / 2, width: 17, height: 18))
            context.textMatrix = .identity
            func draw(_ line: CTLine, x: CGFloat, bottom: CGFloat) {
                var ascent: CGFloat = 0, descent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                context.textPosition = CGPoint(x: x, y: bottom + (height / 2 - ascent - descent) / 2 + descent)
                CTLineDraw(line, context)
            }
            var x: CGFloat = 24
            for (index, rows) in columns.enumerated() {
                let (nameWidth, valueWidth) = widths[index]
                for (row, pair) in rows.enumerated() {
                    let bottom = rows.count == 1 ? height / 4 : row == 0 ? height / 2 : 0
                    draw(pair.0, x: x, bottom: bottom)
                    let actual = CGFloat(CTLineGetTypographicBounds(pair.1, nil, nil, nil))
                    draw(pair.1, x: x + nameWidth + 5 + valueWidth - actual, bottom: bottom)
                }
                x += nameWidth + 5 + valueWidth + 10
            }
            return true
        }
        result.isTemplate = true; result.accessibilityDescription = summary.title
        return result
    }
}

struct MenuBarLayoutsPreview: View {
    @EnvironmentObject var store: DeckStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Quote nella barra dei menu").font(.system(size: 22, weight: .semibold))
            StatusPill(text: "ANTEPRIMA · DATI FITTIZI", color: DeckTheme.amber)
            ForEach(MenuBarLayout.allCases, id: \.self) { layout in
                let summary = summary(layout)
                DeckCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(layout.title).font(.system(size: 12, weight: .semibold))
                        HStack(spacing: 7) {
                            if layout == .twoRows { Image(nsImage: MenuBarBadge.image(for: summary)).renderingMode(.template).fixedSize() }
                            else { Image(systemName: "square.stack.3d.up"); Text(summary.title).font(.system(size: 11, weight: .medium)).monospacedDigit() }
                            Spacer()
                        }.frame(height: 24)
                    }
                }
            }
            Text("Le quote dell’esempio sono rimanenti. Finestra, reset e aggiornamento sono disponibili nel tooltip e nel pannello.")
                .font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
        }.padding(24).frame(width: 650, height: 490).background(DeckTheme.background).foregroundStyle(DeckTheme.foreground).deckAppearance(.light)
    }
    private func summary(_ layout: MenuBarLayout) -> MenuBarSummary {
        var options = MenuBarOptions(); options.metrics = [.claude, .openAI]; options.quotaStyle = .remaining; options.layout = layout
        var claude = store.claude, openAI = store.codex
        for i in claude.windows.indices { claude.windows[i].usedPercent = 100 }
        for i in openAI.windows.indices { openAI.windows[i].usedPercent = 1 }
        return .render(options: options, snapshot: store.snapshot, claude: claude, openAI: openAI)
    }
}
