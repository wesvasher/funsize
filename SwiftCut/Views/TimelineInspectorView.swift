import SwiftUI

/// Right-hand panel for the timeline: its format (frame size, frame rate, fit), the selected
/// clip (with Edit to open it in the clip viewer), and buttons to save and load timeline settings.
struct TimelineInspectorView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(ExportManager.self) private var exporter
    @State private var presets = TimelinePresetStore.shared
    @State private var isNamingPreset = false
    @State private var presetName = ""

    var body: some View {
        InspectorPanel {
            format
            export
            if let item = store.selectedTimelineItem, let clip = store.clip(for: item.clipID) {
                selectedClip(item, clip)
            } else {
                InspectorSection("Selected Clip") {
                    GridRow {
                        Text("Select a clip in the timeline to see it here.")
                            .foregroundStyle(.secondary)
                            .gridCellColumns(2)
                    }
                }
            }
        } footer: {
            footer
        }
    }

    // MARK: Timeline settings

    /// Frame size, frame rate, and how clips fit the frame.
    private var format: some View {
        @Bindable var store = store
        return InspectorSection("Timeline Settings") {
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
            GridRow {
                InspectorLabel("Loudness")
                HStack(spacing: 6) {
                    Toggle("Match Loudness", isOn: $store.timelineSettings.matchLoudness)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    Text("Even out the clips")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("Turns each clip up or down so they all sound equally loud. Change a clip under Selected Clip.")
            GridRow {
                InspectorLabel("Target")
                picker($store.timelineSettings.loudnessTarget, TimelineSettings.loudnessTargets.map(\.lufs)) { lufs in
                    TimelineSettings.loudnessTargets.first { $0.lufs == lufs }?.title ?? "\(lufs.loudnessText) LUFS"
                }
                .disabled(!store.timelineSettings.matchLoudness)
            }
            .help("How loud the clips are made. Online video is usually −14 LUFS; TV is −23 or −24.")
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

    private func picker<Value: Hashable>(_ selection: Binding<Value>, _ choices: [Value],
                                         title: @escaping (Value) -> String) -> some View {
        Picker("", selection: selection) {
            ForEach(choices, id: \.self) { choice in
                Text(title(choice)).tag(choice)
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

    // MARK: Export

    /// The preset the Export section uses: the chosen one, or the first if it was deleted.
    private var exportPreset: ExportPreset? {
        exporter.presets.first { $0.id == store.timelineSettings.exportPresetID } ?? exporter.presets.first
    }

    /// Export preset, where the file goes, a size estimate, and the Export button.
    private var export: some View {
        @Bindable var exporter = exporter
        let preset = exportPreset
        return InspectorSection("Export") {
            GridRow {
                InspectorLabel("Preset")
                Picker("", selection: Binding(
                    get: { preset?.id },
                    set: { store.timelineSettings.exportPresetID = $0 }
                )) {
                    ForEach(exporter.presets) { choice in
                        Text(choice.name).tag(Optional(choice.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let preset {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(preset.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                InspectorLabel("Save To")
                Picker("", selection: $exporter.location) {
                    Text("Project Folder").tag(ExportLocation.projectFolder)
                    Text("Ask Each Time").tag(ExportLocation.ask)
                    Text("Chosen Folder").tag(ExportLocation.folder)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("Where exports are saved. This is the same setting as in Settings › Export.")
            if exporter.location == .folder {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    HStack(spacing: 6) {
                        Text(exporter.customFolderPath.map { ($0 as NSString).lastPathComponent } ?? "No folder chosen")
                            .foregroundStyle(exporter.customFolderIsMissing ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(exporter.customFolderPath?.abbreviatingWithTilde ?? "")
                        Button("Choose…") { exporter.chooseCustomFolder() }
                    }
                }
            }
            if let preset, !store.timeline.isEmpty {
                let estimate = ExportEstimate(preset: preset, source: store.timelineExportSource)
                if estimate.frameSize != .zero {
                    InspectorRow("Output", "\(Int(estimate.frameSize.width)) × \(Int(estimate.frameSize.height)) at \(Self.fpsText(estimate.framesPerSecond))")
                }
                InspectorRow("Length", store.timelineDuration.preciseTimecode)
                GridRow {
                    InspectorLabel("File Size")
                    Text((estimate.isRough ? "About " : "") + ByteCountFormatter.string(fromByteCount: Int64(estimate.totalBytes), countStyle: .file))
                        .fontWeight(.semibold)
                        .help(estimate.isRough
                              ? "An estimate: with a Quality setting, the size depends on the picture. Busy scenes come out bigger than still ones."
                              : "Estimated from the preset's data rate")
                }
            }
            GridRow {
                Button {
                    if let preset { store.exportTimeline(as: preset) }
                } label: {
                    Label("Export Timeline", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.timeline.isEmpty || preset == nil)
                .help("Export the timeline with the preset above")
                .padding(.top, 4)
                .gridCellColumns(2)
            }
        }
    }

    private static func fpsText(_ fps: Double) -> String {
        let rounded = (fps * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? "\(Int(rounded)) fps" : String(format: "%.3g fps", rounded)
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
            audioRows(item)
            GridRow {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button("Edit") { edit(item) }
                        .help(item.subclipID == nil ? "Open the source video in the clip viewer"
                                                    : "Open the subclip in the clip viewer")
                    Button("Duplicate") { store.duplicateTimelineItem(item.id) }
                    Button("Remove", role: .destructive) { store.removeTimelineItem(item.id) }
                }
                .gridCellColumns(2)
            }
        }
    }

    // MARK: Sound

    /// The clip's loudness meter and volume controls.
    @ViewBuilder
    private func audioRows(_ item: TimelineItem) -> some View {
        let plan = store.audioPlan(for: item)
        let settings = store.timelineSettings
        GridRow {
            Divider().gridCellColumns(2)
        }
        GridRow {
            InspectorLabel("Loudness")
            loudnessText(plan)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if plan.state != .measured(nil) {
            let target = plan.isMatching ? settings.loudnessTarget : nil
            let start = store.timelineStart(of: item)
            GridRow {
                InspectorLabel("Clip")
                LoudnessBar(value: plan.result, original: plan.gainDB == 0 ? nil : plan.measurement?.integrated,
                            target: target)
            }
            .help("The clip's loudness after its volume change. The faint mark is where it started; the line is the target.")
            GridRow {
                InspectorLabel("Live")
                LiveLoudnessBar(audio: store.timelineAudio, span: start..<(start + store.duration(of: item)), target: target)
            }
            .help("How loud the clip is right now, while it plays")
            GridRow {
                InspectorLabel("")
                LoudnessScale()
            }
            if settings.matchLoudness {
                GridRow {
                    InspectorLabel("Match")
                    Toggle("Match Target", isOn: Binding(
                        get: { item.audio.matchesTarget },
                        set: { var audio = item.audio; audio.matchesTarget = $0; store.setAudio(audio, for: item.id) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Turn this clip up or down to the timeline's loudness target")
                }
            }
            GridRow {
                InspectorLabel(plan.isMatching ? "Adjust" : "Volume")
                HStack(spacing: 6) {
                    Slider(value: Binding(
                        get: { item.audio.adjustDB },
                        set: { var audio = item.audio; audio.adjustDB = ($0 * 2).rounded() / 2; store.setAudio(audio, for: item.id) }
                    ), in: -20...20)
                    Text(item.audio.adjustDB.decibelChangeText)
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        var audio = item.audio
                        audio.adjustDB = 0
                        store.setAudio(audio, for: item.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(item.audio.adjustDB == 0)
                    .help("Back to 0 dB")
                }
            }
            .help(plan.isMatching ? "Louder or quieter than the target, for this clip" : "Turn this clip up or down")
            if plan.isLimited {
                GridRow {
                    Text("Turned up as far as it goes without distorting.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .gridCellColumns(2)
                }
            }
        }
    }

    @ViewBuilder
    private func loudnessText(_ plan: ProjectStore.AudioPlan) -> some View {
        switch plan.state {
        case nil, .measuring?:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Measuring…").foregroundStyle(.secondary)
            }
        case .failed?:
            Text("Couldn't measure").foregroundStyle(.secondary)
        case .measured(nil)?:
            Text("No sound").foregroundStyle(.secondary)
        case .measured(let measurement?)?:
            if let integrated = measurement.integrated {
                if plan.gainDB == 0 {
                    Text("\(integrated.loudnessText) LUFS")
                } else {
                    Text("\(integrated.loudnessText) → \(plan.result!.loudnessText) LUFS (\(plan.gainDB.decibelChangeText))")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                Text("Silent").foregroundStyle(.secondary)
            }
        }
    }

    /// Opens the clip in the clip viewer: its subclip, or the whole source video.
    private func edit(_ item: TimelineItem) {
        store.selection = [item.subclipID.map { .subclip($0) } ?? .clip(item.clipID)]
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
            .help("Save these timeline settings to use on other timelines")
        }
        .alert("Save Timeline Settings", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { presets.save(name: presetName, settings: store.timelineSettings) }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the aspect ratio, resolution, frame rate, fit, loudness, and export preset so you can load them into other projects. Settings with the same name are replaced.")
        }
    }
}
