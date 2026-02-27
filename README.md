# KubeconfigEditor (macOS)

Native desktop kubeconfig editor for macOS (SwiftUI).

## English

### Features
- Open and edit kubeconfig YAML files.
- Manage `contexts`, `clusters`, and `users` in separate tabs.
- Add, rename, and remove entries.
- Multi-select in list and bulk remove/export for selected contexts.
- Mark entities as hidden (`eye` toggle):
  - hidden entries stay in app storage;
  - hidden contexts are excluded from main kubeconfig save.
- Set selected context as current and save.
- Import full kubeconfig text:
  - import as new entries;
  - merge into selected context with preview and selective apply.
- YAML validation before save (and optional background auto-validation).
- Safe editing model:
  - edits are done in draft/session state;
  - source file is changed only on explicit `Save`.
- Built-in versioning with embedded git (`libgit2` via SwiftGitX):
  - snapshot commit on save;
  - version list and rollback.
- Undo/Redo for step-by-step local changes.
- Background update check on app launch (GitHub Releases).
- In-app bottom-right update toast with one-click auto-update for installed `.app` builds.

### Run
```bash
git clone https://github.com/deadnodes/kubeconfig-editor.git
cd kubeconfig-editor
swift run KubeconfigEditor
```

If the process runs but no app window appears:
```bash
cd kubeconfig-editor
swift build --build-path .build-local
open .build-local/debug/KubeconfigEditor
```

### Build (release)
```bash
cd kubeconfig-editor
swift build --build-path .build-local -c release
```

Binary path:
```text
.build-local/release/KubeconfigEditor
```

### Package to DMG
```bash
cd kubeconfig-editor
./scripts/package_dmg.sh
```

Output:
```text
dist/KubeconfigEditor.app
dist/KubeconfigEditor-${VERSION}.dmg
```

Optional DMG background:
```text
assets/dmg-background.png
```
If present, packaging script applies custom Finder layout with drag-and-drop flow (`.app` -> `Applications`).

Optional signing:
```bash
cd kubeconfig-editor
APPLE_DEV_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/package_dmg.sh
```

Optional notarization (recommended for distribution to other Macs):
```bash
cd kubeconfig-editor
APPLE_DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="AC_NOTARY_PROFILE" \
./scripts/package_dmg.sh
```

Remove quarantine (if macOS blocks first launch):
```bash
sudo xattr -dr com.apple.quarantine "/Applications/KubeconfigEditor.app"
```

### App data location
```text
~/Library/Application Support/KubeconfigEditor
```

Subfolders:
- `drafts/` - draft/session files.
- `git-repos/` - internal repositories with saved versions.
- `logs/` - change logs.
- `detached-store/` - hidden/non-exported entities storage.

### Auto-update source
- Updates are checked from GitHub Releases: `deadnodes/kubeconfig-editor`.
- For auto-update install, publish release assets as `.zip` or `.dmg` containing `KubeconfigEditor.app`.
- Version tags should be semantic (for example: `v1.2.3`).

### App icon
Put icon PNG here:
```text
assets/icon.png
```

Recommended size: `1024x1024`.

`./scripts/package_dmg.sh` will generate `AppIcon.icns` and embed it into the app bundle.

You can also generate icon manually:
```bash
cd kubeconfig-editor
./scripts/generate_icon.sh
```

Optional strict minimum size:
```bash
ICON_MIN_SIZE=1024 ./scripts/generate_icon.sh
```

### Versioning and releases
- Project version is stored in root `VERSION` file.
- Changelog is stored in `CHANGELOG.md`.
- GitHub Actions workflow `.github/workflows/release.yml`:
  - reads version from `VERSION`;
  - compares it with latest GitHub Release tag;
  - creates a new release only when `VERSION` is greater;
  - builds DMG and uploads it to GitHub Releases;
  - does not overwrite existing releases (immutable policy).

---

## Русский

### Возможности
- Открытие и редактирование kubeconfig в формате YAML.
- Раздельные вкладки для `contexts`, `clusters`, `users`.
- Добавление, переименование и удаление сущностей.
- Множественный выбор в списке и массовое удаление/экспорт выбранных контекстов.
- Скрытие сущностей через `глаз`:
  - скрытые записи остаются во внутреннем хранилище приложения;
  - скрытые контексты не попадают в основной kubeconfig при сохранении.
- Установка выбранного контекста как текущего с мгновенным сохранением.
- Импорт полного kubeconfig-текста:
  - как новые сущности;
  - merge в выбранный контекст с preview и выборочным применением изменений.
- Проверка YAML перед сохранением (и опциональная фоновая автопроверка).
- Безопасное редактирование:
  - все правки идут в черновик/сессию;
  - исходный файл меняется только по явной кнопке `Save`.
- Встроенное версионирование через embedded git (`libgit2`/SwiftGitX):
  - коммит на каждое сохранение;
  - просмотр версий и откат.
- `Undo/Redo` по локальным шагам редактирования.
- Фоновая проверка обновлений при запуске (GitHub Releases).
- Встроенное уведомление в правом нижнем углу и кнопка автообновления для установленной `.app`-версии.

### Запуск
```bash
git clone https://github.com/deadnodes/kubeconfig-editor.git
cd kubeconfig-editor
swift run KubeconfigEditor
```

Если процесс запустился, но окна не видно:
```bash
cd kubeconfig-editor
swift build --build-path .build-local
open .build-local/debug/KubeconfigEditor
```

### Сборка release
```bash
cd kubeconfig-editor
swift build --build-path .build-local -c release
```

Путь к бинарнику:
```text
.build-local/release/KubeconfigEditor
```

### Упаковка в DMG
```bash
cd kubeconfig-editor
./scripts/package_dmg.sh
```

Результат:
```text
dist/KubeconfigEditor.app
dist/KubeconfigEditor-${VERSION}.dmg
```

Опциональный фон для DMG:
```text
assets/dmg-background.png
```
Если файл есть, скрипт применит кастомный layout Finder под drag-and-drop (`.app` -> `Applications`).

Подпись (опционально):
```bash
cd kubeconfig-editor
APPLE_DEV_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/package_dmg.sh
```

Нотаризация (рекомендуется для установки на другие Mac):
```bash
cd kubeconfig-editor
APPLE_DEV_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="AC_NOTARY_PROFILE" \
./scripts/package_dmg.sh
```

Снять карантин (если macOS блокирует первый запуск):
```bash
sudo xattr -dr com.apple.quarantine "/Applications/KubeconfigEditor.app"
```

### Где хранятся данные приложения
```text
~/Library/Application Support/KubeconfigEditor
```

Подпапки:
- `drafts/` - черновики/сессии.
- `git-repos/` - внутренние репозитории с историей сохранений.
- `logs/` - логи изменений.
- `detached-store/` - хранилище скрытых/неэкспортируемых сущностей.

### Источник автообновлений
- Проверка обновлений идет из GitHub Releases: `deadnodes/kubeconfig-editor`.
- Для автоустановки релиз должен содержать `.zip` или `.dmg` с `KubeconfigEditor.app`.
- Теги версий должны быть семантическими (например: `v1.2.3`).

### Иконка приложения
Положи PNG-иконку сюда:
```text
assets/icon.png
```

Рекомендуемый размер: `1024x1024`.

`./scripts/package_dmg.sh` автоматически соберет `AppIcon.icns` и встроит иконку в `.app`.

Можно сгенерировать иконку отдельно:
```bash
cd kubeconfig-editor
./scripts/generate_icon.sh
```

Опционально можно задать строгий минимальный размер:
```bash
ICON_MIN_SIZE=1024 ./scripts/generate_icon.sh
```

### Версионирование и релизы
- Версия проекта хранится в файле `VERSION` в корне.
- История изменений хранится в `CHANGELOG.md`.
- GitHub Actions workflow `.github/workflows/release.yml`:
  - читает версию из `VERSION`;
  - сравнивает ее с последним тегом GitHub Release;
  - создает релиз только если версия в `VERSION` больше;
  - собирает DMG и загружает его в GitHub Releases;
  - не перезаписывает существующие релизы (immutable policy).
