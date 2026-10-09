"""Assembles the engine with its stores for the daemon, the CLI's local mode and tests."""
import os
import time
from types import SimpleNamespace

from . import paths
from .api import Api
from .debug import TraceStore
from .engine import Engine
from .fnstore import FnStore
from .model import Store
from .runlog import RunLog
from .schema import load_schema
from .state import State, UndoStore


def build(clock=None, ui=None, proc=None, commands_dir=None, state_dir=None):
    from .clock import RealClock
    clock = clock or RealClock()
    sch = load_schema()
    cdir, sdir = commands_dir or paths.commands_dir(), state_dir or paths.state_dir()
    os.makedirs(sdir, exist_ok=True)
    store = Store(cdir, history_dir=os.path.join(sdir, "history"), clock=time, trash_dir=os.path.join(sdir, "trash")).load()
    fnstore = FnStore(os.path.join(cdir, "functions"), history_dir=os.path.join(sdir, "history"), clock=time,
                      trash_dir=os.path.join(sdir, "trash")).load()
    sch.set_functions(fnstore.all())
    state, log, undo = State(sdir), RunLog(sdir, clock), UndoStore(sdir)
    engine = Engine(sch, store, state, log, undo, clock=clock, proc=proc, ui=ui, traces=TraceStore(os.path.join(sdir, "traces")))
    api = Api(engine, store, state, sch, log, fnstore)
    return SimpleNamespace(sch=sch, store=store, fnstore=fnstore, state=state, log=log, undo=undo, engine=engine, api=api, clock=clock)
