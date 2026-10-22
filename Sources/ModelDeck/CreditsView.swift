import SwiftUI

enum ProjectLinks {
    static let author = URL(string: "https://github.com/tommasinigiovanni")!
    static let repository = URL(string: "https://github.com/tommasinigiovanni/ModelDeck")!
    static let issues = repository.appendingPathComponent("issues")
    static let license = repository.appendingPathComponent("blob/main/LICENSE")
}

struct CreditsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DeckCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 15) {
                        Image(systemName: "square.stack.3d.up.fill").font(.system(size: 38)).foregroundStyle(DeckTheme.mint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ModelDeck").font(.system(size: 25, weight: .semibold)).tracking(-0.7)
                            Text("Il Mac, i modelli locali e i tuoi strumenti AI.").font(.system(size: 12)).foregroundStyle(DeckTheme.muted)
                        }
                    }
                    Divider()
                    Text("Sviluppato da Giovanni Tommasini").font(.system(size: 16, weight: .semibold))
                    creditLink("Giovanni Tommasini su GitHub", detail: "github.com/tommasinigiovanni", symbol: "person.crop.circle", url: ProjectLinks.author)
                    creditLink("Repository del progetto", detail: "Codice sorgente e aggiornamenti", symbol: "chevron.left.forwardslash.chevron.right", url: ProjectLinks.repository)
                    creditLink("Segnalazioni e proposte", detail: "Issue su GitHub", symbol: "bubble.left.and.bubble.right", url: ProjectLinks.issues)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Licenza e riferimenti").font(.system(size: 15, weight: .semibold))
                    Link("Licenza MIT", destination: ProjectLinks.license).font(.system(size: 12))
                    Text("I dati dei servizi provengono dalle rispettive integrazioni. Il calcolatore usa le dimensioni dei pesi e i metadati dei modelli; il risultato è una stima di memoria per inferenza.")
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 18) {
                        Link("Hugging Face", destination: URL(string: "https://huggingface.co/docs/hub/api")!)
                        Link("Cache KV", destination: URL(string: "https://huggingface.co/blog/kv-cache-quantization")!)
                        Link("Calcolatore ApX", destination: URL(string: "https://apxml.com/tools/vram-calculator")!)
                    }.font(.system(size: 11))
                    Text("Nome e icona sono provvisori.").font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
            }
        }.tint(DeckTheme.mint)
    }
    private func creditLink(_ title: String, detail: String, symbol: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 30).foregroundStyle(DeckTheme.mint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(DeckTheme.foreground)
                    Text(detail).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
            }.padding(12).background(DeckTheme.subtle.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}
