import SwiftUI
import PhotosUI

@main
struct RawsamApp: App {
    @StateObject private var printer = PrinterManager()
    @StateObject private var cloud = CloudLibrary()
    @StateObject private var local = LocalLibrary()

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(printer)
                .environmentObject(cloud)
                .environmentObject(local)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
                .tint(.brand)
                .preferredColorScheme(.light)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var printer: PrinterManager
    @EnvironmentObject private var cloud: CloudLibrary
    @EnvironmentObject private var local: LocalLibrary
    @State private var path = NavigationPath()
    @State private var tab: String?
    @State private var showPrinters = false
    @State private var printerMenu = false
    @State private var pick: PhotosPickerItem?

    private let mine = "mine"
    /// أول ما يفتح التطبيق يطلع قسم «+» (صور المستخدم).
    private var currentTab: String { tab ?? mine }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                tabs
                ScrollView {
                    VStack(spacing: 14) {
                        BannerView(items: cloud.config?.banners ?? [], seconds: cloud.config?.bannerSeconds ?? 3)
                            .padding(.horizontal)
                        grid
                    }
                    .padding(.vertical, 12)
                }
                .refreshable { await cloud.refresh() }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .editor(let source): EditorView(source: source)
                case .settings: SettingsView()
                }
            }
            .sheet(isPresented: $showPrinters) { PrinterPicker() }
            .confirmationDialog(printer.connectedName ?? "", isPresented: $printerMenu, titleVisibility: .visible) {
                Button("قطع الاتصال", role: .destructive) { printer.disconnect(forget: true) }
                Button("اختيار طابعة ثانية") { showPrinters = true }
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let url = local.add(data) {
                        path.append(Route.editor(.local(url)))
                    }
                    pick = nil
                }
            }
        }
        .task { await cloud.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(height: 44)
            Spacer()
            PrinterPill {
                if printer.isReady { printerMenu = true } else { showPrinters = true }
            }
            NavigationLink(value: Route.settings) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color.white)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(cloud.config?.categories ?? []) { tabButton($0.id, $0.name) }
                tabButton(mine, "+")
            }
            .padding(.horizontal)
            .padding(.top, 6)
        }
        .background(Color.white)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tabButton(_ id: String, _ title: String) -> some View {
        let selected = currentTab == id
        return Button { withAnimation(.snappy) { tab = id } } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(selected ? Color.brand : Color.secondary)
                Capsule()
                    .fill(selected ? Color.brand : Color.clear)
                    .frame(width: 26, height: 3)
            }
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    @ViewBuilder
    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            if currentTab == mine {
                PhotosPicker(selection: $pick, matching: .images) {
                    tile {
                        VStack(spacing: 8) {
                            Image(systemName: "plus").font(.system(size: 44, weight: .bold))
                            Text("صورة من تلفونك").font(.subheadline)
                        }
                        .foregroundStyle(Color.brand)
                    }
                }
                ForEach(local.items, id: \.self) { url in
                    NavigationLink(value: Route.editor(.local(url))) {
                        tile { LocalThumb(url: url) }
                    }
                    .contextMenu {
                        Button("حذف", systemImage: "trash", role: .destructive) { local.delete(url) }
                    }
                }
            } else if let category = cloud.config?.categories.first(where: { $0.id == currentTab }) {
                ForEach(category.items) { item in
                    NavigationLink(value: Route.editor(.remote(Cloud.file(item.file)))) {
                        tile { RemoteImage(url: Cloud.file(item.file)).padding(8) }
                    }
                }
            }
        }
        .padding(.horizontal)
        if cloud.config == nil {
            VStack(spacing: 10) {
                if cloud.loading { ProgressView() }
                if let error = cloud.error {
                    Text(error).foregroundStyle(.secondary)
                    Button("حاول مرة ثانية") { Task { await cloud.refresh() } }
                }
            }
            .padding()
        }
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white)
            .aspectRatio(1, contentMode: .fit)
            .overlay { content() }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }
}

private struct LocalThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit().padding(8) } else { ProgressView() }
        }
        .task(id: url) {
            guard let full = UIImage(contentsOfFile: url.path) else { return }
            let s = min(1, 360 / max(full.size.width, full.size.height, 1))
            image = await full.byPreparingThumbnail(ofSize: CGSize(width: full.size.width * s, height: full.size.height * s)) ?? full
        }
    }
}

struct PrinterPill: View {
    @EnvironmentObject private var printer: PrinterManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if printer.isConnecting {
                    ProgressView().tint(.white).controlSize(.small)
                } else {
                    Image(systemName: printer.isReady ? "checkmark.circle.fill" : "printer.fill")
                }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(color))
            .shadow(color: color.opacity(0.35), radius: 6, y: 3)
        }
        .animation(.snappy, value: printer.isReady)
    }

    private var title: String {
        if printer.isReady { return "متصلة" }
        if printer.isConnecting { return "جاري الاتصال…" }
        return "ابحث عن طابعة"
    }

    private var color: Color {
        if printer.isReady { return .ok }
        if printer.isConnecting { return .orange }
        return .brand
    }
}

struct PrinterPicker: View {
    @EnvironmentObject private var printer: PrinterManager
    @Environment(\.dismiss) private var dismiss
    @State private var showAll = false

    var body: some View {
        NavigationStack {
            List {
                if printer.bluetoothOff {
                    Label("شغّل البلوتوث واسمح للتطبيق بيه من الإعدادات", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.brand)
                }
                let shown = printer.devices.filter { showAll || printer.looksLikePrinter($0) }
                Section {
                    if shown.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("أدور على الطابعات… تأكد الطابعة شغالة")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(shown) { device in
                        Button {
                            printer.connect(device)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: printer.looksLikePrinter(device) ? "printer.fill" : "dot.radiowaves.right")
                                    .foregroundStyle(Color.brand)
                                Text(device.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "wifi", variableValue: signal(device.rssi))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Toggle("عرض كل أجهزة البلوتوث", isOn: $showAll)
            }
            .navigationTitle("اختر الطابعة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("إغلاق") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .onAppear { printer.scan() }
        .onDisappear { printer.stopScan() }
    }

    private func signal(_ rssi: Int) -> Double {
        min(1, max(0.1, Double(rssi + 100) / 50))
    }
}

/// بانر صور يتبدل وحده. يستخدم بالرئيسية، صفحة الطباعة، والإعدادات.
struct BannerView: View {
    let items: [LibraryItem]
    let seconds: Double
    var height: CGFloat? = 160
    var square = false
    @State private var index = 0
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !items.isEmpty {
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, banner in
                    RemoteImage(url: Cloud.file(banner.file), fill: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { if let url = Links.url(banner.link) { openURL(url) } }
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
            .frame(height: square ? nil : height)
            .aspectRatio(square ? 1 : nil, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .task(id: items) {
                guard items.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(max(1, seconds)))
                    if Task.isCancelled { return }
                    withAnimation(.easeInOut(duration: 0.5)) { index = (index + 1) % items.count }
                }
            }
        }
    }
}
