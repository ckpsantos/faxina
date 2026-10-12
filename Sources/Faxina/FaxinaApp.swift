import SwiftUI

@main
struct FaxinaApp: App {
    var body: some Scene {
        // Janela única: fechar e reabrir o app sempre traz a janela de volta.
        Window("Faxina", id: "principal") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
    }
}

enum Secao: String, CaseIterable, Identifiable {
    case arquivos = "Arquivos pesados"
    case sobras = "Caches e sobras"
    case apps = "Aplicativos"
    case memoria = "Memória"
    case organizador = "Organizador"
    case uploads = "Uploads"
    case historico = "Últimas ações"

    var id: Self { self }

    var icone: String {
        switch self {
        case .arquivos: return "externaldrive"
        case .sobras: return "trash"
        case .apps: return "square.grid.2x2"
        case .memoria: return "memorychip"
        case .organizador: return "folder"
        case .uploads: return "icloud.and.arrow.up"
        case .historico: return "clock.arrow.circlepath"
        }
    }
}

struct ContentView: View {
    @State private var secao: Secao? = .arquivos
    @StateObject private var arquivos = ArquivosModel()
    @StateObject private var sobras = SobrasModel()
    @StateObject private var memoria = MemoriaModel()
    @StateObject private var apps = AppsModel()
    @StateObject private var organizador = OrganizadorModel()
    @StateObject private var drive = DriveModel()
    @ObservedObject private var historico = Historico.shared

    var body: some View {
        NavigationSplitView {
            List(Secao.allCases, selection: $secao) { s in
                Label(s.rawValue, systemImage: s.icone).tag(s)
                    .badge(s == .uploads ? drive.enviando : 0)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch secao ?? .arquivos {
            case .arquivos: ArquivosView(model: arquivos, drive: drive)
            case .sobras: SobrasView(model: sobras)
            case .apps: AppsView(model: apps)
            case .memoria: MemoriaView(model: memoria)
            case .organizador: OrganizadorView(model: organizador)
            case .uploads: UploadsView(drive: drive)
            case .historico: HistoricoView(model: historico)
            }
        }
        .task {
            historico.aoDesfazerDrive = { drive.esquecer($0) }
            await drive.acompanhar()
        }
    }
}
