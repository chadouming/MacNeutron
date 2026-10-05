import Foundation
import Testing
@testable import MacNeutronCore

/// A minimal PE: 64-byte DOS header with `e_lfanew` 0x80, padding, `PE\0\0`, then the COFF machine.
private func peBytes(machine: UInt16) -> Data {
    var bytes = [UInt8](repeating: 0, count: 0x86)
    bytes[0] = 0x4D; bytes[1] = 0x5A
    bytes[0x3C] = 0x80
    bytes[0x80] = 0x50; bytes[0x81] = 0x45
    bytes[0x84] = UInt8(machine & 0xFF); bytes[0x85] = UInt8(machine >> 8)
    return Data(bytes)
}

@Test func amd64AndArm64AndI386MachinesAreRead() throws {
    let dir = try makeTempDir()
    for machine in [PEImage.amd64, PEImage.arm64, PEImage.i386, 0x01c4] {
        let exe = dir.appending(path: "\(machine).exe")
        try peBytes(machine: machine).write(to: exe)
        #expect(PEImage.machine(of: exe) == machine)
    }
}

@Test func aScriptIsNotPE() throws {
    let script = try makeTempDir().appending(path: "run.sh")
    try write("#!/bin/sh\necho MZ PE\n" + String(repeating: "x", count: 200), to: script, executable: true)
    #expect(PEImage.machine(of: script) == nil)
}

@Test func aTruncatedMZIsNotPE() throws {
    let dir = try makeTempDir()
    let short = dir.appending(path: "short.exe")
    try Data([0x4D, 0x5A, 0, 0]).write(to: short)
    #expect(PEImage.machine(of: short) == nil)
    let noNT = dir.appending(path: "nont.exe")
    try peBytes(machine: PEImage.amd64).prefix(0x83).write(to: noNT)
    #expect(PEImage.machine(of: noNT) == nil)
}

@Test func aMissingFileIsNotPE() throws {
    #expect(PEImage.machine(of: try makeTempDir().appending(path: "missing.exe")) == nil)
}

@Test func machineReadsAPathWithSpaces() throws {
    let exe = try makeTempDir().appending(path: "game é/Game.exe")
    try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
    try peBytes(machine: PEImage.arm64).write(to: exe)
    #expect(PEImage.machine(of: exe) == PEImage.arm64)
}

@Test func machineReadsOnlyTheHeaderOfAHugeFile() throws {
    let exe = try makeTempDir().appending(path: "Huge.exe")
    try peBytes(machine: PEImage.amd64).write(to: exe)
    let handle = try FileHandle(forWritingTo: exe)
    try handle.truncate(atOffset: 4 << 30)   // sparse, 4 GiB
    try handle.close()
    let start = ContinuousClock.now
    #expect(PEImage.machine(of: exe) == PEImage.amd64)
    #expect(ContinuousClock.now - start < .seconds(1))
}
