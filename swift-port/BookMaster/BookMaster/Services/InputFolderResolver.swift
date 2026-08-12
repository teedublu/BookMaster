import Foundation

/// Ports file_helpers.py's find_input_folder_from_isbn(): resolves the
/// real input folder for a given ISBN, either because the configured
/// base folder's own name already contains it, or because it's the name
/// of an immediate subfolder. This is what lets one shared "Input
/// Folder" setting act as a base directory that both the "Find input
/// from ISBN" toggle and Batch Create search under, rather than
/// requiring a separate folder path typed in per book.
public enum InputFolderResolver {
    public static func resolve(basePath: URL, isbn: String) -> URL? {
        guard !isbn.isEmpty else { return nil }
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: basePath.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        if basePath.lastPathComponent.contains(isbn) {
            return basePath
        }

        guard let entries = try? fm.contentsOfDirectory(at: basePath, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isSubdirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isSubdirectory, entry.lastPathComponent.contains(isbn) {
                return entry
            }
        }
        return nil
    }
}
