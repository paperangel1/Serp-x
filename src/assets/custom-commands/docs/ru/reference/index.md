<!-- Файл создан автоматически из схемы узлов; не правьте его руками. -->

# Справочник узлов «Команд»

## Действия
- [Gemini](action.md) — `action.ai.gemini@1`
- [Микрофон](action.md) — `action.audio.mic_mute@1`
- [Устройство вывода звука](action.md) — `action.audio.set_output@1`
- [Громкость](action.md) — `action.audio.set_volume@1`
- [Записать в буфер обмена](action.md) — `action.clipboard_set@1`
- [Архивировать](action.md) — `action.file.archive@1`
- [Конвертировать картинки](action.md) — `action.file.convert_image@1`
- [Переместить или копировать файл](action.md) — `action.file.move@1`
- [Переименовать файл](action.md) — `action.file.rename@1`
- [HTTP-запрос](action.md) — `action.http.request@1`
- [Управление плеером](action.md) — `action.media.control@1`
- [Уведомление](action.md) — `action.notify@1`
- [Открыть ссылку](action.md) — `action.open_link@1`
- [Снимок экрана](action.md) — `action.screenshot@1`
- [Команда на сервере](action.md) — `action.server.run@1`
- [Выполнить команду оболочки](action.md) — `action.shell@1`
- [Панель: показать или спрятать](action.md) — `action.shell.bar@1`
- [Яркость экрана](action.md) — `action.shell.brightness@1`
- [Не беспокоить](action.md) — `action.shell.dnd@1`
- [Ночной фильтр](action.md) — `action.shell.night_filter@1`
- [Тёмная или светлая тема](action.md) — `action.shell.theme@1`
- [Сменить обои](action.md) — `action.shell.wallpaper@1`
- [Таймер](action.md) — `action.timer@1`
- [VPN](action.md) — `action.vpn.set@1`
- [Расставить окна](action.md) — `action.window.arrange@1`
- [Закрыть окно](action.md) — `action.window.close@1`
- [Открыть приложение](action.md) — `action.window.open_app@1`

## Данные
- [Текст → Число](data.md) — `convert.to_int@1`
- [Любое → Текст](data.md) — `convert.to_text@1`
- [И](data.md) — `data.and@1`
- [Сравнить числа](data.md) — `data.compare_number@1`
- [Сравнить тексты](data.md) — `data.compare_text@1`
- [Склеить текст](data.md) — `data.concat@1`
- [Вид файла](data.md) — `data.file_kind@1`
- [Подставить в шаблон](data.md) — `data.format@1`
- [Прочитать переменную](data.md) — `data.get_var@1`
- [Склеить список](data.md) — `data.join@1`
- [Элемент списка](data.md) — `data.list_get@1`
- [Длина списка](data.md) — `data.list_length@1`
- [Арифметика](data.md) — `data.math@1`
- [Не](data.md) — `data.not@1`
- [Или](data.md) — `data.or@1`
- [Числа подряд](data.md) — `data.range@1`
- [Выбранные файлы](data.md) — `data.selected_files@1`
- [Выделенный текст](data.md) — `data.selected_text@1`
- [Разбить текст](data.md) — `data.split@1`

## События
- [Приложение закрыто](event.md) — `event.app_closed@1`
- [Приложение открыто](event.md) — `event.app_opened@1`
- [Наушники подключены](event.md) — `event.audio.headphones_connected@1`
- [Наушники отключены](event.md) — `event.audio.headphones_disconnected@1`
- [Bluetooth-устройство](event.md) — `event.bluetooth.device@1`
- [Скопирован цвет](event.md) — `event.clipboard.color@1`
- [Скопирована ссылка](event.md) — `event.clipboard.link@1`
- [Скопирован телефон](event.md) — `event.clipboard.phone@1`
- [Новый файл в папке](event.md) — `event.folder.new_file@1`
- [Бездействие](event.md) — `event.idle@1`
- [Возвращение после бездействия](event.md) — `event.idle_return@1`
- [Каждые N минут](event.md) — `event.interval@1`
- [Экран заблокирован](event.md) — `event.lock@1`
- [Вход в систему](event.md) — `event.login@1`
- [Вручную](event.md) — `event.manual@1`
- [Монитор подключён](event.md) — `event.monitor_added@1`
- [Монитор отключён](event.md) — `event.monitor_removed@1`
- [Пришло уведомление](event.md) — `event.notification.received@1`
- [Сервер снова доступен](event.md) — `event.server.recovered@1`
- [Сервер недоступен](event.md) — `event.server.unreachable@1`
- [Рассвет или закат](event.md) — `event.sun@1`
- [В заданное время](event.md) — `event.time_at@1`
- [Экран разблокирован](event.md) — `event.unlock@1`
- [USB-устройство подключено](event.md) — `event.usb.connected@1`
- [VPN изменился](event.md) — `event.vpn.changed@1`
- [Wi-Fi подключён](event.md) — `event.wifi.connected@1`
- [Wi-Fi отключён](event.md) — `event.wifi.disconnected@1`
- [Смена рабочего стола](event.md) — `event.workspace@1`

## Логика
- [Спросить меня](logic.md) — `logic.ask@1`
- [Прервать цикл](logic.md) — `logic.break@1`
- [Задержка](logic.md) — `logic.delay@1`
- [Для каждого](logic.md) — `logic.foreach@1`
- [Если](logic.md) — `logic.if@1`
- [Увеличить переменную](logic.md) — `logic.increment@1`
- [Записать переменную](logic.md) — `logic.set_var@1`
- [Ждать событие](logic.md) — `logic.wait_event@1`

## Интерфейс
- [Показать результат](ui.md) — `ui.show_result@1`

