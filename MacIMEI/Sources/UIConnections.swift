import SwiftUI

extension ContentView {
    var connectionRoutingCard: some View {
        StudioCard {
            Text(L10n.text("Web → ADB → агент и SSH → подключение по SSH"))
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
            HStack(spacing: 10) {
                Button(L10n.text("Выполнить предварительную подготовку модема"), action: model.preparePreferredSSH)
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canPrepareModem)
                    .fixedSize(horizontal: false, vertical: true)
                OperationInfoButton(topic: .preparation)
                Spacer(minLength: 0)
            }
            if let reason = model.preparationUnavailableReason {
                Text(L10n.text(reason))
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.preparationError.isEmpty {
                Label(L10n.text(model.preparationError), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.warning).fixedSize(horizontal: false, vertical: true)
            }

            Button(L10n.text("Подключиться к модему"), action: model.connect)
                .buttonStyle(StudioButtonStyle(prominent: true))
                .disabled(model.busy || model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !model.connected && !model.connectionReason.isEmpty {
                Label(L10n.text(model.connectionReason), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.warning)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var connectionDiagnosticsCard: some View {
        StudioCard {
            HStack(alignment: .center) {
                Text(L10n.text("Доступ к модему")).font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 12)
                Button(L10n.text("Проверить подключения"), action: model.discoverConnections)
                    .buttonStyle(StudioButtonStyle()).disabled(model.busy || model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(L10n.text("Кнопка проверяет доступность SSH и USB ADB, а также вход в агент и штатный Web с введёнными паролями. Автоматическая проверка при открытии страницы выполняется без входа."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                ForEach([ConnectionMode.ssh, .adb, .agent, .web]) { mode in connectionAvailabilityRow(mode) }
            }.padding(.vertical, 4)

        }
    }

    var diagnosticADBCard: some View {
        StudioCard {
            Text(L10n.text("Для диагностики")).font(.system(size: 12, weight: .semibold))
            HStack(spacing: 10) {
                Button(L10n.text(model.diagnosticADBPending ? "Продолжить включение ADB" : "Принудительно включить ADB"), action: model.enableDiagnosticADB)
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canEnableDiagnosticADB)
                OperationInfoButton(topic: .diagnosticADB)
                Spacer(minLength: 0)
            }
            Text(L10n.text("Доступно и при работающем SSH. Возможна перезагрузка модема; агент и настройки SSH не меняются."))
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.diagnosticADBMessage.isEmpty {
                Text(L10n.text(model.diagnosticADBMessage)).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var accessDiagnosticsCard: some View {
        StudioCard {
            HStack {
                Text(L10n.text("Службы и способы входа")).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(action: model.refreshAccess) { Label(L10n.text("Проверить доступы"), systemImage: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
            }
            if let state = model.accessState {
                ForEach(state.services) { service in
                    VStack(alignment: .leading, spacing: 6) {
                        informationRow(service.title, serviceStateLabel(service.state))
                        Text(service.endpoint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Text(L10n.text(service.detail)).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                    }.padding(.vertical, 5)
                }
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
                Text(L10n.text(mode == .web ? "Штатный Web" : mode == .adb ? "ADB · диагностика" : mode.title)).font(.system(size: 12, weight: .medium))
                Text(L10n.text(state.title)).font(.system(size: 10)).foregroundStyle(color)
            }.frame(width: 110, alignment: .leading)
            Text(L10n.text(status?.message ?? "Нажмите «Проверить подключения»."))
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}
