import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    static var copyToClipboard: Bool {
        get { defaults.object(forKey: "copyToClipboard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "copyToClipboard") }
    }

    static var saveToDisk: Bool {
        get { defaults.object(forKey: "saveToDisk") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "saveToDisk") }
    }

    static var saveDirectory: URL {
        if let path = defaults.string(forKey: "saveDirectory") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("screencap", isDirectory: true)
    }

    /// Screenshots always land on disk, in the temp dir when saving is off, so the
    /// quick-access thumbnail can still be dragged out as a real file.
    static var outputDirectory: URL {
        saveToDisk ? saveDirectory : FileManager.default.temporaryDirectory.appendingPathComponent("screencap", isDirectory: true)
    }

    static func timestampedName(prefix: String, ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return "\(prefix) \(f.string(from: Date()))-\(UUID().uuidString.prefix(8)).\(ext)"
    }
}
