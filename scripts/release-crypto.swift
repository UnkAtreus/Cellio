import CryptoKit
import Foundation
import Darwin

// Production tooling only: no Keychain, no key material on stdout.
func writeNew(_ data: Data, to url: URL, mode: mode_t) throws {
    let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try handle.write(contentsOf: data)
    try handle.close()
}

do {
    let args = CommandLine.arguments
    if args.count == 5, args[1] == "qa-key" {
        let privateURL = URL(fileURLWithPath: args[2]).standardizedFileURL.resolvingSymlinksInPath()
        let publicURL = URL(fileURLWithPath: args[3]).standardizedFileURL.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: args[4]).standardizedFileURL.resolvingSymlinksInPath().path
        guard privateURL != publicURL,
              ![privateURL, publicURL].contains(where: { $0.path == root || $0.path.hasPrefix(root + "/") || $0.pathComponents.contains(where: { $0.hasSuffix(".app") }) }),
              !FileManager.default.fileExists(atPath: privateURL.path), !FileManager.default.fileExists(atPath: publicURL.path) else {
            throw NSError(domain: "CellioRelease", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use new explicit key files outside the workspace and applications."])
        }
        let key = Curve25519.Signing.PrivateKey()
        try writeNew(Data((key.rawRepresentation.base64EncodedString() + "\n").utf8), to: privateURL, mode: 0o600)
        try writeNew(Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8), to: publicURL, mode: 0o644)
        print("Created ephemeral QA seed (0600) and public key files. Delete the seed after the campaign.")
    } else if args.count == 5, args[1] == "verify",
              let publicData = Data(base64Encoded: args[2]), let signature = Data(base64Encoded: args[3]) {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
        guard key.isValidSignature(signature, for: try Data(contentsOf: URL(fileURLWithPath: args[4]))) else {
            throw NSError(domain: "CellioRelease", code: 3, userInfo: [NSLocalizedDescriptionKey: "Archive signature does not match the application's update public key."])
        }
    } else {
        throw NSError(domain: "CellioRelease", code: 4, userInfo: [NSLocalizedDescriptionKey: "Usage: qa-key PRIVATE PUBLIC WORKSPACE or verify PUBLIC_BASE64 SIGNATURE_BASE64 ARCHIVE"])
    }
} catch {
    fputs("Release cryptography failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
