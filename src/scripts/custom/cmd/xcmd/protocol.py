"""JSON-lines protocol over a unix socket ($XDG_RUNTIME_DIR/serpantinum/cmdd.sock, mode 0600, same user only).
Request: {"id": N, "method": "...", "params": {...}}  Response: {"id": N, "ok": true, "result": ...} or
{"id": N, "ok": false, "error": {"code", "message"}}. Pushed events (after `subscribe`): {"ev": "...", ...}.
Methods: list get validate save run cancel pause resume status enable disable approve log reload pin_values import
trace traces debug_step debug_continue debug_stop debug_breakpoints debug_state (run params: rehearse, event, step, breakpoints, debug)
subscribe(topics: trace|run|ui) ui_response(id, answer...).
UI requests (event ui.request {id, kind, payload}): kind show {title,text}, confirm {node,text} -> {answer:bool},
ask {mode: choice|text|number|confirm, title, options, default, timeout, command} -> {index|value|answer} or {cancel:true}.
ui.cancel {id} tells the shell to close a request that timed out or whose run was cancelled."""
import asyncio
import json
import os
import socket
import struct

from .api import ApiError


class ProtocolError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


class SocketUiBridge:
    """Sends ui.request events to subscribed shell connections and waits for their ui_response."""

    def __init__(self):
        self.conns = set()
        self.pending = {}
        self._n = 0

    async def request(self, kind, payload, timeout=3.0):
        if not self.conns:
            return None
        self._n += 1
        rid = "ui%d" % self._n
        fut = asyncio.get_event_loop().create_future()
        self.pending[rid] = fut
        for c in list(self.conns):
            c.push({"ev": "ui.request", "id": rid, "kind": kind, "payload": payload})
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            return None
        finally:
            self.pending.pop(rid, None)
            if not fut.done() or fut.cancelled():   # timeout or the run was cancelled: close the dialog in the shell
                fut.cancel()
                for c in list(self.conns):
                    c.push({"ev": "ui.cancel", "id": rid})

    def respond(self, rid, data):
        fut = self.pending.get(rid)
        if fut and not fut.done():
            fut.set_result(data)


class Conn:
    def __init__(self, writer):
        self.writer = writer
        self.tasks = []
        self.queues = []

    def push(self, msg):
        try:
            self.writer.write((json.dumps(msg, ensure_ascii=False) + "\n").encode())
        except (ConnectionError, RuntimeError):
            pass


class Server:
    def __init__(self, api, engine, ui_bridge, path):
        self.api, self.engine, self.ui, self.path = api, engine, ui_bridge, path
        self.server = None
        self.conns = set()

    async def start(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        if os.path.exists(self.path):
            if self._alive(self.path):
                raise ProtocolError("already_running", "Демон уже запущен: сокет %s занят" % self.path)
            os.remove(self.path)
        self.server = await asyncio.start_unix_server(self._client, path=self.path)
        os.chmod(self.path, 0o600)

    @staticmethod
    def _alive(path):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(0.5)
        try:
            s.connect(path)
            return True
        except OSError:
            return False
        finally:
            s.close()

    async def stop(self):
        if self.server:
            self.server.close()
        for c in list(self.conns):
            self._drop(c)
        try:
            os.remove(self.path)
        except FileNotFoundError:
            pass

    def _drop(self, conn):
        self.conns.discard(conn)
        self.ui.conns.discard(conn)
        for q in conn.queues:
            self.engine.events.unsubscribe(q)
        for t in conn.tasks:
            t.cancel()
        try:
            conn.writer.close()
        except Exception:
            pass

    async def _client(self, reader, writer):
        sock = writer.get_extra_info("socket")
        try:
            _pid, uid, _gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            if uid != os.getuid():
                writer.close()
                return
        except OSError:
            writer.close()
            return
        conn = Conn(writer)
        self.conns.add(conn)
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                asyncio.ensure_future(self._handle(conn, line))
        except ConnectionError:
            pass
        finally:
            self._drop(conn)

    async def _handle(self, conn, line):
        try:
            req = json.loads(line)
            method, params, rid = req["method"], req.get("params") or {}, req.get("id")
        except (ValueError, KeyError, TypeError):
            conn.push({"id": None, "ok": False, "error": {"code": "bad_request", "message": "Ожидался JSON {id, method, params}"}})
            return
        try:
            if method == "subscribe":
                result = self._subscribe(conn, params.get("topics") or ["trace", "run"])
            elif method == "ui_response":
                self.ui.respond(params.get("id"), params)
                result = {}
            else:
                result = await self.api.call(method, params)
            conn.push({"id": rid, "ok": True, "result": result})
        except ApiError as e:
            conn.push({"id": rid, "ok": False, "error": {"code": e.code, "message": e.message}})
        except KeyError as e:
            conn.push({"id": rid, "ok": False, "error": {"code": "bad_params", "message": "Не хватает параметра %s" % e}})
        except Exception as e:
            conn.push({"id": rid, "ok": False, "error": {"code": "internal", "message": "%s: %s" % (type(e).__name__, e)}})

    def _subscribe(self, conn, topics):
        engine_topics = [t for t in topics if t in ("trace", "run", "event")]
        if engine_topics:
            q = self.engine.events.subscribe(engine_topics)
            conn.queues.append(q)
            conn.tasks.append(asyncio.ensure_future(self._pump(conn, q)))
        if "ui" in topics:
            self.ui.conns.add(conn)
        return {"topics": topics}

    async def _pump(self, conn, q):
        while True:
            conn.push(await q.get())


class ClientError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


class Client:
    """Blocking client for the CLI and for tests."""

    def __init__(self, path, timeout=30.0):
        self.path, self.timeout = path, timeout
        self.sock = None
        self.buf = b""
        self.n = 0

    def connect(self):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(self.timeout)
        s.connect(self.path)
        self.sock = s
        return self

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None

    def _line(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ClientError("closed", "Демон закрыл соединение")
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        return json.loads(line)

    def call(self, method, params=None, timeout=None):
        if self.sock is None:
            self.connect()
        if timeout is not None:
            self.sock.settimeout(timeout)
        self.n += 1
        self.sock.sendall((json.dumps({"id": self.n, "method": method, "params": params or {}}) + "\n").encode())
        while True:
            msg = self._line()
            if msg.get("id") == self.n:
                if msg.get("ok"):
                    return msg.get("result")
                err = msg.get("error", {})
                raise ClientError(err.get("code", "error"), err.get("message", ""))

    def events(self):
        while True:
            yield self._line()
