import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: DesignLibrary
    @State private var category: String?
    @State private var picked: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var newCategory = ""
    @State private var failed = false

    private var shown: [Design] {
        guard let category, library.categories.contains(category) else { return library.designs }
        return library.designs.filter { $0.category == category }
    }

    private var target: String {
        newCategory.isEmpty ? (category ?? DesignLibrary.userCategory) : newCategory
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            chip("الكل", value: nil)
                            ForEach(library.categories, id: \.self) { chip($0, value: $0) }
                        }
                    }
                    TextField("اسم قسم جديد للإضافة (اختياري)", text: $newCategory)
                        .textFieldStyle(.roundedBorder)
                    if shown.isEmpty {
                        ContentUnavailableView("المكتبة فارغة", systemImage: "photo.on.rectangle",
                                               description: Text("اضغط + حتى تضيف تصاميمك"))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 12)], spacing: 12) {
                        ForEach(shown) { design in
                            NavigationLink(value: design) { Thumbnail(design: design) }
                                .contextMenu {
                                    if design.isUserAdded {
                                        Button("حذف", role: .destructive) { library.delete(design) }
                                    }
                                }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("وشم")
            .navigationDestination(for: Design.self) { EditorView(design: $0) }
            .toolbar {
                Menu {
                    Button("من الصور", systemImage: "photo") { showPhotos = true }
                    Button("من الملفات", systemImage: "folder") { showFiles = true }
                } label: { Image(systemName: "plus") }
            }
            .photosPicker(isPresented: $showPhotos, selection: $picked, matching: .images)
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                let destination = target
                Task { @MainActor in
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           library.add(data, category: destination) { continue }
                        failed = true
                    }
                    picked = []
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                for url in (try? result.get()) ?? [] {
                    let access = url.startAccessingSecurityScopedResource()
                    if let data = try? Data(contentsOf: url), library.add(data, category: target) {} else { failed = true }
                    if access { url.stopAccessingSecurityScopedResource() }
                }
            }
            .alert("تعذرت إضافة صورة", isPresented: $failed) { Button("تمام", role: .cancel) {} }
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        Button(title) { category = value; newCategory = "" }
            .buttonStyle(.borderedProminent)
            .tint(category == value ? Color.accentColor : Color.gray.opacity(0.35))
    }
}

private struct Thumbnail: View {
    let design: Design
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image { Image(uiImage: image).resizable().scaledToFit().padding(6) }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task(id: design.url) {
            guard let full = UIImage(contentsOfFile: design.url.path) else { return }
            // نحافظ على نسبة أبعاد الصورة.
            let scale = min(1, 320 / max(full.size.width, full.size.height, 1))
            let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
            image = await full.byPreparingThumbnail(ofSize: size) ?? full
        }
    }
}
