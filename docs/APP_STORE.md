# Публикация Kumquat в Mac App Store

Версия для App Store собирается отдельно (`scripts/build-appstore.sh`): она работает в песочнице (App Sandbox), содержит свой ffmpeg и не использует Pages, Keynote, LibreOffice и Homebrew. Код, ffmpeg, скриншоты и тексты готовы; ниже — шаги, которые можно сделать только из вашего аккаунта Apple.

## 1. Сборка и подпись (уже настроено)

Команда **Pavel Bardin (9R756Z2ZZG)**, Bundle ID **ru.pabit.kumquat**. Подпись автоматическая: Xcode сам регистрирует Bundle ID, выпускает профиль и подписывает облачными сертификатами Apple Distribution и Mac Installer Distribution — ничего создавать на developer.apple.com вручную не нужно. Нужно только, чтобы в Xcode → Settings → Accounts был ваш Apple ID этой команды.

```bash
./scripts/build-appstore.sh            # → build/xc/export/Kumquat.pkg
./scripts/build-appstore.sh --upload   # собрать и сразу загрузить в App Store Connect
```

Номер сборки берётся из числа коммитов и растёт сам. Проект Xcode генерируется из `project.yml` (`xcodegen generate`).

Проверка в песочнице без подписи:

```bash
./scripts/build-appstore.sh --local
build/appstore/Kumquat.app/Contents/MacOS/Kumquat --selftest
```

## 2. Карточка приложения в App Store Connect

https://appstoreconnect.apple.com → Apps → **+** → New App:

- Platform: macOS
- Name: `Kumquat: File Converter` (если имя занято, Apple скажет сразу — тогда, например, `Kumquat Converter`)
- Primary Language: English (U.S.) — русскую локализацию добавьте потом кнопкой рядом с языком
- Bundle ID: `ru.pabit.kumquat` (выберите из списка)
- SKU: `kumquat-mac`

Дальше заполните поля по `docs/appstore/metadata.md`: тексты на двух языках, ключевые слова, ссылки, категория, возрастной рейтинг, App Privacy («Data Not Collected»), цена Free, заметки для ревьюера. Скриншоты — из `docs/appstore/screenshots/` (`en-*` для английской локализации, `ru-*` для русской).

## 3. Загрузка сборки

```bash
./scripts/build-appstore.sh --upload
```

или перетащите `build/xc/export/Kumquat.pkg` в приложение **Transporter**. Через 10–30 минут сборка появится в App Store Connect → ваше приложение → версия 1.2 → **Build**.

## 4. Отправка на ревью

**Add for Review** → **Submit**. Ревью обычно занимает 1–3 дня. Если Apple что-то отклонит, ответ придёт в Resolution Center — пришлите его текст, разберём.

## Что отличается от версии с GitHub

| | GitHub (DMG) | App Store |
|---|---|---|
| Песочница | нет | да; при первом запуске нужно разрешить доступ к домашней папке |
| ffmpeg | встроен | встроен |
| Экспорт в .pages, чтение .pages | через Pages | нет |
| Презентации → PDF | через Keynote или LibreOffice | нет (только картинка первого слайда) |
| Старые .xls, .numbers | через LibreOffice | нет |
| Обновления | вручную | через App Store |

## Возможные вопросы на ревью

- **ffmpeg и LGPL.** ffmpeg собран без GPL-частей, как отдельный исполняемый файл; лицензии и ссылка на исходники — в «Настройки → Лицензии открытого ПО». Скрипт сборки — `scripts/build-ffmpeg.sh`. Многие приложения в App Store поставляют ffmpeg так же, но юридически вопрос совместимости LGPL с условиями App Store не закрыт окончательно; если Apple или правообладатель возразят, вариант отступления — версия на одних системных средствах macOS.
- **Только Apple silicon.** Сборка под arm64. Если App Store Connect потребует универсальную сборку (Intel + Apple silicon), ffmpeg и библиотеки придётся собрать ещё и под x86_64.
