import SwiftUI

/// Asks how to make a new source video from the clip in the viewer: its name and format,
/// whether to keep only the in-to-out range, which settings to bake into the picture, and
/// whether the new clip inherits the rest.
struct NewSourceSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let clip: Clip
    let controller: ClipPlayerController
    var subclip: Subclip?

    @State private var options: NewSourceOptions
    @AppStorage("newSourcePreset") private var savedPresetID = ""

    init(clip: Clip, controller: ClipPlayerController, subclip: Subclip?) {
        self.clip = clip
        self.controller = controller
        self.subclip = subclip
        _options = State(initialValue: NewSourceOptions(name: "\(subclip?.name ?? clip.name) Copy"))
    }

    private var settings: EnhanceSettings { clip.enhanceSettings }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Source Video")
                    .font(.headline)
                Text("Save a new video file from “\(subclip?.name ?? clip.name)”.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                Section {
                    TextField("Name", text: $options.name)
                    Picker("Format", selection: $options.presetID) {
                        ForEach(store.videoPresets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }
                } footer: {
                    Text("Saved in the project folder and added to Source Videos.")
                        .foregroundStyle(.secondary)
                }

                Section("Range") {
                    Toggle(isOn: $options.trimToMarks) {
                        Text("Only the In to Out range")
                        Text(rangeText)
                    }
                    .disabled(!controller.hasMarks)
                }

                Section {
                    bakeToggle("Deinterlace", isOn: $options.bakeTiming, isSet: settings.fieldOrder != nil,
                               detail: "Each field becomes a frame (\(clip.deinterlacedRateLabel))")
                    bakeToggle("Effects", isOn: $options.bakeEffects, isSet: settings.hasEffects,
                               detail: "Noise reduction, upscaling, and sharpening")
                    bakeToggle("Color", isOn: $options.bakeColor, isSet: settings.lut != nil || settings.look != nil,
                               detail: "The LUT and look")
                    bakeToggle("Grade", isOn: $options.bakeGrade, isSet: settings.grade != nil,
                               detail: "Exposure, contrast, color, and the rest of the Grade section")
                } header: {
                    Text("Bake Into the New File")
                } footer: {
                    Text("Baked settings are drawn into the picture, and turned off on the new clip so they don't apply twice.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(isOn: $options.inherit) {
                        Text("Inherit Settings")
                        Text("The new clip starts with this clip's settings for anything not baked in, so it looks the same and you can keep adjusting them.")
                    }
                }
            }
            .formStyle(.grouped)
            // Tall enough to show every option without scrolling.
            .frame(minHeight: 640)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Source Video") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(options.presetID == nil)
            }
            .padding(16)
        }
        .frame(width: 480)
        .onAppear {
            if !controller.hasMarks { options.trimToMarks = false }
            let saved = UUID(uuidString: savedPresetID)
            // ProRes keeps the most quality for further editing.
            options.presetID = store.videoPresets.first { $0.id == saved }?.id
                ?? store.videoPresets.first { $0.video?.codec == .proRes422 }?.id
                ?? store.videoPresets.first?.id
        }
    }

    private var rangeText: String {
        guard controller.hasMarks else { return "Nothing is marked, so the whole source video is used." }
        let clock = controller.clock
        let range = controller.markedRange
        let frames = clock.frameIndex(at: range.upperBound) - clock.frameIndex(at: range.lowerBound)
        return "\(clock.timecode(seconds: range.lowerBound)) to \(clock.timecode(frames: max(0, clock.frameIndex(at: range.upperBound) - 1))), \(frames.formatted()) frames. Off: the whole source video."
    }

    private func bakeToggle(_ title: String, isOn: Binding<Bool>, isSet: Bool, detail: String) -> some View {
        Toggle(isOn: Binding(get: { isSet && isOn.wrappedValue }, set: { isOn.wrappedValue = $0 })) {
            Text(title)
            Text(isSet ? detail : "Not set on this clip")
        }
        .disabled(!isSet)
    }

    private func create() {
        if let id = options.presetID { savedPresetID = id.uuidString }
        var chosen = options
        // Only bake what's actually set.
        chosen.bakeTiming = chosen.bakeTiming && settings.fieldOrder != nil
        chosen.bakeEffects = chosen.bakeEffects && settings.hasEffects
        chosen.bakeColor = chosen.bakeColor && (settings.lut != nil || settings.look != nil)
        chosen.bakeGrade = chosen.bakeGrade && settings.grade != nil
        store.makeSourceVideo(from: clip, range: controller.hasMarks ? controller.markedRange : nil,
                              marks: (controller.inPoint, controller.outPoint), options: chosen)
        dismiss()
    }
}
