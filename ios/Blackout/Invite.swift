import UIKit
import CoreImage.CIFilterBuiltins
import BlackoutCore

extension Invite {
    /// Black-on-white QR code of an invite link, sharp at any size.
    static func qr(_ url: URL) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(url.absoluteString.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
