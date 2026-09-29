import Foundation
import Testing
@testable import MacNeutronCore

@Test func defaultsToDXMTEvenWithGPTK() {
    let choice = GraphicsBackend.select(requested: nil, gptkImported: true)
    #expect(choice.backend == .dxmt)
    #expect(choice.note == nil)
}

@Test func unknownRequestWithGPTKFallsBackToDXMT() {
    let choice = GraphicsBackend.select(requested: "vulkan", gptkImported: true)
    #expect(choice.backend == .dxmt)
    #expect(choice.note == "unknown MACNEUTRON_GRAPHICS 'vulkan', using dxmt")
}

@Test func d3dmetalStaysSelectableWithGPTK() {
    let choice = GraphicsBackend.select(requested: "d3dmetal", gptkImported: true)
    #expect(choice.backend == .d3dmetal)
    #expect(choice.note == nil)
}

/// A tool folder whose DXMT has, or lacks, our d3d12.dll.
private func dxmtLayout(d3d12: Bool) throws -> ToolLayout {
    let layout = ToolLayout(root: try makeTempDir())
    if d3d12 { try write("ours", to: layout.dxmtD3D12) }
    return layout
}

@Test func dxmtTakesD3D12OnlyWithOurD3D12() throws {
    // Without ours, a d3d12.dll an earlier DXMT left in the prefix must never load.
    #expect(GraphicsBackend.dxmt.dllOverrides(layout: try dxmtLayout(d3d12: false)) == "dxgi,d3d10core,d3d11=n,b;d3d9,d3d10,d3d12=b")
    #expect(GraphicsBackend.dxmt.dllOverrides(layout: try dxmtLayout(d3d12: true)) == "dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b")
    #expect(GraphicsBackend.d3dmetal.dllOverrides(layout: try dxmtLayout(d3d12: true)) == "dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b")
}

@Test func dxmtDeploysOurD3D12To64BitOnly() throws {
    let layout = try dxmtLayout(d3d12: true)
    let dlls = GraphicsBackend.dxmt.prefixDLLs(layout: layout)
    #expect(dlls.count == 7)
    #expect(dlls.contains { $0.source == layout.dxmtD3D12 && $0.destination == "drive_c/windows/system32/d3d12.dll" })
    #expect(!dlls.contains { $0.destination == "drive_c/windows/syswow64/d3d12.dll" })
    #expect(!GraphicsBackend.dxvk.prefixDLLs(layout: layout).contains { $0.source.lastPathComponent == "d3d12.dll" })
}

@Test func defaultsToDXMTWithoutGPTK() {
    #expect(GraphicsBackend.select(requested: nil, gptkImported: false).backend == .dxmt)
}

@Test func honorsRequestCaseInsensitively() {
    #expect(GraphicsBackend.select(requested: " DXVK ", gptkImported: false).backend == .dxvk)
}

@Test func unknownRequestFallsBackWithNote() {
    let choice = GraphicsBackend.select(requested: "vulkan", gptkImported: false)
    #expect(choice.backend == .dxmt)
    #expect(choice.note == "unknown MACNEUTRON_GRAPHICS 'vulkan', using dxmt")
}

@Test func d3dmetalWithoutGPTKFallsBackToDXMT() {
    let choice = GraphicsBackend.select(requested: "d3dmetal", gptkImported: false)
    #expect(choice.backend == .dxmt)
    #expect(choice.note != nil)
}

@Test func everyBackendOverridesTheSameDLLSet() throws {
    let managed: Set = ["dxgi", "d3d9", "d3d10", "d3d10core", "d3d11", "d3d12"]
    for layout in [try dxmtLayout(d3d12: false), try dxmtLayout(d3d12: true)] {
        for backend in GraphicsBackend.allCases {
            let names = backend.dllOverrides(layout: layout).split(separator: ";").flatMap {
                $0.split(separator: "=")[0].split(separator: ",").map(String.init)
            }
            #expect(Set(names) == managed, "\(backend)")
            #expect(names.count == managed.count, "\(backend) repeats a DLL")
        }
    }
}

@Test func dxvkUsesWinesDXGIAndOnlyTheDLLsTheRuntimeShips() {
    // A native dxgi left behind by DXMT must never be paired with DXVK's d3d11.
    let layout = ToolLayout(root: URL(filePath: "/t", directoryHint: .isDirectory))
    #expect(GraphicsBackend.dxvk.dllOverrides(layout: layout) == "d3d10core,d3d11=n,b;dxgi,d3d9,d3d10,d3d12=b")
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

@Test func dxvkFallsBackToD3DMetalWhenGPTKIsImported() {
    // The GPTK overlay replaces the Wine dxgi this DXVK build runs on; the pair crashes.
    let choice = GraphicsBackend.select(requested: "dxvk", gptkImported: true)
    #expect(choice.backend == .d3dmetal)
    #expect(choice.note == "dxvk does not work while GPTK is imported, using d3dmetal")
    #expect(GraphicsBackend.select(requested: "dxvk", gptkImported: false).backend == .dxvk)
}
