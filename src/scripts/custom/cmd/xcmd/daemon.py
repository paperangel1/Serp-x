"""serpantinum-cmdd: the engine as a long-running process (systemd --user service, design §5)."""
import asyncio
import logging
import signal
import sys

from . import paths
from .build import build
from .protocol import Server, SocketUiBridge
from .triggers import TriggerManager


class Daemon:
    def __init__(self, rt=None, socket_path=None, reload_every=2.0, sources=None):
        self.ui = SocketUiBridge()
        self.rt = rt or build(ui=self.ui)
        if rt is not None:
            self.rt.engine.ui = self.ui
        self.server = Server(self.rt.api, self.rt.engine, self.ui, socket_path or paths.socket_path())
        self.reload_every = reload_every
        self._task = None
        self.triggers = TriggerManager(self.rt.engine, self.rt.clock, sources=sources)
        self.rt.api.triggers = self.triggers

    async def start(self):
        for run, cmd, n in self.rt.undo.discard_stale():
            self.rt.log.append({"ev": "undo_discarded", "run": run, "cmd": cmd, "entries": n, "ts": self.rt.clock.now(),
                                "status": "rolled_back", "reason": "stale_undo",
                                "message": "Стек отката после перезапуска отброшен без выполнения (%s записей)" % n})
        self.rt.log.prune()
        await self.server.start()
        await self.triggers.start()
        self._task = asyncio.ensure_future(self._watch())

    async def _watch(self):
        while True:
            await asyncio.sleep(self.reload_every)
            fs = getattr(self.rt, "fnstore", None)
            if fs is not None and fs.changed():
                fs.load()
                self.rt.sch.set_functions(fs.all())
                logging.getLogger("xcmd.daemon").info("functions reloaded: %d", len(fs.fns))
            if self.rt.store.changed():
                self.rt.store.load()
                logging.getLogger("xcmd.daemon").info("commands reloaded: %d", len(self.rt.store.cmds))
                self.triggers.dirty()

    async def stop(self):
        if self._task:
            self._task.cancel()
        await self.triggers.stop()
        await self.rt.engine.cancel_all()          # every run rolls back before the process exits
        await self.server.stop()


async def serve():
    logging.basicConfig(stream=sys.stderr, level=logging.INFO, format="%(asctime)s %(levelname)s serpantinum-x:cmdd %(name)s %(message)s")
    d = Daemon()
    logging.getLogger("xcmd.daemon").info("daemon started (socket %s)", d.server.path)
    await d.start()
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    logging.getLogger("xcmd.daemon").info("daemon stopping")
    await d.stop()


def main():
    asyncio.run(serve())
