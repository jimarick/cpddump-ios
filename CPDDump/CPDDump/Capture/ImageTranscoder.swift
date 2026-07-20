import UIKit

/// Images are tamed before upload: HEIC always becomes JPEG (so the vision
/// models can read it), and anything bulky — multi-megabyte PNG screenshots
/// included — is downscaled to a size the AI reads comfortably and servers
/// accept without body-size tantrums.
enum ImageTranscoder {
    private static let sizeThreshold = 1_500_000
    /// The server normalises every image to ≤1600px anyway — matching it
    /// here just saves the bandwidth.
    private static let maxDimension: CGFloat = 1600

    static func normalise(
        data: Data, filename: String, mimeType: String
    ) -> (data: Data, filename: String, mimeType: String) {
        let name = filename.lowercased()
        let mime = mimeType.lowercased()
        let isHeic = ["image/heic", "image/heif"].contains(mime)
            || name.hasSuffix(".heic") || name.hasSuffix(".heif")
        let isOtherImage = mime.hasPrefix("image/")
            || ["png", "jpg", "jpeg", "webp", "gif"].contains((name as NSString).pathExtension)

        // HEIC always converts; other images only when they're heavy.
        guard isHeic || (isOtherImage && data.count > sizeThreshold),
              let image = UIImage(data: data)
        else {
            return (data, filename, mimeType)
        }

        let largestSide = max(image.size.width, image.size.height)
        let scale = min(1, maxDimension / max(largestSide, 1))
        let target: UIImage
        if scale < 1 {
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            target = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            target = image
        }

        guard let jpeg = target.jpegData(compressionQuality: 0.85),
              jpeg.count < data.count || isHeic
        else {
            return (data, filename, mimeType)
        }

        let base = (filename as NSString).deletingPathExtension
        return (jpeg, base + ".jpg", "image/jpeg")
    }
}
