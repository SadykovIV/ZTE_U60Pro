import SwiftUI

extension ContentView {
    var connectionRoutingCard: some View {
        StudioCard {
            Text(L10n.text("Web → ADB → агент и SSH → подключение по SSH"))
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
            HStack(spacing: 10) {
                Button(L10n.text(model.componentCleanupPending ? "Продолжить очистку компонентов" : "Выполнить предварительную подготовку модема"), action: model.preparePreferredSSH)
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canPrepareModem)
                    .fixedSize(horizontal: false, vertical: true)
                OperationInfoButton(topic: .preparation)
                Spacer(minLength: 0)
            }
            if model.componentCleanupPending && model.componentCleanupCanCancel {
                Button(L10n.text("Отменить очистку"), action: model.cancelComponentCleanup)
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canCancelComponentCleanup)
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

    var connectionMethodsContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Все операции с модемом выполняются через SSH. USB ADB нужен для подготовки SSH; веб-панели открываются в браузере."))
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            HStack {
                connectionAvailabilityRow(.ssh)
                Button(L10n.text("Проверить подключения"), action: model.discoverConnections)
                    .buttonStyle(StudioButtonStyle()).disabled(model.busy || model.terminalActive || model.host.isEmpty)
            }
            HStack {
                Toggle(L10n.text("Включить ADB"), isOn: Binding(get: { model.adbControlStatus?.enabled == true }, set: { model.setADBEnabled($0) }))
                    .toggleStyle(.checkbox).disabled(!model.canChangeADB)
                if model.adbControlStatus?.enabled == nil { Text(L10n.text("Состояние не определено")).font(.system(size: 10)) }
                Spacer()
                Button(L10n.text("Обновить состояние ADB"), action: model.refreshADBState)
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canReadModem)
                OperationInfoButton(topic: .diagnosticADB)
            }
            Text(L10n.text(model.diagnosticADBMessage.isEmpty ? model.adbControlStatus?.detail ?? "Для чтения состояния ADB подключитесь по SSH." : model.diagnosticADBMessage))
                .font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !model.connected {
                Text(L10n.text("Если SSH ещё не настроен, включение ADB использует поддерживаемый способ первоначальной подготовки. Заполните параметры подготовки SSH."))
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.text("Штатный Web")) { model.openModemBrowser(port: nil) }.buttonStyle(StudioButtonStyle())
                Button(L10n.text("Веб-панель агента")) { model.openModemBrowser(port: 8080) }.buttonStyle(StudioButtonStyle())
                Spacer()
                Button(L10n.text("Проверить доступы"), action: model.refreshAccess)
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canManage)
            }
            if let state = model.accessState {
                ForEach(state.services.filter { $0.id != .stockWeb && $0.id != .dashboard && $0.id != .agent && $0.id != .adb }) { service in
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.text(service.title)).frame(width: 140, alignment: .leading)
                        Text(L10n.text(serviceStateLabel(service.state)))
                        Spacer()
                        Text(service.endpoint).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }.font(.system(size: 11))
                }
            }
        }
    }

    private func connectionAvailabilityRow(_ mode: ConnectionMode) -> some View {
        let status = model.channelStatuses.first { $0.mode == mode }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: status?.state == .available ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status?.state == .available ? StudioStyle.accent : StudioStyle.secondary)
            Text(mode.title).font(.system(size: 12, weight: .medium))
            Text(L10n.text(status?.state.title ?? "Не проверен")).font(.system(size: 11))
            Spacer()
        }
    }
}
