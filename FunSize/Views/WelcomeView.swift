import SwiftUI
import UniformTypeIdentifiers

enum WelcomeWindow {
    static let id = "welcome"
    /// Set by any open window, so the app can bring Welcome back (e.g. clicking the Dock icon).
    static var open: (() -> Void)?
}

/// Shown at launch: start a project, open one, or open videos, plus recent projects.
struct WelcomeView: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.openWindow) private var openWindow
    @State private var recents: [URL] = []
    @State private var selectedRecent: URL?
    @State private var isChoosingVideos = false
    @State private var isDropTargeted = false
    @State private var openError: String?

    var body: some View {
        HStack(spacing: 0) {
            actions
                .frame(width: 420)
            Divider()
            recentList
                .frame(width: 300)
        }
        .frame(height: 440)
        .ignoresSafeArea()
        .onAppear {
            WelcomeWindow.open = { openWindow(id: WelcomeWindow.id) }
            refreshRecents()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshRecents()
        }
        .fileImporter(isPresented: $isChoosingVideos, allowedContentTypes: [.audiovisualContent], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { openVideos(urls) }
        }
        .alert("Couldn't Open Project", isPresented: Binding(get: { openError != nil }, set: { if !$0 { openError = nil } })) {
            Button("OK") {}
        } message: {
            Text(openError ?? "")
        }
    }

    // MARK: Left side

    private var actions: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
            Text("FunSize")
                .font(.system(size: 34, weight: .bold))
                .padding(.top, 6)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 24)

            VStack(spacing: 8) {
                WelcomeButton(title: "New Project", subtitle: "Start with an empty project", systemImage: "plus.square.on.square") {
                    newDocument(ProjectDocument())
                }
                WelcomeButton(title: "Open Project…", subtitle: "Open a saved FunSize project", systemImage: "folder") {
                    NSDocumentController.shared.openDocument(nil)
                }
                WelcomeButton(title: "Open Video…", subtitle: "Or drop videos on this window", systemImage: "film") {
                    isChoosingVideos = true
                }
            }
            .padding(.horizontal, 44)
            Spacer(minLength: 32)
        }
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(Color.accentColor)
                .padding(10)
                .opacity(isDropTargeted ? 1 : 0)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter(MediaLoader.isSupported)
            guard !videos.isEmpty else { return false }
            openVideos(videos)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: Right side

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Projects")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 40)
                .padding(.bottom, 6)

            if recents.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Projects", systemImage: "clock")
                } description: {
                    Text("Projects you save or open appear here.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(recents, id: \.self, selection: $selectedRecent) { url in
                    RecentProjectRow(url: url)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: URL.self) { urls in
                    if let url = urls.first {
                        Button("Open") { open(url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                } primaryAction: { urls in
                    if let url = urls.first { open(url) }
                }
                .onKeyPress(.return) {
                    guard let selectedRecent else { return .ignored }
                    open(selectedRecent)
                    return .handled
                }

                HStack {
                    Spacer()
                    Button("Clear Recents") {
                        NSDocumentController.shared.clearRecentDocuments(nil)
                        refreshRecents()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .padding(12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary)
    }

    // MARK: Actions

    private func refreshRecents() {
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls != recents { recents = urls }
    }

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
            } catch {
                openError = error.localizedDescription
                refreshRecents()
            }
        }
    }

    /// Starts an untitled project holding these videos.
    private func openVideos(_ urls: [URL]) {
        let file = ProjectFile.with(videos: urls)
        guard !file.clips.isEmpty else { return }
        newDocument(ProjectDocument(file: file))
    }
}

/// A large rectangular button with an icon, title, and short description.
private struct WelcomeButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct RecentProjectRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: .funsizeProject))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 3)
        .help(url.path(percentEncoded: false))
    }

    /// The folder, with the home folder shown as "~".
    private var folder: String {
        let path = url.deletingLastPathComponent().path(percentEncoded: false)
        let home = Self.realHome
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The user's home folder (not the app's sandbox container).
    private static let realHome: String = {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }()
}
