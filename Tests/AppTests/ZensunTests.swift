import Foundation
@testable import App
import XCTest

final class ZensunTests: XCTestCase {
    func testIsDaylightTime() {
        let time = TimerangeDt(start: Timestamp(2023, 04, 06), nTime: 48, dtSeconds: 3600)
        let isDay = Zensun.calculateIsDay(timeRange: time, lat: 52.52, lon: 13.42)
        XCTAssertEqual(isDay, [0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
    }

    func testSunRiseSetLosAngeles() {
        // https://www.timeanddate.com/sun/usa/los-angeles?month=11&year=2021
        let utcOffsetSeconds = -25200
       // let currentTime = Timestamp(1636199223) // UTC 2021-11-06T11:47:03+00:00
        let time = Timestamp(1636182000) ..< Timestamp(1636268400)

        // vancouver: lat: 49.25, lon: -123.12
        let times = Zensun.calculateSunRiseSet(timeRange: time, lat: 34.05223, lon: -118.24368, utcOffsetSeconds: utcOffsetSeconds)
        XCTAssertEqual(times.rise[0], Timestamp(1636208261))
        XCTAssertEqual(times.set[0], Timestamp(1636246534))
        let sunset = times.set.map({ $0.add(utcOffsetSeconds) }).iso8601_YYYYMMddHHmm
        let sunrise = times.rise.map({ $0.add(utcOffsetSeconds) }).iso8601_YYYYMMddHHmm
        XCTAssertEqual(sunrise[0], "2021-11-06T07:17") // supposed to be 07:17
        XCTAssertEqual(sunset[0], "2021-11-06T17:55") // supposed to be 17:55
    }

    func testSunRiseSetPolar() {
        // https://www.timeanddate.com/sun/usa/los-angeles?month=11&year=2021
        let utcOffsetSeconds = -25200
       // let currentTime = Timestamp(1636199223) // UTC 2021-11-06T11:47:03+00:00
        let time = Timestamp(1636182000) ..< Timestamp(1636268400)

        let times = Zensun.calculateSunRiseSet(timeRange: time, lat: 85.05223, lon: -118.24368, utcOffsetSeconds: utcOffsetSeconds)
        XCTAssertEqual(times.rise[0], Timestamp(1636182000))
        XCTAssertEqual(times.set[0], Timestamp(1636182000))
        let sunset = times.set.map({ $0.add(utcOffsetSeconds) }).iso8601_YYYYMMddHHmm
        let sunrise = times.rise.map({ $0.add(utcOffsetSeconds) }).iso8601_YYYYMMddHHmm
        XCTAssertEqual(sunrise[0], "2021-11-06T00:00") // polar night -> 0h length
        XCTAssertEqual(sunset[0], "2021-11-06T00:00") //

        let times2 = Zensun.calculateSunRiseSet(timeRange: time, lat: -85.05223, lon: -118.24368, utcOffsetSeconds: utcOffsetSeconds)
        XCTAssertEqual(times2.rise[0], Timestamp(1636182000))
        XCTAssertEqual(times2.set[0], Timestamp(1636268400))
        let sunset2 = times2.set.map({ $0.add(utcOffsetSeconds) }).iso8601_YYYYMMddHHmm
        let sunrise2 = times2.rise.map({ $0.add(utcOffsetSeconds) }).iso8601_YYYYMMddHHmm
        XCTAssertEqual(sunrise2[0], "2021-11-06T00:00") // polar day -> 24h length
        XCTAssertEqual(sunset2[0], "2021-11-07T00:00") //
    }

    func testSunRiseSetVancouver() {
        // https://www.timeanddate.com/sun/canada/vancouver?month=11&year=2021
        let utcOffsetSeconds = -25200
       // let currentTime = Timestamp(1636199223) // UTC 2021-11-06T11:47:03+00:00
        let time = Timestamp(1636182000) ..< Timestamp(1636268400)

        let times = Zensun.calculateSunRiseSet(timeRange: time, lat: 49.25, lon: -123.12, utcOffsetSeconds: utcOffsetSeconds)
        XCTAssertEqual(times.rise[0], Timestamp(1636211364))
        XCTAssertEqual(times.set[0], Timestamp(1636245772))
        let sunset = times.set.map({ $0.add(utcOffsetSeconds) }).iso8601_YYYYMMddHHmm
        let sunrise = times.rise.map({ $0.add(utcOffsetSeconds) }).iso8601_YYYYMMddHHmm
        XCTAssertEqual(sunset[0], "2021-11-06T17:42") // supposed to be 17:42
        XCTAssertEqual(sunrise[0], "2021-11-06T08:09") // supposed to be 08:09
    }

    func testExtraTerrestrialRadiation() {
        // jaunary 3rd sun is closest to earth
        XCTAssertEqual(Zensun.extraTerrestrialRadiationBackwards(latitude: -23.5, longitude: 0, timerange: TimerangeDt(start: Timestamp(2020, 12, 26, 12), nTime: 1, dtSeconds: 3600))[0], 1400.073)
        // on jyuly 4rd the sun is the farthest away from earth
        XCTAssertEqual(Zensun.extraTerrestrialRadiationBackwards(latitude: 23.5, longitude: 0, timerange: TimerangeDt(start: Timestamp(2020, 6, 26, 12), nTime: 1, dtSeconds: 3600))[0], 1308.9365)
    }

    /*func testZenith() {
        let z2 = SolarPositionAlgorithm.zenith(lat: 23.5, lon: 2, time: Timestamp(1636211364))
        let z = Zensun.calculateZenithInstant(lat: 23.5, lon: 2, time: Timestamp(1636211364))
        
        XCTAssertEqual(z, z2)
        // 65.556435 vs 65.53193
    }*/

    func testSunRadius() {
        XCTAssertEqual(Timestamp(2009, 12, 31).getSunRadius(), 0.9833197)
        XCTAssertEqual(Timestamp(2010, 1, 2).getSunRadius(), 0.9832899)
        XCTAssertEqual(Timestamp(2010, 1, 3).getSunRadius(), 0.98328245)
        XCTAssertEqual(Timestamp(2010, 1, 4).getSunRadius(), 0.98328) // NASA 0.983297
        XCTAssertEqual(Timestamp(2010, 1, 5).getSunRadius(), 0.98328245)
        XCTAssertEqual(Timestamp(2010, 1, 6).getSunRadius(), 0.9832899)
        XCTAssertEqual(Timestamp(2010, 7, 4).getSunRadius(), 1.0167135) // NASA 1.016705
        XCTAssertEqual(Zensun.solarConstant * powf(0.9832855, 2), 1322.3612) // should 1321
        XCTAssertEqual(Zensun.solarConstant * powf(1.0167282, 2), 1413.8408) // should 1412
    }

    func testDaylightDuration() {
        // https://www.timeanddate.com/sun/usa/los-angeles?month=11&year=2021
        // should be length 10:46:48 -> 10.78
        let duration = Zensun.calculateDaylightDuration(utcMidnight: Timestamp(2021, 11, 01) ..< Timestamp(2021, 11, 02), lat: 34.05223, lon: -118.24368)
        XCTAssertEqual(duration[0] / 3600, 10.78, accuracy: 0.002)

        // https://www.timeanddate.com/sun/@3027582?month=1&year=2021
        // should be 9:04:53 -> 9.08138888889
        let duration2 = Zensun.calculateDaylightDuration(utcMidnight: Timestamp(2021, 1, 01) ..< Timestamp(2021, 1, 02), lat: 43, lon: 2)
        XCTAssertEqual(duration2[0] / 3600, 9.0787735, accuracy: 0.002)
    }

    func testZensunDate() {
        // https://en.wikipedia.org/wiki/June_solstice
        XCTAssertEqual(Timestamp(2018, 03, 20, 16, 15).getSunDeclination(), 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2018, 06, 21, 10, 07).getSunDeclination() - 23.44, 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2018, 09, 23, 01, 54).getSunDeclination(), 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2018, 12, 21, 22, 22).getSunDeclination() + 23.44, 0, accuracy: 0.02)

        XCTAssertEqual(Timestamp(2019, 03, 20, 21, 58).getSunDeclination(), 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2019, 06, 21, 15, 54).getSunDeclination() - 23.44, 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2019, 09, 23, 07, 50).getSunDeclination(), 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2019, 12, 22, 04, 19).getSunDeclination() + 23.44, 0, accuracy: 0.02)

        XCTAssertEqual(Timestamp(2020, 03, 20, 03, 50).getSunDeclination(), 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2020, 06, 20, 21, 43).getSunDeclination() - 23.44, 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2020, 09, 22, 13, 31).getSunDeclination(), 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2020, 12, 21, 10, 03).getSunDeclination() + 23.44, 0, accuracy: 0.02)

        XCTAssertEqual(Timestamp(2021, 03, 20, 09, 37).getSunDeclination(), 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2021, 06, 21, 03, 32).getSunDeclination() - 23.44, 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2021, 09, 22, 19, 21).getSunDeclination(), 0, accuracy: 0.02)
        XCTAssertEqual(Timestamp(2021, 12, 21, 15, 59).getSunDeclination() + 23.44, 0, accuracy: 0.02)

        XCTAssertEqual(Timestamp(2023, 3, 20, 12, 25).getSunDeclination(), -0.1483404, accuracy: 0.01)

        // reference https://gml.noaa.gov/grad/solcalc/azel.html
        let p = Timestamp(2022, 1, 1, 12).getSunDeclination()
        let e = Timestamp(2022, 1, 1, 12).getSunEquationOfTime()
        XCTAssertEqual(p, -22.977999, accuracy: 0.02)
        XCTAssertEqual(e * 60, -3.5339856, accuracy: 0.05)

        let p2 = Timestamp(2024, 1, 1, 12).getSunDeclination()
        let e2 = Timestamp(2024, 1, 1, 12).getSunEquationOfTime()
        XCTAssertEqual(p2, -23.018219, accuracy: 0.02)
        XCTAssertEqual(e2 * 60, -3.3114738, accuracy: 0.05)

        let p3 = Timestamp(2022, 7, 1, 12).getSunDeclination()
        let e3 = Timestamp(2022, 7, 1, 12).getSunEquationOfTime()
        XCTAssertEqual(p3, 23.08617, accuracy: 0.001)
        XCTAssertEqual(e3 * 60, -3.9086208, accuracy: 0.02)
    }

    func testSolarInterpolation() {
        let samples = 4
        let directRadiation = [Float(0.0), 0.0, 0.0, 0.0, 0.0, 0.0, 7.0, 116.0, 305.0, 485.0, 615.0, 680.0, 681.0, 579.0, 428.0, 272.0, 87.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let time = TimerangeDt(start: Timestamp(2022, 7, 31), nTime: 24, dtSeconds: 3600)
        let dtNew = time.dtSeconds / samples
        let timeNew = time.range.add(-time.dtSeconds + dtNew).range(dtSeconds: dtNew)
        XCTAssertEqual(timeNew.range.lowerBound.iso8601_YYYY_MM_dd_HH_mm, "2022-07-30T23:15")

        // test coefficients
        /*let position = RegularGrid(nx: 1, ny: 1, latMin: -22.5, lonMin: 17, dx: 1, dy: 1)
        let solarLow = Zensun.calculateRadiationBackwardsAveraged(grid: position, locationRange: 0..<1, timerange: time).data
        let solar = Zensun.calculateRadiationBackwardsAveraged(grid: position, locationRange: 0..<1, timerange: timeNew).data
        let solb = solar.mean(by: samples)
        // very small differences at sunrise/set
        XCTAssertEqualArray(solb, solarLow, accuracy: 0.0001)*/

        let interpolated = directRadiation.interpolateSolarBackwards(timeOld: time, timeNew: timeNew, latitude: -22.5, longitude: 17, scalefactor: 10000)
        let averaged = interpolated.mean(by: samples)

        // It is not the same, but it is relatively close without any time shift
        XCTAssertEqualArray(averaged, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 6.903125, 117.9211, 305.77502, 484.58722, 614.3561, 680.2455, 677.99414, 578.95483, 430.6342, 270.31412, 90.66743, 3.6926, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], accuracy: 0.01)
    }

    func testSolarGapfilling() {
        let time = TimerangeDt(start: Timestamp(2020, 12, 26, 0), nTime: 48, dtSeconds: 3600)
        let position = RegularGrid(nx: 1, ny: 1, latMin: 47.5, lonMin: 7, dx: 1, dy: 1)
        /// 60% ex rad
        let reference = Zensun.extraTerrestrialRadiationBackwards(latitude: position.latMin, longitude: position.lonMin, timerange: time).map { $0 * 0.6 }
        var averagedWithNaNs = reference
        for i in 0..<20 {
            averagedWithNaNs[7 + i * 2 + 1] = averagedWithNaNs[7 + i * 2..<9 + i * 2].mean()
            averagedWithNaNs[7 + i * 2] = .nan
        }
        averagedWithNaNs.interpolateInplaceSolarBackwards(time: time, grid: position, locationRange: 0..<1, missingValuesAreBackwardsAveraged: true)
        XCTAssertEqualArray(reference, averagedWithNaNs, accuracy: 0.001)

        averagedWithNaNs = reference
        for i in 0..<13 {
            averagedWithNaNs[7 + i * 3 + 2] = averagedWithNaNs[7 + i * 3..<10 + i * 3].mean()
            averagedWithNaNs[7 + i * 3 + 1] = .nan
            averagedWithNaNs[7 + i * 3] = .nan
        }
        print(averagedWithNaNs)
        averagedWithNaNs.interpolateInplaceSolarBackwards(time: time, grid: position, locationRange: 0..<1, missingValuesAreBackwardsAveraged: true)
        XCTAssertEqualArray(reference, averagedWithNaNs, accuracy: 0.01)
    }

    func testDNI() {
        let directRadiation = [Float(0.0), 0.0, 0.0, 0.0, 0.0, 0.0, 7.0, 116.0, 305.0, 485.0, 615.0, 680.0, 681.0, 579.0, 428.0, 272.0, 87.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let time = TimerangeDt(start: Timestamp(2022, 7, 31), nTime: 24, dtSeconds: 3600)
        let dni = Zensun.calculateBackwardsDNISupersampled(directRadiation: directRadiation, latitude: -22.5, longitude: 17, timerange: time, samples: 4)
        XCTAssertEqualArray(dni, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 94.52869, 510.3472, 726.8794, 836.6179, 888.55334, 908.3525, 907.0859, 842.14484, 752.32007, 655.86975, 405.88232, 23.293142, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], accuracy: 0.01)

        /// Analytical solution is fairly close to supersampled solution. Smaller difference at sun rise/set
        let dni2 = Zensun.calculateBackwardsDNI(directRadiation: directRadiation, latitude: -22.5, longitude: 17, timerange: time)
        XCTAssertEqualArray(dni2, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 75.31125, 525.6262, 730.035, 838.7038, 889.7469, 908.00757, 911.16675, 843.0275, 749.2078, 665.61414, 414.24997, 34.339397, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], accuracy: 0.01)
    }

    func testGTI() {
        let directRadiation = [Float(0.0), 0.0, 0.0, 0.0, 0.0, 0.0, 7.0, 116.0, 305.0, 485.0, 615.0, 680.0, 681.0, 579.0, 428.0, 272.0, 87.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let diffuseRadiation = [Float(0.0), 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 130.0, 118.0, 224.0, 315.0, 316.0, 318.0, 280.0, 215.0, 139.0, 40.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let time = TimerangeDt(start: Timestamp(2022, 7, 31), nTime: 24, dtSeconds: 3600)
        let gti = Zensun.calculateTiltedIrradiance(directRadiation: directRadiation, diffuseRadiation: diffuseRadiation, tilt: 45, azimuth: 0, latitude: -22.5, longitude: 17, timerange: time, convertBackwardsToInstant: false)
        XCTAssertEqualArray(gti, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.9707108, 118.167114, 113.10868, 211.9621, 336.0515, 361.00406, 362.58548, 300.82724, 202.34702, 130.68182, 37.861877, 0.9707107, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], accuracy: 0.01)

        let gtiInstant = Zensun.calculateTiltedIrradiance(directRadiation: directRadiation, diffuseRadiation: diffuseRadiation, tilt: 45, azimuth: 0, latitude: -22.5, longitude: 17, timerange: time, convertBackwardsToInstant: true)
        XCTAssertEqualArray(gtiInstant, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.3991673, 173.6138, 136.74342, 235.82225, 354.7455, 365.43063, 352.53616, 279.27585, 176.0145, 100.48777, 18.381083, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], accuracy: 0.01)

        let gtiTrackHorizontal = Zensun.calculateTiltedIrradiance(directRadiation: directRadiation, diffuseRadiation: diffuseRadiation, tilt: 45, azimuth: .nan, latitude: -22.5, longitude: 17, timerange: time, convertBackwardsToInstant: false)
        XCTAssertEqualArray(gtiTrackHorizontal, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 59.943016, 562.7015, 797.77844, 1038.7473, 1185.6353, 1205.2142, 1210.2856, 1106.8444, 939.80383, 752.5833, 385.76633, 27.280811, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], accuracy: 0.01)

        let gtiTrackVertical = Zensun.calculateTiltedIrradiance(directRadiation: directRadiation, diffuseRadiation: diffuseRadiation, tilt: .nan, azimuth: 0, latitude: -22.5, longitude: 17, timerange: time, convertBackwardsToInstant: false)
        XCTAssertEqualArray(gtiTrackVertical, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.9092948, 98.51584, 108.27706, 206.66702, 316.56372, 418.15967, 417.75742, 277.57715, 196.47887, 122.20553, 34.23313, 0.90873635, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], accuracy: 0.01)

        let gtiBiAxialTracking = Zensun.calculateTiltedIrradiance(directRadiation: directRadiation, diffuseRadiation: diffuseRadiation, tilt: .nan, azimuth: .nan, latitude: -22.5, longitude: 17, timerange: time, convertBackwardsToInstant: false)
        XCTAssertEqualArray(gtiBiAxialTracking, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 77.22054, 624.142, 838.312, 1045.3708, 1184.8297, 1209.3428, 1214.2375, 1106.0839, 945.6867, 787.8196, 448.4831, 35.248135, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], accuracy: 0.01)
    }

    func testDiffuseRadiation() {
        let directRadiation = [Float(0.0), 0.0, 0.0, 0.0, 0.0, 0.0, 7.0, 116.0, 305.0, 485.0, 615.0, 680.0, 681.0, 579.0, 428.0, 272.0, 87.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let diffuseRadiation = [Float(0.0), 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 130.0, 118.0, 224.0, 315.0, 316.0, 318.0, 280.0, 215.0, 139.0, 40.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        let swrad = zip(directRadiation, diffuseRadiation).map(+)
        let time = TimerangeDt(start: Timestamp(2022, 7, 31), nTime: 24, dtSeconds: 3600)
        let diff = Zensun.calculateDiffuseRadiationBackwards(shortwaveRadiation: swrad, latitude: -22.5, longitude: 17, timerange: time)
        // Note: Differences to the actual diffuse radiation are expected!
        XCTAssertEqualArray(diff, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 9.287625, 116.9848, 133.84239, 166.59798, 219.15633, 200.51555, 205.13588, 167.13881, 146.30597, 132.74532, 84.49708, 4.2427073, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], accuracy: 0.01)
    }

    func testSarahInterpolation() {
        let time = TimerangeDt(start: Timestamp(2006, 5, 18), nTime: 24 * 2, dtSeconds: 1800)
        let grid = RegularGrid(nx: 1, ny: 1, latMin: 52.25, lonMin: 21, dx: 1, dy: 1)
        var rad = [0.0, 0.0, 0.0, 1.0, 4.0, 23.0, 113.0, 190.0, 284.0, 287.0, 407.0, 568.0, 638.0, 691.0, 706.0, 738.0, 692.0, 559.0, 361.0, 380.0, 420.0, 700.0, 631.0, 659.0, 502.0, 464.0, Float.nan, .nan, .nan, .nan, .nan, .nan, 62.0, 34.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        rad.interpolateInplaceSolarBackwards(time: time, grid: grid, locationRange: 0..<1, missingValuesAreBackwardsAveraged: false)
        XCTAssertEqualArray(rad, [0.0, 0.0, 0.0, 1.0, 4.0, 23.0, 113.0, 190.0, 284.0, 287.0, 407.0, 568.0, 638.0, 691.0, 706.0, 738.0, 692.0, 559.0, 361.0, 380.0, 420.0, 700.0, 631.0, 659.0, 502.0, 464.0, 415.3082, 348.894, 275.25363, 203.68459, 141.54568, 93.67375, 62.0, 34.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], accuracy: 0.01)
    }
    
    func test3to6HourlyInterpolation() {
        // data contains 2 locations times 2 members. 4 series in total
        // First step is NaN as usual for model data
        var rad: [Float] = [Float.nan, 0.0, 0.0, 0.0, 210.0, 504.0, 336.0, 51.0, 0.0, 0.0, 0.0, 0.0, 197.0, 564.0, 441.0, 50.0, 0.0, 0.0, 0.0, 0.0, 215.0, 567.0, 442.0, 45.0, 0.0, 0.0, 0.0, 0.0, 189.0, 474.0, 330.0, 34.0, 0.0, 0.0, 0.0, 0.0, 153.0, 481.0, 336.0, 39.0, 0.0, 0.0, 0.0, 0.0, 191.0, 520.0, 402.0, 42.0, 0.0, .nan, 0.0, .nan, 63.0, .nan, 347.0, .nan, 20.0, .nan, 0.0, .nan, 95.0, .nan, 422.0, .nan, 20.0, .nan, 0.0, .nan, 91.0, .nan, 336.0, .nan, 14.0, .nan, 0.0, .nan, 81.0, .nan, 338.0, .nan, 10.0, .nan, 0.0, .nan, 94.0, .nan, 465.0, .nan, 19.0, .nan, 0.0, .nan, 87.0, .nan, 405.0, .nan, 17.0, .nan, 0.0, .nan, 66.0, .nan, 347.0, .nan, 15.0, .nan, 0.0, .nan, 49.0, .nan, 306.0, .nan, 14.0, .nan, 0.0, .nan, 86.0, .nan, 407.0, .nan, 14.0, .nan, 0.0, 0.0, 0.0, 210.0, 504.0, 336.0, 51.0, 0.0, 0.0, 0.0, 0.0, 197.0, 564.0, 441.0, 50.0, 0.0, 0.0, 0.0, 0.0, 215.0, 567.0, 442.0, 45.0, 0.0, 0.0, 0.0, 0.0, 189.0, 474.0, 330.0, 34.0, 0.0, 0.0, 0.0, 0.0, 153.0, 481.0, 336.0, 39.0, 0.0, 0.0, 0.0, 0.0, 191.0, 520.0, 402.0, 42.0, 0.0, .nan, 0.0, .nan, 63.0, .nan, 347.0, .nan, 20.0, .nan, 0.0, .nan, 95.0, .nan, 422.0, .nan, 20.0, .nan, 0.0, .nan, 91.0, .nan, 336.0, .nan, 14.0, .nan, 0.0, .nan, 81.0, .nan, 338.0, .nan, 10.0, .nan, 0.0, .nan, 94.0, .nan, 465.0, .nan, 19.0, .nan, 0.0, .nan, 87.0, .nan, 405.0, .nan, 17.0, .nan, 0.0, .nan, 66.0, .nan, 347.0, .nan, 15.0, .nan, 0.0, .nan, 49.0, .nan, 306.0, .nan, 14.0, .nan, 0.0, .nan, 86.0, .nan, 407.0, .nan, 14.0,.nan, 0.0, 0.0, 0.0, 215.0, 501.0, 333.0, 49.0, 0.0, 0.0, 0.0, 0.0, 212.0, 565.0, 439.0, 48.0, 0.0, 0.0, 0.0, 0.0, 218.0, 568.0, 441.0, 46.0, 0.0, 0.0, 0.0, 0.0, 196.0, 513.0, 339.0, 29.0, 0.0, 0.0, 0.0, 0.0, 162.0, 484.0, 325.0, 39.0, 0.0, 0.0, 0.0, 0.0, 190.0, 515.0, 398.0, 41.0, 0.0, .nan, 0.0, .nan, 68.0, .nan, 310.0, .nan, 17.0, .nan, 0.0, .nan, 96.0, .nan, 419.0, .nan, 19.0, .nan, 0.0, .nan, 93.0, .nan, 333.0, .nan, 13.0, .nan, 0.0, .nan, 61.0, .nan, 314.0, .nan, 8.0, .nan, 0.0, .nan, 96.0, .nan, 459.0, .nan, 18.0, .nan, 0.0, .nan, 87.0, .nan, 404.0, .nan, 16.0, .nan, 0.0, .nan, 61.0, .nan, 332.0, .nan, 15.0, .nan, 0.0, .nan, 39.0, .nan, 279.0, .nan, 14.0, .nan, 0.0, .nan, 87.0, .nan, 380.0, .nan, 12.0, .nan, 0.0, 0.0, 0.0, 215.0, 501.0, 333.0, 49.0, 0.0, 0.0, 0.0, 0.0, 212.0, 565.0, 439.0, 48.0, 0.0, 0.0, 0.0, 0.0, 218.0, 568.0, 441.0, 46.0, 0.0, 0.0, 0.0, 0.0, 196.0, 513.0, 339.0, 29.0, 0.0, 0.0, 0.0, 0.0, 162.0, 484.0, 325.0, 39.0, 0.0, 0.0, 0.0, 0.0, 190.0, 515.0, 398.0, 41.0, 0.0, .nan, 0.0, .nan, 68.0, .nan, 310.0, .nan, 17.0, .nan, 0.0, .nan, 96.0, .nan, 419.0, .nan, 19.0, .nan, 0.0, .nan, 93.0, .nan, 333.0, .nan, 13.0, .nan, 0.0, .nan, 61.0, .nan, 314.0, .nan, 8.0, .nan, 0.0, .nan, 96.0, .nan, 459.0, .nan, 18.0, .nan, 0.0, .nan, 87.0, .nan, 404.0, .nan, 16.0, .nan, 0.0, .nan, 61.0, .nan, 332.0, .nan, 15.0, .nan, 0.0, .nan, 39.0, .nan, 279.0, .nan, 14.0, .nan, 0.0, .nan, 87.0, .nan, 380.0, .nan, 12.0]
        let time = TimerangeDt(start: Timestamp(2025, 4, 30, 12), nTime: 121, dtSeconds: 3*3600)
        /// ifs025 grid, 302260..<302262
        let grid = RegularGrid(nx: 1440, ny: 721, latMin: -90, lonMin: -180, dx: 360 / 1440, dy: 180 / (721 - 1))
        let range: any RandomAccessCollection<Int> = RegularGridSlice(grid: grid, yRange: 209..<209+1, xRange: 1300..<1300+2)
        XCTAssertEqual(range.map{$0}, [302260, 302261])
        rad.interpolateInplaceSolarBackwards(time: time, grid: grid, locationRange: range, missingValuesAreBackwardsAveraged: true)
        XCTAssertEqualArray(rad, [.nan, 0.0, 0.0, 0.0, 210.0, 504.0, 336.0, 51.0, 0.0, 0.0, 0.0, 0.0, 197.0, 564.0, 441.0, 50.0, 0.0, 0.0, 0.0, 0.0, 215.0, 567.0, 442.0, 45.0, 0.0, 0.0, 0.0, 0.0, 189.0, 474.0, 330.0, 34.0, 0.0, 0.0, 0.0, 0.0, 153.0, 481.0, 336.0, 39.0, 0.0, 0.0, 0.0, 0.0, 191.0, 520.0, 402.0, 42.0, 0.0, 0.0, 0.0, 0.0, 126.00001, 349.5491, 309.25827, 63.463787, 0.0, 0.0, 0.0, 0.0, 190.0, 470.11734, 375.76132, 71.304405, 0.0, 0.0, 0.0, 0.0, 182.0, 411.06235, 298.92218, 53.583794, 0.0, 0.0, 0.0, 0.0, 162.0, 391.9802, 300.4463, 50.16329, 0.0, 0.0, 0.0, 0.0, 188.0, 496.44165, 412.99677, 74.90041, 0.0, 0.0, 0.0, 0.0, 174.0, 444.32034, 359.42184, 65.00996, 0.0, 0.0, 0.0, 0.0, 132.0, 360.9896, 307.71442, 56.342964, 0.0, 0.0, 0.0, 0.0, 98.0, 296.8039, 271.1577, 50.74117, 0.0, 0.0, 0.0, 0.0, 172.0, 446.20398, 360.40485, 60.574318, 0.0, .nan, 0.0, 0.0, 0.0, 210.0, 504.0, 336.0, 51.0, 0.0, 0.0, 0.0, 0.0, 197.0, 564.0, 441.0, 50.0, 0.0, 0.0, 0.0, 0.0, 215.0, 567.0, 442.0, 45.0, 0.0, 0.0, 0.0, 0.0, 189.0, 474.0, 330.0, 34.0, 0.0, 0.0, 0.0, 0.0, 153.0, 481.0, 336.0, 39.0, 0.0, 0.0, 0.0, 0.0, 191.0, 520.0, 402.0, 42.0, 0.0, 0.0, 0.0, 0.0, 126.00001, 349.5491, 309.25827, 63.463787, 0.0, 0.0, 0.0, 0.0, 190.0, 470.11734, 375.76132, 71.304405, 0.0, 0.0, 0.0, 0.0, 182.0, 411.06235, 298.92218, 53.583794, 0.0, 0.0, 0.0, 0.0, 162.0, 391.9802, 300.4463, 50.16329, 0.0, 0.0, 0.0, 0.0, 188.0, 496.44165, 412.99677, 74.90041, 0.0, 0.0, 0.0, 0.0, 174.0, 444.32034, 359.42184, 65.00996, 0.0, 0.0, 0.0, 0.0, 132.0, 360.9896, 307.71442, 56.342964, 0.0, 0.0, 0.0, 0.0, 98.0, 296.8039, 271.1577, 50.74117, 0.0, 0.0, 0.0, 0.0, 172.0, 446.20398, 360.40485, 60.574318, 0.0, .nan, 0.0, 0.0, 0.0, 215.0, 501.0, 333.0, 49.0, 0.0, 0.0, 0.0, 0.0, 212.0, 565.0, 439.0, 48.0, 0.0, 0.0, 0.0, 0.0, 218.0, 568.0, 441.0, 46.0, 0.0, 0.0, 0.0, 0.0, 196.0, 513.0, 339.0, 29.0, 0.0, 0.0, 0.0, 0.0, 162.0, 484.0, 325.0, 39.0, 0.0, 0.0, 0.0, 0.0, 190.0, 515.0, 398.0, 41.0, 0.0, 0.0, 0.0, 0.0, 136.0, 339.36212, 275.48016, 54.694756, 0.0, 0.0, 0.0, 0.0, 192.0, 470.7092, 371.99835, 69.29764, 0.0, 0.0, 0.0, 0.0, 186.0, 413.9049, 295.37994, 51.644497, 0.0, 0.0, 0.0, 0.0, 121.99999, 331.919, 278.284, 45.768112, 0.0, 0.0, 0.0, 0.0, 192.0, 497.53537, 406.4484, 72.37207, 0.0, 0.0, 0.0, 0.0, 174.0, 443.9453, 357.45435, 63.340176, 0.0, 0.0, 0.0, 0.0, 122.00001, 339.82492, 293.5196, 54.228523, 0.0, 0.0, 0.0, 0.0, 78.0, 256.64536, 246.47684, 47.4395, 0.0, 0.0, 0.0, 0.0, 174.0, 432.45615, 335.4611, 54.94417, 0.0, .nan, 0.0, 0.0, 0.0, 215.0, 501.0, 333.0, 49.0, 0.0, 0.0, 0.0, 0.0, 212.0, 565.0, 439.0, 48.0, 0.0, 0.0, 0.0, 0.0, 218.0, 568.0, 441.0, 46.0, 0.0, 0.0, 0.0, 0.0, 196.0, 513.0, 339.0, 29.0, 0.0, 0.0, 0.0, 0.0, 162.0, 484.0, 325.0, 39.0, 0.0, 0.0, 0.0, 0.0, 190.0, 515.0, 398.0, 41.0, 0.0, 0.0, 0.0, 0.0, 136.0, 339.36212, 275.48016, 54.694756, 0.0, 0.0, 0.0, 0.0, 192.0, 470.7092, 371.99835, 69.29764, 0.0, 0.0, 0.0, 0.0, 186.0, 413.9049, 295.37994, 51.644497, 0.0, 0.0, 0.0, 0.0, 121.99999, 331.919, 278.284, 45.768112, 0.0, 0.0, 0.0, 0.0, 192.0, 497.53537, 406.4484, 72.37207, 0.0, 0.0, 0.0, 0.0, 174.0, 443.9453, 357.45435, 63.340176, 0.0, 0.0, 0.0, 0.0, 122.00001, 339.82492, 293.5196, 54.228523, 0.0, 0.0, 0.0, 0.0, 78.0, 256.64536, 246.47684, 47.4395, 0.0, 0.0, 0.0, 0.0, 174.0, 432.45615, 335.4611, 54.94417, 0.0], accuracy: 0.01)
    }
}
