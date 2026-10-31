#!/usr/bin/env python3
"""Patch the bundled offline pip policy for Android's /data/user/0 alias.

Only the app-owned runtime path is normalized. Other symbolic links remain
rejected. The patched ZIP and its SHA-256 manifest are built together.
"""
from pathlib import Path
from zipfile import ZipFile
import hashlib
import os
import tempfile

assets = Path("android/app/src/main/assets/qeltravyx/python")
archive = assets / "pip-runtime.zip"
manifest = assets / "pip-runtime.sha256"
member_name = "pip/_qeltravyx.py"

old = (
    "    if path.resolve() != path:\n"
    "        raise PolicyError('Runtime por link simbólico não suportado.')\n"
    "    return path.parent\n"
)
new = (
    "    allowed = (Path('/data/data/dev.qeltravyx.qeltravyx/files'),\n"
    "               Path('/data/user/0/dev.qeltravyx.qeltravyx/files'))\n"
    "    if path.parent not in allowed or path.resolve() != path.parent.resolve() / path.name:\n"
    "        raise PolicyError('Runtime por link simbólico não suportado.')\n"
    "    return path.parent.resolve()\n"
)

expected = manifest.read_text(encoding="ascii").strip()
actual = hashlib.sha256(archive.read_bytes()).hexdigest()
if len(expected) != 64 or expected != actual:
    raise SystemExit("Erro: checksum original do pip-runtime.zip não confere")

fd, temporary = tempfile.mkstemp(prefix=".pip-runtime-", suffix=".zip", dir=assets)
os.close(fd)
temp = Path(temporary)
try:
    found = False
    with ZipFile(archive, "r") as source, ZipFile(temp, "w") as target:
        if source.testzip() is not None:
            raise SystemExit("Erro: ZIP original do pip corrompido")
        for info in source.infolist():
            data = source.read(info)
            if info.filename == member_name:
                found = True
                src = data.decode("utf-8")
                if src.count(old) != 1:
                    raise SystemExit("Erro: política original mudou; patch não aplicado")
                patched = src.replace(old, new, 1)
                compile(patched, member_name, "exec")
                data = patched.encode("utf-8")
            target.writestr(info, data)
    if not found:
        raise SystemExit("Erro: módulo de política do pip não encontrado")
    with ZipFile(temp, "r") as result:
        if result.testzip() is not None or new.encode() not in result.read(member_name):
            raise SystemExit("Erro: validação do ZIP corrigido falhou")
    temp.replace(archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest.write_text(digest + "\n", encoding="ascii")
    print("Pip Android: alias corrigido no ZIP, checksum atualizado e Python validado")
finally:
    temp.unlink(missing_ok=True)
