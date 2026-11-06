import SwiftUI
import MapLibre
import BlackoutCore

/// Something to show on the street map: a shared place or a friend's last check-in.
struct MapPin: Equatable, Identifiable {
    let id: String
    let lat: Double
    let lon: Double
    let title: String
    let subtitle: String
    let symbol: String?  // SF Symbol, or nil to show `letter`
    let letter: String
    let tint: UIColor
}

/// The dark OpenFreeMap street map with you, friends and places. Works offline in the saved area.
struct StreetMap: UIViewRepresentable {
    let pins: [MapPin]
    let center: Spot?
    var open: (String) -> Void = { _ in } // pin id
    var moved: (Spot?) -> Void = { _ in } // the middle of the map once zoomed in on an area (zoom 9+), else nil

    func makeUIView(context: Context) -> MLNMapView {
        let m = MLNMapView(frame: .zero, styleURL: OfflineMap.styleURL)
        m.delegate = context.coordinator
        m.showsUserLocation = true
        m.tintColor = .white
        m.maximumZoomLevel = 18
        m.compassView.compassVisibility = .adaptive
        if let c = center { m.setCenter(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), zoomLevel: 14, animated: false) }
        return m
    }

    func updateUIView(_ m: MLNMapView, context: Context) {
        context.coordinator.open = open
        context.coordinator.moved = moved
        let shown = (m.annotations ?? []).compactMap { $0 as? PinAnnotation }
        let current = Dictionary(pins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        m.removeAnnotations(shown.filter { a in current[a.pin.id] != a.pin }) // gone or changed
        let kept = Set(shown.filter { a in current[a.pin.id] == a.pin }.map(\.pin.id))
        m.addAnnotations(pins.filter { !kept.contains($0.id) }.map(PinAnnotation.init))
        if !context.coordinator.centered, let c = center {
            context.coordinator.centered = true
            m.setCenter(CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), zoomLevel: 14, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(centered: center != nil) }

    final class PinAnnotation: MLNPointAnnotation {
        let pin: MapPin
        init(_ pin: MapPin) {
            self.pin = pin
            super.init()
            coordinate = CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon)
            title = pin.title; subtitle = pin.subtitle
        }
        required init?(coder: NSCoder) { fatalError("not used") }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var centered: Bool
        var open: (String) -> Void = { _ in }
        var moved: (Spot?) -> Void = { _ in }
        init(centered: Bool) { self.centered = centered }

        func mapView(_ m: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let c = m.centerCoordinate, z = m.zoomLevel
            DispatchQueue.main.async { self.moved(z >= 9 ? Spot(lat: c.latitude, lon: c.longitude) : nil) }
        }

        func mapView(_ m: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let a = annotation as? PinAnnotation else { return nil }
            let v = MLNAnnotationView(reuseIdentifier: nil)
            v.frame = CGRect(x: 0, y: 0, width: 38, height: 38)
            v.backgroundColor = UIColor(white: 0.13, alpha: 1)
            v.layer.cornerRadius = 19
            v.layer.borderWidth = 2.5
            v.layer.borderColor = a.pin.tint.cgColor
            if let s = a.pin.symbol, let img = UIImage(systemName: s, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)) {
                let iv = UIImageView(image: img.withTintColor(.white, renderingMode: .alwaysOriginal))
                iv.center = CGPoint(x: 19, y: 19); v.addSubview(iv)
            } else {
                let l = UILabel(frame: v.bounds)
                l.text = a.pin.letter; l.textAlignment = .center; l.textColor = .white
                l.font = .systemFont(ofSize: 16, weight: .bold); v.addSubview(l)
            }
            v.accessibilityLabel = "\(a.pin.title), \(a.pin.subtitle)"
            return v
        }

        func mapView(_ m: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { annotation is PinAnnotation }

        func mapView(_ m: MLNMapView, rightCalloutAccessoryViewFor annotation: MLNAnnotation) -> UIView? {
            guard annotation is PinAnnotation else { return nil }
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: "location.north.fill"), for: .normal)
            b.tintColor = .white
            b.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
            b.accessibilityLabel = "Compass"
            return b
        }

        func mapView(_ m: MLNMapView, annotation: MLNAnnotation, calloutAccessoryControlTapped control: UIControl) {
            if let a = annotation as? PinAnnotation { m.deselectAnnotation(a, animated: false); open(a.pin.id) }
        }
    }
}

/// Save, update or delete the offline map of your area: around you, or around the middle of the map on screen when
/// the phone has no position (location off, or no GPS fix indoors).
struct OfflineMapCard: View {
    @ObservedObject var map = OfflineMap.shared
    @ObservedObject private var loc = LocationService.shared
    let me: Spot?
    var mapCenter: Spot? = nil
    private var target: Spot? { me ?? mapCenter }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch map.state {
            case .none:
                Text("Save this map for the blackout").scaledFont(17, .bold).foregroundStyle(Theme.text)
                Text(me != nil ? "Downloads the streets about 10 km around you (up to 50 MB) while you still have internet. Then the map works with none."
                               : "Downloads the streets about 10 km around the middle of the map (up to 50 MB) while you still have internet.")
                    .scaledFont(14).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                if me == nil {
                    Text(loc.denied ? "Location is off for DarkProof, so move and zoom the map to your area first."
                                    : mapCenter == nil ? "Finding your position… or zoom the map to your area." : "No position yet: it saves the area on screen.")
                        .scaledFont(14, .semibold).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
                download(me != nil ? "Download map" : "Save the area on screen")
            case .downloading(let p):
                Text("Saving the map… \(Int(p * 100))%").scaledFont(17, .bold).foregroundStyle(Theme.text)
                ProgressLine(progress: p)
                Button("Cancel") { map.cancel() }.buttonStyle(GhostButton())
            case .ready(let bytes, let center, let ts):
                HStack(alignment: .firstTextBaseline) {
                    Label("Saved for offline use", systemImage: "checkmark.circle.fill").scaledFont(15, .bold)
                        .foregroundStyle(Theme.safe)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).scaledFont(13).foregroundStyle(Theme.dim)
                }
                Text(savedText(center, ts)).scaledFont(14).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    download(me != nil ? "Update to here" : "Save the area on screen", ghost: true)
                    Button("Delete") { map.delete() }.buttonStyle(GhostButton())
                }
            case .failed(let why):
                Text("The map wasn't saved").scaledFont(17, .bold).foregroundStyle(Theme.text)
                Text(why).scaledFont(14).foregroundStyle(Theme.help)
                download("Try again")
            }
        }
        .padding(18)
        .background(Theme.card.opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func savedText(_ c: Spot, _ ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ts) / 1000).formatted(date: .abbreviated, time: .omitted)
        if let me {
            let d = Geo.distance(me, c)
            return d < 300 ? "About 20 km across, around where you are. Saved \(date)."
                           : "About 20 km across, centered \(FindSheet.meters(d)) from here. Saved \(date)."
        }
        return "About 20 km across. Saved \(date)."
    }

    @ViewBuilder private func download(_ title: String, ghost: Bool = false) -> some View {
        let b = Button(title) { if let t = target { map.download(around: t) } }.disabled(target == nil)
        if ghost { b.buttonStyle(GhostButton()) } else { b.buttonStyle(PrimaryButton()) }
    }
}
