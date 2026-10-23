# Release numbering

The current development release is **1.27**.

- Substantial feature or architecture changes advance the second number:
  `1.25`, `1.26`, `1.27`.
- Small fixes within that release add a patch number:
  `1.25.1`, `1.25.2`.
- macOS and Windows use the same public version. macOS build numbers and
  Windows four-part assembly/file versions are internal identifiers; for
  example, public `1.25` uses Windows `1.25.0.0`.
- Each handed-off build receives a new version. Keep earlier release archives
  and their verification reports unchanged.
- Agent and modem component versions remain separate. Change their version
  when their implementation changes, and package matching resource hashes.

## Нумерация выпусков

Крупные обновления: **1.25 → 1.26 → 1.27**.
Небольшие исправления: **1.25.1 → 1.25.2**.
Версия программы одинакова на macOS и Windows. Ранее переданные сборки
сохраняются вместе с контрольными суммами и результатами проверок.
