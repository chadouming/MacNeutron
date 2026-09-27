import Foundation

/// How Direct3D reaches Metal for one launch.
public enum GraphicsBackend: String, Sendable, CaseIterable {
    case d3dmetal, dxmt, dxvk

    /// Honors `MACPROTON_GRAPHICS` when valid; otherwise D3DMetal if GPTK is imported, else DXMT.
    /// `note` explains any fallback so the launcher can log it.
    public static func select(requested: String?, gptkImported: Bool) -> (backend: GraphicsBackend, note: String?) {
        let fallback: GraphicsBackend = gptkImported ? .d3dmetal : .dxmt
        guard let raw = requested?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return (fallback, nil)
        }
        guard let backend = GraphicsBackend(rawValue: raw) else {
            return (fallback, "unknown MACPROTON_GRAPHICS '\(raw)', using \(fallback.rawValue)")
        }
        if backend == .d3dmetal && !gptkImported {
            return (.dxmt, "d3dmetal requested but GPTK is not imported, using dxmt")
        }
        return (backend, nil)
    }

    /// `WINEDLLOVERRIDES` for this backend. Every backend names every D3D DLL any backend
    /// manages, so DLLs a previous backend left in the prefix can never leak into this launch.
    public var dllOverrides: String {
        switch self {
        case .d3dmetal: "dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b"
        case .dxmt: "dxgi,d3d10core,d3d11=n,b;d3d9,d3d10,d3d12=b"
        // The pinned DXVK-macOS ships d3d10core/d3d11 only and runs on Wine's own dxgi.
        case .dxvk: "d3d10core,d3d11=n,b;dxgi,d3d9,d3d10,d3d12=b"
        }
    }

    /// Native DLLs copied into the prefix: runtime file → path inside the prefix.
    /// D3DMetal needs none: GPTK is overlaid onto Wine's own builtins.
    public func prefixDLLs(layout: ToolLayout) -> [(source: URL, destination: String)] {
        let (dir, names): (URL, [String]) = switch self {
        case .d3dmetal: (layout.libraries, [])
        case .dxmt: (layout.dxmt, ["d3d11.dll", "d3d10core.dll", "dxgi.dll"])
        case .dxvk: (layout.dxvk, ["d3d10core.dll", "d3d11.dll"])
        }
        return names.flatMap { name in
            [
                (dir.appending(path: "x64/\(name)"), "drive_c/windows/system32/\(name)"),
                (dir.appending(path: "x32/\(name)"), "drive_c/windows/syswow64/\(name)"),
            ]
        }
    }
}
