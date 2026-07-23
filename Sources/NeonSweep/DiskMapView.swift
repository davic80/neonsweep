import SwiftUI

struct DiskMapView: View {
    @ObservedObject var model: DiskMapModel
    @State private var confirming = false
    @AppStorage("diskmap.treemap") private var showTreemap = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeonScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if model.scanning {
                        ProgressStrip(label: model.progress, fraction: nil)
                    }
                    if model.current == nil && !model.scanning {
                        startPanel
                    } else {
                        breadcrumbs
                        if showTreemap { treemapPanel }
                        treePanel
                    }
                }
                .padding(20)
            }
            footer
        }
        .background(Theme.bg)
        .onAppear { if model.current == nil && !model.scanning { model.start() } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("david@mac:~$").font(Theme.mono(14, .bold)).foregroundStyle(Theme.gray)
            Text("neonsweep --disk").font(Theme.mono(14, .bold)).foregroundStyle(Theme.neon)
            if !model.scanning { BlinkingCursor() }
            Spacer()
            Button { showTreemap.toggle() } label: {
                Text(showTreemap ? t("[ ▦ map ]") : t("[ ▤ list ]"))
                    .font(Theme.mono(11, .bold))
                    .foregroundStyle(showTreemap ? Theme.neon : Theme.grayDark)
                    .frame(minHeight: 24).contentShape(Rectangle())
            }
            .buttonStyle(NeonClick())
            .help(t("Show or hide the proportional map"))
            Button { model.start(at: "/") } label: {
                Text(t("[ WHOLE DISK ]"))
                    .font(Theme.mono(11)).foregroundStyle(Theme.neonDim)
            }
            .buttonStyle(NeonClick())
            .disabled(model.scanning)
            .help(t("Scan / instead of your home folder (slower, needs Full Disk Access)"))
            Button { model.start() } label: {
                Text(model.scanning ? t("[ SCANNING… ]") : t("[ SCAN HOME ]"))
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(model.scanning ? Theme.grayDark : Theme.neon)
            }
            .buttonStyle(NeonClick())
            .disabled(model.scanning)
        }
    }

    private var startPanel: some View {
        TerminalPanel(title: t("WHAT'S TAKING UP SPACE"), collapsible: false) {
            Text(t("Navigate your folders by size, biggest first. Click a folder to go inside; anything you mark goes to the Trash."))
                .font(Theme.body).foregroundStyle(Theme.gray)
        }
    }

    // MARK: Migas de pan

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.stack.enumerated()), id: \.element.id) { idx, node in
                if idx > 0 {
                    Text("/").font(Theme.small).foregroundStyle(Theme.grayDark)
                }
                Button { model.goTo(index: idx) } label: {
                    Text(idx == 0 ? (node.path == "/" ? "/" : "~") : node.name)
                        .font(Theme.mono(11, idx == model.stack.count - 1 ? .bold : .regular))
                        .foregroundStyle(idx == model.stack.count - 1 ? Theme.neon : Theme.neonDim)
                        .frame(minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NeonClick())
            }
            Spacer()
            if model.stack.count > 1 {
                Button { model.goBack() } label: {
                    Text(t("[ UP ]")).font(Theme.mono(11, .bold)).foregroundStyle(Theme.neonDim)
                        .frame(minHeight: 22).contentShape(Rectangle())
                }
                .buttonStyle(NeonClick())
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    // MARK: Treemap — rectángulos proporcionales al tamaño

    private var treemapPanel: some View {
        TerminalPanel(title: t("PROPORTIONAL MAP"), id: "diskmap.tree", collapsible: false) {
            TreemapView(
                nodes: model.current?.children ?? [],
                checked: model.checked,
                onTap: { node in
                    if node.isDir { model.enter(node) } else { model.revealInFinder(node) }
                },
                onToggle: { node in
                    if model.checked.contains(node.id) { model.checked.remove(node.id) }
                    else { model.checked.insert(node.id) }
                }
            )
            .frame(height: 300)
            Text(t("// area = size · click to go inside · ⌘-click to mark for deletion"))
                .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
        }
    }

    // MARK: Árbol con barras proporcionales

    private var treePanel: some View {
        let node = model.current
        let children = node?.children ?? []
        let maxSize = children.first?.size ?? 1
        return TerminalPanel(
            title: String(format: t("%@ — %@"),
                          node?.name ?? "", formatBytes(node?.size ?? 0)),
            id: "diskmap", collapsible: false
        ) {
            if children.isEmpty && !model.scanning {
                Text(t("empty folder")).font(Theme.body).foregroundStyle(Theme.grayDark)
            }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(children.prefix(200)) { child in
                    row(child, maxSize: maxSize, total: node?.size ?? 1)
                }
            }
            if children.count > 200 {
                Text(String(format: t("showing %d of %d"), 200, children.count))
                    .font(Theme.mono(10)).foregroundStyle(Theme.grayDark)
            }
        }
    }

    private func row(_ child: DiskNode, maxSize: Int64, total: Int64) -> some View {
        let isSel = model.checked.contains(child.id)
        let share = total > 0 ? Double(child.size) / Double(total) : 0
        let barFraction = maxSize > 0 ? Double(child.size) / Double(maxSize) : 0
        return HStack(spacing: 8) {
            Button {
                if isSel { model.checked.remove(child.id) } else { model.checked.insert(child.id) }
            } label: {
                Text(isSel ? "[x]" : "[ ]")
                    .font(Theme.body)
                    .foregroundStyle(isSel ? Theme.neon : Theme.grayDark)
                    .frame(minWidth: 28, minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NeonClick())
            .accessibilityLabel(child.name)
            .accessibilityValue(isSel ? t("marked") : t("not marked"))

            Text(child.isDir ? "▸" : " ")
                .font(Theme.small).foregroundStyle(Theme.neonDim)

            Button {
                if child.isDir { model.enter(child) } else { model.revealInFinder(child) }
            } label: {
                Text(child.name)
                    .font(Theme.small)
                    .foregroundStyle(child.isDir ? Theme.gray : Theme.grayDark)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: 260, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NeonClick())
            .help(child.isDir ? t("Click to go inside") : t("Click to reveal in Finder"))

            // Barra proporcional al hijo más grande
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.bg)
                    Rectangle()
                        .fill(share > 0.25 ? Theme.neon : Theme.neonDim)
                        .frame(width: max(2, geo.size.width * barFraction))
                        .shadow(color: share > 0.25 ? Theme.neon.opacity(0.5) : .clear, radius: 4)
                }
            }
            .frame(height: 10)

            Text(String(format: "%2.0f%%", share * 100))
                .font(Theme.mono(9)).foregroundStyle(Theme.grayDark)
                .frame(width: 34, alignment: .trailing)
            Text(formatBytes(child.size))
                .font(Theme.mono(11, .bold))
                .foregroundStyle(share > 0.25 ? Theme.neon : Theme.gray)
                .frame(width: 80, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack {
            if let r = model.lastResult {
                Text(r).font(Theme.small)
                    .foregroundStyle(r.hasPrefix("OK") ? Theme.neon : Theme.amber)
            }
            Spacer()
            Text("\(model.checked.count) " + t("checked =") + " \(formatBytes(model.checkedSize))")
                .font(Theme.body).foregroundStyle(Theme.gray)
            Button { confirming = true } label: {
                Text(t("[ MOVE TO TRASH ]"))
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(model.checked.isEmpty ? Theme.grayDark : Theme.neon)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                        model.checked.isEmpty ? Theme.border : Theme.neon, lineWidth: 1))
            }
            .buttonStyle(NeonClick())
            .disabled(model.checked.isEmpty)
            .confirmationDialog(
                String(format: t("Move %d items (%@) to the Trash?"),
                       model.checked.count, formatBytes(model.checkedSize)),
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
