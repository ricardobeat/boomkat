"""Generate the self-contained startup fixture used in cache measurements."""
from pathlib import Path

source = "\n".join(f"function value{i}(x) {{ return x + {i}; }}" for i in range(2000))
source += '\nif (value1999(1) !== 2000) throw new Error("FAIL");\nprint("PASS");\n'
Path("module_startup.js").write_text(source)
