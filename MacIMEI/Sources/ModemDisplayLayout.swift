import Foundation

enum ModemDisplayMetric: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu, signal, network, carriers
    case cpuTemperature = "cpu_temp", modemTemperature = "modem_temp"
    case memory, storage, uptime, battery, rsrq, sinr

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "Загрузка процессора"
        case .signal: return "Уровень сигнала"
        case .network: return "Тип сети"
        case .carriers: return "Активные несущие"
        case .cpuTemperature: return "Температура процессора"
        case .modemTemperature: return "Температура модема"
        case .memory: return "Оперативная память"
        case .storage: return "Хранилище /data"
        case .uptime: return "Время работы"
        case .battery: return "Заряд батареи"
        case .rsrq: return "Качество сигнала RSRQ"
        case .sinr: return "Сигнал / помехи SINR"
        }
    }
    var detail: String {
        switch self {
        case .cpu: return "Доля занятого времени CPU, в процентах."
        case .signal: return "Мощность сигнала в дБм; при отсутствии данных — деления."
        case .network: return "2G, 3G, LTE или 5G по данным модема."
        case .carriers: return "Количество и диапазоны активных несущих, например B3, B7, n78."
        case .cpuTemperature: return "Максимальная температура датчиков процессора."
        case .modemTemperature: return "Температура модемной части."
        case .memory: return "Занятая и общая оперативная память в МиБ."
        case .storage: return "Занятый и общий объём раздела /data в ГиБ."
        case .uptime: return "Время с последней загрузки модема."
        case .battery: return "Оставшийся заряд аккумулятора, в процентах."
        case .rsrq: return "Качество радиосигнала в дБ: помогает оценить помехи и нагрузку сети."
        case .sinr: return "Отношение сигнала к шуму и помехам в дБ: больше — лучше."
        }
    }
    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .signal: return "antenna.radiowaves.left.and.right"
        case .network: return "network"
        case .carriers: return "waveform.path"
        case .cpuTemperature, .modemTemperature: return "thermometer.medium"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .uptime: return "clock"
        case .battery: return "battery.75percent"
        case .rsrq: return "waveform.path.ecg"
        case .sinr: return "waveform"
        }
    }
    var previewValue: String {
        switch self {
        case .cpu: return "24 %"
        case .signal: return "−87 dBm"
        case .network: return "5G NSA"
        case .carriers: return "3 · B3 + B7 + n78"
        case .cpuTemperature: return "48 °C"
        case .modemTemperature: return "43 °C"
        case .memory: return "284 / 512 МиБ"
        case .storage: return "1,2 / 3,5 ГиБ"
        case .uptime: return "2 д 03:04:05"
        case .battery: return "82 %"
        case .rsrq: return "−10 dB"
        case .sinr: return "18 dB"
        }
    }
}

enum ModemDisplayPageStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case list, tiles
    var id: String { rawValue }
    var title: String { self == .list ? "Список" : "Плитки" }
}

struct ModemDisplayLayoutItem: Equatable, Codable, Sendable, Identifiable {
    var metric: ModemDisplayMetric
    var enabled: Bool
    var id: String { metric.rawValue }
}

struct ModemDisplayLayout: Equatable, Codable, Sendable {
    static let header = "ZTE_INFO_LAYOUT_V2"
    static let legacyHeader = "ZTE_INFO_LAYOUT_V1"
    static let maximumBytes = 512
    static let maximumEnabled = 12
    var items: [ModemDisplayLayoutItem]
    var style: ModemDisplayPageStyle = .list
    static let defaultLayout = ModemDisplayLayout(items: ModemDisplayMetric.allCases.enumerated().map {
        ModemDisplayLayoutItem(metric: $0.element, enabled: $0.offset < 6)
    })
    var enabledCount: Int { items.filter(\.enabled).count }

    func validate() throws {
        try require(items.count == ModemDisplayMetric.allCases.count && Set(items.map(\.metric)) == Set(ModemDisplayMetric.allCases),
                    "Настройка дисплея должна содержать каждый показатель ровно один раз")
        try require((1...Self.maximumEnabled).contains(enabledCount), "Выберите от 1 до 12 показателей для плитки")
    }

    func encoded() throws -> Data {
        try validate()
        let value = Self.header + "\nstyle=" + style.rawValue + "\n" + items.map { $0.metric.rawValue + "=" + ($0.enabled ? "1" : "0") + "\n" }.joined()
        let data = Data(value.utf8)
        try require(data.count <= Self.maximumBytes, "Настройка дисплея слишком велика")
        return data
    }

    static func decode(_ data: Data) throws -> ModemDisplayLayout {
        try require(!data.isEmpty && data.count <= maximumBytes && data.allSatisfy { $0 == 10 || (32...126).contains($0) },
                    "Повреждён формат настройки дисплея")
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let legacy = lines.first == legacyHeader
        let expectedCount = legacy ? 9 : ModemDisplayMetric.allCases.count
        try require(lines.count == expectedCount + (legacy ? 2 : 3) && (legacy || lines.first == header) && lines.last == "",
                    "Неизвестная или неполная настройка дисплея")
        let style: ModemDisplayPageStyle
        if legacy { style = .list }
        else {
            let pair = lines[1].components(separatedBy: "=")
            guard pair.count == 2, pair[0] == "style", let parsed = ModemDisplayPageStyle(rawValue: pair[1]) else {
                throw IMEIError.message("Неизвестный тип страницы в настройке дисплея")
            }
            style = parsed
        }
        var items = try lines.dropFirst(legacy ? 1 : 2).dropLast().map { line -> ModemDisplayLayoutItem in
            let pair = line.components(separatedBy: "=")
            guard pair.count == 2, let metric = ModemDisplayMetric(rawValue: pair[0]), ["0", "1"].contains(pair[1]) else {
                throw IMEIError.message("Неизвестный показатель или значение в настройке дисплея")
            }
            return ModemDisplayLayoutItem(metric: metric, enabled: pair[1] == "1")
        }
        if legacy {
            let oldMetrics = Set(ModemDisplayMetric.allCases.prefix(9))
            try require(Set(items.map(\.metric)) == oldMetrics, "Неполная настройка дисплея предыдущей версии")
            items += ModemDisplayMetric.allCases.dropFirst(9).map { ModemDisplayLayoutItem(metric: $0, enabled: false) }
        }
        let layout = ModemDisplayLayout(items: items, style: style)
        try layout.validate()
        return layout
    }

    private enum CodingKeys: String, CodingKey { case items, style }
    init(items: [ModemDisplayLayoutItem], style: ModemDisplayPageStyle = .list) {
        self.items = items; self.style = style
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([ModemDisplayLayoutItem].self, forKey: .items)
        style = try values.decodeIfPresent(ModemDisplayPageStyle.self, forKey: .style) ?? .list
        if items.count == 9 && Set(items.map(\.metric)) == Set(ModemDisplayMetric.allCases.prefix(9)) {
            items += ModemDisplayMetric.allCases.dropFirst(9).map { ModemDisplayLayoutItem(metric: $0, enabled: false) }
        }
        try validate()
    }
}
