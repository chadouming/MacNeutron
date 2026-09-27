import Foundation
import Testing
@testable import MacProtonCore

@Test func defaultsToD3DMetalWhenGPTKIsImported() {
    let choice = GraphicsBackend.select(requested: nil, gptkImported: true)
    #expect(choice.backend == .d3dmetal)
    #expect(choice.note == nil)
}

@Test func defaultsToDXMTWithoutGPTK() {
    #expect(GraphicsBackend.select(requested: nil, gptkImported: false).backend == .dxmt)
}

@Test func honorsRequestCaseInsensitively() {
    #expect(GraphicsBackend.select(requested: " DXVK ", gptkImported: true).backend == .dxvk)
}

@Test func unknownRequestFallsBackWithNote() {
    let choice = GraphicsBackend.select(requested: "vulkan", gptkImported: false)
    #expect(choice.backend == .dxmt)
    #expect(choice.note == "unknown MACPROTON_GRAPHICS 'vulkan', using dxmt")
}

@Test func d3dmetalWithoutGPTKFallsBackToDXMT() {
    let choice = GraphicsBackend.select(requested: "d3dmetal", gptkImported: false)
    #expect(choice.backend == .dxmt)
    #expect(choice.note != nil)
}

@Test func everyBackendOverridesTheSameDLLSet() {
    let managed: Set = ["dxgi", "d3d9", "d3d10", "d3d10core", "d3d11", "d3d12"]
    for backend in GraphicsBackend.allCases {
        let names = backend.dllOverrides.split(separator: ";").flatMap {
            $0.split(separator: "=")[0].split(separator: ",").map(String.init)
        }
        #expect(Set(names) == managed, "\(backend)")
        #expect(names.count == managed.count, "\(backend) repeats a DLL")
    }
}

@Test func dxvkUsesWinesDXGIAndOnlyTheDLLsTheRuntimeShips() {
    // A native dxgi left behind by DXMT must never be paired with DXVK's d3d11.
    #expect(GraphicsBackend.dxvk.dllOverrides == "d3d10core,d3d11=n,b;dxgi,d3d9,d3d10,d3d12=b")
    let layout = ToolLayout(root: URL(filePath: "/t", directoryHint: .isDirectory))
    let names = Set(GraphicsBackend.dxvk.prefixDLLs(layout: layout).map(\.source.lastPathComponent))
    #expect(names == ["d3d10core.dll", "d3d11.dll"])
}

@Test func dxmtDeploysBothArchitectures() {
    let layout = ToolLayout(root: URL(filePath: "/t", directoryHint: .isDirectory))
    let dlls = GraphicsBackend.dxmt.prefixDLLs(layout: layout)
    #expect(dlls.count == 6)
    #expect(dlls.contains { $0.source.path(percentEncoded: false) == "/t/Libraries/DXMT/x64/d3d11.dll"
        && $0.destination == "drive_c/windows/system32/d3d11.dll" })
    #expect(dlls.contains { $0.source.path(percentEncoded: false) == "/t/Libraries/DXMT/x32/dxgi.dll"
        && $0.destination == "drive_c/windows/syswow64/dxgi.dll" })
    #expect(GraphicsBackend.d3dmetal.prefixDLLs(layout: layout).isEmpty)
}
