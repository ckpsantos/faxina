import CoreServices
import SwiftUI

struct AppInstalado: Identifiable, Hashable {
    let url: URL
    let tamanho: Int64
    let ultimoUso: Date?  // última abertura registrada pelo Spotlight

    var id: URL { url }
    var nome: String { url.deletingPathExtension().lastPathComponent }
    var usoOrdenavel: Date { ultimoUso ?? .distantPast }

    /// Sem abrir há 6 meses ou mais, ou sem nenhuma abertura registrada.
    var parado: Bool { usoOrdenavel < Date().addingTimeInterval(-182 * 86_400) }

    var textoUso: String {
        ultimoUso.map { "aberto \($0.formatted(.relative(presentation: .named)))" } ?? "sem registro de uso"
    }
}

enum Apps {
    /// Apps em /Applications e ~/Applications (e um nível de subpasta). Os do sistema ficam de fora.
    static func listar(aoMedir: (String) -> Void) -> [AppInstalado] {
        let fm = FileManager.default
        let pastas = [
            URL(fileURLWithPath: "/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var pacotes: [URL] = []
        for pasta in pastas {
            for item in (try? fm.contentsOfDirectory(at: pasta, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                if item.pathExtension == "app" {
                    pacotes.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let dentro = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    pacotes.append(contentsOf: dentro.filter { $0.pathExtension == "app" })
                }
            }
        }
        return pacotes.map { url in
            aoMedir(url.deletingPathExtension().lastPathComponent)
            let uso = NSMetadataItem(url: url)?.value(forAttribute: kMDItemLastUsedDate as String) as? Date
            return AppInstalado(url: url, tamanho: Sobras.tamanho(de: url), ultimoUso: uso)
        }
    }
}

@MainActor
final class AppsModel: ObservableObject {
    @Published var apps: [AppInstalado] = []
    @Published var carregando = false
    @Published var removendo = false
    @Published var jaCarregou = false
    @Published var appAtual = ""
    @Published var aviso: String?
    @Published var atualizadoEm: Date?
    @Published var versaoDisco = 0

    func carregar() {
        guard !carregando else { return }
        carregando = true
        aviso = nil
        versaoDisco += 1
        Task {
            let lista = await Task.detached(priority: .userInitiated) {
                Apps.listar { nome in
                    Task { @MainActor in self.appAtual = nome }
                }
            }.value
            apps = lista
            carregando = false
            jaCarregou = true
            atualizadoEm = Date()
        }
    }

    func enviarParaLixeira(_ urls: Set<URL>) {
        guard !removendo else { return }
        removendo = true
        aviso = nil
        Task {
            // Primeiro o caminho direto; o que o macOS protege vai pelo Finder, que pede a senha.
            let descarte = await Task.detached {
                var descarte = moverParaLixeira(Array(urls))
                var semPermissao: [URL] = []
                for url in descarte.falhas {
                    if let naLixeira = PeloFinder.moverParaLixeira(url) {
                        descarte.movidos.append((url, naLixeira))
                    } else {
                        semPermissao.append(url)
                    }
                }
                descarte.falhas = semPermissao
                return descarte
            }.value
            let movidos = Set(descarte.movidos.map(\.origem))
            let tamanhos = Dictionary(uniqueKeysWithValues: apps.map { ($0.url, $0.tamanho) })
            Historico.shared.registrar(.lixeira, itens: descarte.movidos, tamanhos: tamanhos)
            apps.removeAll { movidos.contains($0.url) }
            aviso = descarte.falhas.isEmpty
                ? nil
                : "\(descarte.falhas.count) app(s) ficaram: a senha foi cancelada ou o Faxina não tem permissão para controlar o Finder (Ajustes › Privacidade e Segurança › Automação)."
            removendo = false
            versaoDisco += 1
        }
    }
}

struct AppsView: View {
    @ObservedObject var model: AppsModel
    @State private var selecao = Set<URL>()  // marcados no checkbox
    @State private var realce = Set<URL>()  // linha clicada
    @State private var soParados = false
    @State private var confirmando = false
    @State private var ordem = [KeyPathComparator(\AppInstalado.tamanho, order: .reverse)]

    private var visiveis: [AppInstalado] {
        (soParados ? model.apps.filter(\.parado) : model.apps).sorted(using: ordem)
    }

    /// Apps abertos agora não podem ser removidos.
    private var abertos: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    private var selecionados: [AppInstalado] {
        let abertos = abertos
        return visiveis.filter { selecao.contains($0.url) && !abertos.contains($0.url.standardizedFileURL.path) }
    }

    var body: some View {
        VStack(spacing: 0) {
            EspacoDisco(gatilho: model.versaoDisco + Historico.shared.versaoDisco)
            Divider()
            conteudo
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            rodape
        }
        .navigationTitle("Aplicativos")
        .toolbar {
            Toggle("Só parados há 6+ meses", isOn: $soParados)
                .toggleStyle(.checkbox)
            Button("Atualizar", systemImage: "arrow.clockwise") {
                realce.removeAll()
                model.carregar()
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.carregando)
        }
        .onAppear { if !model.jaCarregou { model.carregar() } }
        .confirmationDialog(
            "Mover \(selecionados.count) app(s) para a Lixeira?",
            isPresented: $confirmando
        ) {
            Button("Mover para a Lixeira", role: .destructive) {
                model.enviarParaLixeira(Set(selecionados.map(\.url)))
                selecao.removeAll()
            }
        } message: {
            Text("Alguns apps pedem a senha de administrador; o pedido aparece pelo Finder. Dá para desfazer em Últimas ações enquanto a Lixeira não for esvaziada. Os dados e ajustes do app ficam no Mac.")
        }
    }

    @ViewBuilder
    private var conteudo: some View {
        if model.carregando {
            VStack(spacing: 12) {
                ProgressView()
                Text("Medindo \(model.appAtual)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visiveis.isEmpty {
            ContentUnavailableView(
                "Nada por aqui", systemImage: "checkmark.circle",
                description: Text("Nenhum aplicativo com esse filtro."))
        } else {
            let abertos = abertos
            Table(visiveis, selection: $realce, sortOrder: $ordem) {
                TableColumn("") { a in
                    Toggle("Marcar \(a.nome)", isOn: marcado(a.url))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(abertos.contains(a.url.standardizedFileURL.path))
                }
                .width(22)
                TableColumn("Aplicativo", value: \.nome) { a in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        Text(a.nome).lineLimit(1)
                        if abertos.contains(a.url.standardizedFileURL.path) {
                            Text("aberto").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                TableColumn("Tamanho", value: \.tamanho) { a in
                    Text(formatar(a.tamanho)).monospacedDigit()
                }
                .width(90)
                TableColumn("Último uso", value: \.usoOrdenavel) { a in
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

    private var rodape: some View {
        HStack {
            if model.removendo {
                ProgressView().controlSize(.small)
                Text("Removendo… se o Finder pedir a senha de administrador, digite para continuar.")
                    .foregroundStyle(.secondary)
            } else if let aviso = model.aviso {
                Label(aviso, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
            } else if selecionados.isEmpty {
                Text("\(visiveis.count) apps · \(formatar(visiveis.reduce(0) { $0 + $1.tamanho }))\(model.atualizadoEm.map { " · atualizado às \($0.formatted(date: .omitted, time: .standard))" } ?? "")")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(selecionados.count) selecionado(s) · \(formatar(selecionados.reduce(0) { $0 + $1.tamanho }))")
            }
            Spacer()
            Button("Mostrar no Finder") { mostrarNoFinder(selecionados.map(\.url)) }
                .disabled(selecionados.isEmpty)
            Button("Mover para a Lixeira", role: .destructive) { confirmando = true }
                .disabled(selecionados.isEmpty || model.removendo)
        }
        .padding(12)
    }
}
