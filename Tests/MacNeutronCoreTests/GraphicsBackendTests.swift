import Foundation
import Testing
@testable import MacNeutronCore

@Test func defaultsToDXMT() {
    let choice = GraphicsBackend.select(requested: nil)
    #expect(choice.backend == .dxmt)
    #expect(choice.note == nil)
}

@Test func removedBackendsReadAsDXMTWithANote() {
    for old in ["d3dmetal", "dxvk"] {
        let choice = GraphicsBackend.select(requested: old)
        #expect(choice.backend == .dxmt)
        #expect(choice.note == "'\(old)' was removed in 0.1, using dxmt")
    }
}

@Test func overrideStringsPerBackend() {
    #expect(GraphicsBackend.dxmt.dllOverrides == "dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b")
    #expect(GraphicsBackend.wined3d.dllOverrides == "dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b")
}

@Test func honorsRequestCaseInsensitively() {
    let choice = GraphicsBackend.select(requested: " WINED3D ")
    #expect(choice.backend == .wined3d)
    #expect(choice.note == nil)
}

@Test func unknownRequestFallsBackWithNote() {
    let choice = GraphicsBackend.select(requested: "vulkan")
    #expect(choice.backend == .dxmt)
    #expect(choice.note == "unknown MACNEUTRON_GRAPHICS 'vulkan', using dxmt")
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
