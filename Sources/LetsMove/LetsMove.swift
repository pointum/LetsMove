//
//  LetsMove.swift
//  LetsMove
//
//  Created by Andy Kim at Potion Factory LLC on 9/17/09
//
//  The contents of this file are dedicated to the public domain.

import AppKit

public enum LetsMove {
    private static var couldNotMoveTitle: String {
        NSLocalizedString("COULD_NOT_MOVE", bundle: .module, comment: "")
    }
    private static func alertTitle(with appName: String) -> String {
        String(format: NSLocalizedString("ALERT_TITLE", bundle: .module, comment: ""), appName)
    }
    private static var alertMessage: String {
        NSLocalizedString("MOVE_TO_APPS", bundle: .module, comment: "")
    }
    private static var alertMessageHome: String {
        NSLocalizedString("MOVE_TO_HOME", bundle: .module, comment: "")
    }
    private static var moveButtonTitle: String {
        NSLocalizedString("MOVE_BUTTON", bundle: .module, comment: "")
    }
    private static var dontMoveButtonTitle: String {
        NSLocalizedString("DONT_BUTTON", bundle: .module, comment: "")
    }
    private static var downloadsNote: String {
        NSLocalizedString("DOWNLOADS_NOTE", bundle: .module, comment: "")
    }

    // By default, we use a small control/font for the suppression button.
    // If you prefer to use the system default (to match your other alerts),
    // set this to false.
    public static var usesSmallSuppressionCheckbox = true
    public private(set) static var isInProgress = false
    private static let alertSuppressKey = "moveToApplicationsFolderAlertSuppress"

    // MARK: - Main worker function

    public static func moveToApplicationsFolderIfNecessary() {

        // Make sure to do our work on the main thread.
        // Apparently Electron apps need this for things to work properly.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { moveToApplicationsFolderIfNecessary() }
            return
        }

        // Skip if user suppressed the alert before
        guard !UserDefaults.standard.bool(forKey: alertSuppressKey) else { return }

        // URL of the bundle
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return }

        // Check if the bundle is embedded in another application
        let hasParentApp = bundleURL.hasParentApp

        // Skip if the application is already in some Applications folder,
        // unless it's inside another app's bundle.
        guard !bundleURL.isInApplicationsFolder || hasParentApp else { return }

        // Skip if won't be able to move
        guard let (applicationsDirectory, installToUserApplications) = preferredInstallLocation() else { return }
        let destinationURL = applicationsDirectory.appendingPathComponent(bundleURL.lastPathComponent)
        guard !destinationURL.resourceExists || destinationURL.isWritable else { return }

        isInProgress = true

        // Are we on a disk image?
        let removableDevicePath = bundleURL.removableDevicePath

        // Setup the alert
        let appName = NSRunningApplication.current.localizedName
                   ?? bundleURL.deletingPathExtension().lastPathComponent

        let alert = NSAlert()
        alert.messageText = alertTitle(with: appName)

        var informativeText = installToUserApplications ? alertMessageHome : alertMessage
        if bundleURL.isContained(in: .downloadsDirectory) {
            informativeText += " " + downloadsNote
        }
        alert.informativeText = informativeText

        alert.addButton(withTitle: moveButtonTitle)

        let cancelButton = alert.addButton(withTitle: dontMoveButtonTitle)
        cancelButton.keyEquivalent = "\u{1b}" // Escape key

        alert.showsSuppressionButton = true
        if usesSmallSuppressionCheckbox {
            alert.suppressionButton?.controlSize = .small
            alert.suppressionButton?.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        // Activate app -- work-around for focus issues related to "scary file from internet" OS dialog.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        func showFailureAlert() {
            let failAlert = NSAlert()
            failAlert.messageText = couldNotMoveTitle
            failAlert.runModal()
            isInProgress = false
        }

        if alert.runModal() == .alertFirstButtonReturn {
            NSLog("INFO -- Moving myself to the Applications folder")

            // If a copy already exists in the Applications folder, make sure it's not running
            if destinationURL.isApplicationRunning {
                // Give the running app focus and quit
                openRunning(at: destinationURL)
                isInProgress = false
                exit(0)
            }

            // If a copy already exists in the Applications folder, put it in the Trash
            if destinationURL.resourceExists {
                if !destinationURL.moveToTrash() {
                    showFailureAlert()
                    return
                }
            }

            if !copyBundle(srcURL: bundleURL, dstURL: destinationURL) {
                NSLog("ERROR -- Could not copy myself to \(destinationURL.path)")
                showFailureAlert()
                return
            }

            // It's okay if deleting original fails.
            // NOTE: This can fail in these known cases:
            // - The source bundle is on a network mounted volume
            // - The app was translocated and cannot modify itself
            if !hasParentApp && removableDevicePath == nil && !bundleURL.delete() {
                NSLog("WARNING -- Could not delete application after moving it to Applications folder")
            }

            // Relaunch.
            relaunch(destination: destinationURL)

            // Launched from within a disk image? -- unmount (if no files are open after 5 seconds,
            // otherwise leave it mounted).
            if let device = removableDevicePath, !hasParentApp {
                let script = "(/bin/sleep 5 && /usr/bin/hdiutil detach \(shellQuoted(device))) &"
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", script]
                try? task.run()
            }

            exit(0)
        }
        // Save the alert suppress preference if checked
        else if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: alertSuppressKey)
        }

        isInProgress = false
    }

    // MARK: - Helper Functions

    private static func preferredInstallLocation() -> (url: URL, isUserDirectory: Bool)? {
        // Prefer ~/Applications if the user already has apps there.
        let fm = FileManager.default

        if let userAppsFolder = fm.urls(for: .applicationDirectory, in: .userDomainMask).first,
           let enumerator = fm.enumerator(at: userAppsFolder, includingPropertiesForKeys: nil,
                                          options: .skipsSubdirectoryDescendants) {
            let hasAnApp = enumerator.contains { ($0 as? URL)?.pathExtension == "app" }
            if hasAnApp && userAppsFolder.isWritable { return (userAppsFolder, true) }
        }

        guard let localAppsFolder = fm.urls(for: .applicationDirectory, in: .localDomainMask).last else { return nil }
        if localAppsFolder.isWritable { return (localAppsFolder, false) }

        return nil
    }

    private static func copyBundle(srcURL: URL, dstURL: URL) -> Bool {
        do {
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
            return true
        } catch {
            NSLog("ERROR -- Could not copy '\(srcURL.path)' to '\(dstURL.path)' (\(error))")
            return false
        }
    }

    private static func openRunning(at url: URL) {
        NSLog("INFO -- Switching to an already running version")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [url.path]
        try? task.run()
        task.waitUntilExit()
    }

    private static func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func relaunch(destination: URL) {
        // The shell script waits until the original app process terminates.
        // This is done so that the relaunched app opens as the front-most app.
        let pid = ProcessInfo.processInfo.processIdentifier

        let quotedDestinationPath = shellQuoted(destination.path)

        // Command run just before running open /final/path
        // Before we launch the new app, clear xattr:com.apple.quarantine to avoid
        // duplicate "scary file from the internet" dialog.

        let removeQuarantine = "/usr/bin/xattr -d -r com.apple.quarantine \(quotedDestinationPath)"

        let script = "(while /bin/kill -0 \(pid) >&/dev/null; do /bin/sleep 0.1; done; \(removeQuarantine); /usr/bin/open \(quotedDestinationPath)) &"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }
}
