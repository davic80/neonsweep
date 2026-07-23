import SwiftUI

struct JunkView: View {
    @ObservedObject var model: JunkModel
    var prompt = "--junk"
    @State private var confirming = false
    @State private var anchor: UUID?     // última fila clicada (Shift+clic)

    /// Clic alterna; Shift+clic marca el rango dentro de la misma categoría.
    private func toggle(_ e: JunkEntry, in cat: JunkCategory) {
        if NSEvent.modifierFlags.contains(.shift),
           let anchor,
           let a = cat.entries.firstIndex(where: { $0.id == anchor }),
           let b = cat.entries.firstIndex(where: { $0.id == e.id }) {
            let marking = !model.checked.contains(e.id)
            for item in cat.entries[min(a, b)...max(a, b)] {
                if marking { model.checked.insert(item.id) }
                else { model.checked.remove(item.id) }
            }
        } else if model.checked.contains(e.id) {
            model.checked.remove(e.id)
        } else {
            model.checked.insert(e.id)
        }
        anchor = e.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeonScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if model.scanning {
                        ProgressStrip(label: String(format: t("scanning %@…"), t(model.progress)),
                                      fraction: model.fraction)
                    }
                    ForEach(model.categories) { cat in
                        categoryPanel(cat)
                    }
                }
                .padding(20)
            }
            footer
        }
        .background(Theme.bg)
        .onAppear { if model.categories.isEmpty { model.scan() } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("david@mac:~$")
                .font(Theme.mono(14, .bold)).foregroundStyle(Theme.gray)
            Text("neonsweep \(prompt)")
                .font(Theme.mono(14, .bold)).foregroundStyle(Theme.neon)
            if !model.scanning {
                BlinkingCursor()
            }
            Spacer()
            Button { model.scan() } label: {
                Text(model.scanning ? t("[ SCANNING… ]") : t("[ RESCAN ]"))
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(model.scanning ? Theme.grayDark : Theme.neon)
            }
            .buttonStyle(NeonClick())
            .disabled(model.scanning)
        }
    }

    private func categoryPanel(_ cat: JunkCategory) -> some View {
        TerminalPanel(title: t(cat.name), id: cat.name) {
            HStack {
                Text(t(cat.note))
                    .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
                Spacer()
                Text(cat.scanned ? formatBytes(cat.totalSize) : "…")
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(cat.totalSize > 1_000_000_000 ? Theme.neon : Theme.gray)
                if cat.scanned && !cat.entries.isEmpty {
                    Button { model.toggleAll(in: cat) } label: {
                        Text(t("[all]")).font(Theme.small).foregroundStyle(Theme.neonDim)
                    }.buttonStyle(NeonClick())
                    Button {
                        if model.expanded.contains(cat.id) { model.expanded.remove(cat.id) }
                        else { model.expanded.insert(cat.id) }
                    } label: {
                        Text(model.expanded.contains(cat.id) ? "[-]" : "[+]")
                            .font(Theme.body).foregroundStyle(Theme.neon)
                    }.buttonStyle(NeonClick())
                }
            }

            if cat.scanned && cat.entries.isEmpty {
                Text(t("nothing to clean here"))
                    .font(Theme.small).foregroundStyle(Theme.grayDark)
            }

            if model.expanded.contains(cat.id) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(cat.entries) { e in
                        entryRow(e, cat)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func entryRow(_ e: JunkEntry, _ cat: JunkCategory) -> some View {
        HStack(spacing: 8) {
            Button {
                toggle(e, in: cat)
            } label: {
                Text(model.checked.contains(e.id) ? "[x]" : "[ ]")
                    .font(Theme.body)
                    .foregroundStyle(model.checked.contains(e.id) ? Theme.neon : Theme.grayDark)
                    .frame(minWidth: 28, minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NeonClick())
            .accessibilityLabel(e.name)
            .accessibilityValue(model.checked.contains(e.id) ? t("marked") : t("not marked"))
            Text(e.name)
                .font(Theme.small).foregroundStyle(Theme.gray)
                .lineLimit(1).truncationMode(.middle)
                .help(e.path)
            if let d = e.detail {
                Text("// \(d)").font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
            }
            Spacer()
            Text(formatBytes(e.size))
                .font(Theme.small)
                .foregroundStyle(e.size > 500_000_000 ? Theme.neon : Theme.gray)
        }
    }

    private var footer: some View {
        HStack {
            if let r = model.lastResult {
                Text(r).font(Theme.small)
                    .foregroundStyle(r.hasPrefix("OK") ? Theme.neon : Theme.amber)
            }
            Spacer()
            Text("\(model.checkedCount) " + t("checked =") + " \(formatBytes(model.checkedSize))")
                .font(Theme.body).foregroundStyle(Theme.gray)
            Button { confirming = true } label: {
                Text(t("[ MOVE TO TRASH ]"))
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(model.checkedCount == 0 ? Theme.grayDark : Theme.neon)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                        model.checkedCount == 0 ? Theme.border : Theme.neon, lineWidth: 1))
            }
            .buttonStyle(NeonClick())
            .disabled(model.checkedCount == 0)
            .confirmationDialog(
                String(format: t("Move %d items (%@) to the Trash?"),
                       model.checkedCount, formatBytes(model.checkedSize)),
                isPresented: $confirming
            ) {
                Button(t("Move to Trash"), role: .destructive) { model.trashChecked() }
                Button(t("Cancel"), role: .cancel) {}
            } message: {
                Text(t("Everything goes to the macOS Trash: you can restore it from Finder."))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .top)
    }
}
