import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app (required when launched from CLI, not a .app bundle)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Start Sparkle updater
        _ = Updater.shared

        HomeWindowController.shared.showWindow(nil)
        Task.detached(priority: .utility) {
            Project.ensureStorageDirectory()
        }

        AppNotifications.configure()

        AppState.shared.startMCPService()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if AppState.shared.activeProject == nil {
                let registry = ProjectRegistry.shared
                if let latest = registry.sortedEntries.first(where: { $0.isAccessible }) {
                    AppState.shared.openProject(at: latest.url)
                } else {
                    let defaultURL = Project.storageDirectory.appendingPathComponent("tsumugi_project.palmier")
                    let doc = VideoProject()
                    doc.fileURL = defaultURL
                    doc.fileType = VideoProject.typeIdentifier
                    doc.makeWindowControllers()
                    doc.showWindows()
                    NSDocumentController.shared.addDocument(doc)
                    doc.save(to: defaultURL, ofType: VideoProject.typeIdentifier, for: .saveOperation) { _ in
                        ProjectRegistry.shared.register(defaultURL)
                    }
                }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared.showHome()
        }
        return true
    }

    @MainActor
    @objc func newProject(_ sender: Any?) {
        AppState.shared.createNewProject()
    }

    @MainActor
    @objc func openProject(_ sender: Any?) {
        AppState.shared.openProjectFromPanel()
    }

    @MainActor
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @MainActor
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .shortcuts)
    }

    @MainActor
    @objc func showMCPInstructions(_ sender: Any?) {
        HelpWindowController.shared.show(tab: .mcp)
    }

    @MainActor
    @objc func showFeedback(_ sender: Any?) {
        FeedbackWindowController.shared.show()
    }

    @MainActor
    @objc func showTutorial(_ sender: Any?) {
        guard let editor = AppState.shared.activeProject?.editorViewModel else { return }
        editor.tour.start(in: editor)
    }
}
