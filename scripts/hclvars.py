#!/usr/bin/env python3
"""Read / update simple string keys in terraform.tfvars, in place.

  hclvars.py get <file> <key>            print the (unescaped) value, or nothing
  hclvars.py set <file>  < JSON          {"key": "value" | null, ...}; null removes

* Values arrive on stdin (JSON), never argv, so secrets don't show in `ps`.
* Every other line (your own keys and comments) is preserved.
* Written atomically with mode 0600.
* Only `key = "string"` assignments are managed; HCL escaping (\\ \" ${ %{) is handled.
"""
import json
import os
import re
import sys
import tempfile


def line_re(key):
    return re.compile(r'^(\s*)' + re.escape(key) + r'(\s*=\s*)"((?:[^"\\]|\\.)*)"(.*)$')


def hcl_escape(v):
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("${", "$${").replace("%{", "%%{")


def hcl_unescape(v):
    out, i = [], 0
    while i < len(v):
        if v[i] == "\\" and i + 1 < len(v):
            out.append({"n": "\n", "t": "\t"}.get(v[i + 1], v[i + 1])); i += 2
        elif v.startswith("$${", i):
            out.append("${"); i += 3
        elif v.startswith("%%{", i):
            out.append("%{"); i += 3
        else:
            out.append(v[i]); i += 1
    return "".join(out)


def get(path, key):
    if not os.path.exists(path):
        return
    rx = line_re(key)
    for line in open(path, encoding="utf-8"):
        m = rx.match(line.rstrip("\n"))
        if m:
            sys.stdout.write(hcl_unescape(m.group(3)))
            return


def set_(path, updates):
    lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
    for key, value in updates.items():
        if not re.fullmatch(r"[a-z_][a-z0-9_]*", key):
            sys.exit(f"bad key: {key!r}")
        rx = line_re(key)
        idx = next((i for i, l in enumerate(lines) if rx.match(l)), None)
        if value is None:
            if idx is not None:
                del lines[idx]
            continue
        if not isinstance(value, str) or "\n" in value:
            sys.exit(f"{key}: only single-line strings are supported")
        new = f'{key} = "{hcl_escape(value)}"'
        if idx is None:
            lines.append(new)
        else:
            m = rx.match(lines[idx])
            lines[idx] = f'{m.group(1)}{key}{m.group(2)}"{hcl_escape(value)}"{m.group(4)}'
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tfvars.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(lines).rstrip("\n") + "\n")
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "get":
        get(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 3 and sys.argv[1] == "set":
        set_(sys.argv[2], json.load(sys.stdin))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
