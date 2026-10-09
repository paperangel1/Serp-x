package plain

type msg struct{ ru, en string }

var msgs = map[string]msg{
	"plan":        {"План: шагов %d", "Plan: %d steps"},
	"eta":         {"осталось %s", "left %s"},
	"ok":          {"готово", "done"},
	"skipped":     {"пропущено", "skipped"},
	"fail":        {"ОШИБКА", "FAILED"},
	"finish.ok":   {"Установка завершена.", "Installation finished."},
	"finish.fail": {"Установка не завершена. Журнал сохранён, можно продолжить через --resume.", "Installation did not finish. The journal is kept, continue with --resume."},
	"opt.retry":   {"повторить", "retry"},
	"opt.skip":    {"пропустить модуль", "skip module"},
	"opt.abort":   {"прервать", "abort"},
	"ask.error":   {"Шаг %s не удался. Что делать?", "Step %s failed. What now?"},
	"yn":          {"[д/Н]", "[y/N]"},
	"auto.yes":    {"да (--yes)", "yes (--yes)"},
	"preflight":   {"Проверка системы:", "System check:"},
	"retype":      {"Введи заново (секреты не входят в бэкап):", "Enter again (secrets are not part of a backup):"},
}
