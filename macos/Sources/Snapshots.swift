import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The last picture seen on each channel (small JPEGs in Application Support/SDR TV/snapshots), shown
/// dimmed while that channel is tuned again until live video arrives.
final class Snapshots {
    struct Still { var image: CGImage; var taken: Date; var aspect: CGFloat }

    private var cache: [String: Still] = [:]
    private let folder: URL = {
        let u = Library.folder.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private let io = DispatchQueue(label: "snapshots", qos: .utility)

    private func file(_ id: String) -> URL { folder.appendingPathComponent(id.replacingOccurrences(of: "/", with: "-") + ".jpg") }

    func store(_ image: CGImage, aspect: CGFloat, for id: String) {
        let still = Still(image: image, taken: Date(), aspect: aspect)
        cache[id] = still
        let url = file(id)
        io.async {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            // the aspect ratio rides along in the image description
            let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.7,
                                          kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "aspect=\(aspect)"]]
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
    }

    func still(for id: String) -> Still? {
        if let s = cache[id] { return s }
        let url = file(id)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let desc = (props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFImageDescription] as? String
        let aspect = desc.flatMap { Double($0.replacingOccurrences(of: "aspect=", with: "")) }.map { CGFloat($0) }
            ?? CGFloat(img.width) / CGFloat(max(img.height, 1))
        let taken = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let s = Still(image: img, taken: taken, aspect: aspect)
        cache[id] = s
        return s
    }
}
