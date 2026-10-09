"""Loop guard: automations (every trigger except manual) are limited per command; exceeding the limit pauses the
command automatically (design §5/§9). Manual runs are never counted or blocked by the pause."""
import logging

log = logging.getLogger("xcmd.guard")


class Guard:
    WINDOW = 60.0

    def __init__(self, clock, state, notify=None):
        self.clock = clock
        self.state = state
        self.notify = notify            # async callable(title, body)
        self.hits = {}                  # cmd id -> [timestamps]

    async def allow(self, cmd_id, limit, name=""):
        """True when this trigger may start a run; False (and the command is paused) when the limit is exceeded."""
        now = self.clock.now()
        hits = [t for t in self.hits.get(cmd_id, []) if now - t < self.WINDOW]
        if len(hits) >= int(limit):
            self.hits[cmd_id] = hits
            self.state.pause_cmd(cmd_id, "loop_guard", now)
            log.warning("loop guard: command %s paused (%d runs in %ds)", name or cmd_id, int(limit), int(self.WINDOW))
            if self.notify:
                await self.notify("Команда «%s» приостановлена" % name,
                                  "Больше %d запусков в минуту — похоже на зацикливание. Возобновите её командой "
                                  "serpantinum-x cmd resume." % int(limit))
            return False
        hits.append(now)
        self.hits[cmd_id] = hits
        return True
