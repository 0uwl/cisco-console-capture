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

# -- Guard: Linux only --------------------------------------------------------
if sys.platform != "linux":
    sys.exit("ERROR: This script only runs on Linux.")

try:
    import serial
except ImportError:
    sys.exit("ERROR: pyserial is not installed.  Run: pip install pyserial")

try:
    import pyudev
except ImportError:
    sys.exit("ERROR: pyudev is not installed.  Run: pip install pyudev")


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
        if not re.match(r"tty(USB|ACM|AMA|XR|S[0-9])\d*", name):
            continue

        parts = []
        for key in ("ID_VENDOR", "ID_MODEL", "ID_SERIAL_SHORT"):
            val = device.get(key)
            if val:
                parts.append(val.replace("_", " "))

        if not Path(dev_node).exists():
            continue

        description = " \u2013 ".join(parts) if parts else "Serial device"
        ports.append({"device": dev_node, "description": description})

    return sorted(ports, key=lambda p: p["device"])


def select_port(ports: list[dict]) -> str:
    """Prompt the user to choose from the discovered ports."""
    if not ports:
        sys.exit(
            "No serial TTY devices found via udev.\n"
            "Check that your USB-serial adapter is connected and "
            "your user is in the 'dialout' group."
        )

    print("\nDetected serial ports:")
    for i, p in enumerate(ports, start=1):
        print(f"  [{i}] {p['device']}  ({p['description']})")

    while True:
        raw = input(f"\nSelect port [1-{len(ports)}]: ").strip()
        if raw.isdigit() and 1 <= int(raw) <= len(ports):
            return ports[int(raw) - 1]["device"]
        print("Invalid choice, try again.")


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
    print(f"\nOutput written to: {output_path.resolve()}")


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
      save auto-named output to /tmp/captures/<hostname>_<timestamp>.txt""",
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
        "--version", "-v",
        action="version",
        version="%(prog)s 1.0.0",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    ser = None
    results: dict[str, str] = {}
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_path = Path(args.output) if args.output else None
    output_dir = Path(args.output_dir) if (args.output_dir and not args.output) else None

    try:
        if output_dir is not None and not output_dir.is_dir():
            sys.exit(f"ERROR: Output directory {str(output_dir)!r} does not exist.")

        # Resolve port
        if args.port:
            port = args.port
            if not Path(port).exists():
                sys.exit(f"ERROR: Device {port!r} does not exist.")
            print(f"Using specified port: {port}")
        else:
            print("Scanning for serial TTY devices via udev \u2026")
            ports = discover_serial_ports()
            port = select_port(ports)

        # Connect
        print(f"\nConnecting to {port} at {args.baud} baud \u2026")
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
            sys.exit(f"ERROR: Could not open {port}: {exc}")

        print("Connected. Attempting login \u2026")
        login(ser, args.username, args.password, args.enable_password)

        if output_path is None:
            hostname = get_hostname(ser)
            prefix = hostname if hostname else "cisco_output"
            filename = f"{prefix}_{ts}.txt"
            output_path = (output_dir / filename) if output_dir else Path(filename)

        for cmd in (args.commands or COMMANDS):
            print(f"  \u2192 {cmd}")
            output = send_command(ser, cmd)
            results[cmd] = output

    except KeyboardInterrupt:
        print("\nInterrupted.")
    finally:
        if ser is not None:
            ser.close()
            print("Serial port closed.")

    if results:
        fallback = (output_dir or Path()) / f"cisco_output_{ts}.txt"
        write_output(results, output_path or fallback)
    else:
        print("No output captured.")


if __name__ == "__main__":
    main()
