import SwiftUI

struct SettingsView: View {
    @Environment(ExportManager.self) private var exporter

    var body: some View {
        @Bindable var exporter = exporter

        Form {
            Section("Exports") {
                LabeledContent("Save to") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(exporter.destinationFolder.path(percentEncoded: false).abbreviatingWithTilde)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack {
                            if exporter.customFolder != nil {
                                Button("Use Default") { exporter.resetDestinationFolder() }
                            }
                            Button("Choose…") { exporter.chooseDestinationFolder() }
                        }
                    }
                }
                Toggle("Show in Finder when an export finishes", isOn: $exporter.revealWhenFinished)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
