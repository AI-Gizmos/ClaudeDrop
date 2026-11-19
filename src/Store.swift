import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Something waiting in the panel, not yet saved.
struct StagedItem: Identifiable {
    enum Payload {
        case file(URL)
        case image(Data, String)  // PNG data, display name
        case link(String)
        case text(String)
    }

    let id = UUID()
    let payload: Payload

    var title: String {
        switch payload {
        case .file(let url): return url.lastPathComponent
        case .image(_, let name): return name
        case .link(let s): return s
        case .text(let s):
            let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return line.count > 70 ? String(line.prefix(70)) + "…" : line
        }
    }

    var symbol: String {
        switch payload {
        case .file(let url):
            let type = UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .image) == true ? "photo" : "doc"
        case .image: return "photo"
        case .link: return "link"
        case .text: return "text.alignleft"
        }
    }
}

/// On-disk layout, shared with connector/server.mjs:
///   Inbox/<Project>/<id>.json        one entry per dropped item
///   Inbox/<Project>/files/<id>-name  the file itself, plus <id>.extracted.txt
///   Inbox/<Project>/archived/        entries Claude was told are done
enum Store {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDEDROP_INBOX"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ClaudeDrop/Inbox", isDirectory: true)
    }

    static func projects() -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func pendingCount(_ project: String) -> Int {
        let dir = root.appendingPathComponent(project, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.count
    }

    @discardableResult
    static func createProject(_ rawName: String) throws -> String {
        let name = sanitize(rawName)
        guard !name.isEmpty else { throw DropError("Type a project name first.") }
        if let existing = projects().first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        return name
    }

    /// Saves every staged item into the project and returns how many were written.
    @discardableResult
    static func save(_ items: [StagedItem], note: String, project: String) throws -> Int {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(project, isDirectory: true)
        let files = dir.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)

        var saved = 0
        for (index, item) in items.enumerated() {
            let id = makeID(index)
            var entry: [String: Any] = [
                "id": id,
                "title": item.title,
                "addedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            if !note.isEmpty { entry["note"] = note }

            switch item.payload {
            case .link(let url):
                entry["kind"] = "link"
                entry["url"] = url
            case .text(let text):
                entry["kind"] = "text"
                entry["text"] = text
            case .image(let data, let name):
                let dest = files.appendingPathComponent("\(id)-\(sanitize(name))")
                try data.write(to: dest, options: .atomic)
                entry["kind"] = "image"
                entry["file"] = "files/\(dest.lastPathComponent)"
                entry["originalName"] = name
                entry["size"] = data.count
            case .file(let source):
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: source.path, isDirectory: &isDir), !isDir.boolValue else {
                    throw DropError("\(source.lastPathComponent) is a folder. Drop the files inside it instead.")
                }
                let dest = files.appendingPathComponent("\(id)-\(sanitize(source.lastPathComponent))")
                try fm.copyItem(at: source, to: dest)
                let type = UTType(filenameExtension: source.pathExtension)
                entry["kind"] = type?.conforms(to: .image) == true ? "image" : "file"
                entry["file"] = "files/\(dest.lastPathComponent)"
                entry["originalName"] = source.lastPathComponent
                if let size = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int {
                    entry["size"] = size
                }
                if let type, let mime = type.preferredMIMEType { entry["mime"] = mime }
                if let extracted = extractText(from: dest), !extracted.isEmpty {
                    let textFile = files.appendingPathComponent("\(id).extracted.txt")
                    try extracted.write(to: textFile, atomically: true, encoding: .utf8)
                    entry["extractedText"] = "files/\(textFile.lastPathComponent)"
                }
            }

            let data = try JSONSerialization.data(
                withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
            saved += 1
        }
        return saved
    }

    /// Pull readable text out of documents Claude could not otherwise open through the connector.
    private static func extractText(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return PDFDocument(url: url)?.string
        case "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive":
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        default:
            return nil
        }
    }

    private static func makeID(_ index: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(f.string(from: Date()))-\(String(format: "%02d", index))\(suffix)"
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.newlines)
        let cleaned = name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.hasPrefix(".") ? String(cleaned.dropFirst()) : cleaned
    }

    /// Turns a pasted or typed string into a link or a text note.
    static func classify(_ string: String) -> StagedItem.Payload {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace),
            let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme), url.host != nil
        {
            return .link(trimmed)
        }
        return .text(string)
    }
}

struct DropError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
