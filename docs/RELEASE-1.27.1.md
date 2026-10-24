# 1.27.1 — eUICC detection and ADB recovery

[GitHub release](https://github.com/SadykovIV/ZTE_U60Pro/releases/tag/v1.27.1) · [Windows x64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.27.1/ZTE-U60Pro-Manager-1.27.1-Windows-x64-portable.zip) · [macOS ARM64](https://github.com/SadykovIV/ZTE_U60Pro/releases/download/v1.27.1/ZTE-U60Pro-Manager-1.27.1-macOS-arm64.zip)

macOS build **68** · Windows FileVersion **1.27.1.0** · Agent **2.9.0-esim.15** · VPN controller **1.5.0**.

## Русский

Исправлено определение съёмной eUICC, включая проверенную карту 9eSIM. Некоторые
карты отвечают на выбор приложения ISD-R кодом `61xx`: это запрос продолжения
ответа, который прежняя версия ошибочно считала отказом. Теперь helper получает
продолжение через `GET RESPONSE` на том же открытом логическом канале. Число
обменов и размер ответа ограничены. Код отсутствия приложения `6A82` означает
обычную SIM только в ответе на первоначальный `SELECT`.

Ошибки чтения карты больше не называются ошибками очистки, если завершение
сеанса подтверждено. Клиенты и веб-панель различают неудачное чтение
(`snapshot_failed`) и неподтверждённое завершение сеанса. Сообщение о готовности
SIM не утверждает, что радио было переключено. В журнале счётчик показан как
`lpac_apdu_count`: он относится к обменам lpac, а не ко всем командам обнаружения
карты. Неудачное чтение не подтверждает тип SIM и не разрешает изменение профилей.

После восстановления SSH приложение сверяет незавершённое переключение ADB
с сохранённым состоянием и текущим устройством. Подтверждённая завершённая или
не начавшаяся операция архивируется, поэтому потерянный ответ или ошибка удаления
временных файлов не оставляют постоянный блокировщик. Восстановление выполняет
текущий проверенный helper; старый сценарий не запускается. Повторное применение
команды, подтверждение ACK и переподключение USB при сверке не выполняются.
После перезагрузки старое намерение снимается только при повторном подтверждении
того же устройства и отсутствия прежних временных файлов и блокировки.

Если компоненты VPN остались от старого выпуска, обновите их обычной кнопкой
установки в разделе VPN, затем выключите и снова включите VPN Wi-Fi.
Обновление сохраняет профили, но уже запущенный процесс использует прежние
функции до перезапуска VPN. Обновление одного агента не заменяет этот шаг.

### Проверки и ограничения

На модеме B31 установлены исправленный агент и веб-панель. Установленный агент
определил съёмную 9eSIM как eUICC и прочитал два профиля, один активный;
завершение сеанса подтверждено. Профили не изменялись. Проверено сохранение
процессов SSH и IPsec без перезапуска при обновлении.

Локальные проверки покрывают продолжение APDU, обработку ошибок и журналирование
обоих клиентов, а также прерывания и восстановление ADB. Восстановление ADB для
B04 проверяется на синтетических сценариях; на модеме друга оно не проверено.
Запуск Windows EXE в Windows не проверен. Итоговые результаты сборки и тестов
фиксируются в `VERIFICATION.json` релиза.

[Подробная проверка B04 и порядок обновления](https://github.com/SadykovIV/ZTE_U60Pro/blob/v1.27.1/docs/B04-VERIFICATION-1.27.1.md)
отделяет сведения из отчёта, локальные проверки и оставшиеся проверки на устройстве.
В обычный диагностический отчёт добавлены текущие метаданные IPA без изменения
настроек устройства; точная причина прежних IPA-сбоев пока не установлена.

## English

Removable-eUICC detection now handles cards, including the tested 9eSIM, that
answer ISD-R selection with `61xx`. This requests response continuation; the
previous helper incorrectly rejected it. The helper now issues bounded
`GET RESPONSE` commands on the same owned logical channel. Only `6A82` from
the initial `SELECT` identifies an ordinary SIM.

A failed card read now reports `snapshot_failed` when session cleanup is
confirmed, instead of incorrectly reporting a cleanup failure. Both desktop
clients and the dashboard retain separate handling for uncertain cleanup.
SIM-readiness messages no longer imply a radio change. The journal displays
`lpac_apdu_count` to clarify that the counter covers lpac exchanges, not every
card-detection command. Failed reads leave the card type unknown and do not
authorize profile changes.

ADB recovery now reconciles a saved operation against the same device and its
recorded USB state after SSH reconnects. Confirmed completed or unstarted
operations are archived, including when a final reply or temporary-file cleanup
was lost. Recovery runs the current verified helper, never the old staged
script, and does not replay apply/ACK or reconnect USB. After reboot, retiring
old intent requires repeated same-device proofs and absence of its stage and
lock.

If VPN components remain from an older release, update them using the existing
VPN installation action, then turn VPN Wi-Fi off and on. Profiles are preserved,
but an already running supervisor keeps its loaded functions until VPN restarts.
Updating the agent alone does not update that running VPN process.

### Verification and limitations

On B31 hardware, the updated agent and dashboard were installed. The installed
agent identified a removable 9eSIM as eUICC and read two profiles, one enabled,
with confirmed session cleanup and no profile changes. SSH and IPsec process
identity was verified unchanged across the update.

Local tests cover APDU continuation, desktop diagnostics, and interrupted ADB
operations. B04 ADB recovery is covered by synthetic scenarios only; it has not
been tested on the friend's modem. Native Windows execution has not been
verified. Final build and test results are recorded in the release's
`VERIFICATION.json`.

The [B04 verification report](https://github.com/SadykovIV/ZTE_U60Pro/blob/v1.27.1/docs/B04-VERIFICATION-1.27.1.md)
separates observed evidence, local tests, and remaining device checks. Existing
diagnostic reports now include passive current IPA metadata. The precise cause
of historical IPA failures remains undetermined.
