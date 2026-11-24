import SwiftUI
import UniformTypeIdentifiers
import ZittoCore

/// The left side of the window: adding songs, searching, the list, what is being prepared.
struct LibraryView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.links.isEmpty ? "Add audio or video files" : "Add \((model.links + ["or files"]).joined(separator: ", "))")
                .font(.system(size: 11))
                .foregroundColor(.zDim)
            if !model.links.isEmpty {
                TextField("Paste a link", text: $model.linkText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.addEntry)
            }
            HStack(spacing: 6) {
                if !model.links.isEmpty {
                    Button("Add link", action: model.addEntry).buttonStyle(FlatButtonStyle())
                }
                Button("Files...", action: model.chooseFiles).buttonStyle(FlatButtonStyle())
                Spacer()
                Button("Delete") { model.deleteSelected() }.buttonStyle(FlatButtonStyle())
            }
            HStack(spacing: 8) {
                Text("Search").font(.system(size: 11)).foregroundColor(.zDim)
                TextField("Words of the title or of the playlist", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searching)
                    .onSubmit(model.openFirst)
                    .onExitCommand {
                        model.clearSearch()
                        searching = false
                    }
            }
            list
            ProgressView(value: model.progress, total: 100)
                .progressViewStyle(.linear)
                .tint(.zAccent)
            Text(model.status)
                .font(.system(size: 11))
                .foregroundColor(.zDim)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: 360)
        .background(Color.zPanel)
        .onChange(of: model.focusSearch) { _ in searching = true }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        HStack {
                            Text(row.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 6)
                            Text(row.state).font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundColor(color(row.look))
                        .tag(row.id)
                    }
                } header: {
                    HStack {
                        Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundColor(.zText)
                        Spacer()
                        Text(group.count).font(.system(size: 11)).foregroundColor(.zDim)
                    }
                    .contextMenu {
                        Button(group.isPlaylist ? "Delete the playlist..." : "Delete all these songs...") {
                            model.deleteSelected(playlist: group.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.zPanel)
        .contextMenu(forSelectionType: String.self) { rows in
            let keys = rows.compactMap { id in model.groups.flatMap(\.rows).first { $0.id == id }?.key }
            if keys.count == 1 {
                Button("Open") { model.open(keys[0]) }
                Button("Rename...") { model.renameSelected() }
            }
            let failed = keys.filter { model.song($0)?.error != nil }
            if !failed.isEmpty {
                Button("Try again") { model.retry(failed) }
            }
            if !keys.isEmpty {
                Button("Delete...") { model.deleteSelected() }
            }
        } primaryAction: { rows in
            // Double-click, or Return.
            if let id = rows.first, let row = model.groups.flatMap(\.rows).first(where: { $0.id == id }) {
                model.open(row.key)
            }
        }
        .onDeleteCommand { model.deleteSelected() }
    }

    private func color(_ look: SongRow.Look) -> Color {
        switch look {
        case .normal: return .zText
        case .todo: return .zDim
        case .failed: return .zBad
        case .open: return .zAccent
        }
    }
}
