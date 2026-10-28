import SwiftUI

/// Right-hand panel for a source video or subclip: file and format details, plus effects.
/// Laid out compactly (like Finder's Get Info) so most clips fit without scrolling.
struct ClipInspectorView: View {
    /// The source video (for a subclip, the video it comes from).
    @Bindable var clip: Clip
    var subclip: Subclip? = nil
    /// The clip's preview player, for "Show Original".
    var controller: ClipPlayerController?
    /// Selects the source video of `subclip`.
    var showSource: (() -> Void)? = nil
    @State private var presets = EffectsPresetStore.shared
    @State private var library = LUTLibrary.shared
    @Environment(\.openSettings) private var openSettings
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var isConfirmingReset = false

    var body: some View {
        InspectorPanel {
            sections
        } footer: {
            footer
        }
    }

    /// Show Original and Reset All, below the sections.
    private var footer: some View {
        HStack(spacing: 8) {
            if clip.canEnhance {
                PressAndHoldButton(
                    title: "Show Original",
                    systemImage: controller?.isShowingOriginal == true ? "eye.slash" : "eye",
                    isEnabled: clip.enhanceSettings.hasLook && controller != nil
                ) { pressed in
                    controller?.showOriginal(pressed)
                }
                .help("Hold to see the video without its effects, LUT, look, and grade. Release to see them again.")
            }
            Button {
                isConfirmingReset = true
            } label: {
                Label("Reset All", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .disabled(clip.isAtDefaults)
            .help("Put timing, captions, effects, LUT, look, grade, and scale and position back to how they were when the video was imported")
        }
        .confirmationDialog("Reset all settings for “\(clip.name)”?", isPresented: $isConfirmingReset) {
            Button("Reset All", role: .destructive) { clip.resetAll() }
        } message: {
            Text("Timing, captions, effects, LUT, look, grade, and scale and position go back to how they were when the video was imported. Its subclips share these settings, so they change too. In and out marks are kept. You can undo this with Edit › Undo.")
        }
    }

    private var sections: some View {
        Group {
                if let subclip {
                    SubclipSection(subclip: subclip, clip: clip, clock: controller?.clock, showSource: showSource)
                }

                InspectorSection(subclip == nil ? "File" : "Source Video") {
                    InspectorRow("Name", clip.name)
                    InspectorRow("Format", clip.containerName)
                    InspectorRow("Size", clip.fileSize.formatted(.byteCount(style: .file)))
                    InspectorRow("Duration", clip.duration.preciseTimecode)
                    InspectorRow("Created", clip.creationDate?.formatted(date: .abbreviated, time: .shortened))
                    GridRow {
                        InspectorLabel("Location")
                        Button(clip.url.deletingLastPathComponent().lastPathComponent) {
                            NSWorkspace.shared.activateFileViewerSelecting([clip.url])
                        }
                        .buttonStyle(.link)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Show in Finder: \(clip.url.path(percentEncoded: false))")
                    }
                }

                if clip.hasVideo {
                    InspectorSection("Video") {
                        InspectorRow("Codec", clip.videoCodec)
                        InspectorRow("Frame Rate", frameRate)
                        InspectorRow("Scan", scan)
                        if clip.encodedSize != .zero {
                            InspectorRow("Resolution", dimensions(clip.encodedSize))
                        }
                        if clip.displaySize != clip.encodedSize, clip.displaySize != .zero {
                            InspectorRow("Display Size", dimensions(clip.displaySize))
                        }
                        if let par = clip.pixelAspectRatio, par.width != par.height {
                            InspectorRow("Pixel Aspect", "\(Int(par.width)):\(Int(par.height))")
                        }
                        InspectorRow("Color", clip.colorSpace)
                        InspectorRow("Data Rate", clip.videoBitRate.map(bitRate))
                        if clip.canEnhance {
                            FrameRows(clip: clip)
                        }
                    }
                }

                if clip.hasAudio {
                    InspectorSection("Audio") {
                        InspectorRow("Codec", clip.audioCodec)
                        InspectorRow("Sample Rate", clip.audioSampleRate.map { String(format: "%.4g kHz", $0 / 1000) })
                        InspectorRow("Channels", clip.audioChannels.map(channels))
                        if let controller {
                            VolumeRows(clip: clip, controller: controller)
                        }
                    }
                }

                if clip.hasCaptions {
                    InspectorSection("Captions") {
                        GridRow {
                            InspectorLabel("Show")
                            Toggle("Captions", isOn: $clip.showCaptions)
                                .toggleStyle(.switch)
                        }
                        InspectorRow("Source", clip.captionName)
                        if clip.captionName?.localizedCaseInsensitiveContains("transcribed") == true {
                            GridRow {
                                Text("Transcribed from the audio by macOS. Shown in the preview only, not in exports.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .gridCellColumns(2)
                            }
                        }
                    }
                }

                if clip.canDeinterlace {
                    timing
                }

                if clip.hasVideo {
                    effects
                    color
                    GradeSection(clip: clip, controller: controller)
                }
        }
    }

    /// Frame timing: turning interlaced fields into frames.
    private var timing: some View {
        InspectorSection("Timing") {
            GridRow {
                InspectorLabel("Deinterlace")
                Toggle("To \(clip.deinterlacedRateLabel)", isOn: $clip.deinterlace)
                    .toggleStyle(.switch)
                    .help("Turns each field into its own frame (\(String(format: "%.4g", clip.frameRate * 2))i → \(clip.deinterlacedRateLabel)).")
            }
            if clip.deinterlace {
                GridRow {
                    InspectorLabel("Field Order")
                    Picker("Field Order", selection: $clip.fieldOrderChoice) {
                        Text("Auto (\((clip.detectedFieldOrder ?? .bottomFirst) == .topFirst ? "Top" : "Bottom") First)").tag(FieldOrder?.none)
                        Divider()
                        ForEach(FieldOrder.allCases) { order in
                            Text(order.title).tag(FieldOrder?.some(order))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Switch this if motion looks jittery or steps backward.")
                }
            }
        }
    }

    /// Picture effects: noise, resolution, sharpening.
    @ViewBuilder
    private var effects: some View {
        InspectorSection("Effects") {
            if clip.canEnhance {
                presetMenu
            }
        } content: {
            if clip.canEnhance {
                GridRow {
                    InspectorLabel("Reduce Noise")
                    Toggle("On", isOn: $clip.denoise)
                        .toggleStyle(.switch)
                        .disabled(!Enhancer.canReduceNoise)
                        .help("Removes tape noise and grain by comparing each frame with its neighbors.")
                }
                if clip.denoise {
                    GridRow {
                        InspectorLabel("Strength")
                        HStack(spacing: 6) {
                            Slider(value: $clip.denoiseStrength, in: 0.1...1)
                            Text("\(Int((clip.denoiseStrength * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }

                GridRow {
                    InspectorLabel("Enhance")
                    Picker("Enhance", selection: $clip.upscale) {
                        ForEach(UpscaleMode.allCases) { mode in
                            Text(mode.title)
                                .tag(mode)
                                .selectionDisabled(!Enhancer.canUpscale(mode, displaySize: clip.displaySize))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Increases resolution with Apple's machine-learning video scaler.")
                }
                if clip.upscale != .off {
                    InspectorRow("Output", dimensions(clip.outputSize))
                }
                if clip.upscale == .best {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        ModelStatusView(size: clip.displaySize)
                    }
                }

                GridRow {
                    InspectorLabel("Sharpen")
                    HStack(spacing: 6) {
                        Slider(value: $clip.sharpen, in: 0...1)
                        Text(clip.sharpen < 0.01 ? "Off" : "\(Int((clip.sharpen * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    .help("A light final sharpen. Too much makes tape noise stand out.")
                }
            } else {
                GridRow {
                    Text(clip.isRotated ? "Not available for rotated video yet" : "None available for this clip")
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }

            if let error = clip.effectsError {
                GridRow {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .gridCellColumns(2)
                }
            }

            if clip.enhanceSettings.isActive {
                GridRow {
                    Text("Timing and effects show in the preview and are used for exports of this clip. The timeline uses the original.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(2)
                }
            }
        }
        .alert("Save Effects Set", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { presets.save(name: presetName, from: clip) }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves Reduce Noise, Enhance, and Sharpen so you can use them on other clips. A set with the same name is replaced.")
        }
    }

    /// Color: a LUT (usually converting log footage), then a creative look, each with an
    /// on/off switch. Shortcut to Settings › Color.
    private var color: some View {
        InspectorSection("Color") {
            Button {
                openColorSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Color settings and LUT library")
        } content: {
            if clip.canEnhance {
                if let log = clip.logFormat {
                    InspectorRow("Footage", log)
                }
                ColorPart(title: "LUT", noun: "LUT", chosenID: $clip.lutID, chosen: clip.lut,
                          intensity: $clip.lutIntensity, isOn: $clip.lutEnabled, controller: controller) {
                    Section("Apple Log") { items(library.appleLog, selection: $clip.lutID, isOn: $clip.lutEnabled) }
                    if !library.imported.isEmpty {
                        Section("Imported") { items(library.imported, selection: $clip.lutID, isOn: $clip.lutEnabled) }
                    }
                    Divider()
                    Button("Manage LUTs…") { openColorSettings() }
                }
                .help("A LUT converts or grades the video. Applies first.")
                if clip.logFormat != nil, clip.lutID == nil {
                    GridRow {
                        Text("This clip is log footage, so it looks flat until it's converted.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .gridCellColumns(2)
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Button("Convert to Rec. 709") {
                            clip.lutID = ColorLUT.builtIns[0].id
                            clip.lutEnabled = true
                        }
                    }
                }
                ColorPart(title: "Look", noun: "look", chosenID: $clip.lookID, chosen: clip.look,
                          intensity: $clip.lookIntensity, isOn: $clip.lookEnabled, controller: controller) {
                    Section("Looks") { items(library.looks, selection: $clip.lookID, isOn: $clip.lookEnabled) }
                    if !library.imported.isEmpty {
                        Section("Imported") { items(library.imported, selection: $clip.lookID, isOn: $clip.lookEnabled) }
                    }
                    Divider()
                    Button("Manage LUTs…") { openColorSettings() }
                }
                .help("A creative look. Applies after the LUT and before the Grade.")
            } else {
                GridRow {
                    Text(clip.isRotated ? "Not available for rotated video yet" : "None available for this clip")
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
        }
    }

    /// Menu items that choose a LUT. Choosing one also turns its switch on.
    private func items(_ luts: [ColorLUT], selection: Binding<UUID?>, isOn: Binding<Bool>) -> some View {
        ForEach(luts) { lut in
            Toggle(lut.name, isOn: Binding(get: { selection.wrappedValue == lut.id }, set: {
                guard $0 else { return }
                selection.wrappedValue = lut.id
                isOn.wrappedValue = true
            }))
        }
    }

    private func openColorSettings() {
        UserDefaults.standard.set(SettingsPage.color.rawValue, forKey: SettingsPage.storageKey)
        openSettings()
    }

    /// Save, load, and reset effect settings.
    private var presetMenu: some View {
        let current = presets.presets.first { $0.matches(clip) }
        return Menu {
            if presets.presets.isEmpty {
                Text("No Saved Sets")
            } else {
                Section("Load") {
                    ForEach(presets.presets) { preset in
                        Toggle(preset.name, isOn: Binding(
                            get: { preset.matches(clip) },
                            set: { _ in preset.apply(to: clip) }
                        ))
                    }
                }
            }
            Divider()
            Button("Save Current Settings…") {
                presetName = current?.name ?? ""
                isNamingPreset = true
            }
            Button("Reset to Defaults") { clip.resetEffects() }
            if !presets.presets.isEmpty {
                Menu("Delete") {
                    ForEach(presets.presets) { preset in
                        Button(preset.name, role: .destructive) { presets.delete(preset) }
                    }
                }
            }
        } label: {
            Text(current?.name ?? (clip.enhanceSettings.hasEffects ? "Custom" : "Default"))
                .font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Effects sets: save, load, or reset these settings")
    }

    // MARK: Formatting

    private var frameRate: String {
        guard clip.frameRate > 0 else { return "—" }
        let source = String(format: "%.4g fps", clip.frameRate)
        return clip.isDeinterlacing ? "\(source) → \(String(format: "%.4g", clip.outputFrameRate))" : source
    }

    private var scan: String {
        switch clip.isInterlaced {
        case true?: "Interlaced, \((clip.detectedFieldOrder ?? clip.fieldOrder) == .topFirst ? "top" : "bottom") first"
        case false?: "Progressive"
        case nil: "Not specified"
        }
    }

    private func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }

    private func bitRate(_ bitsPerSecond: Float) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kbps", bitsPerSecond / 1_000)
    }

    private func channels(_ count: Int) -> String {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1 Surround"
        case 8: "7.1 Surround"
        default: "\(count) channels"
        }
    }
}

/// Download state for the 4× model, with a button to fetch it.
private struct ModelStatusView: View {
    let size: CGSize
    private var model: SuperResolutionModel { .shared }

    var body: some View {
        Group {
            switch model.status {
            case .unknown:
                ProgressView().controlSize(.mini)
            case .unsupported:
                Text("Not supported on this Mac").foregroundStyle(.secondary)
            case .needsDownload:
                VStack(alignment: .leading, spacing: 2) {
                    Button("Download Model") { model.download(for: size) }
                    Text("One-time download from Apple").font(.caption2).foregroundStyle(.secondary)
                }
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: progress)
                    Text("Downloading… \(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                }
            case .ready:
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 2) {
                    Text(message).foregroundStyle(.red).lineLimit(2)
                    Button("Try Again") { model.download(for: size) }
                }
            }
        }
        .onAppear { model.refresh(for: size) }
    }
}

/// Basic color correction sliders, applied after the LUT. The preview follows them as you drag.
private struct GradeSection: View {
    @Bindable var clip: Clip
    /// The preview, which shows a quick low-resolution version while a slider is dragged.
    var controller: ClipPlayerController?
    @State private var saveError: String?

    /// One slider: what it changes, its range, and how its value reads.
    private struct Control: Identifiable {
        let title: String
        let help: String
        let keyPath: WritableKeyPath<ColorGrade, Double>
        var range: ClosedRange<Double> = -1...1
        var isExposure = false
        var id: String { title }
    }

    private static let light: [Control] = [
        Control(title: "Exposure", help: "Brightens or darkens the whole picture, in stops of light",
                keyPath: \.exposure, range: -2...2, isExposure: true),
        Control(title: "Contrast", help: "Makes the difference between dark and bright areas smaller or bigger", keyPath: \.contrast),
        Control(title: "Highlights", help: "Darken to recover detail in bright areas, or brighten them", keyPath: \.highlights),
        Control(title: "Shadows", help: "Brighten to open up dark areas, or deepen them", keyPath: \.shadows),
    ]

    private static let color: [Control] = [
        Control(title: "Temperature", help: "Cooler (bluer) to the left, warmer (more orange) to the right", keyPath: \.temperature),
        Control(title: "Tint", help: "Greener to the left, more magenta to the right", keyPath: \.tint),
        Control(title: "Saturation", help: "How colorful everything is. All the way left is black and white", keyPath: \.saturation),
        Control(title: "Vibrance", help: "Boosts or mutes dull colors while mostly leaving strong colors alone", keyPath: \.vibrance),
    ]

    var body: some View {
        InspectorSection("Grade") {
            Menu {
                Button("Reset Grade") { clip.grade = ColorGrade() }
                    .disabled(clip.grade.isIdentity)
                Divider()
                Button("Save as LUT") { saveAsLUT() }
                    .disabled(clip.grade.isIdentity)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reset the grade, or save it to your LUT library")
        } content: {
            if clip.canEnhance {
                group("Light", Self.light)
                group("Color", Self.color)
                GridRow {
                    Text("Double-click a name to reset it. Applies after the LUT and look, to this video and all of its subclips.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(2)
                }
            } else {
                GridRow {
                    Text(clip.isRotated ? "Not available for rotated video yet" : "None available for this clip")
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
        }
        .alert("Couldn't Save the LUT", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ controls: [Control]) -> some View {
        GridRow {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .gridCellColumns(2)
                .padding(.top, 2)
        }
        ForEach(controls) { control in
            row(control)
        }
    }

    private func row(_ control: Control) -> some View {
        let value = clip.grade[keyPath: control.keyPath]
        return GridRow {
            InspectorLabel(control.title)
                .fontWeight(value == 0 ? nil : .medium)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { clip.grade[keyPath: control.keyPath] = 0 }
                .help("\(control.help). Double-click to reset.")
            HStack(spacing: 6) {
                Slider(value: $clip.grade[dynamicMember: control.keyPath], in: control.range) { editing in
                    editing ? controller?.beginColorAdjustment() : controller?.endColorAdjustment()
                }
                    .help(control.help)
                Text(Self.format(value, exposure: control.isExposure))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? .secondary : .primary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    /// "+0.5" for exposure (stops), "+25" for the rest (−100…+100).
    private static func format(_ value: Double, exposure: Bool) -> String {
        if exposure {
            let rounded = (value * 10).rounded() / 10
            return rounded == 0 ? "0" : String(format: "%+.1f", rounded)
        }
        let percent = Int((value * 100).rounded())
        return percent == 0 ? "0" : String(format: "%+d", percent)
    }

    /// Adds the grade to the LUT library (Settings › Color), to reuse or export.
    private func saveAsLUT() {
        do {
            let lut = clip.grade.makeLUT(name: "\(clip.name) Grade")
            try LUTLibrary.shared.add(lut)
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Name and range of a subclip, and a link back to its source video.
private struct SubclipSection: View {
    @Bindable var subclip: Subclip
    let clip: Clip
    let clock: FrameClock?
    let showSource: (() -> Void)?

    var body: some View {
        InspectorSection("Subclip") {
            GridRow {
                InspectorLabel("Name")
                TextField("Name", text: $subclip.name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            GridRow {
                InspectorLabel("Source")
                Button(clip.name) { showSource?() }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Show the source video")
            }
            let range = subclip.range(in: clip.duration)
            InspectorRow("In", time(range.lowerBound))
            InspectorRow("Out", lastFrame(range.upperBound))
            InspectorRow("Length", time(range.upperBound - range.lowerBound))
            GridRow {
                Text("Mark In and Out to change this subclip. The source video isn't changed. Effects and Color below belong to the source video, so they apply to all of its subclips.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .gridCellColumns(2)
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        if let clock, clock.fps > 0 { return clock.timecode(seconds: seconds) }
        return seconds.preciseTimecode
    }

    /// The out point shown as its last included frame, like the transport bar.
    private func lastFrame(_ end: Double) -> String {
        if let clock, clock.fps > 0 { return clock.timecode(frames: max(0, clock.frameIndex(at: end) - 1)) }
        return end.preciseTimecode
    }
}

/// The Video section's framing: scale and position the picture inside its frame (which keeps its
/// size), with a background color or transparency around it.
private struct FrameRows: View {
    @Bindable var clip: Clip

    var body: some View {
        GridRow {
            Divider().gridCellColumns(2)
        }
        GridRow {
            InspectorLabel("Scale")
            sliderRow(value: $clip.layout.scale, in: FrameLayout.scaleRange, reset: 1,
                      label: "\(Int((clip.layout.scale * 100).rounded()))%",
                      help: "Make the picture smaller or larger inside the frame. The frame keeps its size.")
        }
        GridRow {
            InspectorLabel("Position X")
            sliderRow(value: $clip.layout.offsetX, in: -1...1, reset: 0,
                      label: pixels(clip.layout.offsetX * clip.outputSize.width),
                      help: "Move the picture left or right, in pixels of the frame")
        }
        GridRow {
            InspectorLabel("Position Y")
            sliderRow(value: $clip.layout.offsetY, in: -1...1, reset: 0,
                      label: pixels(clip.layout.offsetY * clip.outputSize.height),
                      help: "Move the picture up or down, in pixels of the frame")
        }
        GridRow {
            InspectorLabel("Background")
            HStack(spacing: 6) {
                Picker("Background", selection: $clip.layout.background) {
                    Text("Color").tag(FrameLayout.Background.color)
                    Text("Transparent").tag(FrameLayout.Background.transparent)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if clip.layout.background == .color {
                    ColorPicker("Background Color", selection: Binding(
                        get: { clip.layout.backgroundColor.cgColor },
                        set: { if let color = RGBAColor($0) { clip.layout.backgroundColor = color } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
            }
            .help(clip.layout.background == .color
                  ? "The color around the picture when it doesn't fill the frame"
                  : "Leave the space around the picture clear. Only Apple ProRes 4444 exports keep transparency; other formats show black. The viewer shows it as a checkerboard.")
        }
        if !clip.layout.isIdentity {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Button("Reset Scale and Position", systemImage: "arrow.counterclockwise") {
                    clip.layout.scale = 1
                    clip.layout.offsetX = 0
                    clip.layout.offsetY = 0
                }
                .help("Make the picture fill the frame again")
            }
        }
    }

    /// A slider with its value beside it. Double-click the value to reset it.
    private func sliderRow(value: Binding<Double>, in range: ClosedRange<Double>, reset: Double,
                           label: String, help: String) -> some View {
        HStack(spacing: 6) {
            Slider(value: value, in: range)
                .help(help)
            Text(label)
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
                .onTapGesture(count: 2) { value.wrappedValue = reset }
                .help("Double-click to reset")
        }
    }

    private func pixels(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded == 0 ? "0 px" : "\(rounded > 0 ? "+" : "−")\(abs(rounded)) px"
    }
}

/// The Audio section's volume controls: Edit Volume opens the tall waveform in the clip viewer
/// with its volume line, and Add Keyframe puts a keyframe on it at the playhead. A clicked
/// keyframe shows below, to switch between linear and spline and set how much it curves.
/// For a subclip these are the subclip's own keyframes; the source video's stay as they are.
private struct VolumeRows: View {
    @Bindable var clip: Clip
    @Bindable var controller: ClipPlayerController

    var body: some View {
        GridRow {
            InspectorLabel("Volume")
            Button(controller.isEditingVolume ? "Done" : "Edit Volume",
                   systemImage: controller.isEditingVolume ? "checkmark" : "slider.vertical.3") {
                withAnimation(.snappy(duration: 0.25)) { controller.isEditingVolume.toggle() }
            }
            .help(controller.isEditingVolume
                  ? "Close the volume editor"
                  : "Make the waveform in the viewer taller and show its volume line, to change the volume over time with keyframes")
        }
        if controller.isEditingVolume {
            GridRow {
                InspectorLabel("Keyframes")
                HStack(spacing: 6) {
                    Button("Add Keyframe", systemImage: "plus.diamond", action: addKeyframe)
                        .help("Add a volume keyframe at the playhead")
                    Button("Remove All", systemImage: "trash") {
                        controller.volumeEnvelope.removeAll()
                        controller.selectedKeyframe = nil
                    }
                    .labelStyle(.iconOnly)
                    .disabled(controller.volumeEnvelope.isEmpty)
                    .help(controller.subclip == nil
                          ? "Remove every volume keyframe, so the sound plays as recorded"
                          : "Remove every volume keyframe from this subclip, so it plays as recorded. The source video's keyframes aren't changed.")
                }
            }

            if let id = controller.selectedKeyframe, let key = controller.volumeEnvelope.keyframe(id) {
                selectedKeyframe(key)
            } else {
                GridRow {
                    Text("Drag a keyframe on the waveform up or down to change the volume, or sideways to move it. Double-click the waveform to add one. Click a keyframe to select it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
        }
    }

    @ViewBuilder
    private func selectedKeyframe(_ key: VolumeEnvelope.Keyframe) -> some View {
        GridRow {
            Divider().gridCellColumns(2)
        }
        GridRow {
            Text("Selected Keyframe")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .gridCellColumns(2)
        }
        InspectorRow("Time", controller.clock.timecode(seconds: key.time))
        GridRow {
            InspectorLabel("Level")
            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { VolumeEnvelope.position(forDB: key.gainDB) },
                    set: { position in
                        let db = VolumeEnvelope.db(forPosition: position)
                        controller.volumeEnvelope.move(key.id, to: key.time, gainDB: db.isFinite ? db : VolumeEnvelope.minDB)
                    }
                ), in: 0...1)
                .help("The volume at this keyframe")
                Text(VolumeEnvelope.label(forDB: key.gainDB))
                    .font(.caption.monospacedDigit())
                    .frame(width: 58, alignment: .trailing)
            }
        }
        GridRow {
            InspectorLabel("Type")
            Picker("Type", selection: Binding(
                get: { key.isSmooth },
                set: { controller.volumeEnvelope.setSmooth(key.id, $0) }
            )) {
                Text("Linear").tag(false)
                Text("Spline").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("Linear meets the keyframe at a corner; spline curves through it")
        }
        GridRow {
            InspectorLabel("Curve")
            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { key.curve },
                    set: { controller.volumeEnvelope.setCurve(key.id, $0) }
                ), in: 0...1)
                .help("How much the spline curves through this keyframe: from nearly straight to fully eased")
                Text("\(Int((key.curve * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 58, alignment: .trailing)
            }
            .disabled(!key.isSmooth)
        }
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            Button("Delete Keyframe", systemImage: "trash", role: .destructive) {
                controller.volumeEnvelope.remove(key.id)
                controller.selectedKeyframe = nil
            }
            .help("Delete this keyframe")
        }
    }

    private func addKeyframe() {
        let clock = controller.clock
        // On the frame on screen, so it lines up with what you see.
        let time = clock.fps > 0 ? clock.seconds(ofFrame: clock.frameIndex(at: controller.currentTime)) : controller.currentTime
        controller.selectedKeyframe = controller.volumeEnvelope.addKeyframe(
            at: time, minimumGap: clock.fps > 0 ? clock.seconds(ofFrame: 1) / 2 : 0.01)
    }
}

/// One part of the Color section (LUT or Look): a heading with an on/off switch,
/// a menu to choose, a swatch, and an intensity slider.
private struct ColorPart<Choices: View>: View {
    let title: String
    /// Lowercase name for messages, e.g. "look".
    let noun: String
    @Binding var chosenID: UUID?
    let chosen: ColorLUT?
    @Binding var intensity: Double
    @Binding var isOn: Bool
    let controller: ClipPlayerController?
    @ViewBuilder let choices: () -> Choices

    var body: some View {
        GridRow {
            HStack {
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
                // With nothing chosen there's nothing to turn on, so the switch shows off.
                Toggle(title, isOn: Binding(get: { isOn && chosenID != nil }, set: { isOn = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(chosenID == nil)
                    .help(chosenID == nil ? "Choose a \(noun) first" : (isOn ? "Turn the \(noun) off" : "Turn the \(noun) on"))
                    .accessibilityLabel("Use \(title)")
            }
            .padding(.top, 6)
            .gridCellColumns(2)
        }
        GridRow {
            InspectorLabel(title)
            // Fills the column; long names are shortened to fit.
            Menu {
                Toggle("None", isOn: Binding(get: { chosenID == nil }, set: { if $0 { chosenID = nil } }))
                choices()
            } label: {
                Text(chosen?.name ?? (chosenID == nil ? "None" : "Missing \(title)"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(chosen?.name ?? "")
        }
        if let chosen {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Image(nsImage: LUTSwatch.image(for: chosen))
                    .resizable()
                    .frame(width: 96, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .opacity(isOn ? 1 : 0.4)
                    .help(chosen.summary)
            }
        }
        if chosenID != nil, chosen == nil {
            GridRow {
                Label("This \(noun) is no longer in your library.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .gridCellColumns(2)
            }
        }
        if chosen != nil {
            GridRow {
                InspectorLabel("Intensity")
                HStack(spacing: 6) {
                    Slider(value: $intensity, in: 0...1) { editing in
                        editing ? controller?.beginColorAdjustment() : controller?.endColorAdjustment()
                    }
                    Text("\(Int((intensity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
                .disabled(!isOn)
            }
        }
    }
}

// MARK: Building blocks

/// A button that reports when it's pressed and released (for before/after comparisons).
private struct PressAndHoldButton: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let onChange: (Bool) -> Void

    var body: some View {
        Button {} label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(HoldStyle(onChange: onChange))
        .disabled(!isEnabled)
    }

    private struct HoldStyle: ButtonStyle {
        let onChange: (Bool) -> Void
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .padding(.vertical, 4)
                .foregroundStyle(configuration.isPressed ? Color.white : (isEnabled ? Color.primary : Color.secondary))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(configuration.isPressed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                )
                .contentShape(Rectangle())
                .onChange(of: configuration.isPressed) { _, pressed in onChange(pressed) }
        }
    }
}

