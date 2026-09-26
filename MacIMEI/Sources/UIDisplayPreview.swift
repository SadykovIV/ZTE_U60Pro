import SwiftUI

// The preview follows the native 320 × 432 launcher geometry. Values are examples.
typealias ModemDisplayPreviewStyle = ModemDisplayPageStyle

struct ModemDisplayLayoutPreview: View {
    let layout: ModemDisplayLayout
    private let overrideStyle: ModemDisplayPageStyle?
    var style: ModemDisplayPageStyle { overrideStyle ?? layout.style }
    init(layout: ModemDisplayLayout, style: ModemDisplayPageStyle? = nil) {
        self.layout = layout; self.overrideStyle = style
    }
    private let scale: CGFloat = 0.75
    private var selected: [ModemDisplayLayoutItem] { layout.items.filter(\.enabled) }

    var body: some View {
        screen
            .frame(width: 320, height: 432)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: 320 * scale, height: 432 * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioStyle.line, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Предпросмотр: " + style.title + ". Пример значений, не показания подключённого модема.")
    }

    private var screen: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.06, green: 0.07, blue: 0.09)
            Text("О модеме")
                .font(.system(size: 24, weight: .medium))
                .frame(width: 288, height: 34, alignment: .leading).offset(x: 16, y: 12)
            Text("Данные модема")
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 288, height: 20, alignment: .leading).offset(x: 16, y: 50)
            ScrollView(.vertical, showsIndicators: true) {
                if style == .list {
                    VStack(spacing: 7) {
                        ForEach(selected, id: \.id) { item in listCard(item.metric) }
                    }.frame(width: 292, alignment: .topLeading)
                        .padding(.horizontal, 14)
                } else {
                    LazyVGrid(columns: [GridItem(.fixed(141), spacing: 10), GridItem(.fixed(141))], spacing: 10) {
                        ForEach(selected, id: \.id) { item in tileCard(item.metric) }
                    }.padding(.horizontal, 14).padding(.bottom, 5)
                }
            }
            .id(style)
            .frame(width: 320, height: 346, alignment: .topLeading).offset(x: 0, y: 76)
        }.foregroundStyle(.white.opacity(0.94))
    }

    private func listCard(_ metric: ModemDisplayMetric) -> some View {
        let carriers = metric == .carriers
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08))
            Text(previewTitle(metric))
                .font(.system(size: 14)).lineLimit(1)
                .frame(width: 268, height: 19, alignment: .leading).offset(x: 12, y: 3)
            Text(listValue(metric))
                .font(.system(size: carriers ? 17 : 19, weight: .medium))
                .lineLimit(carriers ? 2 : 1)
                .frame(width: 268, height: carriers ? 40 : 24, alignment: .topLeading).offset(x: 12, y: 23)
        }.frame(width: 292, height: carriers ? 66 : 48)
    }

    private func tileCard(_ metric: ModemDisplayMetric) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08))
            Text(tileTitle(metric)).font(.system(size: 14))
                .lineLimit(1).frame(width: 121, height: 19, alignment: .leading).offset(x: 10, y: 8)
            Text(tileValue(metric)).font(.system(size: metric == .carriers ? 16 : 17, weight: .medium))
                .monospacedDigit().lineLimit(4)
                .frame(width: 121, height: 70, alignment: .topLeading).offset(x: 10, y: 30)
        }.frame(width: 141, height: 106)
        .accessibilityElement(children: .combine)
    }

    private func previewTitle(_ metric: ModemDisplayMetric) -> String {
        switch metric {
        case .network: return "Тип соединения"
        case .carriers: return "Несущие: 3"
        case .battery: return "Батарея"
        case .rsrq: return "Качество сигнала · RSRQ"
        case .sinr: return "Сигнал / шум · SINR"
        default: return metric.title
        }
    }
    private func listValue(_ metric: ModemDisplayMetric) -> String {
        switch metric {
        case .carriers: return "B3 + B7 + n78"
        case .battery: return "82% · Заряжается"
        case .rsrq: return "−10 dB · LTE"
        case .sinr: return "18 dB · LTE"
        default: return metric.previewValue
        }
    }
    private func tileTitle(_ metric: ModemDisplayMetric) -> String {
        switch metric {
        case .cpu: return "CPU"
        case .signal: return "Сигнал"
        case .network: return "Соединение"
        case .carriers: return "Несущие: 3"
        case .cpuTemperature: return "Темп. CPU"
        case .modemTemperature: return "Темп. модема"
        case .memory: return "Память"
        case .storage: return "Хранилище"
        case .uptime: return "Время работы"
        case .battery: return "Батарея"
        case .rsrq: return "RSRQ"
        case .sinr: return "SINR"
        }
    }
    private func tileValue(_ metric: ModemDisplayMetric) -> String {
        switch metric {
        case .cpu: return "24%"
        case .signal: return "−87 dBm\nRSRP"
        case .network: return "5G NSA"
        case .carriers: return "B3 + B7 + n78"
        case .cpuTemperature: return "48 °C"
        case .modemTemperature: return "43 °C"
        case .memory: return "284 / 512\nМиБ"
        case .storage: return "1,2 / 3,5\nГиБ"
        case .uptime: return "2 д\n03:04:05"
        case .battery: return "82%\nЗаряжается"
        case .rsrq: return "−10 dB\nLTE"
        case .sinr: return "18 dB\nLTE"
        }
    }
}

/// Last inspected modem state; preview taps never change the modem.
struct ModemVPNPagePreview: View {
    private let scale: CGFloat = 0.75
    var status: VPNStatus?
    private var profiles: [VPNProfile] { Array((status?.profiles ?? []).prefix(3)) }
    private var ssid: String {
        guard let status else { return "SSID не прочитан" }
        return status.actualSSID.isEmpty ? status.editableSSID : status.actualSSID
    }
    private var footer: String {
        guard let status else { return "Состояние не прочитано" }
        if !status.installed { return "Установите компоненты VPN" }
        if !status.configured { return "Сеть ещё не настроена" }
        if !status.enabled { return "Wi-Fi с VPN выключен" }
        return status.coreRunning && status.networkOk ? "VPN работает" : "Проверьте состояние VPN"
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.06, green: 0.07, blue: 0.09)
            Text("VPN").font(.system(size: 24, weight: .medium))
                .frame(width: 288, height: 34, alignment: .leading).offset(x: 16, y: 12)
            Text(ssid).font(.system(size: 18)).lineLimit(1).truncationMode(.tail)
                .frame(width: 288, height: 26, alignment: .leading).offset(x: 16, y: 52)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08))
                Text("WiFi с VPN").font(.system(size: 19))
                    .frame(width: 196, height: 30, alignment: .leading).offset(x: 12, y: 20)
                Capsule().fill(status?.enabled == true ? Color(red: 0.22, green: 0.78, blue: 0.55) : Color.white.opacity(0.20)).frame(width: 45, height: 24)
                    .overlay(alignment: status?.enabled == true ? .trailing : .leading) { Circle().fill(Color.white).frame(width: 20, height: 20).padding(.trailing, 2) }
                    .offset(x: 231, y: 19)
            }.frame(width: 292, height: 62).offset(x: 14, y: 88)
            Text("Профиль VPN").font(.system(size: 16))
                .frame(width: 288, height: 24, alignment: .leading).offset(x: 16, y: 163)
            ForEach(Array(profiles.enumerated()), id: \.offset) { index, profile in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08))
                    Text(profile.name).font(.system(size: 17)).lineLimit(2)
                        .frame(width: 262, height: 39, alignment: .leading).offset(x: 18, y: 7)
                    if profile.active { RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.22, green: 0.78, blue: 0.55)).frame(width: 5, height: 32).offset(x: 0, y: 8) }
                }.frame(width: 292, height: 48).offset(x: 14, y: CGFloat(194 + 54 * index))
            }
            if profiles.isEmpty {
                Text(status == nil ? "Проверьте VPN в приложении" : "Профили не добавлены")
                    .font(.system(size: 16)).foregroundStyle(.white.opacity(0.6))
                    .frame(width: 288, height: 100, alignment: .center).offset(x: 16, y: 194)
            }
            navigationLabel("Назад", x: 14)
            navigationLabel("Далее", x: 166)
            Text(footer).font(.system(size: 16)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 288, height: 25, alignment: .leading).offset(x: 16, y: 405)
        }.foregroundStyle(.white.opacity(0.94))
            .frame(width: 320, height: 432)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: 320 * scale, height: 432 * scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StudioStyle.line, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Предпросмотр страницы VPN по последнему прочитанному состоянию. Элементы предпросмотра не управляют модемом.")
    }
    private func navigationLabel(_ title: String, x: CGFloat) -> some View {
        Text(title).font(.system(size: 17)).frame(width: 140, height: 40)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)).offset(x: x, y: 360)
    }
}
