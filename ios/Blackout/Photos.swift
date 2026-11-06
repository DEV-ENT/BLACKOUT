import SwiftUI
import PhotosUI
import ImageIO
import BlackoutCore

/// Makes a photo small enough for one packet (`Photo.maxBytes`): JPEG, a few hundred pixels wide.
/// Bluetooth carries a few kilobytes per second, so this keeps a photo to a few seconds per hop.
enum PhotoShrinker {
    /// A photo from another phone, decoded safely: its bytes are untrusted, so a header claiming a huge picture is
    /// refused (it could use hundreds of MB) and the picture is decoded at most `maxPixels` on its longest side.
    static func received(_ data: Data, maxPixels: Int = 1280) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 4096, h <= 4096 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func jpeg(_ image: UIImage) -> Data? {
        var side: CGFloat = 640
        while side >= 120 {
            let small = resized(image, maxSide: side)
            for q in stride(from: 0.6, through: 0.2, by: -0.1) {
                if let d = small.jpegData(compressionQuality: q), d.count <= Photo.maxBytes { return d }
            }
            side *= 0.8
        }
        return nil
    }

    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let s = image.size, k = min(1, maxSide / max(s.width, s.height))
        let size = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// A photo picked or taken, waiting for a caption.
struct PendingPhoto: Identifiable {
    let id = UUID()
    let jpeg: Data
    let image: UIImage
}

/// Preview, caption and send.
struct PhotoSendSheet: View {
    let photo: PendingPhoto
    let groupName: String
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var caption = ""
    @FocusState private var typing: Bool

    var body: some View {
        SheetPage(title: "Send photo") {
            Image(uiImage: photo.image).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: 360)
            InputField(label: "Caption", hint: "\(ByteCountFormatter.string(fromByteCount: Int64(photo.jpeg.count), countStyle: .file)), made small so it travels over Bluetooth.") {
                TextField("", text: $caption, prompt: Text("What does it show?").foregroundColor(Theme.faint))
                    .focused($typing).submitLabel(.done)
                    .onChange(of: caption) { c in if c.count > 200 { caption = String(c.prefix(200)) } }
            }
            Button { send(caption); dismiss() } label: { Label("Send to \(groupName)", systemImage: "arrow.up") }
                .buttonStyle(PrimaryButton())
            Text("Only your group can see it. Phones without the newest DarkProof show “📷 Photo” instead.")
                .font(.footnote).foregroundStyle(Theme.dim)
        }
    }
}

/// Full-size view of a photo from the chat, with Share (which can also save it).
struct PhotoViewer: View {
    let jpeg: Data
    let caption: String
    let from: String

    var body: some View {
        SheetPage(title: from) {
            if let ui = PhotoShrinker.received(jpeg) {
                Image(uiImage: ui).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .frame(maxWidth: .infinity)
                if !caption.isEmpty { Text(caption).scaledFont(17).foregroundStyle(Theme.text) }
                ShareLink(item: Image(uiImage: ui), preview: SharePreview(caption.isEmpty ? "Photo" : caption, image: Image(uiImage: ui))) {
                    Label("Share or save", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButton())
            }
        }
    }
}

/// Takes a photo with the camera (UIKit's picker; SwiftUI has none).
struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { done(nil) }
    }
}
