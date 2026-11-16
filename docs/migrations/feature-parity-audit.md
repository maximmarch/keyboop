# SB-MIG-007 · Аудит разделения продуктов

## Базовые ревизии

| Продукт | GitHub main | Версия и конфигурация |
|---|---|---|
| Keyboop | d1187fe8175a | 0.5.4. Package.swift заявляет macOS 13, штатная сборка arm64 с Metal — macOS 14, Intel — macOS 13 |
| SelectionBar | c3ad4d26c900 | 0.2.5, SwiftPM macOS 14+, Apple Translation macOS 15+ |
| SelectionBar с миграциями | 812f8af (локальная ветка) | SB-MIG-001–006, 442 автоматических теста на базе этапа 006 |

Checkout Keyboop был чист. В соседнем checkout SelectionBar были незакоммиченные
документы о преобразованиях. Работа ведётся в отдельных копиях. Перенесённые
функции ещё не входят в main SelectionBar.

## Матрица соответствия

| Функция | Keyboop и запуск | SelectionBar и запуск | Доказательства и решение |
|---|---|---|---|
| Раскладка выделения | Engine.convertSelection, SelectionText, хоткей через EventTap | TextTransform, действие преобразования с предпросмотром | Есть тесты преобразования и координатора. В реальных редакторах не подтверждено. No-Go |
| Регистр выделения | Engine.changeSelectionCase, ручной хоткей | TextTransform, меню преобразований | Автотесты трансформаций и доставки. Ручная приёмка открыта. No-Go |
| Типографика выделения | TypographyCoordinator.formatSelectedText, горячая клавиша, предпросмотр | TypographyEngine, TypographyViews, действие профиля | Проверены правила и технические зоны. Сфера распознавания различается. Ручная приёмка открыта. No-Go |
| Перевод выделения | Engine.translateSelection, TranslationEngine, хоткей и загрузка языков | LocalTranslationService, карточка локального перевода | Моки и слабая линковка. Реальные модели, загрузка и замена не проверены. No-Go |
| История clipboard | ClipboardWatcher, VoiceHistory, настройки и общая лента | ClipboardHistoryStore, ClipboardHistoryWindow, меню и хоткей без выделения | Автотесты хранения и повторного импорта. Нужны реальная миграция, проверка ключей и подтверждение пользователя. No-Go |
| Paste Queue | PasteQueueSystem, PasteQueuePanel, EventTap | PasteQueueController, PasteQueueView, общий HotkeyManager и координатор вставки | Тесты переходов, отказов и частичных результатов. Реальная доставка, фокус и хоткеи не подтверждены. No-Go |
| Paste Plain | PlainPaste, EventTap, самостоятельный хоткей | BuiltinAction.pastePlain, AppController, открытие панели по хоткею в редактируемом поле | Захват .hotkey/.hold допускает пустое выделение, при доставке нужен AX-диапазон длины 0. Самостоятельный хоткей и эквивалентное покрытие редакторов не подтверждены. No-Go |
| Автоматическая типографика | TypographyCoordinator, TypographyEngine, SettingsWindow, Engine при вводе | Вне назначения | Сохранить |
| Последнее слово и N слов | Engine.convertGroup/convertFromBuffer, EventTap и состояние ввода | Вне назначения | Сохранить, перед удалением ветки convertSelection проверить fallback с пустым буфером |
| Сниппеты по триггеру | Engine, SnippetTemplateParser, SnippetVariableResolver, SnippetFormController | Личные шаблоны запускаются явно | Сохранить |
| Диктовка и история | VoiceHistory, VoiceHistoryWindow, VoiceClips, голосовые контроллеры | Вне назначения | Сохранить, включая общий ключ, аудио, импорт и звонки |

Шаблоны с полями используют .insertAtCaret для пустого снимка. История открывается
из меню без выделения. Paste Next получает активный фокус независимо от панели.
Эти маршруты присутствуют в коде, запуск в пользовательском сеансе ещё требуется.

## Карта зависимостей Keyboop

- **Кандидаты на удаление после приёмки:** PasteQueueItem/Store/Coordinator/Panel,
  PasteQueueSettingsStore/System, ClipboardQueueAdapter, PlainPaste,
  ClipboardWatcher. TranslationEngine связан с Engine, SettingsWindow и
  WelcomeWindow. Перепроверить вызовы перед удалением.
- **Частичная очистка:** Engine и EventTap содержат клавиатурный движок и ветки
  пользовательских действий. MenuBarController, AppDelegate, SettingsWindow,
  AppSettings, VoiceHistoryWindow и L10n содержат общую UI-инфраструктуру.
  TypographyCoordinator участвует в типографике при наборе и её Undo.
- **Сохранить:** TextReplacer, AXScreenCheck, SecureInputPolicy, нужные сгруппированные
  возможности SelectionText, ClipboardOwnership, VoiceHistory/VoiceClips,
  TypographyEngine/ContextAnalyzer/Rule, сниппеты и ASR. Перед очисткой
  ClipboardHistoryCore выделить нужные модели общей истории и учёт владения.
- **Сохранить для перехода:** чтение старого history.enc, старый .histkey, ключ в
  Keychain, идентификацию clipboard-записей и защищённый экспорт.

## Порядок допуска

Аудит → зашифрованный экспорт → подтверждаемый импорт → проверка исходного
архива, клипов и перезапуска → отдельная приёмка каждой функции → отдельные
изменения по выводу. Удаление записей из Keyboop не входит в проверку синтетической
фикстуры. Перед выводом функций проверить режимы только Keyboop, только SelectionBar
и обе программы вместе. Частично подтверждённый импорт не означает готовность к удалению.

### KB-MIG-008 · Условия внедрения

Очистка Keyboop идёт в черновой ветке. Для смены регистра подтверждена базовая
замена в TextEdit на SelectionBar 0.2.5 (9), но полноценная проверка устаревшего
выделения не зафиксирована. Для раскладки, типографики, перевода, Paste Queue,
Paste Plain и переноса реальной истории обязательные пользовательские проверки
ещё не закрыты. Решение о merge и релизе по всем семи функциям остаётся No-Go.
