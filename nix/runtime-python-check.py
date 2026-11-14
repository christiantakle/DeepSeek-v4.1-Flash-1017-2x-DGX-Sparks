"""CPU-only check of the exact python3 -I invocation used by the engine."""
import io
import json
import os
import subprocess
import sys

from PIL import Image

assert sys.flags.isolated == 1
# A BMP ensures this exercises Pillow rather than the engine's native PNG path.
image = Image.new("RGB", (2, 1), (7, 19, 43))
encoded = io.BytesIO()
image.save(encoded, format="BMP")
child = subprocess.run(
    [
        "python3",
        "-I",
        "-c",
        'import io,sys; from PIL import Image; '
        'im=Image.open(io.BytesIO(sys.stdin.buffer.read())).convert("RGB"); '
        'sys.stdout.buffer.write(im.tobytes())',
    ],
    input=encoded.getvalue(),
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=True,
    env={**os.environ, "PATH": os.path.dirname(sys.executable) + os.pathsep + os.environ.get("PATH", "")},
)
assert child.stdout == bytes((7, 19, 43)) * 2, child.stderr
print(json.dumps({"python": sys.version.split()[0], "pillow": Image.__version__, "isolated_child_bmp": "ok"}))
