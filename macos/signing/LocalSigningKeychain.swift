import Foundation
import Security

func require(_ code: OSStatus, _ operation: String) throws {
    if code != errSecSuccess { throw NSError(domain: operation, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(code)"])}
}
func run() throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else { throw NSError(domain: "Usage: helper initialize|sign IDENTITY_DIRECTORY [APP_PATH]", code: 1) }
    let operation = args[1]
    let directory = URL(fileURLWithPath: args[2], isDirectory: true)
    let path = directory.appendingPathComponent("LocalDictationSigning.keychain-db").path
    let password = try Data(contentsOf: directory.appendingPathComponent("keychain-password"))
    var keychain: SecKeychain?
    if operation == "initialize" {
        guard !FileManager.default.fileExists(atPath: path) else { throw NSError(domain: "Keychain already exists; refusing to replace identity", code: 2) }
        try password.withUnsafeBytes { bytes in
            try require(SecKeychainCreate(path, UInt32(password.count), bytes.baseAddress, false, nil, &keychain), "SecKeychainCreate")
        }
    } else {
        try require(SecKeychainOpen(path, &keychain), "SecKeychainOpen")
        try password.withUnsafeBytes { bytes in
            try require(SecKeychainUnlock(keychain, UInt32(password.count), bytes.baseAddress, true), "SecKeychainUnlock")
        }
    }
    guard let keychain else { throw NSError(domain: "No private keychain", code: 3) }
    defer { SecKeychainLock(keychain) }
    if operation == "initialize" {
        var app: SecTrustedApplication?
        try require(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &app), "SecTrustedApplicationCreateFromPath")
        var access: SecAccess?
        try require(SecAccessCreate("LocalDictation local signing key" as CFString, [app!] as CFArray, &access), "SecAccessCreate")
        let payload = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
        guard let passphrase = String(data: password, encoding: .utf8) else { throw NSError(domain: "Password encoding", code: 4) }
        let options: [String: Any] = [kSecImportExportPassphrase as String: passphrase,
            kSecImportExportKeychain as String: keychain, kSecImportExportAccess as String: access!]
        var items: CFArray?
        try require(SecPKCS12Import(payload as CFData, options as CFDictionary, &items), "SecPKCS12Import")
        guard let rows = items as? [[String: Any]], rows.count == 1, rows[0][kSecImportItemIdentity as String] != nil else {
            throw NSError(domain: "Expected exactly one imported identity", code: 5)
        }
        print("Imported one local signing identity into its explicit private keychain.")
    } else if operation == "sign" {
        guard args.count == 4 else { throw NSError(domain: "Missing app path", code: 6) }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("identity.json"))) as! [String: Any]
        let fingerprint = manifest["certificate_sha1"] as! String
        let requirement = manifest["requirement"] as! String
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", fingerprint, "--keychain", path, "--requirements", "=designated => " + requirement, "--timestamp=none", args[3]]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "codesign", code: Int(process.terminationStatus)) }
    } else { throw NSError(domain: "Unknown helper mode", code: 7) }
}
do { try run() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
