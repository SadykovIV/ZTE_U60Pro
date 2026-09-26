import SwiftUI

extension ContentView {
    var connectionRoutingCard: some View {
        StudioCard {
            HStack(alignment: .center) {
                Text("Доступ к модему").font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 12)
                Button("Проверить подключения", action: model.discoverConnections)
                    .buttonStyle(StudioButtonStyle()).disabled(model.busy || model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Кнопка проверяет доступность SSH и USB ADB, а также вход в агент и штатный Web с введёнными паролями. Автоматическая проверка при открытии страницы выполняется без входа.")
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                ForEach([ConnectionMode.ssh, .adb, .agent, .web]) { mode in connectionAvailabilityRow(mode) }
            }.padding(.vertical, 4)

            Divider().overlay(StudioStyle.line)
            HStack(spacing: 10) {
                Button("Выполнить предварительную подготовку модема", action: model.preparePreferredSSH)
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canPrepareModem)
                    .fixedSize(horizontal: false, vertical: true)
                OperationInfoButton(topic: .preparation)
                Spacer(minLength: 0)
            }
            if let reason = model.preparationUnavailableReason {
                Text(reason)
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.preparationError.isEmpty {
                Label(model.preparationError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.warning).fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(StudioStyle.line)
            Button("Подключиться к модему", action: model.connect)
                .buttonStyle(StudioButtonStyle(prominent: true))
                .disabled(model.busy || model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !model.connected && !model.connectionReason.isEmpty {
                Label(model.connectionReason, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.warning)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connectionAvailabilityRow(_ mode: ConnectionMode) -> some View {
        let status = model.channelStatuses.first { $0.mode == mode }
        let state = status?.state ?? .notChecked
        let color: Color
        let symbol: String
        switch state {
        case .available: color = StudioStyle.accent; symbol = "checkmark.circle.fill"
        case .invalidPassword: color = .red; symbol = "xmark.circle.fill"
        case .authenticationRequired: color = StudioStyle.warning; symbol = "key.fill"
        case .rateLimited: color = StudioStyle.warning; symbol = "clock.badge.exclamationmark"
        default: color = StudioStyle.secondary; symbol = "circle"
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(mode == .web ? "Штатный Web" : mode.title).font(.system(size: 12, weight: .medium))
                Text(state.title).font(.system(size: 10)).foregroundStyle(color)
            }.frame(width: 110, alignment: .leading)
            Text(status?.message ?? "Нажмите «Проверить подключения».")
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}
