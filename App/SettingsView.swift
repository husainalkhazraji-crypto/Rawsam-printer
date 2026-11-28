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
    @State private var copied = false
    @State private var heatWarning = false

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

            Section {
                Button {
                    password = ""
                    askPassword = true
                } label: {
                    Label("Admin", systemImage: "lock.fill")
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
                Text("Designed by Rawsam Tattoo")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }

            if let ads = cloud.config?.settingsBanners, !ads.isEmpty {
                Section {
                    BannerView(items: ads, seconds: cloud.config?.bannerSeconds ?? 3, square: true)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
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
        .navigationDestination(item: $adminConfig) { config in
            AdminView(config: config)
        }
    }

    private func checkPassword() {
        guard let config = cloud.config else {
            problem = "حدّث المكتبة أولاً (تحتاج إنترنت)"
            return
        }
        if Cloud.hash(password) == config.passwordHash {
            adminConfig = config
        } else {
            problem = "كلمة السر غلط"
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
    @State private var token = Keychain.read(Cloud.tokenKey) ?? ""
    @State private var tokenField = ""
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
                if token.isEmpty {
                    Label("السحابة مو مربوطة بهذا التلفون", systemImage: "xmark.icloud").foregroundStyle(Color.brand)
                } else {
                    Label("السحابة مربوطة", systemImage: "checkmark.icloud.fill").foregroundStyle(Color.ok)
                }
                SecureField("الصق رمز GitHub هنا", text: $tokenField)
                Button("حفظ الرمز") {
                    let clean = tokenField.trimmingCharacters(in: .whitespacesAndNewlines)
                    Keychain.save(clean, for: Cloud.tokenKey)
                    token = clean
                    tokenField = ""
                }
                .disabled(tokenField.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("ربط السحابة")
            } footer: {
                Text("مرة وحدة بس بهذا التلفون. الرمز ينحفظ بشكل آمن ومحد يشوفه.")
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
            AdminBannerSection(title: "إعلان الإعدادات (مربع)", draft: draft, items: \.settingsBannerList, maxSide: 1200, wide: false)
            Section {
                Stepper("البانرات تتبدل كل \(Int(draft.config.bannerSeconds)) ثانية", value: $draft.config.bannerSeconds, in: 1...10, step: 1)
            }

            Section("كلمة سر المدير") {
                SecureField("كلمة سر جديدة (4 أحرف أو أكثر)", text: $newPassword)
                Button("تغيير كلمة السر") {
                    draft.config.passwordHash = Cloud.hash(newPassword)
                    newPassword = ""
                    message = "تتغير بعد ما تضغط «رفع»"
                }
                .disabled(newPassword.count < 4)
            }
        }
        .navigationTitle("لوحة المدير")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("رفع", action: upload)
                    .bold()
                    .disabled(!draft.dirty || status != nil || token.isEmpty)
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
    }

    private func upload() {
        let config = draft.config, files = draft.newFiles, deleted = draft.deleted
        status = "أبدي الرفع…"
        Task {
            do {
                let saved = try await GitHubUploader(token: token).upload(config: config, newFiles: files, deleted: deleted) { text in
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
}

/// قسم بانر بلوحة المدير: صور، حذف، وإضافة.
struct AdminBannerSection: View {
    let title: String
    @ObservedObject var draft: AdminDraft
    let items: WritableKeyPath<LibraryConfig, [LibraryItem]>
    let maxSide: CGFloat
    let wide: Bool
    @State private var picks: [PhotosPickerItem] = []

    var body: some View {
        Section(title) {
            let list = draft.config[keyPath: items]
            if !list.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(list) { banner in
                            AdminThumb(draft: draft, file: banner.file, fill: true)
                                .frame(width: wide ? 150 : 90, height: wide ? 80 : 90)
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
