# Cisco Console Capture

Capture Cisco CLI output over a serial console on Linux.

Connects to a Cisco device via a USB-serial adapter (or any TTY), sends
`show run brief` and `show interfaces status`, and writes the output to a
timestamped text file.

## Requirements

- Ubuntu 20.04 or later (Linux only)
- Python 3.10+
- User must be in the `dialout` group

## Installation

Download the release tarball, extract it, and run the bundled installer:

```bash
tar -xzf cisco-console-capture-1.0.0.tar.gz
cd cisco-console-capture-1.0.0
./install.sh
```

The installer creates a Python virtual environment under
`~/.local/share/cisco-console-capture` and places a wrapper script at
`/usr/local/bin/console-capture`. All dependencies are bundled in the
tarball — no internet access is required on the target machine.

### Add yourself to the dialout group (once)

```bash
sudo usermod -aG dialout $USER
# Log out and back in, then verify:
groups | grep dialout
```

## Usage

```
console-capture [OPTIONS]
```

| Option | Short | Description |
|---|---|---|
| `--port PATH` | `-p` | Serial device (e.g. `/dev/ttyUSB0`). Auto-detected if omitted. |
| `--baud RATE` | `-b` | Baud rate (default: 9600) |
| `--username USER` | `-u` | Login username (prompted if needed) |
| `--password PASS` | `-P` | Login password (prompted securely if needed) |
| `--enable-password PASS` | `-e` | Enable mode password (prompted securely if the device asks) |
| `--output FILE` | `-o` | Output file (default: `<hostname>_<timestamp>.txt`) |
| `--output-dir DIR` | `-d` | Directory for the auto-named output file (ignored if `--output` is given) |
| `--command CMD` | `-c` | Command to run (repeatable). Combined with `--command-file`; both replace the defaults. |
| `--command-file FILE` | `-f` | File with one CLI command per line. Blank lines and `#` comments are ignored. |
| `--version` | `-v` | Show version and exit |

### Examples

```bash
# Auto-detect port, interactive login, auto-named output file (runs default commands)
console-capture

# Specify everything
console-capture -p /dev/ttyUSB0 -b 9600 -u admin -o capture.txt

# Run custom commands instead of the defaults
console-capture -c "show version" -c "show ip route" -c "show ip interface brief"

# Read commands from a file
console-capture -f commands.txt

# Save to a specific directory without changing the filename
console-capture -d /tmp/captures
```

## Uninstallation

```bash
~/.local/share/cisco-console-capture/uninstall.sh
```

## How it works

1. **udev discovery** – scans the `tty` subsystem via pyudev for USB-serial
   adapters (`ttyUSB*`, `ttyACM*`).
2. **Login handling** – sends Enter, responds to username/password prompts, issues `enable` to enter privileged EXEC mode (handling the enable password prompt if the device asks), then sends `terminal length 0` to disable pagination.
3. **Command execution** – sends each command, reads until a Cisco prompt
   (`#` or `>`) or timeout, and handles any remaining `--More--` pages.
4. **Output** – writes all results to a clearly formatted text file.

## License

MIT
