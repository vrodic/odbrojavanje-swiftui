import SwiftUI
import Combine
import Foundation

// MARK: - Sun Events

enum SunEvent: Int, CaseIterable {
    case sunrise
    case sunset
    case civilDawn
    case civilDusk
    case nauticalDawn
    case nauticalDusk
    case astronomicalDawn
    case astronomicalDusk
    case solarNoon

    var name: String {
        switch self {
        case .sunrise: return "Sunrise"
        case .sunset: return "Sunset"
        case .civilDawn: return "Civil Dawn"
        case .civilDusk: return "Civil Dusk"
        case .nauticalDawn: return "Nautical Dawn"
        case .nauticalDusk: return "Nautical Dusk"
        case .astronomicalDawn: return "Astronomical Dawn"
        case .astronomicalDusk: return "Astronomical Dusk"
        case .solarNoon: return "Solar Noon"
        }
    }

    var zenith: Double {
        switch self {
        case .sunrise, .sunset:
            return 90.833
        case .civilDawn, .civilDusk:
            return 96
        case .nauticalDawn, .nauticalDusk:
            return 102
        case .astronomicalDawn, .astronomicalDusk:
            return 108
        case .solarNoon:
            return 90
        }
    }

    var isDawn: Bool {
        switch self {
        case .sunrise, .civilDawn, .nauticalDawn, .astronomicalDawn:
            return true
        default:
            return false
        }
    }
}

// MARK: - Model Structures

struct Coordinate: Codable {
    let latitude: Double
    let longitude: Double
}

struct Polygon {
    var coordinates: [Coordinate]
}

struct Country {
    var name: String
    var polygons: [Polygon]
}

struct GeoFeature: Codable {
    struct Geometry: Codable {
        let type: String
        let coordinates: [[[Double]]]?
        let multiCoordinates: [[[[Double]]]]?

        enum CodingKeys: String, CodingKey {
            case type
            case coordinates
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            if type == "Polygon" {
                coordinates = try container.decode([[[Double]]].self, forKey: .coordinates)
                multiCoordinates = nil
            } else if type == "MultiPolygon" {
                multiCoordinates = try container.decode([[[[Double]]]].self, forKey: .coordinates)
                coordinates = nil
            } else {
                coordinates = nil
                multiCoordinates = nil
            }
        }
    }

    struct Properties: Codable {
        let name: String?
    }

    let geometry: Geometry
    let properties: Properties
}

struct GeoJSONRoot: Codable {
    let features: [GeoFeature]
}

// MARK: - View Model

class OdbrojavanjeViewModel: ObservableObject {
    @Published var targetDate: Date = Date() // Give a default value
    @Published var currentTime: Date = Date()
    @Published var intervalMilliseconds: Int = 1000
    @Published var logs: [String] = []
    @Published var selectedSunEvent: SunEvent = .sunrise
    @Published var latitude: Double = 45.8150
    @Published var longitude: Double = 15.9819
    @Published var worldMap: [Country] = []
    @Published var scale: CGFloat = 2.0
    @Published var offset: CGSize = .zero
    @Published var dayLineX: CGFloat = 100
    @Published var draggingLine = false

    private var startTime: Date
    private var timerCancellable: AnyCancellable?
    private var logLap: Int = 0

    init() {
        // Now all published properties have initial values, so 'self' is considered safe to use
        startTime = Date()

        // After properties are set, we can safely call getSunTime
        let now = Date()
        let todayEventTime = getSunTime(date: now, event: selectedSunEvent)
        let finalTarget: Date
        if todayEventTime <= now {
            if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) {
                finalTarget = getSunTime(date: tomorrow, event: selectedSunEvent)
            } else {
                finalTarget = todayEventTime.addingTimeInterval(86400)
            }
        } else {
            finalTarget = todayEventTime
        }

        self.targetDate = finalTarget

        loadWorldMapData()
        setupTimer()
        updateLineXFromDate()
    }

    func setupTimer() {
        timerCancellable = Timer.publish(every: 0.01667, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                guard let self = self else { return }
                self.currentTime = now

                if self.logLap >= self.intervalMilliseconds {
                    self.logs.insert(DateFormatter.localizedString(from: now, dateStyle: .medium, timeStyle: .medium), at: 0)
                    self.logLap = 0
                }
                self.logLap += 1
            }
    }

    func isDaylightTime(_ date: Date) -> Bool {
        let timeZone = TimeZone(identifier: "Europe/Zagreb") ?? TimeZone.current
        return timeZone.isDaylightSavingTime(for: date)
    }

    func getSunTime(date: Date, event: SunEvent) -> Date {
        let lat = latitude
        let lng = longitude
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)

        let startOfYear = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let N = calendar.dateComponents([.day], from: startOfYear, to: date).day! + 1

        let lngHour = lng / 15.0
        var ApproxTime: Double

        switch event {
        case .sunrise, .civilDawn, .nauticalDawn, .astronomicalDawn:
            ApproxTime = Double(N) + ((6.0 - lngHour) / 24.0)
        case .sunset, .civilDusk, .nauticalDusk, .astronomicalDusk:
            ApproxTime = Double(N) + ((18.0 - lngHour) / 24.0)
        case .solarNoon:
            ApproxTime = Double(N) + ((12.0 - lngHour) / 24.0)
        }

        let M = (0.9856 * ApproxTime) - 3.289
        var L = M + (1.916 * sin(M.deg2rad())) + (0.020 * sin((2 * M).deg2rad())) + 282.634
        L = L.trunc360()

        var RA = atan(0.91764 * tan(L.deg2rad())).rad2deg()
        RA = RA.trunc360()

        let Lquadrant = floor(L / 90.0) * 90.0
        let RAquadrant = floor(RA / 90.0) * 90.0
        RA = RA + (Lquadrant - RAquadrant)
        RA = RA / 15.0

        let sinDec = 0.39782 * sin(L.deg2rad())
        let cosDec = cos(asin(sinDec))

        if event == .solarNoon {
            let LocalMeanTime = RA - (0.06571 * ApproxTime) - 6.622
            var UT = LocalMeanTime - lngHour
            UT = UT.normalize24()
            let timeZone = isDaylightTime(date) ? 2.0 : 1.0
            UT = (UT + timeZone).normalize24()
            return calendar.startOfDay(for: date).addingTimeInterval(UT * 3600)
        } else {
            let cosH = (cos(event.zenith.deg2rad()) - (sinDec * sin(lat.deg2rad()))) / (cosDec * cos(lat.deg2rad()))

            if cosH > 1 {
                // never rises
                return calendar.startOfDay(for: date)
            } else if cosH < -1 {
                // never sets
                return calendar.startOfDay(for: date).addingTimeInterval(23*3600 + 59*60 + 59)
            }

            var H = acos(cosH).rad2deg()
            if event.isDawn {
                H = 360.0 - H
            }
            H = H / 15.0

            let LocalMeanTime = H + RA - (0.06571 * ApproxTime) - 6.622
            var UT = LocalMeanTime - lngHour
            UT = UT.normalize24()
            let timeZone = isDaylightTime(date) ? 2.0 : 1.0
            UT = (UT + timeZone).normalize24()

            return calendar.startOfDay(for: date).addingTimeInterval(UT * 3600)
        }
    }

    func calculateDayLength(date: Date) -> TimeInterval {
        let sunrise = getSunTime(date: date, event: .sunrise)
        let sunset = getSunTime(date: date, event: .sunset)
        var length = sunset.timeIntervalSince(sunrise)
        if length < 0 { length += 86400 }
        return length
    }

    func updateTimeForSelectedEvent() {
        let chosen = getSunTime(date: targetDate, event: selectedSunEvent)
        let d = Calendar.current.startOfDay(for: targetDate)
        let timeOfDay = chosen.timeIntervalSince(d)
        targetDate = d.addingTimeInterval(timeOfDay)
    }

    func loadWorldMapData() {
        guard let url = Bundle.main.url(forResource: "world", withExtension: "geo.json") else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        guard let root = try? decoder.decode(GeoJSONRoot.self, from: data) else { return }

        var countries: [Country] = []

        for feature in root.features {
            let countryName = feature.properties.name ?? "Unknown"
            var polys: [Polygon] = []
            if feature.geometry.type == "Polygon", let coords = feature.geometry.coordinates {
                // Single polygon
                for ring in coords {
                    let polygon = ring.map { Coordinate(latitude: $0[1], longitude: $0[0]) }
                    polys.append(Polygon(coordinates: polygon))
                }
            } else if feature.geometry.type == "MultiPolygon", let multiCoords = feature.geometry.multiCoordinates {
                // MultiPolygon
                for polygonSet in multiCoords {
                    for ring in polygonSet {
                        let polygon = ring.map { Coordinate(latitude: $0[1], longitude: $0[0]) }
                        polys.append(Polygon(coordinates: polygon))
                    }
                }
            }
            countries.append(Country(name: countryName, polygons: polys))
        }

        worldMap = countries
    }

    func mercatorProjectionY(lat: Double) -> Double {
        var latitude = lat
        if latitude > 89.5 { latitude = 89.5 }
        if latitude < -89.5 { latitude = -89.5 }
        let latRad = latitude.deg2rad()
        return log(tan(Double.pi/4 + latRad/2))
    }

    func mercatorYToLatitude(y: Double) -> Double {
        return (2 * atan(exp(y)) - Double.pi/2).rad2deg()
    }

    func updateDateFromLineX(graphWidth: CGFloat, year: Int) {
        let totalDays = daysInYear(year)
        let effectiveWidth = graphWidth - 40
        var dayIndex = Int(round((dayLineX - 40) * CGFloat(totalDays) / effectiveWidth))
        if dayIndex < 0 { dayIndex = 0 }
        if dayIndex >= totalDays { dayIndex = totalDays - 1 }
        let start = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1))!
        targetDate = start.addingTimeInterval(Double(dayIndex)*86400)
    }

    func updateLineXFromDate() {
        let year = Calendar.current.component(.year, from: targetDate)
        let totalDays = daysInYear(year)
        let dayIndex = dayOfYear(targetDate) - 1
        // The actual lineX gets updated in the SunGraphView on appear
        let _ = dayIndex
    }

    func dayOfYear(_ date: Date) -> Int {
        let year = Calendar.current.component(.year, from: date)
        let start = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1))!
        return Calendar.current.dateComponents([.day], from: start, to: date).day! + 1
    }

    func daysInYear(_ year: Int) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(year: year))!
        let end = cal.date(from: DateComponents(year: year+1))!
        return cal.dateComponents([.day], from: start, to: end).day!
    }

    func hashName(_ name: String) -> UInt32 {
        var result: UInt32 = 0
        for c in name.utf8 {
            result = ((result << 5) | (result >> 27)) ^ UInt32(c)
        }
        return result
    }

    func getCountryColor(countryName: String, lat: Double) -> Color {
        let h = hashName(countryName)
        let r = UInt8((h & 0xFF0000) >> 16)
        let g = UInt8((h & 0x00FF00) >> 8)
        let b = UInt8(h & 0x0000FF)

        let brightnessFactor = 1.0 - (abs(lat)/90.0)*0.5
        let R = Double(r)/255.0 * brightnessFactor
        let G = Double(g)/255.0 * brightnessFactor
        let B = Double(b)/255.0 * brightnessFactor

        return Color(red: R, green: G, blue: B)
    }
}

// MARK: - Extensions

extension Double {
    func deg2rad() -> Double { return self * Double.pi / 180.0 }
    func rad2deg() -> Double { return self * 180.0 / Double.pi }
    func trunc360() -> Double {
        var value = self
        while value < 0 { value += 360 }
        while value >= 360 { value -= 360 }
        return value
    }
    func normalize24() -> Double {
        var value = self
        while value < 0 { value += 24 }
        while value >= 24 { value -= 24 }
        return value
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject var vm = OdbrojavanjeViewModel()

    var body: some View {
        TabView {
            CountdownView(vm: vm)
                .tabItem {
                    Image(systemName: "timer")
                    Text("Countdown")
                }

            SunGraphAndMapView(vm: vm)
                .tabItem {
                    Image(systemName: "sun.max")
                    Text("Sun Graph & Map")
                }
        }
    }
}

// MARK: - Countdown View

struct CountdownView: View {
    @ObservedObject var vm: OdbrojavanjeViewModel

    var timeRemaining: String {
        let now = vm.currentTime
        let target = vm.targetDate
        if now >= target {
            return "Time is up!"
        }
        let diff = target.timeIntervalSince(now)
        return timeIntervalToString(diff)
    }

    func timeIntervalToString(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let ms = Int((interval - Double(totalSeconds)) * 1000)
        var secs = totalSeconds
        let days = secs / 86400
        secs %= 86400
        let hrs = secs / 3600
        secs %= 3600
        let mins = secs / 60
        secs %= 60

        var s = ""
        if days > 0 { s += "\(days)d " }
        s += String(format: "%02d:%02d:%02d.%03d", hrs, mins, secs, ms)
        return s
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Current Time: \(vm.currentTime, style: .time)")

            DatePicker("Target Date", selection: $vm.targetDate, displayedComponents: .date)
                .datePickerStyle(.compact)

            DatePicker("Target Time", selection: $vm.targetDate, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)

            Picker("Sun Event", selection: $vm.selectedSunEvent) {
                ForEach(SunEvent.allCases, id: \.self) { event in
                    Text(event.name).tag(event)
                }
            }
            .onChange(of: vm.selectedSunEvent) { _ in
                vm.updateTimeForSelectedEvent()
            }

            Text("Countdown: \(timeRemaining)")
                .font(.headline).frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("Interval: \(vm.intervalMilliseconds/1000)s")
                Slider(value: Binding(get: {
                    Double(vm.intervalMilliseconds)
                }, set: { newVal in
                    vm.intervalMilliseconds = Int(newVal)
                }), in: 1...50000000, step: 1000)
            }

            Text("Logs:")
            List(vm.logs, id: \.self) { log in
                Text(log)
            }
        }
        .padding()
    }
}

// MARK: - Sun Graph and Map View

struct SunGraphAndMapView: View {
    @ObservedObject var vm: OdbrojavanjeViewModel
    @State private var sunGraphSize: CGSize = .zero

    var body: some View {
        VStack {
            Text("Day Length: \(dayLengthString())").font(.title3).padding(.top)
            SunGraphView(vm: vm, sunGraphSize: $sunGraphSize)
                .frame(height: 300)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let year = Calendar.current.component(.year, from: vm.targetDate)
                        vm.dayLineX = value.location.x
                        vm.updateDateFromLineX(graphWidth: sunGraphSize.width, year: year)
                    }
                )

            Text("Map (Tap to choose location)")
            MapView(vm: vm)
                .aspectRatio(1.5, contentMode: .fit)
                .gesture(DragGesture()
                    .onChanged { value in
                        vm.offset = CGSize(width: vm.offset.width + value.translation.width,
                                           height: vm.offset.height + value.translation.height)
                    }
                )
                .gesture(MagnificationGesture()
                    .onChanged { value in
                        vm.scale *= value
                    }
                )
        }
    }

    func dayLengthString() -> String {
        let length = vm.calculateDayLength(date: vm.targetDate)
        let hrs = Int(length/3600)
        let mins = Int((length.truncatingRemainder(dividingBy: 3600))/60)
        let secs = Int(length.truncatingRemainder(dividingBy: 60))
        return "\(hrs) hrs \(mins) mins \(secs) secs"
    }
}

// MARK: - Sun Graph View

struct SunGraphView: View {
    @ObservedObject var vm: OdbrojavanjeViewModel
    @Binding var sunGraphSize: CGSize

    let eventColors: [SunEvent: Color] = [
        .sunrise: .yellow,
        .sunset: .red,
        .civilDawn: Color(red:0.53, green:0.81, blue:0.92),
        .civilDusk: .purple,
        .nauticalDawn: .blue,
        .nauticalDusk: .brown,
        .astronomicalDawn: .indigo,
        .astronomicalDusk: .black,
        .solarNoon: .green
    ]

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                DispatchQueue.main.async {
                    sunGraphSize = size
                    let year = Calendar.current.component(.year, from: vm.targetDate)
                    let totalDays = vm.daysInYear(year)
                    let dayIndex = vm.dayOfYear(vm.targetDate)-1
                    let effectiveWidth = size.width - 40
                    let newLineX = 40 + CGFloat(dayIndex)*effectiveWidth/CGFloat(totalDays)
                    if abs(vm.dayLineX - newLineX) > 0.1 {
                        vm.dayLineX = newLineX
                    }
                }

                let year = Calendar.current.component(.year, from: vm.targetDate)
                let totalDays = vm.daysInYear(year)
                let start = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1))!
                let maxHeight = size.height - 50.0
                let scaleY = maxHeight / 24.0
                let sunEventTimes = computeSunEventTimes(year: year, totalDays: totalDays, start: start)

                drawAxes(context: context, size: size, maxHeight: maxHeight)
                drawHours(context: context, size: size, maxHeight: maxHeight, scaleY: scaleY)
                drawMonths(context: context, size: size, maxHeight: maxHeight, totalDays: totalDays, year: year, start: start)
                drawSunEventLines(context: context, size: size, totalDays: totalDays, maxHeight: maxHeight, scaleY: scaleY, sunEventTimes: sunEventTimes)
                drawLegend(context: context, size: size, maxHeight: maxHeight)
                drawDateLine(context: context, size: size, maxHeight: maxHeight, totalDays: totalDays, year: year)
            }
        }
    }

    private func computeSunEventTimes(year: Int, totalDays: Int, start: Date) -> [SunEvent: [Double]] {
        var result: [SunEvent: [Double]] = [:]
        for event in SunEvent.allCases {
            var times: [Double] = []
            for i in 0..<totalDays {
                let date = Calendar.current.date(byAdding: .day, value: i, to: start)!
                let t = vm.getSunTime(date: date, event: event)
                let h = Double(Calendar.current.component(.hour, from: t))
                    + Double(Calendar.current.component(.minute, from: t))/60.0
                    + Double(Calendar.current.component(.second, from: t))/3600.0
                times.append(h)
            }
            result[event] = times
        }
        return result
    }

    private func drawAxes(context: GraphicsContext, size: CGSize, maxHeight: CGFloat) {
        var path = Path()
        // Y-axis
        path.move(to: CGPoint(x: 40, y: 0))
        path.addLine(to: CGPoint(x: 40, y: maxHeight))
        // X-axis
        path.move(to: CGPoint(x: 40, y: maxHeight))
        path.addLine(to: CGPoint(x: size.width, y: maxHeight))
        context.stroke(path, with: .color(.black))
    }

    private func drawHours(context: GraphicsContext, size: CGSize, maxHeight: CGFloat, scaleY: CGFloat) {
        for hour in 0...24 {
            let y = maxHeight - CGFloat(hour)*scaleY
            var line = Path()
            line.move(to: CGPoint(x: 35, y: y))
            line.addLine(to: CGPoint(x: 40, y: y))
            context.stroke(line, with: .color(.gray))

            let text = Text("\(hour):00").font(.system(size: 8))
            context.draw(text, at: CGPoint(x: 20, y: y), anchor: .center)
        }
    }

    private func drawMonths(context: GraphicsContext, size: CGSize, maxHeight: CGFloat, totalDays: Int, year: Int, start: Date) {
        for m in 1...12 {
            let mDate = Calendar.current.date(from: DateComponents(year: year, month: m, day: 1))!
            let mIndex = Calendar.current.dateComponents([.day], from: start, to: mDate).day!
            let X = 40 + CGFloat(mIndex)*((size.width - 40)/CGFloat(totalDays))

            var line = Path()
            line.move(to: CGPoint(x: X, y: maxHeight))
            line.addLine(to: CGPoint(x: X, y: 0))
            context.stroke(line, with: .color(.gray), style: StrokeStyle(dash: [2,2]))

            let formatter = DateFormatter()
            formatter.dateFormat = "MMM"
            let monthName = formatter.string(from: mDate)
            let text = Text(monthName).font(.system(size: 8))
            context.draw(text, at: CGPoint(x: X+15, y: maxHeight+10), anchor: .center)
        }
    }

    private func drawSunEventLines(context: GraphicsContext, size: CGSize, totalDays: Int, maxHeight: CGFloat, scaleY: CGFloat, sunEventTimes: [SunEvent: [Double]]) {
        for event in SunEvent.allCases {
            guard let times = sunEventTimes[event] else { continue }
            var line = Path()
            line.move(to: CGPoint(x: 40, y: maxHeight - CGFloat(times[0])*scaleY))
            for i in 1..<totalDays {
                let X = 40 + CGFloat(i)*((size.width-40)/CGFloat(totalDays))
                let Y = maxHeight - CGFloat(times[i])*scaleY
                line.addLine(to: CGPoint(x: X, y: Y))
            }
            if let color = eventColors[event] {
                context.stroke(line, with: .color(color))
            }
        }
    }

    private func drawLegend(context: GraphicsContext, size: CGSize, maxHeight: CGFloat) {
        var legendX: CGFloat = 50
        let legendY = maxHeight + 20
        for event in SunEvent.allCases {
            let rect = CGRect(x: legendX, y: legendY, width: 10, height: 10)
            if let color = eventColors[event] {
                context.fill(Path(rect), with: .color(color))
            }
            let text = Text(event.name).font(.system(size: 8))
            context.draw(text, at: CGPoint(x: legendX+30, y: legendY+5), anchor: .center)
            legendX += 100
        }
    }

    private func drawDateLine(context: GraphicsContext, size: CGSize, maxHeight: CGFloat, totalDays: Int, year: Int) {
        var dateLine = Path()
        dateLine.move(to: CGPoint(x: vm.dayLineX, y: 0))
        dateLine.addLine(to: CGPoint(x: vm.dayLineX, y: maxHeight))
        context.stroke(dateLine, with: .color(.black), style: StrokeStyle(lineWidth: 2, dash: [5,5]))

        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM"
        let dateStr = formatter.string(from: vm.targetDate)
        let dateText = Text(dateStr).font(.system(size: 8)).bold()
        context.draw(dateText, at: CGPoint(x: vm.dayLineX, y: 5), anchor: .center)
    }
}

// MARK: - Map View

struct MapView: View {
    @ObservedObject var vm: OdbrojavanjeViewModel

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))

                for country in vm.worldMap {
                    for poly in country.polygons {
                        let path = drawCountryPolygon(poly, size: size)
                        let color = vm.getCountryColor(countryName: country.name, lat: poly.coordinates.first?.latitude ?? 0)
                        context.fill(path, with: .color(color))
                    }
                }

                // Draw marker
                let marker = pointFor(lat: vm.latitude, lon: vm.longitude, size: size)
                let markerPath = Path(ellipseIn: CGRect(x: marker.x-5, y: marker.y-5, width: 10, height: 10))
                context.stroke(markerPath, with: .color(.red), lineWidth: 2)
            }
            .onTapGesture { location in
                hitTestMap(x: location.x, y: location.y, size: geo.size)
            }
        }
    }

    func drawCountryPolygon(_ polygon: Polygon, size: CGSize) -> Path {
        var path = Path()
        let minDim = min(size.width, size.height)
        let s = Double(vm.scale) * Double(minDim) / (2 * Double.pi)
        let offsetX = Double(size.width/2) + Double(vm.offset.width)
        let offsetY = Double(size.height/2) + Double(vm.offset.height)

        var first = true
        for coord in polygon.coordinates {
            let x = offsetX + s * coord.longitude.deg2rad()
            let y = offsetY - s * vm.mercatorProjectionY(lat: coord.latitude)
            if first {
                path.move(to: CGPoint(x: x, y: y))
                first = false
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }

    func pointFor(lat: Double, lon: Double, size: CGSize) -> CGPoint {
        let minDim = min(size.width, size.height)
        let s = Double(vm.scale) * Double(minDim) / (2 * Double.pi)
        let offsetX = Double(size.width/2) + Double(vm.offset.width)
        let offsetY = Double(size.height/2) + Double(vm.offset.height)

        let x = offsetX + s * lon.deg2rad()
        let y = offsetY - s * vm.mercatorProjectionY(lat: lat)
        return CGPoint(x: x, y: y)
    }

    func hitTestMap(x: CGFloat, y: CGFloat, size: CGSize) {
        let minDim = min(size.width, size.height)
        let s = Double(vm.scale) * Double(minDim) / (2 * Double.pi)
        let offsetX = Double(size.width/2) + Double(vm.offset.width)
        let offsetY = Double(size.height/2) + Double(vm.offset.height)

        let projX = (Double(x) - offsetX) / s
        let projY = (offsetY - Double(y)) / s

        let lon = projX.rad2deg()
        let lat = vm.mercatorYToLatitude(y: projY)
        vm.latitude = lat
        vm.longitude = lon
    }
}
