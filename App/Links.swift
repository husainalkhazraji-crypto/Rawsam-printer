import SwiftUI

/// روابط التواصل الي يحطها المدير.
struct SocialLinks: Codable, Hashable {
    var instagram: String?
    var facebook: String?
    var tiktok: String?
    var whatsapp: String?   // رقم الواتساب أو رابط
}

enum Links {
    /// يحول أي نص يكتبه المدير لرابط يفتح. روابط واتساب وإنستغرام وتيك توك وفيسبوك
    /// تفتح بتطبيقاتها مباشرة إذا موجودة بالتلفون.
    static func url(_ raw: String?, kind: Kind = .web) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") { return URL(string: text) }
        switch kind {
        case .whatsapp:
            let digits = text.filter(\.isNumber)
            guard !digits.isEmpty else { return nil }
            // رقم عراقي يبدي بصفر: نحوله لـ 964
            let number = digits.hasPrefix("0") ? "964" + digits.dropFirst() : digits
            return URL(string: "https://wa.me/\(number)")
        case .instagram:
            if text.hasPrefix("@") { text.removeFirst() }
            return text.contains(".") ? URL(string: "https://" + text) : URL(string: "https://instagram.com/\(text)")
        case .tiktok:
            if text.hasPrefix("@") { text.removeFirst() }
            return text.contains(".") ? URL(string: "https://" + text) : URL(string: "https://www.tiktok.com/@\(text)")
        case .facebook:
            return text.contains(".") ? URL(string: "https://" + text) : URL(string: "https://facebook.com/\(text)")
        case .web:
            return URL(string: "https://" + text)
        }
    }

    enum Kind { case web, whatsapp, instagram, tiktok, facebook }
}

/// صف أيقونات التواصل بالإعدادات.
struct SocialRow: View {
    let social: SocialLinks
    @Environment(\.openURL) private var openURL

    private struct Item: Identifiable {
        let title: String
        let icon: String
        let color: Color
        let url: URL?
        var id: String { title }
    }

    private var items: [Item] {
        [Item(title: "إنستغرام", icon: "camera.fill", color: Color(red: 0.84, green: 0.16, blue: 0.48), url: Links.url(social.instagram, kind: .instagram)),
         Item(title: "فيسبوك", icon: "f.cursive", color: Color(red: 0.09, green: 0.47, blue: 0.95), url: Links.url(social.facebook, kind: .facebook)),
         Item(title: "تيك توك", icon: "music.note", color: .black, url: Links.url(social.tiktok, kind: .tiktok)),
         Item(title: "واتساب", icon: "phone.fill", color: Color(red: 0.15, green: 0.73, blue: 0.36), url: Links.url(social.whatsapp, kind: .whatsapp))]
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.filter { $0.url != nil }) { item in
                Button {
                    if let url = item.url { openURL(url) }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(item.color))
                        Text(item.title).font(.caption).foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    var isEmpty: Bool { items.allSatisfy { $0.url == nil } }
}

/// شريط «منتجاتنا»: 3 مربعات بعرض الشاشة، يتحرك كله سوة.
struct ProductsStrip: View {
    let items: [LibraryItem]
    let seconds: Double
    let link: URL?
    @Environment(\.openURL) private var openURL
    @State private var position: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("منتجاتنا").font(.headline)
            GeometryReader { geo in
                let spacing: CGFloat = 10
                let side = (geo.size.width - spacing * 2) / 3
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: spacing) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            RemoteImage(url: Cloud.file(item.file), fill: true)
                                .frame(width: side, height: side)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .id(i)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $position, anchor: .leading)
                .frame(height: side)
            }
            .aspectRatio(3.1, contentMode: .fit)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let link { openURL(link) } }
        .task(id: items) {
            guard items.count > 3 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(1, seconds)))
                if Task.isCancelled { return }
                let next = (position ?? 0) + 1
                withAnimation(.easeInOut(duration: 0.6)) { position = next > items.count - 3 ? 0 : next }
            }
        }
    }
}
