import SwiftUI

/// Minúsculas, sem acento, com hífen e sublinhado virando espaço.
private func normalizar(_ texto: String) -> String {
    texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .trimmingCharacters(in: .whitespaces)
}

struct Regra: Identifiable, Codable, Hashable {
    var id = UUID()
    var palavras: String  // separadas por vírgula
    var destino: String  // caminho da pasta
    var ativa = true

    /// Palavras curtas demais pegariam arquivo demais.
    var chaves: [String] {
        palavras.split(separator: ",").map { normalizar(String($0)) }.filter { $0.count >= 3 }
    }

    var destinoCurto: String {
        destino.replacingOccurrences(of: NSHomeDirectory() + "/Projetos/", with: "")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

struct Proposta: Identifiable, Hashable {
    let url: URL
    let tamanho: Int64
    let modificado: Date
    let regra: Regra?

    var id: URL { url }
    var nome: String { url.lastPathComponent }
    var destinoTexto: String { regra?.destinoCurto ?? "" }
}

enum Organizador {
    static let origem = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

    /// A palavra precisa aparecer inteira: "ata" não casa com "data".
    static func contem(_ nome: String, _ chave: String) -> Bool {
        var busca = nome.startIndex..<nome.endIndex
        while let r = nome.range(of: chave, range: busca) {
            let antes = r.lowerBound == nome.startIndex ? nil : nome[nome.index(before: r.lowerBound)]
            let depois = r.upperBound == nome.endIndex ? nil : nome[r.upperBound]
            if !(antes?.isLetter ?? false) && !(depois?.isLetter ?? false) { return true }
            busca = r.upperBound..<nome.endIndex
        }
        return false
    }

    /// Lê os arquivos soltos do Downloads e diz para onde cada um iria. Só leitura.
    static func analisar(_ regras: [Regra]) -> [Proposta] {
        let fm = FileManager.default
        let chaves: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        let ativas = regras.filter { $0.ativa && !$0.destino.isEmpty }
        let itens = (try? fm.contentsOfDirectory(at: origem, includingPropertiesForKeys: Array(chaves), options: [.skipsHiddenFiles])) ?? []
        let emAndamento: Set<String> = ["crdownload", "download", "part", "partial"]
        return itens.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: chaves), v.isRegularFile == true,
                !emAndamento.contains(url.pathExtension.lowercased())
            else { return nil }
            let modificado = v.contentModificationDate ?? .distantPast
            guard modificado < Date().addingTimeInterval(-120) else { return nil }  // pode estar em uso

            let nome = normalizar(url.deletingPathExtension().lastPathComponent)
            var melhor: Regra?
            var tamanhoChave = 0
            for regra in ativas {
                for chave in regra.chaves where chave.count > tamanhoChave && contem(nome, chave) {
                    melhor = regra
                    tamanhoChave = chave.count
                }
            }
            return Proposta(
                url: url, tamanho: Int64(v.totalFileAllocatedSize ?? 0), modificado: modificado, regra: melhor)
        }
    }

    /// Move para a pasta da regra, sem sobrescrever: "arquivo.pdf" vira "arquivo (2).pdf".
    static func mover(_ url: URL, para pasta: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: pasta, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var destino = pasta.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: destino.path) {
            destino = pasta.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        try fm.moveItem(at: url, to: destino)
        return destino
    }
}

@MainActor
final class OrganizadorModel: ObservableObject {
    @Published var regras: [Regra] = [] { didSet { salvar() } }
    @Published var propostas: [Proposta] = []
    @Published var analisando = false
    @Published var jaAnalisou = false
    @Published var aviso: String?
    @Published var atualizadoEm: Date?

    private let arquivo: URL

    init() {
        let pasta = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Faxina")
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        arquivo = pasta.appendingPathComponent("regras.json")
        if let dados = try? Data(contentsOf: arquivo),
            let salvas = try? JSONDecoder().decode([Regra].self, from: dados)
        {
            regras = salvas
        }
        // Sem arquivo, começa sem regras: cada pessoa cria as suas (veja CLAUDE.md).
    }

    private func salvar() {
        if let dados = try? JSONEncoder().encode(regras) {
            try? dados.write(to: arquivo, options: .atomic)
        }
    }

    func analisar() {
        guard !analisando else { return }
        analisando = true
        aviso = nil
        let regras = regras
        Task {
            propostas = await Task.detached(priority: .userInitiated) { Organizador.analisar(regras) }.value
            analisando = false
            jaAnalisou = true
            atualizadoEm = Date()
        }
    }

    func organizar(_ escolhidas: [Proposta]) {
        var pares: [(origem: URL, atual: URL)] = []
        var tamanhos: [URL: Int64] = [:]
        var falhas = 0
        // Um registro por pasta de destino, para o histórico mostrar para onde cada arquivo foi.
        for (destino, grupo) in Dictionary(grouping: escolhidas.filter { $0.regra != nil }, by: { $0.regra!.destino }) {
            pares.removeAll()
            for proposta in grupo {
                do {
                    let novo = try Organizador.mover(proposta.url, para: URL(fileURLWithPath: destino))
                    pares.append((proposta.url, novo))
                    tamanhos[proposta.url] = proposta.tamanho
                } catch {
                    falhas += 1
                }
            }
            Historico.shared.registrar(
                .organizado, itens: pares, tamanhos: tamanhos, detalhe: grupo[0].regra!.destinoCurto)
            let movidos = Set(pares.map(\.origem))
            propostas.removeAll { movidos.contains($0.url) }
        }
        aviso = falhas == 0 ? nil : "\(falhas) arquivo(s) não puderam ser movidos e ficaram no Downloads."
    }
}

struct OrganizadorView: View {
    @ObservedObject var model: OrganizadorModel
    @State private var selecao = Set<URL>()  // marcados no checkbox
    @State private var realce = Set<URL>()  // linha clicada
    @State private var semRegra = false
    @State private var editandoRegras = false
    @State private var confirmando = false
    @State private var ordem = [KeyPathComparator(\Proposta.destinoTexto)]

    private var visiveis: [Proposta] {
        model.propostas.filter { ($0.regra == nil) == semRegra }.sorted(using: ordem)
    }

    private var selecionados: [Proposta] {
        semRegra ? [] : visiveis.filter { selecao.contains($0.url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            conteudo
            Divider()
            rodape
        }
        .navigationTitle("Organizador")
        .toolbar {
            Picker("Mostrar", selection: $semRegra) {
                Text("Com regra").tag(false)
                Text("Sem regra").tag(true)
            }
            .pickerStyle(.segmented)
            Button("Regras", systemImage: "list.bullet") { editandoRegras = true }
                .labelStyle(.titleAndIcon)
            Button("Atualizar", systemImage: "arrow.clockwise") {
                realce.removeAll()
                model.analisar()
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.analisando)
        }
        .onAppear { if !model.jaAnalisou { model.analisar() } }
        .sheet(isPresented: $editandoRegras, onDismiss: { model.analisar() }) {
            RegrasView(model: model)
        }
        .confirmationDialog(
            "Mover \(selecionados.count) arquivo(s) do Downloads para as pastas das regras?",
            isPresented: $confirmando
        ) {
            Button("Organizar") {
                model.organizar(selecionados)
                selecao.removeAll()
            }
        } message: {
            Text("Nada é sobrescrito, e dá para desfazer arquivo por arquivo em Últimas ações.")
        }
    }

    @ViewBuilder
    private var conteudo: some View {
        if model.analisando {
            VStack(spacing: 12) {
                ProgressView()
                Text("Lendo o Downloads…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.regras.isEmpty && !semRegra {
            ContentUnavailableView {
                Label("Crie suas regras", systemImage: "folder.badge.plus")
            } description: {
                Text("Uma regra liga uma palavra do nome do arquivo a uma pasta de destino. Ex.: \"contrato\" vai para Documentos/Contratos.")
            } actions: {
                Button("Criar regras") { editandoRegras = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if visiveis.isEmpty {
            ContentUnavailableView(
                semRegra ? "Todo arquivo tem regra" : "Nada para organizar",
                systemImage: "checkmark.circle",
                description: Text(
                    semRegra
                        ? "Nenhum arquivo solto do Downloads ficou sem regra."
                        : "Nenhum arquivo solto do Downloads casa com as regras. Veja a aba Sem regra ou edite as Regras."))
        } else {
            Table(visiveis, selection: $realce, sortOrder: $ordem) {
                TableColumn("") { p in
                    Toggle("Marcar \(p.nome)", isOn: marcado(p.url))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(p.regra == nil)
                }
                .width(22)
                TableColumn("Arquivo", value: \.nome) { p in
                    Text(p.nome).lineLimit(1)
                }
                TableColumn("Vai para", value: \.destinoTexto) { p in
                    Text(p.regra == nil ? "—" : p.destinoTexto).lineLimit(1)
                        .foregroundStyle(p.regra == nil ? .secondary : .primary)
                }
                .width(min: 140, ideal: 240)
                TableColumn("Tamanho", value: \.tamanho) { p in
                    Text(formatar(p.tamanho)).monospacedDigit()
                }
                .width(80)
                TableColumn("Modificado", value: \.modificado) { p in
                    Text(p.modificado.formatted(date: .abbreviated, time: .omitted))
                }
                .width(100)
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                Button("Mostrar no Finder") { mostrarNoFinder(Array(urls)) }
            } primaryAction: { urls in
                mostrarNoFinder(Array(urls))
            }
        }
    }

    private func marcado(_ url: URL) -> Binding<Bool> {
        Binding(
            get: { selecao.contains(url) },
            set: { if $0 { selecao.insert(url) } else { selecao.remove(url) } })
    }

    private var todosMarcados: Binding<Bool> {
        Binding(
            get: { !visiveis.isEmpty && selecionados.count == visiveis.count },
            set: { selecao = $0 ? Set(visiveis.map(\.url)) : [] })
    }

    private var rodape: some View {
        HStack {
            Toggle("Marcar todos", isOn: todosMarcados)
                .toggleStyle(.checkbox)
                .disabled(semRegra || visiveis.isEmpty)
            if let aviso = model.aviso {
                Label(aviso, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if selecionados.isEmpty {
                Text("\(visiveis.count) arquivos · \(formatar(visiveis.reduce(0) { $0 + $1.tamanho }))\(model.atualizadoEm.map { " · atualizado às \($0.formatted(date: .omitted, time: .standard))" } ?? "")")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(selecionados.count) selecionado(s) · \(formatar(selecionados.reduce(0) { $0 + $1.tamanho }))")
            }
            Spacer()
            Button("Organizar selecionados") { confirmando = true }
                .buttonStyle(.borderedProminent)
                .disabled(selecionados.isEmpty)
        }
        .padding(12)
    }
}

struct RegrasView: View {
    @ObservedObject var model: OrganizadorModel
    @Environment(\.dismiss) private var fechar

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Regras do Organizador").font(.title3.bold())
                Text("Arquivo do Downloads cujo nome contém uma das palavras vai para a pasta da regra. Separe as palavras por vírgula; se duas regras casarem, ganha a palavra mais longa.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            List {
                ForEach($model.regras) { $regra in
                    HStack(spacing: 10) {
                        Toggle("Ativa", isOn: $regra.ativa).labelsHidden()
                        TextField("palavras, separadas por vírgula", text: $regra.palavras)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 230)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(regra.destino.isEmpty ? "Escolha a pasta" : regra.destinoCurto)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(regra.destino.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Escolher…") {
                            if let pasta = escolherPasta() { regra.destino = pasta.path }
                        }
                        Button("Remover", systemImage: "trash", role: .destructive) {
                            model.regras.removeAll { $0.id == regra.id }
                        }
                        .labelStyle(.iconOnly)
                    }
                    .padding(.vertical, 2)
                }
            }
            Divider()
            HStack {
                Button("Nova regra", systemImage: "plus") {
                    model.regras.append(Regra(palavras: "", destino: ""))
                }
                Spacer()
                Button("Concluir") { fechar() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 760, height: 460)
    }

    private func escolherPasta() -> URL? {
        let painel = NSOpenPanel()
        painel.canChooseDirectories = true
        painel.canChooseFiles = false
        painel.canCreateDirectories = true
        painel.prompt = "Escolher"
        return painel.runModal() == .OK ? painel.url : nil
    }
}
