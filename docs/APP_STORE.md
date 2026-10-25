# Публикация Kumquat в Mac App Store

Версия для App Store собирается отдельно (`scripts/build-appstore.sh`): она работает в песочнице (App Sandbox), содержит свой ffmpeg и не использует Pages, Keynote, LibreOffice и Homebrew. Код, ffmpeg, скриншоты и тексты готовы; ниже — шаги, которые можно сделать только из вашего аккаунта Apple.

## 1. Apple Developer Program

1. Откройте https://developer.apple.com/programs/enroll/ и вступите как **Individual** (частное лицо). Стоимость — $99 в год.
2. Дождитесь письма о том, что членство активно (обычно от нескольких часов до 2 дней).
3. Запишите **Team ID**: https://developer.apple.com/account → Membership details.

## 2. Bundle ID

https://developer.apple.com/account/resources/identifiers → **+** → App IDs → App → Platform: macOS.

- Description: `Kumquat`
- Bundle ID: **Explicit**, `com.pavelbardin.kumquat`
- Capabilities: ничего отмечать не нужно (App Sandbox включается в самой сборке).

Если хотите другой Bundle ID, передайте его в сборку: `BUNDLE_ID=... scripts/build-appstore.sh`.

## 3. Сертификаты

Xcode → Settings → Accounts → войдите своим Apple ID → выберите команду → **Manage Certificates…** → **+**:

- **Apple Distribution**
- **Mac Installer Distribution**

Оба появятся в связке ключей. Проверка:

```bash
security find-identity -v
```

Должны быть строки `Apple Distribution: …` и `3rd Party Mac Developer Installer: …`.

## 4. Provisioning profile

https://developer.apple.com/account/resources/profiles → **+** → Distribution → **Mac App Store Connect** → App ID `com.pavelbardin.kumquat` → сертификат Apple Distribution → имя `Kumquat Mac App Store` → **Download**. Файл попадёт в «Загрузки».

## 5. Сборка .pkg

```bash
TEAM_ID=ВАШ_TEAM_ID PROFILE=~/Downloads/Kumquat_Mac_App_Store.provisionprofile ./scripts/build-appstore.sh
```

Результат: `build/appstore/Kumquat-1.2.pkg`. Номер сборки (`CFBundleVersion`) берётся из числа коммитов и растёт сам; при повторной загрузке той же версии сделайте коммит или задайте `BUILD=…`.

Проверить сборку в песочнице до подписи можно так:

```bash
./scripts/build-appstore.sh --local
build/appstore/Kumquat.app/Contents/MacOS/Kumquat --selftest
```

## 6. Карточка приложения в App Store Connect

https://appstoreconnect.apple.com → Apps → **+** → New App:

- Platform: macOS
- Name: `Kumquat: File Converter` (если имя занято, Apple скажет сразу — тогда, например, `Kumquat Converter`)
- Primary Language: English (U.S.) — русскую локализацию добавьте потом кнопкой рядом с языком
- Bundle ID: `com.pavelbardin.kumquat`
- SKU: `kumquat-mac`

Дальше заполните поля по `docs/appstore/metadata.md`: тексты на двух языках, ключевые слова, ссылки, категория, возрастной рейтинг, App Privacy («Data Not Collected»), цена Free, заметки для ревьюера. Скриншоты — из `docs/appstore/screenshots/` (`en-*` для английской локализации, `ru-*` для русской).

## 7. Загрузка сборки

1. Установите **Transporter** из Mac App Store и войдите тем же Apple ID.
2. Перетащите `build/appstore/Kumquat-1.2.pkg` в Transporter → **Deliver**.
3. Через 10–30 минут сборка появится в App Store Connect → ваше приложение → раздел версии → **Build** → выберите её.

## 8. Отправка на ревью

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
