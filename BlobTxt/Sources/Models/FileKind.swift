import Foundation

// File-type classification used to decide how a file opens: blobs in the editor, images in the native viewer, anything else handed to the OS.
extension URL {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp", "tiff",
    ]

    var isBlobFile: Bool { pathExtension.lowercased() == "md" }

    var isImageFile: Bool { URL.imageExtensions.contains(pathExtension.lowercased()) }
}
