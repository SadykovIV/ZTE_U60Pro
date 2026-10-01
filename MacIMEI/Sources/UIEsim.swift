import AppKit
import SwiftUI
import Vision
import UniformTypeIdentifiers


@MainActor struct EsimPanel: View {
    @ObservedObject var model: AppModel
    @StudioState private var activationCode = ""
    @StudioState private var manualInput = true
    @StudioState private var smdpAddress = ""
    @StudioState private var matchingID = ""
    @StudioState private var confirmationCode = ""
    @StudioState private var pending: EsimOperation?
    @StudioState private var confirmationText = ""
    @StudioState private var confirmationPresented = false
    @StudioState private var qrBusy = false
    @StudioState private var inputError = ""
    private var selected: EsimProfile? { model.esimSnapshot?.profiles.first { $0.iccid == model.esimSelectedICCID && $0.selectable } }
    private var blocked: Bool { model.busy || qrBusy }
    private var preparedCode: String? { manualInput ? EsimValidation.manualCode(address: smdpAddress, matchingID: matchingID) : EsimValidation.activationCode(activationCode) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StudioNote(symbol: "simcard", text: "Физическая eUICC в SIM-слоте 1. Проверено: 9eSIM V0 и MU5250 B31. Встроенная карта ZTE и обычная SIM не поддерживаются.")
            if model.activeChannel != .ssh && !model.esimPreview {
                StudioNote(symbol: "network", text: "Для eSIM требуется SSH. В «Подготовке модема» выберите SSH и проверьте подключение. Web и ADB для этого раздела не используются.")
            }
            if model.skipFirmwareCheck { StudioNote(symbol: "exclamationmark.triangle", text: "Для eSIM включите проверку прошивки и переподключитесь к B31.") }
            StudioCard {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Профили на карте")).font(.system(size: 19, weight: .semibold))
                        Text(L10n.text("Показываются все профили, включая выключенные")).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    }
                    Spacer()
                    Button { model.performEsim(.list) } label: { Label(L10n.text("Обновить список"), systemImage: "arrow.clockwise") }
                        .buttonStyle(StudioButtonStyle()).disabled(!model.canReadEsim || qrBusy)
                }
                if let snapshot = model.esimSnapshot {
                    HStack {
                        Text("EID · " + EsimPrivacy.mask(snapshot.eid)).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text(L10n.text("Профилей: \(snapshot.profiles.count)")).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    }
                    if snapshot.profiles.isEmpty {
                        Label(L10n.text("На карте пока нет профилей. Добавьте профиль по QR-коду оператора."), systemImage: "simcard")
                            .foregroundStyle(StudioStyle.secondary).padding(.vertical, 18)
                    } else {
                        ForEach(Array(snapshot.profiles.enumerated()), id: \.offset) { _, profile in
                            profileRow(profile)
                        }
                    }
                    HStack(spacing: 12) {
                        Button(L10n.text(selected?.enabled == true ? "Перечитать SIM" : "Сделать активным")) {
                            guard let profile = selected, let iccid = profile.iccid else { return }
                            pending = .enable(iccid); confirmationText = L10n.text(profile.enabled ? "Перечитать SIM для профиля" : "Активировать профиль") + " «" + profile.title + "» (" + profile.maskedICCID + ")? " + L10n.text("Модем временно включит авиарежим, перечитает SIM и вернёт радио в обычный режим. Мобильное подключение прервётся."); confirmationPresented = true
                        }.buttonStyle(StudioButtonStyle()).disabled(!model.canWriteEsim || blocked || selected == nil || selected?.state == "unknown")
                        Button(L10n.text("Удалить профиль"), role: .destructive) {
                            guard let profile = selected, let iccid = profile.iccid else { return }
                            pending = .delete(iccid); confirmationText = L10n.text("Удалить без возможности отмены") + " «" + profile.title + "» (" + profile.maskedICCID + ")? " + L10n.text("Для повторной установки может понадобиться новый код оператора."); confirmationPresented = true
                        }.buttonStyle(StudioButtonStyle()).disabled(!model.canWriteEsim || blocked || selected?.state != "disabled")
                    }
                } else {
                    Text(L10n.text("Нажмите «Обновить список», чтобы проверить карту и прочитать профили.")).foregroundStyle(StudioStyle.secondary).padding(.vertical, 14)
                }
            }
            EsimLauncherCard(model: model)
            StudioCard {
                Text(L10n.text("Добавить профиль")).font(.system(size: 19, weight: .semibold))
                Text(L10n.text("Интернет используется на Mac. Установленный профиль останется выключенным до вашей команды.")).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                Picker(L10n.text("Способ ввода профиля"), selection: $manualInput) {
                    Text(L10n.text("Код LPA / QR")).tag(false)
                    Text("SM-DP+ + Activation code").tag(true)
                }.pickerStyle(.segmented).disabled(blocked)
                if manualInput {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SM-DP+ Address").font(.system(size: 12, weight: .medium))
                        TextField("rsp.example.com", text: $smdpAddress).textFieldStyle(.roundedBorder).accessibilityLabel("SM-DP+ Address").disabled(blocked)
                        Text("Activation code (Matching ID)").font(.system(size: 12, weight: .medium))
                        SecureField(L10n.text("Код, выданный оператором"), text: $matchingID).textFieldStyle(.roundedBorder).accessibilityLabel("Activation code (Matching ID)").disabled(blocked)
                    }
                } else {
                    SecureField("LPA:1$…", text: $activationCode).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.text("Код активации LPA"))
                        .disabled(blocked).onChange(of: activationCode) { _ in inputError = "" }
                }
                HStack {
                    if !manualInput {
                        Button(L10n.text("Вставить код")) { activationCode = NSPasteboard.general.string(forType: .string) ?? "" }.buttonStyle(StudioButtonStyle()).disabled(blocked)
                    }
                    Button { chooseQR() } label: { Label(L10n.text("Выбрать QR-изображение"), systemImage: "qrcode.viewfinder") }.buttonStyle(StudioButtonStyle()).disabled(blocked)
                    Spacer()
                    if preparedCode != nil { Label(L10n.text("Формат LPA распознан"), systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(StudioStyle.accent) }
                }
                SecureField(L10n.text("Код подтверждения, если выдан оператором"), text: $confirmationCode).textFieldStyle(.roundedBorder).disabled(blocked)
                Button(L10n.text("Установить профиль")) {
                    guard let code = preparedCode else { return }
                    pending = .download(code, confirmationCode); confirmationText = L10n.text("Установить профиль на эту 9eSIM? Код оператора может быть одноразовым. Профиль останется выключенным."); confirmationPresented = true
                }.buttonStyle(StudioButtonStyle()).disabled(!model.canWriteEsim || blocked || preparedCode == nil)
                Text(L10n.text("Код не сохраняется и очищается после отправки. Для записи нужен свежий список профилей.")).font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
            }
            if model.busy || qrBusy { HStack { ProgressView().controlSize(.small); Text(L10n.text(qrBusy ? "Читаю QR-код…" : model.esimMessage)) }.font(.system(size: 12)) }
            else if !model.esimMessage.isEmpty { StudioNote(symbol: "checkmark.circle", text: model.esimMessage) }
            if !model.esimError.isEmpty { StudioNote(symbol: "exclamationmark.triangle", text: EsimLog.localizedCardMessage(model.esimError, language: L10n.language)) }
            if !inputError.isEmpty { StudioNote(symbol: "exclamationmark.triangle", text: inputError) }
        }
        .alert(L10n.text("Подтверждение операции eSIM"), isPresented: $confirmationPresented) {
            Button(L10n.text("Отмена"), role: .cancel) { pending = nil }
            Button(L10n.text("Подтвердить"), role: pending?.name == "delete" ? .destructive : nil) {
                if let operation = pending {
                    activationCode = ""; confirmationCode = ""; smdpAddress = ""; matchingID = ""; pending = nil
                    model.performEsim(operation)
                }
            }
        } message: { Text(confirmationText) }
        .onDisappear { activationCode = ""; confirmationCode = ""; smdpAddress = ""; matchingID = ""; pending = nil }
    }
    private func profileRow(_ profile: EsimProfile) -> some View {
        Button {
            if profile.selectable { model.esimSelectedICCID = profile.iccid }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: profile.iccid == model.esimSelectedICCID ? "largecircle.fill.circle" : "circle").foregroundStyle(StudioStyle.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.title).font(.system(size: 14, weight: .semibold))
                    Text(EsimPrivacy.label(profile.serviceProvider ?? "") + " · " + profile.maskedICCID).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.secondary)
                }
                Spacer()
                Text(L10n.text(profile.state == "enabled" ? "Активен" : profile.state == "disabled" ? "Выключен" : "Состояние неизвестно"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(profile.enabled ? StudioStyle.accent : StudioStyle.secondary)
            }.padding(13).background(StudioStyle.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(blocked || !profile.selectable).accessibilityLabel(profile.title + ", " + profile.maskedICCID)
    }
    private func chooseQR() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.title = L10n.text("Выберите изображение с одним QR-кодом LPA")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        qrBusy = true; inputError = ""
        Task {
            do { activationCode = try await Task.detached { try EsimQR.read(url) }.value; manualInput = false }
            catch { inputError = "Нужен один QR-код с корректным LPA-кодом. Код не был отправлен." }
            qrBusy = false
        }
    }
}

/// Shared entry point in eSIM and Launcher. It installs the complete extension
/// bundle while leaving the modem's saved information-page layout untouched.
@MainActor struct EsimLauncherCard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        StudioCard {
            Label(L10n.text("Страница eSIM на экране модема"), systemImage: "simcard")
                .font(.system(size: 17, weight: .semibold))
            Text(L10n.text("Все профили карты и выбор активного профиля прямо на дисплее модема. После переключения модем перечитает SIM через авиарежим и вернёт радио в обычный режим."))
                .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Обновляются агент и пакет Launcher. eSIM добавляется в конец, если её нет среди выбранных страниц. Прежний порядок, раскладка и настройки VPN сохраняются. Экран может перезапуститься."))
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("Установить / обновить страницу eSIM"), action: model.installEsimDisplay)
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canInstallEsimDisplay)
                Button(L10n.text("Проверить Launcher"), action: model.refreshDisplay)
                    .buttonStyle(StudioButtonStyle()).disabled(!model.canManage || model.esimPreview)
            }
            if let state = model.displayInspection {
                Text(L10n.text(state.title)).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
            if !model.displayLayoutMessage.isEmpty {
                Text(L10n.text(model.displayLayoutMessage)).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            }
            if !model.displayError.isEmpty {
                Text(L10n.text(model.displayError)).font(.system(size: 12)).foregroundStyle(StudioStyle.warning)
            }
        }
    }
}
