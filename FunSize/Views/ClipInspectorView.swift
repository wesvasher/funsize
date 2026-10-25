import SwiftUI

/// Right-hand panel for a clip: file and format details, plus effects.
/// Laid out compactly (like Finder's Get Info) so most clips fit without scrolling.
struct ClipInspectorView: View {
    @Bindable var clip: Clip

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InspectorSection("File") {
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

                if clip.hasVideo {
                    effects
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .controlSize(.small)
    }

    @ViewBuilder
    private var effects: some View {
        InspectorSection("Effects") {
            if clip.canDeinterlace {
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
            } else if !clip.canDeinterlace {
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
                    Text("Shown in the preview and used for exports of this clip. The timeline uses the original.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(2)
                }
            }
        }
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

// MARK: Building blocks

/// A small uppercase heading over a two-column grid of rows.
private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                content
            }
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
