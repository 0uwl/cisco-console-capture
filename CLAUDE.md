# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Single-module Python CLI tool that connects to a Cisco device over a serial console, sends `show run brief` and `show interfaces status`, and writes the output to a timestamped text file. Linux-only (uses pyudev for udev-based port discovery).

## Development setup

The project uses hatchling as the build backend. To set up a local dev environment:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

Run the tool directly:

```bash
console-capture --help
```

Run the build and install integration test:

```bash
bash tests/test_install.sh
```

The test runs `build.sh`, extracts the produced tarball into a `mktemp` directory, installs from the tarball's own `install.sh`, asserts the expected files exist and the binary works, then uninstalls and removes the temp directory unconditionally via a `trap EXIT`.

## Building a portable release tarball

```bash
bash build.sh
# outputs dist/cisco-console-capture-<version>.tar.gz
```

The build script creates a temporary venv, builds the package wheel via hatchling, downloads all runtime dependency wheels (`pyserial`, `pyudev`) with `--only-binary :all:`, then bundles them into a tarball alongside a self-contained `install.sh`. The target machine needs no internet access or build tools — only Python 3.10+ and `python3-venv`.

**Adding dependencies**: all runtime dependencies must be available as pure-Python `--only-binary` wheels. The build will fail for dependencies that require compilation.

## Installation / uninstallation

Build the tarball, extract it on the target machine, and run the bundled installer:

```bash
bash build.sh
# then on the target:
tar -xzf dist/cisco-console-capture-<version>.tar.gz
cd cisco-console-capture-<version>
./install.sh        # installs to ~/.local/share/cisco-console-capture, wrapper at /usr/local/bin/
~/.local/share/cisco-console-capture/uninstall.sh
```

The wrapper path can be overridden by setting `CONSOLE_CAPTURE_BIN_LINK` before running `install.sh` (the integration test uses this to avoid writing to `/usr/local/bin/`).

## Version

The canonical version lives in [cisco_console_capture/__init__.py](cisco_console_capture/__init__.py) as `__version__`. `pyproject.toml` and `build.sh` both read it from there — bump it in `__init__.py` only.

## Architecture

All logic lives in [cisco_console_capture/main.py](cisco_console_capture/main.py). The execution flow is:

1. **Port resolution** — `discover_serial_ports()` uses pyudev to enumerate `ttyUSB*`, `ttyACM*`, `ttyS[0-9]*`, `ttyAMA*`, `ttyXR*` nodes; `select_port()` prompts the user to pick one if `--port` is not supplied.
2. **Login** — `login()` sends `\r\n`, reads the banner, responds to username/password prompts, and sends `terminal length 0` to disable pagination.
3. **Hostname detection** — `get_hostname()` sends a bare `\r\n` and parses the resulting prompt (`hostname#`) to derive the output filename prefix; falls back to `cisco_output` if the prompt can't be parsed.
4. **Command execution** — `send_command()` writes a command and calls `read_until_prompt()`, which buffers output, automatically pages through `--More--` prompts by writing a space, and stops at a Cisco `#`/`>` prompt or a 15-second timeout.
5. **Output** — `write_output()` writes all captured output to a UTF-8 text file with section headers. The default filename is `<hostname>_<timestamp>.txt`.

The commands sent to the device are defined in the `COMMANDS` list constant near the top of [main.py](cisco_console_capture/main.py) — add or reorder entries there to change what gets captured.

## Key constants (main.py)

| Constant | Default | Purpose |
|---|---|---|
| `COMMANDS` | `["show run brief", "show interfaces status"]` | Commands sent to the device |
| `DEFAULT_BAUD` | `9600` | Default serial baud rate |
| `READ_TIMEOUT` | `15` s | Per-read timeout waiting for a prompt |
| `INTER_CMD_DELAY` | `0.5` s | Delay between write and read |
| `MORE_PATTERN` | `--More--` / `--- more ---` | Regex that triggers automatic pagination |
| `PROMPT_PATTERN` | `[>#]\s*$` | Regex that signals the end of command output |

## Man page

The man page source is at [man/man1/console-capture.1](man/man1/console-capture.1). `build.sh` bundles it into the tarball; `install.sh` gzip-compresses it to `~/.local/share/man/man1/console-capture.1.gz`.
