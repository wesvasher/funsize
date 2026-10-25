import SwiftUI

/// Sheet for creating or changing an export preset.
struct ExportPresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preset: ExportPreset
    private let isNew: Bool
    private let onSave: (ExportPreset) -> Void

    init(preset: ExportPreset, isNew: Bool, onSave: @escaping (ExportPreset) -> Void) {
        _preset = State(initialValue: preset)
        self.isNew = isNew
        self.onSave = onSave
    }

    private static let commonSizes: [(String, Int, Int)] = [
        ("4K UHD", 3840, 2160), ("1080p HD", 1920, 1080), ("720p HD", 1280, 720),
        ("540p", 960, 540), ("480p Wide", 854, 480), ("480p 4:3", 640, 480), ("360p", 640, 360),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $preset.name)
                    TextField("File name ending", text: $preset.fileSuffix, prompt: Text("Export"))
                    LabeledContent("Example") {
                        Text("My Clip - \(preset.fileSuffix.isEmpty ? "Export" : preset.fileSuffix).\(preset.container.fileExtension)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("File") {
                    Picker("Format", selection: $preset.container) {
                        ForEach(ExportPreset.Container.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: preset.container) { preset.normalize() }
                    if preset.container.canOptimizeForNetwork {
                        Toggle("Optimize for web streaming", isOn: $preset.optimizeForNetwork)
                            .help("Lets the movie start playing before it's fully downloaded.")
                    }
                }

                if preset.video != nil {
                    videoSection
                }
                audioSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Preset" : "Save") {
                    var saved = preset
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    if saved.fileSuffix.trimmingCharacters(in: .whitespaces).isEmpty { saved.fileSuffix = "Export" }
                    onSave(saved.normalized)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
    }

    // MARK: Video

    private var video: Binding<ExportPreset.Video> {
        Binding(get: { preset.video ?? .init() }, set: { preset.video = $0 })
    }

    private var videoSection: some View {
        let v = video.wrappedValue
        return Section("Video") {
            Picker("Codec", selection: video.codec) {
                ForEach(preset.container.videoCodecs) { Text($0.title).tag($0) }
            }

            Picker("Frame size", selection: video.frameSize) {
                ForEach(ExportPreset.FrameSize.allCases) { Text($0.title).tag($0) }
            }
            if v.frameSize != .source {
                LabeledContent(v.frameSize == .fitWithin ? "Maximum size" : "Size") {
                    HStack(spacing: 4) {
                        TextField("Width", value: video.width, format: .number.grouping(.never))
                            .frame(width: 60)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", value: video.height, format: .number.grouping(.never))
                            .frame(width: 60)
                        Menu {
                            ForEach(Self.commonSizes, id: \.0) { name, width, height in
                                Button("\(name) (\(width)×\(height))") {
                                    video.wrappedValue.width = width
                                    video.wrappedValue.height = height
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Common sizes")
                    }
                    .labelsHidden()
                }
                if v.frameSize == .fitWithin {
                    Toggle("Enlarge smaller videos", isOn: video.enlarges)
                    note("Keeps the picture's shape. For example, 4:3 video fit within 1920×1080 becomes 1440×1080.")
                } else {
                    Picker("If the shape differs", selection: video.scaling) {
                        ForEach(ExportPreset.Scaling.allCases) { Text($0.title).tag($0) }
                    }
                }
            }

            Picker("Frame rate", selection: video.frameRate) {
                Text("Same as Source").tag(Double?.none)
                Divider()
                ForEach(ExportPreset.frameRateChoices, id: \.self) { rate in
                    Text(ExportPreset.rateTitle(rate)).tag(Double?.some(rate))
                }
            }

            if v.codec.hasCompressionSettings {
                Picker("Compression", selection: video.rateControl) {
                    ForEach(ExportPreset.RateControl.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                switch v.rateControl {
                case .quality:
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: video.quality, in: 0.1...1, step: 0.05) {
                                EmptyView()
                            } minimumValueLabel: {
                                Text("Smaller").font(.caption)
                            } maximumValueLabel: {
                                Text("Better").font(.caption)
                            }
                            Text("\(Int((v.quality * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                case .bitRate:
                    LabeledContent("Average bit rate") {
                        HStack(spacing: 4) {
                            TextField("Mbps", value: video.bitRateMbps, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 60)
                            Stepper("", value: video.bitRateMbps, in: 0.5...400, step: 0.5)
                                .labelsHidden()
                            Text("Mbps").foregroundStyle(.secondary)
                        }
                        .labelsHidden()
                    }
                    note("About \(sizePerMinute(v.bitRateMbps)) per minute of video.")
                }

                Picker("Keyframes", selection: video.keyframeInterval) {
                    Text("Automatic").tag(0)
                    Divider()
                    Text("Every frame").tag(1)
                    ForEach([12, 15, 24, 30, 60, 120, 300], id: \.self) { Text("Every \($0) frames").tag($0) }
                }
                .help("More keyframes make scrubbing and editing smoother but files bigger.")
            } else {
                note("ProRes sets its own data rate. It makes large, high-quality files for editing.")
            }
        }
    }

    // MARK: Audio

    private var audio: Binding<ExportPreset.Audio> {
        Binding(get: { preset.audio ?? .init() }, set: { preset.audio = $0 })
    }

    private var audioSection: some View {
        Section("Audio") {
            if preset.container.holdsVideo {
                Toggle("Include audio", isOn: Binding(
                    get: { preset.audio != nil },
                    set: { include in
                        preset.audio = include ? ExportPreset.Audio(codec: preset.container.audioCodecs[0]) : nil
                    }
                ))
            }
            if let a = preset.audio {
                Picker("Codec", selection: audio.codec) {
                    ForEach(preset.container.audioCodecs) { Text($0.title).tag($0) }
                }
                if a.codec == .aac {
                    Picker("Bit rate", selection: audio.bitRateKbps) {
                        ForEach([64, 96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                } else {
                    Picker("Bit depth", selection: audio.bitDepth) {
                        Text("16-bit").tag(16)
                        Text("24-bit").tag(24)
                    }
                }
                Picker("Sample rate", selection: audio.sampleRate) {
                    Text("Same as Source").tag(Double?.none)
                    Divider()
                    Text("44.1 kHz").tag(Double?.some(44_100))
                    Text("48 kHz").tag(Double?.some(48_000))
                    if a.codec != .aac {
                        Text("96 kHz").tag(Double?.some(96_000))
                    }
                }
                Picker("Channels", selection: audio.channels) {
                    Text("Same as Source").tag(Int?.none)
                    Divider()
                    Text("Mono").tag(Int?.some(1))
                    Text("Stereo").tag(Int?.some(2))
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func sizePerMinute(_ mbps: Double) -> String {
        let bytes = Int64(mbps * 1_000_000 / 8 * 60)
        return bytes.formatted(.byteCount(style: .file))
    }
}
