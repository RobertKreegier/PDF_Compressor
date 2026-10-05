import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable {
    enum Status {
        case pending
        case working
        case done(CompressionResult, URL)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var status: Status = .pending
}

struct ContentView: View {
    @State private var items: [FileItem] = []
    @State private var level: CompressionLevel = .medium
    @State private var isTargeted = false
    @State private var isRunning = false
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 16) {
            if items.isEmpty {
                dropZone
            } else {
                List(items) { item in
                    FileRow(item: item)
                }
                .frame(minHeight: 160)
                .overlay { if isTargeted { dropHighlight } }
            }

            HStack {
                Picker("Compression", selection: $level) {
                    ForEach(CompressionLevel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                Text(level.detail).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                Button("Add PDFs…") { showImporter = true }
                Button("Clear") { items.removeAll() }
                    .disabled(items.isEmpty || isRunning)
                Spacer()
                Button("Compress", action: compressAll)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || isRunning)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.zipper").font(.system(size: 40))
            Text("Drop PDFs here").font(.headline)
            Text("or use Add PDFs…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
        )
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isRunning else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in add([url]) }
            }
        }
        return true
    }

    private func add(_ urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" && !items.contains(where: { $0.url == url }) {
            items.append(FileItem(url: url))
        }
    }

    private func chooseOutputFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save the compressed PDFs"
        panel.directoryURL = items.first?.url.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func compressAll() {
        guard let outputFolder = chooseOutputFolder() else { return }
        isRunning = true
        let level = level
        let pending = items.filter { if case .done = $0.status { false } else { true } }
        Task {
            for item in pending {
                update(item.id, .working)
                let status: FileItem.Status = await Task.detached {
                    Self.compress(item.url, into: outputFolder, level: level)
                }.value
                update(item.id, status)
            }
            isRunning = false
        }
    }

    private func update(_ id: UUID, _ status: FileItem.Status) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].status = status }
    }

    /// Writes "<name> compressed.pdf" into `folder`, never overwriting existing files.
    nonisolated private static func compress(_ url: URL, into folder: URL, level: CompressionLevel) -> FileItem.Status {
        let accessing = url.startAccessingSecurityScopedResource()
        let folderAccessing = folder.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
            if folderAccessing { folder.stopAccessingSecurityScopedResource() }
        }

        let base = url.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent("\(base) compressed.pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) compressed \(n).pdf")
            n += 1
        }
        do {
            let result = try PDFCompressor.compress(source: url, destination: destination, level: level)
            return .done(result, destination)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack {
            Image(systemName: "doc.richtext")
            VStack(alignment: .leading) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                detail
            }
            Spacer()
            if case .working = item.status { ProgressView().controlSize(.small) }
            if case .done(_, let output) = item.status {
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch item.status {
        case .pending:
            Text("Ready").font(.caption).foregroundStyle(.secondary)
        case .working:
            Text("Compressing…").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        case .done(let r, _):
            if r.keptCompressed {
                let saved = 100 - Double(r.newSize) / Double(max(r.originalSize, 1)) * 100
                Text("\(format(r.originalSize)) → \(format(r.newSize)) (\(Int(saved.rounded()))% smaller)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Already well compressed — copy saved unchanged (\(format(r.originalSize)))")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    ContentView()
}
