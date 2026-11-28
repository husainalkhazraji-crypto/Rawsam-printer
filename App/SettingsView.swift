import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject private var printer: PrinterManager
    @EnvironmentObject private var cloud: CloudLibrary
    @AppStorage("printMode") private var mode: PrintMode = .mhtLegacy
    @AppStorage("density") private var density: Density = .normal
    @State private var askPassword = false
    @State private var password = ""
    @State private var problem: String?
    @State private var adminConfig: LibraryConfig?
    @State private var loggingIn = false
    @State private var copied = false
    @State private var heatWarning = false
    @State private var taps: [Date] = []

    var body: some View {
        Form {
            Section("الطباعة") {
                Picker("حرارة الطباعة", selection: $density) {
                    ForEach(Density.allCases) { Text($0.title).tag($0) }
                }
                Picker("طريقة الإرسال", selection: $mode) {
                    ForEach(PrintMode.allCases) { Text($0.title).tag($0) }
                }
                Button("اطبع مستطيل الاختبار (4×2 سم)") {
                    let test = PrinterProtocol.calibration(width: mode.widthDots)
                    printer.send(PrinterProtocol.job(test, mode: mode, density: .low))
                }
                .disabled(!printer.isReady || printer.isPrinting)
                if let message = printer.lastMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            }

            Section("المكتبة") {
                Button {
                    Task { await cloud.refresh() }
                } label: {
                    HStack {
                        Text("تحديث المكتبة")
                        Spacer()
                        if cloud.loading { ProgressView() }
                    }
                }
                if let error = cloud.error { Text(error).foregroundStyle(.secondary) }
            }

            SuggestionSection()

            if let social = cloud.config?.social, !SocialRow(social: social).isEmpty {
                Section("تواصل ويّانا") {
                    SocialRow(social: social)
                }
            }

            if printer.connectedName != nil {
                Section("متقدم") {
                    Picker("قناة الكتابة", selection: $printer.selectedTarget) {
                        ForEach(printer.writeTargets, id: \.self) {
                            Text($0.uuid.uuidString).tag(Optional($0))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Button("اسأل الطابعة عن موديلها") { printer.send(Data(PrinterProtocol.queryModel)) }
                        .disabled(!printer.isReady || printer.isPrinting)
                    Button(copied ? "انتسخ ✓" : "انسخ تقرير الفحص") {
                        UIPasteboard.general.string = printer.report()
                        copied = true
                    }
                }
            }

            Section {
                LabeledContent("الإصدار", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
            } footer: {
                // باب المدير المخفي: 5 ضغطات.
                Text("Designed by Rawsam Tattoo")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { secretTap() }
            }

            if let products = cloud.config?.settingsBanners, !products.isEmpty {
                Section {
                    ProductsStrip(items: products, seconds: cloud.config?.bannerSeconds ?? 3,
                                  link: Links.url(cloud.config?.productsLink))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
        }
        .navigationTitle("الإعدادات")
        .onChange(of: density) { _, new in if new == .thick { heatWarning = true } }
        .alert("تنبيه", isPresented: $heatWarning) {
            Button("تمام", role: .cancel) {}
        } message: {
            Text(darkHeatWarning)
        }
        .alert("Admin", isPresented: $askPassword) {
            SecureField("كلمة السر", text: $password)
            Button("دخول", action: checkPassword)
            Button("إلغاء", role: .cancel) {}
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("تمام", role: .cancel) {}
        }
        .overlay { if loggingIn { ProgressView().controlSize(.large) } }
        .navigationDestination(item: $adminConfig) { config in
            AdminView(config: config)
        }
    }

    private func secretTap() {
        let now = Date()
        taps = taps.filter { now.timeIntervalSince($0) < 3 } + [now]
        if taps.count >= 5 {
            taps = []
            password = ""
            askPassword = true
        }
    }

    private func checkPassword() {
        let entered = password
        password = ""
        loggingIn = true
        Task {
            do {
                try await Server.login(password: entered)
                await cloud.refresh()
                if let config = cloud.config { adminConfig = config } else { problem = "تعذر تحميل المكتبة" }
            } catch {
                problem = error.localizedDescription
            }
            loggingIn = false
        }
    }
}


// MARK: - لوحة المدير

@MainActor
final class AdminDraft: ObservableObject {
    @Published var config: LibraryConfig { didSet { dirty = true } }
    @Published private(set) var newFiles: [String: Data] = [:]
    @Published private(set) var deleted: Set<String> = []
    @Published private(set) var dirty = false
    private var uploaded: Set<String>

    init(_ config: LibraryConfig) {
        self.config = config
        uploaded = config.allFiles
    }

    func addImage(_ data: Data, maxSide: CGFloat) -> String? {
        guard let jpeg = UIImage(data: data)?.uploadJPEG(maxSide: maxSide) else { return nil }
        let name = UUID().uuidString.lowercased() + ".jpg"
        newFiles[name] = jpeg
        dirty = true
        return name
    }

    func forget(_ file: String) {
        if newFiles.removeValue(forKey: file) == nil, uploaded.contains(file) { deleted.insert(file) }
        dirty = true
    }

    func reset(to saved: LibraryConfig) {
        config = saved
        newFiles = [:]
        deleted = []
        uploaded = saved.allFiles
        dirty = false
    }
}

struct AdminView: View {
    @EnvironmentObject private var cloud: CloudLibrary
    @StateObject private var draft: AdminDraft
    @AppStorage("messagesLastSeen") private var lastSeen: Double = 0
    @State private var newMessages = 0
    @State private var newCategory = ""
    @State private var newPassword = ""
    @State private var status: String?
    @State private var message: String?

    init(config: LibraryConfig) {
        _draft = StateObject(wrappedValue: AdminDraft(config))
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    MessagesView(lastSeen: $lastSeen)
                } label: {
                    HStack {
                        Label("رسائل المستخدمين", systemImage: "envelope.fill")
                        Spacer()
                        if newMessages > 0 {
                            Text("\(newMessages)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.brand))
                        }
                    }
                }
            }

            Section {
                ForEach(draft.config.categories) { category in
                    NavigationLink {
                        AdminCategoryView(draft: draft, categoryID: category.id)
                    } label: {
                        HStack {
                            Text(category.name)
                            Spacer()
                            Text("\(category.items.count) صورة").foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { draft.config.categories[i].items.forEach { draft.forget($0.file) } }
                    draft.config.categories.remove(atOffsets: offsets)
                }
                .onMove { draft.config.categories.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    TextField("اسم قسم جديد", text: $newCategory)
                    Button("إضافة") {
                        let name = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.config.categories.append(LibraryCategory(id: UUID().uuidString.lowercased(), name: name, items: []))
                        newCategory = ""
                    }
                    .disabled(newCategory.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("الأقسام")
            } footer: {
                Text("اضغط على القسم حتى تغيّر اسمه وصوره. اسحب لليسار للحذف، و«تعديل» للترتيب.")
            }

            AdminBannerSection(title: "بانر الصفحة الرئيسية", draft: draft, items: \.banners, maxSide: 1600, wide: true)
            AdminBannerSection(title: "إعلان صفحة الطباعة", draft: draft, items: \.editorBannerList, maxSide: 1600, wide: true)
            AdminBannerSection(title: "منتجاتنا (أسفل الإعدادات)", draft: draft, items: \.settingsBannerList, maxSide: 1000, wide: false)
            Section {
                TextField("رابط شريط منتجاتنا", text: $draft.config.productsLinkText)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text("رابط واحد يفتح لما أحد يضغط على شريط منتجاتنا.")
            }
            Section("روابط التواصل") {
                socialField("إنستغرام (اسم الحساب أو رابط)", \.instagram)
                socialField("فيسبوك (اسم الصفحة أو رابط)", \.facebook)
                socialField("تيك توك (اسم الحساب أو رابط)", \.tiktok)
                socialField("رقم الواتساب (مثل 07701234567)", \.whatsapp)
            }
            Section {
                Stepper("البانرات تتبدل كل \(Int(draft.config.bannerSeconds)) ثانية", value: $draft.config.bannerSeconds, in: 1...10, step: 1)
            }

            Section("كلمة سر المدير") {
                SecureField("كلمة سر جديدة (6 أحرف أو أكثر)", text: $newPassword)
                Button("تغيير كلمة السر") {
                    let password = newPassword
                    newPassword = ""
                    Task {
                        do {
                            try await Server.changePassword(password)
                            message = "تغيّرت كلمة السر ✓"
                        } catch { message = error.localizedDescription }
                    }
                }
                .disabled(newPassword.count < 6)
            }
        }
        .navigationTitle("لوحة المدير")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("رفع", action: upload)
                    .bold()
                    .disabled(!draft.dirty || status != nil)
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .overlay {
            if let status {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(status)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("تمام", role: .cancel) {}
        }
        .task(id: lastSeen) {
            let all = (try? await Server.messages()) ?? []
            newMessages = all.filter { $0.date > lastSeen }.count
        }
    }

    private func socialField(_ title: String, _ key: WritableKeyPath<SocialLinks, String?>) -> some View {
        TextField(title, text: Binding(
            get: { draft.config.social?[keyPath: key] ?? "" },
            set: { value in
                var social = draft.config.social ?? SocialLinks()
                social[keyPath: key] = value.isEmpty ? nil : value
                draft.config.social = social
            }))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func upload() {
        let config = draft.config, files = draft.newFiles
        status = "أبدي الرفع…"
        Task {
            do {
                let saved = try await Server.publish(config: config, newFiles: files) { text in
                    Task { @MainActor in status = text }
                }
                cloud.apply(saved)
                draft.reset(to: saved)
                message = "تم الرفع ✓ التغييرات توصل لكل المستخدمين"
            } catch {
                message = error.localizedDescription
            }
            status = nil
        }
    }
}

struct AdminCategoryView: View {
    @ObservedObject var draft: AdminDraft
    let categoryID: String
    @State private var picks: [PhotosPickerItem] = []
    @State private var adding = false

    private var index: Int? { draft.config.categories.firstIndex { $0.id == categoryID } }

    var body: some View {
        if let i = index {
            Form {
                Section("اسم القسم") {
                    TextField("الاسم", text: $draft.config.categories[i].name)
                }
                Section("الصور (\(draft.config.categories[i].items.count))") {
                    PhotosPicker(selection: $picks, matching: .images) {
                        HStack {
                            Label("إضافة صور", systemImage: "plus")
                            if adding { Spacer(); ProgressView() }
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
                        ForEach(draft.config.categories[i].items) { item in
                            AdminThumb(draft: draft, file: item.file, fill: false)
                                .aspectRatio(1, contentMode: .fit)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2)))
                                .overlay(alignment: .topLeading) {
                                    removeButton {
                                        draft.forget(item.file)
                                        draft.config.categories[i].items.removeAll { $0.file == item.file }
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(draft.config.categories[i].name)
            .onChange(of: picks) { _, items in
                guard !items.isEmpty else { return }
                adding = true
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let name = draft.addImage(data, maxSide: 2000),
                           let j = index {
                            draft.config.categories[j].items.append(LibraryItem(file: name))
                        }
                    }
                    picks = []
                    adding = false
                }
            }
        }
    }
}

struct AdminThumb: View {
    @ObservedObject var draft: AdminDraft
    let file: String
    let fill: Bool

    var body: some View {
        if let data = draft.newFiles[file], let image = UIImage(data: data) {
            if fill {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(uiImage: image).resizable().scaledToFit().padding(4)
            }
        } else {
            RemoteImage(url: Cloud.file(file), fill: fill).padding(fill ? 0 : 4)
        }
    }
}

@ViewBuilder
func removeButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.brand)
    }
    .buttonStyle(.borderless)
    .padding(4)
}

extension LibraryConfig {
    var editorBannerList: [LibraryItem] {
        get { editorBanners ?? [] }
        set { editorBanners = newValue }
    }
    var settingsBannerList: [LibraryItem] {
        get { settingsBanners ?? [] }
        set { settingsBanners = newValue }
    }
    var productsLinkText: String {
        get { productsLink ?? "" }
        set { productsLink = newValue.isEmpty ? nil : newValue }
    }
}

/// قسم بانر بلوحة المدير: صور، حذف، وإضافة.
struct AdminBannerSection: View {
    let title: String
    @ObservedObject var draft: AdminDraft
    let items: WritableKeyPath<LibraryConfig, [LibraryItem]>
    let maxSide: CGFloat
    let wide: Bool
    @State private var picks: [PhotosPickerItem] = []

    private func linkBinding(_ file: String) -> Binding<String> {
        Binding(get: { draft.config[keyPath: items].first { $0.file == file }?.link ?? "" },
                set: { value in
                    if let i = draft.config[keyPath: items].firstIndex(where: { $0.file == file }) {
                        draft.config[keyPath: items][i].link = value.isEmpty ? nil : value
                    }
                })
    }

    var body: some View {
        Section(title) {
            let list = draft.config[keyPath: items]
            if wide {
                ForEach(list) { banner in
                    HStack(spacing: 10) {
                        AdminThumb(draft: draft, file: banner.file, fill: true)
                            .frame(width: 96, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        TextField("رابط عند الضغط (اختياري)", text: linkBinding(banner.file))
                            .font(.footnote)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        removeButton {
                            draft.forget(banner.file)
                            draft.config[keyPath: items].removeAll { $0.file == banner.file }
                        }
                    }
                }
            } else if !list.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(list) { banner in
                            AdminThumb(draft: draft, file: banner.file, fill: true)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topLeading) {
                                    removeButton {
                                        draft.forget(banner.file)
                                        draft.config[keyPath: items].removeAll { $0.file == banner.file }
                                    }
                                }
                        }
                    }
                }
            }
            PhotosPicker(selection: $picks, matching: .images) {
                Label("إضافة صور", systemImage: "photo.badge.plus")
            }
        }
        .onChange(of: picks) { _, chosen in
            guard !chosen.isEmpty else { return }
            Task {
                for item in chosen {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let name = draft.addImage(data, maxSide: maxSide) {
                        draft.config[keyPath: items].append(LibraryItem(file: name))
                    }
                }
                picks = []
            }
        }
    }
}


// MARK: - الرسائل

/// مربع «اقترح تعديل أو إضافة» للمستخدمين.
struct SuggestionSection: View {
    @State private var text = ""
    @State private var contact = ""
    @State private var sending = false
    @State private var result: String?
    @AppStorage("lastMessageDay") private var lastDay = ""
    private let limit = 300

    private var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    var body: some View {
        Section {
            if lastDay == today {
                Label("وصلتنا رسالتك، شكراً! تگدر ترسل رسالة ثانية باچر.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.ok)
            } else {
                TextField("رقمك أو حسابك حتى نرد عليك (اختياري)", text: $contact)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("اكتب اقتراحك هنا…", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .onChange(of: text) { _, new in if new.count > limit { text = String(new.prefix(limit)) } }
                HStack {
                    Text("\(limit - text.count) حرف باقي")
                        .font(.caption)
                        .foregroundStyle(text.count >= limit ? Color.brand : .secondary)
                    Spacer()
                    Button {
                        send()
                    } label: {
                        if sending { ProgressView() } else { Label("إرسال", systemImage: "paperplane.fill") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let result { Text(result).font(.caption).foregroundStyle(Color.brand) }
        } header: {
            Text("اقترح تعديل أو إضافة")
        }
    }

    private func send() {
        sending = true
        result = nil
        Task {
            do {
                try await Server.sendMessage(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                             contact: contact.trimmingCharacters(in: .whitespacesAndNewlines))
                lastDay = today
                text = ""
                contact = ""
            } catch {
                result = error.localizedDescription
            }
            sending = false
        }
    }
}

/// رسائل المستخدمين بلوحة المدير.
struct MessagesView: View {
    @Binding var lastSeen: Double
    @Environment(\.openURL) private var openURL
    @State private var messages: [UserMessage] = []
    @State private var loading = true
    @State private var problem: String?

    var body: some View {
        List {
            if loading && messages.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if messages.isEmpty {
                ContentUnavailableView("ما اكو رسائل", systemImage: "envelope.open",
                                       description: Text("الرسائل تنحذف وحدها بعد أسبوع."))
            }
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if message.date > lastSeen {
                            Circle().fill(Color.brand).frame(width: 8, height: 8)
                        }
                        Text(message.time, format: .dateTime.day().month().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(message.text)
                    if let contact = message.contact, !contact.isEmpty {
                        Button {
                            if let url = contactURL(contact) { openURL(url) }
                        } label: {
                            Label(contact, systemImage: "person.crop.circle")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                let removed = offsets.map { messages[$0] }
                messages.remove(atOffsets: offsets)
                Task {
                    for m in removed {
                        do { try await Server.deleteMessage(m.id) } catch { problem = error.localizedDescription }
                    }
                }
            }
        }
        .navigationTitle("رسائل المستخدمين")
        .refreshable { await load() }
        .task { await load() }
        .onDisappear {
            if let newest = messages.first?.date { lastSeen = max(lastSeen, newest) }
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("تمام", role: .cancel) {}
        }
    }

    private func load() async {
        loading = true
        do { messages = try await Server.messages() } catch { problem = error.localizedDescription }
        loading = false
    }

    /// رقم ← واتساب، وغيره ← إنستغرام أو رابط.
    private func contactURL(_ contact: String) -> URL? {
        let digits = contact.filter(\.isNumber)
        let visible = contact.filter({ !$0.isWhitespace }).count
        if digits.count >= 8 && digits.count >= visible - 2 {
            return Links.url(contact, kind: .whatsapp)
        }
        return Links.url(contact, kind: contact.contains(".") ? .web : .instagram)
    }
}
