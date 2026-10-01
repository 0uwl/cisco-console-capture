#!/usr/bin/env python3
"""
cisco_console_capture.main
---------------------------
Detects active serial TTY devices via udev (Linux only), connects to a Cisco
device over serial using pyserial, sends diagnostic commands, and writes the
output to a timestamped text file.
"""

import argparse
import getpass
import re
import sys
import time
from datetime import datetime
from pathlib import Path

from cisco_console_capture import __version__

# -- ANSI colors --------------------------------------------------------------
_R  = "\033[0m"    # reset
_B  = "\033[1m"    # bold
_DM = "\033[2m"    # dim
_RE = "\033[31m"   # red
_GR = "\033[32m"   # green
_YL = "\033[33m"   # yellow
_CY = "\033[36m"   # cyan
_MG = "\033[35m"   # magenta

# -- Guard: Linux only --------------------------------------------------------
if sys.platform != "linux":
    sys.exit(f"{_RE}ERROR: This script only runs on Linux.{_R}")

try:
    import serial
except ImportError:
    sys.exit(f"{_RE}ERROR: pyserial is not installed.  Run: pip install pyserial{_R}")

try:
    import pyudev
except ImportError:
    sys.exit(f"{_RE}ERROR: pyudev is not installed.  Run: pip install pyudev{_R}")


# -- Constants ----------------------------------------------------------------
COMMANDS = [
    "show run brief",
    "show interfaces status",
]

DEFAULT_BAUD    = 9600
READ_TIMEOUT    = 15      # seconds to wait for a prompt / output
INTER_CMD_DELAY = 0.5     # seconds between writes
MORE_PATTERN    = re.compile(r"--More--|--- more ---", re.IGNORECASE)
PROMPT_PATTERN  = re.compile(r"[>#]\s*$")


# -- udev helpers -------------------------------------------------------------

def discover_serial_ports() -> list[dict]:
    """
    Use pyudev to enumerate connected TTY devices that look like serial
    adapters (USB-serial, built-in UARTs, etc.).
    """
    context = pyudev.Context()
    ports = []

    for device in context.list_devices(subsystem="tty"):
        dev_node = device.get("DEVNAME")
        if not dev_node:
            continue

        name = Path(dev_node).name
        if not re.match(r"tty(USB|ACM)\d*", name):
            continue

        parts = []
        for key in ("ID_VENDOR", "ID_MODEL", "ID_SERIAL_SHORT"):
            val = device.get(key)
            if val:
                parts.append(val.replace("_", " "))

        if not Path(dev_node).exists():
            continue

        vendor = device.get("ID_VENDOR", "")
        description = " \u2013 ".join(parts) if parts else "Serial device"
        ports.append({
            "device": dev_node,
            "description": description,
            "is_cisco": "cisco" in vendor.lower(),
        })

    return sorted(ports, key=lambda p: p["device"])


def select_port(ports: list[dict]) -> str:
    """Auto-select a Cisco device if unambiguous, otherwise prompt the user."""
    if not ports:
        sys.exit(
            f"{_RE}No serial TTY devices found via udev.\n"
            f"Check that your USB-serial adapter is connected and "
            f"your user is in the 'dialout' group.{_R}"
        )

    cisco_ports = [p for p in ports if p["is_cisco"]]
    if len(cisco_ports) == 1:
        p = cisco_ports[0]
        print(f"{_GR}{_B}Auto-selected Cisco device:{_R} {p['device']}  {_DM}({p['description']}){_R}")
        return p["device"]

    print(f"\n{_CY}{_B}Detected serial ports:{_R}")
    for i, p in enumerate(ports, start=1):
        print(f"  {_B}[{i}]{_R} {p['device']}  {_DM}({p['description']}){_R}")

    while True:
        raw = input(f"\n{_YL}Select port [1-{len(ports)}]: {_R}").strip()
        if raw.isdigit() and 1 <= int(raw) <= len(ports):
            return ports[int(raw) - 1]["device"]
        print(f"{_RE}Invalid choice, try again.{_R}")


# -- Serial I/O helpers -------------------------------------------------------

def read_until_prompt(ser: serial.Serial, timeout: float = READ_TIMEOUT) -> str:
    """
    Read bytes until a Cisco CLI prompt (# or >) is detected or timeout
    expires.  Automatically pages through --More-- prompts.
    """
    buf = ""
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        chunk = ser.read(ser.in_waiting or 1).decode("utf-8", errors="replace")
        if chunk:
            buf += chunk
            deadline = time.monotonic() + timeout

            if MORE_PATTERN.search(buf):
                ser.write(b" ")
                buf = buf[: MORE_PATTERN.search(buf).start()]

            if PROMPT_PATTERN.search(buf):
                break

        time.sleep(0.05)

    return buf


def send_command(ser: serial.Serial, cmd: str) -> str:
    """Send a single command and return the full output."""
    ser.write((cmd + "\r\n").encode("utf-8"))
    time.sleep(INTER_CMD_DELAY)
    return read_until_prompt(ser)


def login(
    ser: serial.Serial,
    username: str | None,
    password: str | None,
    enable_password: str | None,
) -> None:
    """Handle login, enter privileged EXEC mode, and disable pagination."""
    ser.write(b"\r\n")
    time.sleep(1)
    banner = ser.read(ser.in_waiting or 256).decode("utf-8", errors="replace")

    if re.search(r"[Uu]sername\s*:", banner):
        if not username:
            username = input("Username: ").strip()
        ser.write((username + "\r\n").encode())
        time.sleep(0.5)

    combined = banner + ser.read(ser.in_waiting or 256).decode("utf-8", errors="replace")
    if re.search(r"[Pp]assword\s*:", combined):
        if not password:
            password = getpass.getpass("Password: ")
        ser.write((password + "\r\n").encode())
        time.sleep(1)

    time.sleep(1)
    ser.read(ser.in_waiting or 1)

    ser.write(b"enable\r\n")
    time.sleep(INTER_CMD_DELAY)
    enable_buf = ser.read(ser.in_waiting or 256).decode("utf-8", errors="replace")

    if re.search(r"[Pp]assword\s*:", enable_buf):
        if not enable_password:
            enable_password = getpass.getpass("Enable password: ")
        ser.write((enable_password + "\r\n").encode())
        time.sleep(1)
        ser.read(ser.in_waiting or 1)

    ser.write(b"terminal length 0\r\n")
    time.sleep(0.5)
    ser.read(ser.in_waiting or 1)


def get_hostname(ser: serial.Serial) -> str | None:
    """Return the device hostname parsed from the CLI prompt, or None."""
    ser.write(b"\r\n")
    buf = read_until_prompt(ser, timeout=5)
    match = re.search(r"([A-Za-z0-9._-]+)\s*[#>]\s*$", buf)
    return match.group(1) if match else None


# -- Output -------------------------------------------------------------------

def write_output(results: dict[str, str], output_path: Path) -> None:
    """Write collected command outputs to a text file."""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines = [
        "=" * 70,
        f"  Cisco Serial Capture  \u2013  {ts}",
        "=" * 70,
        "",
    ]

    for cmd, output in results.items():
        lines += [
            "-" * 70,
            f"  COMMAND: {cmd}",
            "-" * 70,
            output.strip(),
            "",
        ]

    output_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n{_GR}{_B}Output written to:{_R} {output_path.resolve()}")


# -- CLI -----------------------------------------------------------------------

class _Formatter(argparse.RawDescriptionHelpFormatter, argparse.ArgumentDefaultsHelpFormatter):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="console-capture",
        description="Send Cisco CLI commands over a serial console and capture output.",
        formatter_class=_Formatter,
        epilog="""examples:
  console-capture
      auto-detect port, prompt for credentials, save to <hostname>_<timestamp>.txt

  console-capture -p /dev/ttyUSB0 -u admin
      specify port and username (password prompted securely)

  console-capture -c "show version" -c "show ip route" -c "show ip interface brief"
      run custom commands instead of the defaults

  console-capture -p /dev/ttyUSB0 -o capture.txt
      save output to a specific file

  console-capture -d /tmp/captures
      save auto-named output to /tmp/captures/<hostname>_<timestamp>.txt

  console-capture -f commands.txt
      run commands listed in a file instead of the defaults""",
    )
    parser.add_argument(
        "--port", "-p",
        help="Serial device path (e.g. /dev/ttyUSB0). Auto-detected via udev if omitted.",
    )
    parser.add_argument(
        "--baud", "-b",
        type=int,
        default=DEFAULT_BAUD,
        help="Baud rate",
    )
    parser.add_argument(
        "--username", "-u",
        default=None,
        help="Login username (prompted interactively if needed and not supplied)",
    )
    parser.add_argument(
        "--password", "-P",
        default=None,
        help="Login password (prompted securely if needed and not supplied)",
    )
    parser.add_argument(
        "--enable-password", "-e",
        default=None,
        help="Enable mode password (prompted securely if the device asks and not supplied)",
    )
    parser.add_argument(
        "--output", "-o",
        default=None,
        help="Output file path (default: <hostname>_<timestamp>.txt)",
    )
    parser.add_argument(
        "--output-dir", "-d",
        default=None,
        metavar="DIR",
        help="Directory for the auto-named output file (ignored if --output is given; default: current directory)",
    )
    parser.add_argument(
        "--command", "-c",
        dest="commands",
        metavar="CMD",
        action="append",
        help=(
            "CLI command to run on the device. "
            "May be repeated for multiple commands. "
            f"Defaults to: {COMMANDS}"
        ),
    )
    parser.add_argument(
        "--command-file", "-f",
        default=None,
        metavar="FILE",
        help=(
            "Path to a text file with one CLI command per line. "
            "Blank lines and lines starting with '#' are ignored. "
            "Commands from this file are combined with any --command values; "
            "together they replace the defaults."
        ),
    )
    parser.add_argument(
        "--version", "-v",
        action="version",
        version=f"%(prog)s {__version__}",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    ser = None
    results: dict[str, str] = {}
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_path = Path(args.output) if args.output else None
    output_dir = Path(args.output_dir) if (args.output_dir and not args.output) else None

    file_commands: list[str] = []
    if args.command_file:
        cmd_file = Path(args.command_file)
        if not cmd_file.is_file():
            sys.exit(f"{_RE}ERROR: Command file {str(cmd_file)!r} does not exist.{_R}")
        file_commands = [
            line.strip()
            for line in cmd_file.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        if not file_commands:
            sys.exit(f"{_RE}ERROR: Command file {str(cmd_file)!r} contains no commands.{_R}")
    commands = file_commands + (args.commands or []) or COMMANDS

    try:
        if output_dir is not None and not output_dir.is_dir():
            sys.exit(f"{_RE}ERROR: Output directory {str(output_dir)!r} does not exist.{_R}")

        # Resolve port
        if args.port:
            port = args.port
            if not Path(port).exists():
                sys.exit(f"{_RE}ERROR: Device {port!r} does not exist.{_R}")
            print(f"{_CY}Using specified port:{_R} {port}")
        else:
            print(f"{_CY}Scanning for serial TTY devices via udev \u2026{_R}")
            ports = discover_serial_ports()
            port = select_port(ports)

        print(f"\n{_B}Commands to be sent ({len(commands)}):{_R}")
        for cmd in commands:
            print(f"  {_DM}{cmd}{_R}")

        # Connect + execute (retry loop on serial errors)
        while True:
            print(f"\n{_CY}Connecting to {port} at {args.baud} baud \u2026{_R}")
            try:
                ser = serial.Serial(
                    port=port,
                    baudrate=args.baud,
                    bytesize=serial.EIGHTBITS,
                    parity=serial.PARITY_NONE,
                    stopbits=serial.STOPBITS_ONE,
                    timeout=1,
                    xonxoff=False,
                    rtscts=False,
                    dsrdtr=False,
                )
            except serial.SerialException as exc:
                print(f"\n{_RE}ERROR: Could not open {port}: {exc}{_R}")
                input(
                    f"{_YL}Close any applications using this port (e.g. minicom) "
                    f"and press Enter to retry, or Ctrl+C to quit: {_R}"
                )
                continue

            try:
                print(f"{_CY}Connected. Attempting login \u2026{_R}")
                login(ser, args.username, args.password, args.enable_password)
                print(f"{_GR}{_B}Login successful.{_R}")

                if output_path is None:
                    hostname = get_hostname(ser)
                    prefix = hostname if hostname else "cisco_output"
                    filename = f"{prefix}_{ts}.txt"
                    output_path = (output_dir / filename) if output_dir else Path(filename)

                print(f"\n{_CY}Sending commands \u2026{_R}")
                results = {}
                for cmd in commands:
                    print(f"  {_MG}\u2192{_R} {cmd}")
                    results[cmd] = send_command(ser, cmd)

                break  # all commands completed successfully

            except serial.SerialException as exc:
                ser.close()
                ser = None
                print(f"\n{_RE}Serial error: {exc}{_R}")
                input(
                    f"{_YL}Close any applications using this port (e.g. minicom) "
                    f"and press Enter to retry, or Ctrl+C to quit: {_R}"
                )

    except KeyboardInterrupt:
        print(f"\n{_YL}Interrupted.{_R}")
    finally:
        if ser is not None:
            ser.close()
            print(f"{_DM}Serial port closed.{_R}")

    if results:
        fallback = (output_dir or Path()) / f"cisco_output_{ts}.txt"
        write_output(results, output_path or fallback)
    else:
        print(f"{_YL}No output captured.{_R}")


if __name__ == "__main__":
    main()
