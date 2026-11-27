import SwiftUI
import UIKit

struct Design: Identifiable, Hashable {
    let url: URL
    let category: String
    let isUserAdded: Bool
    var name: String = ""
    var id: URL { url }
}

/// المكتبة تجمع مصدرين:
/// ١) مجلد Designs المرفق مع التطبيق (كل مجلد فرعي = قسم).
/// ٢) التصاميم التي تضيفها من داخل التطبيق.
final class DesignLibrary: ObservableObject {
    @Published private(set) var designs: [Design] = []
    static let userCategory = "تصاميمي"
    private let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
    private let files = FileManager.default
    /// أسماء الملفات داخل التطبيق لازم تكون إنگليزية (الأسماء العربية تخرّب التثبيت)،
    /// فالأسماء العربية الظاهرة تنكتب بـ Designs/names.json.
    private var labels: [String: String] = [:]

    private var userFolder: URL {
        files.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Designs", isDirectory: true)
    }

    init() { reload() }

    var categories: [String] {
        let all = Set(designs.map(\.category))
        return all.sorted { a, b in
            if a == Self.userCategory { return true }
            if b == Self.userCategory { return false }
            return a.localizedCompare(b) == .orderedAscending
        }
    }

    func reload() {
        var found: [Design] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Designs") {
            if let data = try? Data(contentsOf: bundled.appendingPathComponent("names.json")),
               let map = try? JSONDecoder().decode([String: String].self, from: data) { labels = map }
            found += scan(bundled, isUserAdded: false)
        }
        try? files.createDirectory(at: userFolder, withIntermediateDirectories: true)
        found += scan(userFolder, isUserAdded: true)
        designs = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func scan(_ root: URL, isUserAdded: Bool) -> [Design] {
        var out: [Design] = []
        for item in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for file in (try? files.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                where extensions.contains(file.pathExtension.lowercased()) {
                    let folder = item.lastPathComponent, base = file.deletingPathExtension().lastPathComponent
                    out.append(Design(url: file, category: label(folder), isUserAdded: isUserAdded,
                                      name: label("\(folder)/\(base)", or: base)))
                }
            } else if extensions.contains(item.pathExtension.lowercased()) {
                let base = item.deletingPathExtension().lastPathComponent
                out.append(Design(url: item, category: isUserAdded ? Self.userCategory : "عام", isUserAdded: isUserAdded,
                                  name: label(base)))
            }
        }
        return out
    }

    private func label(_ key: String, or fallback: String? = nil) -> String {
        labels[key] ?? fallback ?? key
    }

    @discardableResult
    func add(_ data: Data, category: String) -> Bool {
        guard let png = UIImage(data: data)?.pngData() else { return false }
        let clean = category.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let folder = userFolder.appendingPathComponent(clean.isEmpty ? Self.userCategory : clean, isDirectory: true)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "تصميم-\(UUID().uuidString.prefix(6)).png"
            try png.write(to: folder.appendingPathComponent(name))
        } catch { return false }
        reload()
        return true
    }

    func delete(_ design: Design) {
        guard design.isUserAdded else { return }
        try? files.removeItem(at: design.url)
        reload()
    }
}
