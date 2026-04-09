//
//  LetsMove.swift
//  LetsMove
//
//  Created by Andy Kim at Potion Factory LLC on 9/17/09
//
//  The contents of this file are dedicated to the public domain.

import AppKit
import Darwin

public enum LetsMove {
    // Strings are computed properties to allow custom i18n tooling to intercept.
    private static var couldNotMoveAlertTitle: String { localizedString("Could not move to Applications folder") }
    private static var moveAlertTitle: String { localizedString("Move to Applications folder?") }
    private static var moveAlertTitleHome: String { localizedString("Move to Applications folder in your Home folder?") }
    private static var moveAlertMessage: String { localizedString("I can move myself to the Applications folder if you'd like.") }
    private static var moveButtonTitle: String { localizedString("Move to Applications Folder") }
    private static var doNotMoveButtonTitle: String { localizedString("Do Not Move") }
    private static var requiresPasswordNote: String { localizedString("Note that this will require an administrator password.") }
    private static var downloadsNote: String { localizedString("This will keep your Downloads folder uncluttered.") }

    private static func localizedString(_ key: String) -> String {
        NSLocalizedString(key, tableName: "LetsMove", bundle: Bundle.module, comment: "")
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

        // Check if the bundle is embedded in another application
        let isNested = isApplicationNested(at: bundleURL)

        // Skip if the application is already in some Applications folder,
        // unless it's inside another app's bundle.
        guard !isInApplicationsFolder(bundleURL) || isNested else { return }

        // OK, looks like we'll need to do a move - set the status variable appropriately
        isInProgress = true

        // Are we on a disk image?
        let diskImageDevice = diskImageDevice(containing: bundleURL)

        // Since we are good to go, get the preferred installation directory.
        let (applicationsDirectory, installToUserApplications) = preferredInstallLocation()
        let destinationURL = applicationsDirectory.appendingPathComponent(bundleURL.lastPathComponent)

        // Check if we need admin password to write to the Applications directory
        var needAuthorization = !applicationsDirectory.isWritable

        // Check if the destination bundle is already there but not writable
        if destinationURL.resourceExists {
            needAuthorization = needAuthorization || !destinationURL.isWritable
        }

        // Setup the alert
        let alert = NSAlert()
        do {
            alert.messageText = installToUserApplications ? moveAlertTitleHome : moveAlertTitle

            var informativeText = moveAlertMessage

            if needAuthorization {
                informativeText += " " + requiresPasswordNote
            } else if isURL(bundleURL, in: .downloadsDirectory) {
                // Don't mention this stuff if we need authentication. The informative text is long enough as it is in that case.
                informativeText += " " + downloadsNote
            }

            alert.informativeText = informativeText

            // Add accept button
            alert.addButton(withTitle: moveButtonTitle)

            // Add deny button
            let cancelButton = alert.addButton(withTitle: doNotMoveButtonTitle)
            cancelButton.keyEquivalent = "\u{1b}" // Escape key

            // Setup suppression button
            alert.showsSuppressionButton = true

            if usesSmallSuppressionCheckbox {
                alert.suppressionButton?.controlSize = .small
                alert.suppressionButton?.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            }
        }

        // Activate app -- work-around for focus issues related to "scary file from internet" OS dialog.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        func showFailureAlert() {
            let failAlert = NSAlert()
            failAlert.messageText = couldNotMoveAlertTitle
            failAlert.runModal()
            isInProgress = false
        }

        if alert.runModal() == .alertFirstButtonReturn {
            NSLog("INFO -- Moving myself to the Applications folder")

            // Move
            if needAuthorization {
                switch privilegedInstaller.install(from: bundleURL, to: destinationURL) {
                case .success:
                    break
                case .failed:
                    NSLog("ERROR -- Could not copy myself to /Applications with authorization")
                    showFailureAlert()
                    return
                case .canceled:
                    NSLog("INFO -- Not moving because user canceled authorization")
                    isInProgress = false
                    return
                }
            } else {
                // If a copy already exists in the Applications folder, put it in the Trash
                if destinationURL.resourceExists {
                    // But first, make sure that it's not running
                    if isApplicationRunning(at: destinationURL) {
                        // Give the running app focus and terminate myself
                        NSLog("INFO -- Switching to an already running version")
                        let task = Process()
                        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        task.arguments = [destinationURL.path]
                        try? task.run()
                        task.waitUntilExit()
                        isInProgress = false
                        exit(0)
                    } else {
                        if !trash(destinationURL) {
                            showFailureAlert()
                            return
                        }
                    }
                }

                if !copyBundle(srcURL: bundleURL, dstURL: destinationURL) {
                    NSLog("ERROR -- Could not copy myself to \(destinationURL.path)")
                    showFailureAlert()
                    return
                }
            }

            // Trash the original app. It's okay if this fails.
            // NOTE: This final delete does not work if the source bundle is in a network mounted volume.
            //       Calling rm or file manager's delete method doesn't work either. It's unlikely to happen
            //       but it'd be great if someone could fix this.
            if !isNested && diskImageDevice == nil && !deleteOrTrash(bundleURL) {
                NSLog("WARNING -- Could not delete application after moving it to Applications folder")
            }

            // Relaunch.
            relaunch(destination: destinationURL)

            // Launched from within a disk image? -- unmount (if no files are open after 5 seconds,
            // otherwise leave it mounted).
            if let device = diskImageDevice, !isNested {
                let script = "(/bin/sleep 5 && /usr/bin/hdiutil detach \(shellQuoted(device))) &"
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", script]
                try? task.run()
            }

            isInProgress = false
            exit(0)
        }
        // Save the alert suppress preference if checked
        else if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: alertSuppressKey)
        }

        isInProgress = false
    }

    // MARK: - Helper Functions

    private static func preferredInstallLocation() -> (url: URL, isUserDirectory: Bool) {
        // Return the preferred install location.
        // Assume that if the user has a ~/Applications folder, they'd prefer their
        // applications to go there.

        let fm = FileManager.default

        if let userAppURL = fm.urls(for: .applicationDirectory, in: .userDomainMask).first,
           userAppURL.isDirectory {
            // User Applications directory exists. Get the directory contents.
            let contents = (try? fm.contentsOfDirectory(at: userAppURL, includingPropertiesForKeys: nil)) ?? []

            // Check if there is at least one ".app" inside the directory.
            for item in contents where item.pathExtension == "app" {
                return (userAppURL.resolvingSymlinksInPath(), true)
            }
        }

        // No user Applications directory in use. Return the machine local Applications directory
        let localAppURL = fm.urls(for: .applicationDirectory, in: .localDomainMask).last
            ?? URL(fileURLWithPath: "/Applications")
        return (localAppURL.resolvingSymlinksInPath(), false)
    }

    private static func isURL(_ url: URL, in directory: FileManager.SearchPathDirectory) -> Bool {
        let fm = FileManager.default
        for directoryURL in fm.urls(for: directory, in: .allDomainsMask) {
            var relationship: FileManager.URLRelationship = .other
            try? fm.getRelationship(&relationship, ofDirectoryAt: directoryURL, toItemAt: url)
            if relationship == .contains { return true }
        }
        return false
    }

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        // Also, handle the case that the user has some other Application directory (perhaps on a separate data partition).
        isURL(url, in: .applicationDirectory) || url.pathComponents.contains("Applications")
    }

    private static func isApplicationRunning(at bundleURL: URL) -> Bool {
        guard let id = bundleURL.fileResourceIdentifier else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.fileResourceIdentifier.map { id.isEqual($0) } ?? false
        }
    }

    private static func isApplicationNested(at url: URL) -> Bool {
        for component in url.deletingLastPathComponent().pathComponents {
            if component.hasSuffix(".app") {
                return true
            }
        }

        return false
    }

    private static func diskImageDevice(containing url: URL) -> String? {
        let containingPath = url.deletingLastPathComponent().path

        var fs = statfs()
        if statfs((containingPath as NSString).fileSystemRepresentation, &fs) != 0 || (fs.f_flags & UInt32(MNT_ROOTFS)) != 0 {
            return nil
        }

        let device = withUnsafeBytes(of: fs.f_mntfromname) { bytes -> String in
            let ptr = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
            return FileManager.default.string(withFileSystemRepresentation: ptr, length: strlen(ptr))
        }

        let hdiutil = Process()
        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = ["info", "-plist"]
        let pipe = Pipe()
        hdiutil.standardOutput = pipe
        guard (try? hdiutil.run()) != nil else { return nil }
        hdiutil.waitUntilExit()

        struct HdiutilInfo: Decodable {
            let images: [Image]

            struct Image: Decodable {
                let systemEntities: [SystemEntity]?
                enum CodingKeys: String, CodingKey { case systemEntities = "system-entities" }

                struct SystemEntity: Decodable {
                    let devEntry: String?
                    enum CodingKeys: String, CodingKey { case devEntry = "dev-entry" }
                }
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let info = try? PropertyListDecoder().decode(HdiutilInfo.self, from: data) else { return nil }

        let isDiskImage = info.images.contains {
            $0.systemEntities?.contains {
                $0.devEntry == device
            } ?? false
        }
        return isDiskImage ? device : nil
    }

    private static func trash(_ url: URL) -> Bool {
        var result = (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil

        // As a last resort try trashing with AppleScript.
        // This allows us to trash the app in macOS Sierra even when the app is running inside
        // an app translocation image.
        if !result {
            let source = """
                set theFile to POSIX file "\(url.path)"
                tell application "Finder"
                    move theFile to trash
                end tell
                """
            var errorDict: NSDictionary?
            let appleScript = NSAppleScript(source: source)
            let scriptResult = appleScript?.executeAndReturnError(&errorDict)
            if scriptResult == nil {
                NSLog("Trash AppleScript error: %@", errorDict ?? [:])
            }
            result = scriptResult != nil
        }

        if !result {
            NSLog("ERROR -- Could not trash '\(url.path)'")
        }

        return result
    }

    private static func deleteOrTrash(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            // Don't log warning if on Sierra and running inside App Translocation path
            if !url.path.contains("/AppTranslocation/") {
                NSLog("WARNING -- Could not delete '\(url.path)': \(error.localizedDescription)")
            }

            return trash(url)
        }
    }

    private static let privilegedInstaller = PrivilegedInstaller()

    private static func copyBundle(srcURL: URL, dstURL: URL) -> Bool {
        do {
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
            return true
        } catch {
            NSLog("ERROR -- Could not copy '\(srcURL.path)' to '\(dstURL.path)' (\(error))")
            return false
        }
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

        let preOpenCmd = "/usr/bin/xattr -d -r com.apple.quarantine \(quotedDestinationPath)"

        let script = "(while /bin/kill -0 \(pid) >&/dev/null; do /bin/sleep 0.1; done; \(preOpenCmd); /usr/bin/open \(quotedDestinationPath)) &"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
    }
}

private extension URL {
    var resourceExists: Bool {
        (try? checkResourceIsReachable()) == true
    }

    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    var isWritable: Bool {
        (try? resourceValues(forKeys: [.isWritableKey]))?.isWritable == true
    }

    var fileResourceIdentifier: (any NSCopying & NSSecureCoding & NSObjectProtocol)? {
        try? resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }
}
