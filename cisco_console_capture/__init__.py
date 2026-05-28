"""cisco_console_capture – Capture Cisco CLI output over a serial console."""
from importlib.metadata import version, PackageNotFoundError

try:
    __version__ = version("cisco-console-capture")
except PackageNotFoundError:
    __version__ = "unknown"
