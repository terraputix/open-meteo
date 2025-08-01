import Foundation
import Vapor
import OmFileFormat
import SwiftNetCDF

/**
NCEP GFS downloader
 */
struct GfsDownload: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "domain")
        var domain: String

        @Option(name: "run")
        var run: String?

        @Flag(name: "create-netcdf")
        var createNetcdf: Bool

        @Flag(name: "second-flush", help: "For GFS05 ensemble to download hours 390-840")
        var secondFlush: Bool

        @Option(name: "only-variables")
        var onlyVariables: String?

        @Flag(name: "upper-level", help: "Download upper-level variables on pressure levels")
        var upperLevel: Bool

        @Flag(name: "surface-level", help: "Download surface-level variables")
        var surfaceLevel: Bool

        @Option(name: "max-forecast-hour", help: "Only download data until this forecast hour")
        var maxForecastHour: Int?

        @Option(name: "timeinterval", short: "t", help: "Timeinterval to download past forecasts. Format 20220101-20220131")
        var timeinterval: String?

        @Option(name: "concurrent", short: "c", help: "Numer of concurrent download/conversion jobs")
        var concurrent: Int?

        @Option(name: "upload-s3-bucket", help: "Upload open-meteo database to an S3 bucket after processing")
        var uploadS3Bucket: String?

        @Flag(name: "upload-s3-only-probabilities", help: "Only upload probabilities files to S3")
        var uploadS3OnlyProbabilities: Bool

        @Flag(name: "skip-missing", help: "Ignore missing GRIB messages in inventory")
        var skipMissing: Bool

        @Flag(name: "download-from-aws", help: "Download GRIB files from AWS")
        var downloadFromAws: Bool
    }

    var help: String {
        "Download GFS from NOAA NCEP"
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let domain = try GfsDomain.load(rawValue: signature.domain)
        disableIdleSleep()

        if let timeinterval = signature.timeinterval {
            for run in try Timestamp.parseRange(yyyymmdd: timeinterval).toRange(dt: 86400).with(dtSeconds: 86400 / domain.runsPerDay) {
                try await downloadRun(using: context, signature: signature, run: run, domain: domain)
            }
            return
        }

        /// 18z run is available the day after starting 05:26
        let run = try signature.run.flatMap(Timestamp.fromRunHourOrYYYYMMDD) ?? domain.lastRun
        try await downloadRun(using: context, signature: signature, run: run, domain: domain)
    }

    func downloadRun(using context: CommandContext, signature: Signature, run: Timestamp, domain: GfsDomain) async throws {
        let start = DispatchTime.now()
        let logger = context.application.logger
        disableIdleSleep()

        if signature.onlyVariables != nil && signature.upperLevel {
            fatalError("Parameter 'onlyVariables' and 'upperLevel' must not be used simultaneously")
        }

        let variables: [any GfsVariableDownloadable]

        switch domain {
        case .gfs05_ens, .gfs025_ens, .gfs013, .hrrr_conus_15min, .hrrr_conus, .gfs025:
            let onlyVariables: [any GfsVariableDownloadable]? = try signature.onlyVariables.map {
                try $0.split(separator: ",").map {
                    if let variable = GfsPressureVariable(rawValue: String($0)) {
                        return variable
                    }
                    return try GfsSurfaceVariable.load(rawValue: String($0))
                }
            }

            let pressureVariables = domain.levels.reversed().flatMap { level in
                GfsPressureVariableType.allCases.map { variable in
                    GfsPressureVariable(variable: variable, level: level)
                }
            }
            let surfaceVariables = GfsSurfaceVariable.allCases

            variables = onlyVariables ?? (signature.upperLevel ? (signature.surfaceLevel ? surfaceVariables + pressureVariables : pressureVariables) : surfaceVariables)

            let handles = try await downloadGfs(application: context.application, domain: domain, run: run, variables: variables, secondFlush: signature.secondFlush, maxForecastHour: signature.maxForecastHour, skipMissing: signature.skipMissing, downloadFromAws: signature.downloadFromAws, uploadS3Bucket: signature.uploadS3Bucket)

            let nConcurrent = signature.concurrent ?? 1
            try await GenericVariableHandle.convert(logger: logger, domain: domain, createNetcdf: signature.createNetcdf, run: run, handles: handles, concurrent: nConcurrent, writeUpdateJson: true, uploadS3Bucket: signature.uploadS3Bucket, uploadS3OnlyProbabilities: signature.uploadS3OnlyProbabilities, generateFullRun: !signature.secondFlush)
        case .gfswave025, .gfswave025_ens, .gfswave016:
            variables = GfsWaveVariable.allCases
            let handles = try await downloadGfs(application: context.application, domain: domain, run: run, variables: variables, secondFlush: signature.secondFlush, maxForecastHour: signature.maxForecastHour, skipMissing: signature.skipMissing, downloadFromAws: signature.downloadFromAws, uploadS3Bucket: signature.uploadS3Bucket)
            let nConcurrent = signature.concurrent ?? 1
            try await GenericVariableHandle.convert(logger: logger, domain: domain, createNetcdf: signature.createNetcdf, run: run, handles: handles, concurrent: nConcurrent, writeUpdateJson: true, uploadS3Bucket: signature.uploadS3Bucket, uploadS3OnlyProbabilities: signature.uploadS3OnlyProbabilities, generateFullRun: !signature.secondFlush)
        }
        logger.info("Finished in \(start.timeElapsedPretty())")
    }

    func downloadNcepElevation(application: Application, url: [String], surfaceElevationFileOm: OmFileManagerReadable, grid: Gridable, isGlobal: Bool) async throws {
        let logger = application.logger

        /// download seamask and height
        if FileManager.default.fileExists(atPath: surfaceElevationFileOm.getFilePath()) {
            return
        }
        try surfaceElevationFileOm.createDirectory()

        logger.info("Downloading height and elevation data")

        enum ElevationVariable: String, CurlIndexedVariable, CaseIterable {
            case height
            case landmask

            var gribIndexName: String? {
                switch self {
                case .height:
                    return ":HGT:surface:"
                case .landmask:
                    return ":LAND:surface:"
                }
            }

            var exactMatch: Bool {
                return false
            }
        }

        var height: Array2D?
        var landmask: Array2D?
        let curl = Curl(logger: logger, client: application.dedicatedHttpClient)
        var grib2d = GribArray2D(nx: grid.nx, ny: grid.ny)
        for (variable, message) in try await curl.downloadIndexedGrib(url: url, variables: ElevationVariable.allCases) {
            try grib2d.load(message: message)
            if isGlobal {
                grib2d.array.shift180LongitudeAndFlipLatitude()
            }
            switch variable {
            case .height:
                height = grib2d.array
            case .landmask:
                landmask = grib2d.array
            }
        }

        guard var height = height, let landmask = landmask else {
            fatalError("Could not download land and sea mask")
        }
        for i in height.data.indices {
            // landmask: 0=sea, 1=land
            height.data[i] = landmask.data[i] == 1 ? height.data[i] : -999
        }

        try height.data.writeOmFile2D(file: surfaceElevationFileOm.getFilePath(), grid: grid, createNetCdf: false)
    }

    /// download GFS025 and NAM CONUS
    func downloadGfs(application: Application, domain: GfsDomain, run: Timestamp, variables: [any GfsVariableDownloadable], secondFlush: Bool, maxForecastHour: Int?, skipMissing: Bool, downloadFromAws: Bool, uploadS3Bucket: String?) async throws -> [GenericVariableHandle] {
        let logger = application.logger

        // GFS025 ensemble does not have elevation information, use non-ensemble version
        let elevationUrl = (domain == .gfs025_ens ? GfsDomain.gfs025 : domain).getGribUrl(run: run, forecastHour: 0, member: 0, useAws: downloadFromAws)
        if ![GfsDomain.hrrr_conus_15min, .gfswave025, .gfswave025_ens, .gfswave016].contains(domain) {
            // 15min hrrr data uses hrrr domain elevation files
            try await downloadNcepElevation(application: application, url: elevationUrl, surfaceElevationFileOm: domain.surfaceElevationFileOm, grid: domain.grid, isGlobal: domain.isGlobal)
        }

        let deadLineHours: Double
        switch domain {
        case .gfs013:
            deadLineHours = 6
        case .gfs025, .gfswave025, .gfswave016:
            deadLineHours = 5
        case .hrrr_conus_15min:
            deadLineHours = 2
        case .hrrr_conus:
            deadLineHours = 2
        case .gfs025_ens, .gfswave025_ens:
            deadLineHours = 8
        case .gfs05_ens:
            deadLineHours = secondFlush ? 16 : 8
        }
        let waitAfterLastModified: TimeInterval = domain == .gfs025 ? 180 : 120
        let curl = Curl(logger: logger, client: application.dedicatedHttpClient, deadLineHours: deadLineHours, waitAfterLastModified: waitAfterLastModified)
        Process.alarm(seconds: Int(deadLineHours + 2) * 3600)
        defer { Process.alarm(seconds: 0) }

        //let storeOnDisk = domain == .gfs013 || domain == .gfs025 || domain == .hrrr_conus
        let isEnsemble = domain.ensembleMembers > 1

        var grib2d = GribArray2D(nx: domain.grid.nx, ny: domain.grid.ny)
        
        /// Domain elevation field. Used to calculate sea level pressure from surface level pressure in ICON EPS and ICON EU EPS
        let domainElevation = await {
            guard let elevation = try? await domain.getStaticFile(type: .elevation, httpClient: curl.client, logger: logger)?.read(range: nil) else {
                fatalError("cannot read elevation for domain \(domain)")
            }
            return elevation
        }()

        // Download HRRR 15 minutes data
        if domain == .hrrr_conus_15min {
            let handles = try await (0...(maxForecastHour ?? 18)).asyncFlatMap { forecastHour in
                logger.info("Downloading forecastHour \(forecastHour)")

                /// Keep variables in memory. Precip + Frozen percent to calculate snowfall
                let inMemory = VariablePerMemberStorage<GfsSurfaceVariable>()

                let variables: [GfsVariableAndDomain] = (variables.flatMap({ v in
                    return forecastHour == 0 ? [GfsVariableAndDomain(variable: v, domain: domain, timestep: 0)] : (0..<4).map {
                        GfsVariableAndDomain(variable: v, domain: domain, timestep: (forecastHour - 1) * 60 + ($0 + 1) * 15)
                    }
                }))
                
                let writer = OmSpatialMultistepWriter(domain: domain, run: run, storeOnDisk: true, realm: nil)

                let url = domain.getGribUrl(run: run, forecastHour: forecastHour, member: 0, useAws: downloadFromAws)
                for (variable, message) in try await curl.downloadIndexedGrib(url: url, variables: variables, errorOnMissing: !skipMissing) {
                    try grib2d.load(message: message)
                    guard let timestep = variable.timestep else {
                        continue
                    }
                    let timestamp = run.add(timestep * 60)
                    if let fma = variable.variable.multiplyAdd(domain: domain) {
                        grib2d.array.data.multiplyAdd(multiply: fma.multiply, add: fma.add)
                    }

                    if let surface = variable.variable as? GfsSurfaceVariable {
                        if [GfsSurfaceVariable.precipitation, .frozen_precipitation_percent].contains(surface) {
                            await inMemory.set(variable: surface, timestamp: timestamp, member: 0, data: grib2d.array)
                        }
                        if surface == .frozen_precipitation_percent {
                            continue // do not store frozen precip on disk
                        }
                    }

                    // HRRR_15min data has backwards averaged radiation, but diffuse radiation is still instantanous
                    if let variable = variable.variable as? GfsSurfaceVariable, variable == .diffuse_radiation {
                        let factor = Zensun.backwardsAveragedToInstantFactor(grid: domain.grid, locationRange: 0..<domain.grid.count, timerange: TimerangeDt(start: timestamp, nTime: 1, dtSeconds: domain.dtSeconds))
                        for i in grib2d.array.data.indices {
                            if factor.data[i] < 0.05 {
                                continue
                            }
                            grib2d.array.data[i] /= factor.data[i]
                        }
                    }
                    try await writer.write(time: timestamp, member: 0, variable: variable.variable, data: grib2d.array.data)
                }
                for writer in await writer.writer {
                    try await inMemory.calculateSnowfallAmount(precipitation: .precipitation, frozen_precipitation_percent: .frozen_precipitation_percent, outVariable: GfsSurfaceVariable.snowfall_water_equivalent, writer: writer)
                }
                let completed = forecastHour == 18
                let validTimes = TimerangeDt(start: run, nTime: (forecastHour+1)*4, dtSeconds: 900).map({$0})
                return try await writer.finalise(completed: completed, validTimes: validTimes, uploadS3Bucket: uploadS3Bucket)
            }
            await curl.printStatistics()
            return handles
        }

        let variables: [GfsVariableAndDomain] = variables.map {
            GfsVariableAndDomain(variable: $0, domain: domain, timestep: nil)
        }
        // let variables = variablesAll.filter({ !$0.variable.isLeastCommonlyUsedParameter })

        let variablesHour0 = variables.filter({ !$0.variable.skipHour0(for: domain) })

        /// Keep values from previous timestep. Actori isolated, because of concurrent data conversion
        let deaverager = GribDeaverager()

        /// Variables that are kept in memory
        /// For GFS013, keep pressure and temperature in memory to convert specific humidity to relative
        let keepVariableInMemory: [GfsSurfaceVariable] = domain == .gfs013 ? [.temperature_2m, .pressure_msl] : []
        /// Keep pressure level temperature in memory to convert pressure vertical velocity (Pa/s) to geometric velocity (m/s)
        let keepVariableInMemoryPressure: [GfsPressureVariableType] = (domain == .hrrr_conus || domain == .gfs05_ens) ? [.temperature] : []

        var forecastHours = domain.forecastHours(run: run.hour, secondFlush: secondFlush)
        if let maxForecastHour {
            forecastHours = forecastHours.filter({ $0 <= maxForecastHour })
        }
        let timestamps = forecastHours.map { run.add(hours: $0) }
        
        let handles = try await timestamps.enumerated().asyncFlatMap { (i,timestamp) in
            let forecastHour = (timestamp.timeIntervalSince1970 - run.timeIntervalSince1970) / 3600
            logger.info("Downloading forecastHour \(forecastHour)")

            let storePrecipMembers = VariablePerMemberStorage<GfsSurfaceVariable>()
            
            let writer = OmSpatialTimestepWriter(domain: domain, run: run, time: timestamp, storeOnDisk: !isEnsemble, realm: nil)
            let writerProbabilities = isEnsemble ? OmSpatialTimestepWriter(domain: domain, run: run, time: timestamp, storeOnDisk: true, realm: nil) : nil

            for member in 0..<domain.ensembleMembers {
                let variables = (forecastHour == 0 ? variablesHour0 : variables)
                let url = domain.getGribUrl(run: run, forecastHour: forecastHour, member: member, useAws: downloadFromAws)
                
                /// Keep data from previous timestep in memory to deaverage the next timestep
                var inMemorySurface = [GfsSurfaceVariable: [Float]]()
                var inMemoryPressure = [GfsPressureVariable: [Float]]()
                /// Keep variables in memory. Precip + Frozen percent to calculate snowfall
                let inMemory = VariablePerMemberStorage<GfsSurfaceVariable>()
                
                for (variable, message) in try await curl.downloadIndexedGrib(url: url, variables: variables, errorOnMissing: !skipMissing) {
                    if skipMissing {
                        // for whatever reason, the `hrrr.t10z.wrfprsf01.grib2` file uses different grib dimensions
                        guard let nx = message.get(attribute: "Nx")?.toInt() else {
                            fatalError("Could not get Nx")
                        }
                        guard let ny = message.get(attribute: "Ny")?.toInt() else {
                            fatalError("Could not get Ny")
                        }
                        if domain.grid.nx != nx || domain.grid.ny != ny {
                            logger.warning("GRIB dimensions (nx=\(nx), ny=\(ny)) do not match domain grid dimensions (nx=\(domain.grid.nx), ny=\(domain.grid.ny)). Skipping")
                            continue
                        }
                    }
                    try grib2d.load(message: message)
                    if domain.isGlobal {
                        grib2d.array.shift180LongitudeAndFlipLatitude()
                    }
                    // try message.debugGrid(grid: domain.grid, flipLatidude: domain.isGlobal, shift180Longitude: domain.isGlobal)
                    
                    guard let shortName = message.get(attribute: "shortName"),
                          let stepRange = message.get(attribute: "stepRange"),
                          let stepType = message.get(attribute: "stepType") else {
                        fatalError("could not get step range or type")
                    }
                    
                    /// Generate land mask from regular data for GFS Wave013
                    if domain == .gfswave016 && !domain.surfaceElevationFileOm.exists() {
                        let height = Array2D(data: grib2d.array.data.map { $0.isNaN ? 0 : -999 }, nx: domain.grid.nx, ny: domain.grid.ny)
                        try height.data.writeOmFile2D(file: domain.surfaceElevationFileOm.getFilePath(), grid: domain.grid, createNetCdf: false)
                    }
                    
                    // Deaccumulate precipitation
                    guard await deaverager.deaccumulateIfRequired(variable: variable.variable, member: member, stepType: stepType, stepRange: stepRange, grib2d: &grib2d) else {
                        continue
                    }
                    
                    // Convert specific humidity to relative humidity
                    if let variable = variable.variable as? GfsSurfaceVariable,
                       variable == .relative_humidity_2m,
                       shortName == "2sh" {
                        guard let temperature = inMemorySurface[.temperature_2m] else {
                            fatalError("Could not get temperature 2m to convert specific humidity")
                        }
                        // gfs013 loads surface pressure instead of msl, however we do not use it, because it is not corrected
                        guard let surfacePressure = inMemorySurface[.pressure_msl] else {
                            fatalError("Could not get surface_pressure to convert specific humidity")
                        }
                        grib2d.array.data.multiplyAdd(multiply: 1000, add: 0) // kg/kg to g/kg
                        grib2d.array.data = Meteorology.specificToRelativeHumidity(specificHumidity: grib2d.array.data, temperature: temperature, pressure: surfacePressure)
                    }
                    
                    // Convert pressure vertical velocity to geometric velocity in HRRR
                    if let variable = variable.variable as? GfsPressureVariable,
                       variable.variable == .vertical_velocity,
                       shortName == "w" {
                        guard let temperature = inMemoryPressure[.init(variable: .temperature, level: variable.level)] else {
                            fatalError("Could not get temperature 2m to convert pressure vertical velocity to geometric velocity")
                        }
                        grib2d.array.data = Meteorology.verticalVelocityPressureToGeometric(omega: grib2d.array.data, temperature: temperature, pressureLevel: Float(variable.level))
                    }
                    
                    // HRRR contains instantanous values for solar flux. Convert it to backwards averaged.
                    if let variable = variable.variable as? GfsSurfaceVariable {
                        if domain == .hrrr_conus && [.shortwave_radiation, .diffuse_radiation].contains(variable) {
                            let factor = Zensun.backwardsAveragedToInstantFactor(grid: domain.grid, locationRange: 0..<domain.grid.count, timerange: TimerangeDt(start: timestamp, nTime: 1, dtSeconds: domain.dtSeconds))
                            for i in grib2d.array.data.indices {
                                if factor.data[i] < 0.05 {
                                    continue
                                }
                                grib2d.array.data[i] /= factor.data[i]
                            }
                        }
                    }
                    
                    // Cloud cover in GFS ensemble may be -1 or 101 or 102
                    if [GfsDomain.gfs025_ens, .gfs05_ens].contains(domain), let variable = variable.variable as? GfsSurfaceVariable, variable == .cloud_cover {
                        for i in grib2d.array.data.indices {
                            if grib2d.array.data[i] > 100 {
                                grib2d.array.data[i] = 100
                            }
                            if grib2d.array.data[i] < 0 {
                                grib2d.array.data[i] = 0
                            }
                        }
                    }
                    
                    // Scaling before compression with scalefactor
                    if let fma = variable.variable.multiplyAdd(domain: domain) {
                        grib2d.array.data.multiplyAdd(multiply: fma.multiply, add: fma.add)
                    }
                    
                    if let surface = variable.variable as? GfsSurfaceVariable {
                        if [GfsSurfaceVariable.precipitation, .frozen_precipitation_percent].contains(surface) {
                            await inMemory.set(variable: surface, timestamp: timestamp, member: member, data: grib2d.array)
                        }
                        if surface == .frozen_precipitation_percent {
                            continue // do not store frozen precip on disk
                        }
                    }
                    
                    /// GFS Waves may show NaN values on water if there are no waves -> set to 0 instead of NaN
                    if domain == .gfswave016 || domain == .gfswave025 {
                        for i in grib2d.array.data.indices {
                            if domainElevation[i] <= -999 && grib2d.array.data[i].isNaN {
                                grib2d.array.data[i] = 0
                            }
                        }
                    }

                    // Keep temperature and pressure in memory to relative humidity conversion
                    if let variable = variable.variable as? GfsSurfaceVariable,
                        keepVariableInMemory.contains(variable) {
                        inMemorySurface[variable] = grib2d.array.data
                    }
                    if let variable = variable.variable as? GfsPressureVariable,
                        keepVariableInMemoryPressure.contains(variable.variable) {
                        inMemoryPressure[variable] = grib2d.array.data
                    }

                    if let variable = variable.variable as? GfsSurfaceVariable, variable == .precipitation {
                        await storePrecipMembers.set(variable: variable, timestamp: timestamp, member: member, data: grib2d.array)
                    }

                    if domain == .gfs013 && variable.variable as? GfsSurfaceVariable == .pressure_msl {
                        // do not write pressure to disk
                        continue
                    }
                    try await writer.write(member: member, variable: variable.variable, data: grib2d.array.data)
                }
                try await inMemory.calculateSnowfallAmount(precipitation: .precipitation, frozen_precipitation_percent: .frozen_precipitation_percent, outVariable: GfsSurfaceVariable.snowfall_water_equivalent, writer: writer)
            }
            
            if let writerProbabilities {
                let previousHour = (timestamps[max(0, i-1)].timeIntervalSince1970 - run.timeIntervalSince1970) / 3600
                try await storePrecipMembers.calculatePrecipitationProbability(
                    precipitationVariable: .precipitation,
                    dtHoursOfCurrentStep: forecastHour - previousHour,
                    writer: writerProbabilities
                )
            }
            let completed = i == timestamps.count - 1
            return try await writer.finalise(completed: completed, validTimes: Array(timestamps[0...i]), uploadS3Bucket: uploadS3Bucket) + (writerProbabilities?.finalise(completed: completed, validTimes: Array(timestamps[0...i]), uploadS3Bucket: uploadS3Bucket) ?? [])
        }
        await curl.printStatistics()
        return handles
    }
}

/// Small helper structure to fuse domain and variable for more control in the gribindex selection
struct GfsVariableAndDomain: CurlIndexedVariable {
    let variable: any GfsVariableDownloadable
    let domain: GfsDomain
    let timestep: Int?

    var exactMatch: Bool {
        return false
    }

    var gribIndexName: String? {
        return variable.gribIndexName(for: domain, timestep: timestep)
    }
}

extension VariablePerMemberStorage {
    /// Snowfall is given in percent. Multiply with precipitation to get the amount. Note: For whatever reason it can be `-50%`.
    func calculateSnowfallAmount(precipitation: V, frozen_precipitation_percent: V, outVariable: GenericVariable, writer: OmSpatialTimestepWriter) async throws {
        for (t, handles) in self.data.groupedPreservedOrder(by: { $0.key.timestampAndMember }) {
            guard
                t.timestamp == writer.time,
                let precipitation = handles.first(where: { $0.key.variable == precipitation }),
                let frozen_precipitation_percent = handles.first(where: { $0.key.variable == frozen_precipitation_percent }) else {
                continue
            }
            let snowfall = zip(frozen_precipitation_percent.value.data, precipitation.value.data).map({
                max($0 / 100 * $1 * 0.7, 0)
            })
            try await writer.write(member: t.member, variable: outVariable, data: snowfall)
        }
    }
    
    /// Calculate relative humidity
    func calculateRelativeHumidity(temperature: V, dewpoint: V, outVariable: GenericVariable, writer: OmSpatialTimestepWriter) async throws {
        for (t, handles) in self.data.groupedPreservedOrder(by: { $0.key.timestampAndMember }) {
            guard
                t.timestamp == writer.time,
                let temperature = handles.first(where: { $0.key.variable == temperature }),
                let dewpoint = handles.first(where: { $0.key.variable == dewpoint }) else {
                continue
            }
            let rh = zip(temperature.value.data, dewpoint.value.data).map(Meteorology.relativeHumidity)
            try await writer.write(member: t.member, variable: outVariable, data: rh)
        }
    }
}
