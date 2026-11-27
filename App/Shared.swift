import SwiftUI
import Security

extension Color {
    static let brand = Color(red: 0.84, green: 0.07, blue: 0.16)
    static let ok = Color(red: 0.12, green: 0.64, blue: 0.32)
}

/// مستطيل بنسب من 0 إلى 1 (للقص).
struct NormRect: Hashable {
    var x = 0.0, y = 0.0, w = 1.0, h = 1.0
    static let full = NormRect()
}

enum Route: Hashable {
    case editor(DesignSource)
    case settings
}

enum DesignSource: Hashable {
    case local(URL)
    case remote(URL)

    func load() async -> UIImage? {
        switch self {
        case .local(let url):
            return UIImage(contentsOfFile: url.path)
        case .remote(let url):
            guard let result = try? await URLSession.shared.data(from: url) else { return nil }
            return UIImage(data: result.0)
        }
    }
}

extension UIImage {
    /// صورة بالاتجاه الصحيح وبحجم معقول.
    func normalized(maxSide: CGFloat = 2400, opaqueWhite: Bool = false) -> UIImage {
        let s = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, (size.width * s).rounded()), height: max(1, (size.height * s).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaqueWhite
        return UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            if opaqueWhite {
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: target))
            }
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// JPEG بخلفية بيضاء، للرفع على السحابة.
    func uploadJPEG(maxSide: CGFloat) -> Data? {
        normalized(maxSide: maxSide, opaqueWhite: true).jpegData(compressionQuality: 0.85)
    }
}

enum Keychain {
    static func save(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// صورة من الإنترنت (تنحفظ بالكاش).
struct RemoteImage: View {
    let url: URL
    var fill = false

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                if fill { image.resizable().scaledToFill() } else { image.resizable().scaledToFit() }
            case .failure:
                Image(systemName: "photo").foregroundStyle(.tertiary)
            default:
                ProgressView()
            }
        }
    }
}

/// صور المستخدم الخاصة، تنحفظ بتلفونه بس.
@MainActor
final class LocalLibrary: ObservableObject {
    @Published private(set) var items: [URL] = []
    private let files = FileManager.default

    private var folder: URL {
        files.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MyDesigns", isDirectory: true)
    }

    init() { reload() }

    func reload() {
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        items = urls.filter { $0.pathExtension.lowercased() == "png" }.sorted { date($0) > date($1) }
    }

    func add(_ data: Data) -> URL? {
        guard let png = UIImage(data: data)?.normalized().pngData() else { return nil }
        let url = folder.appendingPathComponent(UUID().uuidString + ".png")
        do { try png.write(to: url) } catch { return nil }
        reload()
        return url
    }

    func delete(_ url: URL) {
        try? files.removeItem(at: url)
        reload()
    }
}
