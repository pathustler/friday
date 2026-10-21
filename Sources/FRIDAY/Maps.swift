import MapKit
import SwiftUI

struct Place: Codable, Hashable, Identifiable {
    var name: String
    var address: String
    var lat: Double
    var lon: Double
    var id: String { "\(lat),\(lon),\(name)" }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct RoutePreview: Codable, Hashable {
    var meters: Double
    var seconds: Double
    var mode: String          // "driving" | "walking" | "transit"
    var path: [[Double]]      // [lat, lon] pairs, thinned for display
}

struct MapPreview: Codable, Hashable {
    var places: [Place] = []
    var route: RoutePreview?
}

enum MapsService {
    private static func place(_ item: MKMapItem) -> Place {
        let p = item.placemark
        let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let address = [street, p.locality ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        return Place(name: item.name ?? p.name ?? "Place", address: address.isEmpty ? (p.title ?? "") : address,
                     lat: p.coordinate.latitude, lon: p.coordinate.longitude)
    }

    static func search(_ query: String, limit: Int) async -> [(Place, MKMapItem)] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        guard let res = try? await MKLocalSearch(request: req).start() else { return [] }
        return res.mapItems.prefix(limit).map { (place($0), $0) }
    }

    /// Returns the route preview plus its two endpoints (as places), or an error message.
    static func route(from: String, to: String, mode: String) async -> (RoutePreview, [Place])? {
        async let a = search(from, limit: 1)
        async let b = search(to, limit: 1)
        guard let src = await a.first, let dst = await b.first else { return nil }

        let req = MKDirections.Request()
        req.source = src.1
        req.destination = dst.1
        req.transportType = mode == "walking" ? .walking : (mode == "transit" ? .transit : .automobile)
        guard let route = try? await MKDirections(request: req).calculate().routes.first else { return nil }

        let poly = route.polyline
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: poly.pointCount)
        poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
        let step = max(1, coords.count / 250)
        var path = stride(from: 0, to: coords.count, by: step).map { [coords[$0].latitude, coords[$0].longitude] }
        if let last = coords.last, path.last != [last.latitude, last.longitude] { path.append([last.latitude, last.longitude]) }

        return (RoutePreview(meters: route.distance, seconds: route.expectedTravelTime, mode: mode, path: path), [src.0, dst.0])
    }

    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, 1)) min"
    }

    static func distance(_ m: Double) -> String {
        let f = MeasurementFormatter()
        f.unitOptions = .naturalScale
        f.numberFormatter.maximumFractionDigits = 1
        return f.string(from: Measurement(value: m, unit: UnitLength.meters))
    }

    static func openInMaps(_ preview: MapPreview, place: Place? = nil) {
        var comps = URLComponents(string: "https://maps.apple.com/")!
        if let p = place ?? (preview.route == nil ? preview.places.first : nil) {
            comps.queryItems = [URLQueryItem(name: "ll", value: "\(p.lat),\(p.lon)"), URLQueryItem(name: "q", value: p.name)]
        } else if preview.places.count >= 2 {
            let flag = preview.route?.mode == "walking" ? "w" : (preview.route?.mode == "transit" ? "r" : "d")
            comps.queryItems = [URLQueryItem(name: "saddr", value: "\(preview.places[0].lat),\(preview.places[0].lon)"),
                                URLQueryItem(name: "daddr", value: "\(preview.places[1].lat),\(preview.places[1].lon)"),
                                URLQueryItem(name: "dirflg", value: flag)]
        }
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Dark, interactive map view

struct FridayMap: NSViewRepresentable {
    let preview: MapPreview
    let focus: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        map.showsZoomControls = true
        map.showsCompass = false
        map.delegate = context.coordinator

        let isRoute = preview.route != nil
        for (i, p) in preview.places.enumerated() {
            let a = MKPointAnnotation()
            a.coordinate = p.coordinate
            a.title = isRoute ? (i == 0 ? "A · \(p.name)" : "B · \(p.name)") : p.name
            a.subtitle = p.address
            map.addAnnotation(a)
        }

        var rect = MKMapRect.null
        if let r = preview.route {
            let coords = r.path.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
            let line = MKPolyline(coordinates: coords, count: coords.count)
            map.addOverlay(line, level: .aboveRoads)
            rect = line.boundingMapRect
        }
        for p in preview.places {
            let pt = MKMapPoint(p.coordinate)
            rect = rect.union(MKMapRect(x: pt.x, y: pt.y, width: 0, height: 0))
        }
        if preview.places.count == 1, preview.route == nil {
            map.setRegion(MKCoordinateRegion(center: preview.places[0].coordinate,
                                             span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)), animated: false)
        } else if !rect.isNull {
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 50, left: 50, bottom: 50, right: 50), animated: false)
        }
        return map
    }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        map.delegate = nil                       // MapKit can message a freed delegate while tearing down
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        guard focus != context.coordinator.lastFocus else { return }
        context.coordinator.lastFocus = focus
        guard let f = focus, let p = preview.places.first(where: { $0.id == f }) else { return }
        map.setRegion(MKCoordinateRegion(center: p.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)), animated: true)
        if let a = map.annotations.first(where: { abs($0.coordinate.latitude - p.lat) < 1e-9 && abs($0.coordinate.longitude - p.lon) < 1e-9 }) {
            map.selectAnnotation(a, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastFocus: String?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = MKPolylineRenderer(overlay: overlay)
            r.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9)
            r.lineWidth = 5
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pin")
            v.canShowCallout = true
            return v
        }
    }
}

struct MapCardView: View {
    let preview: MapPreview
    @State private var focus: String?

    var body: some View {
        VStack(spacing: 0) {
            FridayMap(preview: preview, focus: focus)
                .frame(height: 280)

            if let r = preview.route {
                HStack(spacing: 8) {
                    Image(systemName: r.mode == "walking" ? "figure.walk" : (r.mode == "transit" ? "tram.fill" : "car.fill"))
                        .foregroundStyle(Color.primary.opacity(0.5))
                    Text("\(MapsService.distance(r.meters)) · \(MapsService.duration(r.seconds))")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.9))
                    Spacer()
                    openButton { MapsService.openInMaps(preview) }
                }
                .padding(12)
            } else {
                VStack(spacing: 0) {
                    ForEach(preview.places) { p in
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill").foregroundStyle(Color(nsColor: .systemRed))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.primary.opacity(0.92))
                                if !p.address.isEmpty {
                                    Text(p.address).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.45))
                                }
                            }
                            Spacer()
                            openButton { MapsService.openInMaps(preview, place: p) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(focus == p.id ? Color.white.opacity(0.07) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { focus = p.id }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func openButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up.forward.app").font(.system(size: 15)).foregroundStyle(Color.primary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help("Open in Maps")
    }
}
