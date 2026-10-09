"""Pub/sub for trace/run events and the UI request bridge (ask/show/confirm)."""
import asyncio


class Subscribers:
    def __init__(self):
        self.subs = []                  # (topics:set, queue)

    def subscribe(self, topics=None):
        q = asyncio.Queue(maxsize=1000)
        self.subs.append((set(topics) if topics else None, q))
        return q

    def unsubscribe(self, q):
        self.subs = [(t, x) for t, x in self.subs if x is not q]

    def publish(self, topic, msg):
        for topics, q in list(self.subs):
            if topics is None or topic in topics:
                try:
                    q.put_nowait(msg)
                except asyncio.QueueFull:
                    pass


class NullUiBridge:
    """No shell connected: every request is unanswered (the engine then falls back or cancels)."""

    async def request(self, kind, payload, timeout=3.0):
        return None
