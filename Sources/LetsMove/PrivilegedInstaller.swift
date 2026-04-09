import Darwin
import Foundation
import Security

final class PrivilegedInstaller {

    enum Result { case success, canceled, failed }

    private typealias AuthorizationExecuteWithPrivilegesType = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private var authorizationExecuteWithPrivileges: AuthorizationExecuteWithPrivilegesType? = nil

    func install(from srcURL: URL, to dstURL: URL) -> Result {
        // Make sure that the destination path is an app bundle. We're essentially running 'sudo rm -rf'
        // so we really don't want to fuck this up.
        guard dstURL.pathExtension == "app" else { return .failed }
        guard !dstURL.path.isEmpty, !srcURL.path.isEmpty else { return .failed }

        var authRef: AuthorizationRef?

        // Get the authorization
        let createErr = AuthorizationCreate(nil, nil, [], &authRef)
        guard createErr == errAuthorizationSuccess, let authRef else { return .failed }

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
            return rightsErr == errAuthorizationCanceled ? .canceled : .failed
        }

        if authorizationExecuteWithPrivileges == nil {
            // On 10.7, AuthorizationExecuteWithPrivileges is deprecated. We want to still use it since there's no
            // good alternative (without requiring code signing). We'll look up the function through dyld and fail
            // if it is no longer accessible. If Apple removes the function entirely this will fail gracefully. If
            // they keep the function and throw some sort of exception, this won't fail gracefully, but that's a
            // risk we'll have to take for now.
            // RTLD_DEFAULT is ((void *) -2) in C — not exposed as a Swift constant
            let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
            if let sym = dlsym(rtldDefault, "AuthorizationExecuteWithPrivileges") {
                authorizationExecuteWithPrivileges = unsafeBitCast(sym, to: AuthorizationExecuteWithPrivilegesType.self)
            }
        }
        guard let executeWithPrivileges = authorizationExecuteWithPrivileges else { return .failed }

        // Delete the destination
        let deleteOK: Bool = dstURL.path.withCString { dstCStr in
            var args: [UnsafeMutablePointer<CChar>?] = [strdup("-rf"), strdup(dstCStr), nil]
            defer { args.forEach { free($0) } }
            let err = args.withUnsafeMutableBufferPointer {
                executeWithPrivileges(authRef, "/bin/rm", [], $0.baseAddress, nil)
            }
            guard err == errAuthorizationSuccess else { return false }

            // Wait until it's done
            var status: Int32 = 0
            let pid = wait(&status)
            return pid != -1 && (status & 0x7F) == 0 // We don't care about exit status as the destination most likely does not exist
        }
        guard deleteOK else { return .failed }

        // Copy
        let copyOK: Bool = srcURL.path.withCString { srcCStr in
            dstURL.path.withCString { dstCStr in
                var args: [UnsafeMutablePointer<CChar>?] = [strdup("-pR"), strdup(srcCStr), strdup(dstCStr), nil]
                defer { args.forEach { free($0) } }
                let err = args.withUnsafeMutableBufferPointer {
                    executeWithPrivileges(authRef, "/bin/cp", [], $0.baseAddress, nil)
                }
                guard err == errAuthorizationSuccess else { return false }

                // Wait until it's done
                var status: Int32 = 0
                let pid = wait(&status)
                return pid != -1 && (status & 0x7F) == 0 && (status >> 8) & 0xFF == 0
            }
        }
        return copyOK ? .success : .failed
    }
}
