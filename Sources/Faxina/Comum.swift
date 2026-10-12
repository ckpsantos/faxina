import SwiftUI

func formatar(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

struct Descarte {
    var movidos: [(origem: URL, atual: URL)] = []  // atual = onde ficou dentro da Lixeira
    var falhas: [URL] = []
}

/// Move para a Lixeira (nunca apaga direto).
func moverParaLixeira(_ urls: [URL]) -> Descarte {
    var descarte = Descarte()
    for url in urls {
        var naLixeira: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &naLixeira)
            descarte.movidos.append((url, (naLixeira as URL?) ?? url))
        } catch {
            descarte.falhas.append(url)
        }
    }
    return descarte
}

/// Pede ao Finder para mover itens que o macOS protege (apps de /Applications).
/// É o Finder que mostra o pedido de senha de administrador, como ao arrastar para a Lixeira.
enum PeloFinder {
    private static func texto(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func executar(_ comando: String) -> String? {
        let fonte = """
            with timeout of 600 seconds
              tell application "Finder"
                set r to \(comando)
                return POSIX path of (r as alias)
              end tell
            end timeout
            """
        var erro: NSDictionary?
        let resultado = NSAppleScript(source: fonte)?.executeAndReturnError(&erro)
        return erro == nil ? resultado?.stringValue : nil
    }

    /// Devolve onde o item ficou dentro da Lixeira, ou nil se não foi (senha cancelada, por exemplo).
    static func moverParaLixeira(_ url: URL) -> URL? {
        executar("delete (POSIX file \(texto(url.path)) as alias)").map { URL(fileURLWithPath: $0) }
    }

    static func mover(_ url: URL, para pasta: URL) -> Bool {
        executar("move (POSIX file \(texto(url.path)) as alias) to (POSIX file \(texto(pasta.path)) as alias)") != nil
    }
}

func mostrarNoFinder(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}

/// Faixa com o espaço livre do disco. Mude `gatilho` para recalcular.
struct EspacoDisco: View {
    let gatilho: Int
    @State private var livre: Int64 = 0
    @State private var total: Int64 = 0
    @State private var medidoEm = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(formatar(livre)) livres de \(formatar(total))")
                    .font(.headline)
                Spacer()
                Text("Medido às \(medidoEm.formatted(date: .omitted, time: .standard)). O espaço só é liberado ao esvaziar a Lixeira ou quando um upload termina.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: total > 0 ? Double(total - livre) / Double(total) : 0)
                .tint(total > 0 && Double(livre) / Double(total) < 0.1 ? .red : .accentColor)
        }
        .padding()
        .onAppear(perform: medir)
        .onChange(of: gatilho) { medir() }
    }

    private func medir() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let v = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        livre = v?.volumeAvailableCapacityForImportantUsage ?? 0
        total = Int64(v?.volumeTotalCapacity ?? 0)
        medidoEm = Date()
    }
}
