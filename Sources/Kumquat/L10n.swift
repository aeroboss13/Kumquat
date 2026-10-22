import Foundation

/// Interface language chosen in Settings. Switching takes effect immediately, without a relaunch.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, en, ru
    var id: String { rawValue }

    /// Shown in each language's own name so it stays recognizable whatever the current language.
    var title: String {
        switch self {
        case .system: tr("System default")
        case .en: "English"
        case .ru: "Русский"
        }
    }

    static let defaultsKey = "language"

    /// The language strings are actually rendered in.
    static var resolved: AppLanguage {
        let stored = AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
        guard stored == .system else { return stored }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("ru") ? .ru : .en
    }
}

/// Translates an English interface string. English text is the key, so a missing translation
/// falls back to readable English. `%@` / `%d` placeholders are filled from `args`.
nonisolated func tr(_ key: String, _ args: any CVarArg...) -> String {
    let template = AppLanguage.resolved == .ru ? (L10n.ru[key] ?? key) : key
    return args.isEmpty ? template : String(format: template, arguments: args)
}

nonisolated enum L10n {
    static let ru: [String: String] = [
        // Language
        "System default": "Как в системе",
        "Language": "Язык",
        "Interface language": "Язык интерфейса",

        // Wheel modes
        "Convert formats": "Конвертация",
        "File tools": "Инструменты",
        "File actions": "Действия",

        // Catalog — shared
        "Convert to %@": "Конвертировать в %@",
        "Export slides as %@": "Экспорт слайдов в %@",
        "Markdown": "Markdown",
        "Collage": "Коллаж",
        "Combine images in a grid": "Собрать картинки в сетку",
        "One PDF": "Один PDF",
        "Combine images into one PDF": "Собрать картинки в один PDF",
        "Merge": "Склеить",
        "Join videos one after another": "Склеить видео друг за другом",
        "Join tracks one after another": "Склеить треки друг за другом",
        "Combine PDFs into one": "Объединить PDF в один",
        "Extract": "Распаковать",
        "Unpack next to the archive": "Распаковать рядом с архивом",

        // Image tools
        "Compress": "Сжать",
        "Smaller file, same look": "Меньше размер, тот же вид",
        "Resize 50%": "Уменьшить 50%",
        "Half the dimensions": "Вдвое меньше по сторонам",
        "Strip metadata": "Стереть метаданные",
        "Erase all metadata": "Стереть все метаданные",
        "Enhance": "Улучшить",
        "Auto-adjust exposure and color": "Автокоррекция экспозиции и цвета",
        "Cut out": "Вырезать",
        "Remove the background": "Убрать фон",
        "Redact": "Скрыть",
        "Blur faces and text": "Размыть лица и текст",
        "Add BG": "Фон",
        "Place on a gradient background": "Положить на градиентный фон",
        "Crop 1:1": "Квадрат 1:1",
        "Center square crop": "Обрезать по центру в квадрат",
        "Rotate": "Повернуть",
        "Rotate 90° clockwise": "Повернуть на 90° по часовой",
        "Flip": "Отразить",
        "Mirror horizontally": "Отразить по горизонтали",
        "B&W": "Ч/Б",
        "Convert to black & white": "Сделать чёрно-белым",
        "Text": "Текст",
        "Recognize text into a .txt file": "Распознать текст в файл .txt",

        // Video / audio tools
        "H.264, max 1080p": "H.264, до 1080p",
        "Audio": "Звук",
        "Extract the audio track": "Извлечь звуковую дорожку",
        "Mute": "Без звука",
        "Remove the audio track": "Удалить звуковую дорожку",
        "GIF": "GIF",
        "Animated GIF, 480px": "Анимированный GIF, 480 px",
        "Half size": "Вдвое меньше",
        "Half the resolution": "Половина разрешения",
        "2× speed": "Скорость 2×",
        "Play twice as fast": "Ускорить в два раза",
        "Frame": "Кадр",
        "Grab a still frame": "Сохранить стоп-кадр",
        "MP3 at 128 kbps": "MP3, 128 кбит/с",
        "Normalize": "Громкость",
        "Even out loudness": "Выровнять громкость",

        // PDF tools
        "Downsample images": "Уменьшить картинки внутри",
        "Split": "Разделить",
        "One PDF per page": "Отдельный PDF на каждую страницу",
        "Rotate all pages 90°": "Повернуть все страницы на 90°",
        "Images": "Картинки",
        "Extract every page as PNG": "Сохранить каждую страницу в PNG",
        "OCR": "OCR",
        "Recognize text from scans": "Распознать текст со сканов",
        "Exact copy of every page": "Точная копия всех страниц",
        "DOCX text": "DOCX текст",
        "Editable text, layout not kept": "Редактируемый текст, без вёрстки",

        // Archives
        "Compress to .zip": "Сжать в .zip",
        "Bundle into .tar": "Упаковать в .tar",
        "Compress to .tar.gz": "Сжать в .tar.gz",

        // File actions
        "AirDrop": "AirDrop",
        "Share via AirDrop": "Отправить через AirDrop",
        "Float": "Полка",
        "Keep in a floating shelf": "Положить на плавающую полку",
        "Copy": "Копировать",
        "Copy files to clipboard": "Скопировать файлы в буфер",
        "Move": "Переместить",
        "Move to a folder…": "Переместить в папку…",
        "Copy Path": "Путь",
        "Copy full paths as text": "Скопировать полный путь текстом",
        "Terminal": "Терминал",
        "Open folder in Terminal": "Открыть папку в Терминале",

        // Wheel / HUD / jobs
        "No options for\nthis file": "Нет вариантов\nдля этого файла",
        "%d files": "Файлов: %d",
        "%d items": "Объектов: %d",
        "%d files created": "Создано файлов: %d",
        "Cancel": "Отменить",
        "Cancelled": "Отменено",
        "Show in Finder": "Показать в Finder",
        "Copied %@": "Скопировано: %@",
        "Path copied": "Путь скопирован",
        "Move Here": "Переместить сюда",
        "Move %@ to…": "Переместить «%@» в…",
        "Moved to %@": "Перемещено в «%@»",

        // Shelf
        "Clear shelf": "Очистить полку",
        "Remove from Shelf": "Убрать с полки",
        "Drag out to use": "Перетащите, чтобы использовать",

        // Main window
        "Drop files here": "Перетащите файлы сюда",
        "…or start dragging a file anywhere and tap a key.\nDrop it on a slice of the wheel — the result lands next to the original.":
            "…или начните тащить файл где угодно и нажмите клавишу.\nБросьте его на сектор колеса — результат появится рядом с оригиналом.",
        "Choose Files…": "Выбрать файлы…",
        "Clear": "Очистить",
        "No options for this selection.": "Для этих файлов нет вариантов.",
        "Recent": "Недавние",
        "Converted files will show up here.": "Здесь появятся сконвертированные файлы.",

        // Menu bar
        "Drag gesture": "Жест перетаскивания",
        "Drag a file, tap %@, drop on the wheel.": "Тащите файл, нажмите %@, бросьте на колесо.",
        "No conversions yet": "Пока нет конвертаций",
        "Open Window": "Открыть окно",
        "Settings…": "Настройки…",
        "Quit": "Выйти",

        // Settings
        "Settings": "Настройки",
        "Wheel keys — tap while dragging": "Клавиши колёс — нажимайте во время перетаскивания",
        "Enable drag gesture": "Включить жест перетаскивания",
        "Output": "Результат",
        "Save converted files": "Сохранять файлы",
        "Next to the original": "Рядом с оригиналом",
        "Downloads": "В «Загрузки»",
        "Custom folder…": "В свою папку…",
        "Folder": "Папка",
        "Choose…": "Выбрать…",
        "Image quality": "Качество изображений",
        "Reveal results in Finder": "Показывать результат в Finder",
        "Play sound when done": "Звук по завершении",
        "General": "Основные",
        "Launch at login": "Запускать при входе в систему",
        "Open folders in iTerm instead of Terminal": "Открывать папки в iTerm вместо Терминала",
        "Helpers": "Утилиты",
        "Found": "Найдено",
        "Installed": "Установлен",
        "Not installed — .pages export disabled": "Не установлен — экспорт в .pages выключен",
        "Audio & video": "Аудио и видео",
        "WebP export (falls back to ffmpeg)": "Экспорт WebP (иначе через ffmpeg)",
        "RAR / 7z extraction": "Распаковка RAR / 7z",
        "Off": "Выкл.",

        // Errors
        "Couldn't read %@.": "Не удалось прочитать «%@».",
        "%@ isn't supported.": "%@ не поддерживается.",
        "%@ is required. Install it with Homebrew: brew install %@": "Нужна утилита %@. Установите через Homebrew: brew install %@",
        "Writing %@": "Запись в %@",
        "Couldn't write %@": "Не удалось записать «%@»",
        "Couldn't write PDF": "Не удалось записать PDF",
        "Couldn't create PDF": "Не удалось создать PDF",
        "Couldn't create collage": "Не удалось собрать коллаж",
        "No subject found in the image": "На изображении не найден объект",
        "No faces or text found to redact": "Не найдено лиц или текста для скрытия",
        "%@ is password-protected.": "«%@» защищён паролем.",
        ".%@ archives": "Архивы .%@",
        "PDF → %@": "PDF → %@",
        "Exporting slides to PDF needs Keynote (free on the App Store) or LibreOffice.":
            "Для экспорта слайдов в PDF нужен Keynote (бесплатно в App Store) или LibreOffice.",
        ".%@ files need LibreOffice to read. Save as XLSX or CSV first.":
            "Для чтения .%@ нужен LibreOffice. Сначала сохраните файл как XLSX или CSV.",
        "Pages isn't installed.": "Pages не установлен.",
        "%@ failed (%d)": "%@ завершился с ошибкой (%d)",
    ]
}
