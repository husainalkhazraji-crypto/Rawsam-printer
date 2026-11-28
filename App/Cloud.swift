import SwiftUI
import CryptoKit

/// المكتبة السحابية: ملفات بفرع library بنفس مستودع GitHub.
/// القراءة مجانية لكل المستخدمين، والكتابة تحتاج رمز GitHub عند المدير بس.
struct LibraryItem: Codable, Hashable, Identifiable {
    var file: String
    var link: String?       // رابط يفتح لما المستخدم يضغط على الإعلان
    var id: String { file }
}

struct LibraryCategory: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var items: [LibraryItem]
}

struct LibraryConfig: Codable, Hashable {
    var version = 1
    var passwordHash: String
    var bannerSeconds: Double = 3
    var banners: [LibraryItem] = []
    var editorBanners: [LibraryItem]?     // إعلان صفحة الطباعة
    var settingsBanners: [LibraryItem]?   // شريط «منتجاتنا» بأسفل الإعدادات
    var productsLink: String?             // رابط واحد لشريط «منتجاتنا» كله
    var social: SocialLinks?              // إنستغرام، فيسبوك، تيك توك، واتساب
    var categories: [LibraryCategory] = []

    var allFiles: Set<String> {
        var files = Set(banners.map(\.file))
        for item in editorBanners ?? [] { files.insert(item.file) }
        for item in settingsBanners ?? [] { files.insert(item.file) }
        for category in categories { for item in category.items { files.insert(item.file) } }
        return files
    }
}

enum Cloud {
    static let owner = "husainalkhazraji-crypto"
    static let repo = "Rawsam-printer"
    static let branch = "library"
    static let tokenKey = "githubToken"

    static let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/")!

    static func raw(_ ref: String, _ path: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(path)")!
    }

    static func file(_ name: String) -> URL { raw(branch, "files/" + name) }

    static func hash(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class CloudLibrary: ObservableObject {
    @Published private(set) var config: LibraryConfig?
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("library-config.json")
    }

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode(LibraryConfig.self, from: data) {
            config = saved
        }
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            // نجيب آخر نسخة بالضبط حتى ما ننتظر كاش GitHub.
            let ref = (try? await latestCommit()) ?? Cloud.branch
            var request = URLRequest(url: Cloud.raw(ref, "config.json"))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let fresh = try JSONDecoder().decode(LibraryConfig.self, from: data)
            apply(fresh)
            self.error = nil
        } catch {
            self.error = "تعذر تحديث المكتبة، تأكد من الإنترنت"
        }
    }

    private func latestCommit() async throws -> String {
        var request = URLRequest(url: Cloud.api.appendingPathComponent("commits/\(Cloud.branch)"))
        request.setValue("application/vnd.github.sha", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let sha = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              sha.count == 40 else { throw URLError(.badServerResponse) }
        return sha
    }

    func apply(_ fresh: LibraryConfig) {
        config = fresh
        if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: cacheURL) }
    }
}

enum UploadError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// يرفع كل التغييرات بعملية وحدة (commit) على فرع library.
struct GitHubUploader {
    let token: String

    /// يرجع المكتبة بعد التنظيف (بدون روابط لصور محذوفة).
    @discardableResult
    func upload(config: LibraryConfig, newFiles: [String: Data], deleted: Set<String>,
                progress: @escaping (String) -> Void) async throws -> LibraryConfig {
        progress("أتصل بالسحابة…")
        let ref = try await call("GET", "git/ref/heads/\(Cloud.branch)")
        guard let head = (ref["object"] as? [String: Any])?["sha"] as? String else { throw UploadError.message("ما لكيت فرع المكتبة") }
        let commit = try await call("GET", "git/commits/\(head)")
        guard let baseTree = (commit["tree"] as? [String: Any])?["sha"] as? String else { throw UploadError.message("رد غير متوقع من GitHub") }

        // الصور الموجودة فعلاً بالسحابة هسه.
        let tree = try await call("GET", "git/trees/\(baseTree)?recursive=1")
        var existing = Set<String>()
        for entry in tree["tree"] as? [[String: Any]] ?? [] {
            if let path = entry["path"] as? String, path.hasPrefix("files/"), entry["type"] as? String == "blob" {
                existing.insert(String(path.dropFirst(6)))
            }
        }
        // نشيل أي رابط لصورة مو موجودة، حتى ما تطلع صور فارغة.
        let available = existing.union(newFiles.keys)
        var config = config
        config.banners.removeAll { !available.contains($0.file) }
        config.editorBanners?.removeAll { !available.contains($0.file) }
        config.settingsBanners?.removeAll { !available.contains($0.file) }
        for i in config.categories.indices { config.categories[i].items.removeAll { !available.contains($0.file) } }
        // نحذف بس الصور الموجودة الي ما عاد يستخدمها أي قسم أو بانر.
        let unused = existing.subtracting(config.allFiles)

        var entries: [[String: Any]] = []
        var done = 0
        for (name, data) in newFiles {
            done += 1
            progress("أرفع الصور \(done) من \(newFiles.count)")
            let blob = try await call("POST", "git/blobs", ["content": data.base64EncodedString(), "encoding": "base64"])
            guard let sha = blob["sha"] as? String else { throw UploadError.message("فشل رفع صورة") }
            entries.append(["path": "files/\(name)", "mode": "100644", "type": "blob", "sha": sha])
        }
        for name in unused {
            entries.append(["path": "files/\(name)", "mode": "100644", "type": "blob", "sha": NSNull()])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(config), as: UTF8.self)
        entries.append(["path": "config.json", "mode": "100644", "type": "blob", "content": json])

        progress("أحفظ التغييرات…")
        let newTree = try await call("POST", "git/trees", ["base_tree": baseTree, "tree": entries])
        guard let treeSha = newTree["sha"] as? String else { throw UploadError.message("فشل حفظ التغييرات") }
        let newCommit = try await call("POST", "git/commits", ["message": "تحديث المكتبة من التطبيق", "tree": treeSha, "parents": [head]])
        guard let commitSha = newCommit["sha"] as? String else { throw UploadError.message("فشل حفظ التغييرات") }
        _ = try await call("PATCH", "git/refs/heads/\(Cloud.branch)", ["sha": commitSha])
        return config
    }

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: path, relativeTo: Cloud.api)!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw UploadError.message("ما اكو إنترنت أو الاتصال انقطع")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            switch code {
            case 401: throw UploadError.message("رمز GitHub غلط أو منتهي")
            case 403, 404: throw UploadError.message("رمز GitHub ما عنده صلاحية الكتابة على المستودع")
            default: throw UploadError.message("خطأ من GitHub (\(code))")
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
