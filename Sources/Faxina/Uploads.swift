import SwiftUI

struct UploadsView: View {
    @ObservedObject var drive: DriveModel

    /// Enviando primeiro, do mais adiantado para o menos.
    private var itens: [Arquivado] {
        drive.itens.sorted {
            let a = $0.estado == .enviando, b = $1.estado == .enviando
            if a != b { return a }
            return $0.fracao > $1.fracao
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if drive.itens.isEmpty {
                ContentUnavailableView(
                    "Nenhum upload ainda", systemImage: "icloud.and.arrow.up",
                    description: Text("Os arquivos que você mandar para o Google Drive aparecem aqui com o andamento do envio.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cabecalho
                Divider()
                Table(itens) {
                    TableColumn("Arquivo") { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.nome).lineLimit(1)
                            Text(a.pastaNoDrive).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                    TableColumn("Conta") { a in
                        Text(a.conta).lineLimit(1)
                    }
                    .width(min: 120, ideal: 190)
                    TableColumn("Tamanho") { a in
                        Text(formatar(a.tamanho)).monospacedDigit()
                    }
                    .width(80)
                    TableColumn("Envio") { a in
                        HStack(spacing: 8) {
                            ProgressView(value: a.fracao)
                            Text("\(Int(a.fracao * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                    .width(150)
                    TableColumn("Situação") { a in
                        Text(a.situacao).foregroundStyle(a.estado == .enviando ? .primary : .secondary)
                    }
                    .width(min: 120, ideal: 190)
                }
            }
        }
        .navigationTitle("Uploads")
        .toolbar {
            Button("Atualizar", systemImage: "arrow.clockwise") { drive.atualizar(forcar: true) }
                .labelStyle(.titleAndIcon)
        }
    }

    private var cabecalho: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fracao = drive.fracaoGeral {
                Text("Enviando \(drive.enviando) arquivo(s) · \(Int(fracao * 100))% do total")
                    .font(.headline)
                ProgressView(value: fracao)
            } else {
                Label("Nenhum envio em andamento", systemImage: "checkmark.circle").font(.headline)
            }
            Text("O envio é feito pelo Google Drive e continua mesmo com o Faxina fechado. O espaço no Mac é liberado quando cada arquivo termina.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
