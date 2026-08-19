import AppKit
import SwiftUI

@main
struct VibeStickForMacApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(AppPreferenceKey.showMenuBarItem)
    private var menuBarItemInserted = AppConfiguration.standard.showMenuBarItem

    var body: some Scene {
        WindowGroup("VibeStick for Mac", id: "control-center") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    model.start()
                }
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("刷新状态") {
                    model.requestRefresh(forcePermissionCheck: true)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra(
            "VibeStick",
            image: "VibeStickMenuBar",
            isInserted: $menuBarItemInserted
        ) {
            MenuBarContentView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
                .environmentObject(model)
                .frame(width: 520)
                .padding(20)
        }
    }
}
