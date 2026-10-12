import SwiftUI

struct Sobra: Identifiable {
    let nome: String
    let descricao: String
    let caminho: String  // relativo à pasta pessoal
    /// true = o conteúdo se refaz sozinho e o app pode limpar; false = só mostra.
    let seguro: Bool
    var tamanho: Int64?

    var id: String { caminho }
    var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(caminho) }
}

enum Sobras {
    static let lista: [Sobra] = [
        Sobra(nome: "Caches de apps", descricao: "Arquivos temporários; os apps recriam quando precisam.",
              caminho: "Library/Caches", seguro: true),
        Sobra(nome: "Cache do npm", descricao: "Pacotes Node já baixados; baixa de novo se precisar.",
              caminho: ".npm/_cacache", seguro: true),
        Sobra(nome: "Cache do uv (Python)", descricao: "Pacotes Python já baixados; baixa de novo se precisar.",
              caminho: ".cache/uv", seguro: true),
        Sobra(nome: "Logs", descricao: "Registros antigos de apps.",
              caminho: "Library/Logs", seguro: true),
        Sobra(nome: "Downloads", descricao: "Tudo o que você baixou e ainda está na pasta.",
              caminho: "Downloads", seguro: false),
        Sobra(nome: "Projetos do CapCut", descricao: "Projetos de vídeo e mídias copiadas para dentro deles.",
              caminho: "Movies/CapCut", seguro: false),
        Sobra(nome: "Perfil do Chrome", descricao: "Histórico, extensões e dados de sites de todos os perfis.",
              caminho: "Library/Application Support/Google/Chrome", seguro: false),
        Sobra(nome: "Máquina virtual do Claude", descricao: "Usada pelo app Claude Desktop.",
              caminho: "Library/Application Support/Claude/vm_bundles", seguro: false),
        Sobra(nome: "Modelos de IA (Hugging Face)", descricao: "Modelos baixados por ferramentas de IA.",
              caminho: ".cache/huggingface", seguro: false),
        Sobra(nome: "Modelos do Whisper", descricao: "Modelos de transcrição usados nas edições de vídeo.",
              caminho: ".cache/whisper", seguro: false),
        Sobra(nome: "Modelos do Ollama", descricao: "Modelos de IA locais.",
              caminho: ".ollama", seguro: false),
    ]

    static func tamanho(de pasta: URL) -> Int64 {
        guard
            let itens = FileManager.default.enumerator(
                at: pasta, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in itens {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Manda o conteúdo da pasta para a Lixeira, mantendo a pasta. Pula o que é da Apple.
    static func limpar(_ pasta: URL) -> Descarte {
        let filhos =
            (try? FileManager.default.contentsOfDirectory(at: pasta, includingPropertiesForKeys: nil)) ?? []
        return moverParaLixeira(filhos.filter { !$0.lastPathComponent.hasPrefix("com.apple.") })
    }
}

@MainActor
final class SobrasModel: ObservableObject {
    @Published var itens = Sobras.lista
    @Published var medindo = false
    @Published var aviso: String?
    @Published var versaoDisco = 0

    func medir() {
        guard !medindo else { return }
        medindo = true
        for i in itens.indices { itens[i].tamanho = nil }  // mostra que está medindo de novo
        versaoDisco += 1
        Task {
            for i in itens.indices {
                let url = itens[i].url
                itens[i].tamanho = await Task.detached { Sobras.tamanho(de: url) }.value
            }
            medindo = false
        }
    }

    func limpar(_ item: Sobra) {
        guard item.seguro, let i = itens.firstIndex(where: { $0.id == item.id }) else { return }
        Task {
            let url = item.url
            let descarte = await Task.detached { Sobras.limpar(url) }.value
            let depois = await Task.detached { Sobras.tamanho(de: url) }.value
            itens[i].tamanho = depois
            Historico.shared.registrar(.limpeza, itens: descarte.movidos, detalhe: item.nome)
            aviso = descarte.falhas.isEmpty
                ? nil : "\(descarte.falhas.count) item(ns) de \(item.nome) estavam em uso e ficaram."
            versaoDisco += 1
        }
    }
}

struct SobrasView: View {
    @ObservedObject var model: SobrasModel
    @State private var paraLimpar: Sobra?

    var body: some View {
        VStack(spacing: 0) {
            EspacoDisco(gatilho: model.versaoDisco)
            Divider()
            List {
                Section("Pode limpar (se refaz sozinho)") {
                    ForEach(model.itens.filter(\.seguro)) { linha($0) }
                }
                Section("Vale revisar (só você sabe se ainda usa)") {
                    ForEach(model.itens.filter { !$0.seguro }) { linha($0) }
                }
            }
            if let aviso = model.aviso {
                Divider()
                Label(aviso, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .navigationTitle("Caches e sobras")
        .toolbar {
            Button("Atualizar", systemImage: "arrow.clockwise") { model.medir() }
                .labelStyle(.titleAndIcon)
                .disabled(model.medindo)
        }
        .onAppear { if model.itens.allSatisfy({ $0.tamanho == nil }) { model.medir() } }
        .confirmationDialog(
            "Limpar \(paraLimpar?.nome ?? "")?",
            isPresented: Binding(get: { paraLimpar != nil }, set: { if !$0 { paraLimpar = nil } }),
            presenting: paraLimpar
        ) { item in
            Button("Mover conteúdo para a Lixeira", role: .destructive) { model.limpar(item) }
        } message: { _ in
            Text("O conteúdo vai para a Lixeira. Feche os apps abertos antes, para que nada em uso seja movido.")
        }
    }

    private func linha(_ item: Sobra) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.nome)
                Text(item.descricao).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let tamanho = item.tamanho {
                Text(formatar(tamanho)).monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
            if item.seguro {
                Button("Limpar") { paraLimpar = item }
                    .disabled((item.tamanho ?? 0) == 0)
                    .frame(width: 130, alignment: .trailing)
            } else {
                Button("Abrir no Finder") { NSWorkspace.shared.open(item.url) }
                    .frame(width: 130, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
    }
}
