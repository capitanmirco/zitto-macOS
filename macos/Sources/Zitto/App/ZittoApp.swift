import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZittoCore

@main
struct ZittoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("zitto", id: "main") {
            ContentView(model: model, player: model.player)
                .frame(minWidth: 1120, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1400, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files...") { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Mix...") { model.player.save() }
                    .keyboardShortcut("s")
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find Songs") { model.focusSearch += 1 }
                    .keyboardShortcut("f")
            }
            CommandMenu("Player") {
                Button("Play / Pause") { model.player.perform("toggle") }
                Button("Rewind") { model.player.perform("rewind") }
                Button("Stop") { model.player.perform("stop") }
                Divider()
                Button("Loop On / Off") { model.player.toggleLoop() }
                Button("Clear Loop") { model.player.perform("clear_loop") }
                Button("Zoom to Loop") { model.player.wave.showLoop() }
                Button("Show All") { model.player.wave.showAll() }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerModel

    var body: some View {
        HStack(spacing: 0) {
            LibraryView(model: model)
            PlayerView(player: player)
        }
        .background(Color.zBg)
        .navigationTitle(model.windowTitle)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            let lock = NSLock()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if !urls.isEmpty {
                    model.addFiles(urls.sorted { $0.path < $1.path })
                }
            }
            return true
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also when started without a bundle, from a terminal.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // zitto song.mp3: open the window with this song, as --player does on Windows.
        let given = CommandLine.arguments.dropFirst().filter {
            Texts.isURL($0) || FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath)
        }
        if let first = given.first {
            AppModel.shared.add(first)
        }
    }

    /// Files opened from the Finder, or dropped on the icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            AppModel.shared.addFiles(files)
        }
        for link in urls where !link.isFileURL {  // zitto --player LINK, from the command line
            AppModel.shared.add(link.absoluteString)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.close()
    }
}
