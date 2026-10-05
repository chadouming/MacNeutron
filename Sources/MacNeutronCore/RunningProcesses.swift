import Darwin

/// The processes running on this Mac, by executable.
public enum RunningProcesses {
    /// The kernel's executable path of every process this user can see (`/private/var/…`, not argv, which Wine
    /// rewrites). Processes of other users and ones that exit mid-scan are skipped.
    public static func executablePaths() -> [String] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)   // room for processes started since
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE doesn't import
        return pids.prefix(Int(count)).compactMap { pid in
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
        }
    }
}
