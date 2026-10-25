import XCTest
import NavCore

final class GeocoderTests: XCTestCase {
    private let klcc = Coordinate(latitude: 3.1579, longitude: 101.7123)

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testPhotonRequest() {
        let geocoder = WebGeocoder(backend: .photon(baseURL: URL(string: "https://photon.example.my/")!))
        let request = geocoder.request(for: "mid valley", near: klcc)
        XCTAssertEqual(request.url?.absoluteString.hasPrefix("https://photon.example.my/api/?"), true)
        XCTAssertEqual(query(request)["q"], "mid valley")
        XCTAssertEqual(query(request)["bbox"], "99.6,0.8,119.3,7.4")
        XCTAssertEqual(query(request)["lat"], "3.15790")
        XCTAssertEqual(query(request)["lon"], "101.71230")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Jalan/"), true)
    }

    func testJalanRequest() {
        let project = URL(string: "https://abcd.supabase.co/")!
        let typing = WebGeocoder(backend: .jalan(projectURL: project, askPhoton: true, askNominatim: false))
            .request(for: "mid valley", near: klcc)
        XCTAssertEqual(typing.url?.absoluteString.hasPrefix("https://abcd.supabase.co/functions/v1/places?"), true)
        XCTAssertEqual(query(typing)["q"], "mid valley")
        XCTAssertEqual(query(typing)["limit"], "8")
        XCTAssertEqual(query(typing)["lat"], "3.15790")
        XCTAssertEqual(query(typing)["lon"], "101.71230")
        XCTAssertNil(query(typing)["photon"])
        XCTAssertNil(query(typing)["submit"])
        XCTAssertEqual(typing.timeoutInterval, 20)

        let onSearch = WebGeocoder(backend: .jalan(projectURL: project, askPhoton: false, askNominatim: true))
            .request(for: "kedai ah seng", near: nil)
        XCTAssertEqual(query(onSearch)["photon"], "0")
        XCTAssertEqual(query(onSearch)["submit"], "1")
        XCTAssertNil(query(onSearch)["lat"])
    }

    func testPeliasRequests() {
        let ors = WebGeocoder(backend: .openrouteservice(apiKey: "k1")).request(for: "klcc", near: klcc)
        XCTAssertEqual(ors.url?.host, "api.openrouteservice.org")
        XCTAssertEqual(query(ors)["text"], "klcc")
        XCTAssertEqual(query(ors)["api_key"], "k1")
        XCTAssertEqual(query(ors)["boundary.country"], "MY")
        XCTAssertEqual(query(ors)["focus.point.lat"], "3.15790")

        let stadia = WebGeocoder(backend: .stadia(apiKey: "k2")).request(for: "klcc", near: nil)
        XCTAssertEqual(stadia.url?.absoluteString.hasPrefix("https://api.stadiamaps.com/geocoding/v1/autocomplete?"), true)
        XCTAssertEqual(query(stadia)["api_key"], "k2")
        XCTAssertNil(query(stadia)["focus.point.lat"])
    }

    func testMapTilerPutsQueryInPath() {
        let request = WebGeocoder(backend: .mapTiler(apiKey: "k")).request(for: "R&R Tapah/Utara", near: klcc)
        XCTAssertEqual(request.url?.absoluteString.hasPrefix(
            "https://api.maptiler.com/geocoding/R%26R%20Tapah%2FUtara.json?"), true)
        XCTAssertEqual(query(request)["country"], "my")
        XCTAssertEqual(query(request)["proximity"], "101.71230,3.15790")

        let chinese = WebGeocoder(backend: .mapTiler(apiKey: "k")).request(for: "茨厂街", near: nil)
        XCTAssertEqual(chinese.url?.path, "/geocoding/茨厂街.json")
    }

    func testNominatimAndLocationIQRequests() {
        let nominatim = WebGeocoder(backend: .nominatimPublic).request(for: "kampung baru", near: klcc)
        XCTAssertEqual(nominatim.url?.path, "/search")
        XCTAssertEqual(query(nominatim)["format"], "jsonv2")
        XCTAssertEqual(query(nominatim)["countrycodes"], "my")
        XCTAssertEqual(query(nominatim)["viewbox"], "101.01230,3.85790,102.41230,2.45790")
        XCTAssertNil(query(nominatim)["bounded"])

        let locationIQ = WebGeocoder(backend: .locationIQ(apiKey: "pk.x")).request(for: "kampung baru", near: nil)
        XCTAssertEqual(locationIQ.url?.path, "/v1/autocomplete")
        XCTAssertEqual(query(locationIQ)["key"], "pk.x")
    }

    func testParsePhoton() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"Point","coordinates":[101.6772,3.1182]},
           "properties":{"osm_type":"W","osm_id":123,"name":"Mid Valley Megamall","street":"Lingkaran Syed Putra",
                         "city":"Kuala Lumpur","state":"Kuala Lumpur","country":"Malaysia"}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[101.70,3.15]},
           "properties":{"osm_type":"N","osm_id":456,"housenumber":"12","street":"Jalan Alor","city":"Kuala Lumpur"}},
          {"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[101.0,3.0],[101.1,3.0],[101.0,3.1]]]},
           "properties":{"name":"Not a point"}}
        ]}
        """
        let places = try WebGeocoder.parse(Data(json.utf8), from: .photon)
        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(places[0].id, "photon:W123")
        XCTAssertEqual(places[0].name, "Mid Valley Megamall")
        XCTAssertEqual(places[0].subtitle, "Lingkaran Syed Putra, Kuala Lumpur")
        XCTAssertEqual(places[0].coordinate, Coordinate(latitude: 3.1182, longitude: 101.6772))
        XCTAssertEqual(places[1].name, "12 Jalan Alor")
        XCTAssertEqual(places[1].subtitle, "Kuala Lumpur")
    }

    func testParseJalan() throws {
        let json = """
        {"places":[
          {"id":"w123","name":"Mid Valley Megamall","subtitle":"Bangsar, Kuala Lumpur","lat":3.1182,"lon":101.6772},
          {"id":"n456","name":"Kedai Ah Seng","subtitle":"","lat":3.15,"lon":101.7}
        ]}
        """
        let places = try WebGeocoder.parse(Data(json.utf8), from: .jalan)
        XCTAssertEqual(places, [
            PlaceResult(id: "jalan:w123", name: "Mid Valley Megamall", subtitle: "Bangsar, Kuala Lumpur",
                        coordinate: Coordinate(latitude: 3.1182, longitude: 101.6772), source: .jalan),
            PlaceResult(id: "jalan:n456", name: "Kedai Ah Seng", subtitle: "",
                        coordinate: Coordinate(latitude: 3.15, longitude: 101.7), source: .jalan),
        ])
        XCTAssertThrowsError(try WebGeocoder.parse(Data(#"{"error":"Search failed"}"#.utf8), from: .jalan))
    }

    func testParsePelias() throws {
        let json = """
        {"geocoding":{"version":"0.2"},"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"Point","coordinates":[101.7123,3.1579]},
           "properties":{"gid":"openstreetmap:venue:way/1","layer":"venue","name":"Suria KLCC",
                         "label":"Suria KLCC, Kuala Lumpur, Malaysia","locality":"Kuala Lumpur"}}
        ]}
        """
        let places = try WebGeocoder.parse(Data(json.utf8), from: .stadia)
        XCTAssertEqual(places, [PlaceResult(id: "stadia:openstreetmap:venue:way/1", name: "Suria KLCC",
                                            subtitle: "Kuala Lumpur, Malaysia",
                                            coordinate: Coordinate(latitude: 3.1579, longitude: 101.7123),
                                            source: .stadia)])
    }

    func testParseMapTiler() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","id":"poi.99","text":"R&R Tapah","place_name":"R&R Tapah, Perak, Malaysia",
           "center":[101.25,4.19],"geometry":{"type":"Point","coordinates":[101.25,4.19]},"properties":{}},
          {"type":"Feature","id":"municipality.5","text":"Ipoh","place_name":"Ipoh, Perak, Malaysia",
           "center":[101.08,4.6],"geometry":{"type":"Polygon","coordinates":[[[101.0,4.5],[101.2,4.5],[101.0,4.7]]]}}
        ]}
        """
        let places = try WebGeocoder.parse(Data(json.utf8), from: .mapTiler)
        XCTAssertEqual(places.map(\.name), ["R&R Tapah", "Ipoh"])
        XCTAssertEqual(places[0].subtitle, "Perak, Malaysia")
        XCTAssertEqual(places[1].coordinate, Coordinate(latitude: 4.6, longitude: 101.08))
    }

    func testParseNominatim() throws {
        let json = """
        [{"place_id":2345,"osm_type":"node","osm_id":1,"lat":"3.1660","lon":"101.6990","category":"place",
          "type":"suburb","name":"Kampung Baru","display_name":"Kampung Baru, Kuala Lumpur, Malaysia"},
         {"place_id":2346,"lat":"3.1","lon":"101.6","name":"","display_name":"Jalan 1/2, Petaling Jaya, Selangor, Malaysia"}]
        """
        let places = try WebGeocoder.parse(Data(json.utf8), from: .nominatim)
        XCTAssertEqual(places.map(\.id), ["nominatim:2345", "nominatim:2346"])
        XCTAssertEqual(places[0].subtitle, "Kuala Lumpur, Malaysia")
        XCTAssertEqual(places[1].name, "Jalan 1/2")
        XCTAssertEqual(places[1].subtitle, "Petaling Jaya, Selangor, Malaysia")
    }

    func testParseLocationIQ() throws {
        let json = """
        [{"place_id":"321","lat":"4.5975","lon":"101.0901","display_place":"Ipoh Parade",
          "display_address":"Jalan Sultan Abdul Jalil, Ipoh, Perak, Malaysia",
          "display_name":"Ipoh Parade, Jalan Sultan Abdul Jalil, Ipoh, Perak, Malaysia"}]
        """
        let places = try WebGeocoder.parse(Data(json.utf8), from: .locationIQ)
        XCTAssertEqual(places.first?.id, "locationIQ:321")
        XCTAssertEqual(places.first?.name, "Ipoh Parade")
        XCTAssertEqual(places.first?.subtitle, "Jalan Sultan Abdul Jalil, Ipoh, Perak, Malaysia")
    }

    func testParseErrorBody() {
        let data = Data(#"{"error":"Invalid key"}"#.utf8)
        XCTAssertThrowsError(try WebGeocoder.parse(data, from: .locationIQ)) { error in
            XCTAssertEqual(error as? GeocodingError, .invalidResponse)
        }
    }
}
