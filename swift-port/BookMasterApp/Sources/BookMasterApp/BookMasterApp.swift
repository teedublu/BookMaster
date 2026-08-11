import SwiftUI

@main
struct BookMasterApp: App {
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var usbMonitor = USBMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsStore)
                .environmentObject(usbMonitor)
                .frame(minWidth: 760, minHeight: 720)
        }
        .windowResizability(.contentSize)
    }
}
