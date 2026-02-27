import SwiftUI
import AppKit

enum AppMenuCommand {
    static let newConfig = Notification.Name("AppMenuCommand.newConfig")
    static let open = Notification.Name("AppMenuCommand.open")
    static let save = Notification.Name("AppMenuCommand.save")
    static let saveAs = Notification.Name("AppMenuCommand.saveAs")
    static let setCurrentAndSave = Notification.Name("AppMenuCommand.setCurrentAndSave")
    static let export = Notification.Name("AppMenuCommand.export")
    static let `import` = Notification.Name("AppMenuCommand.import")
    static let updates = Notification.Name("AppMenuCommand.updates")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct KubeconfigEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppView()
        }
        .defaultSize(width: 1320, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            FileMenuCommands()
        }
    }
}

struct FileMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Updates...") {
                NotificationCenter.default.post(name: AppMenuCommand.updates, object: nil)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New") {
                NotificationCenter.default.post(name: AppMenuCommand.newConfig, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Open...") {
                NotificationCenter.default.post(name: AppMenuCommand.open, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                NotificationCenter.default.post(name: AppMenuCommand.save, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command])

            Button("Save As...") {
                NotificationCenter.default.post(name: AppMenuCommand.saveAs, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandGroup(after: .saveItem) {
            Divider()

            Button("Set Current + Save") {
                NotificationCenter.default.post(name: AppMenuCommand.setCurrentAndSave, object: nil)
            }

            Button("Export...") {
                NotificationCenter.default.post(name: AppMenuCommand.export, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Import...") {
                NotificationCenter.default.post(name: AppMenuCommand.import, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}
