#!/usr/bin/env python3
"""Write empty Verilog modules for VHDL entities so Verilator can lint the Verilog around them.
Port and generic names come out lower case (VHDL is case-insensitive, the instances are not).

    vhdl_stub.py file.vhd [entity ...] > stubs.v
"""
import re, sys

src = open(sys.argv[1]).read()
want = set(sys.argv[2:])
src = re.sub(r"--[^\n]*", "", src)

for m in re.finditer(r"entity\s+(\w+)\s+is(.*?)end\s+(?:entity|\1)", src, re.S | re.I):
    name, body = m.group(1), m.group(2)
    if want and name not in want:
        continue
    gens = []
    g = re.search(r"generic\s*\((.*?)\)\s*;\s*port", body, re.S | re.I)
    if g:
        for d in g.group(1).split(";"):
            if ":" in d:
                for n in d.split(":")[0].split(","):
                    dflt = re.search(r":=\s*([^;]+)$", d.strip())
                    v = dflt.group(1).strip() if dflt else "0"
                    if not re.match(r"^-?\d+$", v):
                        v = '""' if '"' in v else "0"
                    gens.append(f"parameter {n.strip().lower()} = {v}")
    p = re.search(r"port\s*\((.*)\)\s*;\s*$", body.strip(), re.S | re.I)
    ports = []
    for d in p.group(1).split(";"):
        if ":" not in d:
            continue
        names, typ = d.split(":", 1)
        mm = re.match(r"\s*(in|out|inout)\s+(.*)", typ, re.I | re.S)
        direction = {"in": "input", "out": "output", "inout": "inout"}[mm.group(1).lower()]
        rng = re.search(r"\(\s*(.+?)\s+downto\s+(.+?)\s*\)", mm.group(2), re.I)
        width = f"[{rng.group(1)}:{rng.group(2)}] " if rng else ""
        for n in names.split(","):
            ports.append(f"\t{direction} {width}{n.strip().lower()}")
    gp = f" #({', '.join(gens)})" if gens else ""
    print(f"module {name}{gp}\n(\n" + ",\n".join(ports) + "\n);\nendmodule\n")
