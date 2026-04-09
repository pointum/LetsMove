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

    private struct WaitResult {
        fileprivate let pid: pid_t
        fileprivate let status: Int32

        // WIFEXITED: process called exit() rather than being killed by a signal
        private var didExit: Bool { pid != -1 && (status & 0x7F) == 0 }

        // WEXITSTATUS: the exit code passed to exit() or returned from main()
        private var exitCode: Int32 { (status >> 8) & 0xFF }

        var succeeded: Bool { didExit && exitCode == 0 }
    }

    @discardableResult
    private func waitForChild() -> WaitResult {
        var pid: pid_t
        var status: Int32 = 0
        repeat { pid = wait(&status) } while pid == -1 && errno == EINTR
        return WaitResult(pid: pid, status: status)
    }

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
            let RTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)
            if let sym = dlsym(RTLD_DEFAULT, "AuthorizationExecuteWithPrivileges") {
                authorizationExecuteWithPrivileges = unsafeBitCast(sym, to: AuthorizationExecuteWithPrivilegesType.self)
            }
        }
        guard let authorizationExecuteWithPrivileges else { return .failed }

        func run(_ executable: String, _ stringArgs: [String]) -> Bool {
            var args: [UnsafeMutablePointer<CChar>?] = stringArgs.map { strdup($0) } + [nil]
            defer { args.forEach { free($0) } }
            let err = args.withUnsafeMutableBufferPointer {
                authorizationExecuteWithPrivileges(authRef, executable, [], $0.baseAddress, nil)
            }
            return err == errAuthorizationSuccess
        }

        // Delete the destination
        guard run("/bin/rm", ["-rf", dstURL.path]) else { return .failed }
        waitForChild()

        // Copy
        guard run("/bin/cp", ["-pR", srcURL.path, dstURL.path]) else { return .failed }
        return waitForChild().succeeded ? .success : .failed
    }
}
