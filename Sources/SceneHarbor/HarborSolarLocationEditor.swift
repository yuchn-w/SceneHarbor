import SwiftUI

/// Location is always a user-entered choice. Merely opening the schedule never
/// asks macOS for location permission or transmits coordinates.
struct HarborSolarLocationEditor: View {
    @Binding var location: HarborSolarLocation?
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var name = ""
    @State private var message: String?

    private let cities: [(String, Double, Double)] = [
        ("臺北", 25.0330, 121.5654), ("臺中", 24.1477, 120.6736), ("高雄", 22.6273, 120.3014),
        ("東京", 35.6762, 139.6503), ("香港", 22.3193, 114.1694),
        ("倫敦", 51.5074, -0.1278), ("舊金山", 37.7749, -122.4194)
    ]
    private var candidate: HarborSolarLocation? {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return nil }
        let value = HarborSolarLocation(latitude: lat, longitude: lon, name: name.isEmpty ? nil : name)
        return value.isValid ? value : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("日出日落地點", systemImage: "sun.horizon").font(HarborControlStyle.labelFont.weight(.semibold))
            Text("選擇城市或輸入經緯度，只在這台 Mac 計算。實際日出日落可能受地形與天候影響。")
                .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
            HStack {
                Menu("選擇城市") {
                    ForEach(cities, id: \.0) { city in
                        Button(city.0) { name = city.0; latitude = String(city.1); longitude = String(city.2) }
                    }
                }.menuStyle(.borderedButton)
                TextField("地點名稱", text: $name).textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("緯度 −90 至 90", text: $latitude)
                TextField("經度 −180 至 180", text: $longitude)
                Button("使用此地點") { location = candidate; message = "已更新排程地點" }.disabled(candidate == nil)
            }.textFieldStyle(.roundedBorder)
            if let location {
                HStack {
                    Text("目前：\(location.name ?? "自訂地點")（\(location.latitude.formatted(.number.precision(.fractionLength(2))))，\(location.longitude.formatted(.number.precision(.fractionLength(2))))）")
                    Spacer()
                    Button("移除地點") { self.location = nil; message = "日出日落規則將暫停，固定時間規則不受影響" }
                }.font(HarborControlStyle.secondaryFont)
                if let rise = HarborSolarTimes.date(for: .sunrise, on: Date(), location: location, timeZone: .autoupdatingCurrent),
                   let set = HarborSolarTimes.date(for: .sunset, on: Date(), location: location, timeZone: .autoupdatingCurrent) {
                    Text("今日約 \(rise, style: .time) 日出、\(set, style: .time) 日落（Mac 當地時間）")
                        .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
                } else {
                    Text("這個地點今天沒有可用的日出或日落時間，相關規則會保留目前桌布。")
                        .font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary)
                }
            }
            if let message { Text(message).font(HarborControlStyle.secondaryFont).foregroundStyle(.secondary) }
        }
        .font(HarborControlStyle.labelFont).controlSize(.regular)
        .onAppear { loadFields(location) }
        .onChange(of: location) { _, updated in loadFields(updated) }
    }

    private func loadFields(_ location: HarborSolarLocation?) {
        name = location?.name ?? ""
        latitude = location.map { String($0.latitude) } ?? ""
        longitude = location.map { String($0.longitude) } ?? ""
    }
}
