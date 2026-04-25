import AppKit

extension URL {
    var resourceExists: Bool {
        (try? checkResourceIsReachable()) == true
    }

    var isWritable: Bool {
        (try? resourceValues(forKeys: [.isWritableKey]))?.isWritable == true
    }

    private var fileResourceIdentifier: (any NSCopying & NSSecureCoding & NSObjectProtocol)? {
        try? resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }

    @available(macOS 13.3, *)
    private var fileIdentifier: UInt64? {
        try? resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier
    }

    func contains(_ other: URL) -> Bool {
        var relationship: FileManager.URLRelationship = .other
        try? FileManager.default.getRelationship(&relationship, ofDirectoryAt: self, toItemAt: other)
        return relationship == .contains
    }

    func isContained(in directory: FileManager.SearchPathDirectory) -> Bool {
        FileManager.default.urls(for: directory, in: .allDomainsMask).contains { $0.contains(self) }
    }

    var isInApplicationsFolder: Bool {
        // Also, handle the case that the user has some other Application directory (perhaps on a separate data partition).
        isContained(in: .applicationDirectory) || pathComponents.contains("Applications")
    }

    var isApplicationRunning: Bool {
        if #available(macOS 13.3, *) {
            guard let id = fileIdentifier else { return false }
            return NSWorkspace.shared.runningApplications.contains {
                $0.bundleURL?.fileIdentifier == id
            }
        } else {
            guard let id = fileResourceIdentifier else { return false }
            return NSWorkspace.shared.runningApplications.contains {
                $0.bundleURL?.fileResourceIdentifier.map(id.isEqual) == true
            }
        }
    }

    var hasParentApp: Bool {
        deletingLastPathComponent().pathComponents.contains { $0.hasSuffix(".app") }
    }

    var removableDevicePath: String? {
        var fs = statfs()
        let containingFSPath = (deletingLastPathComponent() as NSURL).fileSystemRepresentation
        if statfs(containingFSPath, &fs) != 0 || (fs.f_flags & UInt32(MNT_ROOTFS)) != 0 {
            return nil
        }

        let device = withUnsafeBytes(of: fs.f_mntfromname) {
            let ptr = $0.baseAddress!.assumingMemoryBound(to: CChar.self)
            return FileManager.default.string(withFileSystemRepresentation: ptr, length: strlen(ptr))
        }

        let hdiutil = Process()
        hdiutil.executableURL = URL(filePath: "/usr/bin/hdiutil")
        hdiutil.arguments = ["info", "-plist"]
        let pipe = Pipe()
        hdiutil.standardOutput = pipe
        do { try hdiutil.run() } catch { return nil }
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
            $0.systemEntities?.contains { $0.devEntry == device } ?? false
        }
        return isDiskImage ? device : nil
    }
}
