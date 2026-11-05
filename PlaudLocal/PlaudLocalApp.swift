import SwiftUI

@main
struct PlaudLocalApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "list.bullet") }
            DeviceView()
                .tabItem { Label("Device", systemImage: "wave.3.right") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
