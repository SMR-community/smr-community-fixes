"""Capture the Paradox Mods routes, then finish pdx_client.py automatically.

    python tools/publish/capture.py

Starts mitmproxy with the recording addon, tells you how to trust its CA and
point the game at it on your platform, and waits. Upload the mod once from the
game's Mod Editor, press Ctrl+C, and it fills in the ROUTES table for you.

On Windows the system proxy is set and restored automatically. On macOS and
Linux the exact commands are printed rather than run, because they need sudo and
would be changing settings well outside this repository's business.

Only shape is recorded - method, path and field names. Values, including your
password, are redacted by capture_routes.py before anything reaches disk.
"""

from __future__ import annotations

import argparse
import contextlib
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "capture_routes.py")
ROUTES = os.path.join(HERE, "routes.json")
FINISH = os.path.join(HERE, "finish_routes.py")
CONFDIR = os.path.join(os.path.expanduser("~"), ".mitmproxy")
CERT = os.path.join(CONFDIR, "mitmproxy-ca-cert.pem")


def ensure_mitmproxy() -> None:
    if shutil.which("mitmdump"):
        return
    print("installing mitmproxy...")
    subprocess.run([sys.executable, "-m", "pip", "install", "--quiet", "mitmproxy"], check=True)
    if not shutil.which("mitmdump"):
        sys.exit("mitmdump is still not on PATH; install mitmproxy manually and re-run")


def ensure_ca(port: int) -> None:
    """mitmproxy writes its CA on first start."""
    if os.path.exists(CERT):
        return
    print("generating the mitmproxy CA...")
    seed = subprocess.Popen(["mitmdump", "--listen-port", str(port)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if os.path.exists(CERT):
                return
            time.sleep(0.3)
        sys.exit("mitmproxy did not produce a CA certificate")
    finally:
        seed.terminate()


@contextlib.contextmanager
def windows_proxy(port: int):
    """Point Windows at the proxy, and put the old setting back afterwards."""
    import winreg

    key_path = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path, 0, winreg.KEY_ALL_ACCESS) as key:
        def read(name, default):
            try:
                return winreg.QueryValueEx(key, name)[0]
            except FileNotFoundError:
                return default

        saved_enable, saved_server = read("ProxyEnable", 0), read("ProxyServer", "")
        winreg.SetValueEx(key, "ProxyServer", 0, winreg.REG_SZ, f"127.0.0.1:{port}")
        winreg.SetValueEx(key, "ProxyEnable", 0, winreg.REG_DWORD, 1)
        try:
            yield
        finally:
            winreg.SetValueEx(key, "ProxyEnable", 0, winreg.REG_DWORD, saved_enable)
            winreg.SetValueEx(key, "ProxyServer", 0, winreg.REG_SZ, saved_server)
            print("\nproxy restored.")


def instructions(port: int) -> str:
    if sys.platform == "darwin":
        return f"""
Trust the CA and route traffic through it (both need your password):

  sudo security add-trusted-cert -d -r trustRoot \\
      -k /Library/Keychains/System.keychain "{CERT}"
  sudo networksetup -setwebproxy Wi-Fi 127.0.0.1 {port}
  sudo networksetup -setsecurewebproxy Wi-Fi 127.0.0.1 {port}

Undo afterwards:

  sudo networksetup -setwebproxystate Wi-Fi off
  sudo networksetup -setsecurewebproxystate Wi-Fi off
"""
    if sys.platform.startswith("linux"):
        return f"""
Trust the CA:

  sudo cp "{CERT}" /usr/local/share/ca-certificates/mitmproxy.crt
  sudo update-ca-certificates

Then launch the game through the proxy, which avoids touching system settings:

  HTTPS_PROXY=http://127.0.0.1:{port} HTTP_PROXY=http://127.0.0.1:{port} ./Mars

Undo afterwards:

  sudo rm /usr/local/share/ca-certificates/mitmproxy.crt && sudo update-ca-certificates
"""
    return f"""
Trust the CA, from an elevated prompt:

  certutil -addstore -f ROOT "{CERT}"

The system proxy is set to 127.0.0.1:{port} for you, and restored on exit.
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    ensure_mitmproxy()
    ensure_ca(args.port)

    print(instructions(args.port))
    print("Then: start the game, upload this mod once from the Mod Editor, and")
    print("press Ctrl+C here when it finishes.\n")

    proxy = windows_proxy(args.port) if os.name == "nt" else contextlib.nullcontext()
    with proxy:
        try:
            subprocess.run(["mitmdump", "-s", ADDON, "--listen-port", str(args.port),
                            "--set", f"confdir={CONFDIR}"], check=False)
        except KeyboardInterrupt:
            pass

    if not os.path.exists(ROUTES):
        print("\nno routes.json was written - no API traffic was seen.")
        print("The game may ignore the proxy; capture at the network level instead.")
        return 1

    print("\nfilling in the routes...\n")
    return subprocess.run([sys.executable, FINISH], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
