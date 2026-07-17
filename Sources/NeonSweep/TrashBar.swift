import SwiftUI

/// Barra global de la Papelera: fija bajo el contenido en todos los módulos.
struct TrashBar: View {
    @ObservedObject private var trash = TrashModel.shared
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 12) {
            Text(t("[ TRASH ]"))
                .font(Theme.mono(11, .bold))
                .foregroundStyle(Theme.neonDim)
            Text(trash.size > 0 ? formatBytes(trash.size) : t("empty"))
                .font(Theme.mono(13, .bold))
                .foregroundStyle(trash.size > 0 ? Theme.neon : Theme.grayDark)
            if let r = trash.lastResult {
                Text(r)
                    .font(Theme.mono(10))
                    .foregroundStyle(r.hasPrefix("OK") ? Theme.neonDim : Theme.amber)
                    .lineLimit(1)
            }
            Spacer()
            Button { TrashOps.reveal() } label: {
                Text(t("[ REVIEW ]"))
                    .font(Theme.mono(11, .bold)).foregroundStyle(Theme.neonDim)
                    .padding(.vertical, 4).padding(.horizontal, 7)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(NeonClick())
            Button { confirming = true } label: {
                Text(trash.emptying ? t("[ EMPTYING… ]") : t("[ EMPTY ]"))
                    .font(Theme.mono(11, .bold))
                    .foregroundStyle(trash.size == 0 || trash.emptying ? Theme.grayDark : Theme.amber)
                    .padding(.vertical, 4).padding(.horizontal, 7)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                        trash.size == 0 || trash.emptying ? Theme.border : Theme.amber, lineWidth: 1))
            }
            .buttonStyle(NeonClick())
            .disabled(trash.size == 0 || trash.emptying)
            .help(t("Irreversible: permanently deletes everything in the Trash"))
            .confirmationDialog(
                String(format: t("Empty the Trash (%@)?"), formatBytes(trash.size)),
                isPresented: $confirming
            ) {
                Button(t("Empty permanently"), role: .destructive) { trash.empty() }
                Button(t("Cancel"), role: .cancel) {}
            } message: {
                Text(t("This PERMANENTLY deletes everything in the Trash, including items NeonSweep didn't put there. It cannot be undone."))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .top)
    }
}
