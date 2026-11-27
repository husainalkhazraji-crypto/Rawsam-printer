import SwiftUI

@main
struct WashmApp: App {
    @StateObject private var printer = PrinterManager()
    @StateObject private var library = DesignLibrary()

    var body: some Scene {
        WindowGroup {
            TabView {
                LibraryView()
                    .tabItem { Label("المكتبة", systemImage: "square.grid.2x2.fill") }
                PrinterView()
                    .tabItem { Label("الطابعة", systemImage: "printer.fill") }
            }
            .environmentObject(printer)
            .environmentObject(library)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "ar"))
            .tint(Color(red: 0.55, green: 0.36, blue: 0.96))
            .preferredColorScheme(.dark)
        }
    }
}
