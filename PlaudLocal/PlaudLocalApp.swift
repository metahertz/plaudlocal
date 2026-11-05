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
            Text("Library")
                .tabItem { Label("Library", systemImage: "list.bullet") }
            Text("Device")
                .tabItem { Label("Device", systemImage: "wave.3.right") }
            Text("Settings")
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
