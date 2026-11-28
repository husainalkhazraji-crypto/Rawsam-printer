import SwiftUI

/// المكتبة السحابية على سيرفر Cloudflare (مجاني).
/// القراءة لكل المستخدمين، والتعديل للمدير بس بعد ما يدخل بكلمة السر.
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
    var passwordHash: String?             // قديم (أيام GitHub)، السيرفر ما يرجعه
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
    static let base = URL(string: "https://rawsam.husain-alkhazraji.workers.dev/")!
    static let sessionKey = "adminSession"

    static func file(_ name: String) -> URL {
        base.appendingPathComponent("files").appendingPathComponent(name)
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
            var request = URLRequest(url: Cloud.base.appendingPathComponent("config"))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            apply(try JSONDecoder().decode(LibraryConfig.self, from: data))
            self.error = nil
        } catch {
            self.error = "تعذر تحديث المكتبة، تأكد من الإنترنت"
        }
    }

    func apply(_ fresh: LibraryConfig) {
        config = fresh
        if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: cacheURL) }
    }
}

struct UserMessage: Codable, Identifiable, Hashable {
    let id: String
    let text: String
    let contact: String?
    let date: Double   // ملي ثانية
    var time: Date { Date(timeIntervalSince1970: date / 1000) }
}

enum ServerError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// كل الاتصال بالسيرفر.
enum Server {
    private struct Failure: Decodable { let error: String }
    private struct Token: Decodable { let token: String }

    private static func call(_ method: String, _ path: String, body: Data? = nil,
                             contentType: String = "application/json", admin: Bool = false) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: Cloud.base)!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = body
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if admin, let token = Keychain.read(Cloud.sessionKey) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw ServerError.message("ما اكو إنترنت أو الاتصال انقطع")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) { throw ServerError.message(failure.error) }
            throw ServerError.message("خطأ من السيرفر (\(code))")
        }
        return data
    }

    private static func encode(_ value: [String: String]) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }

    // المستخدمين
    static func sendMessage(text: String, contact: String) async throws {
        let device = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        _ = try await call("POST", "messages", body: encode(["text": text, "contact": contact, "device": device]))
    }

    // المدير
    static func login(password: String) async throws {
        let data = try await call("POST", "admin/login", body: encode(["password": password]))
        Keychain.save(try JSONDecoder().decode(Token.self, from: data).token, for: Cloud.sessionKey)
    }

    static func changePassword(_ password: String) async throws {
        let data = try await call("POST", "admin/password", body: encode(["password": password]), admin: true)
        Keychain.save(try JSONDecoder().decode(Token.self, from: data).token, for: Cloud.sessionKey)
    }

    /// يرفع الصور الجديدة وبعدين الإعدادات. السيرفر يحذف الصور الي ما عاد مستخدمة.
    static func publish(config: LibraryConfig, newFiles: [String: Data], progress: @escaping (String) -> Void) async throws -> LibraryConfig {
        var done = 0
        for (name, data) in newFiles {
            done += 1
            progress("أرفع الصور \(done) من \(newFiles.count)")
            _ = try await call("PUT", "admin/files/\(name)", body: data, contentType: "image/jpeg", admin: true)
        }
        progress("أحفظ التغييرات…")
        var clean = config
        clean.passwordHash = nil
        let saved = try await call("PUT", "admin/config", body: try JSONEncoder().encode(clean), admin: true)
        return try JSONDecoder().decode(LibraryConfig.self, from: saved)
    }

    static func messages() async throws -> [UserMessage] {
        try JSONDecoder().decode([UserMessage].self, from: try await call("GET", "admin/messages", admin: true))
    }

    static func deleteMessage(_ id: String) async throws {
        _ = try await call("DELETE", "admin/messages/\(id)", admin: true)
    }
}
