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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                    }
                }

                if clip.hasAudio {
                    InspectorSection("Audio") {
                        InspectorRow("Codec", clip.audioCodec)
                        InspectorRow("Sample Rate", clip.audioSampleRate.map { String(format: "%.4g kHz", $0 / 1000) })
                        InspectorRow("Channels", clip.audioChannels.map(channels))
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
                    GradeSection(clip: clip)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThinScrollers())
        }
        .font(.subheadline)
        .controlSize(.small)
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
                    PressAndHoldButton(
                        title: "Show Original",
                        systemImage: controller?.isShowingOriginal == true ? "eye.slash" : "eye",
                        isEnabled: clip.enhanceSettings.hasLook && controller != nil
                    ) { pressed in
                        controller?.showOriginal(pressed)
                    }
                    .help("Hold to see the clip without effects or LUT. Release to see them again.")
                    .gridCellColumns(2)
                }

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

    /// Color: a LUT for grading or converting Apple Log, with a shortcut to Settings › Color.
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
                GridRow {
                    InspectorLabel("LUT")
                    lutMenu
                }
                if clip.lutID != nil, clip.lut == nil {
                    GridRow {
                        Label("This LUT is no longer in your library.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .gridCellColumns(2)
                    }
                }
                if let lut = clip.lut {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Image(nsImage: LUTSwatch.image(for: lut))
                            .resizable()
                            .frame(width: 96, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .help(lut.summary)
                    }
                    GridRow {
                        InspectorLabel("Intensity")
                        HStack(spacing: 6) {
                            Slider(value: $clip.lutIntensity, in: 0...1)
                            Text("\(Int((clip.lutIntensity * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
                if clip.logFormat != nil, clip.lutID == nil {
                    GridRow {
                        Text("This clip is log footage, so it looks flat until it's converted.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .gridCellColumns(2)
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Button("Convert to Rec. 709") { clip.lutID = ColorLUT.builtIns[0].id }
                    }
                }
            } else {
                GridRow {
                    Text(clip.isRotated ? "Not available for rotated video yet" : "None available for this clip")
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
        }
    }

    private var lutMenu: some View {
        Menu {
            Toggle("None", isOn: Binding(get: { clip.lutID == nil }, set: { if $0 { clip.lutID = nil } }))
            Section("Apple Log") { lutItems(library.appleLog) }
            Section("Looks") { lutItems(library.looks) }
            if !library.imported.isEmpty {
                Section("Imported") { lutItems(library.imported) }
            }
            Divider()
            Button("Manage LUTs…") { openColorSettings() }
        } label: {
            Text(clip.lut?.name ?? (clip.lutID == nil ? "None" : "Missing LUT"))
        }
        .fixedSize()
        .help("Choose a LUT to grade this clip")
    }

    private func lutItems(_ luts: [ColorLUT]) -> some View {
        ForEach(luts) { lut in
            Toggle(lut.name, isOn: Binding(get: { clip.lutID == lut.id }, set: { if $0 { clip.lutID = lut.id } }))
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
                    Text("Double-click a name to reset it. Applies after the LUT, to this video and all of its subclips.")
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
                Slider(value: $clip.grade[dynamicMember: control.keyPath], in: control.range)
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

// MARK: Building blocks

/// A small uppercase heading over a two-column grid of rows.
/// Click the heading to collapse or expand it; the choice is remembered per section.
private struct InspectorSection<Accessory: View, Content: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content
    @AppStorage private var isCollapsed: Bool

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
        _isCollapsed = AppStorage(wrappedValue: false, "inspectorCollapsed.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isCollapsed.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: 8)
                        Text(title.uppercased())
                            .font(.caption2.weight(.semibold))
                        Spacer(minLength: 4)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Show \(title)" : "Hide \(title)")
                .accessibilityLabel(title)
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

                if !isCollapsed {
                    accessory
                }
            }
            Divider()
            if !isCollapsed {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                    content
                }
                .transition(.opacity)
            }
        }
    }
}

/// Gives the surrounding scroll view an always-visible scroller at the small size,
/// instead of the regular-width one.
private struct ThinScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if observer == nil {
                // macOS resets the style when the system setting or mouse changes.
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        DispatchQueue.main.async { self?.apply() }
                    }
                }
            }
        }

        private func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
            scrollView.verticalScroller?.controlSize = .small
            scrollView.horizontalScroller?.controlSize = .small
        }

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

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

/// Label column: right-aligned, secondary color, fixed width so values line up.
private struct InspectorLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 78, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

/// One "Label   value" row. Shows "—" when the file doesn't include the value.
private struct InspectorRow: View {
    let title: String
    let value: String?

    init(_ title: String, _ value: String?) {
        self.title = title
        self.value = value
    }

    var body: some View {
        GridRow {
            InspectorLabel(title)
            Text(value ?? "—")
                .foregroundStyle(value == nil ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
