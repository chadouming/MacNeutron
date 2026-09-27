import Foundation
@testable import MacNeutronCore

/// Writes a minimal appinfo.vdf v29 the way Steam lays it out, for tests.
func makeAppInfoV29(_ apps: [AppInfo], magic: UInt32 = AppInfoReader.magicV29) -> Data {
    var strings: [String] = []
    func index(_ key: String) -> UInt32 {
        if let found = strings.firstIndex(of: key) { return UInt32(found) }
        strings.append(key)
        return UInt32(strings.count - 1)
    }
    func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }

    var body: [UInt8] = []
    for app in apps {
        var kv: [UInt8] = []
        func section(_ key: String) { kv += [0x00] + le(index(key)) }
        func string(_ key: String, _ value: String) { kv += [0x01] + le(index(key)) + Array(value.utf8) + [0] }
        section("appinfo")
        kv += [0x02] + le(index("appid")) + le(app.appID)
        section("common")
        string("name", app.name)
        string("type", app.type.capitalized)
        string("oslist", app.oslist.sorted().joined(separator: ","))
        kv += [0x07] + le(index("gameid")) + le(UInt64(app.appID))
        kv += [0x08, 0x08, 0x08]  // end common, end appinfo, end of tree
        let header = le(UInt32(0)) + le(UInt32(0)) + le(UInt64(0)) + [UInt8](repeating: 0, count: 20)
            + le(UInt32(0)) + [UInt8](repeating: 0, count: 20)
        body += le(app.appID) + le(UInt32(header.count + kv.count)) + header + kv
    }
    body += le(UInt32(0))
    let tableOffset = 4 + 4 + 8 + body.count
    var table = le(UInt32(strings.count))
    for string in strings { table += Array(string.utf8) + [0] }
    return Data(le(magic) + le(UInt32(1)) + le(UInt64(tableOffset)) + body + table)
}
