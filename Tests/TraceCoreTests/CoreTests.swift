import XCTest
@testable import TraceCore

final class GeoTests: XCTestCase {
    func testHaversineVitreFougeres() {
        // Vitré -> Fougères : environ 25,6 km à vol d'oiseau.
        let d = Geo.distance(lat1: 48.1247, lon1: -1.2099, lat2: 48.3525, lon2: -1.2014)
        XCTAssertEqual(d, 25_340, accuracy: 400)
    }

    func testSimplifyKeepsEndsAndReduces() {
        var pts: [TrackPoint] = []
        for i in 0..<200 {
            let t = Double(i) / 199
            pts.append(TrackPoint(lat: 48.0 + 0.01 * t + (i % 2 == 0 ? 0.000001 : 0), lon: -1.0 + 0.02 * t))
        }
        let s = Geo.simplify(pts, tolerance: 5)
        XCTAssertEqual(s.first, pts.first)
        XCTAssertEqual(s.last, pts.last)
        XCTAssertLessThan(s.count, 10)
    }

    func testNearestPoint() {
        let line = [TrackPoint(lat: 48.0, lon: -1.0), TrackPoint(lat: 48.0, lon: -0.9), TrackPoint(lat: 48.1, lon: -0.9)]
        let r = Geo.nearestPoint(on: line, to: TrackPoint(lat: 48.001, lon: -0.95))!
        XCTAssertEqual(r.segment, 0)
        XCTAssertEqual(r.fraction, 0.5, accuracy: 0.01)
        XCTAssertEqual(r.distance, 111, accuracy: 5)
    }

    func testStraightLineSampling() {
        let a = TrackPoint(lat: 48.0, lon: -1.0), b = TrackPoint(lat: 48.0, lon: -0.99)
        let pts = Geo.straightLine(from: a, to: b, step: 25)
        XCTAssertEqual(pts.first, a)
        XCTAssertEqual(pts.last, b)
        XCTAssertGreaterThan(pts.count, 25)
    }

    func testTileXY() {
        let t = Geo.tileXY(lat: 48.1247, lon: -1.2099, zoom: 15)
        XCTAssertEqual(t.x, 16273)
        XCTAssertEqual(t.y, 11373)
    }
}

final class GPXTests: XCTestCase {
    func testRoundTripWithProject() throws {
        var p = RouteProject(name: "Test & <fun>")
        p.anchors = [Anchor(lat: 48.1, lon: -1.2), Anchor(lat: 48.11, lon: -1.19)]
        p.legs = [Leg(profile: .hiking, points: [TrackPoint(lat: 48.1, lon: -1.2, ele: 100), TrackPoint(lat: 48.105, lon: -1.195, ele: 110.5), TrackPoint(lat: 48.11, lon: -1.19, ele: 105)])]
        p.waypoints = [Waypoint(lat: 48.1, lon: -1.2, name: "Départ", desc: "ici", symbol: "Flag")]
        let data = GPXWriter.write(p.toGPX(embedProject: true), options: GPXWriteOptions(embedProject: true))
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("Test &amp; &lt;fun&gt;"))
        XCTAssertTrue(s.contains("<trace:project>"))
        let f = try GPXReader.read(data)
        XCTAssertEqual(f.name, "Test & <fun>")
        XCTAssertEqual(f.waypoints.count, 1)
        XCTAssertEqual(f.waypoints[0].name, "Départ")
        XCTAssertEqual(f.tracks.count, 1)
        XCTAssertEqual(f.tracks[0].segments[0].count, 3)
        XCTAssertEqual(f.tracks[0].segments[0][1].ele!, 110.5, accuracy: 0.01)
        let p2 = RouteProject.fromGPX(f, fallbackName: "x")
        XCTAssertEqual(p2.anchors.count, 2)
        XCTAssertEqual(p2.legs.count, 1)
        XCTAssertEqual(p2.legs[0].profile, .hiking)
        XCTAssertEqual(p2.name, "Test & <fun>")
    }

    func testReadForeignGPX() throws {
        let xml = """
        <?xml version="1.0"?>
        <gpx version="1.1" creator="Garmin" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Sortie</name><time>2026-08-30T10:00:00Z</time></metadata>
          <wpt lat="48.1" lon="-1.2"><name>Café</name></wpt>
          <trk><name>Sortie</name><trkseg>
            <trkpt lat="48.1" lon="-1.2"><ele>50</ele><time>2026-08-30T10:00:00.000Z</time></trkpt>
            <trkpt lat="48.2" lon="-1.3"><ele>60</ele></trkpt>
          </trkseg></trk>
          <rte><name>R</name><rtept lat="48.0" lon="-1.0"/><rtept lat="48.0" lon="-1.1"/></rte>
        </gpx>
        """
        let f = try GPXReader.read(Data(xml.utf8))
        XCTAssertEqual(f.name, "Sortie")
        XCTAssertEqual(f.tracks.count, 2)
        XCTAssertEqual(f.tracks[0].segments[0][0].time!.timeIntervalSince1970, 1_788_084_000, accuracy: 1)
        XCTAssertEqual(f.tracks[1].name, "R")
        let p = RouteProject.fromGPX(f, fallbackName: "x")
        XCTAssertTrue(p.anchors.isEmpty)
        XCTAssertEqual(p.importedTracks.count, 2)
        XCTAssertEqual(p.trackPoints.count, 4)
    }

    func testExportSimplifiedWithoutProject() {
        var pts: [TrackPoint] = []
        for i in 0..<100 { pts.append(TrackPoint(lat: 48.0 + Double(i) * 0.0001, lon: -1.0, ele: 10)) }
        let f = GPXFile(name: "n", tracks: [GPXTrack(segments: [pts])], projectJSON: "{}")
        let data = GPXWriter.write(f, options: GPXWriteOptions(simplifyTolerance: 2, embedProject: false))
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(s.contains("trace:project>"))
        XCTAssertEqual(s.components(separatedBy: "<trkpt").count - 1, 2)
    }
}

final class StatsTests: XCTestCase {
    func testAscentHysteresis() {
        let e: [Double] = [100, 102, 101, 103, 110, 108, 112, 100]
        let r = Stats.ascentDescent(e, threshold: 5)
        XCTAssertEqual(r.ascent, 10, accuracy: 0.001)
        XCTAssertEqual(r.descent, 10, accuracy: 0.001)
    }

    func testComputeAndProfile() {
        var pts: [TrackPoint] = []
        for i in 0..<400 {
            pts.append(TrackPoint(lat: 48.0 + Double(i) * 0.0002, lon: -1.0, ele: 100 + 50 * sin(Double(i) / 40)))
        }
        let st = Stats.compute(pts)
        XCTAssertTrue(st.hasElevation)
        XCTAssertGreaterThan(st.ascent, 100)
        XCTAssertGreaterThan(st.distance, 8000)
        let prof = Stats.profile(pts, maxSamples: 100)
        XCTAssertEqual(prof.count, 100); XCTAssertEqual(Set(prof.map { $0.id }).count, 100)
        XCTAssertEqual(prof.last!.distance, st.distance, accuracy: 1)
    }

    func testDuration() {
        let s = Stats.estimatedDuration(distance: 10_000, ascent: 500, descent: 500, profile: .hiking)
        XCTAssertEqual(s / 3600, 3.3, accuracy: 0.3)
        XCTAssertEqual(Stats.formatDuration(s).hasPrefix("3 h"), true)
        XCTAssertEqual(Stats.formatDistance(12_345), "12,3 km")
    }
}
