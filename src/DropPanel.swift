import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class DropModel: ObservableObject {
    @Published var staged: [StagedItem] = []
    @Published var note = ""
    @Published var projects: [String] = []
    @Published var selected = ""
    @Published var addingProject = false
    @Published var newProjectName = ""
    @Published var status = ""
    @Published var statusIsError = false
    @Published var isTargeted = false
    /// When pinned, the window stays open after each Add instead of closing itself.
    @Published var pinned = UserDefaults.standard.bool(forKey: "pinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinned") }
    }

    var onClose: () -> Void = {}

    private let lastProjectKey = "lastProject"

    func refresh() {
        projects = Store.projects()
        if !projects.contains(selected) {
            let last = UserDefaults.standard.string(forKey: lastProjectKey) ?? ""
            selected = projects.contains(last) ? last : (projects.first ?? "")
        }
        addingProject = projects.isEmpty
        status = ""
        statusIsError = false
    }

    var canSubmit: Bool {
        let hasContent = !staged.isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasProject = addingProject
            ? !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty : !selected.isEmpty
        return hasContent && hasProject
    }

    func stage(_ payload: StagedItem.Payload) {
        staged.append(StagedItem(payload: payload))
        status = ""
    }

    func remove(_ item: StagedItem) {
        staged.removeAll { $0.id == item.id }
    }

    func fail(_ message: String) {
        status = message
        statusIsError = true
    }

    // MARK: Clipboard

    func pasteClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            urls.forEach { stage(.file($0)) }
            return
        }
        if let image = NSImage(pasteboard: pb), let png = image.pngData() {
            stage(.image(png, "Pasted image \(Self.timestamp()).png"))
            return
        }
        if let string = pb.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stage(Store.classify(string))
            return
        }
        fail("Nothing on the clipboard to paste.")
    }

    // MARK: Drag and drop

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = Self.url(from: item) else { return }
                    DispatchQueue.main.async { self.stage(.file(url)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let png = NSImage(data: data)?.pngData() else { return }
                    DispatchQueue.main.async {
                        self.stage(.image(png, "Dropped image \(Self.timestamp()).png"))
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    guard let url = Self.url(from: item) else { return }
                    DispatchQueue.main.async { self.stage(Store.classify(url.absoluteString)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    var string: String?
                    if let s = item as? String { string = s }
                    if let d = item as? Data { string = String(data: d, encoding: .utf8) }
                    guard let string, !string.isEmpty else { return }
                    DispatchQueue.main.async { self.stage(Store.classify(string)) }
                }
            }
        }
        return true
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    // MARK: Save

    func submit() {
        guard canSubmit else { return }
        do {
            let project = addingProject ? try Store.createProject(newProjectName) : selected
            var items = staged
            var attachedNote = note
            if items.isEmpty {
                // A note on its own becomes a text item.
                items = [StagedItem(payload: Store.classify(note))]
                attachedNote = ""
            }
            let count = try Store.save(items, note: attachedNote, project: project)
            UserDefaults.standard.set(project, forKey: lastProjectKey)
            staged = []
            note = ""
            newProjectName = ""
            selected = project
            projects = Store.projects()
            addingProject = false
            statusIsError = false
            let message = "Added \(count) item\(count == 1 ? "" : "s") to \(project)"
            status = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.staged.isEmpty, !self.pinned else { return }
                self.onClose()
            }
            // A pinned window stays open, so put the shortcut hint back after a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.pinned, self.status == message else { return }
                self.status = ""
            }
        } catch {
            fail(error.localizedDescription)
        }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

struct DropView: View {
    @ObservedObject var model: DropModel
    @FocusState private var newProjectFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.tint)
                Text("Drop for Claude").font(.headline)
                Spacer()
                Button {
                    model.pinned.toggle()
                } label: {
                    Image(systemName: model.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(model.pinned ? Color.accentColor : Color.secondary)
                }
                .controlSize(.small)
                .help(model.pinned ? "Pinned: stays open after adding. Click to unpin." : "Pin to top: keep this window open after adding")
                .accessibilityLabel("Pin to Top")
                Button("Paste") { model.pasteClipboard() }
                    .controlSize(.small)
                    .help("Add what is on the clipboard (⌘V)")
            }

            dropZone

            TextField("Note for Claude (optional)", text: $model.note, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                if model.addingProject {
                    TextField("New project name", text: $model.newProjectName)
                        .textFieldStyle(.roundedBorder)
                        .focused($newProjectFocused)
                        .onAppear { newProjectFocused = true }
                    if !model.projects.isEmpty {
                        Button("Cancel") { model.addingProject = false }
                    }
                } else {
                    Picker("Project", selection: $model.selected) {
                        ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    Button {
                        model.addingProject = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add a project")
                }
                Spacer(minLength: 0)
                Button("Add to Project") { model.submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
            }

            Text(model.status.isEmpty ? "⌘V paste   ⏎ add   esc close" : model.status)
                .font(.caption)
                .foregroundStyle(model.status.isEmpty ? Color.secondary : (model.statusIsError ? Color.red : Color.green))
                .lineLimit(2)
        }
        .padding(16)
        .frame(width: 440)
        .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: $model.isTargeted) {
            model.handleDrop($0)
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(model.isTargeted ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    model.isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

            if model.staged.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down").font(.title)
                    Text("Drop files, images or links here")
                    Text("or press ⌘V to paste").font(.caption)
                }
                .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.staged) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary)
                                Text(item.title).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Button {
                                    model.remove(item)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(height: 170)
    }
}

/// Floating panel that can take keyboard focus and closes on Escape.
final class DropPanel: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}
