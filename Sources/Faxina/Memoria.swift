import Darwin
import SwiftUI

struct ConsumoApp: Identifiable {
    let nome: String
    let caminhoApp: String?  // pacote .app, quando o processo pertence a um
    var memoria: Int64
    var processos: Int

    var id: String { caminhoApp ?? nome }
}

struct ResumoMemoria {
    var usada: Int64 = 0
    var total: Int64 = 0
    var swap: Int64 = 0
}

enum Memoria {
    /// Soma a memória residente (RSS) dos processos, agrupando auxiliares no app dono.
    static func consumoPorApp() -> [ConsumoApp] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,rss=,comm="]
        let saida = Pipe()
        ps.standardOutput = saida
        guard (try? ps.run()) != nil else { return [] }
        let dados = saida.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        var grupos: [String: ConsumoApp] = [:]
        for linha in String(decoding: dados, as: UTF8.self).split(separator: "\n") {
            let partes = linha.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard partes.count == 3, let kb = Int64(partes[1]) else { continue }
            let caminho = String(partes[2])
            var app: String?
            if let r = caminho.range(of: ".app/") {
                app = String(caminho[..<r.lowerBound]) + ".app"
            }
            let nome = app.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? URL(fileURLWithPath: caminho).lastPathComponent
            let chave = app ?? nome
            grupos[chave, default: ConsumoApp(nome: nome, caminhoApp: app, memoria: 0, processos: 0)]
                .memoria += kb * 1024
            grupos[chave]?.processos += 1
        }
        return grupos.values.sorted { $0.memoria > $1.memoria }
    }

    static func resumo() -> ResumoMemoria {
        var r = ResumoMemoria(total: Int64(ProcessInfo.processInfo.physicalMemory))

        var vm = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n)
            }
        }
        if ok == KERN_SUCCESS {
            let paginas = Int64(vm.active_count) + Int64(vm.wire_count) + Int64(vm.compressor_page_count)
            r.usada = paginas * Int64(vm_kernel_page_size)
        }

        var swap = xsw_usage()
        var tamanho = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &tamanho, nil, 0) == 0 {
            r.swap = Int64(swap.xsu_used)
        }
        return r
    }
}

@MainActor
final class MemoriaModel: ObservableObject {
    @Published var apps: [ConsumoApp] = []
    @Published var resumo = ResumoMemoria()
    @Published var atualizadoEm: Date?

    func atualizar() async {
        let (lista, r) = await Task.detached { (Memoria.consumoPorApp(), Memoria.resumo()) }.value
        apps = Array(lista.prefix(15))
        resumo = r
        atualizadoEm = Date()
    }

    /// App com janela que pode ser encerrado normalmente (ele ainda pode pedir para salvar).
    func appAberto(_ item: ConsumoApp) -> NSRunningApplication? {
        guard let caminho = item.caminhoApp else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == caminho && $0.activationPolicy == .regular
                && $0 != .current && $0.bundleIdentifier != "com.apple.finder"
        }
    }
}

struct MemoriaView: View {
    @ObservedObject var model: MemoriaModel

    var body: some View {
        VStack(spacing: 0) {
            cabecalho
            Divider()
            List(model.apps) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.nome)
                            if item.processos > 1 {
                                Text("\(item.processos) processos").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ProgressView(value: Double(item.memoria), total: Double(model.apps.first?.memoria ?? 1))
                    }
                    Text(formatar(item.memoria)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    Button("Encerrar") { model.appAberto(item)?.terminate() }
                        .disabled(model.appAberto(item) == nil)
                }
                .padding(.vertical, 3)
            }
        }
        .navigationTitle("Memória")
        .toolbar {
            Button("Atualizar", systemImage: "arrow.clockwise") { Task { await model.atualizar() } }
                .labelStyle(.titleAndIcon)
        }
        .task {
            while !Task.isCancelled {
                await model.atualizar()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var cabecalho: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(formatar(model.resumo.usada)) em uso de \(formatar(model.resumo.total))")
                    .font(.headline)
                Spacer()
                Text("Swap em uso: \(formatar(model.resumo.swap))")
                    .foregroundStyle(model.resumo.swap > 2 * 1024 * 1024 * 1024 ? .orange : .secondary)
            }
            ProgressView(value: Double(model.resumo.usada), total: Double(max(model.resumo.total, 1)))
            Text("\(model.atualizadoEm.map { "Atualizado às \($0.formatted(date: .omitted, time: .standard)). " } ?? "")Valores aproximados. Swap alto indica que a RAM não está dando conta; encerrar os apps do topo é o que alivia.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
