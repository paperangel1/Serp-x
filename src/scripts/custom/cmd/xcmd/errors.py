class NodeError(Exception):
    """A node failed; the message is shown to the user (ru)."""


class EngineError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class BreakLoop(Exception):
    """Raised by «Прервать цикл»; the nearest «Для каждого» catches it."""
