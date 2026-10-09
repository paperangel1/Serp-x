"""Time source of the engine; the fake one makes delays and the loop guard testable without waiting."""
import asyncio
import time


class RealClock:
    def now(self):
        return time.time()

    async def sleep(self, seconds):
        await asyncio.sleep(max(0.0, seconds))


class FakeClock:
    def __init__(self, start=1_000_000.0):
        self.t = start
        self.sleeps = []

    def now(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds

    async def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.t += max(0.0, seconds)
        await asyncio.sleep(0)
