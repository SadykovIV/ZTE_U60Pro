#!/usr/bin/env python3
"""Assemble the same public eSIM runtime resources for both desktop clients."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
LPAC = ROOT / 'third_party/lpac'
CERT = ROOT / 'tools/removable-euicc/certs/gsma-rsp-roots.pem'
CERT_SHA = '7364a2ac4d2b5f77c1b83ee7e1c535e8fc806c67ee42e73ad97c35464d203477'
BASELINE_REF = 'da091fb7e6af804b81d51b913c20eb848303982e'
BASELINE_DEPENDENCIES_SHA = '29c00a9cc4bd76f5190141be668230acf00ad008871fad72a200e17f40d4883b'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def baseline_dependencies():
    """Keep the pinned bootstrap manifest, also when rebuilding an extracted archive."""
    current = (ROOT / 'tools/dependencies.json').read_bytes()
    if sha(current) == BASELINE_DEPENDENCIES_SHA:
        return current
    result = subprocess.run(['git', 'show', BASELINE_REF + ':tools/dependencies.json'],
                            cwd=ROOT, check=True, capture_output=True)
    if sha(result.stdout) != BASELINE_DEPENDENCIES_SHA:
        raise SystemExit('Baseline dependency snapshot identity mismatch')
    return result.stdout


def source_archive():
    """Deterministic corresponding source with no evidence, caches or build paths."""
    items = {}
    selected = ['third_party/lpac', 'third_party/lpac-build', 'tools/removable-euicc/certs',
        'tools/removable-euicc/device/src', 'tools/removable-euicc/device/Cargo.toml',
        'tools/removable-euicc/device/Cargo.lock', 'tools/removable-euicc/device/component.json',
        'tools/removable-euicc/device/COMPONENT-NOTICE.txt',
        'tools/removable-euicc/device/.cargo', 'tools/removable-euicc/device/README.md',
        'ModemAgent/agent/src', 'ModemAgent/agent/Cargo.toml', 'ModemAgent/agent/resources/esim',
        'ModemAgent/process-runner', 'ModemAgent/vpnctl', 'ModemAgent/launcher',
        'ModemAgent/Cargo.toml','ModemAgent/Cargo.lock','ModemAgent/.cargo','ModemAgent/LICENSE',
        'ModemAgent/scripts/build-esim-agent.sh','ModemAgent/web-app/src','ModemAgent/web-app/public',
        'ModemAgent/web-app/tools','ModemAgent/web-app/package.json','ModemAgent/web-app/package-lock.json',
        'ModemAgent/web-app/vite.config.ts','ModemAgent/web-app/tsconfig.json','ModemAgent/web-app/tsconfig.app.json',
        'ModemAgent/web-app/tsconfig.node.json','ModemAgent/web-app/index.html','ModemAgent/web-app/tailwind.config.js',
        'ModemAgent/web-app/postcss.config.js','ModemAgent/web-app/eslint.config.js',
        'tools/esim-app/fixtures', 'tools/esim-app/build_runtime.py','tools/esim-app/package_resources.py','tools/esim-app/package_permanent.py','tools/esim-app/verify_public_build.py','tools/esim-app/verify_public_release.py','tools/esim-app/test_source_packaging.py','tools/esim-app/test_discovery_agent_http.py',
        'tools/build.py','tools/fetch_dependencies.py','tools/dependencies.json',
        'MacIMEI/Sources/BundledAgent.swift','MacIMEI/Sources/VPNSettings.swift',
        'Windows_x64/Resources/Onboarding/provenance.json',
        'Windows_x64/sync_public_resources.py',
        'docs/ESIM-APP-CONTRACT.md','docs/ESIM-DESKTOP.md','docs/DEVICE-DISCOVERY-CONTRACT.md','third_party/ESIM-SOURCES.md','LICENSE-SCOPE.md']
    # Include local installation recipes and manifests. Pinned baseline binaries
    # are obtained with tools/fetch_dependencies.py before the modem build.
    for group in ['VPN','AgentInstallation','Onboarding','SSHAccounts']:
        base=ROOT/'MacIMEI/Resources'/group
        for path in sorted(base.rglob('*')):
            if path.is_file() and (path.suffix in {'.sh','.lua','.md','.txt','.json','.conf','.nft'} or path.name=='network.stock'):
                selected.append(str(path.relative_to(ROOT)))
    for relative in selected:
        base=ROOT/relative
        if not base.exists():continue
        for path in sorted(base.rglob('*')) if base.is_dir() else [base]:
            rel=path.relative_to(ROOT)
            if not path.is_file() or path.is_symlink() or {'target','.git','node_modules','__pycache__'}.intersection(rel.parts):continue
            if path.suffix in {'.pyc','.o','.a','.so','.log'} or path.name=='.DS_Store':continue
            items[str(rel)]=path
    dependency_snapshot = baseline_dependencies()
    import gzip
    output=io.BytesIO()
    with gzip.GzipFile(fileobj=output,mode='wb',filename='',mtime=0) as gz, tarfile.open(fileobj=gz,mode='w') as archive:
        for name,path in sorted(items.items()):
            data=dependency_snapshot if name=='tools/dependencies.json' else path.read_bytes()
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o644;info.mtime=0
            archive.addfile(info,io.BytesIO(data))
    return output.getvalue(),len(items)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--agent', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    args = parser.parse_args()
    agent = args.agent.read_bytes()
    if sha(agent) != args.sha256 or agent[:6] != b'\x7fELF\x02\x01' or int.from_bytes(agent[18:20], 'little') != 183:
        raise SystemExit('Agent identity or ARM64 ELF validation failed')
    if sha(CERT.read_bytes()) != CERT_SHA:
        raise SystemExit('GSMA certificate identity mismatch')
    sources, count = source_archive()
    readme = '''# eSIM для физической eUICC

Версия агента: 2.9.0-esim.4. Приложения: ZTE U60Pro Manager 1.24.4.

Нужна съёмная физическая eUICC в SIM-слоте модема. Проверено: 9eSIM V0,
ZTE MU5250, CN_ZTE_MU5250V1.0.0B31. Обычная SIM распознаётся отдельно:
управление профилями для неё недоступно. Встроенная eSIM ZTE этим
компонентом не поддерживается. Чтение, установка и удаление профилей
проверяют доступ к eUICC через QMI. Переключение с перезапуском радио
пока требует проверенной прошивки B31.

Откройте eSIM в левом меню, подключитесь по SSH и запросите профили.
Для установки вставьте LPA-код, выберите изображение QR или переключитесь
на отдельные поля SM-DP+ Address и Activation code (Matching ID).
Если оператор выдал отдельный код подтверждения, введите его ниже.
Установка сохраняет новый профиль выключенным. Активный профиль выбирается
отдельной кнопкой. Удаление требует подтверждения; активный профиль удалить
нельзя. Повторное использование QR зависит от оператора.

HTTPS выполняет компьютер, поэтому нужен его доступ к интернету.
eSIM-агент передаётся в приватный временный каталог модема на время операции.
Кнопка установки штатного агента теперь устанавливает постоянную сборку
zte-agent-esim вместе с веб-панелью eSIM. --esim-check показывает версию,
--esim-rpc обслуживает программы. Веб-панель использует интернет модема;
для пустой карты без интернета модема используйте программу на компьютере.
Запуск без параметров запускает обычный сервер агента; не запускайте его
параллельно с другим сервером на том же порту.

Проверка TLS включена. Ко всем допустимым адресам eSIM применяется общий
закреплённый набор production-корней GSMA вместе с системными корнями.
Имя, срок и цепочка проверяются; системное хранилище не изменяется.
Ограничения оператора и доверие внутри eUICC остаются в силе.
Приложения не сохраняют коды активации и содержимое протокола в диагностике.
При потере связи запросите профили заново перед повторной попыткой.
Переключение подтверждается только после автономного режима, возврата радио
и совпадения свежего ICCID модема с выбранным профилем. В автономном режиме
агент выключает и включает питание SIM-слота 1, затем ждёт готовность USIM. Нажатие на уже активный
профиль повторно читает SIM без повторной команды включения профиля.
Регистрацию в сети и доступ к интернету проверяйте отдельно.

Кнопка «Страница eSIM на экране модема» добавляет страницу в лаунчер.
Она сохраняет выбранные страницы, их порядок и текущую раскладку показателей.
В разделе Launcher можно выбрать страницы галочками и задать их порядок.
На экране модема доступны список, выбор профиля и перечитывание активной SIM.
Установку по QR и удаление выполняйте в программе или веб-панели агента.

Третьи стороны: lpac v2.3.0, commit c2fcf5e4b21c712d54e35a11da2ad9ad134fb821,
с двумя закреплёнными исправлениями stdio; адаптированный QMI/ES10-компонент
и защищённый bridge. Статус лицензии QMI/ES10: license_unspecified.
MIT-лицензия базового агента не предоставляет прав на этот компонент.
Уведомление NOTICE-QMI-ES10.txt не является лицензией или заявлением
единоличного авторства. Лицензии других компонентов сохранены отдельно.
Исходники, изменения и сборочные скрипты находятся в eSIM-sources.tar.gz;
текущие хэши компонента — в device/component.json внутри архива.
PROVENANCE.json и LICENSE-SCOPE.md уточняют состав и сферу лицензирования.
'''
    payloads = {
        'zte-agent-esim': agent,
        'gsma-rsp-roots.pem': CERT.read_bytes(),
        'README.md': readme.encode(),
        'eSIM-sources.tar.gz': sources,
        'LICENSE-lpac-AGPL-3.0.txt': (LPAC / 'src/LICENSE').read_bytes(),
        'LICENSE-libeuicc-LGPL-2.1.txt': (LPAC / 'euicc/LICENSE').read_bytes(),
        'LICENSE-cJSON-MIT.txt': (LPAC / 'cjson/LICENSE').read_bytes(),
        'LICENSE-agent-MIT.txt': (ROOT / 'ModemAgent/LICENSE').read_bytes(),
        'NOTICE-QMI-ES10.txt': (ROOT / 'tools/removable-euicc/device/COMPONENT-NOTICE.txt').read_bytes(),
        'LICENSE-SCOPE.md': (ROOT / 'LICENSE-SCOPE.md').read_bytes(),
    }
    provenance = {
        'agent_version': '2.9.0-esim.4', 'agent_sha256': sha(agent),
        'lpac_version': '2.3.0 + pinned stdio backports',
        'lpac_commit': 'c2fcf5e4b21c712d54e35a11da2ad9ad134fb821',
        'lpac_linux_sha256': sha((ROOT/'ModemAgent/agent/resources/esim/lpac').read_bytes()),
        'qmi_bridge_sha256': sha((ROOT/'ModemAgent/agent/resources/esim/bridge').read_bytes()),
        'qmi_component': json.loads((ROOT / 'tools/removable-euicc/device/component.json').read_text()),
        'qmi_component_manifest_sha256': sha((ROOT / 'tools/removable-euicc/device/component.json').read_bytes()),
        'license_status': {'qmi_es10': 'license_unspecified'},
        'archived_dependency_snapshot': {'path': 'tools/dependencies.json', 'source_ref': BASELINE_REF, 'sha256': BASELINE_DEPENDENCIES_SHA},
        'source_archive_files': count, 'source_archive_sha256': sha(sources),
        'gsma_pem_sha256': CERT_SHA,
        'gsma_roots': json.loads((CERT.parent / 'gsma-rsp-roots.json').read_text()),
        'scope': 'physical removable eUICC; 9eSIM V0; MU5250 B31; SSH',
        'profile_mutations_hardware_tested_in_desktop_release': False,
    }
    payloads['PROVENANCE.json'] = (json.dumps(provenance, indent=2, ensure_ascii=False) + '\n').encode()
    manifest = {name: sha(data) for name, data in payloads.items()}
    payloads['SHA256.json'] = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    for app in ['MacIMEI', 'Windows_x64']:
        destination = ROOT / app / 'Resources/Esim'
        destination.mkdir(parents=True, exist_ok=True)
        # This input moved to a common bundle; frozen release archives remain intact.
        (destination / 'gsma-rsp2-root-ci1.pem').unlink(missing_ok=True)
        for name, data in payloads.items():
            (destination / name).write_bytes(data)
        (destination / 'zte-agent-esim').chmod(0o755)
    print(json.dumps({'resources_identical': True, 'agent_sha256': sha(agent),
                      'source_files': count, 'source_archive_bytes': len(sources),
                      'files': sorted(payloads)}, indent=2))


if __name__ == '__main__':
    main()
