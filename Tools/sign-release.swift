// Signs a release zip with the ed25519 key in ~/.config/vestitel/release-key
// and writes <zip>.sig next to it. Upload BOTH as release assets: the app's
// updater refuses any release without a valid signature.
//
//   swift Tools/sign-release.swift Vestitel-X.Y.Z.zip

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    print("usage: swift Tools/sign-release.swift <zip>")
    exit(1)
}
let zipPath = CommandLine.arguments[1]
let keyPath = ("~/.config/vestitel/release-key" as NSString).expandingTildeInPath
guard let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let keyRaw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyRaw) else {
    print("no release key at \(keyPath)")
    exit(1)
}
guard let zipData = FileManager.default.contents(atPath: zipPath) else {
    print("cannot read \(zipPath)")
    exit(1)
}
let signature = try key.signature(for: zipData)
try signature.base64EncodedString().write(toFile: zipPath + ".sig", atomically: true, encoding: .utf8)
print("signed: \(zipPath).sig")
