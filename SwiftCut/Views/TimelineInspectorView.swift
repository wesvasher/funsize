import SwiftUI

/// Right-hand panel for the timeline: its format (frame size, frame rate, fit), the selected
/// clip and its trim, and buttons to save and load timeline settings.
struct TimelineInspectorView: View {
    @Environment(ProjectStore.self) private var store
    @State private var presets = TimelinePresetStore.shared
    @State private var isNamingPreset = false
    @State private var presetName = ""

    var body: some View {
        InspectorPanel {
            format
            if let item = store.selectedTimelineItem, let clip = store.clip(for: item.clipID) {
                selectedClip(item, clip)
                trim(item, clip)
            } else {
                InspectorSection("Selected Clip") {
                    GridRow {
                        Text("Select a clip in the timeline to see and trim it.")
                            .foregroundStyle(.secondary)
                            .gridCellColumns(2)
                    }
                }
            }
        } footer: {
            footer
        }
    }

    // MARK: Format

    /// Frame size, frame rate, and how clips fit the frame.
    private var format: some View {
        @Bindable var store = store
        return InspectorSection("Format") {
            GridRow {
                InspectorLabel("Aspect Ratio")
                picker($store.timelineSettings.aspect, TimelineSettings.Aspect.allCases, \.title)
            }
            GridRow {
                InspectorLabel("Resolution")
                picker($store.timelineSettings.resolution, TimelineSettings.Resolution.allCases, \.title)
            }
            GridRow {
                InspectorLabel("Frame Rate")
                picker($store.timelineSettings.frameRate, TimelineSettings.FrameRate.allCases, \.title)
            }
            GridRow {
                InspectorLabel("Clips")
                picker($store.timelineSettings.fit, TimelineSettings.Fit.allCases, \.title)
            }
            .help("How clips of a different shape fill the frame")
            InspectorRow("Frame Size", frameSizeText)
            InspectorRow("Rate", frameRateText)
            GridRow {
                Text("Automatic follows the clips: the first clip's size, and the frame rate of the fastest clip. Applies to the preview and exports.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(2)
            }
        }
    }

    private func picker<Value: Hashable & Identifiable>(_ selection: Binding<Value>, _ choices: [Value],
                                                       _ title: KeyPath<Value, String>) -> some View {
        Picker("", selection: selection) {
            ForEach(choices) { choice in
                Text(choice[keyPath: title]).tag(choice)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var frameSizeText: String {
        let size = store.timelineFrameSize
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    private var frameRateText: String {
        if store.timelineSettings.frameRate != .automatic {
            return store.timelineSettings.frameRate.title
        }
        let fastest = store.timeline.compactMap { store.clip(for: $0.clipID)?.frameRate }.max() ?? 0
        guard fastest > 0 else { return "Follows the clips" }
        let rate = Double(fastest)
        let text = rate == rate.rounded() ? "\(Int(rate))" : String(format: "%.3g", rate)
        return "\(text) fps (from the clips)"
    }

    // MARK: Selected clip

    private func selectedClip(_ item: TimelineItem, _ clip: Clip) -> some View {
        let range = store.trimRange(of: item)
        return InspectorSection("Selected Clip") {
            GridRow {
                ClipThumbnail(clip: clip, time: range.lowerBound)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .gridCellColumns(2)
            }
            InspectorRow("Clip", store.name(of: item))
            InspectorRow("Kind", item.subclipID == nil ? "Whole source video" : "Subclip of \(clip.name)")
            InspectorRow("Source", clip.duration.preciseTimecode)
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                HStack(spacing: 6) {
                    Button("Duplicate") { store.duplicateTimelineItem(item.id) }
                    Button("Remove", role: .destructive) { store.removeTimelineItem(item.id) }
                }
            }
        }
    }

    private func trim(_ item: TimelineItem, _ clip: Clip) -> some View {
        let range = store.trimRange(of: item)
        let limit = 0...max(ProjectStore.minimumClipLength, clip.duration)
        return InspectorSection("Trim") {
            InspectorRow("Start", range.lowerBound.preciseTimecode)
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Slider(value: Binding(get: { range.lowerBound }, set: { store.setTrimStart($0, for: item.id) }), in: limit)
            }
            InspectorRow("End", range.upperBound.preciseTimecode)
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Slider(value: Binding(get: { range.upperBound }, set: { store.setTrimEnd($0, for: item.id) }), in: limit)
            }
            InspectorRow("Length", (range.upperBound - range.lowerBound).preciseTimecode)
            if item.subclipID != nil {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Button("Use Whole Source Video") { store.resetTrim(for: item.id) }
                }
            }
            GridRow {
                Text(item.subclipID == nil
                     ? "Trimming makes this a subclip. The source video isn't changed."
                     : "Trimming changes this subclip. The source video isn't changed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .gridCellColumns(2)
            }
        }
        .monospacedDigit()
    }

    // MARK: Saving and loading settings

    private var footer: some View {
        let current = presets.presets.first { $0.settings == store.timelineSettings }
        return Group {
            Menu {
                if presets.presets.isEmpty {
                    Text("No saved settings yet")
                } else {
                    ForEach(presets.presets) { preset in
                        Toggle(preset.name, isOn: Binding(get: { preset.id == current?.id },
                                                          set: { _ in store.timelineSettings = preset.settings }))
                    }
                    Divider()
                    Menu("Delete") {
                        ForEach(presets.presets) { preset in
                            Button(preset.name) { presets.delete(preset) }
                        }
                    }
                }
                Divider()
                Button("Reset to Automatic") { store.timelineSettings = TimelineSettings() }
                    .disabled(store.timelineSettings.isDefault)
            } label: {
                Label("Load Settings", systemImage: "square.and.arrow.down.on.square")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity)
            .help("Use saved timeline settings")

            Button {
                presetName = current?.name ?? ""
                isNamingPreset = true
            } label: {
                Label("Save Settings…", systemImage: "square.and.arrow.down")
            }
            // Menus don't stretch like buttons, so both keep their own width, centered in half the bar.
            .frame(maxWidth: .infinity)
            .help("Save the Format settings to use on other timelines")
        }
        .alert("Save Timeline Settings", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { presets.save(name: presetName, settings: store.timelineSettings) }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the aspect ratio, resolution, frame rate, and fit so you can load them into other projects. Settings with the same name are replaced.")
        }
    }
}
