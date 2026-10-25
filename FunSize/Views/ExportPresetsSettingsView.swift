import SwiftUI
import UniformTypeIdentifiers

/// Settings › Export Presets: where exports go, and the list of presets.
struct ExportPresetsSettingsView: View {
    @Environment(ExportManager.self) private var exporter
    @State private var selection: Set<ExportPreset.ID> = []
    @State private var editing: ExportPreset?
    @State private var isNew = false
    @State private var isImporting = false
    @State private var exportDocument: PresetsDocument?
    @State private var exportName = ""
    @State private var isConfirmingRestore = false
    @State private var isConfirmingDelete = false
    @State private var message: (title: String, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            locationSection
            presetList
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editing) { preset in
            ExportPresetEditor(preset: preset, isNew: isNew) { saved in
                exporter.save(saved)
                selection = [saved.id]
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.funsizePresets, .json], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .funsizePresets,
            defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result {
                message = ("Couldn't Export Presets", error.localizedDescription)
            }
        }
        .confirmationDialog("Restore the built-in presets?", isPresented: $isConfirmingRestore) {
            Button("Restore Built-in Presets") { exporter.restoreDefaultPresets() }
        } message: {
            Text("The presets that came with FunSize are added back, and any changes made to them are undone. Presets you created aren't changed.")
        }
        .confirmationDialog(deleteTitle, isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                exporter.deletePresets(selection)
                selection = []
            }
        } message: {
            Text("You can't undo this. To keep a copy, export the presets first.")
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message?.text ?? "")
        }
    }

    // MARK: Export location

    private var locationSection: some View {
        @Bindable var exporter = exporter

        return VStack(alignment: .leading, spacing: 8) {
            Text("Export Location")
                .font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Save exported movies:", selection: $exporter.location) {
                        ForEach(ExportLocation.allCases) { location in
                            Text(location.title).tag(location)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    switch exporter.location {
                    case .projectFolder:
                        note("Exports go in the same folder as the project file. If the project hasn't been saved yet, FunSize asks where to put them.")
                    case .ask:
                        note("FunSize asks where to save each time you export.")
                    case .folder:
                        folderRow
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var folderRow: some View {
        HStack(spacing: 6) {
            if let path = exporter.customFolderPath {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(path.abbreviatingWithTilde)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            } else {
                Text("No folder chosen").foregroundStyle(.secondary)
            }
            Spacer()
            Button(exporter.customFolderPath == nil ? "Choose…" : "Change…") { exporter.chooseCustomFolder() }
        }
        if exporter.customFolderPath == nil {
            note("Choose a folder. Until then, FunSize asks where to save each export.")
        } else if exporter.customFolderIsMissing {
            Label("This folder can't be found. It may have been moved or renamed, or it's on a drive that isn't connected. When you export, FunSize will tell you and ask where to save.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    // No .fixedSize on wrapping text here: on macOS 27 it stops the whole Settings window drawing.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: Presets

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets")
                .font(.headline)
            Text("These appear in the Export menu. Double-click a preset to edit it, or drag to change the order.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(exporter.presets) { preset in
                    PresetRow(preset: preset)
                        .tag(preset.id)
                }
                .onMove { exporter.presets.move(fromOffsets: $0, toOffset: $1) }
            }
            // The bordered style draws over the whole window on macOS 27, so draw the border here.
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .frame(minHeight: 160, maxHeight: .infinity)
            .contextMenu(forSelectionType: ExportPreset.ID.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button("Edit…") { edit(id) }
                    Button("Duplicate") { duplicate(id) }
                }
                if !ids.isEmpty {
                    Button(ids.count == 1 ? "Export Preset…" : "Export \(ids.count) Presets…") { export(ids) }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        selection = ids
                        isConfirmingDelete = true
                    }
                }
            } primaryAction: { ids in
                if let id = ids.first { edit(id) }
            }
            .onDeleteCommand {
                if !selection.isEmpty { isConfirmingDelete = true }
            }

            controlBar
        }
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button("Add Preset", systemImage: "plus") { addPreset() }
                    .help("New preset")
                Button("Delete Preset", systemImage: "minus") { isConfirmingDelete = true }
                    .disabled(selection.isEmpty)
                    .help("Delete the selected presets")
            }
            .labelStyle(.iconOnly)
            .fixedSize()

            Button("Duplicate") { if let id = selection.first { duplicate(id) } }
                .disabled(selection.count != 1)
            Button("Edit…") { if let id = selection.first { edit(id) } }
                .disabled(selection.count != 1)

            Spacer()

            Menu("Import & Export") {
                Button("Import Presets…") { isImporting = true }
                Divider()
                Button(selection.count > 1 ? "Export \(selection.count) Selected Presets…" : "Export Selected Preset…") { export(selection) }
                    .disabled(selection.isEmpty)
                Button("Export All Presets…") { export(Set(exporter.presets.map(\.id))) }
                    .disabled(exporter.presets.isEmpty)
                Divider()
                Button("Restore Built-in Presets…") { isConfirmingRestore = true }
            }
            .fixedSize()
        }
        .controlSize(.regular)
    }

    private var deleteTitle: String {
        if selection.count == 1, let id = selection.first, let preset = exporter.preset(id: id) {
            return "Delete “\(preset.name)”?"
        }
        return "Delete \(selection.count) presets?"
    }

    // MARK: Actions

    private func addPreset() {
        var preset = ExportPreset.defaults[0].copy(named: exporter.uniqueName("New Preset"))
        preset.fileSuffix = "Export"
        isNew = true
        editing = preset
    }

    private func edit(_ id: ExportPreset.ID) {
        guard let preset = exporter.preset(id: id) else { return }
        isNew = false
        editing = preset
    }

    private func duplicate(_ id: ExportPreset.ID) {
        if let copy = exporter.duplicatePreset(id) { selection = [copy.id] }
    }

    private func export(_ ids: Set<ExportPreset.ID>) {
        let presets = exporter.presets.filter { ids.contains($0.id) }
        guard !presets.isEmpty else { return }
        exportName = presets.count == 1 ? presets[0].name : "FunSize Presets"
        exportDocument = PresetsDocument(presets: presets)
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            message = ("Couldn't Import Presets", error.localizedDescription)
        case .success(let urls):
            var imported: [ExportPreset] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    imported += try PresetsDocument.decode(Data(contentsOf: url))
                } catch {
                    message = ("Couldn't Import “\(url.lastPathComponent)”", error.localizedDescription)
                    return
                }
            }
            let counts = exporter.importPresets(imported)
            selection = Set(imported.map(\.id))
            var parts: [String] = []
            if counts.added > 0 { parts.append("Added \(counts.added) \(counts.added == 1 ? "preset" : "presets").") }
            if counts.replaced > 0 { parts.append("Updated \(counts.replaced) you already had.") }
            message = ("Presets Imported", parts.joined(separator: " "))
        }
    }
}

private struct PresetRow: View {
    let preset: ExportPreset

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: preset.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
