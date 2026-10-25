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
                    LabeledContent("Clip", value: clip.name)
                    LabeledContent("Original Length", value: clip.duration.preciseTimecode)
                }

                Section("Trim") {
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

                    Button("Reset Trim") { store.resetTrim(for: item.id) }
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
