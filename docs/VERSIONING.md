# Release numbering

Current release: **1.29**, macOS build **71**, Windows FileVersion **1.29.0.0**,
agent **2.11.0**, VPN controller **1.5.1**. It unifies standard 1.27.2 and the
local Internal eUICC 1.28 variant. Earlier archives remain unchanged.

Substantial changes advance the second number; small fixes add a patch number.
macOS and Windows use the same public release version. Their internal build
numbers do not replace that version. Agent and modem component versions remain
separate and their exact hashes must match the packaged resources.

Each handed-off build receives a new version. Keep previous artifacts, manifests
and verification reports. A version number does not establish hardware testing:
record source identity, build checks, native execution and device operations
separately. The historical local 1.28 hardware report remains a dated prior run.

## Нумерация выпусков

Текущий единый выпуск — **1.29**, macOS build **71**, Windows **1.29.0.0**,
агент **2.11.0**. Предыдущий опубликованный выпуск — **1.27.2**; локальная
альтернатива **1.28** сохранена отдельно. Большие изменения: `1.27 → 1.29`,
исправления внутри выпуска: `1.29.1`. Старые комплекты не перезаписываются.
