import SwiftUI

struct ContaDrive: Identifiable, Hashable {
    let email: String
    let meuDrive: URL
    var id: String { email }
}

struct Arquivado: Identifiable {
    enum Estado { case enviando, enviado, liberado, sumiu }

    let destino: URL
    let tamanho: Int64
    var estado: Estado = .enviando
    var progresso: Double?  // 0...1 enquanto envia; nil se o Drive ainda não informou
    var id: URL { destino }

    var nome: String { destino.lastPathComponent }

    var conta: String {
        destino.pathComponents.first { $0.hasPrefix("GoogleDrive-") }
            .map { String($0.dropFirst("GoogleDrive-".count)) } ?? ""
    }

    /// Pasta dentro do Drive, a partir de "Arquivo do Mac".
    var pastaNoDrive: String {
        let partes = destino.deletingLastPathComponent().pathComponents
        guard let i = partes.firstIndex(of: Drive.pastaArquivo) else { return "" }
        return partes[i...].joined(separator: " › ")
    }

    var situacao: String {
        switch estado {
        case .enviando: return (progresso ?? 0) > 0 ? "Enviando" : "Na fila"
        case .enviado: return "Na nuvem, liberando espaço"
        case .liberado: return "Na nuvem, espaço liberado"
        case .sumiu: return "Não está mais na pasta do Drive"
        }
    }

    /// Quanto deste arquivo já subiu, de 0 a 1.
    var fracao: Double {
        switch estado {
        case .enviando: return progresso ?? 0
        case .enviado, .liberado: return 1
        case .sumiu: return 0
        }
    }
}

/// Arquiva pelo app Google Drive para Mac: o arquivo é movido para a pasta do Drive,
/// o Drive envia, e só depois do envio confirmado a cópia local é liberada.
enum Drive {
    static let pastaArquivo = "Arquivo do Mac"

    static func contas() -> [ContaDrive] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let pastas = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return pastas.compactMap { pasta in
            let nome = pasta.lastPathComponent
            guard nome.hasPrefix("GoogleDrive-") else { return nil }
            for meuDrive in ["Meu Drive", "My Drive"] {
                let url = pasta.appendingPathComponent(meuDrive)
                if fm.fileExists(atPath: url.path) {
                    return ContaDrive(email: String(nome.dropFirst("GoogleDrive-".count)), meuDrive: url)
                }
            }
            return nil
        }
    }

    /// Move para "Meu Drive/Arquivo do Mac/<mesma pasta de origem>". Nunca sobrescreve.
    static func mover(_ origem: URL, para conta: ContaDrive) throws -> URL {
        let fm = FileManager.default
        var relativo = origem.deletingLastPathComponent().path
        if relativo.hasPrefix(NSHomeDirectory()) {
            relativo = String(relativo.dropFirst(NSHomeDirectory().count))
        }
        let pasta = conta.meuDrive
            .appendingPathComponent(pastaArquivo)
            .appendingPathComponent(relativo.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        try fm.createDirectory(at: pasta, withIntermediateDirectories: true)

        let base = origem.deletingPathExtension().lastPathComponent
        let ext = origem.pathExtension
        var destino = pasta.appendingPathComponent(origem.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: destino.path) {
            destino = pasta.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        try fm.moveItem(at: origem, to: destino)
        return destino
    }

    /// Confere o envio e, se já está na nuvem, libera a cópia local.
    static func conferir(_ destino: URL) -> Arquivado.Estado {
        let url = URL(fileURLWithPath: destino.path)  // URL nova: sem valores em cache
        guard FileManager.default.fileExists(atPath: url.path) else { return .sumiu }
        let v = try? url.resourceValues(forKeys: [
            .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard v?.ubiquitousItemIsUploaded == true else { return .enviando }
        if v?.ubiquitousItemDownloadingStatus == .notDownloaded { return .liberado }
        try? FileManager.default.evictUbiquitousItem(at: url)
        return .enviado
    }
}

@MainActor
final class DriveModel: ObservableObject {
    @Published var contas = Drive.contas()
    @Published var itens: [Arquivado] = []
    @Published var aviso: String?
    @Published var versaoDisco = 0

    private let chave = "arquivamentosPendentes"
    private var assinaturas: [URL: Any] = [:]
    private var progressos: [URL: Progress] = [:]

    init() {
        // Retoma o acompanhamento do que ainda não tinha terminado na última vez.
        let salvos = UserDefaults.standard.dictionary(forKey: chave) as? [String: Int] ?? [:]
        itens = salvos.map { Arquivado(destino: URL(fileURLWithPath: $0.key), tamanho: Int64($0.value)) }
        // Uploads anteriores ainda não desfeitos também aparecem; a situação real é conferida em seguida.
        let conhecidos = Set(itens.map(\.destino))
        for registro in Historico.shared.registros where registro.tipo == .drive && !registro.desfeito {
            let destino = URL(fileURLWithPath: registro.atual)
            if !conhecidos.contains(destino) {
                itens.append(Arquivado(destino: destino, tamanho: registro.tamanho ?? 0))
            }
        }
    }

    /// Devolve os arquivos de origem que foram de fato movidos.
    func arquivar(_ arquivos: [ArquivoPesado], em conta: ContaDrive) -> Set<URL> {
        var movidos = Set<URL>()
        var pares: [(origem: URL, atual: URL)] = []
        var tamanhos: [URL: Int64] = [:]
        var falhas = 0
        for arquivo in arquivos {
            do {
                let destino = try Drive.mover(arquivo.url, para: conta)
                itens.append(Arquivado(destino: destino, tamanho: arquivo.tamanho))
                movidos.insert(arquivo.url)
                pares.append((arquivo.url, destino))
                tamanhos[arquivo.url] = arquivo.tamanho
            } catch {
                falhas += 1
            }
        }
        aviso = falhas == 0 ? nil : "\(falhas) arquivo(s) não puderam ser movidos para o Drive e ficaram onde estavam."
        Historico.shared.registrar(.drive, itens: pares, tamanhos: tamanhos, detalhe: conta.email)
        salvar()
        return movidos
    }

    /// Para de acompanhar (e de liberar) arquivos que estão sendo trazidos de volta.
    func esquecer(_ caminhos: Set<String>) {
        itens.removeAll { caminhos.contains($0.destino.path) }
        salvar()
    }

    private var appGoogleDrive: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.drivefs")
    }

    /// Contas são conectadas no app Google Drive para Mac; a nova aparece aqui sozinha.
    func abrirGoogleDrive() {
        if let app = appGoogleDrive { NSWorkspace.shared.open(app) }
    }

    var instrucaoConexao: String {
        appGoogleDrive == nil
            ? "O app Google Drive para Mac não está instalado. Instale por google.com/drive/download e entre com a conta; ela aparece aqui sozinha."
            : "O Faxina não consegue abrir essa tela sozinho. No topo da tela, clique no ícone do Google Drive na barra de menus, depois na engrenagem › Preferências, e na sua foto escolha adicionar outra conta. A conta nova aparece aqui sozinha em alguns segundos."
    }

    func acompanhar() async {
        while !Task.isCancelled {
            atualizar()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Relê as contas e o andamento dos uploads. `forcar` também recalcula o espaço em disco.
    func atualizar(forcar: Bool = false) {
        contas = Drive.contas()
        var mudou = forcar
        for i in itens.indices where itens[i].estado != .liberado && itens[i].estado != .sumiu {
            let novo = Drive.conferir(itens[i].destino)
            if novo != itens[i].estado {
                itens[i].estado = novo
                mudou = true
            }
        }
        acompanharProgresso()
        if mudou {
            salvar()
            versaoDisco += 1
        }
    }

    /// O macOS publica o andamento de cada envio do Drive; aqui só lemos esse número.
    private func acompanharProgresso() {
        for i in itens.indices where itens[i].estado == .enviando {
            let url = itens[i].destino
            if assinaturas[url] == nil {
                assinaturas[url] = Progress.addSubscriber(forFileURL: url) { [weak self] progresso in
                    Task { @MainActor in self?.progressos[url] = progresso }
                    return {
                        Task { @MainActor in
                            if self?.progressos[url] === progresso { self?.progressos[url] = nil }
                        }
                    }
                }
            }
            let fracao = progressos[url]?.fractionCompleted
            if let fracao, fracao != itens[i].progresso { itens[i].progresso = fracao }
        }
        let enviando = Set(itens.filter { $0.estado == .enviando }.map(\.destino))
        for url in assinaturas.keys where !enviando.contains(url) {
            if let assinatura = assinaturas.removeValue(forKey: url) { Progress.removeSubscriber(assinatura) }
            progressos[url] = nil
        }
    }

    var enviando: Int { itens.filter { $0.estado == .enviando }.count }

    /// Andamento geral dos uploads em bytes, de 0 a 1. Nil quando não há nada enviando.
    var fracaoGeral: Double? {
        guard enviando > 0 else { return nil }
        let ativos = itens.filter { $0.estado != .sumiu }
        let total = ativos.reduce(0.0) { $0 + Double($1.tamanho) }
        guard total > 0 else { return nil }
        return ativos.reduce(0.0) { $0 + Double($1.tamanho) * $1.fracao } / total
    }

    private func salvar() {
        let pendentes = itens.filter { $0.estado == .enviando || $0.estado == .enviado }
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: pendentes.map { ($0.destino.path, Int($0.tamanho)) }),
            forKey: chave)
    }

    var resumo: String? {
        guard !itens.isEmpty else { return nil }
        func parte(_ estados: [Arquivado.Estado], _ texto: String) -> String? {
            let grupo = itens.filter { estados.contains($0.estado) }
            guard !grupo.isEmpty else { return nil }
            return "\(grupo.count) \(texto) (\(formatar(grupo.reduce(0) { $0 + $1.tamanho })))"
        }
        return [
            parte([.enviando], "enviando"),
            parte([.enviado], "na nuvem, aguardando liberar"),
            parte([.liberado], "na nuvem, espaço liberado"),
            parte([.sumiu], "não encontrado(s) na pasta do Drive"),
        ]
        .compactMap { $0 }.joined(separator: " · ")
    }
}
