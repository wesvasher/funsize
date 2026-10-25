import SwiftUI

/// Right-hand panel for a clip: file and format details, plus effects.
struct ClipInspectorView: View {
    @Bindable var clip: Clip

    var body: some View {
        Form {
            Section("File") {
                LabeledContent("Name", value: clip.name)
                row("Format", clip.containerName)
                LabeledContent("Size", value: clip.fileSize.formatted(.byteCount(style: .file)))
                LabeledContent("Duration", value: clip.duration.preciseTimecode)
                row("Created", clip.creationDate?.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Location") {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
                    } label: {
                        Label(clip.url.deletingLastPathComponent().lastPathComponent, systemImage: "folder")
                    }
                    .buttonStyle(.link)
                    .help(clip.url.path(percentEncoded: false))
                }
            }

            if clip.hasVideo {
                Section("Video") {
                    row("Codec", clip.videoCodec)
                    LabeledContent("Frame Rate", value: frameRate)
                    LabeledContent("Scan", value: scan)
                    if clip.encodedSize != .zero {
                        LabeledContent("Resolution", value: dimensions(clip.encodedSize))
                    }
                    if clip.displaySize != clip.encodedSize, clip.displaySize != .zero {
                        LabeledContent("Display Size", value: dimensions(clip.displaySize))
                    }
                    if let par = clip.pixelAspectRatio, par.width != par.height {
                        LabeledContent("Pixel Aspect", value: "\(Int(par.width)):\(Int(par.height))")
                    }
                    row("Color", clip.colorSpace)
                    row("Data Rate", clip.videoBitRate.map(bitRate))
                }
            }

            if clip.hasAudio {
                Section("Audio") {
                    row("Codec", clip.audioCodec)
                    row("Sample Rate", clip.audioSampleRate.map { String(format: "%.4g kHz", $0 / 1000) })
                    row("Channels", clip.audioChannels.map(channels))
                }
            }

            if clip.hasVideo {
                Section {
                    if clip.canDeinterlace {
                        Toggle(isOn: $clip.deinterlace) {
                            Text("Deinterlace to \(clip.deinterlacedRateLabel)")
                            Text("Turns each field into its own frame (\(String(format: "%.4g", clip.frameRate * 2))i → \(clip.deinterlacedRateLabel)). Applies to the preview and exports.")
                        }
                        .toggleStyle(.switch)

                        if clip.deinterlace {
                            Picker(selection: $clip.fieldOrderChoice) {
                                Text("Automatic (\((clip.detectedFieldOrder ?? .bottomFirst).title))").tag(FieldOrder?.none)
                                Divider()
                                ForEach(FieldOrder.allCases) { order in
                                    Text(order.title).tag(FieldOrder?.some(order))
                                }
                            } label: {
                                Text("Field Order")
                                Text("Switch this if motion looks jittery or steps backward.")
                            }
                        }
                    } else {
                        Text("No effects available for this clip.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Effects")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Formatting

    private var frameRate: String {
        guard clip.frameRate > 0 else { return "—" }
        let source = String(format: "%.4g fps", clip.frameRate)
        return clip.isDeinterlacing ? "\(source) → \(String(format: "%.4g fps", clip.outputFrameRate))" : source
    }

    private var scan: String {
        switch clip.isInterlaced {
        case true?: "Interlaced, \((clip.detectedFieldOrder ?? clip.fieldOrder).title.lowercased())"
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

    /// A row that shows "—" when the file doesn't include the value.
    private func row(_ title: String, _ value: String?) -> some View {
        LabeledContent(title, value: value ?? "—")
    }
}
