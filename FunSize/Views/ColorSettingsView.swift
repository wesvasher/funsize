import SwiftUI
import UniformTypeIdentifiers

/// Settings › Color: Apple Log handling, export color tags, and the LUT library.
/// (No `.fixedSize` on wrapping text in this window: on macOS 27 it blanks the whole window.)
struct ColorSettingsView: View {
    @State private var library = LUTLibrary.shared
    @AppStorage(ColorSettings.autoLUTKey) private var autoLUT = ColorLUT.builtIns[0].id.uuidString
    @AppStorage(ColorSettings.exportTagsKey) private var exportTags = ColorSettings.ExportTags.automatic
    @State private var selection: Set<UUID> = []
    @State private var isImporting = false
    @State private var isConfirmingDelete = false
    @State private var message: (title: String, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Apple Log") {
                Picker("New Apple Log clips:", selection: $autoLUT) {
                    Text("Leave as Log").tag("none")
                    Divider()
                    ForEach(library.appleLog) { lut in
                        Text("Apply “\(lut.name)”").tag(lut.id.uuidString)
                    }
                }
                .fixedSize()
                note("iPhone footage shot in Apple Log looks flat and gray until it's converted. FunSize recognizes it and applies this LUT when you import it. You can change it per clip in the inspector's Color section.")
            }

            section("Export Color") {
                Picker("Color tags:", selection: $exportTags) {
                    ForEach(ColorSettings.ExportTags.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                note("Tells players which color standard exported videos use. Automatic matches what standard-definition (VHS, DV) and HD video normally use.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("LUT Library")
                    .font(.headline)
                Text("Built-in LUTs plus .cube files you import. Choose one for a clip in the inspector's Color section.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                lutList
                controlBar
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [CubeFile.contentType], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .confirmationDialog(selection.count == 1 ? "Delete this LUT?" : "Delete \(selection.count) LUTs?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                library.delete(selection)
                selection = []
            }
        } message: {
            Text("Clips using it go back to no LUT. To keep a copy, export it first.")
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message?.text ?? "")
        }
    }

    // MARK: Library list

    private var lutList: some View {
        List(selection: $selection) {
            Section("Apple Log") { rows(library.appleLog) }
            Section("Looks") { rows(library.looks) }
            Section("Imported") {
                if library.imported.isEmpty {
                    Text("No imported LUTs yet. Click Import to add .cube files.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    rows(library.imported)
                }
            }
        }
        // The bordered style draws over the whole window on macOS 27, so draw the border here.
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .frame(minHeight: 160, maxHeight: .infinity)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Export LUT…" : "Export \(ids.count) LUTs…") { export(ids) }
                if ids.allSatisfy({ library.lut(id: $0)?.kind == .imported }) {
                    Divider()
                    Button("Delete…", role: .destructive) {
                        selection = ids
                        isConfirmingDelete = true
                    }
                }
            }
        }
        .onDeleteCommand {
            if canDelete { isConfirmingDelete = true }
        }
    }

    private func rows(_ luts: [ColorLUT]) -> some View {
        ForEach(luts) { lut in
            HStack(spacing: 10) {
                Image(nsImage: LUTSwatch.image(for: lut))
                    .resizable()
                    .frame(width: 72, height: 21)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
                VStack(alignment: .leading, spacing: 1) {
                    Text(lut.name)
                    Text(lut.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 1)
            .tag(lut.id)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button("Import…") { isImporting = true }
            Button(selection.count > 1 ? "Export \(selection.count) LUTs…" : "Export…") { export(selection) }
                .disabled(selection.isEmpty)
            Button("Delete…") { isConfirmingDelete = true }
                .disabled(!canDelete)
                .help("Only imported LUTs can be deleted")
            Spacer()
            Button("Show LUTs Folder") {
                try? FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(library.directory)
            }
        }
    }

    private var canDelete: Bool {
        !selection.isEmpty && selection.allSatisfy { library.lut(id: $0)?.kind == .imported }
    }

    // MARK: Helpers

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) { content() }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    // MARK: Import and export

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            message = ("Couldn't Import", error.localizedDescription)
        case .success(let urls):
            var added: [ColorLUT] = []
            var failures: [String] = []
            for url in urls {
                do {
                    added.append(try library.importFile(url))
                } catch {
                    failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
            selection = Set(added.map(\.id))
            if !failures.isEmpty {
                let addedLine = added.isEmpty ? "" : "Imported \(added.count). "
                message = ("Some LUTs Couldn't Be Imported", addedLine + failures.joined(separator: "\n"))
            }
        }
    }

    /// One LUT: a Save panel. Several: choose a folder.
    private func export(_ ids: Set<UUID>) {
        let luts = library.all.filter { ids.contains($0.id) }
        guard !luts.isEmpty else { return }
        if luts.count == 1, let lut = luts.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(Self.fileName(lut.name)).cube"
            panel.allowedContentTypes = [CubeFile.contentType]
            panel.message = "Export “\(lut.name)” as a .cube file for other apps."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            write([lut], to: { _ in url })
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "Choose a folder for \(luts.count) .cube files."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            write(luts) { lut in folder.appending(path: "\(Self.fileName(lut.name)).cube") }
        }
    }

    private func write(_ luts: [ColorLUT], to destination: (ColorLUT) -> URL) {
        do {
            for lut in luts {
                try CubeFile.write(lut).write(to: destination(lut), atomically: true, encoding: .utf8)
            }
        } catch {
            message = ("Couldn't Export", error.localizedDescription)
        }
    }

    private static func fileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "→", with: "to")
    }
}
