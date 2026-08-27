import Foundation

enum EmulatorBrandingPatch {
    // Google Emulator 37.1.11 (build 15917651), darwin-aarch64.
    // The instruction patch disables the single call to
    // QGuiApplication::setWindowIcon(QIcon const&) in
    // EmulatorQtWindow::slot_setWindowIcon. Leaving the rest of the method
    // intact preserves QIcon cleanup and QSemaphore release.
    //
    // Android Emulator also formats its native title from the AVD name. The
    // replacement removes implementation details from the user-facing window
    // and uses the same product-first naming as the rest of the app.
    static let sourceSHA256 = "eaa97a970b81f81640db73ed79e19ee173323653a0a1203217e1199d078011f3"
    static let iconInstructionOffset: UInt64 = 0x5af688
    static let sourceIconInstruction = Data([0xf4, 0xbf, 0x4d, 0x94])
    static let patchedIconInstruction = Data([0x1f, 0x20, 0x03, 0xd5])
    static let titleFormatOffset: UInt64 = 0x1a1e891
    static let sourceTitleFormat = fixedWidthData("%s Emulator - %s:%d", byteCount: 20)
    static let patchedTitleFormat = fixedWidthData("Mactician: TFT", byteCount: 20)

    static func isSupportedOrPatched(_ qemu: URL) -> Bool {
        guard let iconInstruction = try? data(
            at: iconInstructionOffset,
            count: patchedIconInstruction.count,
            in: qemu
        ), let titleFormat = try? data(
            at: titleFormatOffset,
            count: sourceTitleFormat.count,
            in: qemu
        ) else {
            return false
        }

        if iconInstruction == sourceIconInstruction && titleFormat == sourceTitleFormat {
            return (try? SystemServices.sha256(of: qemu)) == sourceSHA256
        }
        guard iconInstruction == patchedIconInstruction,
              titleFormat == sourceTitleFormat || titleFormat == patchedTitleFormat else {
            return false
        }
        return (try? verifySignedExecutable(qemu)) != nil
    }

    static func apply(at qemu: URL, entitlements: URL) throws {
        let iconInstruction = try data(
            at: iconInstructionOffset,
            count: patchedIconInstruction.count,
            in: qemu
        )
        let titleFormat = try data(
            at: titleFormatOffset,
            count: sourceTitleFormat.count,
            in: qemu
        )
        if iconInstruction == patchedIconInstruction && titleFormat == patchedTitleFormat {
            try verifyPatchedExecutable(qemu)
            return
        }

        if iconInstruction == sourceIconInstruction {
            guard titleFormat == sourceTitleFormat,
                  try SystemServices.sha256(of: qemu) == sourceSHA256 else {
                throw LauncherError.integrity(
                    "The Android Emulator binary failed verification. Use Repair Installation."
                )
            }
        } else if iconInstruction == patchedIconInstruction {
            guard titleFormat == sourceTitleFormat else {
                throw LauncherError.integrity(
                    "The Android Emulator branding patch is invalid. Use Repair Installation."
                )
            }
            try verifySignedExecutable(qemu)
        } else {
            throw LauncherError.integrity(
                "The Android Emulator binary is not the supported 37.1.11 build. Use Repair Installation."
            )
        }
        guard FileManager.default.fileExists(atPath: entitlements.path) else {
            throw LauncherError.integrity("The launcher hypervisor entitlement resource is missing")
        }

        let fileManager = FileManager.default
        let parent = qemu.deletingLastPathComponent()
        let nonce = UUID().uuidString
        let candidate = parent.appendingPathComponent(".qemu-system-aarch64.\(nonce).next")
        let previous = parent.appendingPathComponent(".qemu-system-aarch64.\(nonce).previous")
        defer {
            try? fileManager.removeItem(at: candidate)
            try? fileManager.removeItem(at: previous)
        }

        try fileManager.copyItem(at: qemu, to: candidate)
        let handle = try FileHandle(forWritingTo: candidate)
        do {
            if iconInstruction == sourceIconInstruction {
                try handle.seek(toOffset: iconInstructionOffset)
                try handle.write(contentsOf: patchedIconInstruction)
            }
            try handle.seek(toOffset: titleFormatOffset)
            try handle.write(contentsOf: patchedTitleFormat)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard try data(
            at: iconInstructionOffset,
            count: patchedIconInstruction.count,
            in: candidate
        ) == patchedIconInstruction,
              try data(
                at: titleFormatOffset,
                count: patchedTitleFormat.count,
                in: candidate
              ) == patchedTitleFormat else {
            throw LauncherError.integrity("Could not apply the Android Emulator branding patch")
        }

        try SystemServices.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            [
                "--force", "--sign", "-", "--timestamp=none",
                "--preserve-metadata=identifier",
                "--entitlements", entitlements.path,
                candidate.path
            ]
        )
        try verifyPatchedExecutable(candidate)

        try fileManager.moveItem(at: qemu, to: previous)
        do {
            try fileManager.moveItem(at: candidate, to: qemu)
        } catch {
            try? fileManager.moveItem(at: previous, to: qemu)
            throw error
        }
        try fileManager.removeItem(at: previous)
        try verifyPatchedExecutable(qemu)
    }

    private static func fixedWidthData(_ string: String, byteCount: Int) -> Data {
        var result = Data(string.utf8)
        precondition(result.count < byteCount)
        result.append(contentsOf: repeatElement(0, count: byteCount - result.count))
        return result
    }

    private static func data(at offset: UInt64, count: Int, in executable: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let result = try handle.read(upToCount: count) ?? Data()
        guard result.count == count else {
            throw LauncherError.integrity("The Android Emulator executable is truncated")
        }
        return result
    }

    private static func verifyPatchedExecutable(_ executable: URL) throws {
        guard try data(
            at: iconInstructionOffset,
            count: patchedIconInstruction.count,
            in: executable
        ) == patchedIconInstruction,
              try data(
                at: titleFormatOffset,
                count: patchedTitleFormat.count,
                in: executable
              ) == patchedTitleFormat else {
            throw LauncherError.integrity("The Android Emulator branding patch is missing")
        }
        try verifySignedExecutable(executable)
    }

    private static func verifySignedExecutable(_ executable: URL) throws {
        try SystemServices.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            ["--verify", "--strict", executable.path]
        )
        let entitlementOutput = try SystemServices.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            ["-d", "--entitlements", "-", executable.path]
        )
        guard entitlementOutput.contains("com.apple.security.hypervisor") else {
            throw LauncherError.integrity("The patched emulator lost its Hypervisor entitlement")
        }
    }
}
