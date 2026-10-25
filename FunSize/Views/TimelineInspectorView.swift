import SwiftUI

/// Trim controls for the selected timeline clip.
struct TimelineInspectorView: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        if let item = store.selectedTimelineItem, let clip = store.clip(for: item.clipID) {
            let range = store.trimRange(of: item)
            let minLength = ProjectStore.minimumClipLength

            Form {
                Section {
                    ClipThumbnail(clip: clip, time: range.lowerBound)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    LabeledContent("Clip", value: store.name(of: item))
                    LabeledContent("Kind", value: item.subclipID == nil ? "Whole source video" : "Subclip of \(clip.name)")
                    LabeledContent("Source Length", value: clip.duration.preciseTimecode)
                }

                Section {
                    LabeledContent("Start", value: range.lowerBound.preciseTimecode)
                    Slider(
                        value: Binding(
                            get: { range.lowerBound },
                            set: { store.setTrimStart($0, for: item.id) }
                        ),
                        in: 0...max(minLength, clip.duration)
                    )

                    LabeledContent("End", value: range.upperBound.preciseTimecode)
                    Slider(
                        value: Binding(
                            get: { range.upperBound },
                            set: { store.setTrimEnd($0, for: item.id) }
                        ),
                        in: 0...max(minLength, clip.duration)
                    )

                    LabeledContent("Length", value: (range.upperBound - range.lowerBound).preciseTimecode)

                    if item.subclipID != nil {
                        Button("Use Whole Source Video") { store.resetTrim(for: item.id) }
                    }
                } header: {
                    Text("Trim")
                } footer: {
                    Text(item.subclipID == nil
                         ? "Trimming makes this a subclip. The source video isn't changed."
                         : "Trimming changes this subclip. The source video isn't changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Duplicate Clip") { store.duplicateTimelineItem(item.id) }
                    Button("Remove from Timeline", role: .destructive) { store.removeTimelineItem(item.id) }
                }
            }
            .formStyle(.grouped)
            .monospacedDigit()
        } else {
            ContentUnavailableView(
                "No Clip Selected",
                systemImage: "scissors",
                description: Text("Select a clip in the timeline to trim it.")
            )
        }
    }
}
