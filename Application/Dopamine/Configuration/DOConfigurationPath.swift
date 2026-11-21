import Darwin
import Foundation

/// Canonical path helpers. The Irisin engine resolves the bootstrap's var anchor through
/// `PackageFilesystem.physicalPath`; here the same rule is expressed with `realpath`.
enum DOConfigurationPath {
    static func canonical(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// Resolves the link at the end of the path, leaving earlier components untouched.
    static func physical(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        guard let resolvedParent = canonical(parent.isEmpty ? "/" : parent) else { return nil }
        var current = resolvedParent + "/" + name
        for _ in 0 ..< 32 {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let count = readlink(current, &buffer, Int(PATH_MAX) - 1)
            if count < 0 { return current }
            let target = String(cString: buffer)
            current = target.hasPrefix("/") ? target : resolvedParent + "/" + target
        }
        return nil
    }
}
