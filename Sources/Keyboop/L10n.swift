import Foundation

extension Notification.Name {
    /// Сменили язык интерфейса в настройках — UI вне окна настроек (меню статус-бара) пересобирается.
    static let keyboopLanguageChanged = Notification.Name("keyboopLanguageChanged")
    /// История голосового набора изменилась — открытое окно истории перестраивается.
    static let keyboopVoiceHistoryChanged = Notification.Name("keyboopVoiceHistoryChanged")
    /// Проверка обновлений сорвалась (или снова заработала) — открытые настройки показывают это.
    static let updaterStatusChanged = Notification.Name("updaterStatusChanged")
    /// Caps-режим не смог включиться (или снова смог) — открытые настройки показывают причину.
    /// Ремап делается в фоне через hidutil, то есть уже ПОСЛЕ того, как человек щёлкнул тумблером,
    /// и без сигнала окно так и осталось бы с бодрым «Работает».
    static let capsRemapStatusChanged = Notification.Name("capsRemapStatusChanged")
    /// Голосовой ввод вставил текст — Engine чистит буфер, чтобы надиктованное не попало в
    /// групповую конвертацию (G3) и не считалось «набранным вручную».
    static let keyboopVoiceInserted = Notification.Name("keyboopVoiceInserted")
}

enum Lang: String { case ru, en }

/// Локализация ru/en. По умолчанию — язык системы; переключается в настройках.
/// RU не дословный перевод — тот же сухой вит в естественном русском (Boopster voice).
enum L10n {
    static var current: Lang {
        switch AppSettings.shared.language {
        case "ru": return .ru
        case "en": return .en
        default:
            let pref = Locale.preferredLanguages.first ?? "en"
            return pref.hasPrefix("ru") ? .ru : .en
        }
    }

    static func t(_ key: String) -> String {
        strings[key]?[current] ?? strings[key]?[.en] ?? key
    }

    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    /// Локализация единиц размера модели: каталог хранит EN («142 MB», «1.5 GB»),
    /// для RU меняем на «МБ/ГБ». Так EN-интерфейс корректен изначально, а не показывает кириллицу.
    static func size(_ s: String) -> String {
        guard current == .ru else { return s }
        return s.replacingOccurrences(of: "MB", with: "МБ").replacingOccurrences(of: "GB", with: "ГБ")
    }

    /// Подпись пункта длительности тёплого окна: «15 с», «30 с», «1 мин», «5 мин».
    static func warmDurTitle(_ seconds: Int) -> String {
        let ru = current == .ru
        if seconds < 60 { return ru ? "\(seconds) с" : "\(seconds)s" }
        let m = seconds / 60
        return ru ? "\(m) мин" : "\(m) min"
    }

    /// Подпись срока хранения истории по минутам (0 значит «не удалять»). Пункты 2 и 4 часа
    /// из списка убраны 24.09.2026, но их подписи живут: у кого они выбраны, тот видит свой
    /// вариант (`HistoryPolicy.retentionMenu`).
    static func retentionTitle(_ mins: Int) -> String {
        switch mins {
        case 0: return t("ret.never")
        case 30: return t("ret.30m")
        case 60: return t("ret.1h")
        case 120: return t("ret.2h")
        case 240: return t("ret.4h")
        case 480: return t("ret.8h")
        case 7 * 24 * 60: return t("ret.7d")
        case 30 * 24 * 60: return t("ret.30d")
        default:
            let ru = current == .ru
            if mins % (24 * 60) == 0 { let d = mins / (24 * 60); return ru ? "\(d) дн." : "\(d) d" }
            if mins % 60 == 0 { let h = mins / 60; return ru ? "\(h) ч" : "\(h) h" }
            return ru ? "\(mins) мин" : "\(mins) min"
        }
    }

    private static let strings: [String: [Lang: String]] = [
        "tagline":        [.ru: "wrong layout? keyboop.", .en: "wrong layout? keyboop."],

        "menu.edit":      [.ru: "Правка",       .en: "Edit"],
        "menu.undo":      [.ru: "Отменить",     .en: "Undo"],
        "menu.redo":      [.ru: "Повторить",    .en: "Redo"],
        "menu.cut":       [.ru: "Вырезать",     .en: "Cut"],
        "menu.copy":      [.ru: "Копировать",   .en: "Copy"],
        "menu.paste":     [.ru: "Вставить",     .en: "Paste"],
        "menu.selectAll": [.ru: "Выделить всё", .en: "Select All"],
        "menu.close":     [.ru: "Закрыть окно", .en: "Close Window"],
        "sec.predictiveInput": [.ru: "Предиктивный ввод", .en: "Predictive Input"],
        "sec.switching":  [.ru: "Переключение", .en: "Switching"],
        "sec.exceptions": [.ru: "Исключения",   .en: "Exceptions"],
        "sec.sites":      [.ru: "Сайты",        .en: "Sites"],
        "sec.snippets":   [.ru: "Автозамена",   .en: "Snippets"],
        "amb.title":  [.ru: "Кто побеждает",
                       .en: "Who wins"],
        "amb.sub":     [.ru: "Эти слова набираются одними и теми же клавишами и существуют в обоих языках. Мы не можем угадать за тебя: кто-то пишет «versus» каждый день, кто-то — «мы» в каждом втором предложении. Выбери, что должно получаться.",
                       .en: "These words are typed with the very same keys and exist in both languages. We can't guess for you: some people write “versus” daily, others write “мы” in every other sentence. Pick what should come out."],
        "amb.auto":    [.ru: "по умолчанию", .en: "default"],
        // ⚠️ ФОРМУЛИРОВКА ИСПРАВЛЕНА 07.08 ПОТОМУ, ЧТО ОНА ВРАЛА. Было «по контексту решаем сами, по
        // словарю и языку соседних слов», а на деле слово, валидное в языке набора, держится
        // БЕЗУСЛОВНО (strict-gate, принцип «валидное слово не трогаем никогда»), и контекст в этих
        // парах не читается вовсе. Обещать разбор по контексту там, где его нет, хуже, чем честно
        // назвать правило: человек не понимает, почему «выбор по контексту» не срабатывает.
        "amb.rowTip":  [.ru: "«%@» и «%@» набираются одними клавишами. Пока выбор не сделан, побеждает то, что является словом того языка, на котором набрано.",
                       .en: "“%@” and “%@” are typed with the same keys. Until you choose, the winner is whichever is a real word in the language it was typed in."],
        "amb.back":    [.ru: "‹ Исключения", .en: "‹ Exceptions"],
        "amb.open":    [.ru: "Открыть список…", .en: "Open the list…"],
        "amb.openSub": [.ru: "Слова, которые набираются одними и теми же клавишами и существуют в обоих языках («vs» и «мы»). Пока выбор не сделан, побеждает язык, на котором набрано — но можно закрепить победителя.",
                       .en: "Words typed with the very same keys that exist in both languages (“vs” and “мы”). Until you choose, the language it was typed in wins — but you can pin a winner."],
        "amb.hint":    [.ru: "Выбор сильнее всех встроенных правил — он попадает в исключения. Слово, которого тут нет, всегда можно добавить вручную на странице «Исключения».",
                       .en: "Your choice outranks every built-in rule — it goes into exceptions. A pair that isn't listed can always be added by hand on the Exceptions page."],

        "sec.translate":  [.ru: "Перевод",      .en: "Translate"],
        "sec.privacy":    [.ru: "Приватность",  .en: "Privacy"],
        "sec.general":    [.ru: "Общие",        .en: "General"],
        "sec.updates":    [.ru: "Обновления",   .en: "Updates"],
        "sec.about":      [.ru: "О программе",   .en: "About"],

        // Переключатель режима окна настроек (над списком разделов). «Основное» — то, что нужно
        // обычному человеку, «Все» — весь список без изъятий.
        // Слово «Pro» одинаково в обоих языках (решение автора 11.08): короткого и понятного
        // русского эквивалента не нашлось, а смысл поясняет подпись под тумблером.

        // Быстрые действия по правому клику и шлепку (задачи 21 и 35)
        "quick.title":    [.ru: "Быстрые действия", .en: "Quick actions"],
        "quick.sub":      [.ru: "Правый клик и шлепок настраиваются независимо. Левый клик по значку по-прежнему открывает меню.", .en: "Right click and slap are configured independently. Left click still opens the menu."],
        "quick.subNoSlap":[.ru: "Выбери действие по правому клику. Левый клик по значку по-прежнему открывает меню.", .en: "Choose what right click does. Left click still opens the menu."],
        "quick.copyVoice":[.ru: "Копировать последнюю диктовку", .en: "Copy the last dictation"],
        // ⚠️ ИМЯ ФУНКЦИИ ЖИВЁТ В ЧЕТЫРЁХ СТРОКАХ СРАЗУ (переименование, автор 07.08). Было
        // «Помолчать», и оно путалось с нашей же настройкой «без звуков»: читалось как «выключи
        // звуки», хотя речь про ввод. «Не мешать» опирается на готовую привычку от системного
        // «Не беспокоить». Меняя одну из этих строк, меняй все: пункт меню, подпись в настройках,
        // тост и строку активной паузы это ОДНА функция, и звать её надо одинаково.
        "quick.pause":    [.ru: "Не мешать", .en: "Do not disturb"],
        "quick.dictate":  [.ru: "Включить или выключить диктовку", .en: "Toggle dictation"],
        "quick.history":  [.ru: "Открыть историю диктовки и буфера", .en: "Open the dictation and clipboard history"],
        "quick.manualSwitchOrUndo":[.ru: "Переключить вручную / отменить", .en: "Switch manually / undo"],
        // Сниппеты как ОТДЕЛЬНЫЙ список (решение автора 06.08.2026)
        "snip.textsTitle":[.ru: "Сниппеты для вставки", .en: "Snippets to insert"],
        "snip.textsSub":  [.ru: "Отдельный список. Автозамена срабатывает сама по аббревиатуре, а это вставляется осознанно: длинные команды, реквизиты, шаблоны писем.", .en: "A separate list. Autoreplace fires by itself on an abbreviation; these are inserted deliberately: long commands, bank details, letter templates."],
        "snip.phName":    [.ru: "название", .en: "name"],
        "snip.phText":    [.ru: "текст для вставки", .en: "text to insert"],
        "snip.copyFrom":  [.ru: "Скопировать из автозамены", .en: "Copy from autoreplace"],
        "snip.copyFromHint":[.ru: "Список пуст. Если что-то подходящее уже лежит в автозамене, можно скопировать его сюда — там оно останется.", .en: "The list is empty. If something suitable already sits in autoreplace, copy it here; it stays there too."],
        "snip.pickOn":    [.ru: "Вставлять сниппет по сочетанию", .en: "Insert a snippet by shortcut"],
        "snip.pickCombo": [.ru: "Сочетание", .en: "Shortcut"],
        "snip.pickCustom":[.ru: "Назначить свою…", .en: "Set your own…"],
        // Выбор сниппета по хоткею (задача 17, 06.08.2026)
        "snip.pickHotkey":[.ru: "Вставить сниппет по сочетанию", .en: "Insert a snippet by shortcut"],
        "snip.pickHint":  [.ru: "Нажмите сочетание — появится список, дальше цифра 1-9. Удобно для того, что не хочется вешать на аббревиатуру: длинные команды, реквизиты, шаблоны писем. Нулевой строкой в списке стоит последняя диктовка, если её есть чем вставить.", .en: "Press the shortcut for a list, then a digit 1-9. Handy for what you would rather not bind to an abbreviation: long commands, bank details, letter templates. The zeroth row is the last dictation, whenever there is one to insert."],
        "snip.pickOff":   [.ru: "Выключено", .en: "Off"],
        "snip.pickTip":   [.ru: "цифра вставит · Esc закроет", .en: "a digit inserts · Esc closes"],
        "snip.pickTipMore":[.ru: "цифра · ⇧цифра · ⌘цифра вставят, дальше мышью · Esc закроет", .en: "digit · ⇧digit · ⌘digit insert, the rest by mouse · Esc closes"],
        "snip.pickEmpty": [.ru: "Список автозамен пуст", .en: "The snippet list is empty"],
        // Нулевая строка списка (задача 242): вставить последнюю диктовку, цифра «0».
        "snip.pickDictation": [.ru: "Диктовка", .en: "Dictation"],   // ⚠️ КОРОТКО: колонка названий ограничена 120 pt, «Последняя диктовка» обрезалась многоточием (снимок 07.09). Что диктовка ПОСЛЕДНЯЯ, видно по самому тексту в строке.
        "quick.action":   [.ru: "Действие", .en: "Action"],
        "quick.rightClick":[.ru: "Правый клик", .en: "Right click"],
        "quick.slap":     [.ru: "Шлепок по MacBook", .en: "Slap the MacBook"],
        "quick.slapSub":  [.ru: "Лёгкий шлепок по корпусу запускает выбранное действие", .en: "A light tap on the case runs the chosen action"],
        "quick.slapChecking": [.ru: "Проверяю встроенный датчик…", .en: "Checking the built-in sensor…"],
        "quick.slapReady": [.ru: "Датчик готов — лёгкий шлепок запускает действие", .en: "Sensor ready — a light tap runs the action"],
        "quick.slapUnavailable": [.ru: "Встроенный датчик сейчас недоступен", .en: "The built-in sensor is currently unavailable"],
        "quick.slapAction":[.ru: "Действие при шлепке", .en: "Action on slap"],
        "quick.slapSound": [.ru: "Звук при срабатывании", .en: "Sound when triggered"],
        "quick.sensitivity": [.ru: "Чувствительность", .en: "Sensitivity"],
        "quick.sensitivity.balanced": [.ru: "Сбалансированная", .en: "Balanced"],
        "quick.sensitivity.high": [.ru: "Высокая", .en: "High"],
        "quick.settings": [.ru: "Открыть настройки", .en: "Open settings"],
        "quick.help":     [.ru: "Правый клик по значку Keyboop в строке меню (рядом с часами) сразу делает выбранное, не открывая меню. Левый клик по-прежнему открывает меню.", .en: "Right-clicking the Keyboop icon in the menu bar (up by the clock) does the chosen thing at once, without opening the menu. Left click still opens the menu."],
        "quick.helpOff":  [.ru: "Сейчас недоступно: значок Keyboop убран из строки меню, а кликать не по чему. Верните значок или индикатор языка в разделе «Строка меню» выше.", .en: "Unavailable right now: the Keyboop icon is hidden from the menu bar, so there is nothing to click. Bring back the icon or the language badge in «Menu bar» above."],
        "quick.pauseLen": [.ru: "Как долго не мешать", .en: "For how long"],
        "quick.paused":   [.ru: "Не мешаю. Повторите быстрое действие, чтобы вернуть", .en: "Not disturbing you. Repeat the quick action to resume"],
        "quick.resumed":  [.ru: "Снова на посту", .en: "Back on duty"],
        "menu.pausedUntil":[.ru: "Не мешаю до %@", .en: "Not disturbing you until %@"],
        "menu.resumeNow": [.ru: "Продолжить сейчас", .en: "Resume now"],
        // ⚠️ ПОДПИСИ ДЛИТЕЛЬНОСТЕЙ ЛЕЖАТ ЗДЕСЬ, А НЕ СОБИРАЮТСЯ СТРОКОЙ НА МЕСТЕ. Раньше их
        // клеил `"\(m / 60) часа"` прямо в списке настроек: во-первых, только по-русски, во-вторых
        // 300 минут читались как «5 часа». Набор фиксированный (`pauseLenMinutes`), поэтому четыре
        // готовые строки честнее любых правил склонения. Меню и настройки берут их отсюда обе.
        "pause.len.15":   [.ru: "15 минут", .en: "15 minutes"],
        "pause.len.60":   [.ru: "1 час",    .en: "1 hour"],
        "pause.len.180":  [.ru: "3 часа",   .en: "3 hours"],
        "pause.len.300":  [.ru: "5 часов",  .en: "5 hours"],
        "switch.title":   [.ru: "Переключение раскладки", .en: "Layout switching"],
        "switch.sub":     [.ru: "Бупни клавишу — кракозябры исчезнут.", .en: "Boop a key — the gibberish vanishes."],
        // ⚠️ ПРАВИЛО ИМЁН (T44, решение автора 30.07). Три настройки годами звучали как одно и то
        // же «переключение», и люди путали их в отчётах (#20 и не только). Различаются они двумя
        // вещами: правят ТЕКСТ или только РАСКЛАДКУ, и когда срабатывают. Поэтому:
        //   всё, что правит текст  → начинается с «Исправлять»
        //   всё, что меняет только раскладку → начинается с «Менять раскладку»
        // Тогда первые две читаются как родственники, а разница видна в хвосте. Держаться правила.
        "switch.auto":    [.ru: "Автоматическое исправление раскладки", .en: "Automatic layout correction"],
        "switch.autoSub": [.ru: "Двусторонне, RU ↔ EN. Слово исправляется, когда вы его дописали", .en: "Two-way, RU ↔ EN. The word is fixed once you finish it"],
        "switch.translate":[.ru: "Перевод выделенного · ⌃⌥T", .en: "Translate selection · ⌃⌥T"],
        "switch.translateSub":[.ru: "Выдели СВОЙ текст в поле ввода и нажми ⌃⌥T — он заменится переводом RU↔EN. Там, где печатаешь (письмо, чат, заметка), а не на чужой веб-странице. Локально, macOS 15+.",
                              .en: "Select YOUR text in an input field and press ⌃⌥T — it's replaced with the RU↔EN translation. Where you type (mail, chat, notes), not on a read-only web page. Local, macOS 15+."],
        "tr.title":       [.ru: "Перевод набранного", .en: "Translate what you typed"],
        "tr.sub":         [.ru: "Выдели свой текст в поле ввода — он ЗАМЕНИТСЯ переводом RU↔EN. Работает там, где можно печатать, а не с текстом на веб-странице «только для чтения». Прямо на твоём Mac.",
                           .en: "Select your text in an input field — it's REPLACED with the RU↔EN translation. Works where you can type, not with read-only web-page text. Right on your Mac."],
        "tr.enabled":     [.ru: "Включить перевод по хоткею", .en: "Enable translate hotkey"],
        "tr.enabledSub":  [.ru: "Направление определяется само по тексту (RU→EN или EN→RU). Нужна macOS 15+.",
                           .en: "Direction is auto-detected from the text (RU→EN or EN→RU). Needs macOS 15+."],
        "tr.hotkey":      [.ru: "Горячая клавиша", .en: "Hotkey"],
        "tr.how":         [.ru: "Перевод офлайн, через системный движок Apple. Если пакет не установлен — нажми «Скачать» выше: пакет RU↔EN загрузится прямо здесь (система разок спросит подтверждение). Звук перевода подтверждает, что всё сработало.",
                           .en: "Translation is offline, via Apple's system engine. If the pack isn't installed — tap “Download” above: the RU↔EN pack loads right here (the system asks for confirmation once). The translation sound confirms it fired."],
        "tr.packTitle":   [.ru: "Языковой пакет", .en: "Language pack"],
        "tr.packName":    [.ru: "Русский ↔ английский", .en: "Russian ↔ English"],
        "tr.checking":    [.ru: "Проверяю…", .en: "Checking…"],
        // Уровень входа микрофона (задача 93). ⚠️ Формулировки честно говорят, что настройка СИСТЕМНАЯ:
        // мы меняем общий ползунок, который видят все программы, и не возвращаем его обратно.
        // «Уровень», а не «громкость» (автор, 09.08): громкость у нас означает то, что СЛЫШНО, а это
        // настройка чувствительности входа. Слово разводит две вещи ещё до того, как человек полез
        // в подсказку.
        "voice.micGain":      [.ru: "Поднимать уровень микрофона",
                               .en: "Raise the microphone input level"],
        "voice.micGainSub":   [.ru: "Перед диктовкой выставляю системный уровень входа и оставляю его",
                               .en: "Sets the system input level before dictation and leaves it there"],
        "voice.micGainUnsupportedShort": [.ru: "Этот микрофон уровнем не управляет", .en: "This microphone has no input level"],
        "voice.micGainUnsupported": [.ru: "Этот микрофон не даёт управлять уровнем входа",
                                     .en: "This microphone does not allow input level control"],
        "voice.micGainHelp":  [.ru: "Некоторые программы (например браузер во время звонка) убавляют системный уровень микрофона и не возвращают его. Тогда следующая диктовка выходит тихой. Keyboop поднимает уровень перед записью. Это ОБЩАЯ системная настройка: поднятый вход увидят и другие программы, и обратно мы его не опускаем, иначе смысл теряется.",
                               .en: "Some apps (a browser during a call, for instance) turn the system microphone level down and never restore it, and your next dictation comes out quiet. Keyboop raises it before recording. This is a SYSTEM-WIDE setting: other apps see the raised level too, and we do not lower it back, or the whole point would be lost."],
        "voice.micGainLevel": [.ru: "До какого уровня", .en: "Up to which level"],
        "voice.micGainLevelHelp": [.ru: "Положение системного ползунка, а не громкость в децибелах: у разных микрофонов одна и та же доля означает разное усиление. 100% у части устройств это уже перегруз, поэтому по умолчанию 90%.",
                                   .en: "The position of the system slider, not a level in decibels: the same percentage means different gain on different microphones. On some devices 100% already clips, which is why the default is 90%."],
        // Сохранение аудио диктовки (задача 101, отзыв #110). ⚠️ Текст обязан честно называть цену:
        // это единственная наша функция, после которой на диске лежит голос человека.
        "voice.saveAudio":    [.ru: "Сохранять запись голоса",
                               .en: "Keep the voice recording"],
        "voice.saveAudioSub": [.ru: "К каждой диктовке в истории прикрепляется исходное аудио",
                               .en: "Each dictation in the history keeps its original audio"],
        "voice.saveAudioHelp":[.ru: "Иногда распознанного текста мало и хочется переслушать, как было сказано. Запись шифруется тем же ключом, что и текст истории, никуда не отправляется и живёт ровно столько же, сколько сама запись в истории: удалили запись или вышел срок хранения — исчезает и звук. Минута речи занимает около 240 КБ.",
                               .en: "Sometimes the transcript is not enough and you want to hear how it was actually said. The recording is encrypted with the same key as the history text, never leaves the Mac, and lives exactly as long as its history entry: delete the entry or let the retention expire and the audio goes with it. A minute of speech takes about 240 KB."],
        // Вставка последней диктовки по сочетанию (задача 242, отзыв #245).
        "voice.pasteLast":    [.ru: "Вставлять последнюю диктовку по сочетанию",
                               .en: "Insert the last dictation by shortcut"],
        "voice.pasteLastSub": [.ru: "Ставит её текст туда, где сейчас курсор — если он уехал не в то поле",
                               .en: "Puts its text where the caret is now — for when it ended up in the wrong field"],
        "voice.pasteLastHelp":[.ru: "Бывает, что диктовка закончилась, а курсор к этому моменту оказался в другом окне: текст ушёл не туда, и набирать заново обидно. Сочетание вставляет текст последней диктовки в то поле, где курсор стоит сейчас, тем же способом, что и обычная замена слова: печатью, буфер обмена не трогаем. Нужна включённая история диктовок — именно из неё берётся последняя запись, и срок хранения действует тот же. Если на историю поставлен пароль, сочетание не сработает: запрос пароля забрал бы фокус у поля, в которое вы целитесь, поэтому текст в этом случае берут из окна истории. По умолчанию сочетание не назначено.",
                               .en: "Sometimes a dictation ends when the caret has already moved to another window: the text lands in the wrong place and retyping it is galling. The shortcut inserts the last dictation's text wherever the caret is now, the same way an ordinary word replacement works — by typing, without touching the clipboard. It needs the dictation history switched on: that is where the last entry comes from, and the same retention applies. If the history is password-protected the shortcut stays silent: the password prompt would take focus away from the very field you are aiming at, so in that case take the text from the history window. No shortcut is assigned by default."],
        "voice.pasteLastAssign": [.ru: "Сочетание", .en: "Shortcut"],
        "voice.pasteLastLocked": [.ru: "История под паролем — откройте окно истории",
                                  .en: "The history is locked — open the history window"],
        "voice.pasteLastNoHistory": [.ru: "Включите историю диктовок, иначе вставлять нечего",
                                     .en: "Switch on the dictation history, otherwise there is nothing to insert"],
        // ⚠️ Формулировка обязана быть верной ПРИ ОБОИХ раскладах: признак «диктовка была, но
        // просрочена» доживает до проверки не всегда (`prune` чистит кэш и на старте, и при записи
        // новой). Поэтому здесь не «диктовок не было», а «её нет» — правда и там, и там.
        "voice.pasteLastNever":  [.ru: "Нечего вставлять: последней диктовки нет",
                                  .en: "Nothing to insert: there is no last dictation"],
        "voice.pasteLastBusy":   [.ru: "Идёт диктовка — дождитесь её текста",
                                  .en: "A dictation is in progress — wait for its text"],
        "voice.pasteLastOurWindow": [.ru: "Курсор в окне Keyboop — встаньте в нужное поле",
                                     .en: "The caret is in a Keyboop window — click into the field you want"],
        // Причин у отказа две — поле пароля и молчание Accessibility, — а `canWrite` отдаёт голый
        // Bool и их не различает. Значит и говорить надо то, что верно в обоих случаях.
        "voice.pasteLastSecure": [.ru: "macOS сейчас не даёт печатать в это поле",
                                  .en: "macOS won't let us type into this field right now"],
        "voice.audioSize":    [.ru: "Записи занимают %@", .en: "Recordings take %@"],
        "voice.audioClear":   [.ru: "Удалить все записи", .en: "Delete all recordings"],
        // Плеер клипа в карточке истории.
        "clip.play":  [.ru: "Прослушать", .en: "Play"],
        "clip.pause": [.ru: "Пауза", .en: "Pause"],
        "clip.gone":  [.ru: "Запись не открывается", .en: "The recording cannot be opened"],
        "clip.rate":  [.ru: "Скорость воспроизведения", .en: "Playback speed"],
        "paste.section":  [.ru: "ВСТАВКА ИЗ БУФЕРА", .en: "PASTING FROM THE CLIPBOARD"],
        // Заголовок над «Исправлять опечатки» и «Две заглавные подряд»: обе правят текст, а не
        // раскладку, поэтому и переехали сюда из «Переключения» (автор 11.08).
        "sage.title": [.ru: "Корректор русского текста · SAGE", .en: "Russian proofreading · SAGE"],
        "sage.detail": [.ru: "Проверяет последнее предложение после паузы в наборе. Работает локально в поддерживаемых полях.", .en: "Checks the last sentence after a pause in typing. Runs on this Mac in supported text fields."],
        "sage.typing.mode": [.ru: "Исправления при наборе", .en: "Corrections while typing"],
        "sage.typing.automatic": [.ru: "Автоматически", .en: "Automatically"],
        "sage.typing.confirmation": [.ru: "С подтверждением", .en: "Ask Before Applying"],
        "sage.typing.off": [.ru: "Выкл.", .en: "Off"],
        "sage.typing.preview": [.ru: "SAGE предлагает исправление", .en: "SAGE suggested a correction"],
        "sage.command": [.ru: "Проверить выделенный текст", .en: "Proofread Selected Text"],
        "sage.download": [.ru: "Скачать SAGE (%@)", .en: "Download SAGE (%@)"],
        "sage.status.missing": [.ru: "SAGE Distilled 95M нужно скачать", .en: "Download SAGE Distilled 95M to get started"],
        "sage.status.downloading": [.ru: "Модель ещё скачивается.", .en: "The model is still downloading."],
        "sage.status.progress": [.ru: "Загрузка модели… %d%%", .en: "Downloading model… %d%%"],
        "sage.status.ready": [.ru: "SAGE Distilled 95M готова к работе", .en: "SAGE Distilled 95M is ready"],
        "sage.checking": [.ru: "Проверяю текст локально…", .en: "Checking text on this Mac…"],
        "sage.preview": [.ru: "Проверьте предложенные исправления.", .en: "Review the suggested corrections."],
        "sage.selection.required": [.ru: "Выделите текст в поле, где Keyboop может заменить выделение через Универсальный доступ.", .en: "Select text in a field where Keyboop can replace the selection using Accessibility."],
        "sage.selection.russian": [.ru: "Выберите фрагмент русского текста.", .en: "Select a passage in Russian."],
        "sage.selection.changed": [.ru: "Выделение изменилось. Выберите текст и запустите проверку снова.", .en: "The selection changed. Select the text and run the check again."],
        "sage.selection.unsafeResult": [.ru: "Модель изменила структуру текста или защищённые фрагменты. Попробуйте выделить только нужное предложение.", .en: "The model changed the text structure or a protected fragment. Try selecting just the sentence you want to check."],
        "sage.selection.writeFailed": [.ru: "Редактор не подтвердил замену выделенного текста.", .en: "The editor did not confirm that the selected text was replaced."],
        "sage.error.unavailable": [.ru: "В этой сборке недоступен движок SAGE.", .en: "The SAGE engine is unavailable in this build."],
        "sage.error.missing": [.ru: "Сначала скачайте модель SAGE в настройках.", .en: "Download the SAGE model in Settings first."],
        "sage.error.download": [.ru: "Не удалось скачать модель. Попробуйте ещё раз.", .en: "The model could not be downloaded. Try again."],
        "sage.error.integrity": [.ru: "Файлы модели не прошли проверку. Скачайте их заново.", .en: "The model files failed verification. Download them again."],
        "sage.error.install": [.ru: "Не удалось сохранить или удалить файлы модели.", .en: "The model files could not be saved or removed."],
        "sage.error.empty": [.ru: "В выделении нет текста для проверки.", .en: "There is no text to check in the selection."],
        "sage.error.tooLong": [.ru: "Выделение слишком длинное. Попробуйте проверить часть текста.", .en: "The selection is too long. Try checking a shorter passage."],
        "sage.error.busy": [.ru: "Завершите предыдущую проверку текста.", .en: "Finish the previous proofreading check first."],
        "sage.error.timeout": [.ru: "Модель не успела проверить текст. Попробуйте выделить меньший фрагмент.", .en: "The check timed out. Try selecting a shorter passage."],
        "sage.error.inference": [.ru: "Модель не смогла проверить выделенный текст.", .en: "The model could not check the selected text."],
        "fix.section":    [.ru: "ПРАВКА ТЕКСТА", .en: "TEXT FIXES"],
        "paste.plain":    [.ru: "Вставлять без форматирования", .en: "Paste without formatting"],
        "paste.plainSub": [.ru: "Текст ляжет шрифтом того места, куда вставляете",
                           .en: "The text takes on the style of where you paste it"],
        "paste.plainCombo":[.ru: "Сочетание", .en: "Shortcut"],
        "paste.plainHelp":[.ru: "Скопированный текст вставится голым: без чужого шрифта, цвета и размера. Мы подменяем содержимое буфера на время вставки и сразу возвращаем его обратно, а если за это время вы скопировали что-то новое, не трогаем его вовсе. ⚠️ Многие программы (Заметки, Pages, браузеры) умеют это сами по ⇧⌘V. Там включённая настройка заменит их поведение нашим, поэтому она выключена по умолчанию, а сочетание можно сменить.",
                           .en: "The copied text is pasted bare: no foreign font, colour or size. We swap the clipboard contents for the moment of pasting and put them straight back, and if you copied something new meanwhile we leave it alone. ⚠️ Many apps (Notes, Pages, browsers) already do this on ⇧⌘V. There, turning this on replaces their behaviour with ours, which is why it is off by default and the shortcut can be changed."],
        "hist.clearConfirm":    [.ru: "Удалить все записи?", .en: "Delete all entries?"],
        "hist.clearConfirmBody":[.ru: "Вместе с текстом исчезнут и сохранённые аудиозаписи. Вернуть их будет нельзя.",
                                 .en: "Saved audio recordings go with the text. This cannot be undone."],
        "hist.clearConfirmYes": [.ru: "Удалить", .en: "Delete"],
        "hist.clearConfirmNo":  [.ru: "Отмена", .en: "Cancel"],
        "tr.installed":   [.ru: "Установлен ✓", .en: "Installed ✓"],
        "tr.notInstalled":[.ru: "Не установлен — нужен для перевода", .en: "Not installed — required for translation"],
        // ⚠️ ОТДЕЛЬНАЯ СТРОКА НА НЕУДАЧУ (отзывы #102 и #108, 08.08.2026). Раньше после неудачной
        // докачки метка возвращалась к обычному «не установлен», то есть выглядела так, будто
        // человек и не нажимал ничего. Отсюда «после каждого обновления ставлю заново»: пакет,
        // вероятно, не ставился ни разу, а мы это скрывали. Теперь говорим прямо и показываем
        // единственный путь, где виден настоящий прогресс, — системный менеджер языков.
        "tr.dlFailed":    [.ru: "Не установился. Загрузку видно в «Системные настройки» → «Язык и регион»",
                           .en: "Did not install. You can watch the download in System Settings → Language & Region"],
        "tr.unsupported": [.ru: "Система не умеет эту пару языков",
                           .en: "The system does not support this language pair"],
        "tr.download":    [.ru: "Скачать", .en: "Download"],
        "tr.openSys":     [.ru: "Системные настройки", .en: "System Settings"],
        "tr.dlTitle":     [.ru: "Загрузка языкового пакета", .en: "Downloading language pack"],
        "tr.dlBody":      [.ru: "Готовлю перевод RU↔EN. Если система спросит — подтверди загрузку. Окно закроется само.",
                            .en: "Preparing RU↔EN translation. If the system asks, confirm the download. This window closes itself."],
        "tr.needPackTitle":[.ru: "Нужен языковой пакет", .en: "Language pack needed"],
        "tr.needPackBody": [.ru: "Перевод RU↔EN включается один раз — скачаю прямо сейчас, если нажмёшь.",
                            .en: "RU↔EN translation turns on once — I'll download it right now if you tap."],
        "tr.sound":       [.ru: "Звук перевода", .en: "Translation sound"],
        "tr.soundVol":    [.ru: "Громкость звука", .en: "Sound volume"],
        "sound.keyboopTr": [.ru: "Keyboop", .en: "Keyboop"],   // звук ПЕРЕВОДА
        "switch.live":    [.ru: "Исправлять на лету", .en: "Fix as you type"],
        "completion.title": [.ru: "Завершение слов", .en: "Word completion"],
        "completion.subtitle": [.ru: "Русские и английские подсказки в строке при наборе текста", .en: "Inline suggestions while typing in Russian or English"],
        "completion.localModel": [.ru: "Локальная ИИ-модель", .en: "Local AI model"],
        "completion.localModelDetail": [.ru: "Предлагает короткие продолжения, когда в словаре нет подходящего варианта. Сочетание принятия добавляет по одному слову.", .en: "Suggests short continuations when the dictionary has no match. Press the accept shortcut to insert one word at a time."],
        "prediction.source": [.ru: "Движок", .en: "Engine"],
        "prediction.source.managed": [.ru: "Встроенный llama.cpp", .en: "Built-in llama.cpp"],
        "prediction.source.external": [.ru: "Свой сервер · 127.0.0.1:18181", .en: "External server · 127.0.0.1:18181"],
        "prediction.compare": [.ru: "Сравнить на 38 примерах", .en: "Compare on 38 examples"],
        "prediction.compare.cancel": [.ru: "Отменить сравнение", .en: "Cancel comparison"],
        "prediction.compare.progress": [.ru: "Проверено %d из %d", .en: "Completed %d of %d"],
        "prediction.compare.failed": [.ru: "Ошибка сравнения · %@", .en: "Comparison failed · %@"],
        "prediction.compare.mode": [.ru: "Режим", .en: "Method"],
        "prediction.compare.shown": [.ru: "Показано", .en: "Shown"],
        "prediction.compare.correct": [.ru: "Совпало", .en: "Correct"],
        "prediction.compare.latency": [.ru: "p95", .en: "p95"],
        "prediction.compare.errors": [.ru: "Ошибки", .en: "Errors"],
        "prediction.compare.dictionary": [.ru: "Словарь", .en: "Dictionary"],
        "prediction.compare.direct": [.ru: "Прямой запрос", .en: "Direct request"],
        "prediction.compare.constrained": [.ru: "С ограничениями", .en: "Constrained"],
        "prediction.compare.ms": [.ru: "%d мс", .en: "%d ms"],
        "prediction.compare.metrics": [.ru: "Совпало — первое слово или окончание подошло к эталону. p95 — задержка первого слова в 95% показов.", .en: "Correct counts first words or completions matching the reference. p95 is the first-word latency at the 95th percentile of suggestions shown."],
        "prediction.probe": [.ru: "Проверить модель", .en: "Test model"],
        "prediction.probe.waiting": [.ru: "Ожидание ответа модели…", .en: "Waiting for the model…"],
        "prediction.probe.result": [.ru: "«%@» · первое слово за %d мс", .en: "“%@” · first word in %d ms"],
        "prediction.geometry.selectedRange": [.ru: "Позиция получена из диапазона выделения.", .en: "Position from the selection range."],
        "prediction.geometry.selectedMarker": [.ru: "Позиция получена из текстового маркера.", .en: "Position from the text marker."],
        "prediction.geometry.previousCharacter": [.ru: "Позиция вычислена по предыдущему символу.", .en: "Position derived from the previous character."],
        "prediction.geometry.nextCharacter": [.ru: "Позиция вычислена по следующему символу.", .en: "Position derived from the next character."],
        "prediction.geometry.visibleRun": [.ru: "Позиция вычислена по видимому тексту.", .en: "Position derived from a visible text run."],
        "prediction.weights": [.ru: "Модель", .en: "Model"],
        "prediction.download": [.ru: "Скачать", .en: "Download"],
        "prediction.cancelDownload": [.ru: "Отменить загрузку", .en: "Cancel download"],
        "prediction.deleteDownload": [.ru: "Удалить модель", .en: "Delete model"],
        "prediction.preview": [.ru: "Попробовать", .en: "Try it"],
        "prediction.preview.example": [.ru: "Наберите «прив» или «до сих» с пробелом", .en: "Type “sched” or “as soon” followed by a space"],
        "prediction.preview.enable": [.ru: "Включите завершение слов или подсказку следующего слова.", .en: "Turn on word completion or next-word suggestions."],
        "prediction.preview.needAX": [.ru: "Разрешите Keyboop универсальный доступ в системных настройках.", .en: "Allow Keyboop in System Settings → Privacy & Security → Accessibility."],
        "prediction.preview.needInput": [.ru: "Разрешите Keyboop мониторинг ввода в системных настройках.", .en: "Allow Keyboop in System Settings → Privacy & Security → Input Monitoring."],
        "prediction.idle": [.ru: "Ожидание ввода", .en: "Waiting for input"],
        "prediction.field": [.ru: "Редактор не предоставил доступ к тексту у каретки.", .en: "The editor did not provide the text at the caret."],
        "prediction.caret": [.ru: "Редактор не сообщил положение каретки.", .en: "The editor did not provide the caret position."],
        "prediction.rightText": [.ru: "Справа от каретки уже есть текст.", .en: "There is already text to the right of the caret."],
        "prediction.spellcheck": [.ru: "Системная проверка орфографии отфильтровала подсказку.", .en: "System spelling filtered out the suggestion."],
        "prediction.noMatch": [.ru: "Словарь не нашёл подходящего продолжения.", .en: "The dictionary found no matching completion."],
        "prediction.modelNotReady": [.ru: "Модель ещё не готова к вводу.", .en: "The model is not ready to suggest yet."],
        "prediction.changed": [.ru: "Поле, текст или положение каретки изменились.", .en: "The field, text, or caret position changed."],
        "prediction.noRoom": [.ru: "В строке не хватает места для подсказки.", .en: "There is not enough room on the line to show the suggestion."],
        "prediction.dictionary": [.ru: "Показана подсказка из словаря.", .en: "Showing a dictionary suggestion."],
        "prediction.fieldWord": [.ru: "Показано слово из текущего поля.", .en: "Showing a word from the current field."],
        "prediction.glossary": [.ru: "Показано слово из личного глоссария.", .en: "Showing a word from the personal glossary."],
        "prediction.personal": [.ru: "Показана подсказка из истории набора.", .en: "Showing a suggestion from typing history."],
        "prediction.model": [.ru: "Показана подсказка локальной модели.", .en: "Showing a local model suggestion."],
        "prediction.timeout": [.ru: "Модель не успела ответить за отведённое время.", .en: "The model exceeded the response time limit."],
        "prediction.unavailable": [.ru: "Нет соединения с локальным сервером.", .en: "Could not reach the local server."],
        "prediction.invalidResponse": [.ru: "Сервер вернул неподходящий ответ.", .en: "The server returned an invalid response."],
        "prediction.lowConfidence": [.ru: "У модели нет достаточно уверенного продолжения.", .en: "The model has no sufficiently confident continuation."],
        "prediction.ineligible": [.ru: "В этом поле или режиме подсказки недоступны.", .en: "Suggestions are unavailable in this field or mode."],
        "prediction.runtime.disabled": [.ru: "ИИ-подсказки выключены", .en: "AI suggestions are off"],
        "prediction.runtime.missing": [.ru: "Скачайте выбранную модель", .en: "Download the selected model"],
        "prediction.runtime.installed": [.ru: "Модель установлена и ждёт запроса", .en: "Model installed and on standby"],
        "prediction.runtime.starting": [.ru: "Запуск локальной модели…", .en: "Starting local model…"],
        "prediction.runtime.ready": [.ru: "Модель готова", .en: "Model ready"],
        "prediction.runtime.external": [.ru: "Используется локальный сервер на 127.0.0.1:18181", .en: "Using the local server at 127.0.0.1:18181"],
        "prediction.runtime.downloading": [.ru: "Загрузка модели…", .en: "Downloading model…"],
        "prediction.runtime.verifying": [.ru: "Проверка файла модели…", .en: "Verifying model file…"],
        "prediction.runtime.serverMissing": [.ru: "Исполняемый файл llama-server не найден", .en: "Could not find the llama-server executable"],
        "prediction.runtime.startFailed": [.ru: "Не удалось запустить llama-server", .en: "Could not start llama-server"],
        "prediction.runtime.timeout": [.ru: "Сервер не успел загрузить модель", .en: "The server timed out loading the model"],
        "prediction.runtime.exited": [.ru: "Процесс llama-server завершился", .en: "The llama-server process exited"],
        "prediction.runtime.badDownload": [.ru: "Не удалось скачать модель", .en: "Could not download the model"],
        "prediction.runtime.integrity": [.ru: "Проверка целостности файла не пройдена. Скачайте модель повторно.", .en: "Model verification failed. Download the model again."],
        "prediction.runtime.ioError": [.ru: "Не удалось обработать файл модели", .en: "Could not access the model file"],
        "completion.shortcut": [.ru: "Принять подсказку", .en: "Accept suggestion"],
        "completion.shortcutHelp": [.ru: "Можно назначить Tab без модификаторов. Сочетание срабатывает, пока видна подсказка.",
                                    .en: "You can assign Tab on its own. The shortcut works while a suggestion is visible."],
        "completion.nextWord": [.ru: "Следующее слово", .en: "Next word"],
        "completion.nextWordSubtitle": [.ru: "Предлагать продолжение после пробела", .en: "Suggest a continuation after a space"],
        "completion.fieldWords": [.ru: "Дописывать слова из текущего поля", .en: "Complete words from the current field"],
        "completion.fieldWordsDetail": [.ru: "Подсказывать слова, которые уже встречались в этом поле.", .en: "Suggest words that already appear in this field."],
        "completion.glossary": [.ru: "Личный глоссарий", .en: "Personal glossary"],
        "completion.glossary.edit": [.ru: "Редактировать…", .en: "Edit…"],
        "completion.glossary.help": [.ru: "Вставьте или введите по одному слову на строку. Слова используются для дописывания и хранятся на этом Mac.", .en: "Paste or enter one word per line. These words are used for completion and stored on this Mac."],
        "completion.glossary.save": [.ru: "Сохранить", .en: "Save"],
        "completion.personal": [.ru: "Учиться на моём наборе", .en: "Learn from my typing"],
        "completion.personal.detail": [.ru: "Запоминать слова и короткие сочетания для подсказок. История хранится на этом Mac.", .en: "Remember words and short word combinations for suggestions. History is stored on this Mac."],
        "completion.systemSpelling": [.ru: "Системный словарь для подсказок", .en: "System spelling for suggestions"],
        "completion.systemSpelling.detail": [.ru: "Пилот. Помогает скрывать лишние подсказки для законченных слов и явных опечаток.", .en: "Pilot. Helps suppress suggestions for complete words and obvious typos."],
        "completion.personal.history": [.ru: "История подсказок", .en: "Suggestion history"],
        "completion.personal.reset": [.ru: "Сбросить…", .en: "Reset…"],
        "completion.personal.resetTitle": [.ru: "Сбросить историю подсказок?", .en: "Reset suggestion history?"],
        "completion.personal.resetDetail": [.ru: "Сохранённые слова и сочетания будут удалены.", .en: "Learned words and word combinations will be deleted."],
        "completion.personal.clear": [.ru: "Удалить историю", .en: "Delete history"],
        "completion.personal.resetFailed": [.ru: "Системе не удалось удалить файл истории подсказок.", .en: "The system could not delete the suggestion history file."],
        // Подпись переписана вместе со сменой дефолта на ВКЛ (21.07): пометка «(агрессивно)» пугала
        // ровно там, где тумблер теперь включён из коробки. Объясняем пользу, а не пугаем.
        "switch.liveSub": [.ru: "Не ждать пробела: чиню посреди слова. В браузерах и Slack жду пробел", .en: "Don’t wait for the space: I fix mid-word. In browsers and Slack I wait"],
        "switch.predict":    [.ru: "Угадывать раскладку до ввода", .en: "Predict layout before typing"],
        "switch.predictSub": [.ru: "Заранее ставит RU или EN по тексту у курсора, переписке и памяти чатов",
                              .en: "Sets RU or EN ahead of time from text around the caret, chat messages, and chat memory"],
        "switch.dev":     [.ru: "Режим для разработчиков", .en: "Mode for developers"],
        "switch.devSub":  [.ru: "Бережёт код: одиночные буквы и короткие сочетания (переменные, команды) не трогаем нигде. В IDE и терминалах авто выключено целиком.",
                           .en: "Protects code: single letters and short combos (variables, commands) are left alone everywhere. In IDEs and terminals auto-switch is fully off."],
        "switch.manual":  [.ru: "Ручное переключение и отмена", .en: "Manual switch and undo"],
        // ⚠️ ПОДПИСЬ И «i» ДОБАВЛЕНЫ 04.08.2026, ПОТОМУ ЧТО СТРОКА МОЛЧАЛА. У неё был только
        // заголовок и поле с комбинацией, то есть человек видел ЧТО назначено, но не ЗАЧЕМ. Двое
        // написали автору, что не разобрались, как переключить слово руками и как отменить автозамену.
        // Главное, чего никто не угадывал: переключает и отменяет ОДНА И ТА ЖЕ комбинация.
        // Коротко до предела: справа стоит поле с комбинацией, оно шире тумблера, и места под подпись
        // остаётся мало. Строки в настройках не переносятся принципиально (иначе едет вся сетка),
        // поэтому подпись обязана влезать целиком, а подробности живут в «i».
        "switch.manualSub":  [.ru: "Переключить последнее слово или отменить автозамену",
                             .en: "Switch the last word, or undo an automatic switch"],
        "switch.hkPrefix":[.ru: "Хоткей:  ", .en: "Hotkey:  "],
        "switch.hkRecord":[.ru: "Нажми комбинацию…  (Esc — отмена)", .en: "Press a combo…  (Esc to cancel)"],
        "hk.custom":      [.ru: "Свой…", .en: "Custom…"],
        "hk.press":       [.ru: "Нажми комбинацию…  (Esc)", .en: "Press a combo…  (Esc)"],
        // Окно записи комбинации (HotkeyRecorderPanel)
        // Состояния, в которых Keyboop не может работать (AppHealth). Пишем ЧТО не так и что делать,
        // без паники: человек и так уже видит, что ничего не происходит.
        "health.noAccessibility": [.ru: "Не выдан доступ к Универсальному доступу",
                                   .en: "Accessibility permission not granted"],
        "health.engineDown":      [.ru: "Движок не запущен", .en: "Engine is not running"],
        // Система штормила отключениями тапа, и мы сняли
        // перехват сами, чтобы не держать ввод. Формулировка без терминов: человеку важно, что это
        // наше решение и что оно обратимо, а не что такое «event tap».
        "health.tapSuspended":    [.ru: "Перехват снят: система его глушила, я приостановился",
                                   .en: "Interception is off: the system kept killing it, so I stopped"],
        // ⚠️ КОРОТКО, И ЭТО НЕ ПРИДИРКА К СТИЛЮ (автор 07.08). Было «включён Secure Input (держит
        // Пароли Safari) — macOS прячет клавиатуру»: одна эта строка растягивала всё меню до 578
        // пунктов при том, что любой другой пункт укладывается вдвое у́же. Строка стоит в меню,
        // в подсказке значка и в диагностике отзыва, то есть чинить её надо один раз здесь.
        //
        // Заодно ушёл сам термин (P3.3). «Secure Input» это внутреннее имя механизма Apple, и для
        // человека оно не значит ничего, кроме того, что программа ругается непонятным.
        //
        // ⚠️ И НЕ «БЕЗОПАСНЫЙ ВВОД» (автор 07.08, отверг). Прямой перевод термина заводит шкалу,
        // которой нет: если ЭТОТ ввод безопасный, то весь остальной, выходит, опасный. «Скрытый»
        // описывает ровно то, что происходит (система прячет от нас клавиши), и ничего не оценивает.
        //
        // ⚠️ ДВОЕТОЧИЕ ПЕРЕД ИМЕНЕМ ОБЯЗАТЕЛЬНО, иначе ломается согласование. Имена держателей
        // бывают во множественном числе («Системные настройки», «Пароли»), и «клавиатуру держит
        // Системные настройки» читается как ошибка. Двоеточие снимает вопрос о числе вовсе.
        //
        // Зачин выбран КОРОТКИМ намеренно: длина зачина и место под имя это одна величина, и при
        // «где-то открыто поле пароля: » имени оставалось бы четыре символа. Обрезка имени по
        // ширине живёт в AppHealth.problem(rowWidth:).
        "health.secureInput":     [.ru: "Клавиатуру скрыла другая программа", .en: "Another app hid the keyboard"],
        // ⚠️ ТЕКСТ ОПИРАЕТСЯ НА ЗАМЕР, А НЕ НА ОЩУЩЕНИЕ (26.08.2026). По 120 диагностикам чужой
        // держатель встретился в 25 отчётах у 21 человека, и две трети это браузеры: Chrome 9,
        // Safari 6, Yandex 2. Дальше по одному-двум: 1Password, Viscosity, Slack, Почта, Telegram,
        // терминалы. Поэтому в подсказке названы именно браузеры, а не «какая-то программа вообще».
        // Версия macOS ни при чём: доля ровная 14–29% от 14.8 до 27.0.
        //
        // ⚠️ ENPASS НАЗВАН ПО ИМЕНИ, И ЭТО НЕ ОБВИНЕНИЕ (26.09.2026). Enpass 6.12.6 (вышел 14.09.2026)
        // держит защищённый ввод ВСЁ ВРЕМЯ, пока его хранилище заблокировано, в том числе после
        // автоблокировки в фоне: у автора ветки на форуме Enpass (тема 32258) флаг висел 9 часов.
        // Отпускает только разблокировка или выход из Enpass, а единственный наш совет «заблокируйте
        // и разблокируйте экран» ему не помогает вовсе. С этим и пришёл человек из Telegram:
        // переключение пропало после обновления до macOS 27, а причиной оказался Enpass 6.12.6.
        // Это ПРИМЕР в статичном тексте, а не держатель из ioreg: того по-прежнему не называем
        // (см. абзац «Почему мы не называем виновника»).
        // Совет про экран остаётся одним из вариантов, последним: браузеру и прочим он помогает.
        "health.secureInputWho": [
            .ru: """
                 Что происходит. Какая-то программа включила защищённый ввод macOS. Пока он включён, \
                 система прячет нажатия клавиш ото ВСЕХ программ сразу, не только от Keyboop. \
                 Переключение раскладки в это время не работает ни у кого и починить это изнутри нельзя.

                 Кто это обычно. Чаще всего браузер, в котором осталось в фокусе поле пароля: по нашим \
                 отчётам две трети случаев это Chrome, Safari и Яндекс. Так же умеют менеджеры \
                 паролей, например Enpass и 1Password, а Enpass с версии 6.12.6 держит защиту всё \
                 время, пока его хранилище заблокировано. Реже это VPN-клиенты, мессенджеры и \
                 терминалы с включённым «Secure Keyboard Entry». Ещё это всегда включается на \
                 заблокированном экране, и вот это нормально.

                 Почему мы не называем виновника. macOS сообщает имя держателя ненадёжно: оно \
                 застревает на первом, кто включил защиту за сеанс. Мы проверяли, и там регулярно \
                 оказывается посторонняя программа. Обвинять невиновного хуже, чем промолчать.

                 Что делать. Обычно отпускает само. Если нет: закройте окно или вкладку, где вы \
                 вводили пароль. Если запущен менеджер паролей, разблокируйте его или закройте \
                 совсем. В терминале выключите «Secure Keyboard Entry» в меню программы. А если не \
                 помогло ничего из этого, заблокируйте и разблокируйте экран.

                 Что работает прямо сейчас. Диктовка: ей клавиатура не нужна, она пишет текст сама.
                 """,
            .en: """
                 What is happening. Some app has turned on macOS secure keyboard entry. While it is on, \
                 the system hides keystrokes from EVERY app at once, not just from Keyboop. Layout \
                 switching cannot work for anyone during that time, and no app can fix it from inside.

                 Who usually does it. Most often a browser with a password field left focused: in our \
                 reports two thirds of cases are Chrome, Safari and Yandex. Password managers do it \
                 too, for example Enpass and 1Password, and Enpass since version 6.12.6 keeps it on \
                 the whole time its vault is locked. Less often VPN clients, messengers, and terminals \
                 with Secure Keyboard Entry on. It also always turns on while the screen is locked, \
                 and that part is normal.

                 Why we do not name the culprit. macOS reports the holder unreliably: the name sticks to \
                 whoever turned the protection on first in the session. We measured it, and it regularly \
                 points at an app that has nothing to do with it. Accusing the innocent is worse than \
                 saying nothing.

                 What to do. It usually clears by itself. If it does not: close the window or tab where \
                 you typed a password. If a password manager is running, unlock it or quit it. In a \
                 terminal, turn off Secure Keyboard Entry in the app menu. And if none of that helps, \
                 lock and unlock the screen.

                 What still works. Dictation: it does not need the keyboard, it types the text itself.
                 """],
        // Подсказка значка. Совет про менеджер паролей стоит здесь тоже (26.09.2026): до «Приватности»
        // доходят не все, а у Enpass 6.12.6 блокировка экрана, единственный совет прежнего текста,
        // не помогает. Длинное тире из русского текста убрано заодно.
        "health.secureInputTip":  [.ru: "Какая-то программа включила защищённый ввод macOS, и клавиши скрыты системно: от нас и от любой другой программы. Переключение раскладки сейчас не работает, диктовка работает. Обычно отпускает само. Если нет, закройте вкладку с полем пароля. Менеджер паролей разблокируйте или закройте: Enpass с версии 6.12.6 держит защиту, пока его хранилище заблокировано. Ещё помогает заблокировать и разблокировать экран.",
                                   .en: "Some app turned on macOS secure keyboard entry, so keystrokes are hidden system-wide, from us and from every other app. Layout switching is off for now, dictation still works. It usually clears by itself. If it doesn't, close the tab with the password field. Unlock or quit your password manager: Enpass since 6.12.6 keeps it on while its vault is locked. Locking and unlocking the screen also helps."],
        "health.secureInputHolder": [.ru: "Скрытый ввод: %@", .en: "Hidden input: %@"],
        // Подсказки значка (P3.4). Эти две ЦЕЛЫЕ фразы, а не фрагменты общего ряда, потому что
        // висят сами по себе при наведении. Про паузу отдельной строки нет намеренно: её текст
        // берётся из menu.pausedUntil, чтобы значок и меню называли одно состояние одинаково.
        "health.ok":              [.ru: "Keyboop работает", .en: "Keyboop is working"],
        // Имя держателя, которого не удалось назвать: демоны вроде loginwindow не GUI-приложения,
        // и NSRunningApplication про них ничего не знает. Раньше тут стоял русский литерал прямо
        // в Engine, и он приезжал «зайцем» в английский текст.
        "health.holderUnknown":   [.ru: "фоновый процесс", .en: "a background process"],
        "health.autoOff":         [.ru: "Авто-переключение выключено", .en: "Auto-switch is off"],
        "hkrec.title":    [.ru: "Новая комбинация", .en: "New shortcut"],
        "hkrec.for":      [.ru: "Для действия: %@", .en: "For: %@"],
        "hkrec.waiting":  [.ru: "нажмите клавиши", .en: "press keys"],
        // ⚠️ ПОДСКАЗКА ПРЯТАЛА ПОЛОВИНУ ВОЗМОЖНОСТЕЙ (отзыв, 04.08.2026). Было: «Держите модификаторы
        // и нажмите клавишу». Модификаторы во множественном числе, и обязательно «плюс клавиша», из
        // чего человек честно делал вывод, что одной клавишей обойтись нельзя, и просил добавить то,
        // что уже работало. Одиночный модификатор код принимает с самого начала: нажал, отпустил,
        // назначилось. Не было сказано только об этом. Пишем оба способа, второй с примером.
        // Короче на треть: текст переносится по ширине окна, и три строки мелким кеглем читаются
        // хуже двух. Про Esc не пишем, рядом стоит кнопка «Отмена» и она виднее.
        "hkrec.hint":     [.ru: "Держите модификаторы и нажмите клавишу. Либо просто нажмите и отпустите один модификатор.",
                           .en: "Hold modifiers and press a key. Or just press and release a single modifier."],
        "snip.needMods":  [.ru: "Нужен хотя бы один модификатор: одна клавиша отберёт обычный ввод", .en: "At least one modifier is needed: a bare key would steal ordinary typing"],
        "hkrec.warn.system":[.ru: "Это сочетание уже занято: %@. Назначить можно, но тогда системную функцию стоит отключить в настройках macOS, иначе сработают обе.",
                           .en: "This shortcut is already taken: %@. You can still assign it, but then turn the system function off in macOS settings, or both will fire."],
        "hk.sysGeneric":  [.ru: "системная функция macOS", .en: "a macOS system function"],
        "hkrec.assign":   [.ru: "Назначить", .en: "Assign"],
        // Предупреждения ВНУТРИ окна записи. Тон: понятно, без занудства, с лёгкой усмешкой.
        // ⚠️ Советов «добавьте ⌥ или ⌃» здесь нет намеренно (автор 28.07): объясняем, почему нельзя,
        // а что нажать вместо — человек решает сам. И про F13…F20 молчим: на маке они живут через
        // Fn, так почти никто не назначает, а оговорка только удлиняет текст.
        "hkrec.warn.busy": [.ru: "%@ система уже забрала себе. Отнимать не будем, вам же им пользоваться.",
                            .en: "%@ is already taken by the system. We won't fight it, you need it too."],
        "hkrec.warn.bare": [.ru: "Одна клавиша без модификаторов отнимется у всех программ сразу, включая ту, где вы сейчас читаете это.",
                            .en: "A key with no modifiers gets taken from every app at once, including the one you're reading this in."],
        "hkrec.warn.ours": [.ru: "Это сочетание у нас уже занято: %@. Две функции на одну комбинацию не уживутся.",
                            .en: "We already use this one for %@. Two actions on one shortcut never ends well."],
        "hkrec.cancel":   [.ru: "Отмена", .en: "Cancel"],
        "case.title":  [.ru: "Менять регистр выделенного", .en: "Change case of the selection"],
        "case.sub":    [.ru: "«телефон» становится «ТЕЛЕФОН», второе нажатие возвращает обратно",
                        .en: "«phone» becomes «PHONE», pressing again brings it back"],
        "case.help":   [.ru: "Выделите текст и нажмите сочетание: всё выделенное станет заглавным, независимо от того, что там было. Если оно уже заглавное целиком, следующее нажатие опустит его в строчные, так что одна комбинация работает в обе стороны и помнить ничего не нужно. Задумано для заголовков, титров и типографики, поэтому работает и с несколькими строками сразу. Ограничение одно: до 5000 символов за раз, чтобы случайное «Выделить всё» не подняло в верхний регистр весь документ. В программах, которые не отдают выделение системе (Electron, веб), текст читается через буфер обмена и возвращается в него ровно таким, каким был. По умолчанию сочетание не назначено.",
                        .en: "Select some text and press the shortcut: everything selected becomes upper case, whatever it was before. If it is already all upper case, the next press takes it down to lower case, so one shortcut works both ways and there is nothing to remember. It is meant for headings, titles and typography, so it works across several lines at once. There is one limit: 5000 characters at a time, so that an accidental «Select All» cannot shout a whole document. In apps that do not hand their selection to the system (Electron, web) the text is read through the clipboard and the clipboard is put back exactly as it was. No shortcut is assigned by default."],
        "case.assign": [.ru: "Сочетание", .en: "Shortcut"],
        "hkrec.what.switch": [.ru: "исправление раскладки по хоткею", .en: "fix layout by hotkey"],
        "hkrec.what.voice":  [.ru: "голосовой набор", .en: "dictation"],
        "hkrec.what.translate": [.ru: "перевод выделенного", .en: "translate selection"],
        "hkrec.what.pasteLast": [.ru: "вставка последней диктовки", .en: "insert the last dictation"],
        "hkrec.what.instant":[.ru: "мгновенная смена языка", .en: "instant language switch"],

        // — 0.2.20: строки, ранее захардкоженные мимо L10n (ревизия локализации) —
        // Назначение хоткея (UIControls.displayHotkey / display)
        "hk.rOpt":        [.ru: "Правый ⌥",  .en: "Right ⌥"],
        "hk.lOpt":        [.ru: "Левый ⌥",   .en: "Left ⌥"],
        "hk.rCmd":        [.ru: "Правый ⌘",  .en: "Right ⌘"],
        "hk.lCmd":        [.ru: "Левый ⌘",   .en: "Left ⌘"],
        "hk.rShift":      [.ru: "Правый ⇧",  .en: "Right ⇧"],
        "hk.lShift":      [.ru: "Левый ⇧",   .en: "Left ⇧"],
        "hk.rCtrl":       [.ru: "Правый ⌃",  .en: "Right ⌃"],
        "hk.lCtrl":       [.ru: "Левый ⌃",   .en: "Left ⌃"],
        "hk.key":         [.ru: "клавиша",   .en: "key"],
        "hk.dblMod":      [.ru: "2× мод.",   .en: "2× mod."],
        // Алерты доступа/переноса/перезапуска (AppDelegate)
        "alert.ax.title": [.ru: "Keyboop нужен доступ к Accessibility", .en: "Keyboop needs Accessibility access"],
        "alert.ax.body":  [.ru: "Включи Keyboop в System Settings → Privacy & Security → Accessibility.\nКак включишь — переключение раскладки заработает сразу, перезапускать не нужно.",
                           .en: "Enable Keyboop in System Settings → Privacy & Security → Accessibility.\nOnce you do, layout switching works right away — no restart needed."],
        "alert.ax.open":  [.ru: "Открыть Accessibility", .en: "Open Accessibility"],
        "alert.later":    [.ru: "Позже", .en: "Later"],
        "alert.punto.title":[.ru: "Запущен Punto Switcher", .en: "Punto Switcher is running"],
        "alert.punto.body": [.ru: "Punto Switcher и Keyboop оба переключают раскладку — вместе они конфликтуют и мешают друг другу. Рекомендуем закрыть Punto. Чтобы он не запускался снова — убери его из «Объектов входа».",
                             .en: "Punto Switcher and Keyboop both switch the keyboard layout — together they conflict and fight each other. We recommend quitting Punto. To stop it launching again, remove it from Login Items."],
        "alert.punto.quit": [.ru: "Закрыть Punto", .en: "Quit Punto"],
        "alert.punto.login":[.ru: "Объекты входа…", .en: "Login Items…"],
        "alert.regrant.title":[.ru: "После обновления переразреши Keyboop", .en: "Re-grant Keyboop after the update"],
        "alert.regrant.body": [.ru: "Похоже, ты обновил Keyboop (%@ → %@). Из-за смены подписи доступ к Accessibility мог «протухнуть»: в списке он показан включённым, но не действует.\n\nПочини один раз: System Settings → Privacy & Security → Accessibility → выдели Keyboop, нажми «−» (убрать), затем добавь заново «+» (или перетащи Keyboop в список).\n\nЭто разовое — дальнейшие обновления доступ сохранят.",
                               .en: "Looks like you updated Keyboop (%@ → %@). Because the signature changed, Accessibility access may have gone stale: it shows as enabled but doesn't work.\n\nFix it once: System Settings → Privacy & Security → Accessibility → select Keyboop, press “−” (remove), then add it again with “+” (or drag Keyboop into the list).\n\nThis is one-time — future updates keep the access."],
        "alert.move.title":[.ru: "Перенеси Keyboop в «Программы»", .en: "Move Keyboop to Applications"],
        "alert.move.body": [.ru: "Keyboop запущен из временной папки (образа .dmg или «Загрузок»), поэтому macOS не сохранит за ним доступ к Accessibility, и переключение раскладки работать не будет.\n\nПеретащи Keyboop.app в «Программы» и запусти уже оттуда — тогда всё заработает и не слетит.",
                            .en: "Keyboop is running from a temporary folder (a .dmg image or Downloads), so macOS won't keep its Accessibility access and layout switching won't work.\n\nDrag Keyboop.app into Applications and launch it from there — then everything works and sticks."],
        "alert.move.reveal":[.ru: "Показать в Finder", .en: "Reveal in Finder"],
        "alert.relaunch.title":[.ru: "Перезапустить Keyboop?", .en: "Relaunch Keyboop?"],
        "alert.relaunch.body": [.ru: "Доступ к Accessibility выдан, но macOS не подхватил его для текущего сеанса (известная особенность системы). Один перезапуск Keyboop это чинит — перезагружать компьютер не нужно.",
                                .en: "Accessibility is granted, but macOS didn't pick it up for the current session (a known system quirk). One relaunch of Keyboop fixes it — no need to reboot."],
        "alert.relaunch.ok":[.ru: "Перезапустить", .en: "Relaunch"],
        "alert.relaunch.no":[.ru: "Не сейчас", .en: "Not now"],
        // Индикатор диктовки (VoiceIndicator) + a11y статусов меню-бара
        "voice.listening":[.ru: "Слушаю…", .en: "Listening…"],
        "voice.recognizing":[.ru: "Распознаю…", .en: "Recognizing…"],
        "voice.enhancing":[.ru: "Улучшаю…", .en: "Enhancing…"],
        // Очистка текста, фоновая нарезка и AI-постобработка
        "voice.cleanFillers":           [.ru: "Удалять слова-паразиты", .en: "Remove filler words"],
        "voice.cleanFillersSub":        [.ru: "Убирает «эээ», «ммм», «uh», «um» перед вставкой", .en: "Strips hesitation fillers like “uh”, “um”, “эээ” before pasting"],
        "voice.cleanFillersHelp":       [.ru: "Детерминированная очистка: удаляет частые междометия-хезитации, сохраняя заглавные буквы в начале предложений и пунктуацию.", .en: "Deterministic cleanup: removes common spoken hesitation fillers while preserving sentence capitalization and punctuation."],
        "voice.collapseStutters":       [.ru: "Схлопывать повторы слов", .en: "Collapse word stutters"],
        "voice.collapseStuttersSub":    [.ru: "Убирает случайные 3+ повтора подряд («я я я» → «я»)", .en: "Collapses 3+ accidental consecutive word repeats (“I I I” → “I”)"],
        "voice.pauseChunking":          [.ru: "Фоновая нарезка длинных диктовок", .en: "Background pause chunking"],
        "voice.pauseChunkingSub":       [.ru: "Распознаёт фрагменты на паузах (от 10 с), не дожидаясь стопа", .en: "Transcribes long speech chunk-by-chunk during pauses (> 10s)"],
        "voice.pauseChunkingHelp":      [.ru: "Диктовки короче 10 секунд по-прежнему распознаются целиком за один проход. На длинной речи фрагменты уходят в модель прямо во время пауз, поэтому финальный ответ приходит почти сразу.", .en: "Dictations under 10 seconds still run in a single pass. On longer recordings, segments are transcribed in the background during natural pauses so final output appears almost right away."],
        "voice.grpAI":                  [.ru: "AI-постобработка", .en: "AI Post-Processing"],
        "voice.postprocess.enable":     [.ru: "Улучшать текст после диктовки", .en: "Enhance text after dictation"],
        "voice.postprocess.enableSub":  [.ru: "Пунктуация, орфография и оформление по промпту локально", .en: "Fixes punctuation, grammar, and formatting locally via prompt"],
        "voice.postprocess.help":       [.ru: "Текст обрабатывается локально на этом Mac через Apple Intelligence или локальный LLM-сервер, ничего не уходит в облако. При ошибке или таймауте вставляется очищенная расшифровка.", .en: "Runs strictly on your Mac via Apple Intelligence or a local LLM server. Nothing leaves your machine. On error or timeout, the cleaned transcript is pasted as fallback."],
        "voice.postprocess.hotkey":     [.ru: "Отдельный хоткей «Диктовка с AI»", .en: "Dedicated AI dictation hotkey"],
        "voice.postprocess.hotkeySub":  [.ru: "Включает постобработку только по этому сочетанию", .en: "Runs AI post-processing only for this shortcut"],
        "voice.postprocess.hotkeyAssign":[.ru: "Назначить…", .en: "Assign…"],
        "voice.postprocess.hotkeyChange":[.ru: "Изменить…", .en: "Change…"],
        "voice.postprocess.hotkeyClear":[.ru: "Очистить", .en: "Clear"],
        "voice.postprocess.hotkeyUnset":[.ru: "Не назначен", .en: "Not set"],
        "hkrec.what.voiceAI":           [.ru: "диктовки с AI", .en: "AI dictation"],
        "voice.postprocess.provider":   [.ru: "Движок постобработки", .en: "Post-processing engine"],
        "voice.postprocess.apple":      [.ru: "Apple Intelligence", .en: "Apple Intelligence"],
        "voice.postprocess.local":      [.ru: "Локальный LLM", .en: "Local LLM"],
        "voice.postprocess.baseURL":    [.ru: "Base URL", .en: "Base URL"],
        "voice.postprocess.model":      [.ru: "Модель", .en: "Model"],
        "voice.postprocess.apiKey":     [.ru: "API-ключ", .en: "API key"],
        "voice.postprocess.apiKeyPh":   [.ru: "Необязательно", .en: "Optional"],
        "voice.postprocess.promptRow":  [.ru: "Промпт", .en: "Prompt"],
        "voice.postprocess.editPrompt": [.ru: "Настроить…", .en: "Edit prompt…"],
        "voice.postprocess.promptTitle":[.ru: "Промпт AI-постобработки", .en: "AI Post-Processing Prompt"],
        "voice.postprocess.preset.improve":[.ru: "Исправить", .en: "Clean up"],
        "voice.postprocess.preset.formal":[.ru: "Деловой стиль", .en: "Professional"],
        "voice.postprocess.preset.bullets":[.ru: "Список", .en: "Bullet list"],
        "voice.postprocess.reset":      [.ru: "Сбросить", .en: "Reset"],
        "voice.postprocess.test":       [.ru: "Проверить", .en: "Test prompt"],
        "voice.postprocess.testing":    [.ru: "Выполняю…", .en: "Running…"],
        "voice.postprocess.testSample": [.ru: "привет давай завтра созвонимся часов в десять утра обсудим релиз ок", .en: "hey let's hop on a call tomorrow around ten am to discuss the release okay"],
        "voice.postprocess.apple.ok":   [.ru: "Apple Intelligence готов (на устройстве)", .en: "Apple Intelligence is ready (on-device)"],
        "voice.postprocess.apple.os":   [.ru: "Требуется macOS 26 (Tahoe) или новее", .en: "Requires macOS 26 (Tahoe) or newer"],
        "voice.postprocess.apple.device":[.ru: "Apple Intelligence не поддерживается этим Mac", .en: "Apple Intelligence is not supported on this Mac"],
        "voice.postprocess.apple.disabled":[.ru: "Включите Apple Intelligence в Системных настройках", .en: "Enable Apple Intelligence in System Settings"],
        "voice.postprocess.apple.notready":[.ru: "Модель Apple Intelligence ещё загружается или готовится", .en: "Apple Intelligence model is downloading or preparing"],
        "voice.postprocess.apple.unavailable":[.ru: "Apple Intelligence сейчас недоступен", .en: "Apple Intelligence is currently unavailable"],
        "voice.postprocess.err.empty":  [.ru: "Пустой текст", .en: "Empty transcript"],
        "voice.postprocess.err.url":    [.ru: "Некорректный Base URL (ожидается http:// или https://)", .en: "Invalid Base URL (expected http:// or https://)"],
        "voice.postprocess.err.model":  [.ru: "Укажите имя модели", .en: "Specify a model name"],
        "voice.postprocess.err.response":[.ru: "Модель вернула пустой или некорректный ответ", .en: "Model returned an empty or invalid response"],
        "voice.postprocess.err.timeout":[.ru: "Превышено время ожидания ответа модели", .en: "Post-processing request timed out"],
        "voice.postprocess.fallbackToast":[.ru: "AI недоступен — вставлен исходный текст", .en: "AI unavailable — pasted cleaned transcript"],
        "a11y.recording": [.ru: "Запись", .en: "Recording"],
        // Хранение истории голоса (SettingsWindow)
        "ret.30m":        [.ru: "30 минут", .en: "30 minutes"],
        "ret.1h":         [.ru: "1 час",    .en: "1 hour"],
        "ret.2h":         [.ru: "2 часа",   .en: "2 hours"],
        "ret.4h":         [.ru: "4 часа",   .en: "4 hours"],
        "ret.8h":         [.ru: "8 часов",  .en: "8 hours"],
        "ret.7d":         [.ru: "7 дней",   .en: "7 days"],
        "ret.30d":        [.ru: "30 дней",  .en: "30 days"],
        "ret.never":      [.ru: "Не удалять", .en: "Keep all"],
        "model.memNote":    [.ru: "Пока модель загружена, она занимает в памяти примерно столько же, сколько весит на диске. Само приложение без модели это около 285 МБ. Модель выгружается после часа без диктовки, а если системе не хватает памяти, то раньше.",
                             .en: "While a model is loaded it takes roughly as much memory as it takes on disk. The app itself without a model is about 285 MB. A model is unloaded after an hour without dictation, and sooner if the system runs short of memory."],
        // Общие действия / подсказки (тултипы, a11y)
        "act.delete":     [.ru: "Удалить", .en: "Delete"],
        "act.close":      [.ru: "Закрыть", .en: "Close"],
        "snip.delRow":    [.ru: "Удалить строку", .en: "Delete row"],
        "hist.opacityHint":[.ru: "⌃-клик: настроить", .en: "⌃-click: configure"],
        "audio.micFallback":[.ru: "Микрофон", .en: "Microphone"],
        "switch.trig":    [.ru: "Срабатывание", .en: "Triggers"],
        "switch.trigAfter":[.ru: "После слова", .en: "After a word"],
        "key.space":      [.ru: "Пробел", .en: "Space"],
        "key.enter":      [.ru: "Enter",  .en: "Enter"],
        "key.tab":        [.ru: "Tab",    .en: "Tab"],
        // Заголовок переписан 28.07 по прямому вопросу из репорта #31: «Пункт "стрелка отменяет
        // переключение" — это про какую стрелку речь?». Старая формулировка не отвечала ни на
        // «какая стрелка», ни на «переключение чего», и у строки вдобавок не было подписи вовсе.
        // ⚠️ ВЕРНУЛИ ПРЕЖНЕЕ НАЗВАНИЕ (автор 13.08.2026: «раньше было нормально — стрелки отменяют
        // переключение, с чего вдруг переименовали»). Формулировка «сбрасывают набранное слово»
        // описывала НАШУ внутреннюю механику (буфер набранного), а не то, что человек видит.
        // Человек видит одно: нажал стрелку — слово не переключилось. Название настройки обязано
        // говорить о результате, а не о том, как он устроен внутри.
        "switch.arrows":  [.ru: "Стрелки отменяют переключение",
                           .en: "Arrow keys cancel the switch"],
        "switch.arrowsSub": [.ru: "Нажали стрелку курсора — и слово, которое вы печатали, переключаться уже не будет. Удобно, если вы часто правите текст, двигая курсор",
                             .en: "Press a cursor arrow and the word you were typing will not be switched any more. Handy if you often move the caret while writing"],
        "switch.soundOn": [.ru: "Звук при переключении", .en: "Sound on switch"],
        "switch.sound":   [.ru: "Звук", .en: "Sound"],
        "switch.soundVol":[.ru: "Громкость", .en: "Volume"],
        "switch.login":   [.ru: "Запускать при входе в систему", .en: "Launch at login"],
        "sound.none":     [.ru: "Без звука", .en: "No sound"],

        "exc.appsTitle":  [.ru: "Программы-исключения", .en: "App exceptions"],
        "exc.appsSub":    [.ru: "Где не переключать раскладку автоматически. «Мягкий» — только очевидные слова, одиночные/повторяющиеся буквы не трогаем (хоткеи целы). Слева от режима — раскладка, которую включать при входе в программу: EN спасает там, где хоткеи работают только на латинице.",
                           .en: "Where not to auto-switch the layout. “Soft” — only obvious words; single/repeated letters are left alone (hotkeys stay intact). Left of the mode is the layout to switch to when you enter the app: EN saves you where hotkeys only work in Latin."],
        "exc.appsEmpty":  [.ru: "Пока пусто. Добавь программу ниже.", .en: "Empty so far. Add an app below."],
        "exc.appsHint":   [.ru: "Перетаскивать не нужно — выбери из /Applications или из запущенных.", .en: "No dragging needed — pick from /Applications or from running apps."],
        "exc.off":        [.ru: "Выкл", .en: "Off"],
        "exc.soft":       [.ru: "Мягкий", .en: "Soft"],
        "exc.forceLayoutHelp": [.ru: "Всегда включать эту раскладку при переходе в программу. Нужно там, где горячие клавиши работают только на латинице (DaVinci Resolve и подобные). Переключаем на входе; если внутри вы сменили раскладку сами, спорить не будем. Прочерк — не трогать.",
                                .en: "Always switch to this layout when you go into the app. Handy where hotkeys only work in Latin (DaVinci Resolve and friends). We switch on entry; if you change the layout yourself inside, we leave it alone. Dash means do not touch."],
        "exc.addApp":     [.ru: "Добавить программу…", .en: "Add app…"],
        "exc.fromRunning":[.ru: "Из запущенных…", .en: "From running…"],
        "exc.title":      [.ru: "Исключения", .en: "Exceptions"],
        // ⚠️ ТЕКСТ ПЕРЕПИСАН 04.08.2026 ВМЕСТЕ С МЕХАНИКОЙ. Раньше слова назывались «образцом», хотя
        // на деле были декорацией: настоящая защита сидела в глобальном списке, и удаление чипа
        // ничего не меняло. Теперь это обычные исключения, и подпись говорит именно это.
        "exc.sub":        [.ru: "Слова, которые трогать не надо. Впиши и нажми Enter или «Добавить». «вк», «тг» и «vk» добавлены сразу: их раскладочная пара случайно совпадает со словом другого языка, и без исключения они ломались бы.",
                           .en: "Words to leave alone. Type one and press Enter or “Add”. «вк», «тг» and “vk” come pre-added: each one’s layout-swap happens to be a real word in the other language, so without an exception they would get mangled."],
        "exc.hint":       [.ru: "Удалить слово — крестик ✕ на нём. Удалите «вк» или «vk» — они снова начнут переключаться: это обычные исключения, без особых прав.",
                           .en: "Remove a word — the ✕ on it. Delete «вк» or “vk” and they start switching again: these are ordinary exceptions, with no special powers."],
        "exc.empty":      [.ru: "Пока пусто.", .en: "Empty so far."],
        "exc.addPlaceholder":[.ru: "Слово…", .en: "Word…"],
        "exc.addWord":    [.ru: "Добавить", .en: "Add"],
        // Исход добавления слова в исключения (P3.5). Обращаемся на «ты», как соседние строки
        // этого же раздела («Впиши и нажми Enter», «Добавь программу ниже»).
        // ⚠️ «Уже бережём» СООБЩАЕТ, а не отказывает: слово всё равно добавлено, см. addIgnored.
        "exc.res.rejected":[.ru: "«%@» так не сработает: в слове не может быть пробела",
                            .en: "«%@» will never match: a word cannot contain a space"],
        "exc.res.builtin": [.ru: "«%@» мы и так бережём, но теперь это и твоя запись",
                            .en: "«%@» is protected out of the box, but now it is yours too"],
        "exc.res.already": [.ru: "«%@» уже в списке",
                            .en: "«%@» is already in the list"],
        "exc.builtinTitle":[.ru: "Уже бережём", .en: "Already protected"],
        "exc.builtinBody": [.ru: "Популярные сервисы, чья раскладка случайно совпадает с английским словом, не трогаем по умолчанию — например «вк», «тг». Список вшит и обновляется с приложением.",
                            .en: "Popular services whose layout-swap happens to be an English word are left alone by default — e.g. «вк», «тг». The list is built in and ships with updates."],
        "learn.title":    [.ru: "Учиться на отмене", .en: "Learn from undo"],
        "learn.sub":      [.ru: "Если сразу откатить переключение и вернуть слово как было — спрошу, добавить ли его в исключения. Скажешь «нет» — больше про него не спрошу.",
                           .en: "Undo a switch right away and restore the word as you typed it — I'll ask whether to add it to exceptions. Say no and I won't ask about it again."],
        "learn.askTitle": [.ru: "Оставить «%@» как есть?", .en: "Keep “%@” as is?"],
        "learn.askBody":  [.ru: "Добавить в исключения, чтобы Keyboop его больше не переключал?",
                           .en: "Add it to exceptions so Keyboop stops switching it?"],
        "learn.add":      [.ru: "Добавить", .en: "Add"],
        "learn.no":       [.ru: "Не надо", .en: "No thanks"],
        "learn.hint":     [.ru: "Выученные слова — ниже. Удалить — крестик ✕ на слове; «Очистить» убирает все.",
                           .en: "Learned words are below. Remove one — the ✕ on it; “Clear” removes all."],
        "learn.empty":    [.ru: "Пока ничего не выучено.", .en: "Nothing learned yet."],
        "learn.clear":    [.ru: "Очистить", .en: "Clear"],
        "learn.toast":    [.ru: "Запомнил: больше не трогаю «%@»", .en: "Got it — leaving «%@» alone from now on"],

        "snip.title":     [.ru: "Автозамена", .en: "Snippets"],
        "snip.expandOn":  [.ru: "Разворачивать по клавише", .en: "Expand on key"],
        "snip.disabled":  [.ru: "Автозамена отключена — не выбрана ни одна клавиша разворота.",
                           .en: "Snippets are off — no expansion key selected."],
        "snip.sub":       [.ru: "Набрал сокращение, нажал пробел — развернулось.",
                           .en: "Type a shortcut, hit space — it expands."],
        "snip.hint":      [.ru: "Раскладка и регистр не учитываются: !test = !TEST = !еуые. Разворачивается по пробелу или Enter.",
                           .en: "Layout and case are ignored: !test = !TEST = !еуые. Expands on space or Enter."],
        "snip.colTrigger":[.ru: "Что заменять", .en: "Replace"],
        "snip.colExpansion":[.ru: "На что", .en: "With"],
        "snip.phTrigger": [.ru: "напр. сув", .en: "e.g. br"],
        "snip.phExpansion":[.ru: "напр. С уважением, Алекс", .en: "e.g. Best regards, Alex"],
        "snip.add":       [.ru: "Добавить", .en: "Add"],

        "priv.title":     [.ru: "Не звонит домой", .en: "Doesn't phone home"],
        "priv.body":      [.ru: "Keyboop не следит за тобой. Ни телеметрии, ни аналитики, ни кейлоггинга — всё, что ты печатаешь и говоришь, остаётся на твоём Mac.",
                           .en: "Keyboop doesn't track you. No telemetry, no analytics, no keylogging — whatever you type and say stays on your Mac."],
        // ⚠️ ТЕКСТ РАСХОДИЛСЯ С САЙТОМ, И НЕ В ПОЛЬЗУ ЧЕСТНОСТИ (аудит, 05.08.2026). Здесь стояло «только
        // в двух случаях: модель и обновления», а страница приватности перечисляет ЧЕТЫРЕ повода. Не
        // хватало ровно того, где наружу уходит содержимое: отправки отзыва вместе с хвостом лога.
        // Обещание, сказанное двумя разными числами в двух местах, перестаёт быть обещанием.
        "priv.body2":     [.ru: "В сеть Keyboop выходит по четырём поводам, и три из них начинаешь ты: скачать языковую модель, открыть сайт или телеграм из меню, отправить отзыв (уходит ровно то, что видно в окне отправки). Четвёртый — проверка обновлений: она шлёт только твой IP и номер версии, как любой заход на сайт. Ни буквы из набранного или надиктованного. Всё выключается в Настройках → Обновления.",
                           .en: "Keyboop goes online for four reasons, and you start three of them: downloading a voice model, opening the site or Telegram from the menu, sending feedback (only what you see in the send window goes out). The fourth is the update check: it sends your IP and version number, the same as visiting any website. Not a letter of what you typed or dictated. All of it can be turned off in Settings → Updates."],
        "priv.guard":     [.ru: "Вместе с Keyboop всю его сессию работает второй спящий процесс с тем же именем. Это общий сторож системных состояний: он возвращает действие клавиши 🌐 и выключает датчик жеста, если основная программа завершится аварийно. Пока функции не используются, он ничего не включает и просто ждёт. В сеть не ходит, ввод и движения не записывает, вашего в нём нет ничего.",
                           .en: "A second sleeping process with the same name runs for the whole Keyboop session. It guards system state: it restores the 🌐 key action and turns off the gesture sensor if the main app exits abnormally. When those features are unused it enables nothing and simply waits. It never goes online and records neither input nor motion."],
        "priv.guardNoSlap":[.ru: "Вместе с Keyboop всю его сессию работает второй спящий процесс с тем же именем. Это сторож системного состояния: он возвращает действие клавиши 🌐, если основная программа завершится аварийно. Пока функция не используется, он ничего не меняет и просто ждёт. В сеть не ходит, ввод не записывает, вашего в нём нет ничего.",
                           .en: "A second sleeping process with the same name runs for the whole Keyboop session. It guards system state by restoring the 🌐 key action if the main app exits abnormally. While that feature is unused it changes nothing and simply waits. It never goes online or records input."],
        "priv.update":    [.ru: "Обновления — на keyboop.com", .en: "Updates — at keyboop.com"],
        "priv.foot":      [.ru: "Спокойно. Всё остаётся на твоём Mac.", .en: "Calm. It all stays on your Mac."],
        "gen.title":      [.ru: "Общие", .en: "General"],
        "gen.sub":        [.ru: "Язык интерфейса, автозапуск и доступ к системе.",
                           .en: "Interface language, launch at login, and system access."],
        // ⚠️ ЗАГОЛОВОК НАЗЫВАЕТ ДЕЙСТВИЕ, А НЕ ВЫГОДУ (отзыв в Instagram Direct, 01.08.2026).
        // Женщина написала: «У меня до приложения клавиатура переключалась нажатием Caps Lock. Её же
        // я хотела установить клавишей переключения раскладки в приложении, но не получилось».
        // Функция у нас есть ровно эта. Она её не нашла, потому что строка называлась «Менять
        // раскладку БЕЗ ЗАДЕРЖКИ»: человек ищет «сменить клавишу переключения», а мы предлагали ему
        // скорость. Отсутствие задержки — приятное следствие, а не то, за чем сюда приходят, поэтому
        // оно уехало в подзаголовок, а в заголовок встала клавиша.
        // Правило имён T44 сохранено: настройка меняет только раскладку → начинается с «Менять
        // раскладку». Caps Lock назван в подзаголовке ДОСЛОВНО — именно это слово люди ищут глазами.
        "is.title":       [.ru: "Менять раскладку без задержки", .en: "Change layout without the delay"],
        "is.enable":      [.ru: "Менять раскладку без задержки", .en: "Change layout without the delay"],
        "is.enableSub":   [.ru: "У системного переключения есть заметная пауза. Здесь язык меняется сразу, своей клавишей: Caps Lock, 🌐 или любой комбинацией. Набранное не трогаем, это только раскладка, отдельно от ручного исправления слова.",
                           .en: "The system's own switch has a noticeable pause. This one changes the language at once, with a key of your choice: Caps Lock, 🌐 or any shortcut. Your text isn't touched, it's only the layout, separate from fixing a word by hand."],
        // Отказ Caps-режима, сказанный человеку. Без обвинений и без просьбы «удалите Karabiner»:
        // чужой ремап человек ставил осознанно, и ломать его молча мы не станем — об этом и пишем.
        "is.capsForeign": [.ru: "Caps Lock занят: на этом Mac уже настроен свой ремап клавиш (обычно это Karabiner или похожая утилита). Перебивать чужую настройку мы не будем — выберите другую клавишу выше, или снимите тот ремап и включите тумблер заново.",
                           .en: "Caps Lock is taken: this Mac already has its own key remapping (usually Karabiner or a similar tool). We won't override someone else's setup — pick a different key above, or remove that remapping and switch this back on."],
        "is.capsFailed":  [.ru: "Caps Lock не удалось перенастроить: система отклонила запрос. Выберите другую клавишу выше или напишите нам через «Сообщить о проблеме…», приложив лог.",
                           .en: "Caps Lock could not be remapped: the system refused the request. Pick a different key above, or write to us via “Report a problem…” and attach the log."],
        "is.combo":       [.ru: "Комбинация", .en: "Shortcut"],
        "is.offHint":     [.ru: "Выключено — клавиши работают как обычно, системные действия на месте.",
                           .en: "Off — the keys behave as usual, system actions untouched."],
        "is.onClean":     [.ru: "Работает. Выключите тумблер — и клавиша вернётся системе, ничего настраивать не нужно.",
                           .en: "Working. Turn the toggle off and the key goes back to the system — nothing to configure."],
        "is.onShadow":    [.ru: "Работает. Пока включено, эта комбинация больше не вызывает %@ — мы перехватываем её раньше. Выключите тумблер, и всё вернётся.",
                           .en: "Working. While it's on, this shortcut no longer triggers %@ — we intercept it first. Turn the toggle off and everything comes back."],
        "is.warn.title":  [.ru: "Комбинация перейдёт к Keyboop", .en: "The shortcut goes to Keyboop"],
        "is.warn.body":   [.ru: "Теперь она мгновенно меняет язык. Пока включено, %@ по этой комбинации работать не будет. Выключите тумблер — вернётся, системные настройки мы не трогаем.",
                           .en: "It will switch the language instantly. While it's on, %@ won't respond to this shortcut. Turn the toggle off and it returns — we don't touch system settings."],
        "is.warn.ok":     [.ru: "Забрать комбинацию", .en: "Take the shortcut"],
        "is.shadow.spotlight":[.ru: "Spotlight (поиск)", .en: "Spotlight (search)"],
        "is.shadow.inputSrc":[.ru: "системную смену языка", .en: "the system's language switch"],
        "is.shadow.caps": [.ru: "Caps Lock (заглавные)", .en: "Caps Lock (capitals)"],
        "is.shadow.globe":[.ru: "системное действие клавиши 🌐", .en: "the 🌐 key's system action"],
        // ОДНА КОМБИНАЦИЯ НА ДВА ДЕЙСТВИЯ (отзыв #134). Формулируем через СИМПТОМ, а не через
        // термин: человек пришёл с «переключение тормозит», а не с «у меня конфликт хоткеев», и
        // должен узнать в тексте свою жалобу.
        "clash.title":    [.ru: "Одна клавиша на два действия",
                           .en: "One key, two actions"],
        "clash.body":     [.ru: "На одно сочетание назначены %@ и %@. Из-за этого каждое нажатие ждёт, удержание это или короткое нажатие, и переключение кажется медленным. Дайте одному из них другую клавишу.",
                           .en: "The same shortcut runs %@ and %@. Every press has to wait and see whether you are holding or tapping, which makes switching feel slow. Give one of them another key."],
        "clash.open":     [.ru: "Открыть настройки", .en: "Open settings"],
        "is.busy.title":  [.ru: "Комбинация уже занята", .en: "Shortcut already taken"],
        "is.busy.body":   [.ru: "На неё в Keyboop назначено: %@. Выберите другую — иначе два действия подрались бы за одно нажатие.",
                           .en: "In Keyboop it's already used for: %@. Pick another one — otherwise two actions would fight over one press."],
        "is.busy.convert":[.ru: "исправление слова (ручной хоткей)", .en: "fixing a word (manual hotkey)"],
        "is.busy.voice":  [.ru: "голосовой набор", .en: "voice typing"],
        "is.busy.voiceAI":[.ru: "диктовка с AI", .en: "AI dictation"],
        "is.busy.translate":[.ru: "перевод выделенного", .en: "translating the selection"],
        "is.busy.instant":[.ru: "мгновенная смена языка", .en: "instant language switch"],
        "is.busy.snippet":[.ru: "список сниппетов", .en: "the snippet picker"],
        "is.busy.paste":  [.ru: "вставка без форматирования", .en: "paste without formatting"],
        "is.busy.case":   [.ru: "смена регистра", .en: "changing the case"],
        "is.busy.pasteLast":[.ru: "вставка последней диктовки", .en: "inserting the last dictation"],
        "is.busy.snippetNoFree":[.ru: "все готовые сочетания уже заняты другими функциями. Назначьте своё через «Назначить свою…».",
                                 .en: "every ready-made shortcut is already taken by another function. Set your own via «Set your own…»."],
        "is.noShift":     [.ru: "Shift не подойдёт: он нажимается перед каждой заглавной буквой, и язык начнёт переключаться сам собой. Выберите другую клавишу.",
                           .en: "Shift will not work: you press it before every capital letter, so the language would start switching on its own. Pick another key."],
        // ОСИРОТЕВШАЯ 🌐 (задача 96): клавиша забрана, а забравшего уже нет.
        "is.orphan":      [.ru: "Клавиша 🌐 сейчас ничего не делает: её системное действие когда-то отключили ради мгновенного переключения и не вернули. Так бывает после аварийного завершения на старых версиях.",
                           .en: "The 🌐 key currently does nothing: its system action was switched off for instant layout switching and never restored. This happens after an abnormal exit on older versions."],
        "is.orphanFix":   [.ru: "Вернуть клавише 🌐 системное действие",
                           .en: "Restore the 🌐 key’s system action"],
        "is.capsShift":   [.ru: "Заглавные не потерялись: пока Caps Lock меняет язык, настоящий Caps Lock включается по Shift+Caps Lock.",
                           .en: "Capitals aren't lost: while Caps Lock changes the language, real Caps Lock goes on Shift+Caps Lock."],
        // Лампочка Caps Lock как индикатор языка (механизм перенесён из USRU).
        "led.enable":     [.ru: "Лампочка Caps Lock показывает язык", .en: "Caps Lock light shows the language"],
        "led.enableSub":  [.ru: "Горит — русский, погасла — английский",
                           .en: "Lit means Russian, dark means English"],
        "led.offHint":    [.ru: "Выключено — лампочка работает как обычно, показывает капс.",
                           .en: "Off — the light behaves as usual and shows caps."],
        "led.onHint":     [.ru: "Работает на всех клавиатурах, где лампочка есть. Заглавные на месте: если Caps Lock у вас меняет язык — по Shift+Caps Lock.",
                           .en: "Works on every keyboard that has the light. Capitals stay: if your Caps Lock changes the language, use Shift+Caps Lock."],
        "led.noKb":       [.ru: "Лампочки Caps Lock нет ни на одной подключённой клавиатуре — показывать язык нечем.",
                           .en: "None of the connected keyboards has a Caps Lock light — there's nothing to show the language with."],
        "led.noPerm":     [.ru: "Нужен доступ «Мониторинг ввода» — без него macOS не даёт управлять лампочкой (это ДРУГОЕ разрешение, не то, что для исправления слов). Выдайте его в Настройках системы и перезапустите Keyboop.",
                           .en: "Needs the “Input Monitoring” permission — without it macOS won't let us drive the light (a DIFFERENT permission from the one for fixing words). Grant it in System Settings and restart Keyboop."],
        "globe.title":    [.ru: "Клавиша 🌐", .en: "The 🌐 key"],
        "globe.enable":   [.ru: "🌐 переключает язык мгновенно", .en: "🌐 switches language instantly"],
        "globe.enableSub":[.ru: "Клавиша 🌐 (она же Fn, слева внизу) меняет язык без задержки — набранное не трогаем, это просто смена раскладки. Комбинации Fn+F1, Fn+стрелки работают как раньше.",
                           .en: "The 🌐 key (a.k.a. Fn, bottom-left) switches language with no delay — your text isn't touched, it's just the layout. Fn+F1 and Fn+arrows keep working as before."],
        "globe.ours":     [.ru: "Клавиша 🌐 сейчас за Keyboop — переключает язык мгновенно. Выключите тумблер, и системное действие вернётся.",
                           .en: "The 🌐 key belongs to Keyboop now — instant language switching. Turn the toggle off and the system action comes back."],
        "globe.retaken":  [.ru: "⚠︎ Похоже, системное действие на 🌐 вернули в Настройках системы — сейчас сработают оба. Переключите тумблер выключить-включить, и мы заберём клавишу обратно.",
                           .en: "⚠︎ Looks like the system action on 🌐 was restored in System Settings — both will fire now. Toggle this off and on again and we'll take the key back."],
        "globe.nowSystem":[.ru: "Сейчас на 🌐 работает системное действие: %@.", .en: "Right now 🌐 does the system action: %@."],
        "globe.busy.lang":[.ru: "смена языка (с задержкой)", .en: "input source switching (delayed)"],
        "globe.busy.emoji":[.ru: "палитра эмодзи", .en: "the emoji picker"],
        "globe.busy.dictation":[.ru: "диктовка", .en: "dictation"],
        "globe.busy.nothing":[.ru: "ничего", .en: "nothing"],
        "globe.warn.title":[.ru: "Клавиша 🌐 перейдёт к Keyboop", .en: "The 🌐 key will go to Keyboop"],
        "globe.warn.body":[.ru: "Теперь она будет мгновенно переключать язык. Прежнее действие этой клавиши — %@ — при этом отключится. Вернуть его можно, выключив этот тумблер.",
                           .en: "It will switch the language instantly. The key's previous action — %@ — will be turned off. Turning this toggle off brings it back."],
        "globe.warn.bodyFree":[.ru: "Теперь она будет мгновенно переключать язык. Сейчас на неё ничего не назначено, так что ничего не потеряется.",
                               .en: "It will switch the language instantly. Nothing is assigned to it right now, so nothing gets lost."],
        "globe.warn.ok":  [.ru: "Забрать клавишу", .en: "Take the key"],
        "globe.freeFail": [.ru: "Не вышло изменить системную настройку. Откройте Настройки системы → Клавиатура и выберите «При нажатии 🌐 → Ничего не делать».",
                           .en: "Couldn't change the system setting. Open System Settings → Keyboard and choose “Press 🌐 key to → Do Nothing”."],
        "gen.theme":      [.ru: "Оформление", .en: "Appearance"],
        "gen.theme.system":[.ru: "Как в системе", .en: "System"],
        "gen.theme.light":[.ru: "Светлое", .en: "Light"],
        "gen.theme.dark": [.ru: "Тёмное", .en: "Dark"],
        // 🍺 Пасхалка про пиво живёт в SettingsWindow литералом: эмодзи не переводится, и ключи
        // в словаре ей ни к чему.
        "gen.themeHelp":  [.ru: "«Как в системе» означает, что Keyboop переоденется вместе с macOS, когда та переключится на светлую или тёмную тему. Светлое и тёмное закрепляют вид независимо от системы: удобно, если ночью система темнеет сама, а вам привычнее одно и то же. Всплывающие плашки (диктовка, обновление) остаются тёмными при любом выборе: они и в системе такие, как поиск Spotlight.",
                           .en: "“System” means Keyboop changes clothes together with macOS when it switches between light and dark. Light and dark pin the look regardless of the system, which helps if macOS darkens itself at night but you prefer one constant look. Floating panels (dictation, updates) stay dark whatever you pick: they are dark in the system too, like Spotlight."],
        "gen.icon":       [.ru: "Строка меню", .en: "Menu bar"],
        "gen.iconPick":   [.ru: "Значок", .en: "Icon"],
        "gen.iconLang":   [.ru: "Показывать язык рядом (RU/EN)", .en: "Show language next to it (RU/EN)"],
        "gen.icon.brand": [.ru: "Фирменный знак", .en: "Brand mark"],
        "gen.icon.flag":  [.ru: "Флаг языка", .en: "Language flag"],
        "voice.others":   [.ru: "Другие модели", .en: "Other models"],
        "voice.sizeNote": [.ru: "Чем крупнее модель, тем дольше она думает — и, скорее всего, точнее. Скорее всего.",
                          .en: "The bigger the model, the longer it thinks — and probably the more accurate it is. Probably."],

        "gen.icon.keyboard":[.ru: "Клавиатура", .en: "Keyboard"],
        "gen.icon.hidden":[.ru: "Без значка", .en: "No icon"],
        "gen.iconHint":   [.ru: "Как выглядит Keyboop рядом с часами. Индикатор языка (RU/EN) — заодно подсказка, какая раскладка активна.",
                           .en: "How Keyboop looks by the clock. The language tag (RU/EN) doubles as a hint of the active layout."],
        "gen.iconHidden": [.ru: "⚠︎ Без значка и без языка в строке меню ничего не видно. Окно настроек тогда открывается повторным запуском Keyboop из папки «Программы» — работающая копия сама покажет настройки. Переключение раскладки и голос при этом работают как обычно.",
                           .en: "⚠︎ With no icon and no language, nothing shows in the menu bar. Then open Settings by launching Keyboop again from Applications — the running copy brings up Settings. Layout switching and voice keep working as usual."],
        "gen.iconHiddenLang":[.ru: "Значок скрыт, но индикатор языка (RU/EN) остаётся в строке меню — по клику на него открывается меню Keyboop и настройки. Совсем убрать всё — выключите ещё и «Показывать язык».",
                              .en: "The icon is hidden, but the language tag (RU/EN) stays in the menu bar — click it to open Keyboop's menu and settings. To remove everything, also turn off “Show language”."],
        "gen.access":     [.ru: "Доступ", .en: "Access"],
        "gen.accessHint": [.ru: "Нужен, чтобы Keyboop видел нажатия и переключал раскладку. Без него не работает ни авто-переключение, ни голос.",
                           .en: "Needed so Keyboop sees keystrokes and switches the layout. Without it neither auto-switch nor voice works."],
        "gen.mic":        [.ru: "Доступ к микрофону…", .en: "Microphone access…"],
        "gen.micOk":      [.ru: "Микрофон: доступ есть ✓", .en: "Microphone: granted ✓"],
        "gen.micHint":    [.ru: "Нужен для голосового набора. Запрашивается сам при первом запуске; если промпт не появился или доступ отозвали — запроси здесь.",
                           .en: "Needed for voice typing. Requested automatically on first launch; if the prompt didn't show or access was revoked — request it here."],
        "about.title":    [.ru: "О программе", .en: "About"],
        // Тоже упоминаем обе фичи: раньше «О программе» обещала только раскладку (см. wel.tagline).
        "about.tagline":  [.ru: "Keyboop — бесплатно и с открытым кодом. Сделано, чтобы раскладка больше не отвлекала, а печатать можно было голосом.",
                           .en: "Keyboop — free & open source. Made so the layout never trips you up, and so you can type with your voice."],
        "about.support":  [.ru: "Поддержать проект  ₽", .en: "Support the project  ₽"],
        "about.version":  [.ru: "Версия", .en: "Version"],
        "about.license":  [.ru: "Лицензия", .en: "License"],
        "about.rescued":  [.ru: "Расколдовано кракозябр", .en: "Gibberish un-garbled"],
        "about.dictated": [.ru: "Надиктовано голосом", .en: "Dictated by voice"],
        "about.licenseVal":[.ru: "Бесплатно · open source", .en: "Free · open source"],
        "about.fbTitle":  [.ru: "Есть что сказать?", .en: "Got something to say?"],
        "about.fbBody":   [.ru: "Поймал баг, бесит мелочь или придумал фичу — напиши. Я правда читаю: Keyboop растёт на ваших отзывах, а не на фокус-группах.",
                           .en: "Caught a bug, annoyed by some detail, or dreamed up a feature — write. I actually read these: Keyboop grows on your feedback, not focus groups."],
        "about.fbBtn":    [.ru: "Написать разработчику", .en: "Email the developer"],
        "about.logHint":  [.ru: "Форма сама приложит хвост лога (галочка «диагностика») — так баг ловится быстрее. Хочешь посмотреть глазами — кнопка рядом откроет полный лог в «Консоли»: он локальный, без текста ввода, речи и перевода.",
                           .en: "The form attaches the log tail itself (the “diagnostics” checkbox) — it makes bugs far easier to catch. Want to see it with your own eyes — the button next door opens the full log in Console: it's local, with no typed text, speech or translation."],
        "about.whatsNew": [.ru: "Что нового", .en: "What’s new"],
        "about.welcome":  [.ru: "Знакомство", .en: "Welcome tour"],
        "about.updTitle": [.ru: "Узнавать о новых функциях", .en: "Hear about new features"],
        "about.updBody":  [.ru: "Keyboop сам находит новые версии и предлагает обновиться (настраивается в «Общие → Обновления»). А что нового появляется и зачем — рассказываем в телеграм-канале. Без спама.",
                           .en: "Keyboop finds new versions on its own and offers to update (configurable in General → Updates). What's new and why — we tell in the Telegram channel. No spam."],
        "about.updTg":    [.ru: "Телеграм-канал @keyboop", .en: "Telegram channel @keyboop"],
        "about.foot":     [.ru: "Из семьи boop.", .en: "From the boop family."],
        "about.credits":  [.ru: "Распознавание речи: transcribe.cpp · GigaAM v3 · Parakeet · Whisper · Qwen3-ASR (GGUF).",
                           .en: "Speech recognition: transcribe.cpp · GigaAM v3 · Parakeet · Whisper · Qwen3-ASR (GGUF)."],

        // ── Окно-приветствие (онбординг) ──
        "wel.hi":         [.ru: "Привет. Я Keyboop.", .en: "Hi. I’m Keyboop."],
        // Обе главные фичи — в ПЕРВОЙ же строке (раньше здесь была только раскладка, и голос
        // всплывал лишь ниже по онбордингу — пользователь мог его вовсе не заметить).
        "wel.tagline":    [.ru: "Печатаешь не в той раскладке — я молча расколдовываю кракозябры. А печатать лень — проговори вслух, наберу за тебя. Тихо, без слежки, всё на твоём Mac.",
                           .en: "Type in the wrong layout — I quietly un-garble the gibberish. Too lazy to type — say it out loud and I’ll type it for you. Quietly, no spying, all on your Mac."],
        "wel.menubar":    [.ru: "Живу в строке меню — вверху справа, рядом с часами. Окна не занимаю.",
                           .en: "I live in the menu bar — top right, by the clock. No window in your way."],
        "wel.permTitle":  [.ru: "Доступы", .en: "Permissions"],
        "wel.permBody":   [.ru: "Без них главное не заработает. Выдать — минута.",
                           .en: "Without these the main thing won’t work. Granting takes a minute."],
        "wel.permAxT":    [.ru: "Универсальный доступ", .en: "Accessibility"],
        "wel.permAxS":    [.ru: "Чтобы чинить раскладку и слышать хоткеи. Без него авто-переключение не работает.",
                           .en: "To fix the layout and hear hotkeys. Auto-switching won’t work without it."],
        "wel.permMicT":   [.ru: "Микрофон", .en: "Microphone"],
        "wel.permMicS":   [.ru: "Только для голосового набора. Не диктуешь — можно пропустить.",
                           .en: "Only for voice typing. Skip it if you won’t dictate."],
        "wel.allow":      [.ru: "Разрешить", .en: "Allow"],
        "wel.canTitle":   [.ru: "Что я умею", .en: "What I do"],
        "wel.can1":       [.ru: "Сам чиню раскладку: ghbdtn → привет, пока ты не заметил.", .en: "Fix the layout myself: ghbdtn → привет, before you notice."],
        "wel.can2":       [.ru: "Голос → текст: нажал хоткей, проговорил — готово. Локально, без интернета.", .en: "Voice → text: press the hotkey, speak — done. Local, no internet."],
        "wel.can3":       [.ru: "Промахнулся — переключу последнее слово вручную по хоткею.", .en: "Missed one — I’ll switch the last word by hotkey."],
        "wel.can4":       [.ru: "Автозамена: короткое сокращение разворачивается в целую фразу.", .en: "Snippets: a short trigger unfolds into a whole phrase."],
        "wel.keysTitle":  [.ru: "Горячие клавиши", .en: "Hotkeys"],
        "wel.key1v":      [.ru: "Диктовка — нажал старт, нажал ещё стоп", .en: "Dictation — press to start, press to stop"],
        "wel.key2v":      [.ru: "Переключить последнее слово / раскладку", .en: "Switch the last word / layout"],
        "wel.key1short":  [.ru: "Диктовка", .en: "Dictation"],
        "wel.key2short":  [.ru: "Переключить раскладку", .en: "Switch layout"],
        "wel.keysNote":   [.ru: "Меняй прямо тут — или потом в настройках.", .en: "Change them right here — or later in settings."],
        "wel.practiceTitle":[.ru: "Песочница", .en: "Sandbox"],
        // %@ — реальный хоткей из настроек (подставляется в WelcomeWindow), чтобы пользователь
        // запоминал СВОЮ комбинацию, а не абстрактное «нажми хоткей».
        "wel.practiceHint":[.ru: "Печатай прямо здесь. Набери ghbdtn и пробел — увидишь фокус вживую.",
                            .en: "Type right here. Enter ghbdtn and a space — watch the trick live."],
        "wel.practiceVoice":[.ru: "Голос тоже можно попробовать не выходя отсюда: поставь курсор в поле выше, нажми %@ и продиктуй пару фраз — текст появится сам.",
                            .en: "You can try your voice without leaving this window: click the field above, press %@ and dictate a couple of sentences — the text types itself."],
        "wel.practiceTr":  [.ru: "И перевод тут же: выдели введённый текст и нажми %@ — поменяю на месте.",
                            .en: "And translation too: select the text you typed and press %@ — I’ll swap it in place."],
        "wel.trTitle":     [.ru: "Перевод", .en: "Translate"],
        "wel.trBody":      [.ru: "Выдели текст в любом поле, нажми хоткей — переведётся прямо на месте. Русский ↔ английский, направление ловлю сам по тексту. Офлайн, на твоём Mac, без отправки наружу.",
                            .en: "Select text in any field, press the hotkey — it gets translated in place. Russian ↔ English, I pick the direction myself. Offline, on your Mac, nothing leaves it."],
        "wel.trKeyShort":  [.ru: "Перевести выделенное", .en: "Translate selection"],
        "wel.trPackNote":  [.ru: "Один раз нужно поставить языковой пакет — его качает сама система, кнопкой ниже. Без него переводить нечем.",
                            .en: "You’ll need the language pack once — the system downloads it, button below. Without it there’s nothing to translate with."],
        "wel.trSandbox":   [.ru: "Можно сразу попробовать в песочнице ниже: выдели введённый текст и нажми %@.",
                            .en: "Try it right in the sandbox below: select the text you typed and press %@."],
        "wel.trNeedOS":    [.ru: "Перевод работает на macOS 15 и новее. У тебя постарше — эта часть пока пропускается, остальное в силе.",
                            .en: "Translation needs macOS 15 or newer. Yours is older — this part sits out for now, the rest still works."],
        "wel.voiceTitle": [.ru: "Голос", .en: "Voice"],
        "wel.voiceBody":  [.ru: "Для диктовки нужна модель распознавания. Рекомендуем GigaAM v3 (274 МБ): одна из самых точных моделей для русского языка, работает на GPU через Metal и целиком офлайн. Для смешанной речи RU+EN в настройках также есть Parakeet v3 и Whisper Large v3 Turbo.",
                           .en: "Dictation needs a recognition model. We recommend GigaAM v3 (274 MB): fast, offline, GPU-accelerated via Metal, and tuned for Russian. For mixed Russian and English dictation, Parakeet v3 and Whisper Large v3 Turbo are also available in Settings."],
        "wel.voiceDownload":[.ru: "Скачать GigaAM v3 · ~274 МБ", .en: "Download GigaAM v3 · ~274 MB"],
        "wel.voiceReady": [.ru: "Голос готов ✓", .en: "Voice ready ✓"],
        "wel.histSafety": [.ru: "Не туда вставилось? Всё надиктованное хранится в истории — меню значка → «История». Двойной клик — скопировать.",
                           .en: "Went to the wrong place? Everything you dictated is in History — menu icon → 'History'. Double-click to copy."],
        "wel.settings":   [.ru: "Настройки", .en: "Settings"],
        "wel.go":         [.ru: "Поехали", .en: "Let’s go"],
        "wel.foot":       [.ru: "Из семьи boop. Бупаем клавиши.", .en: "From the boop family. We boop keys."],
        "priv.perm":      [.ru: "Доступ к Accessibility…", .en: "Accessibility access…"],
        "priv.lang":      [.ru: "Язык интерфейса:", .en: "Interface language:"],
        "lang.auto":      [.ru: "По умолчанию", .en: "Default"],
        "lang.ru":        [.ru: "Русский", .en: "Russian"],
        "lang.en":        [.ru: "English", .en: "English"],

        "sec.voice":      [.ru: "Голосовой набор", .en: "Voice input"],
        "voice.title":    [.ru: "Голосовой набор", .en: "Voice input"],
        "voice.sub":      [.ru: "Нажми хоткей, проговори — текст впечатается. Распознавание локальное, без интернета.",
                           .en: "Press the hotkey, speak — the text is typed in. Recognition is local, offline."],
        "voice.on":       [.ru: "Голосовой ввод", .en: "Voice input"],
        "voice.hotkey":   [.ru: "Хоткей диктовки", .en: "Dictation hotkey"],
        "voice.hkTest":   [.ru: "Проверить", .en: "Test"],
        "voice.hkTestPrompt": [.ru: "Нажми свой хоткей диктовки…", .en: "Press your dictation hotkey…"],
        "voice.hkTestOk": [.ru: "✓ Хоткей работает", .en: "✓ Hotkey works"],
        "voice.hkTestFail": [.ru: "✗ Не совпадает", .en: "✗ Mismatch"],
        "voice.hkTestDisabled": [.ru: "Голосовой ввод отключён — включи его выше", .en: "Voice input is off — enable it above"],
        "voice.hkTestCancel": [.ru: "Закрыть", .en: "Close"],
        "voice.mode":     [.ru: "Режим", .en: "Mode"],
        // ⚠️ ВТОРОЙ ЗАХОД НА ЭТУ СТРОКУ (автор, 02.08.2026). 29.07 он сказал, что «Переключать»
        // непонятно, и тогда мы добавили подпись, объясняющую только его. Не помогло: непонятной
        // остаётся сама пара, потому что «переключать» описывает НЕ ЖЕСТ, а внутреннее устройство
        // («переключить режим записи»). Человек читает кнопку и не понимает, что ему делать пальцем.
        //
        // Теперь обе кнопки названы одинаковой формой и обе про жест: удерживать против нажимать.
        // Разница у них ровно одна — чем запись КОНЧАЕТСЯ: отпусканием клавиши или вторым нажатием.
        //
        // ⚠️ ПОДПИСЬ ОБЪЯСНЯЕТ ТОЛЬКО ВТОРОЙ ВАРИАНТ, и это осознанно. Я сначала написал сюда оба
        // («Удерживать — пока держите клавишу. Нажимать — от нажатия до нажатия»), посмотрел рендер
        // и увидел, что строка обрезается ровно на «Нажимать — от нажа…», то есть отрезается именно
        // то, ради чего подпись существует. Строки настроек у нас не переносятся, поэтому в них
        // помещается одна мысль. «Удерживать» понятно из самого слова, объяснять надо второй.
        // Полное сравнение обоих — под кнопкой «i» (voice.modeHelp).
        "voice.modeSub":  [.ru: "Нажимать — нажали, сказали, нажали ещё раз",
                           .en: "Press — press, speak, press again"],
        "voice.modeHold": [.ru: "Удерживать", .en: "Hold"],
        "voice.modeToggle":[.ru: "Нажимать", .en: "Press"],
        "voice.modeHelp": [.ru: "Удерживать: зажали клавишу диктовки, говорите, отпустили — речь распознаётся и текст встаёт в поле. Хорошо для коротких фраз: палец всё время помнит, что запись идёт, и забыть её выключить невозможно.\n\nНажимать: нажали один раз, говорите сколько нужно, нажали второй раз — и появится текст. Хорошо для длинных мыслей и когда руки нужны свободными; следите только за индикатором, запись ждёт второго нажатия сколько угодно.\n\nРазница между ними ровно одна: чем заканчивается запись — отпусканием клавиши или вторым нажатием. Клавиша в обоих случаях та же, что выбрана выше.",
                           .en: "Hold: press and hold the dictation key, speak, let go — your speech is recognised and the text lands in the field. Good for short phrases: your finger keeps reminding you that recording is on, so you cannot forget to stop it.\n\nPress: press once, speak for as long as you need, press again — and the text appears. Good for longer thoughts and when your hands are busy; just watch the indicator, because recording waits for that second press as long as it takes.\n\nThe only difference is what ends the recording: releasing the key, or a second press. The key itself is the same one you picked above."],
        // ГДЕ ПОКАЗЫВАТЬ ПЛАШКУ (задача 125). Кнопки названы местом, а не механикой: «У курсора» и
        // «Вверху» человек проверяет глазами за секунду, а «под чёлкой» верно не на каждой машине.
        // Про чёлку и про внешний монитор сказано в подписи и под «i», где это не мешает выбирать.
        "voice.hudPlace":  [.ru: "Плашка диктовки", .en: "Dictation badge"],
        "voice.hudCaret":  [.ru: "У курсора", .en: "At the cursor"],
        "voice.hudTop":    [.ru: "Вверху", .en: "At the top"],
        "voice.hudIsland": [.ru: "В вырезе", .en: "In the notch"],
        // Вырез в панели есть, но macOS сейчас закрыла его режимом совместимости с корпусом
        // камеры: строка меню становится сплошной полосой, и класть туда нечего. Снаружи это
        // выглядит как «настройка не работает», поэтому причину называем словами.
        // ⚠️ КОРОТКО, В ОДНУ СТРОКУ. Подпись под настройкой не переносится (обрезается многоточием
        // и уходит в toolTip), и первая версия этой фразы обрывалась на «с кам…». Подробности,
        // включая способ вернуть вырез, живут в help рядом.
        // КОРНЕВОЙ ЭКРАН ПРОСТОГО РЕЖИМА (15.08.2026). Подписи здесь свои, а не те же, что в Pro:
        // в разделе строка объясняет настройку соседям по разделу, а на корневом экране она обязана
        // объяснить сам двигатель человеку, который видит приложение впервые.
        // ⚠️ СВОИ, КОРОТКИЕ ЗАГОЛОВКИ. Первый живой снимок показал «Автоматическое исправление
        // расклад…» и «Ручное пе…»: заголовки Pro писались под колонку в 600 пунктов, а корневой
        // экран вдвое уже. Резать их многоточием нельзя, это главные строки приложения.
        // ⚠️ ОДНО СЛОВО, И ЭТО НЕ ЛЕНЬ. В строке с хоткеем управляющий элемент широкий (пикер сочетания,
        // а у диктовки рядом ещё и «Проверить»), заголовку остаётся мало. «Исправить вру…» и «Нач…» на
        // первом снимке резались оба. Под заголовком карточки «Исправление раскладки» строка
        // «Сочетание» однозначна и без глагола.
        "root.manual":   [.ru: "Исправить раскладку", .en: "Fix the layout"],
        "root.voiceKey": [.ru: "Начать диктовку", .en: "Start dictation"],
        "root.tr":       [.ru: "Перевести выделенное", .en: "Translate the selection"],
        // ⚠️ НАЗВАНИЯ РЕЖИМОВ ОПИСЫВАЮТ ОКНО, А НЕ ЧЕЛОВЕКА. «Простой» и «Продвинутый» сообщают
        // человеку, кто он такой, и первый вариант звучит снисходительно. «Кратко» и «Подробно»
        // говорят про то, сколько всего показано, и это правда, а не оценка. автор просил подобрать
        // варианты, этот стоит первым.
        // Ссылка называет, КУДА уйдём. «Кнопка, показывающая текущий режим» заставляет думать,
        // а ссылка с названием места читается за раз.
        // Подпись у тумблера режима. Ровно то, что включает тумблер, и ровно то, что влезает рядом
        // с ним в колонку сайдбара (замер 16.08: 81 пункт из 122 доступных).
        "mode.simple":   [.ru: "Основное",  .en: "Basics"],
        "mode.pro":      [.ru: "Всё",       .en: "Everything"],
        "root.back":     [.ru: "‹ Основное", .en: "‹ Essentials"],
        // ⚠️ САМАЯ ВАЖНАЯ ПОДПИСЬ НА ЭКРАНЕ. Человек, который не знает про ручное переключение,
        // считает, что приложение просто не работает, и удаляет его (случай знакомой автора, 15.08).
        "root.manualSub":[.ru: "Если не починили сами или ошиблись: нажмите, и последнее слово переключится. Тем же сочетанием вернуть обратно",
                          .en: "If we missed it or got it wrong: press this and the last word switches. The same combo puts it back"],
        "root.voiceKeySub":[.ru: "Нажмите и говорите, нажмите ещё раз, чтобы закончить",
                          .en: "Press and talk, press again to finish"],
        // ⚠️ Подпись обязана совпадать с РЕЖИМОМ, а по умолчанию он «удерживать». Пока строка была
        // одна, она обещала второе нажатие всем подряд, в том числе тем, у кого запись кончается
        // отпусканием клавиши.
        "root.voiceKeySubHold":[.ru: "Зажмите и говорите, отпустите, чтобы закончить",
                          .en: "Hold and talk, release to finish"],
        "root.voiceKeyHelp":[.ru: "Нажмите выбранную клавишу и говорите. Речь распознаётся прямо на этом маке: звук никуда не отправляется, интернет не нужен. Готовый текст печатается туда, где стоит курсор, в любой программе, даже там, где системной диктовки нет.\n\nЗапись заканчивается отпусканием клавиши или вторым нажатием — это выбирается в подробных настройках, в разделе «Голосовой набор». Там же живут язык, модель распознавания и то, что делать с текстом после: убирать ли точку в конце, нажимать ли Enter, добавлять ли пробел.\n\nПока идёт запись, у курсора висит плашка «Слушаю»: по ней видно, что микрофон открыт. Escape обрывает запись, и ничего не вставляется.\n\nПервая диктовка после запуска чуть медленнее остальных: модель загружается в память. Дальше текст появляется почти сразу.",
                          .en: "Press the key you picked and talk. Speech is recognised on this Mac: the audio goes nowhere and no internet is needed. The finished text is typed wherever the caret is, in any app, including the ones the system dictation ignores.\n\nRecording ends either when you release the key or on a second press — that is a choice in the full settings, under «Voice input». The language, the recognition model and what happens to the text afterwards (strip the final period, press Enter, add a space) live there too.\n\nWhile it records, a «Listening» plaque sits by the caret so you can see the microphone is open. Escape aborts the recording and inserts nothing.\n\nThe first dictation after launch is a little slower: the model is loading into memory. After that the text shows up almost at once."],
        "root.trHelp":   [.ru: "Выделите текст в поле ввода и нажмите сочетание: перевод встанет ровно на место оригинала. Направление определяется само по тексту, русский становится английским и наоборот.\n\nПереводит сама macOS своим встроенным движком, поэтому текст не уходит в интернет и всё работает без сети. Нужен языковой пакет «русский ↔ английский»: если он не скачан, поставьте его в подробных настройках, в разделе «Перевод». Система разок спросит подтверждение.\n\nРаботает там, где можно печатать. Текст «только для чтения» на веб-странице заменить нечем, поэтому там сочетание промолчит. Нужна macOS 15 или новее.",
                          .en: "Select text in an editable field and press the shortcut: the translation lands exactly where the original was. The direction is picked from the text itself, Russian becomes English and the other way round.\n\nmacOS translates it with its own built-in engine, so nothing leaves the machine and it works offline. The «Russian ↔ English» language pack is required: if it is not there yet, install it in the full settings, under «Translate». The system will ask for confirmation once.\n\nIt works wherever you can type. Read-only text on a web page has nothing to replace, so there the shortcut stays silent. Requires macOS 15 or newer."],
        "root.trSub":    [.ru: "Выделите текст и нажмите сочетание: перевод встанет на место оригинала",
                          .en: "Select some text and press the combo: the translation replaces the original"],
        // Порядок подстановок: расколдовано, надиктовано.
        "root.counters": [.ru: "Расколдовано %@ · надиктовано %@", .en: "Unjinxed %@ · dictated %@"],
        "voice.hudNotchCompat":[.ru: "macOS сейчас закрыла вырез, плашка будет у курсора",
                            .en: "macOS is hiding the notch right now, so the plaque stays at the cursor"],
        "voice.hudNoNotch":[.ru: "«В вырезе» доступно на MacBook с чёлкой — на этом экране её нет",
                            .en: "“In the notch” needs a MacBook with a notch — this screen has none"],
        // ⚠️ ПОДПИСЬ КОРОТКАЯ НАМЕРЕННО. Первый вариант договаривал и про внешний монитор, и на
        // рендере обрезался ровно на этой оговорке — то есть строка теряла именно то, ради чего
        // была длинной. Строки настроек у нас не переносятся, в них помещается одна мысль;
        // оговорка живёт под «i», где ей и место.
        "voice.hudPlaceSub":[.ru: "В вырезе — плашка вырастает прямо из чёлки MacBook",
                             .en: "In the notch — the badge grows straight out of the MacBook notch"],
        "voice.hudPlaceHelp":[.ru: "У курсора: плашка появляется там, куда пойдёт текст, и её видно, не отрывая глаз от места ввода. Так было всегда.\n\nВверху: плашка встаёт по центру верхней кромки, сразу под чёлкой MacBook. Удобно, если она мешает читать написанное или прыгает вслед за кареткой.\n\nУ внешнего монитора выреза нет, и плашка под несуществующей чёлкой выглядит чужеродно, поэтому на нём она сама возвращается к курсору. На встроенном экране без чёлки (MacBook Air 2020, машины на Intel) верхний режим работает как обычно.\n\nЕсли вырез вдруг пропал и сверху появилась ровная полоса, это режим совместимости macOS с корпусом камеры. Система включает его сама, когда приложение, собранное до macOS 12 или с галочкой «Подогнать под встроенную камеру» в «Свойствах», положит окно за камерой на этом рабочем столе. Возвращается вырез выходом из системы или на новом рабочем столе.",
                             .en: "At the cursor: the badge appears where the text will go, so you can see it without looking away from what you are typing. This is how it has always worked.\n\nAt the top: the badge sits centred at the top edge, right under the MacBook notch. Handy if it covers what you have written or keeps jumping after the caret.\n\nAn external display has no notch, and a badge under a notch that isn’t there looks out of place, so on one it falls back to the cursor. On a built-in screen without a notch (MacBook Air 2020, Intel machines) the top mode works as usual."],
        // СЛОВАРЬ ДИКТОВКИ (задачи 13/126).
        "voice.grpDict":   [.ru: "СЛОВАРЬ", .en: "DICTIONARY"],
        "voice.dictSub":   [.ru: "Слова, которые распознавание слышит по-своему",
                            .en: "Words the recogniser keeps hearing its own way"],
        "voice.dictPhHeard":  [.ru: "напр. кейбуп", .en: "e.g. keyboop"],
        "voice.dictPhWritten":[.ru: "напр. Keyboop", .en: "e.g. Keyboop"],
        "voice.dictHint":  [.ru: "Замена ищется с начала слова, поэтому «вайп» → «вайб» чинит и «вайпкодинг». Регистр и «ё» при поиске не важны; если справа написано с заглавной, она сохраняется.",
                            .en: "A match is looked for at the start of a word, so “vibe” fixes “vibecoding” too. Case and “ё” don’t matter when matching; a capital on the right-hand side is kept as you wrote it."],
        "voice.noEmDash":   [.ru: "Без длинных тире", .en: "No em dashes"],
        "voice.noEmDashSub":[.ru: "Заменять «—» на обычный дефис", .en: "Replace “—” with a plain hyphen"],
        "voice.noEmDashHelp":[.ru: "Распознавание щедро расставляет длинное тире там, где вы сами набрали бы дефис: на клавиатуре этого знака попросту нет. В переписке он вдобавок выдаёт текст, набранный не руками.\n\nМы не выбрасываем знак, а заменяем на дефис: он держит ту же паузу, и без него фраза слипается. Меняются оба длинных знака, «—» и «–»: на слух они не различаются, а модель ставит то один, то другой.",
                             .en: "Recognition is generous with em dashes where you would have typed a plain hyphen — the key simply isn’t on the keyboard. In chats it also makes text look machine-written.\n\nWe replace rather than drop it: the hyphen holds the same pause, and without it the sentence runs together. Both long dashes are replaced, “—” and “–”: they sound identical and the model uses them interchangeably."],
        "voice.needModelTitle":[.ru: "Нужна модель распознавания", .en: "A recognition model is needed"],
        "voice.needModelBody": [.ru: "Чтобы я понимал речь, скачай модель — один раз, дальше всё локально, без интернета. Открыть настройки?",
                                .en: "To understand speech I need a model — once, then it’s all local, no internet. Open settings?"],
        "voice.needModelOpen": [.ru: "Открыть настройки", .en: "Open settings"],
        "voice.needModelLater":[.ru: "Не сейчас", .en: "Not now"],
        "voice.escCancel":[.ru: "Escape отменяет диктовку", .en: "Escape cancels dictation"],
        "voice.escCancelSub": [.ru: "Запись обрывается, ничего не вставляется",
                          .en: "Recording is dropped and nothing is inserted"],
        "voice.escSave":  [.ru: "Отменённую всё равно сохранять", .en: "Keep cancelled dictations"],
        "voice.escSaveSub":[.ru: "В поле не вставим, но в историю положим",
                            .en: "Nothing is inserted, but it lands in the history"],
        "voice.escSaveHelp":[.ru: "Escape отменяет вставку, но речь к этому моменту уже записана. С этой настройкой она всё равно распознаётся и попадает в историю диктовок, откуда её можно скопировать. Пригодится, если Escape нажимается случайно или если вы передумали в последний момент, а сказанное жалко. Выключено по умолчанию: Escape означает «не надо», и сохранять вопреки этому мы не станем без вашего согласия. История и её срок хранения настраиваются ниже.",
                             .en: "Escape cancels the insertion, but by then your speech is already recorded. With this on it is still recognised and lands in the dictation history, where you can copy it from. Useful if Escape gets pressed by accident, or if you changed your mind at the last moment and the words were worth keeping. Off by default: Escape means “no”, and we will not save against that without your say-so. The history and how long it is kept are configured below."],
        "voice.escSaved": [.ru: "Отменено, но сохранено в историю", .en: "Cancelled, but saved to history"],
        "voice.warm":     [.ru: "Мгновенный старт (тёплый микрофон)", .en: "Instant start (warm mic)"],
        // Было «Мгновенный повтор. Оранжевая точка записи горит, пока окно тёплое» — жаргон
        // («окно тёплое») и главное не сказано: микрофон ОСТАЁТСЯ ВКЛЮЧЁННЫМ какое-то время после
        // диктовки. Замечание автора 29.07. Про оранжевую точку — в подсказку «i» (шаг 6), она важна
        // как сигнал приватности, но в одну строку вместе с сутью не помещается.
        "voice.warmSub":  [.ru: "Микрофон остаётся включённым после диктовки, чтобы следующая началась сразу",
                           .en: "The mic stays on after you finish, so the next dictation starts instantly"],
        "voice.warmDur":  [.ru: "Окно прогрева", .en: "Warm window"],
        // Регистр не задаём: sectionTitle сам поднимает через eyebrowLabel(t.uppercased()).
        "voice.grpMic":       [.ru: "Микрофон", .en: "Microphone"],
        "voice.grpDictation": [.ru: "Диктовка", .en: "Dictation"],
        "voice.grpHistory":   [.ru: "История", .en: "History"],
        "voice.outputGroup": [.ru: "Как вставлять текст", .en: "How the text is inserted"],
        "voice.outputOpen":  [.ru: "Настроить", .en: "Configure"],
        "voice.othersN":     [.ru: "Показать все модели (%d)", .en: "Show all models (%d)"],
        "voice.outputHelp":  [.ru: "Эти правила применяются к УЖЕ распознанному тексту, поэтому работают одинаково на любой модели: сменив GigaAM на Whisper или Parakeet, вы получите тот же результат.",
                              .en: "These rules apply to the FINISHED text, so they behave the same on every model regardless of whether you pick GigaAM, Parakeet, or Whisper."],
        // Сводка в строке: человек видит текущее состояние, не раскрывая группу.
        "voice.sumDefault":  [.ru: "Как распознала модель", .en: "As the model produced it"],
        "voice.sumNoCap":    [.ru: "без заглавной", .en: "no capital"],
        "voice.sumNoDot":    [.ru: "без точки", .en: "no period"],
        "voice.sumEnter":    [.ru: "с отправкой", .en: "auto-send"],
        "voice.sumNoSpace":  [.ru: "без пробела", .en: "no space"],
        // Подсказки «i». Пишем ТО, ЧЕГО НЕТ в подписи: подпись это тизер, подсказка это ответ.
        "voice.soundHelp":   [.ru: "Два коротких сигнала: один в начале записи, другой в конце. Нужны, чтобы не гадать, слушает вас Keyboop или уже нет, особенно когда индикатор скрыт. Громкость настраивается строкой ниже, а ноль на ползунке выключает сигнал совсем.",
                              .en: "Two short cues: one when recording starts, one when it stops. They exist so you never have to guess whether Keyboop is still listening, especially with the indicator hidden. Volume is the row below, and zero turns the cue off entirely."],
        "voice.warmHelp":    [.ru: "После диктовки микрофон не выключается сразу, а ждёт заданное время. Следующая диктовка в этом окне начинается мгновенно, без паузы на запуск устройства. Пока микрофон включён, macOS показывает оранжевую точку в строке меню — это системный индикатор, а не наш: он горит у любого приложения с открытым микрофоном.",
                              .en: "After you finish, the mic stays on for the time you set instead of shutting down. The next dictation within that window starts instantly, with no device warm-up. While the mic is on, macOS shows an orange dot in the menu bar. That indicator is the system's, not ours: it appears for any app holding the microphone open."],
        "voice.escHelp":     [.ru: "Escape во время записи обрывает её, и ничего не вставляется — сказанное просто пропадает. Выключите, если Escape нужен самой программе, в которой вы диктуете: тогда он уйдёт туда, а диктовку останавливайте тем же сочетанием, которым начали.",
                              .en: "Escape during recording drops it and inserts nothing — what you said is discarded. Turn it off if the app you dictate into needs Escape itself: it will pass through, and you stop dictation with the same shortcut you started it with."],
        "voice.streamHelp":  [.ru: "Распознанное показывается прямо на плашке «Слушаю» (или в вырезе Notch Island), пока вы говорите, а в документ вставляется один раз, в конце. Для потоковых моделей transcribe.cpp (Nemotron Streaming, Voxtral Realtime) используется нативный поток; для остальных моделей текст обновляется по естественным паузам и быстрому превью, которое мгновенно прерывается при отпускании клавиши.",
                              .en: "Recognized text appears live on the “Listening” pill (or Notch Island) as you speak, and gets inserted into your document once at the end. Models with native transcribe.cpp streaming (Nemotron Streaming, Voxtral Realtime) run in continuous streaming mode; other models update live via pause chunks and fast preview, which aborts immediately when you release the key."],

        "voice.outputGroupNote": [.ru: "Эти правила применяются к уже распознанному тексту, поэтому работают одинаково на любой модели.",
                                  .en: "These rules apply to the finished text, so they work the same on every model."],
        "voice.noCapital":[.ru: "Не начинать с заглавной", .en: "No leading capital"],
        "voice.noCapitalSub": [.ru: "Каждое предложение — со строчной; имена вроде «Иван» и «Мария» и аббревиатуры сохраняют заглавную",
                               .en: "Every sentence starts lowercase; common Russian names and acronyms keep their capitals"],
        "voice.noCapitalHelp": [.ru: "Заглавная снимается у первой буквы каждого предложения: в самом начале, после точки, вопросительного и восклицательного знака. Частые русские имена, их обычные краткие и падежные формы остаются с заглавной. В неоднозначных случаях имя важнее нарицательного: «Роман», «Вера» и «Лев» считаются именами. Редкое неизвестное имя не угадываем, но если слово уже встретилось с заглавной внутри предложения, такое же написание дальше сохраняется. Аббревиатуры и слова с заданным регистром из словаря диктовки тоже не трогаем. Сокращения с точкой («г.», «ул.», «т. д.») концом предложения не считаются, поэтому «г. Москва» остаётся Москвой.",
                                .en: "The first letter of every sentence is lowercased: at the beginning and after full stops, question marks, and exclamation marks. Common Russian given names and their usual short and inflected forms keep their capitals. When a word is ambiguous, the name wins: «Роман», «Вера», and «Лев» are treated as names. An unknown rare name is not guessed, but an identical spelling already seen capitalized inside the sentence is preserved later. Acronyms and words whose case is set by the dictation dictionary are also left alone. Abbreviations ending in a period («Mr.», «Dr.», «e.g.») do not start a new sentence."],
        "voice.noPeriod": [.ru: "Не ставить точку в конце", .en: "No trailing period"],
        "voice.noPeriodSub": [.ru: "Для мессенджеров и полей поиска, где точка в конце лишняя. Вопрос, восклицание и многоточие остаются",
                              .en: "For chats and search fields where a final period is noise. Question marks, exclamations and ellipses stay"],
        "voice.noPeriodHelp": [.ru: "Снимается ТОЛЬКО одиночная точка в самом конце вставляемого текста. Точки внутри предложений остаются на месте, а многоточие, вопросительный и восклицательный знаки не трогаются вовсе: они несут смысл, а многоточие вдобавок часто ставит сама модель на оборванной фразе. Если после снятия точки на конце остались пробелы, они тоже убираются.",
                               .en: "Only a single period at the very end of the inserted text is removed. Periods inside the text stay where they are, and ellipses, question marks and exclamation marks are never touched: they carry meaning, and an ellipsis is often the model's own mark for an unfinished phrase. Any spaces left at the end after the period is dropped are removed too."],
        "voice.autoEnter": [.ru: "Отправлять сразу", .en: "Send right away"],
        "voice.autoEnterKey": [.ru: "Чем отправлять", .en: "Send with"],
        "voice.autoEnterSub": [.ru: "После вставки нажимается Enter. Для чатов; в текстовом редакторе это будет перенос строки, а не отправка",
                               .en: "Enter is pressed after the insert. Meant for chats; in a text editor it will be a line break, not a send"],
        "voice.autoEnterHelp": [.ru: "Сразу после вставки текста нажимается Enter, как если бы вы нажали его сами. Смысл зависит от того, где вы диктуете: в мессенджере это отправка сообщения, а в текстовом редакторе просто перенос строки. Чем именно нажимать, выбирается ниже: Enter или ⌘Enter, потому что в части чатов отправка висит на втором сочетании. Учтите, что отменить отправку уже нельзя, поэтому в незнакомом месте лучше проверить на безобидной фразе.",
                                .en: "Enter is pressed right after the text is inserted, exactly as if you pressed it yourself. What that means depends on where you dictate: in a chat it sends the message, in a text editor it is just a line break. Which key to press is chosen below, Enter or ⌘Enter, because some chats put sending on the second one. Keep in mind that a sent message cannot be taken back, so try it on something harmless first."],
        "voice.trailSpace": [.ru: "Пробел после вставки", .en: "Space after the insert"],
        "voice.trailSpaceSub": [.ru: "Чтобы следующая фраза не слиплась с этой. В поле поиска бывает лишним",
                                .en: "So the next phrase does not stick to this one. In a search field it can be excess"],
        "voice.trailSpaceHelp": [.ru: "После вставленного текста добавляется один пробел, чтобы следующая продиктованная фраза не слиплась с предыдущей. В полях поиска и в коротких формах он чаще мешает: пробел на конце запроса иногда меняет результат, а иногда просто выглядит небрежно. Поэтому настройка отдельная, а не вшита намертво.",
                                 .en: "A single space is added after the inserted text so that the next dictated phrase does not stick to the previous one. In search fields and short forms it is usually a nuisance: a trailing space sometimes changes the result and always looks careless. That is why this is a separate setting rather than fixed behaviour."],
        "voice.sound":    [.ru: "Звук записи", .en: "Recording sound"],
        "voice.soundSub": [.ru: "Короткий сигнал в начале и в конце записи",
                          .en: "A short cue when recording starts and stops"],
        // ⚠️ У нас ЧЕТЫРЕ разные громкости в соседних разделах: звук старта диктовки, звук
        // переключения, приглушение музыки и уровень входа микрофона. Голое «Громкость звука» не
        // отвечало, какая из них (автор, 09.08). Каждое название теперь называет источник.
        "voice.soundVol": [.ru: "Громкость звука начала диктовки", .en: "Volume of the dictation start sound"],
        "voice.streaming":   [.ru: "Живой показ речи на плашке",
                              .en: "Live speech preview on HUD"],
        "voice.streamingSub": [.ru: "Показывает текст на плашке или в вырезе, пока вы говорите",
                              .en: "Shows live text on the pill or Notch Island while you speak"],
        "voice.ctxProfiles": [.ru: "Контекстные профили по приложениям",
                              .en: "Context profiles per app"],
        "voice.ctxProfilesSub": [.ru: "Автоматически подстраивает стиль, точку в конце и промпт под активное окно",
                                 .en: "Automatically adapts style, final period, and AI prompt to the active app"],
        "voice.ctxProfilesHelp": [.ru: "При начале диктовки Keyboop определяет активную программу (например, Telegram, Mail, Xcode или Terminal) и применяет её стиль: в мессенджерах убирает лишнюю точку в конце, в редакторах кода и терминалах сохраняет дефисы и английские термины, а в письмах включает полную пунктуацию. Если включена AI-постобработка, профиль также дополняет системный промпт.",
                                  .en: "When dictation starts, Keyboop detects the frontmost app (e.g. Telegram, Mail, Xcode, or Terminal) and applies its profile: messengers strip noisy trailing periods, code editors and terminals preserve hyphens and English identifiers, and mail/docs keep full punctuation. When AI post-processing runs, the profile also tailors the prompt."],
        "voice.ctx.manage":  [.ru: "Настроить профили…", .en: "Configure profiles…"],
        "voice.ctx.rulesTitle": [.ru: "Правила для приложений", .en: "Application rules"],
        "voice.ctx.summaryFmt": [.ru: "Активных правил: %d · своих: %d", .en: "Active rules: %d · custom: %d"],
        "voice.ctx.windowTitle": [.ru: "Контекстные профили диктовки", .en: "Contextual Dictation Profiles"],
        "voice.ctx.windowNote": [.ru: "Стиль выбирается автоматически по активному приложению на старте записи. Вы можете изменить режим для любого встроенного приложения или добавить свои программы.",
                                 .en: "The profile is selected automatically from the active application when recording starts. You can customize any built-in rule or add your own apps."],
        "voice.ctx.addApp": [.ru: "+ Добавить приложение…", .en: "+ Add app…"],
        "voice.ctx.reset":  [.ru: "Сбросить свои", .en: "Reset custom"],
        "voice.ctx.cat.general": [.ru: "По умолчанию", .en: "Default"],
        "voice.ctx.cat.chat": [.ru: "Мессенджер / чат", .en: "Messenger / Chat"],
        "voice.ctx.cat.emailDocs": [.ru: "Почта и документы", .en: "Mail & Docs"],
        "voice.ctx.cat.codeTerminal": [.ru: "Код и терминал", .en: "Code & Terminal"],
        "voice.ctx.cat.custom": [.ru: "Свой стиль", .en: "Custom Style"],
        "voice.ctx.periodAuto": [.ru: "Точка: авто", .en: "Period: auto"],
        "voice.ctx.periodStrip": [.ru: "Без точки", .en: "Strip period"],
        "voice.ctx.periodKeep": [.ru: "С точкой", .en: "Keep period"],
        "voice.ctx.promptBtn": [.ru: "Промпт…", .en: "Prompt…"],
        "voice.ctx.promptBtnSet": [.ru: "Промпт ●", .en: "Prompt ●"],
        "voice.ctx.promptDlgTitle": [.ru: "Промпт для «%@»", .en: "Custom prompt for “%@”"],
        "voice.ctx.promptDlgSub": [.ru: "Необязательный индивидуальный промпт AI-постобработки для этого приложения. Оставьте пустым, чтобы использовать промпт категории.",
                                   .en: "Optional AI post-processing prompt for this app. Leave empty to use the category instruction."],
        "voice.ctx.promptClear": [.ru: "Очистить", .en: "Clear"],
        "voice.ctx.noNewRunning": [.ru: "Все запущенные приложения уже в списке", .en: "All running apps are already listed"],
        "voice.ctx.chooseBundle": [.ru: "Выбрать .app на диске…", .en: "Choose .app bundle…"],
        // Условие, о котором тумблер раньше молчал: на whisper он включался и не делал НИЧЕГО.
        "voice.streamNeedsPk":[.ru: "Нужен движок Parakeet — выберите его в списке моделей выше",
                               .en: "Needs the Parakeet engine — pick it in the model list above"],
        // ⚠️ ЦИФРА ЗАМЕРЕНА, А НЕ ВЗЯТА ИЗ ОПИСАНИЯ МОДЕЛИ (13.08.2026). Было «~120 МБ»: столько
        // весит сама модель по карточке, а в каталог приезжает 429 МБ, потому что рядом с .mlmodelc
        // качается и .mlpackage. Обещать человеку втрое меньший объём и потом занять диск нельзя.
        "voice.streamDlTitle":[.ru: "Скачать модель потокового набора?",
                               .en: "Download the streaming dictation model?"],
        "voice.streamDlSub": [.ru: "Это отдельная модель (около 430 МБ), едет один раз. Без неё потоковый набор не заведётся, а пока качается, диктовка работает по-старому.",
                              .en: "A separate model (about 430 MB), downloaded once. Streaming will not run without it, and meanwhile dictation works the old way."],
        "voice.streamDlGo":  [.ru: "Скачать", .en: "Download"],
        "voice.streamDlOk":  [.ru: "Готово — потоковый набор включён. Нажми хоткей диктовки и говори.",
                              .en: "Done — streaming dictation is on. Press the dictation hotkey and talk."],
        "voice.streamDlFail":[.ru: "Не вышло скачать модель. Проверь сеть и попробуй ещё раз.",
                              .en: "Couldn't download the model. Check your connection and try again."],
        // ⚠️ Было «Хранить историю» — ДОСЛОВНО как voice.history строкой ниже по разделу, и обе
        // строки стояли в одной карточке. Два разных контрола с одинаковым заголовком: тумблер
        // «хранить или нет» и выпадающий «сколько хранить». Найдено дизайн-разбором 28.07.
        "voice.retention":[.ru: "Срок хранения", .en: "Keep for"],
        "voice.ret3":     [.ru: "3 дня", .en: "3 days"],
        "voice.ret7":     [.ru: "7 дней", .en: "7 days"],
        "voice.ret30":    [.ru: "30 дней", .en: "30 days"],
        "voice.retForever":[.ru: "Без удаления", .en: "Forever"],
        "sound.keyboop":  [.ru: "Keyboop", .en: "Keyboop"],
        "voice.log":      [.ru: "Системный лог", .en: "System log"],
        "voice.logHint":  [.ru: "Если диктовка вдруг не сработала — открой лог (локальный, без текста распознавания) и пришли его на hi@keyboop.com.",
                           .en: "If dictation ever misfires — open the log (local, without recognized text) and send it to hi@keyboop.com."],
        "voice.securePwd": [.ru: "Сюда печатать не буду. Текст сохранён в истории.",
                            .en: "Password field — won't type here. Your text is saved to history."],
        "voice.deadBundle": [.ru: "Файлы Keyboop изменились на диске — перезапусти приложение, и микрофон вернётся.",
                             .en: "Keyboop's files changed on disk — relaunch the app to get the mic back."],
        "voice.deadMic":  [.ru: "Микрофон отдаёт тишину. Загляни в Настройки → Звук → Вход.",
                           .en: "The microphone yields silence. Check System Settings → Sound → Input."],
        "voice.stuck":    [.ru: "Распознавание застряло — бросил. Попробуй ещё раз.",
                           .en: "Recognition got stuck — dropped it. Try again."],
        "voice.intelNote": [.ru: "Intel-Mac: распознавание идёт на процессоре (без Metal GPU) — медленнее, чем на Apple Silicon. Для быстрого отклика выбирай компактные модели вроде GigaAM v3, Parakeet или Whisper Small.",
                            .en: "Intel Mac: recognition runs on the CPU (no Metal GPU) — slower than Apple Silicon. For snappy response pick compact models like GigaAM v3, Parakeet, or Whisper Small."],
        "voice.dlStalledShort": [.ru: "застряло…", .en: "stalled…"],
        "voice.dlStalledTip":   [.ru: "Скачивание замерло на %d%% — сеть до Hugging Face бывает капризной. Перезапусти Keyboop и нажми «Скачать» ещё раз: продолжит с того же места.",
                                 .en: "The download froze at %d%% — the connection to Hugging Face can be moody. Relaunch Keyboop and hit Download again: it resumes where it left off."],
        "voice.lang":     [.ru: "Язык распознавания", .en: "Recognition language"],
        "voice.langAuto": [.ru: "Авто (по речи)", .en: "Auto (detect)"],
        "voice.langSub":  [.ru: "Выберите язык, если диктуете на одном",
                           .en: "Pick a language if you dictate in just one"],
        "voice.langHelp": [.ru: "«Авто» определяет язык по самой речи — удобно при переключении между русским и английским. Выбор конкретного языка полезен для мультиязычных моделей (Whisper, Qwen3-ASR): они реже сбиваются на смешанной речи.\n\nМодели только для русского языка (например, GigaAM v3) всегда распознают русскую речь независимо от этой настройки.",
                           .en: "“Auto” detects the language from speech. Choosing a specific language helps multilingual models (Whisper, Qwen3-ASR) stay consistent when dictating in a single language.\n\nRussian-only models (such as GigaAM v3) always transcribe in Russian regardless of this setting."],
        "voice.model":    [.ru: "Модель распознавания", .en: "Recognition model"],
        "voice.installed":[.ru: "установлена", .en: "installed"],
        "voice.download": [.ru: "Скачать", .en: "Download"],
        "voice.use":      [.ru: "Использовать", .en: "Use"],
        "voice.active":   [.ru: "используется", .en: "in use"],
        "voice.modelsTitle":[.ru: "Модель распознавания", .en: "Recognition model"],
        "voice.modelsNote":[.ru: "Каталог ограничен моделями с поддержкой русского языка. GigaAM v3 — лучший выбор для чисто русской речи и скорости; Parakeet v3 и Whisper Large v3 Turbo хороши для смешанной RU+EN диктовки. Скачайте нужные и переключайтесь между ними.",
                            .en: "Catalog is filtered to models supporting Russian. GigaAM v3 excels at Russian accuracy and speed; Parakeet v3 and Whisper Large v3 Turbo work great for mixed RU+EN dictation. Download any model and switch freely."],
        "voice.ruOnlyBadge":[.ru: "только RU", .en: "RU only"],
        "voice.langsN":     [.ru: "%d яз.", .en: "%d langs"],
        "voice.ruWer":      [.ru: "RU WER %.1f%%", .en: "RU WER %.1f%%"],
        "voice.helpRuWer":  [.ru: "Ошибка на русском (WER): %.2f%%", .en: "Russian WER: %.2f%%"],
        "voice.helpSpeed":  [.ru: "Скорость (GPU): ~%.1f× быстрее реального времени", .en: "Speed (GPU): ~%.1f× realtime"],
        "voice.helpLangs":  [.ru: "Языки", .en: "Languages"],
        "voice.refreshCatalog":[.ru: "Обновить список", .en: "Refresh list"],
        "voice.catalogCount":[.ru: "Доступно %d моделей с поддержкой русского языка", .en: "%d models supporting Russian available"],
        "voice.refreshing": [.ru: "Проверяю свежий каталог…", .en: "Checking for updates…"],
        "voice.refreshDone":[.ru: "Каталог обновлён (%d моделей для русского языка)", .en: "Catalog updated (%d Russian-capable models)"],
        "voice.refreshFail":[.ru: "Не удалось обновить каталог: %@", .en: "Failed to refresh catalog: %@"],
        "voice.delete":   [.ru: "Удалить", .en: "Delete"],
        "voice.deleting": [.ru: "Удаляю…", .en: "Deleting…"],
        "voice.delConfirm":[.ru: "Удалить модель «%@»?", .en: "Delete the “%@” model?"],
        "voice.delConfirmSub":[.ru: "Файлы модели удалятся с диска. Скачать заново можно в любой момент.",
                               .en: "The model files will be removed from disk. You can download it again anytime."],
        "common.ok":      [.ru: "ОК", .en: "OK"],
        "common.cancel":  [.ru: "Отмена", .en: "Cancel"],
        "single.title":   [.ru: "Keyboop уже работает", .en: "Keyboop is already running"],
        "single.sub":     [.ru: "Одного зверька достаточно — он уже сидит в строке меню. Вторая копия только дралась бы за клавиши, так что эту я закрою.",
                           .en: "One critter is plenty — it's already up in the menu bar. A second copy would just fight over your keys, so I'll close this one."],
        "gen.silent":     [.ru: "Звуки", .en: "Sounds"],
        "gen.silentSub":  [.ru: "Выключите — и приложение замолчит целиком: переключение, перевод, диктовка и служебные сигналы. Громкости запомнятся",
                           .en: "Turn it off and the app goes completely silent: switching, translation, dictation and system beeps. Volumes are remembered"],
        "upd.title":      [.ru: "Обновления", .en: "Updates"],
        "upd.sub":        [.ru: "Keyboop сам находит новые версии — всегда свежий.", .en: "Keyboop finds new versions on its own — always current."],
        "upd.check2":     [.ru: "Проверять обновления", .en: "Check for updates"],
        "upd.check2Sub":  [.ru: "Скачивает новые версии в фоне; перед установкой спросим",
                           .en: "Downloads new versions in the background; we'll ask before installing"],
        "upd.silent":     [.ru: "Ставить сразу, без вопросов", .en: "Install right away, no questions"],
        "upd.silentSub":  [.ru: "Тихо ставит в простое, когда ты отошёл — не дёргая вопросом",
                           .en: "Installs quietly while you're away, without asking"],
        "upd.betaExistsTitle": [.ru: "Стабильная у вас последняя", .en: "You are on the latest stable"],
        "upd.betaExistsBody":  [.ru: "Новее есть, но это бета %@, а бета-версии у вас выключены. Включить и поставить? Обратно можно в любой момент, в настройках обновлений.",
                                .en: "There is something newer, but it is beta %@, and beta versions are off for you. Turn them on and install it? You can switch back any time in the update settings."],
        "upd.betaExistsYes":   [.ru: "Включить бета-версии", .en: "Turn on betas"],
        "upd.beta":       [.ru: "Ставить бета-версии", .en: "Install beta versions"],
        "upd.betaSub":    [.ru: "Свежие сборки раньше всех, ещё до обкатки",
                           .en: "New builds before everyone else, straight off the bench"],
        // Подсказки «i» вне раздела «Голос». Пишем то, чего НЕТ в подписи.
        "upd.check2Help": [.ru: "Keyboop раз в сутки спрашивает сайт, нет ли версии новее, и качает её в фоне. Запрос отправляет ровно то же, что любой заход на сайт: ваш IP и номер версии. Ничего о наборе, речи или том, как вы пользуетесь программой, не уходит.",
                           .en: "Once a day Keyboop asks the site whether a newer version exists and downloads it in the background. The request sends exactly what visiting a website sends: your IP and the version number. Nothing about your typing, speech or usage leaves the Mac."],
        "upd.silentHelp": [.ru: "Обычно мы спрашиваем перед установкой: программа читает клавиатуру, и молча подменять её у всех подряд неправильно. С этой настройкой обновление ставится само, но только когда вы отошли: не идёт диктовка, не качается модель, не открыто ни одно окно.",
                           .en: "Normally we ask before installing: this app reads your keyboard, and silently swapping it under everyone would be wrong. With this on it installs itself, but only while you are away: no dictation running, no model downloading, no window open."],
        "upd.betaHelp":   [.ru: "Бета это та же сборка, что получат все, только раньше. Обычно она лежит день-два, пока не станет ясно, что ничего не сломалось. Взамен вы иногда ловите свежие ошибки первым — о них очень помогает написать через «Сообщить о проблеме».",
                           .en: "A beta is the same build everyone will get, just earlier. It usually sits for a day or two until it is clear nothing broke. In exchange you sometimes hit fresh bugs first — reporting them via «Report a problem» helps a lot."],
        "switch.autoHelp": [.ru: "Keyboop следит за набранным словом и, если оно не могло быть набрано в текущей раскладке, переключает его сам. Работает в обе стороны, RU и EN. Если слово нужно оставить как есть, верните его как было, и Keyboop предложит запомнить исключение.",
                            .en: "Keyboop watches the word you are typing and, if it could not have been typed in the current layout, switches it. Works both ways, RU and EN. If a word should stay as is, type it back and Keyboop will offer to remember an exception."],
        "switch.liveHelp": [.ru: "Обычно слово чинится на границе, по пробелу или Enter. С этой настройкой оно чинится прямо посреди набора, как только сочетание букв стало невозможным в текущей раскладке. Замена происходит в тот же момент, когда вы нажимаете клавишу, поэтому следующий символ в неё не вклинивается.\n\nГде это НЕ работает, и почему честнее сказать сразу: в приложениях на Chromium и Electron. Это Chrome, Arc, Opera, Яндекс.Браузер, Brave, Vivaldi, а также VS Code, Slack, Notion, Obsidian, Figma, Discord, Linear, Signal и Spotify. Там наша вставка текста ненадёжна: удаление доходит, а вставка нет, и слово пропадает совсем. Стёртое слово хуже непочиненного, поэтому посреди набора мы там ничего не трогаем, а чиним по пробелу, как обычно. В остальных программах настройка работает.",
                            .en: "Normally a word is fixed at its boundary, on space or Enter. With this on it is fixed mid-word, as soon as the letter combination becomes impossible in the current layout. The replacement happens at the exact moment you press the key, so your next character cannot slip into it.\n\nWhere it does NOT work, and it is fairer to say so up front: apps built on Chromium and Electron. That is Chrome, Arc, Opera, Brave, Vivaldi and Yandex Browser, plus VS Code, Slack, Notion, Obsidian, Figma, Discord, Linear, Signal and Spotify. Our text insertion is unreliable there: the deletion lands, the insertion does not, and the word disappears entirely. A word eaten is worse than a word left alone, so mid-word we touch nothing there and fix on the space as usual. Everywhere else the setting works."],
        "switch.predictHelp": [.ru: "Когда курсор попадает в поле ввода, Keyboop в фоне смотрит на текст рядом с курсором и последние сообщения в открытом чате через Accessibility и тихо переключает раскладку ещё до первой буквы.\n\nВыбор запоминается отдельно для каждого чата или окна (в виде одностороннего хэша, без сохранения текста). Если вы сами переключили язык, Keyboop запомнит это и не станет спорить. Поля паролей, терминалы, редакторы кода в режиме разработчика и приложения из «Исключений» не трогаются.",
                               .en: "When focus enters an input field, Keyboop checks text around the caret and recent messages in the active chat via Accessibility in the background and quietly picks the layout before your first keystroke.\n\nYour choice is remembered per chat or window (stored as a one-way hash without saving any text). If you switch the layout yourself, Keyboop remembers it and will not override you. Password fields, terminals, code editors in developer mode, and excluded apps are never touched."],
        "switch.devHelp": [.ru: "В коде полно коротких сочетаний, которые выглядят как опечатка, но опечаткой не являются: имена переменных, флаги, команды. Поэтому в редакторах кода и в IDE авто-переключение выключено целиком, а в остальных программах Keyboop работает как обычно. Раньше этот режим глушил короткие слова ВЕЗДЕ, и «не», «по», «и», «я» переставали чиниться в мессенджерах и заметках; теперь осторожность живёт там, где она нужна, а не поверх всей системы. Программы, где нужна та же осторожность, добавляются в «Исключения» с мягким режимом.",
                           .en: "Code is full of short sequences that look like typos but are not: variable names, flags, commands. So in code editors and IDEs the automatic switching is off entirely, while in every other app Keyboop works as usual. This mode used to mute short words EVERYWHERE, so «не», «по», «и», «я» stopped being fixed in chats and notes too; now the caution lives where it is needed instead of across the whole system. Add any other app that needs the same caution to «Exceptions» in soft mode."],
        "switch.chatter":    [.ru: "Глотать дребезг клавиши", .en: "Swallow key chatter"],
        "switch.chatterSub": [.ru: "Одно нажатие, одна буква", .en: "One press, one letter"],
        "switch.chatterHelp": [.ru: "У изношенных клавиатур контакт иногда срабатывает дважды с одного нажатия, и в тексте появляется лишняя буква. Мы отбрасываем повтор той же клавиши, если он пришёл быстрее чем через 30 миллисекунд. Настоящие двойные буквы это не задевает: даже у быстрых машинисток на «сс» в «ссоре» уходит вдвое больше. Зажатую клавишу тоже не трогаем, автоповтор работает как обычно. Сочетания с ⌘, ⌃ и ⌥ проходят мимо фильтра целиком: пропущенная команда заметна сильнее, чем лишняя. Выключено по умолчанию, потому что это перехват ввода, а не исправление текста.",
                               .en: "On worn keyboards a contact sometimes fires twice from a single press, and an extra letter shows up. We drop a repeat of the same key if it arrives sooner than 30 milliseconds. Genuine double letters are untouched: even fast typists need twice that for the pair in “class”. Holding a key is unaffected too, autorepeat works as usual. Shortcuts with ⌘, ⌃ or ⌥ bypass the filter entirely: a command that never fired hurts more than one that fired twice. Off by default, because this intercepts your typing rather than correcting text."],
        "switch.typoFix":    [.ru: "Исправлять опечатки", .en: "Fix typos"],
        "switch.typoFixSub": [.ru: "«тедефон» → «телефон», «1ю8» → «1.8»", .en: "“tlephone” → “telephone”, “1ю8” → “1.8”"],
        "switch.typoFixHelp":[.ru: "Исправляются очевидные механические ошибки: частая опечатка из проверенного списка («извените» → «извините»), переставленные соседние или случайно удвоенные буквы («тедефон» → «телефон») и русская «ю» между цифрами вместо точки («1ю8» → «1.8»). Для словарной догадки слово меняется, только если правильный вариант получился ровно один; если подходящих несколько, мы не гадаем. Выключено по умолчанию, потому что это правка самого текста, а не раскладки. ⚠️ Профессиональное слово, которого нет в словаре, программа тоже может исправить. Верните его как было, и она это запомнит. Ваши исключения и выученные слова не трогаются вовсе. Сюда же попадает след Caps Lock: слово, у которого первая буква строчная, а все остальные заглавные («пРИВЕТ»), разворачивается обратно в «Привет».",
                              .en: "Obvious mechanical mistakes are corrected: a common typo from a vetted list (“recieve” → “receive”), neighbouring letters swapped or accidentally doubled (“tlephone” → “telephone”), and the Russian-layout letter “ю” between digits in place of a dot (“1ю8” → “1.8”). For dictionary-based guesses, a word changes only when exactly one correction fits; when several do, we do not guess. Off by default, because this edits the text itself rather than the layout. ⚠️ A professional word missing from the dictionary can be corrected too. Put it back the way you had it and the app remembers. Your exceptions and learned words are never touched. The Caps Lock signature belongs here too: a word whose first letter is lower case and all the rest upper case (“hELLO”) is turned back into “Hello”."],
        "switch.twoCaps":    [.ru: "Две заглавные подряд", .en: "Two leading capitals"],
        "switch.twoCapsSub": [.ru: "«КОгда» превращается в «Когда»", .en: "“WHen” becomes “When”"],
        "switch.twoCapsHelp": [.ru: "Так выходит, когда Shift отпущен на миг позже, чем нажата вторая буква. Keyboop чинит только этот случай: ровно две первые буквы заглавные, третья строчная, и в слове одни буквы. Слова целиком заглавными, вроде ГОСТ или USB, а также короткие «ДА» и «ОК» не трогаются. Выключено по умолчанию, потому что это правка самого текста, а не раскладки.",
                              .en: "This happens when Shift is released a moment after the second letter is pressed. Keyboop fixes only that case: exactly the first two letters capital, the third lowercase, and nothing but letters in the word. All-caps words like USB, and short ones like OK, are left alone. Off by default, because this edits your text rather than its layout."],
        // ⚠️ КОРОТКО НАМЕРЕННО (автор, 04.08.2026). Первый вариант был вдвое длиннее: туда попало и
        // обучение на отмене, и почему не помогает стереть слово и набрать заново. Всё это правда, но
        // подсказка у строки отвечает на один вопрос — что делает ЭТА комбинация. Длинный текст в
        // маленьком поповере путает ровно того, кто уже не разобрался, а именно ради него он и писан.
        "switch.manualHelp": [.ru: "Переключает последнее набранное слово в другую раскладку, ждать пробела не нужно. ЭТИМ ЖЕ СОЧЕТАНИЕМ ОТМЕНЯЕТСЯ АВТОМАТИЧЕСКОЕ ПЕРЕКЛЮЧЕНИЕ: если Keyboop переключил слово сам, а вы этого не хотели, нажмите его, и слово вернётся как было. Именно поэтому в названии строки стоит «и отмена»: люди не догадывались, что отменять нужно тем же сочетанием, а не искать отдельное.",
                             .en: "Switches the last typed word to the other layout, no need to wait for a space. THE SAME SHORTCUT UNDOES AN AUTOMATIC SWITCH: if Keyboop switched a word by itself and you did not want that, press it and the word comes back."],
        "switch.arrowsHelp": [.ru: "Речь о четырёх клавишах курсора. Пока вы печатаете слово, Keyboop держит его в памяти, чтобы починить. Стрелка означает, что курсор уехал и слово, скорее всего, уже не то — поэтому память сбрасывается. Выключите, если часто двигаете курсор посреди слова и хотите, чтобы починка всё равно сработала.\n\nВажная мелочь, о которой не говорит ни заголовок, ни подпись: вместе с памятью пропадает цель и у ручного сочетания. Нажали стрелку, потом ⌥⇧ — язык сменится, но слово уже не починится, потому что чинить нечего.",
                              .en: "This is about the four cursor keys. While you type a word, Keyboop keeps it in memory so it can fix it. An arrow means the caret moved and the word is probably no longer the one you meant, so the memory is dropped. Turn this off if you often move the caret mid-word and still want the fix.\n\nOne detail neither the title nor the subtitle mentions: the manual shortcut loses its target too. Press an arrow, then ⌥⇧, and the language will switch but the word will not be fixed — there is nothing left to fix."],
        "hist.lockHelp":  [.ru: "Окно истории будет спрашивать пароль при каждом открытии. Сам пароль хранится в связке ключей macOS, а записи шифруются — мы их не видим и восстановить не сможем. Защита от того, кто сядет за ваш незаблокированный Mac, а не от кражи диска.",
                           .en: "The history window will ask for a password every time it opens. The password lives in the macOS keychain and the entries are encrypted — we cannot see them and cannot recover them. This guards against someone sitting down at your unlocked Mac, not against a stolen disk."],
        "is.enableHelp":  [.ru: "Обычная смена языка в macOS идёт с задержкой: система ждёт, не окажется ли нажатие началом сочетания. Мы перехватываем клавишу раньше и меняем язык сразу. Набранное при этом не трогаем — это именно смена раскладки, а не починка слова.",
                           .en: "Switching language in macOS has a delay: the system waits to see whether your press is the start of a combination. We intercept the key earlier and switch immediately. Nothing you typed is touched — this is a layout switch, not a word fix."],
        "upd.check":      [.ru: "Проверить сейчас", .en: "Check now"],
        // Кнопки плашки об апдейте. Обе ставят СРАЗУ, поэтому «сейчас» из левой убрано: оно
        // подразумевало, что правая поставит когда-нибудь потом, а она тоже ставит сейчас.
        "upd.now":        [.ru: "Обновить", .en: "Update"],
        "upd.auto":       [.ru: "Обновлять автоматически", .en: "Update automatically"],
        "upd.autoShort":  [.ru: "Обновлять автоматически", .en: "Update automatically"],
        "upd.notifyTitle":[.ru: "Keyboop %@ готов", .en: "Keyboop %@ is ready"],
        // ⚠️ Не длиннее двух строк: в плашке у подписи maximumNumberOfLines = 2, и длинный текст
        // обрывался на полуслове (видно на dev-рендере KEYBOOP_BANNERSHOT).
        "upd.notifyBody": [.ru: "Любая кнопка поставит сразу.",
                           .en: "Either button installs it now."],
        // Строка о сорванных проверках обновлений (жалоба 03.08.2026). Формулировка намеренно НЕ
        // обвиняет ни нас, ни человека: причина почти всегда снаружи (сеть, VPN, фильтр, антивирус,
        // запуск не из «Программ»), и наша задача сказать факт, а не поставить диагноз.
        "upd.problem":       [.ru: "Обновления не проверяются", .en: "Updates are not being checked"],
        "upd.problemUnknown":[.ru: "Последняя проверка не дошла до сервера. Обычно виноваты сеть, VPN, корпоративный фильтр или антивирус, а ещё запуск приложения не из папки «Программы».",
                              .en: "The last check never reached the server. Usually the network, a VPN, a corporate filter or antivirus is in the way, and sometimes it is the app running from outside the Applications folder."],
        "upd.problemReport": [.ru: "Сообщить", .en: "Report"],
        "upd.foot":       [.ru: "Проверка шлёт только твой IP и номер версии — как любой заход на сайт. Ничего из набранного.",
                           .en: "The check sends only your IP and version number — like any website visit. Nothing you type."],
        "upd.onboard":    [.ru: "Keyboop сам находит новые версии и спрашивает, ставить ли, — одной кнопкой. Что-то не так — напиши, починим.",
                           .en: "Keyboop finds new versions and asks to install with one tap. If something's off, write to us and we'll fix it."],
        "voice.history":  [.ru: "Хранить историю", .en: "Keep history"],
        "voice.historySub":[.ru: "Зашифровано, остаётся на этом Mac", .en: "Encrypted, stays on this Mac"],
        // Захват буфера обмена в ту же историю (задача 228). Выключен по умолчанию. Тумблер живёт
        // в «Общих» (решение автора 04.09.2026: в голосовом наборе ему не место), остальные настройки
        // истории остаются в голосовом наборе, и подсказка под тумблером говорит, где их искать.
        "gen.history":         [.ru: "История", .en: "History"],
        "gen.clipHistory":     [.ru: "Запоминать скопированный текст", .en: "Remember copied text"],
        "gen.clipHistorySub":  [.ru: "Выключено по умолчанию. Только текст, зашифровано, остаётся на этом Mac",
                                .en: "Off by default. Text only, encrypted, stays on this Mac"],
        "gen.clipHistoryNeedsHistory":[.ru: "Сначала включите «Хранить историю» в разделе «Голосовой набор»",
                                       .en: "Turn on “Keep history” in the “Voice input” section first"],
        "gen.clipHistoryHelp": [.ru: "Всё, что вы копируете как текст, попадает в общую историю рядом с диктовками, и поиск ищет по обоим сразу. Не записывается: пока где-то открыто поле пароля, то, что менеджеры паролей помечают как секрет, а также файлы, картинки и форматирование. Собственные служебные операции Keyboop с буфером в историю не попадают. Срок хранения, пароль на историю и очистка общие.",
                                .en: "Everything you copy as text lands in the shared history next to dictations, and search covers both at once. Not recorded: anything while a password field is open somewhere, entries password managers mark as secret, plus files, images and formatting. Keyboop's own clipboard housekeeping never lands here. Retention, the history password and clearing are shared."],
        "gen.historyHint":     [.ru: "Скопированный текст попадает в ту же историю, что и диктовки: меню значка → «История диктовки и буфера…». Срок хранения, пароль на историю и запись голоса настраиваются в разделе «Голосовой набор» → «История».",
                                .en: "Copied text lands in the same history as dictations: menu icon → “Dictation and clipboard history…”. Retention, the history password and audio recording are set in “Voice input” → “History”."],
        // Сокращение срока хранения (ревью 24.09.2026): без вопроса промах мышью стирал историю.
        "voice.retShrink.title":  [.ru: "Записей старше нового срока: %d", .en: "Entries older than the new period: %d"],
        "voice.retShrink.msg":    [.ru: "Они удалятся сразу вместе с записью голоса, и вернуть их будет нельзя. Расшифровки файлов останутся.",
                                   .en: "They will be deleted right away together with their voice recordings and cannot be brought back. Transcribed files stay."],
        "voice.retShrink.keep":   [.ru: "Оставить как было", .en: "Keep as it was"],
        "voice.retShrink.delete": [.ru: "Удалить и сократить срок", .en: "Delete and shorten"],
        "gen.clipOff.title":   [.ru: "Записей буфера в истории: %d", .en: "Clipboard entries in history: %d"],
        "gen.clipOff.msg":     [.ru: "Новые записи больше не сохраняются. Уже сохранённые можно оставить или удалить сейчас. Диктовки останутся в любом случае.",
                                .en: "New entries are no longer saved. The ones already saved can stay or be deleted now. Dictations stay either way."],
        "gen.clipOff.keep":    [.ru: "Оставить", .en: "Keep"],
        "gen.clipOff.delete":  [.ru: "Удалить записи буфера", .en: "Delete clipboard entries"],
        "voice.histClear":[.ru: "Очистить историю", .en: "Clear history"],
        "voice.showHistory":[.ru: "Показать историю…", .en: "Show history…"],
        // «История диктовки и буфера»: с 04.09.2026 в ленте и буфер (задача 228), имя выбрал автор.
        "hist.title":     [.ru: "История диктовки и буфера", .en: "Dictation and clipboard history"],
        "hist.kind.dictation":    [.ru: "Диктовка", .en: "Dictation"],
        "hist.kind.clipboard":    [.ru: "Буфер", .en: "Clipboard"],
        "hist.kind.clipboardFrom":[.ru: "Буфер · %@", .en: "Clipboard · %@"],
        // Импорт аудиофайла (задача 229).
        "hist.kind.file":     [.ru: "Файл · %@", .en: "File · %@"],
        "hist.import":        [.ru: "Импортировать аудио…", .en: "Import audio…"],
        "hist.importTitle":   [.ru: "Выберите аудио- или видеофайл. Расшифровка идёт на этом Mac и займёт время: у часовой записи это минуты. Результат ляжет в историю и не удалится по сроку хранения, только вручную.",
                               .en: "Choose an audio or video file. Transcription runs on this Mac and takes a while: an hour-long recording means minutes. The result lands in History and is not removed by retention, only by hand."],
        "hist.importProgress":[.ru: "Расшифровываю «%@»: %@ из %@", .en: "Transcribing “%@”: %@ of %@"],
        "hist.importEta":     [.ru: "осталось около %@", .en: "about %@ left"],
        "hist.importCancel":  [.ru: "Отменить", .en: "Cancel"],
        "hist.importDone":    [.ru: "Файл расшифрован и добавлен в историю", .en: "The file is transcribed and added to History"],
        "hist.importPartial": [.ru: "Импорт остановлен, расшифрованная часть сохранена", .en: "Import stopped, the transcribed part is saved"],
        "hist.importCancelled":[.ru: "Импорт отменён", .en: "Import cancelled"],
        "hist.importEmpty":   [.ru: "В файле не нашлось речи", .en: "No speech found in the file"],
        "hist.importFailed":  [.ru: "Не удалось прочитать файл", .en: "The file could not be read"],
        "hist.importEngineFailed":[.ru: "Движок распознавания не ответил, импорт остановлен", .en: "The recognition engine did not respond, import stopped"],
        "hist.importBusy":    [.ru: "Импорт уже идёт", .en: "An import is already running"],
        "hist.importNoHistory":[.ru: "Включите «Хранить историю», чтобы было куда положить расшифровку", .en: "Turn on “Keep history” so the transcript has somewhere to go"],
        "hist.saveText":      [.ru: "Сохранить текст…", .en: "Save text…"],
        "hist.saveTextDoneFolder":[.ru: "Текст сохранён в папке «%@»", .en: "Text saved in the “%@” folder"],
        "hist.saveTextFailed":[.ru: "Не удалось сохранить текст", .en: "The text could not be saved"],
        "hist.expand":        [.ru: "Показать целиком (%@ симв.)", .en: "Show all (%@ chars)"],
        "hist.collapse":      [.ru: "Свернуть", .en: "Collapse"],
        "hist.more":          [.ru: "Показать ещё %@ из %@", .en: "Show %@ more of %@"],
        /// Подпись на значке в Dock, пока открыто окно истории.
        "dock.history":       [.ru: "История", .en: "History"],
        // Запись звука с Mac (задача 230, скрытая: ⌥-клик по значку). В интерфейсе это «запись», не
        // «звонок» (автор 05.09): пишут и созвоны, и выпуски YouTube, и что угодно.
        "hist.kind.call":     [.ru: "Запись · %@", .en: "Recording · %@"],
        "call.tip":           [.ru: "Идёт запись звука. ⌥-клик по значку остановит", .en: "Audio recording in progress. ⌥-click the icon to stop"],
        "call.started":       [.ru: "Запись началась. Остановить: ⌥-клик по значку", .en: "Recording started. To stop: ⌥-click the icon"],
        "call.saved":         [.ru: "Запись расшифрована и добавлена в историю", .en: "The recording is transcribed and added to History"],
        "call.savedAfterStall":[.ru: "Запись прервалась, но записанное расшифровано и в истории", .en: "Recording was interrupted, but what was recorded is transcribed and in History"],
        "call.empty":         [.ru: "В записи не нашлось речи, ничего не сохранено", .en: "No speech in the recording, nothing saved"],
        "call.noSystemAudioTitle": [.ru: "Записан только микрофон", .en: "Only the microphone was recorded"],
        "call.noSystemAudioBody":  [.ru: "Ваш голос слышно, а звук от собеседников не пришёл: скорее всего, macOS не дала нам его записывать. Это отдельное разрешение, оно не то же самое, что микрофон. Откройте «Запись экрана и системного звука», найдите там список «Только запись системного звука» и включите в нём Keyboop.",
                                    .en: "Your voice came through, but the other side did not: macOS most likely did not let us record it. That is a separate permission, not the same as the microphone. Open “Screen & System Audio Recording”, find the “System Audio Recording Only” list there and switch Keyboop on."],
        "call.silenceTitle":  [.ru: "Пять минут тишины", .en: "Five minutes of silence"],
        "call.silenceBody":   [.ru: "Звук, похоже, закончился. Остановить запись? Через две минуты остановлю сам.",
                               .en: "The audio seems to be over. Stop recording? I will stop on my own in two minutes."],
        "call.silenceStop":   [.ru: "Остановить", .en: "Stop"],
        "call.silenceContinue":[.ru: "Продолжить", .en: "Keep recording"],
        "call.stalledTitle":  [.ru: "Запись прервалась", .en: "Recording interrupted"],
        "call.stalledBody":   [.ru: "Звук перестал приходить, и три перезапуска не помогли. Записанное сохраняю; на всякий случай включи диктофон на телефоне.",
                               .en: "Audio stopped arriving and three restarts did not help. Saving what was recorded; start a phone recorder just in case."],
        "call.noPermissionTitle":[.ru: "Нет разрешения записывать звук", .en: "No permission to record audio"],
        "call.noPermissionBody":[.ru: "macOS не дала Keyboop записывать системный звук. Разреши в Системных настройках → Конфиденциальность → Запись экрана и системного звука, затем нажми ⌥-клик снова.",
                                 .en: "macOS did not let Keyboop record system audio. Allow it in System Settings → Privacy → Screen & System Audio Recording, then ⌥-click again."],
        "call.noPermissionOpen":[.ru: "Открыть настройки", .en: "Open Settings"],
        "call.noSpace":       [.ru: "Мало места на диске для записи", .en: "Not enough disk space to record"],
        "call.unavailable":   [.ru: "Запись звука требует macOS 14.2 или новее", .en: "Audio recording needs macOS 14.2 or later"],
        "call.recovering":    [.ru: "Восстанавливаю незавершённую запись", .en: "Recovering an unfinished recording"],
        "hist.copy":      [.ru: "Скопировать", .en: "Copy"],
        "hist.hint":      [.ru: "Двойной клик по записи — скопировать.", .en: "Double-click an entry to copy."],
        "hist.search":    [.ru: "Поиск по истории", .en: "Search history"],
        "hist.empty":     [.ru: "Пока пусто. Зажми хоткей и продиктуй.", .en: "Empty so far. Hold the hotkey and dictate."],
        "hist.emptyClip": [.ru: "Пока пусто. Продиктуй или скопируй что-нибудь.", .en: "Empty so far. Dictate or copy something."],
        "hist.pin":       [.ru: "Поверх всех окон", .en: "Keep on top"],
        "hist.translucent":[.ru: "Полупрозрачность окна", .en: "Window translucency"],
        "hist.rec":       [.ru: "Записать", .en: "Record"],
        "hist.recStop":   [.ru: "Стоп", .en: "Stop"],
        "hist.saveAudio": [.ru: "Сохранить аудио…", .en: "Save audio…"],
        "hist.saveAudioDone":[.ru: "Аудио сохранено", .en: "Audio saved"],
        "hist.saveAudioDoneFolder":[.ru: "Аудио сохранено в папке «%@»", .en: "Audio saved in the “%@” folder"],
        "hist.saveAudioFailed":[.ru: "Не удалось сохранить аудио", .en: "The audio could not be saved"],
        "hist.showInFinder":[.ru: "Показать сохранённый файл в Finder", .en: "Show the saved file in Finder"],
        "hist.del":       [.ru: "Удалить", .en: "Delete"],
        "hist.settings":  [.ru: "Настройки голосового набора", .en: "Voice settings"],
        "hist.lock.toggle":   [.ru: "Пароль на историю", .en: "History password"],
        "hist.lock.toggleSub": [.ru: "Спрошу пароль при открытии окна истории",
                          .en: "I will ask for a password when the history window opens"],
        "hist.lock.title":    [.ru: "История под паролем", .en: "History is locked"],
        "hist.lock.msg":      [.ru: "Введи пароль, чтобы открыть историю диктовок.", .en: "Enter the password to open your dictation history."],
        "hist.lock.open":     [.ru: "Открыть", .en: "Open"],
        "hist.lock.forgot":   [.ru: "Забыл пароль…", .en: "Forgot password…"],
        "hist.lock.wrong":    [.ru: "Не подошло. Попробуй ещё раз.", .en: "That's not it. Try again."],
        "hist.lock.forgot.title":  [.ru: "Пароль не восстановить", .en: "The password can't be recovered"],
        "hist.lock.forgot.confirm":[.ru: "Единственный выход — стереть историю и снять пароль. Записи не вернуть. Стереть?",
                                    .en: "The only way out is to erase the history and remove the password. Entries can't be brought back. Erase?"],
        "hist.lock.forgot.wipe":   [.ru: "Стереть и снять пароль", .en: "Erase and remove password"],
        "hist.lock.set.title":  [.ru: "Пароль на историю", .en: "History password"],
        "hist.lock.set.msg":    [.ru: "Будет запрашиваться при открытии окна истории. Восстановления нет — только стереть историю.",
                                 .en: "You'll be asked for it when opening the history window. There's no recovery — only erasing the history."],
        "hist.lock.set.ok":     [.ru: "Установить", .en: "Set"],
        "hist.lock.set.p1":     [.ru: "Пароль", .en: "Password"],
        "hist.lock.set.p2":     [.ru: "Ещё раз", .en: "Once more"],
        "hist.lock.set.short":  [.ru: "Хотя бы 4 символа.", .en: "At least 4 characters."],
        "hist.lock.set.mismatch":[.ru: "Пароли не совпали.", .en: "The passwords don't match."],
        "menu.report":    [.ru: "Сообщить о проблеме…", .en: "Report a problem…"],
        "fb.title":       [.ru: "Написать разработчику", .en: "Write to the developer"],
        "fb.placeholder": [.ru: "Что сломалось, что бесит, чего не хватает…", .en: "What broke, what annoys you, what's missing…"],
        "fb.contact":     [.ru: "Телеграм или почта — необязательно",
                           .en: "Telegram or email — optional"],
        // Мотивация оставить контакт. ⚠️ Обещание «напишу лично» убрано 30.07 по просьбе автора: он
        // отвечает не всем, а там, где это действительно нужно, и обещать личный ответ каждому —
        // значит расставлять ожидания, которые он не собирается выполнять. Осталась честная причина.
        "fb.contactWhy":  [.ru: "Без него я прочитаю, но ответить будет некуда.",
                           .en: "Without it I'll still read this, but I'll have nowhere to reply."],
        // ⚠️ КОРОТКО, ПОТОМУ ЧТО РЯДОМ КНОПКА. Подпись живёт в одном ряду с «показать, что уйдёт»,
        // и длинный вариант «(версия, настройки, хвост лога)» обрезался многоточием прямо на
        // середине слова (скриншот автора 26.08.2026). Расшифровка и так стоит строкой ниже, в
        // `fb.hint`, целиком и без обрезки, так что в самой галочке она была лишней.
        "fb.diag":        [.ru: "Приложить диагностику", .en: "Attach diagnostics"],
        "fb.diagShow":    [.ru: "показать, что уйдёт", .en: "see what's sent"],
        "fb.diagTitle":   [.ru: "Что уйдёт вместе с отзывом", .en: "What goes along with your feedback"],
        "fb.hint":        [.ru: "Улетает на keyboop.com и разработчику в Telegram. Текст ввода и речь в диагностику не попадают — там только версии, настройки и служебный лог.",
                           .en: "Goes to keyboop.com and straight to the developer's Telegram. Your typing and speech never enter the diagnostics — only versions, settings and the service log."],
        "fb.send":        [.ru: "Отправить", .en: "Send"],
        "fb.sending":     [.ru: "Отправляю…", .en: "Sending…"],
        "fb.fail":        [.ru: "Сеть не отвечает. Можно почтой:", .en: "Network isn't answering. Email works:"],
        "fb.mail":        [.ru: "Отправить почтой", .en: "Send by email"],
        "fb.tg":          [.ru: "Через Telegram", .en: "Via Telegram"],
        "fb.tgTip":       [.ru: "Сохраним отчёт файлом и откроем чат с ботом. Вы увидите, что именно отправляете, и отправите сами",
                           .en: "Saves the report to a file and opens the bot chat. You see exactly what you are sending, and you send it yourself"],
        "fb.tgReady":     [.ru: "Файл в «Загрузках», перетащите его боту",
                           .en: "File is in Downloads, drop it to the bot"],
        "fb.tgSaved":     [.ru: "Отчёт сохранён в «Загрузки»", .en: "Report saved to Downloads"],
        "fb.tgHowTitle":  [.ru: "Отчёт готов, осталось отправить",
                           .en: "The report is ready, one step left"],
        // %@ — имя файла. Называем его прямо: в «Загрузках» у человека сотни файлов.
        "fb.tgHowBody":   [.ru: "Сейчас откроются два окна: чат с ботом Keyboop и папка «Загрузки», где уже лежит файл %@\n\n1. Перетащите этот файл в чат (или приложите скрепкой).\n2. Можно дописать пару слов о том, что случилось.\n3. Отправьте.\n\nНичего не уходит само: отчёт отправляете вы, и видите, что именно отправляете.",
                           .en: "Two windows are about to open: the Keyboop bot chat and your Downloads folder, where the file %@ is already waiting.\n\n1. Drag that file into the chat (or attach it with the paperclip).\n2. Add a couple of words about what happened, if you like.\n3. Send.\n\nNothing goes anywhere on its own: you send the report, and you see exactly what you send."],
        "fb.tgHowGo":     [.ru: "Открыть Telegram", .en: "Open Telegram"],
        "fb.tgHowCancel": [.ru: "Не сейчас", .en: "Not now"],
        "fb.tgFileFail":  [.ru: "Не получилось сохранить файл", .en: "Could not save the file"],
        "fb.doneTitle":   [.ru: "Улетело", .en: "Off it goes"],
        "fb.doneWithContact": [.ru: "Спасибо. Прочитаю всё до последней буквы, и если понадобится уточнить — напишу вам сам.",
                              .en: "Thank you. I'll read every word, and if I need details I'll get in touch."],
        "fb.doneNoContact":   [.ru: "Спасибо. Прочитаю всё до последней буквы. Контакта вы не оставили, так что ответить будет некуда — но на разбор это никак не влияет.",
                              .en: "Thank you. I'll read every word. You left no contact, so there's nowhere to reply — that doesn't affect anything else."],
        "fb.doneClose":   [.ru: "Закрыть", .en: "Close"],
        "fb.tooShort":    [.ru: "Напиши хоть пару слов )", .en: "Give me at least a couple of words )"],
        // Вложение к отзыву (задача 191, 05.09.2026).
        "fb.attach":      [.ru: "Прикрепить скриншот или видео…", .en: "Attach a screenshot or video…"],
        "fb.attachHint":  [.ru: "PNG или JPEG до 10 МБ, MOV или MP4 до 25 МБ. Файл уходит разработчику в Telegram и на сервере не остаётся.",
                           .en: "PNG or JPEG up to 10 MB, MOV or MP4 up to 25 MB. The file goes straight to the developer's Telegram and is not kept on the server."],
        "fb.attachRemove": [.ru: "Убрать файл", .en: "Remove the file"],
        "fb.attachTooLarge": [.ru: "Файл больше %@. Обрежьте или сожмите его.", .en: "The file is over %@. Trim or compress it."],
        "fb.attachBadType": [.ru: "Подойдут только PNG, JPEG, MOV и MP4.", .en: "Only PNG, JPEG, MOV and MP4 will do."],
        "fb.sendingFile": [.ru: "Текст улетел, отправляю файл…", .en: "Text is off, sending the file…"],
        "fb.fileFail":    [.ru: "Текст улетел, а файл не дошёл.", .en: "The text made it, the file didn't."],
        "fb.fileRetry":   [.ru: "Повторить файл", .en: "Retry the file"],
        "fb.doneFile":    [.ru: "Файл тоже дошёл.", .en: "The file made it too."],
        "fb.unitMB":      [.ru: "МБ", .en: "MB"],
        "fb.unitKB":      [.ru: "КБ", .en: "KB"],
        "menu.voiceHistory":[.ru: "История диктовки и буфера…", .en: "Dictation and clipboard history…"],
        "menu.copyLast":  [.ru: "Скопировать последнюю диктовку", .en: "Copy last dictation"],
        "voice.grpDuck":  [.ru: "Пока вы диктуете", .en: "While you dictate"],
        "voice.duck":     [.ru: "Приглушать звук на время диктовки", .en: "Turn the volume down while dictating"],
        "voice.duckSub":  [.ru: "Музыка и видео не будут вас перекрикивать", .en: "Music and video stop talking over you"],
        "voice.duckHelp": [.ru: "Пока идёт запись, громкость системы плавно убавляется, а после неё так же плавно возвращается на прежнее место. Если вы покрутите её сами во время диктовки, мы не станем спорить и оставим ваше значение. Паузу медиа мы намеренно не жмём: клавиша паузы уходит в то приложение, которое система считает главным, а когда открыты вкладка с видео, музыка и созвон, угадать это нельзя.",
                           .en: "While recording, the system volume fades down, and afterwards it fades back to where it was. If you change it yourself mid-dictation, we won't argue and will leave your value. We deliberately don't press pause: the pause key goes to whichever app the system considers primary, and with a video tab, music and a call all open, that is a coin toss."],
        // ⚠️ В НАЗВАНИИ ОБЯЗАНО БЫТЬ СЛОВО «ВОСПРОИЗВЕДЕНИЯ» (автор, 09.08.2026). Прежнее «Громкость
        // во время диктовки» не отвечало на главный вопрос: это про звук, который мы приглушаем, или
        // про чувствительность микрофона? С появлением в соседнем разделе настройки «Поднимать
        // громкость микрофона» двусмысленность стала прямой ловушкой: два ползунка про громкость,
        // и по названию не отличить, какой из них про вход, а какой про выход.
        "voice.duckLevel":[.ru: "Громкость музыки и видео во время диктовки",
                           .en: "Music and video volume while dictating"],
        "voice.duckMute": [.ru: "тишина", .en: "silent"],
        // Коротко: сначала что делает, потом потолок, потом шутка. Не расписывать (автор 30.07).
        "voice.duckLevelHelp": [.ru: "Во время диктовки громкость опустится до этого уровня, потом вернётся. Выше 77% не поднимается. Просто потому что.",
                                 .en: "While you dictate the volume drops to this level, then comes back. It will not go above 77%. Just because."],
        // Выгрузка модели после каждой диктовки (автор 24.09.2026). Подпись однострочная и
        // усекается, поэтому в ней только главное: кому НЕ нужно. Цена и механика — в «i».
        "voice.unloadAfter":    [.ru: "Выгружать модель после каждой диктовки",
                                 .en: "Unload the model after each dictation"],
        "voice.unloadAfterSub": [.ru: "Не нужно, если объединённой памяти хватает",
                                 .en: "Not needed if you have enough unified memory"],
        // У Intel-Mac объединённой памяти нет, там это обычная оперативная (ревью 24.09).
        "voice.unloadAfterSubIntel": [.ru: "Не нужно, если оперативной памяти хватает",
                                      .en: "Not needed if you have enough memory"],
        "voice.unloadAfterHelp":[.ru: "Для Mac с небольшой памятью, например 8 ГБ. Модель распознавания занимает от полутора сотен мегабайт до 1,6 ГБ и обычно остаётся в памяти между диктовками, чтобы следующая начиналась сразу. С этой настройкой Keyboop отдаёт память системе после каждой диктовки, а следующая загружает модель заново. Загрузка начинается в момент нажатия и прячется, пока вы говорите, но короткая фраза может закончиться на секунду-две позже. Если памяти хватает, оставьте выключенным: модель в памяти работает быстрее.",
                                 .en: "For Macs with little memory, such as 8 GB. A recognition model takes from about 150 MB to 1.6 GB and normally stays in memory between dictations so the next one starts right away. With this on, Keyboop hands the memory back to the system after every dictation, and the next one loads the model again. Loading starts the moment you press the shortcut and hides while you speak, but a short phrase may finish a second or two later. If you have enough memory, leave it off: a model kept in memory is faster."],
        "voice.retentionSub": [.ru: "По нему же пропадает копирование из меню",
                               .en: "Also drops copy-from-menu"],
        "voice.retentionHelp": [.ru: "Через это время записи удаляются, и вместе с ними пропадает пункт «Скопировать последнюю диктовку» в меню: копировать ему становится нечего. Если диктуете подолгу и возвращаетесь к сказанному через час, ставьте срок побольше. 7 и 30 дней превращают историю в журнал с поиском. При любом сроке хранятся не больше 3000 последних диктовок и 100 скопированных строк: более старые уходят сами, даже при «Не удалять».",
                                .en: "After this time entries are deleted, and the menu item “Copy last dictation” goes with them: there is nothing left for it to copy. If you dictate over long sessions and come back to what you said an hour later, pick a longer period. 7 and 30 days turn History into a searchable log. Whatever the period, at most the last 3000 dictations and 100 copied snippets are kept: older ones go on their own, even with “Keep all”."],
        // ⚠️ ГОВОРИМ, ЧТО ИМЕННО СКОПИРОВАНО (автор 08.08). Голое «Скопировано» ничего не сообщало,
        // а у того, кто настроил правый клик не на копирование, оно и вовсе подтверждало действие,
        // которого человек не совершал.
        // Ошибки/статус меню (строка состояния)
        "menu.copyLastDone": [.ru: "Скопирована последняя диктовка", .en: "Last dictation copied"],
        // Редкий случай: срок хранения истёк между открытием меню и кликом. В остальных ситуациях
        // пункта в меню просто нет, поэтому объяснять «история выключена» здесь уже не нужно.
        "menu.copyLastEmpty": [.ru: "Последняя диктовка уже удалена по сроку хранения",
                               .en: "The last dictation is gone, its retention time ran out"],
        "voice.foot":     [.ru: "Аудио и распознавание не покидают Mac. История шифруется и остаётся только у вас.",
                           .en: "Audio and recognition never leave the Mac. History is encrypted and stays only on this device."],
        "voice.hkRopt":   [.ru: "Правый ⌥  (right Option)", .en: "Right ⌥  (right Option)"],
        "voice.hkRcmd":   [.ru: "Правый ⌘  (right Command)", .en: "Right ⌘  (right Command)"],
        "voice.hkFn":     [.ru: "🌐  Globe / Fn", .en: "🌐  Globe / Fn"],
        "voice.hkTilde":  [.ru: "⌥`  (Option + клавиша под Esc)", .en: "⌥`  (Option + the key under Esc)"],
        "voice.shadow.body": [.ru: "Пока включена диктовка по этой клавише, %@ работать не будет. Смените клавишу или выключите диктовку — всё вернётся как было.",
                              .en: "While dictation uses this key, %@ won't work. Change the key or turn off dictation to restore it."],
        "voice.mic":      [.ru: "Микрофон", .en: "Microphone"],
        "voice.micSystem":[.ru: "По умолчанию (система)", .en: "Default (system)"],
        // ⚠️ Было «Открыть настройки звука…», и это читалось как наш собственный звук записи,
        // стоявший парой строк ниже. На деле кнопка открывает СИСТЕМНУЮ панель, то есть уровень
        // входа микрофона. Слово «звук» убрано, коллизия исчезает вместе с ним.
        "voice.micSettings":[.ru: "Уровень входа в настройках macOS…", .en: "Input level in macOS Settings…"],

        "exp.groupConvert":   [.ru: "Переключать несколько слов", .en: "Convert multiple words"],
        "exp.groupConvertSub":[.ru: "Хоткеем чинит сразу всю набранную фразу, а не одно слово.",
                               .en: "One hotkey fixes the whole typed phrase, not just one word."],
        "exp.groupConvertAutoOff":[.ru: "Доступно при выключенном авто-переключении — иначе оно само чинит на лету.",
                                   .en: "Available when auto-switch is off — otherwise it fixes things on the fly."],
        "exp.title":          [.ru: "Эксперименты", .en: "Experimental"],

        // Заголовок меню теперь строится в коде из версии (MenuBarController), слоган убран.
        "menu.autoOff":   [.ru: "авто выкл", .en: "auto off"],
        "menu.auto":      [.ru: "Авто-переключение", .en: "Auto-switch"],
        "menu.checkUpdates": [.ru: "Проверить обновления…", .en: "Check for Updates…"],
        "menu.settings":  [.ru: "Настройки…", .en: "Settings…"],
        "menu.quit":      [.ru: "Выйти", .en: "Quit"],
        // Без «⚠︎» в тексте: с 30.07 у пункта есть цветной значок-треугольник (MenuBarController.icon).
        // ⚠️ ДВА РАЗНЫХ ПУНКТА ВМЕСТО ОДНОГО (репорт #71). Раньше здесь был единственный
        // «Нужен доступ (Accessibility)…», и человеку с выданным Accessibility он врал в лицо.
        // Названия совпадают с тем, как разделы называются в системных Настройках, чтобы человек
        // искал глазами ровно ту строчку, которую прочитал у нас.
        "menu.permInput": [.ru: "Нужен доступ: Мониторинг ввода…", .en: "Needs access: Input Monitoring…"],
        "menu.permAX":    [.ru: "Нужен доступ: Универсальный доступ…", .en: "Needs access: Accessibility…"],
        "menu.permMove":  [.ru: "…и перенесите Keyboop в «Программы»", .en: "…and move Keyboop to Applications"],
        // ⚠️ menu.perm оставлен НАМЕРЕННО, хотя меню его больше не зовёт: ключи локализации живут
        // дольше кода, и удалить строку дешевле, чем однажды обнаружить пустой пункт меню у того,
        // у кого сборка старше словаря. Если через пару релизов он так и не понадобится — убрать.
        "menu.perm":      [.ru: "Нужен доступ (Accessibility)…", .en: "Needs access (Accessibility)…"],
        "menu.mic":       [.ru: "Микрофон", .en: "Microphone"],
        "menu.micDefault":[.ru: "По умолчанию (система)", .en: "Default (system)"],
        "menu.quitConfirm":[.ru: "Выйти из Keyboop?", .en: "Quit Keyboop?"],
        "menu.quitBody":  [.ru: "Тогда раскладка снова на тебе: авто-переключение и голосовой ввод отключатся, пока не запустишь Keyboop заново.",
                           .en: "Then the layout is on you again — auto-switch and dictation turn off until you launch Keyboop next time."],
        "menu.stay":      [.ru: "Остаться", .en: "Stay"],

        // About — развёрнутое описание (что это, что умеет, нюансы)
        "about.whatTitle":[.ru: "Что это", .en: "What it is"],
        "about.what":     [.ru: "Keyboop сам исправляет неверную раскладку: напечатал «ghbdtn» — молча стало «привет». Двусторонне, RU↔EN, по словарю и контексту. Не угадал — поправь сам хоткеем %@.",
                           .en: "Keyboop fixes the wrong layout for you: type “ghbdtn” and it quietly becomes “привет”. Both ways, RU↔EN, by dictionary and context. Missed one? Fix it yourself with %@."],
        "about.canTitle": [.ru: "Что умеет", .en: "What it can do"],
        "about.can":      [.ru: "• Авто-переключение раскладки на пробеле/Enter/Tab.\n• Ручной хоткей %@ — переключить последнее слово (или просто язык, если ничего не набрано).\n• Голосовой набор: проговорил по хоткею — текст на месте (локально, без интернета).\n• Автозамена: сокращение → фраза (раскладка и регистр не важны).\n• Исключения: программы, где переключать не нужно.",
                           .en: "• Auto-switch layout on space/Enter/Tab.\n• Manual %@ — switch the last word (or just the language if nothing’s typed).\n• Voice typing: press the hotkey and speak — text appears (local, no internet).\n• Snippets: shortcut → phrase (layout and case don’t matter).\n• Exceptions: apps where switching isn’t wanted."],
        "about.nuanceTitle":[.ru: "Нюансы", .en: "Good to know"],
        "about.nuance":   [.ru: "Работает в фоне (значок у часов). При исправлении слов не трогает буфер обмена — печатает символы напрямую. Из твоего ввода и голоса наружу не уходит ничего; в сеть — только за моделями и обновлениями. Нужен доступ к «Универсальному доступу» (Accessibility), чтобы видеть и исправлять ввод.",
                           .en: "Runs in the background (menu-bar icon). Doesn’t touch the clipboard when fixing words — it types characters directly. Nothing from your input or voice ever leaves the Mac; the network is used only for models and updates. Needs Accessibility access to see and fix input."],

        // KB-001: Правила ввода на уровне сайтов
        "menu.siteProfilePrefix":  [.ru: "Профиль: %@", .en: "Profile: %@"],
        "menu.siteAddCurrent":     [.ru: "Добавить правило для текущего сайта…", .en: "Add rule for current site…"],
        "menu.siteDisconnected":   [.ru: "Правила сайтов недоступны", .en: "Site rules unavailable"],
        "menu.siteSummaryAutoOff": [.ru: "Автоисправление выключено", .en: "Auto-switch off"],
        "menu.siteSummaryTypoOff": [.ru: "Опечатки выключены", .en: "Typo fix off"],
        "menu.siteSummarySnipOff": [.ru: "Сниппеты выключены", .en: "Snippets off"],
        "menu.siteSummarySoft":    [.ru: "Мягкий режим", .en: "Soft mode"],
        "menu.siteSummaryModeOff": [.ru: "Отключено для сайта", .en: "Disabled for site"],
        "menu.siteSummaryDefault": [.ru: "Особые правила", .en: "Custom rules"],

        "sites.title":             [.ru: "Правила для сайтов", .en: "Website rules"],
        "sites.subtitle":          [.ru: "Индивидуальные настройки раскладки, опечаток и автозамены для отдельных доменов в Chrome.",
                                    .en: "Per-domain layout, typo correction and snippet rules inside Google Chrome."],
        "sites.bridgeTitle":       [.ru: "Расширение для Chrome", .en: "Chrome extension"],
        "sites.bridgeHint":        [.ru: "Расширение передаёт только домен активной вкладки. Полные URL, параметры запроса и текст страниц не покидают браузер и не пишутся в логи.",
                                    .en: "Only the active tab's domain name is shared. Full URLs, query parameters and page contents never leave the browser or touch logs."],
        "sites.bridgeConnected":   [.ru: "Статус: расширение подключено", .en: "Status: extension connected"],
        "sites.bridgeInstalled":   [.ru: "Статус: системный мост установлен, ожидание подключения Chrome", .en: "Status: native bridge installed, waiting for Chrome extension"],
        "sites.bridgeNeedsUpdate": [.ru: "Статус: требуется обновить системный мост Chrome", .en: "Status: Chrome native bridge needs an update"],
        "sites.bridgeNotInstalled":[.ru: "Статус: системный мост Chrome не установлен", .en: "Status: Chrome native bridge not installed"],
        "sites.bridgeHostMissing": [.ru: "Статус: компонент KeyboopNativeHost не найден в сборке", .en: "Status: KeyboopNativeHost helper missing from app bundle"],
        "sites.installBridge":     [.ru: "Установить мост для Chrome", .en: "Install Chrome bridge"],
        "sites.reinstallBridge":   [.ru: "Обновить мост", .en: "Update bridge"],
        "sites.openExtension":     [.ru: "Папка расширения…", .en: "Reveal extension folder…"],
        "sites.bridgeInstalledOk": [.ru: "Системный мост Chrome установлен", .en: "Chrome native bridge installed"],
        "sites.bridgeInstallFail": [.ru: "Не удалось установить мост: %@", .en: "Failed to install bridge: %@"],
        "sites.incognito":         [.ru: "Применять правила в окнах Инкогнито", .en: "Apply rules in Incognito windows"],
        "sites.incognitoSub":      [.ru: "По умолчанию вкладки Инкогнито игнорируются ради приватности",
                                    .en: "By default Incognito tabs are ignored for privacy"],
        "sites.rulesTitle":        [.ru: "Правила сайтов", .en: "Site rules"],
        "sites.rulesHint":         [.ru: "Допустимы точный домен (github.com) и поддомены (*.github.com). Параметр «Наследовать» берёт значение из правил Chrome или общих настроек.",
                                    .en: "Supports exact domains (github.com) and subdomains (*.github.com). “Inherit” falls back to Chrome app rules or global settings."],
        "sites.col.site":          [.ru: "Сайт", .en: "Site"],
        "sites.col.typo":          [.ru: "Автоисправление", .en: "Auto-fix"],
        "sites.col.layout":        [.ru: "Раскладка", .en: "Layout"],
        "sites.col.snippets":      [.ru: "Сниппеты", .en: "Snippets"],
        "sites.empty":             [.ru: "Пока нет ни одного правила для сайта. Нажмите «Добавить» или откройте сайт в Chrome и выберите «Применить к текущему сайту».",
                                    .en: "No site rules yet. Click “Add” or open a site in Chrome and use “Apply to current site”."],
        "sites.btn.add":           [.ru: "Добавить", .en: "Add"],
        "sites.btn.edit":          [.ru: "Изменить", .en: "Edit"],
        "sites.btn.delete":        [.ru: "Удалить", .en: "Delete"],
        "sites.btn.applyCurrent":  [.ru: "Применить к текущему сайту", .en: "Apply to current site"],
        "sites.val.inherit":       [.ru: "Наследовать", .en: "Inherit"],
        "sites.val.on":            [.ru: "Вкл.", .en: "On"],
        "sites.val.off":           [.ru: "Выкл.", .en: "Off"],
        "sites.val.auto":          [.ru: "Авто", .en: "Auto"],
        "sites.val.keep":          [.ru: "Не менять", .en: "Keep"],
        "sites.val.ru":            [.ru: "RU", .en: "RU"],
        "sites.val.en":            [.ru: "EN", .en: "EN"],
        "sites.val.soft":          [.ru: "Мягкий", .en: "Soft"],
        "sites.val.disabled":      [.ru: "Выкл.", .en: "Off"],
        "sites.val.anyBrowser":    [.ru: "Любой поддерживаемый", .en: "Any supported browser"],
        "sites.val.chrome":        [.ru: "Google Chrome", .en: "Google Chrome"],
        "sites.ed.addTitle":       [.ru: "Новое правило для сайта", .en: "New site rule"],
        "sites.ed.editTitle":      [.ru: "Редактировать правило сайта", .en: "Edit site rule"],
        "sites.ed.domain":         [.ru: "Домен сайта", .en: "Domain"],
        "sites.ed.domainPh":       [.ru: "github.com или *.github.com", .en: "github.com or *.github.com"],
        "sites.ed.domainHint":     [.ru: "Только домен или *.поддомен без пути и протокола.", .en: "Domain or *.subdomain only, no URL path or scheme."],
        "sites.ed.name":           [.ru: "Название (необязательно)", .en: "Name (optional)"],
        "sites.ed.namePh":         [.ru: "Например: GitHub", .en: "e.g. GitHub"],
        "sites.ed.enabled":        [.ru: "Правило включено", .en: "Rule enabled"],
        "sites.ed.browser":        [.ru: "Браузер", .en: "Browser"],
        "sites.ed.autoSwitch":     [.ru: "Автосмена раскладки", .en: "Auto-switch layout"],
        "sites.ed.typoFix":        [.ru: "Исправление при наборе", .en: "Typo correction"],
        "sites.ed.snippets":       [.ru: "Автозамена сниппетов", .en: "Snippet expansion"],
        "sites.ed.preferredLayout":[.ru: "Предпочтительная раскладка", .en: "Preferred layout"],
        "sites.ed.exceptionMode":  [.ru: "Режим исключения", .en: "Exception mode"],
        "sites.ed.cancel":         [.ru: "Отмена", .en: "Cancel"],
        "sites.ed.save":           [.ru: "Сохранить", .en: "Save"],
        "sites.ed.errEmpty":       [.ru: "Укажите домен сайта.", .en: "Enter a domain name."],
        "sites.ed.errInvalid":     [.ru: "Некорректный домен. Пример: github.com или *.github.com.", .en: "Invalid domain. Example: github.com or *.github.com."],
        "sites.ed.errTooBroad":    [.ru: "Слишком широкий шаблон домена запрещён (например *.com).", .en: "Overly broad domain patterns (like *.com) are not allowed."],
        "sites.ed.errRegex":       [.ru: "Регулярные выражения не поддерживаются — используйте домен или *.", .en: "Regular expressions are not supported — use a domain or *."],
        "sites.ed.errNoWildcard":  [.ru: "Неверный формат домена.", .en: "Invalid domain format."],

        // MARK: - KB-004 Динамические сниппеты с переменными
        "snip.form.title":            [.ru: "Заполнить шаблон «%@»", .en: "Fill template “%@”"],
        "snip.form.preview":          [.ru: "Предпросмотр", .en: "Preview"],
        "snip.form.insert":           [.ru: "Вставить", .en: "Insert"],
        "snip.form.cancel":           [.ru: "Отмена", .en: "Cancel"],
        "snip.form.requiredPh":       [.ru: "Обязательное поле", .en: "Required"],
        "snip.form.optionalPh":       [.ru: "Необязательно", .en: "Optional"],
        "snip.form.chooseNone":       [.ru: "— не выбрано —", .en: "— none —"],
        "snip.form.missingRequired":  [.ru: "Заполните обязательные поля: %@", .en: "Fill required fields: %@"],
        "snip.form.clipboardBlocked": [.ru: "Доступ к {{clipboard}} запрещён настройками этого шаблона.", .en: "{{clipboard}} access is not allowed for this template."],
        "snip.form.emptyResult":      [.ru: "Итоговый текст пуст — триггер сохранён без удаления.", .en: "Rendered text is empty — trigger preserved."],
        "snip.form.abortTitle":       [.ru: "Вставка шаблона отменена", .en: "Template insertion cancelled"],
        "snip.form.abortApp":         [.ru: "Фокус перешёл в другое приложение. Исходный триггер остался на месте.", .en: "Focus moved to another app. Trigger left intact."],
        "snip.form.abortWindow":      [.ru: "Исходное окно было закрыто или сменилось. Текст не изменён.", .en: "Original window changed or closed. Text left untouched."],
        "snip.form.abortField":       [.ru: "Активное поле ввода изменилось — вставка отменена для безопасности.", .en: "Focused input field changed — insertion aborted safely."],
        "snip.form.abortSecure":      [.ru: "Поле защищено (Secure Input) — динамические сниппеты здесь не работают.", .en: "Protected input (Secure Input) — dynamic snippets are disabled here."],

        "snip.tpl.newBtn":            [.ru: "Новый шаблон…", .en: "New template…"],
        "snip.tpl.editBtn":           [.ru: "Настроить как текст или шаблон…", .en: "Edit as text or template…"],
        "snip.tpl.addTitle":          [.ru: "Новый динамический сниппет", .en: "New dynamic snippet"],
        "snip.tpl.editTitle":         [.ru: "Редактировать сниппет", .en: "Edit snippet"],
        "snip.tpl.trigger":           [.ru: "Триггер:", .en: "Trigger:"],
        "snip.tpl.kind":              [.ru: "Тип:", .en: "Type:"],
        "snip.tpl.kindPlain":         [.ru: "Обычный текст", .en: "Plain text"],
        "snip.tpl.kindTemplate":      [.ru: "Шаблон с переменными", .en: "Template with variables"],
        "snip.tpl.enabled":           [.ru: "Включён", .en: "Enabled"],
        "snip.tpl.private":           [.ru: "Приватный", .en: "Private"],
        "snip.tpl.allowClipboard":    [.ru: "Разрешить {{clipboard}}", .en: "Allow {{clipboard}}"],
        "snip.tpl.body":              [.ru: "Содержимое:", .en: "Content:"],
        "snip.tpl.addVar":            [.ru: "Добавить переменную ▾", .en: "Add variable ▾"],
        "snip.tpl.varDate":           [.ru: "Дата ({{date}})", .en: "Date ({{date}})"],
        "snip.tpl.varDateFmt":        [.ru: "Дата по формату ({{date:dd.MM.yyyy}})", .en: "Formatted date ({{date:dd.MM.yyyy}})"],
        "snip.tpl.varTime":           [.ru: "Время ({{time}})", .en: "Time ({{time}})"],
        "snip.tpl.varDateTime":       [.ru: "Дата и время ({{datetime}})", .en: "Date & time ({{datetime}})"],
        "snip.tpl.varClipboard":      [.ru: "Буфер обмена ({{clipboard}})", .en: "Clipboard ({{clipboard}})"],
        "snip.tpl.varCustom":         [.ru: "Пользовательская переменная ({{%@}})", .en: "Custom variable ({{%@}})"],
        "snip.tpl.fieldsHeader":      [.ru: "Поля формы", .en: "Form fields"],
        "snip.tpl.noFields":          [.ru: "Добавьте переменную вроде {{name}} в текст шаблона — она появится здесь автоматически.", .en: "Add a variable like {{name}} to the template body to configure its field here."],
        "snip.tpl.fldLabelPh":        [.ru: "Название поля", .en: "Field label"],
        "snip.tpl.fldDefPh":          [.ru: "По умолчанию", .en: "Default value"],
        "snip.tpl.fldReq":            [.ru: "Обяз.", .en: "Req."],
        "snip.tpl.fldOptions":        [.ru: "Варианты:", .en: "Options:"],
        "snip.tpl.fldOptionsPh":      [.ru: "Через запятую, например: Да, Нет", .en: "Comma-separated, e.g.: Yes, No"],
        "snip.tpl.typeText":          [.ru: "Строка", .en: "Single line"],
        "snip.tpl.typeMultiline":     [.ru: "Многострочный", .en: "Multiline"],
        "snip.tpl.typeDate":          [.ru: "Дата", .en: "Date"],
        "snip.tpl.typeChoice":        [.ru: "Список", .en: "Choice list"],
        "snip.tpl.clipboardPreviewSample": [.ru: "[текст из буфера обмена]", .en: "[clipboard text]"],
        "snip.tpl.warnClipboardOff":  [.ru: "В шаблоне есть {{clipboard}}, но разрешение «Разрешить {{clipboard}}» выключено — при вставке будет пусто.", .en: "Template contains {{clipboard}}, but permission is disabled — it will expand empty."],
        "snip.tpl.errEmptyTrigger":   [.ru: "Укажите триггер (например ;meeting или !ee).", .en: "Enter a trigger (e.g. ;meeting or !ee)."],
        "snip.tpl.errSpaceTrigger":   [.ru: "Триггер не должен содержать пробелы или переводы строк.", .en: "Trigger cannot contain spaces or line breaks."],
        "snip.tpl.errDupTrigger":     [.ru: "Конфликт триггеров: активный сниппет «%@» совпадает по раскладке/регистру.", .en: "Trigger conflict: active snippet “%@” matches by layout/case."],
        "snip.tpl.diagUnclosed":      [.ru: "Незакрытая переменная `{{`.", .en: "Unclosed variable `{{`."],
        "snip.tpl.diagUnmatchedClose":[.ru: "Лишняя закрывающая скобка `}}` (экранируйте через \\}}).", .en: "Unmatched closing braces `}}` (escape with \\}})."],
        "snip.tpl.diagEmptyVar":      [.ru: "Пустое имя переменной `{{}}`.", .en: "Empty variable placeholder `{{}}`."],
        "snip.tpl.diagNested":        [.ru: "Вложенная скобка `{{` внутри переменной не поддерживается.", .en: "Nested `{{` inside a variable is not supported."],
        "snip.tpl.diagBadName":       [.ru: "Недопустимое имя переменной `{{%@}}`.", .en: "Invalid variable name `{{%@}}`."],
        "snip.tpl.diagEmptyFmt":      [.ru: "Не указан формат даты/времени в `{{%@}}`.", .en: "Empty date/time format in `{{%@}}`."],
        "snip.tpl.diagClipArg":       [.ru: "`{{clipboard}}` не принимает параметры (`{{%@}}`).", .en: "`{{clipboard}}` does not accept arguments (`{{%@}}`)."],
        "snip.tpl.diagUnknownFn":     [.ru: "Неизвестная встроенная функция `%@`.", .en: "Unknown built-in function `%@`."],

        // MARK: - KB-021 Умная типографика
        "sec.typography":             [.ru: "Типографика", .en: "Typography"],
        "sites.col.typography":       [.ru: "Типографика", .en: "Typography"],
        "sites.ed.typography":        [.ru: "Умная типографика", .en: "Smart Typography"],
        "is.busy.typoFormat":         [.ru: "типографика выделения", .en: "format selection typography"],
        "is.busy.typoUndo":           [.ru: "отмена типографики", .en: "undo typography"],
        "hkrec.what.typoFormat":      [.ru: "Исправить типографику выделения", .en: "Format selection typography"],
        "hkrec.what.typoUndo":        [.ru: "Отменить последнюю типографику", .en: "Undo last typography change"],

        "typo.title":                 [.ru: "Умная типографика", .en: "Smart Typography"],
        "typo.sub":                   [.ru: "Консервативное преобразование кавычек, тире, неразрывных пробелов и спецсимволов при наборе и в выделенном тексте.", .en: "Conservative formatting of quotes, dashes, non-breaking spaces, and symbols while typing or in selected text."],
        "typo.enabled":               [.ru: "Включить умную типографику", .en: "Enable Smart Typography"],
        "typo.enabledSub":            [.ru: "Работает полностью офлайн и автоматически пропускает код, ссылки, пути и терминалы.", .en: "Works completely offline and skips code, URLs, file paths, and terminals."],
        "typo.mode":                  [.ru: "Режим правил", .en: "Rule preset"],
        "typo.modeSub":               [.ru: "Первый запуск всегда стартует в безопасном минимальном режиме.", .en: "Starts in the safe minimal preset on first enable."],
        "typo.mode.minimal":          [.ru: "Минимальный (безопасный)", .en: "Minimal (safe)"],
        "typo.mode.standard":         [.ru: "Стандартный", .en: "Standard"],
        "typo.mode.custom":           [.ru: "Пользовательский", .en: "Custom"],
        "typo.lang":                  [.ru: "Язык кавычек", .en: "Quote language"],
        "typo.lang.auto":             [.ru: "Авто (по тексту и раскладке)", .en: "Auto (from text & layout)"],
        "typo.lang.ru":               [.ru: "Всегда русский («ёлочки»)", .en: "Always Russian («guillemets»)"],
        "typo.lang.en":               [.ru: "Всегда английский (“curly”)", .en: "Always English (“curly”)"],
        "typo.preview":               [.ru: "Предпросмотр для длинных выделений", .en: "Preview panel for long selections"],
        "typo.previewSub":            [.ru: "Показывать «Было / Стало» перед заменой нескольких строк или правок.", .en: "Show Before / After comparison for multiline or multi-change edits."],

        "typo.sec.hotkeys":           [.ru: "Горячие клавиши", .en: "Shortcuts"],
        "typo.hotkey.format":         [.ru: "Исправить типографику выделенного текста", .en: "Format selected text typography"],
        "typo.hotkey.formatSub":      [.ru: "Читает только через Accessibility, никогда не трогает буфер обмена.", .en: "Reads strictly via Accessibility without touching the clipboard."],
        "typo.hotkey.combo":          [.ru: "Сочетание клавиш", .en: "Shortcut"],
        "typo.hotkey.undo":           [.ru: "Отменить последнее автоформатирование", .en: "Undo last automatic formatting"],
        "typo.hotkey.undoSub":        [.ru: "Возвращает исходные символы, включая обычный или неразрывный пробел.", .en: "Restores exact original characters including space codepoints."],
        "typo.hotkey.undoCombo":      [.ru: "Сочетание отмены", .en: "Undo shortcut"],

        "typo.sec.rules":             [.ru: "Правила преобразования", .en: "Formatting rules"],
        "typo.grp.quotes":            [.ru: "Кавычки и апострофы", .en: "Quotes & Apostrophes"],
        "typo.grp.dashes":            [.ru: "Тире", .en: "Dashes"],
        "typo.grp.spaces":            [.ru: "Пробелы и неразрывные пробелы", .en: "Spaces & Non-Breaking Spaces"],
        "typo.grp.symbols":           [.ru: "Символы и многоточие", .en: "Symbols & Ellipsis"],

        "typo.rule.ruQuotes":         [.ru: "Русские парные кавычки \"текст\" → «текст»", .en: "Russian paired quotes \"text\" → «text»"],
        "typo.rule.ruQuotes.hint":    [.ru: "Срабатывает только для корректных пар и не трогает одиночную кавычку.", .en: "Applies only to valid pairs; unmatched single quotes stay untouched."],
        "typo.rule.nestedQuotes":     [.ru: "Вложенные кавычки 'внутри' → „внутри“", .en: "Nested inner quotes 'inner' → „inner“"],
        "typo.rule.nestedQuotes.hint": [.ru: "Работает только внутри закрытой пары внешних кавычек.", .en: "Only triggers inside a closed outer quote pair."],
        "typo.rule.enQuotes":         [.ru: "Английские парные кавычки “…”", .en: "English curly quotes “…”"],
        "typo.rule.enQuotes.hint":    [.ru: "Применяется к английскому тексту при автоопределении или режиме EN.", .en: "Applies to English prose when language is Auto or EN."],
        "typo.rule.enApostrophe":     [.ru: "Английский типографский апостроф don't → don’t", .en: "English typographic apostrophe don't → don’t"],
        "typo.rule.emDash":           [.ru: "Длинное тире слово -- слово → слово — слово", .en: "Em-dash word -- word → word — word"],
        "typo.rule.emDash.hint":      [.ru: "Не изменяет флаги CLI (--amend, --help) и дефисы в словах.", .en: "Preserves CLI flags (--amend, --help) and hyphenated words."],
        "typo.rule.enDashRanges":     [.ru: "Короткое тире в числовых диапазонах 5-10 → 5–10", .en: "En-dash in numeric ranges 5-10 → 5–10"],
        "typo.rule.enDashRanges.hint": [.ru: "Осторожно: пропускает ISO-даты 2026-11-14 и версии.", .en: "Skips ISO dates like 2026-11-14 and version identifiers."],
        "typo.rule.nbspUnits":        [.ru: "Неразрывные пробелы (U+00A0): 10 кг, 25 %, 100 ₽, 2026 г., № 15", .en: "Non-breaking spaces (U+00A0): 10 kg, 25 %, $100, № 15"],
        "typo.rule.nbspUnits.hint":   [.ru: "Предотвращает отрыв единиц измерения, валют и сокращений при переносе строки.", .en: "Prevents awkward line wraps between numbers and units or currencies."],
        "typo.rule.narrowNbsp":       [.ru: "Узкий неразрывный пробел (U+202F) вместо U+00A0", .en: "Narrow no-break space (U+202F) instead of U+00A0"],
        "typo.rule.narrowNbsp.hint":  [.ru: "Опционально для % и валют; часть шрифтов и редакторов отображает U+202F шире или иначе.", .en: "Optional for % and currencies; note some fonts render U+202F differently."],
        "typo.rule.collapseSpacesSelection": [.ru: "Схлопывать двойные пробелы (только в выделении)", .en: "Collapse multiple spaces (selection only)"],
        "typo.rule.trimSpaceBeforePunctSelection": [.ru: "Убирать пробел перед , . ! ? ; : (только в выделении)", .en: "Remove space before , . ! ? ; : (selection only)"],
        "typo.rule.selectionOnly.hint": [.ru: "Отключено при живом наборе и применяется только командой форматирования выделения.", .en: "Disabled during live typing; applies only to manual selection formatting."],
        "typo.rule.ellipsis":         [.ru: "Многоточие ... → …", .en: "Ellipsis ... → …"],
        "typo.rule.ellipsis.hint":    [.ru: "Ждёт следующий символ, чтобы не сломать .... или пути ./", .en: "Waits past the 3rd dot so .... or ./ paths stay untouched."],
        "typo.rule.copyright":        [.ru: "(c) → ©", .en: "(c) → ©"],
        "typo.rule.registered":       [.ru: "(r) → ®", .en: "(r) → ®"],
        "typo.rule.trademark":        [.ru: "(tm) → ™", .en: "(tm) → ™"],

        "typo.nbspInfo.title":        [.ru: "Чем отличаются пробелы U+0020, U+00A0 и U+202F", .en: "Space characters: U+0020 vs U+00A0 vs U+202F"],
        "typo.nbspInfo.body":         [.ru: "• Обычный пробел (U+0020) — допускает разрыв строки.\n• Неразрывный пробел (U+00A0) — выглядит как обычный пробел, но удерживает «10 кг» и «25 %» на одной строке.\n• Узкий неразрывный пробел (U+202F) — тоньше обычного и хорошо подходит перед % и ₽, если ваш шрифт его поддерживает.", .en: "• Regular space (U+0020) — allows line breaks.\n• Non-breaking space (U+00A0) — standard width, keeps “10 kg” and “25 %” together.\n• Narrow NBSP (U+202F) — thinner spacing before %/currencies when supported by the target font."],

        "typo.sec.exclusions":        [.ru: "Исключения приложений", .en: "Excluded applications"],
        "typo.exc.empty":             [.ru: "Дополнительных исключений нет.", .en: "No extra app exclusions added."],
        "typo.exc.defaultHint":       [.ru: "Терминалы и редакторы кода (Terminal, iTerm2, Xcode, VS Code, Cursor, JetBrains, Obsidian в блоках кода и др.) отключены автоматически.", .en: "Terminals and code editors (Terminal, iTerm2, Xcode, VS Code, Cursor, JetBrains, etc.) are excluded automatically."],

        "typo.sec.sandbox":           [.ru: "Попробовать", .en: "Try it"],
        "typo.sandbox.desc":          [.ru: "Изолированная область внутри настроек: проверьте живой набор и очистку текста с текущими правилами.", .en: "Isolated sandbox inside Settings to test live typing rules and selection formatting safely."],
        "typo.sandbox.initial":       [.ru: "Наберите: Он сказал \"Привет, мир\" и добавил: это -- 10 кг и 25 % (c)", .en: "Type or edit: Он сказал \"Привет, мир\" и добавил: это -- 10 кг и 25 % (c)"],
        "typo.sandbox.formatNow":     [.ru: "Исправить всё", .en: "Format all"],
        "typo.sandbox.undo":          [.ru: "Отменить последнее", .en: "Undo last"],
        "typo.sandbox.sampleQuotes":  [.ru: "Пример: текст", .en: "Sample: prose"],
        "typo.sandbox.sampleCode":    [.ru: "Пример: код", .en: "Sample: code"],
        "typo.sandbox.clear":         [.ru: "Очистить", .en: "Clear"],
        "typo.sandbox.ready":         [.ru: "Готово к проверке: введите пробел, кавычку или нажмите «Исправить всё».", .en: "Ready: type a space/quote or click Format all."],
        "typo.sandbox.noChanges":     [.ru: "Изменений не требуется (правила не сработали или фрагмент защищён).", .en: "No changes needed (rules skipped or text protected)."],
        "typo.sandbox.undone":        [.ru: "Последнее изменение в песочнице отменено.", .en: "Last sandbox edit undone."],
        "typo.sandbox.sampleLoaded":  [.ru: "Пример загружен — нажмите «Исправить всё» или допечатайте текст.", .en: "Sample loaded — click Format all or continue typing."],
        "typo.sandbox.applied":       [.ru: "Сработало: %@ (неразрывных пробелов: %d)", .en: "Applied: %@ (NBSP count: %d)"],

        "typo.sel.title":             [.ru: "Умная типографика", .en: "Smart Typography"],
        "typo.sel.secure":            [.ru: "Поле защищено (Secure Input) — изменение невозможно.", .en: "Protected input (Secure Input) — cannot edit."],
        "typo.sel.geckoMultiline":    [.ru: "Выделение недоступно в многострочном поле через Accessibility (буфер обмена не используется).", .en: "Selection unavailable via Accessibility here (clipboard untouched)."],
        "typo.sel.noSelection":       [.ru: "Выделенный текст не прочитан через Accessibility.", .en: "Could not read selected text via Accessibility."],
        "typo.sel.noChanges":         [.ru: "Выделенный текст уже в порядке или защищён правилами безопасности.", .en: "Selected text already clean or protected by safety rules."],

        "typo.preview.title":         [.ru: "Предпросмотр типографики", .en: "Typography Preview"],
        "typo.preview.summary":       [.ru: "Изменений: %d • %@", .en: "Changes: %d • %@"],
        "typo.preview.before":        [.ru: "Было", .en: "Before"],
        "typo.preview.after":         [.ru: "Стало", .en: "After"],
        "typo.preview.apply":         [.ru: "Применить", .en: "Apply"],

        // KB-022 · Очередь вставки
        "pq.tab.history":       [.ru: "История", .en: "History"],
        "pq.tab.queue":         [.ru: "Очередь", .en: "Queue"],
        "pq.empty":             [.ru: "Очередь пуста", .en: "The queue is empty"],
        "pq.completed":         [.ru: "Очередь завершена: %d из %d", .en: "Queue finished: %d of %d"],
        "pq.progress":          [.ru: "%d / %d · Следующий элемент: %@", .en: "%d / %d · Next item: %@"],
        "pq.sentUnconfirmed":   [.ru: "Отправлено, подтверждение недоступно · %d / %d · Следующий: %@",
                                 .en: "Sent, confirmation unavailable · %d / %d · Next: %@"],
        "pq.partial":           [.ru: "Вставка могла выполниться частично. Очередь на паузе",
                                 .en: "The paste may have been partial. The queue is paused"],
        "pq.picked":            [.ru: "Элемент вставлен", .en: "Item pasted"],
        "pq.pickedUnconfirmed": [.ru: "Отправлено, подтверждение недоступно", .en: "Sent, confirmation unavailable"],
        "pq.allSent":           [.ru: "Вставлено одним блоком: %d", .en: "Pasted as one block: %d"],
        "pq.refused.paused":    [.ru: "Очередь на паузе после частичной вставки", .en: "The queue is paused after a partial paste"],
        "pq.refused.busy":      [.ru: "Предыдущая вставка ещё идёт", .en: "The previous paste is still running"],
        "pq.refused.keyboopPaused": [.ru: "Keyboop на паузе", .en: "Keyboop is paused"],
        "pq.refused.secureInput": [.ru: "Поле пароля: вставка через Keyboop недоступна", .en: "Password field: Keyboop cannot paste here"],
        "pq.refused.ownWindow": [.ru: "Курсор в окне Keyboop — встаньте в нужное поле", .en: "The cursor is in a Keyboop window — click the target field"],
        "pq.refused.noFocus":   [.ru: "Не найдено поле ввода — щёлкните в нужное поле", .en: "No text field found — click the target field"],
        "pq.refused.keyboopOff":[.ru: "Keyboop выключен для этой программы", .en: "Keyboop is turned off for this app"],
        "pq.refused.unsupportedTarget": [.ru: "Это поле не поддерживает прямую вставку Keyboop", .en: "This field does not support Keyboop’s direct paste"],
        "pq.refused.notFound":  [.ru: "Элемент уже удалён", .en: "The item has been removed"],
        "pq.added":             [.ru: "Добавлено в очередь: %d · всего %d", .en: "Added to the queue: %d · total %d"],
        "pq.skipped":           [.ru: " · пропущено: %d", .en: " · skipped: %d"],
        "pq.add.empty":         [.ru: "Пустой текст в очередь не добавлен", .en: "Empty text was not added"],
        "pq.add.tooLarge":      [.ru: "Элемент больше 64 КиБ — не добавлен", .en: "The item is larger than 64 KiB — not added"],
        "pq.add.queueFull":     [.ru: "В очереди уже 50 элементов", .en: "The queue already has 50 items"],
        "pq.add.concealed":     [.ru: "Скрытое содержимое (менеджер паролей) не добавлено", .en: "Concealed content (password manager) was not added"],
        "pq.add.secureInput":   [.ru: "Открыто поле пароля — буфер не читаем", .en: "A password field is open — the clipboard is not read"],
        "pq.add.noText":        [.ru: "В буфере нет текста", .en: "There is no text on the clipboard"],
        "pq.add.selectionUnavailable": [.ru: "Выделение не прочитано через Accessibility", .en: "Could not read the selection via Accessibility"],
        "pq.state.pending":     [.ru: "Ожидает", .en: "Waiting"],
        "pq.state.next":        [.ru: "Следующий", .en: "Next"],
        "pq.state.confirmed":   [.ru: "Вставлено", .en: "Pasted"],
        "pq.state.sent":        [.ru: "Отправлено", .en: "Sent"],
        "pq.state.partial":     [.ru: "Частично", .en: "Partial"],
        "pq.col.num":           [.ru: "№", .en: "#"],
        "pq.col.text":          [.ru: "Текст", .en: "Text"],
        "pq.col.state":         [.ru: "Состояние", .en: "Status"],
        "pq.btn.addClipboard":  [.ru: "Добавить из буфера", .en: "Add from clipboard"],
        "pq.btn.addHistory":    [.ru: "Из истории…", .en: "From history…"],
        "pq.btn.up":            [.ru: "Выше (⌥↑)", .en: "Move up (⌥↑)"],
        "pq.btn.down":          [.ru: "Ниже (⌥↓)", .en: "Move down (⌥↓)"],
        "pq.btn.edit":          [.ru: "Просмотреть и изменить (↩)", .en: "View and edit (↩)"],
        "pq.btn.remove":        [.ru: "Удалить (⌫)", .en: "Remove (⌫)"],
        "pq.btn.private":       [.ru: "Скрыть содержимое", .en: "Hide contents"],
        "pq.btn.makeNext":      [.ru: "Сделать следующим", .en: "Make next"],
        "pq.btn.back":          [.ru: "На шаг назад", .en: "Step back"],
        "pq.btn.restart":       [.ru: "Начать сначала", .en: "Start over"],
        "pq.btn.clear":         [.ru: "Очистить", .en: "Clear"],
        "pq.btn.resume":        [.ru: "Продолжить", .en: "Resume"],
        "pq.btn.pasteNext":     [.ru: "Вставить следующий", .en: "Paste next"],
        "pq.btn.pastePicked":   [.ru: "Вставить выбранный", .en: "Paste selected"],
        "pq.btn.pasteAll":      [.ru: "Вставить все…", .en: "Paste all…"],
        "pq.indicator.empty":   [.ru: "Очередь пуста. Добавьте элементы из буфера или истории",
                                 .en: "The queue is empty. Add items from the clipboard or history"],
        "pq.indicator.paused":  [.ru: "Вставка могла выполниться частично — очередь на паузе. Проверьте поле и нажмите «Продолжить»",
                                 .en: "The paste may have been partial — the queue is paused. Check the field and press Resume"],
        "pq.hint.key":          [.ru: "Сочетание: %@ · ⌘V работает как обычно", .en: "Shortcut: %@ · ⌘V works as usual"],
        "pq.hint.noKey":        [.ru: "Сочетание не назначено: Настройки → Автозамена → Очередь вставки",
                                 .en: "No shortcut assigned: Settings → Autoreplace → Paste queue"],
        "pq.hint.private":      [.ru: "Очередь живёт только в памяти и исчезает при выходе из Keyboop",
                                 .en: "The queue lives only in memory and disappears when Keyboop quits"],
        "pq.edit.title":        [.ru: "Элемент очереди", .en: "Queue item"],
        "pq.edit.save":         [.ru: "Сохранить", .en: "Save"],
        "pq.cancel":            [.ru: "Отмена", .en: "Cancel"],
        "pq.history.title":     [.ru: "Добавить из истории", .en: "Add from history"],
        "pq.history.hint":      [.ru: "Выберите несколько записей (⌘ или ⇧ + щелчок, ⌘A)", .en: "Select several entries (⌘ or ⇧ + click, ⌘A)"],
        "pq.history.add":       [.ru: "Добавить выбранные", .en: "Add selected"],
        "pq.history.empty":     [.ru: "В истории пока нет записей", .en: "History is empty"],
        "pq.history.locked":    [.ru: "История под паролем — откройте её окно", .en: "History is locked — open its window first"],
        "pq.all.title":         [.ru: "Вставить все элементы одним блоком", .en: "Paste all items as one block"],
        "pq.all.delimiter":     [.ru: "Разделитель (\\n — новая строка)", .en: "Separator (\\n is a new line)"],
        "pq.all.go":            [.ru: "Вставить", .en: "Paste"],
        "pq.card.add":          [.ru: "Добавить в очередь", .en: "Add to queue"],
        "menu.pq":              [.ru: "Очередь вставки", .en: "Paste queue"],
        "menu.pq.next":         [.ru: "Вставить следующий элемент", .en: "Paste next item"],
        "menu.pq.addClipboard": [.ru: "Добавить содержимое буфера в очередь", .en: "Add clipboard contents to queue"],
        "menu.pq.addSelection": [.ru: "Добавить выделение в очередь", .en: "Add selection to queue"],
        "menu.pq.open":         [.ru: "Открыть очередь…", .en: "Open queue…"],
        "menu.pq.restart":      [.ru: "Начать сначала", .en: "Start over"],
        "menu.pq.clear":        [.ru: "Очистить очередь", .en: "Clear queue"],
        "pq.section":           [.ru: "ОЧЕРЕДЬ ВСТАВКИ", .en: "PASTE QUEUE"],
        "pq.set.hotkey":        [.ru: "Вставлять следующий элемент очереди", .en: "Paste the next queue item"],
        "pq.set.hotkeySub":     [.ru: "Своё сочетание; ⌘V не перехватывается", .en: "A separate shortcut; ⌘V is never intercepted"],
        "pq.set.help":          [.ru: "Соберите в очередь несколько значений (из истории, буфера или выделения) и вставляйте их по одному в разные поля одним сочетанием. Очередь хранится только в памяти, в логи не пишется и исчезает при выходе. Текст печатается напрямую, буфер обмена не подменяется; переводы строк вставляются как текст, а не нажатием Enter.",
                                 .en: "Collect several values in a queue (from history, the clipboard or a selection) and paste them one by one into different fields with one shortcut. The queue lives only in memory, is never logged and disappears on quit. Text is typed directly without swapping the clipboard; line breaks are inserted as text, not as Enter presses."],
        "pq.set.assign":        [.ru: "Сочетание", .en: "Shortcut"],
        "pq.set.completion":    [.ru: "После последнего элемента", .en: "After the last item"],
        "pq.set.keep":          [.ru: "Оставить очередь и позицию", .en: "Keep the queue and position"],
        "pq.set.restart":       [.ru: "Начать сначала", .en: "Start over"],
        "pq.set.clear":         [.ru: "Очистить очередь", .en: "Clear the queue"],
        "pq.set.manual":        [.ru: "Ручная вставка двигает позицию", .en: "Manual paste moves the position"],
        "pq.set.manualSub":     [.ru: "Вставка выбранного элемента из окна очереди", .en: "Pasting a chosen item from the queue window"],
        "hkrec.what.pasteQueue":[.ru: "вставка следующего элемента очереди", .en: "paste the next queue item"],
        "is.busy.pasteQueue":   [.ru: "вставка из очереди", .en: "pasting from the queue"]
    ]
}
