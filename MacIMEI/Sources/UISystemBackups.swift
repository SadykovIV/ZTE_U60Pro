import SwiftUI

extension ContentView {
    var systemBackupsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudioCard {
                Text("Полный образ модема").font(.system(size: 18, weight: .semibold))
                Text("Основная область eMMC со всеми разделами и таблицей GPT, плюс boot0 и boot1. Включает ZTEDATA, обе версии прошивки, настройки, приложения и данные модемной части. Защищённая область RPMB не копируется.")
                    .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                StudioNote(symbol: "externaldrive", text: "Образ передаётся прямо на Mac и содержит личные данные без шифрования. Копия работающего модема не является согласованным снимком: во время чтения его данные могут изменяться. Для точного снимка используйте среду восстановления с остановленной модемной частью.")
                HStack {
                    Button(action: model.createSystemBackup) { Label("Создать полный образ", systemImage: "externaldrive.badge.plus") }
                        .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canUseSystemBackupConnection || model.systemRestorePending)
                    Button("Импортировать…", action: model.importSystemBackup).buttonStyle(StudioButtonStyle()).disabled(model.busy)
                    Spacer()
                    Button(action: model.revealSystemBackups) { Image(systemName: "folder") }.help("Папка полных образов").buttonStyle(StudioButtonStyle())
                    Button(action: model.refreshSystemBackups) { Image(systemName: "arrow.clockwise") }.help("Обновить список").buttonStyle(StudioButtonStyle()).disabled(model.busy)
                }
                if model.systemBackupCanCancel {
                    Button("Отменить создание образа", action: model.cancelSystemBackup).buttonStyle(StudioButtonStyle())
                }
                if model.systemRestorePending {
                    StudioNote(symbol: "arrow.clockwise.circle", text: "Есть незавершённое восстановление. Оставьте модем в среде восстановления, выберите исходный образ и нажмите «Проверить восстановление». Приложение проверит журнал и уже записанные блоки. Другие изменения модема заблокированы.")
                }
                ForEach(model.systemBackups) { item in
                    Button { model.selectSystemBackup(item.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: model.selectedSystemBackupID == item.id ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.created).font(.system(size: 12, weight: .medium))
                                Text("CID …\(item.inventory.cid.suffix(8)) · " + (item.isLiveCapture ? "Работающий модем" : "Среда восстановления"))
                                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.system(size: 11))
                        }.padding(10).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.busy)
                }
                if model.selectedSystemBackup != nil {
                    HStack {
                        Button("Проверить целостность", action: model.verifySystemBackup).buttonStyle(StudioButtonStyle()).disabled(model.busy)
                        Button("Экспортировать…", action: model.exportSystemBackup).buttonStyle(StudioButtonStyle()).disabled(model.busy)
                        Button("Проверить восстановление", action: model.prepareSystemRestore).buttonStyle(StudioButtonStyle()).disabled(!model.canUseSystemBackupConnection)
                    }
                }
                Text("Полное восстановление требует отдельной загрузки Linux из RAM: накопитель должен быть отключён от файловых систем, а модемная часть остановлена. Приложение проверяет эти условия по SSH. Образ recovery и автоматический вход в этот режим в комплект не входят.")
                    .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let plan = model.systemRestorePlan {
                StudioCard {
                    Text(plan.isResume ? "Продолжение восстановления" : "План восстановления").font(.system(size: 16, weight: .semibold))
                    informationRow("Модем", plan.inventory.cid)
                    informationRow("Исходный образ", plan.backup.created)
                    informationRow("Будет заменено", ByteCountFormatter.string(fromByteCount: plan.backup.bytes, countStyle: .file) + " · eMMC, boot0, boot1")
                    if !plan.canRestore {
                        StudioNote(symbol: "lock", text: plan.inventory.offlineExplanation)
                    } else {
                        Text("Перед первой записью программа сохранит текущий полный образ. Каждый блок проверяется до передачи и после записи. При наличии интерфейсов ZTE программа вызывает отключение Flash Protect перед записью и включение после неё. Отключение питания может оставить неполный образ; журнал сохраняется на Mac.")
                            .font(.system(size: 12)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
                        if plan.requiresLiveCaptureAcknowledgement {
                            Toggle("Понимаю, что образ снят с работающего модема и его файловые системы могут потребовать восстановления", isOn: $model.systemAllowLiveCapture)
                                .font(.system(size: 12)).disabled(model.busy)
                        }
                        Text("Для подтверждения введите: ВОССТАНОВИТЬ \(plan.inventory.cid.suffix(8))").font(.system(size: 12))
                        TextField("Подтверждение", text: $model.systemRestoreConfirmation).textFieldStyle(.roundedBorder).disabled(model.busy)
                        Button(plan.isResume ? "Продолжить восстановление" : "Восстановить модем", action: model.executeSystemRestore)
                            .buttonStyle(StudioButtonStyle(prominent: true)).disabled(!model.canExecuteSystemRestore)
                    }
                }
            }
        }
    }
}
