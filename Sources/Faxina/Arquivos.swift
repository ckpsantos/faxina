import CoreServices
import SwiftUI

struct ArquivoPesado: Identifiable, Hashable {
    let url: URL
    let tamanho: Int64
    let ultimoUso: Date?  // última abertura registrada pelo Spotlight
    let modificado: Date

    var id: URL { url }
    var nome: String { url.lastPathComponent }

    var pasta: String {
        url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var referencia: Date { max(ultimoUso ?? .distantPast, modificado) }

    /// Sem abrir nem modificar há 6 meses ou mais.
    var parado: Bool { referencia < Date().addingTimeInterval(-182 * 86_400) }

    var textoUso: String {
        let quando = referencia.formatted(.relative(presentation: .named))
        return (ultimoUso ?? .distantPast) >= modificado ? "aberto \(quando)" : "modificado \(quando)"
    }
}

enum Varredura {
    /// Arquivos a partir de `minimo` bytes na pasta pessoal. Só leitura.
    /// Fica de fora: ~/Library, pastas ocultas e node_modules.
    static func arquivosPesados(
        minimo: Int64 = 100 * 1024 * 1024,
        aoEntrar: (String) -> Void
    ) -> [ArquivoPesado] {
        let fm = FileManager.default
        let chaves: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        ]
        var achados: [ArquivoPesado] = []

        func avaliar(_ url: URL) {
            guard let v = try? url.resourceValues(forKeys: chaves),
                v.isRegularFile == true,
                let tamanho = v.totalFileAllocatedSize, Int64(tamanho) >= minimo
            else { return }
            let uso = NSMetadataItem(url: url)?
                .value(forAttribute: kMDItemLastUsedDate as String) as? Date
            achados.append(
                ArquivoPesado(
                    url: url, tamanho: Int64(tamanho), ultimoUso: uso,
                    modificado: v.contentModificationDate ?? .distantPast))
        }

        let raizes =
            (try? fm.contentsOfDirectory(
                at: fm.homeDirectoryForCurrentUser, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []

        for raiz in raizes where raiz.lastPathComponent != "Library" {
            aoEntrar(raiz.lastPathComponent)
            avaliar(raiz)
            guard
                let itens = fm.enumerator(
                    at: raiz, includingPropertiesForKeys: Array(chaves),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in itens {
                if url.lastPathComponent == "node_modules" {
                    itens.skipDescendants()
                    continue
                }
                avaliar(url)
            }
        }
        return achados.sorted { $0.tamanho > $1.tamanho }
    }
}

extension Varredura {
    /// Lista fictícia para capturas de tela e demonstração (abra com FAXINA_DEMO=1).
    /// Nenhum arquivo real aparece, e nenhum destes existe no disco.
    static var exemplo: [ArquivoPesado] {
        let casa = FileManager.default.homeDirectoryForCurrentUser
        let itens: [(String, Double, Int, Bool)] = [  // caminho, GB, dias parado, aberto?
            ("Movies/Viagem Chapada 2024.mov", 4.21, 610, true),
            ("Downloads/Instalador macOS.dmg", 3.08, 240, false),
            ("Movies/Gravação de tela 14-03.mov", 1.84, 380, true),
            ("Downloads/curso-fotografia-modulo-3.zip", 1.22, 95, false),
            ("Documents/Backup iPhone antigo.zip", 0.98, 1100, false),
            ("Downloads/apresentacao-final-v7.key", 0.64, 12, true),
            ("Movies/Aniversário 2023.mp4", 0.52, 720, true),
            ("Downloads/dataset-treino.csv", 0.41, 30, false),
            ("Documents/Projeto casa - plantas.pdf", 0.23, 200, true),
            ("Downloads/podcast-episodio-12.wav", 0.18, 3, false),
        ]
        return itens.map { caminho, gb, dias, aberto in
            let quando = Date().addingTimeInterval(-Double(dias) * 86_400)
            return ArquivoPesado(
                url: casa.appendingPathComponent(caminho), tamanho: Int64(gb * 1_000_000_000),
                ultimoUso: aberto ? quando : nil, modificado: aberto ? quando.addingTimeInterval(-86_400) : quando)
        }
    }
}

@MainActor
final class ArquivosModel: ObservableObject {
    @Published var arquivos: [ArquivoPesado] = []
    @Published var varrendo = false
    @Published var jaVarreu = false
    @Published var atualizadoEm: Date?
    @Published var pastaAtual = ""
    @Published var aviso: String?
    @Published var versaoDisco = 0

    func varrer() {
        guard !varrendo else { return }
        if ProcessInfo.processInfo.environment["FAXINA_DEMO"] != nil {
            arquivos = Varredura.exemplo
            jaVarreu = true
            atualizadoEm = Date()
            return
        }
        varrendo = true
        aviso = nil
        Task {
            let resultado = await Task.detached(priority: .userInitiated) {
                Varredura.arquivosPesados { nome in
                    Task { @MainActor in self.pastaAtual = nome }
                }
            }.value
            arquivos = resultado
            varrendo = false
            jaVarreu = true
            atualizadoEm = Date()
        }
    }

    func remover(_ urls: Set<URL>) {
        arquivos.removeAll { urls.contains($0.url) }
    }

    func enviarParaLixeira(_ urls: Set<URL>) {
        let descarte = moverParaLixeira(Array(urls))
        let movidos = Set(descarte.movidos.map(\.origem))
        let tamanhos = Dictionary(uniqueKeysWithValues: arquivos.map { ($0.url, $0.tamanho) })
        Historico.shared.registrar(.lixeira, itens: descarte.movidos, tamanhos: tamanhos)
        arquivos.removeAll { movidos.contains($0.url) }
        aviso = descarte.falhas.isEmpty ? nil : "\(descarte.falhas.count) item(ns) não puderam ir para a Lixeira."
        versaoDisco += 1
    }
}

struct ArquivosView: View {
    @ObservedObject var model: ArquivosModel
    @ObservedObject var drive: DriveModel
    @State private var contaEscolhida: ContaDrive?
    @State private var conectando = false
    @State private var selecao = Set<URL>()  // marcados no checkbox
    @State private var realce = Set<URL>()  // linha clicada
    @State private var soParados = false
    @State private var ordem = [KeyPathComparator(\ArquivoPesado.tamanho, order: .reverse)]
    @State private var confirmando = false

    private var visiveis: [ArquivoPesado] {
        (soParados ? model.arquivos.filter(\.parado) : model.arquivos).sorted(using: ordem)
    }

    private var selecionados: [ArquivoPesado] {
        visiveis.filter { selecao.contains($0.url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            EspacoDisco(gatilho: model.versaoDisco + drive.versaoDisco + Historico.shared.versaoDisco)
            Divider()
            conteudo
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            if let resumo = drive.resumo {
                HStack(spacing: 10) {
                    Label("Google Drive: \(resumo)", systemImage: "icloud.and.arrow.up")
                        .lineLimit(1)
                    Spacer()
                    if let fracao = drive.fracaoGeral {
                        ProgressView(value: fracao).frame(width: 140)
                        Text("\(Int(fracao * 100))%").monospacedDigit()
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            rodape
        }
        .navigationTitle("Arquivos pesados")
        .toolbar {
            Toggle("Só parados há 6+ meses", isOn: $soParados)
                .toggleStyle(.checkbox)
            Button("Atualizar", systemImage: "arrow.clockwise") {
                realce.removeAll()
                drive.atualizar(forcar: true)
                model.varrer()
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.varrendo)
            .help("Varre de novo os arquivos e atualiza o espaço em disco, as contas e os uploads.")
        }
        .confirmationDialog(
            "Mover \(selecionados.count) arquivo(s) para a Lixeira?",
            isPresented: $confirmando
        ) {
            Button("Mover para a Lixeira", role: .destructive) {
                model.enviarParaLixeira(Set(selecionados.map(\.url)))
                selecao.removeAll()
            }
        } message: {
            Text("Dá para recuperar pela Lixeira enquanto ela não for esvaziada.")
        }
        .confirmationDialog(
            "Fazer upload de \(selecionados.count) arquivo(s) para o Google Drive?",
            isPresented: Binding(get: { contaEscolhida != nil }, set: { if !$0 { contaEscolhida = nil } }),
            presenting: contaEscolhida
        ) { conta in
            Button("Enviar para \(conta.email)") {
                let movidos = drive.arquivar(selecionados, em: conta)
                model.remover(movidos)
                selecao.subtract(movidos)
            }
        } message: { conta in
            Text("Conta: \(conta.email). Os arquivos vão para Meu Drive › \(Drive.pastaArquivo). O espaço no Mac só é liberado depois que o envio termina.")
        }
        .alert("Conectar nova conta", isPresented: $conectando) {
            Button("OK") {}
        } message: {
            Text(drive.instrucaoConexao)
        }
    }

    @ViewBuilder
    private var conteudo: some View {
        if model.varrendo {
            VStack(spacing: 12) {
                ProgressView()
                Text("Varrendo \(model.pastaAtual)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.jaVarreu {
            ContentUnavailableView {
                Label("Encontre o que está ocupando espaço", systemImage: "externaldrive")
            } description: {
                Text("Lista arquivos de 100 MB ou mais na sua pasta pessoal. A varredura só lê; nada é apagado.")
            } actions: {
                Button("Varrer agora") { model.varrer() }
                    .buttonStyle(.borderedProminent)
            }
        } else if visiveis.isEmpty {
            ContentUnavailableView(
                "Nada por aqui", systemImage: "checkmark.circle",
                description: Text("Nenhum arquivo de 100 MB ou mais com esse filtro."))
        } else {
            Table(visiveis, selection: $realce, sortOrder: $ordem) {
                TableColumn("") { a in
                    Toggle("Marcar \(a.url.lastPathComponent)", isOn: marcado(a.url))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                .width(22)
                TableColumn("Arquivo", value: \.nome) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.url.lastPathComponent).lineLimit(1)
                        Text(a.pasta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                TableColumn("Tamanho", value: \.tamanho) { a in
                    Text(formatar(a.tamanho)).monospacedDigit()
                }
                .width(90)
                TableColumn("Último uso", value: \.referencia) { a in
                    Text(a.textoUso).foregroundStyle(a.parado ? .primary : .secondary)
                }
                .width(190)
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
                .fixedSize()
                .disabled(visiveis.isEmpty)
            if let aviso = drive.aviso ?? model.aviso {
                Label(aviso, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if selecionados.isEmpty {
                Text("\(visiveis.count) arquivos · \(formatar(visiveis.reduce(0) { $0 + $1.tamanho }))\(model.atualizadoEm.map { " · atualizado às \($0.formatted(date: .omitted, time: .standard))" } ?? "")")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(selecionados.count) selecionado(s) · \(formatar(selecionados.reduce(0) { $0 + $1.tamanho }))")
            }
            Spacer()
            Button("Mostrar no Finder") { mostrarNoFinder(selecionados.map(\.url)) }
                .fixedSize()
                .disabled(selecionados.isEmpty)
            Menu("Fazer upload no Google Drive") {
                Menu("Escolher conta") {
                    ForEach(drive.contas) { conta in
                        Button(conta.email) { contaEscolhida = conta }
                            .disabled(selecionados.isEmpty)
                    }
                    Divider()
                    Button("Conectar nova conta…") {
                        drive.abrirGoogleDrive()
                        conectando = true
                    }
                }
            }
            .fixedSize()
            .help(selecionados.isEmpty ? "Marque os arquivos que quer enviar." : "")
            Button("Mover para a Lixeira", role: .destructive) { confirmando = true }
                .fixedSize()
                .disabled(selecionados.isEmpty)
        }
        .lineLimit(1)
        .padding(12)
    }
}
