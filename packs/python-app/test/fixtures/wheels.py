"""Build the wheels the python-app behavior cases install without a network.

Each is a minimal but complete wheel, so a case's `pip install` unpacks it
exactly as it would a download from an index, and pip list, freeze, show, check
and list --outdated then read genuine installed metadata. No action imports
these packages.
"""

import base64
import hashlib
import sys
import zipfile
from pathlib import Path

WHEELS = [
    ("packtest-gadget", "1.0.0", []),
    # Never installed, so `pip list --outdated` has a newer release to report.
    ("packtest-gadget", "2.0.0", []),
    ("packtest-widget", "1.2.3", ["packtest-gadget>=1.0"]),
    # Installed only by the conflict case, which it breaks on purpose.
    ("packtest-legacy", "0.9.0", ["packtest-gadget<1.0"]),
]


def record_line(path, data):
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=")
    return f"{path},sha256={digest.decode()},{len(data)}"


def build(out, name, version, requires):
    module = name.replace("-", "_")
    dist_info = f"{module}-{version}.dist-info"
    metadata = [
        "Metadata-Version: 2.1",
        f"Name: {name}",
        f"Version: {version}",
        "Summary: Emisar python-app behavior fixture",
    ] + [f"Requires-Dist: {requirement}" for requirement in requires]
    files = {
        f"{module}/__init__.py": f'__version__ = "{version}"\n'.encode(),
        f"{dist_info}/METADATA": ("\n".join(metadata) + "\n").encode(),
        f"{dist_info}/WHEEL": (
            b"Wheel-Version: 1.0\nGenerator: packtest\n"
            b"Root-Is-Purelib: true\nTag: py3-none-any\n"
        ),
    }
    record = [record_line(path, data) for path, data in files.items()]
    files[f"{dist_info}/RECORD"] = ("\n".join(record + [f"{dist_info}/RECORD,,"]) + "\n").encode()
    with zipfile.ZipFile(out / f"{module}-{version}-py3-none-any.whl", "w") as wheel:
        for path, data in files.items():
            entry = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
            entry.external_attr = 0o644 << 16
            wheel.writestr(entry, data, zipfile.ZIP_DEFLATED)


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, version, requires in WHEELS:
        build(out, name, version, requires)


if __name__ == "__main__":
    main()
