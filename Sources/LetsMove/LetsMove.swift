//
//  LetsMove.swift
//  LetsMove
//
//  Created by Andy Kim at Potion Factory LLC on 9/17/09
//
//  The contents of this file are dedicated to the public domain.

import AppKit
import Security
import Darwin

private var letsMoveBundle: Bundle {
#if SWIFT_PACKAGE
    return Bundle.module
#else
    class LetsMoveBundleToken {}
    return Bundle(for: LetsMoveBundleToken.self)
#endif
}

// Strings
// These are computed properties to be able to use custom i18n tools
private func localizedString(_ key: String) -> String {
    NSLocalizedString(key, tableName: "LetsMove", bundle: letsMoveBundle, comment: "")
}

private var strMoveApplicationCouldNotMove: String {
    localizedString("Could not move to Applications folder")
}
private var strMoveApplicationQuestionTitle: String {
    localizedString("Move to Applications folder?")
}
private var strMoveApplicationQuestionTitleHome: String {
    localizedString("Move to Applications folder in your Home folder?")
}
private var strMoveApplicationQuestionMessage: String {
    localizedString("I can move myself to the Applications folder if you'd like.")
}
private var strMoveApplicationButtonMove: String {
    localizedString("Move to Applications Folder")
}
private var strMoveApplicationButtonDoNotMove: String {
    localizedString("Do Not Move")
}
private var strMoveApplicationQuestionInfoWillRequirePasswd: String {
    localizedString("Note that this will require an administrator password.")
}
private var strMoveApplicationQuestionInfoInDownloadsFolder: String {
    localizedString("This will keep your Downloads folder uncluttered.")
}

// By default, we use a small control/font for the suppression button.
// If you prefer to use the system default (to match your other alerts),
// set this to false.
private let useSmallAlertSuppressCheckbox = true
private let alertSuppressKey = "moveToApplicationsFolderAlertSuppress"
private var moveInProgress = false

// Main worker function
@_cdecl("PFMoveToApplicationsFolderIfNecessary")
public func PFMoveToApplicationsFolderIfNecessary() {

    // Make sure to do our work on the main thread.
    // Apparently Electron apps need this for things to work properly.
    guard Thread.isMainThread else {
        DispatchQueue.main.async { PFMoveToApplicationsFolderIfNecessary() }
        return
    }

    // Skip if user suppressed the alert before
    guard !UserDefaults.standard.bool(forKey: alertSuppressKey) else { return }

    // Path of the bundle
    let bundlePath = Bundle.main.bundlePath

    // Check if the bundle is embedded in another application
    let isNestedApplication = isApplicationAtPathNested(bundlePath)

    // Skip if the application is already in some Applications folder,
    // unless it's inside another app's bundle.
    guard !isInApplicationsFolder(bundlePath) || isNestedApplication else { return }

    // OK, looks like we'll need to do a move - set the status variable appropriately
    moveInProgress = true

    // File Manager
    let fm = FileManager.default

    // Are we on a disk image?
    let diskImageDevice = containingDiskImageDevice(bundlePath)

    // Since we are good to go, get the preferred installation directory.
    var installToUserApplications = false
    let applicationsDirectory = preferredInstallLocation(isUserDirectory: &installToUserApplications)
    let bundleName = (bundlePath as NSString).lastPathComponent
    let destinationPath = (applicationsDirectory as NSString).appendingPathComponent(bundleName)

    // Check if we need admin password to write to the Applications directory
    var needAuthorization = !fm.isWritableFile(atPath: applicationsDirectory)

    // Check if the destination bundle is already there but not writable
    needAuthorization = needAuthorization
        || (fm.fileExists(atPath: destinationPath) && !fm.isWritableFile(atPath: destinationPath))

    // Setup the alert
    let alert = NSAlert()
    do {
        alert.messageText = installToUserApplications
            ? strMoveApplicationQuestionTitleHome
            : strMoveApplicationQuestionTitle

        var informativeText = strMoveApplicationQuestionMessage

        if needAuthorization {
            informativeText += " " + strMoveApplicationQuestionInfoWillRequirePasswd
        } else if isInDownloadsFolder(bundlePath) {
            // Don't mention this stuff if we need authentication. The informative text is long enough as it is in that case.
            informativeText += " " + strMoveApplicationQuestionInfoInDownloadsFolder
        }

        alert.informativeText = informativeText

        // Add accept button
        alert.addButton(withTitle: strMoveApplicationButtonMove)

        // Add deny button
        let cancelButton = alert.addButton(withTitle: strMoveApplicationButtonDoNotMove)
        cancelButton.keyEquivalent = "\u{1b}" // Escape key

        // Setup suppression button
        alert.showsSuppressionButton = true

        if useSmallAlertSuppressCheckbox {
            if let cell = alert.suppressionButton?.cell as? NSCell {
                cell.controlSize = .small
                cell.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            }
        }
    }

    // Activate app -- work-around for focus issues related to "scary file from internet" OS dialog.
    if !NSApp.isActive {
        NSApp.activate(ignoringOtherApps: true)
    }

    func showFailureAlert() {
        let failAlert = NSAlert()
        failAlert.messageText = strMoveApplicationCouldNotMove
        failAlert.runModal()
        moveInProgress = false
    }

    if alert.runModal() == .alertFirstButtonReturn {
        NSLog("INFO -- Moving myself to the Applications folder")

        // Move
        if needAuthorization {
            var authorizationCanceled = false
            if !authorizedInstall(srcPath: bundlePath, dstPath: destinationPath, canceled: &authorizationCanceled) {
                if authorizationCanceled {
                    NSLog("INFO -- Not moving because user canceled authorization")
                    moveInProgress = false
                    return
                } else {
                    NSLog("ERROR -- Could not copy myself to /Applications with authorization")
                    showFailureAlert()
                    return
                }
            }
        } else {
            // If a copy already exists in the Applications folder, put it in the Trash
            if fm.fileExists(atPath: destinationPath) {
                // But first, make sure that it's not running
                if isApplicationAtPathRunning(destinationPath) {
                    // Give the running app focus and terminate myself
                    NSLog("INFO -- Switching to an already running version")
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    task.arguments = [destinationPath]
                    try? task.run()
                    task.waitUntilExit()
                    moveInProgress = false
                    exit(0)
                } else {
                    let existingPath = (applicationsDirectory as NSString).appendingPathComponent(bundleName)
                    if !trash(existingPath) {
                        showFailureAlert()
                        return
                    }
                }
            }

            if !copyBundle(srcPath: bundlePath, dstPath: destinationPath) {
                NSLog("ERROR -- Could not copy myself to \(destinationPath)")
                showFailureAlert()
                return
            }
        }

        // Trash the original app. It's okay if this fails.
        // NOTE: This final delete does not work if the source bundle is in a network mounted volume.
        //       Calling rm or file manager's delete method doesn't work either. It's unlikely to happen
        //       but it'd be great if someone could fix this.
        if !isNestedApplication && diskImageDevice == nil && !deleteOrTrash(bundlePath) {
            NSLog("WARNING -- Could not delete application after moving it to Applications folder")
        }

        // Relaunch.
        relaunch(destinationPath: destinationPath)

        // Launched from within a disk image? -- unmount (if no files are open after 5 seconds,
        // otherwise leave it mounted).
        if let device = diskImageDevice, !isNestedApplication {
            let script = "(/bin/sleep 5 && /usr/bin/hdiutil detach \(shellQuotedString(device))) &"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", script]
            try? task.run()
        }

        moveInProgress = false
        exit(0)
    }
    // Save the alert suppress preference if checked
    else if alert.suppressionButton?.state == .on {
        UserDefaults.standard.set(true, forKey: alertSuppressKey)
    }

    moveInProgress = false
}

@_cdecl("PFMoveIsInProgress")
public func PFMoveIsInProgress() -> Bool {
    return moveInProgress
}

// MARK: - Helper Functions

private func preferredInstallLocation(isUserDirectory: inout Bool) -> String {
    // Return the preferred install location.
    // Assume that if the user has a ~/Applications folder, they'd prefer their
    // applications to go there.

    let fm = FileManager.default

    let userAppDirs = NSSearchPathForDirectoriesInDomains(.applicationDirectory, .userDomainMask, true)

    if let userAppDir = userAppDirs.first {
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: userAppDir, isDirectory: &isDir) && isDir.boolValue {
            // User Applications directory exists. Get the directory contents.
            let contents = (try? fm.contentsOfDirectory(atPath: userAppDir)) ?? []

            // Check if there is at least one ".app" inside the directory.
            for item in contents where (item as NSString).pathExtension == "app" {
                isUserDirectory = true
                return (userAppDir as NSString).resolvingSymlinksInPath
            }
        }
    }

    // No user Applications directory in use. Return the machine local Applications directory
    isUserDirectory = false

    return ((NSSearchPathForDirectoriesInDomains(.applicationDirectory, .localDomainMask, true).last ?? "/Applications") as NSString).resolvingSymlinksInPath
}

private func isInApplicationsFolder(_ path: String) -> Bool {
    // Check all the normal Application directories
    let appDirs = NSSearchPathForDirectoriesInDomains(.applicationDirectory, .allDomainsMask, true)
    for appDir in appDirs {
        if path.hasPrefix(appDir) { return true }
    }

    // Also, handle the case that the user has some other Application directory (perhaps on a separate data partition).
    if (path as NSString).pathComponents.contains("Applications") { return true }

    return false
}

private func isInDownloadsFolder(_ path: String) -> Bool {
    let downloadDirs = NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .allDomainsMask, true)
    for downloadDir in downloadDirs {
        if path.hasPrefix(downloadDir) { return true }
    }

    return false
}

private func isApplicationAtPathRunning(_ bundlePath: String) -> Bool {
    let standardizedPath = (bundlePath as NSString).standardizingPath

    for runningApp in NSWorkspace.shared.runningApplications {
        if let path = runningApp.bundleURL?.path {
            if (path as NSString).standardizingPath == standardizedPath {
                return true
            }
        }
    }
    return false
}

private func isApplicationAtPathNested(_ path: String) -> Bool {
    let components = ((path as NSString).deletingLastPathComponent as NSString).pathComponents
    for component in components {
        if (component as NSString).pathExtension == "app" {
            return true
        }
    }

    return false
}

private func containingDiskImageDevice(_ path: String) -> String? {
    let containingPath = (path as NSString).deletingLastPathComponent

    var fs = statfs()
    let nsContainingPath = containingPath as NSString
    if statfs(nsContainingPath.fileSystemRepresentation, &fs) != 0 || (fs.f_flags & UInt32(MNT_ROOTFS)) != 0 {
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

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { return nil }

    guard let images = info["images"] as? [[String: Any]] else { return nil }

    for image in images {
        guard let systemEntities = image["system-entities"] as? [[String: Any]] else { return nil }

        for entity in systemEntities {
            guard let devEntry = entity["dev-entry"] as? String else { return nil }

            if devEntry == device { return device }
        }
    }

    return nil
}

private func trash(_ path: String) -> Bool {
    var result = (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil

    // As a last resort try trashing with AppleScript.
    // This allows us to trash the app in macOS Sierra even when the app is running inside
    // an app translocation image.
    if !result {
        let source = "set theFile to POSIX file \"\(path)\" \n" +
                     "tell application \"Finder\" \n" +
                     "    move theFile to trash \n" +
                     "end tell"
        var errorDict: NSDictionary? = nil
        let appleScript = NSAppleScript(source: source)
        let scriptResult = appleScript?.executeAndReturnError(&errorDict)
        if scriptResult == nil {
            NSLog("Trash AppleScript error: %@", errorDict ?? [:])
        }
        result = scriptResult != nil
    }

    if !result {
        NSLog("ERROR -- Could not trash '\(path)'")
    }

    return result
}

private func deleteOrTrash(_ path: String) -> Bool {
    do {
        try FileManager.default.removeItem(atPath: path)
        return true
    } catch {
        // Don't log warning if on Sierra and running inside App Translocation path
        if !path.contains("/AppTranslocation/") {
            NSLog("WARNING -- Could not delete '\(path)': \(error.localizedDescription)")
        }

        return trash(path)
    }
}

private typealias AuthorizationExecuteWithPrivilegesType = @convention(c) (
    AuthorizationRef,
    UnsafePointer<CChar>,
    AuthorizationFlags,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
) -> OSStatus

private var _securityAuthorizationExecuteWithPrivileges: AuthorizationExecuteWithPrivilegesType? = nil

private func authorizedInstall(srcPath: String, dstPath: String, canceled: inout Bool) -> Bool {
    canceled = false

    // Make sure that the destination path is an app bundle. We're essentially running 'sudo rm -rf'
    // so we really don't want to fuck this up.
    guard (dstPath as NSString).pathExtension == "app" else { return false }

    // Do some more checks
    guard !dstPath.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    guard !srcPath.trimmingCharacters(in: .whitespaces).isEmpty else { return false }

    var authRef: AuthorizationRef?

    // Get the authorization
    let createErr = AuthorizationCreate(nil, nil, [], &authRef)
    guard createErr == errAuthorizationSuccess, let authRef else { return false }

    defer { AuthorizationFree(authRef, []) }

    let myFlags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
    let rightsErr = kAuthorizationRightExecute.withCString { namePtr -> OSStatus in
        var myItem = AuthorizationItem(name: namePtr, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &myItem) { itemPtr -> OSStatus in
            var rights = AuthorizationRights(count: 1, items: itemPtr)
            return AuthorizationCopyRights(authRef, &rights, nil, myFlags, nil)
        }
    }
    guard rightsErr == errAuthorizationSuccess else {
        if rightsErr == errAuthorizationCanceled { canceled = true }
        return false
    }

    if _securityAuthorizationExecuteWithPrivileges == nil {
        // On 10.7, AuthorizationExecuteWithPrivileges is deprecated. We want to still use it since there's no
        // good alternative (without requiring code signing). We'll look up the function through dyld and fail
        // if it is no longer accessible. If Apple removes the function entirely this will fail gracefully. If
        // they keep the function and throw some sort of exception, this won't fail gracefully, but that's a
        // risk we'll have to take for now.
        // RTLD_DEFAULT is ((void *) -2) in C — not exposed as a Swift constant
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        if let sym = dlsym(rtldDefault, "AuthorizationExecuteWithPrivileges") {
            _securityAuthorizationExecuteWithPrivileges = unsafeBitCast(sym, to: AuthorizationExecuteWithPrivilegesType.self)
        }
    }
    guard let executeWithPrivileges = _securityAuthorizationExecuteWithPrivileges else { return false }

    // Delete the destination
    let deleteOK: Bool = dstPath.withCString { dstCStr in
        var args: [UnsafeMutablePointer<CChar>?] = [strdup("-rf"), strdup(dstCStr), nil]
        defer { args.forEach { free($0) } }
        let err = args.withUnsafeMutableBufferPointer {
            executeWithPrivileges(authRef, "/bin/rm", [], $0.baseAddress, nil)
        }
        guard err == errAuthorizationSuccess else { return false }

        // Wait until it's done
        var status: Int32 = 0
        let pid = wait(&status)
        return pid != -1 && wifexited(status) // We don't care about exit status as the destination most likely does not exist
    }
    guard deleteOK else { return false }

    // Copy
    return srcPath.withCString { srcCStr in
        dstPath.withCString { dstCStr in
            var args: [UnsafeMutablePointer<CChar>?] = [strdup("-pR"), strdup(srcCStr), strdup(dstCStr), nil]
            defer { args.forEach { free($0) } }
            let err = args.withUnsafeMutableBufferPointer {
                executeWithPrivileges(authRef, "/bin/cp", [], $0.baseAddress, nil)
            }
            guard err == errAuthorizationSuccess else { return false }

            // Wait until it's done
            var status: Int32 = 0
            let pid = wait(&status)
            return pid != -1 && wifexited(status) && wexitstatus(status) == 0
        }
    }
}

private func copyBundle(srcPath: String, dstPath: String) -> Bool {
    do {
        try FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)
        return true
    } catch {
        NSLog("ERROR -- Could not copy '\(srcPath)' to '\(dstPath)' (\(error))")
        return false
    }
}

private func shellQuotedString(_ string: String) -> String {
    "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func relaunch(destinationPath: String) {
    // The shell script waits until the original app process terminates.
    // This is done so that the relaunched app opens as the front-most app.
    let pid = ProcessInfo.processInfo.processIdentifier

    let quotedDestinationPath = shellQuotedString(destinationPath)

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

private func wifexited(_ status: Int32) -> Bool {
    (status & 0x7F) == 0
}

private func wexitstatus(_ status: Int32) -> Int32 {
    (status >> 8) & 0xFF
}
