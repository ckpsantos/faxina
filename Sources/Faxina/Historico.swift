import SwiftUI

/// Um arquivo (ou pasta) que o app tirou do lugar. Cada um pode ser desfeito sozinho.
struct Registro: Identifiable, Codable, Hashable {
    enum Tipo: String, Codable {
        case lixeira, limpeza, drive, organizado

        var rotulo: String {
            switch self {
            case .lixeira: return "Lixeira"
            case .limpeza: return "Limpeza"
            case .drive: return "Upload no Drive"
            case .organizado: return "Organizado"
            }
        }
    }

    var id = UUID()
    let tipo: Tipo
    let data: Date
    let origem: String  // onde estava
    let atual: String  // onde está agora (Lixeira ou pasta do Drive)
    var tamanho: Int64?
    var detalhe: String?  // conta do Drive ou nome da limpeza
    var desfeito = false

    var nome: String { URL(fileURLWithPath: origem).lastPathComponent }

    var pasta: String {
        URL(fileURLWithPath: origem).deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var tamanhoOrdenavel: Int64 { tamanho ?? -1 }

    var acao: String { detalhe.map { "\(tipo.rotulo) · \($0)" } ?? tipo.rotulo }
}

@MainActor
final class Historico: ObservableObject {
    static let shared = Historico()

    @Published var registros: [Registro] = []
    @Published var desfazendo = Set<UUID>()
    @Published var aviso: String?
    @Published var versaoDisco = 0

    /// Chamado antes de trazer arquivos de volta do Drive, para o acompanhamento parar de liberá-los.
    var aoDesfazerDrive: ((Set<String>) -> Void)?

    private let arquivo: URL
    private let limite = 500

    private init() {
        let pasta = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Faxina")
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        arquivo = pasta.appendingPathComponent("historico-v2.json")
        if let dados = try? Data(contentsOf: arquivo),
            let salvos = try? JSONDecoder().decode([Registro].self, from: dados)
        {
            registros = salvos
        }
    }

    func registrar(
        _ tipo: Registro.Tipo, itens: [(origem: URL, atual: URL)],
        tamanhos: [URL: Int64] = [:], detalhe: String? = nil
    ) {
        guard !itens.isEmpty else { return }
        let agora = Date()
        let novos = itens.map {
            Registro(
                tipo: tipo, data: agora, origem: $0.origem.path, atual: $0.atual.path,
                tamanho: tamanhos[$0.origem], detalhe: detalhe)
        }
        registros.insert(contentsOf: novos, at: 0)
        if registros.count > limite { registros.removeLast(registros.count - limite) }
        salvar()
    }

    func desfazer(_ ids: Set<UUID>) {
        let alvos = registros.filter { ids.contains($0.id) && !$0.desfeito && !desfazendo.contains($0.id) }
        guard !alvos.isEmpty else { return }
        desfazendo.formUnion(alvos.map(\.id))
        aviso = nil
        aoDesfazerDrive?(Set(alvos.filter { $0.tipo == .drive }.map(\.atual)))
        Task {
            var falhas = 0
            for alvo in alvos {
                let voltou = await Task.detached { Historico.restaurar(alvo) }.value
                if voltou, let i = registros.firstIndex(where: { $0.id == alvo.id }) {
                    registros[i].desfeito = true
                } else if !voltou {
                    falhas += 1
                }
                desfazendo.remove(alvo.id)
                versaoDisco += 1
                salvar()
            }
            if falhas > 0 {
                aviso = "\(falhas) item(ns) não voltaram: já existe algo no lugar original, a Lixeira foi esvaziada ou o Google Drive está fechado."
            }
        }
    }

    /// Leva o item de volta ao lugar de origem, sem sobrescrever nada.
    nonisolated static func restaurar(_ registro: Registro) -> Bool {
        let fm = FileManager.default
        let atual = URL(fileURLWithPath: registro.atual)
        let origem = URL(fileURLWithPath: registro.origem)
        guard fm.fileExists(atPath: atual.path), !fm.fileExists(atPath: origem.path) else { return false }
        if registro.tipo == .drive, !baixar(atual) { return false }
        do {
            try fm.createDirectory(at: origem.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: atual, to: origem)
            return true
        } catch {
            // Item protegido pelo macOS (app de /Applications): o Finder move e pede a senha.
            guard registro.tipo == .lixeira,
                PeloFinder.mover(atual, para: origem.deletingLastPathComponent())
            else { return false }
            let chegou = origem.deletingLastPathComponent().appendingPathComponent(atual.lastPathComponent)
            if chegou.path != origem.path { try? fm.moveItem(at: chegou, to: origem) }
            return true
        }
    }

    /// Garante que o arquivo do Drive está baixado no Mac antes de tirá-lo de lá.
    nonisolated private static func baixar(_ url: URL) -> Bool {
        func baixado() -> Bool {
            let nova = URL(fileURLWithPath: url.path)
            let status = (try? nova.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus
            return status == nil || status == .current
        }
        if baixado() { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<900 {  // até 30 minutos
            Thread.sleep(forTimeInterval: 2)
            if baixado() { return true }
        }
        return false
    }

    private func salvar() {
        if let dados = try? JSONEncoder().encode(registros) {
            try? dados.write(to: arquivo, options: .atomic)
        }
    }
}

struct HistoricoView: View {
    @ObservedObject var model: Historico
    @State private var selecao = Set<UUID>()  // marcados no checkbox
    @State private var realce = Set<UUID>()  // linha clicada
    @State private var ordem = [KeyPathComparator(\Registro.data, order: .reverse)]

    /// Marcados que ainda dá para desfazer.
    private var selecionados: [Registro] {
        model.registros.filter { selecao.contains($0.id) && !$0.desfeito && !model.desfazendo.contains($0.id) }
    }

    private var pendentes: [Registro] { model.registros.filter { !$0.desfeito } }

    var body: some View {
        VStack(spacing: 0) {
            if model.registros.isEmpty {
                ContentUnavailableView(
                    "Nenhuma ação ainda", systemImage: "clock.arrow.circlepath",
                    description: Text("O que você mover para a Lixeira, limpar ou enviar ao Drive aparece aqui, arquivo por arquivo, e pode ser desfeito.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabela
            }
            Divider()
            rodape
        }
        .navigationTitle("Últimas ações")
    }

    private var tabela: some View {
        Table(model.registros.sorted(using: ordem), selection: $realce, sortOrder: $ordem) {
            TableColumn("") { r in
                Toggle("Marcar \(r.nome)", isOn: marcado(r.id))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(r.desfeito || model.desfazendo.contains(r.id))
            }
            .width(22)
            TableColumn("Arquivo", value: \.nome) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.nome).lineLimit(1)
                    Text("estava em \(r.pasta)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2)
                .opacity(r.desfeito ? 0.5 : 1)
            }
            TableColumn("Ação", value: \.acao) { r in
                Text(r.acao).lineLimit(1).opacity(r.desfeito ? 0.5 : 1)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Data", value: \.data) { r in
                Text(r.data.formatted(date: .abbreviated, time: .shortened))
                    .opacity(r.desfeito ? 0.5 : 1)
            }
            .width(130)
            TableColumn("Tamanho", value: \.tamanhoOrdenavel) { r in
                Text(r.tamanho.map(formatar) ?? "—").monospacedDigit()
            }
            .width(80)
            TableColumn("Situação") { r in
                if r.desfeito {
                    Text("Desfeito").foregroundStyle(.secondary)
                } else if model.desfazendo.contains(r.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Desfazendo…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Desfazer") { model.desfazer([r.id]) }
                }
            }
            .width(110)
        }
    }

    private func marcado(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selecao.contains(id) },
            set: { if $0 { selecao.insert(id) } else { selecao.remove(id) } })
    }

    private var todosMarcados: Binding<Bool> {
        Binding(
            get: { !pendentes.isEmpty && selecionados.count == pendentes.count },
            set: { selecao = $0 ? Set(pendentes.map(\.id)) : [] })
    }

    private var rodape: some View {
        HStack {
            Toggle("Marcar todos", isOn: todosMarcados)
                .toggleStyle(.checkbox)
                .disabled(pendentes.isEmpty)
            if let aviso = model.aviso {
                Label(aviso, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
            } else if selecionados.isEmpty {
                Text("\(pendentes.count) item(ns) que ainda dá para desfazer").foregroundStyle(.secondary)
            } else {
                Text("\(selecionados.count) selecionado(s) · \(formatar(selecionados.reduce(0) { $0 + ($1.tamanho ?? 0) }))")
            }
            Spacer()
            Button("Abrir Lixeira") {
                NSWorkspace.shared.open(
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
            }
            Button("Desfazer selecionados") {
                model.desfazer(Set(selecionados.map(\.id)))
                selecao.removeAll()
            }
            .disabled(selecionados.isEmpty)
        }
        .padding(12)
    }
}
