#!/usr/bin/env python3
"""QELTRAVYX qpkg 0.8: install pure-Python PyPI wheels into app-private storage.

This is not pip. Native wheels and source distributions are intentionally rejected.
"""
from __future__ import annotations

import email
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import ssl
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile

HOME = Path.home().resolve()
PKGS = (HOME / 'workspace' / 'packages').resolve()
STATE = (HOME / 'workspace' / '.qpkg').resolve()
INDEX = STATE / 'installed.json'
VENDOR = Path(__file__).resolve().parent / 'vendor'
CACERT = VENDOR / 'cacert.pem'
sys.path.insert(0, str(VENDOR))
from packaging.requirements import Requirement
from packaging.utils import canonicalize_name, parse_wheel_filename
from packaging.version import Version, InvalidVersion
from packaging.markers import default_environment
from packaging.specifiers import SpecifierSet

MAX_DOWNLOAD = 25 * 1024 * 1024
MAX_UNPACK = 60 * 1024 * 1024
MAX_FILES = 3000
ALLOWED_HOSTS = {'pypi.org', 'files.pythonhosted.org'}
NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$')
NATIVE_SUFFIXES = ('.so','.pyd','.dll','.dylib','.a','.o','.exe','.whl','.pth')

class QpkgError(Exception):
    pass

def norm(name):
    if not NAME_RE.fullmatch(name):
        raise QpkgError('Nome de pacote inválido.')
    return canonicalize_name(name)

def init_dirs():
    # Refuse a redirected package directory, even if it already exists.
    for directory in (HOME / 'workspace', PKGS, STATE):
        if directory.is_symlink():
            raise QpkgError('Pastas gerenciadas não podem ser links simbólicos.')
        directory.mkdir(parents=True, exist_ok=True)


def checked_target(name):
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ('..', '.') for part in path.parts):
        raise QpkgError('Caminho inválido no registro.')
    target = PKGS.joinpath(*path.parts)
    parent = target.parent
    while parent != PKGS:
        if parent.is_symlink():
            raise QpkgError('Diretório simbólico bloqueado: ' + str(parent))
        parent = parent.parent
    if target.is_symlink():
        raise QpkgError('Arquivo simbólico bloqueado: ' + str(target))
    return target

def registry():
    if not INDEX.exists():
        return {}
    content = json.loads(INDEX.read_text(encoding='utf-8'))
    if not isinstance(content, dict):
        raise QpkgError('Registro de pacotes inválido.')
    return content

def save(data):
    with tempfile.NamedTemporaryFile('w', encoding='utf8', dir=STATE, delete=False) as f:
        json.dump(data, f, indent=2, sort_keys=True)
        tmp = Path(f.name)
    os.replace(tmp, INDEX)

def https_get(url, cap=MAX_DOWNLOAD):
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != 'https' or parsed.hostname not in ALLOWED_HOSTS:
        raise QpkgError('Origem externa não autorizada.')
    if not CACERT.is_file():
        raise QpkgError('Certificados HTTPS ausentes do QELTRAVYX.')
    ctx = ssl.create_default_context(cafile=str(CACERT))
    req = urllib.request.Request(url, headers={'User-Agent':'QELTRAVYX-qpkg/0.8', 'Accept':'application/json, */*'})
    with urllib.request.urlopen(req, timeout=35, context=ctx) as stream:
        final = urllib.parse.urlparse(stream.url)
        if final.scheme != 'https' or final.hostname not in ALLOWED_HOSTS:
            raise QpkgError('Redirecionamento não autorizado.')
        length = stream.headers.get('Content-Length')
        if length and int(length) > cap:
            raise QpkgError('Download maior do que o limite permitido.')
        content = stream.read(cap + 1)
        if len(content) > cap:
            raise QpkgError('Download excedeu o limite permitido.')
        return content

def pypi_json(name):
    payload = https_get('https://pypi.org/pypi/' + urllib.parse.quote(name, safe='') + '/json', 8*1024*1024)
    data = json.loads(payload)
    if not isinstance(data.get('releases'), dict):
        raise QpkgError('Resposta inesperada do PyPI.')
    return data

def find_wheel(req, meta):
    candidates = []
    for ver_text, files in meta['releases'].items():
        try:
            ver = Version(ver_text)
        except InvalidVersion:
            continue
        if ver.is_prerelease or ver.is_devrelease or (req.specifier and ver not in req.specifier):
            continue
        for f in files:
            if f.get('packagetype') != 'bdist_wheel' or f.get('yanked') or int(f.get('size', 0)) > MAX_DOWNLOAD:
                continue
            filename = f.get('filename','')
            try:
                wheel_name, wheel_ver, _, tags = parse_wheel_filename(filename)
                if wheel_name != norm(req.name) or wheel_ver != ver:
                    continue
            except Exception:
                continue
            # Android CPython: only universal, pure Python wheels in Alpha 0.8.
            if not any(t.abi == 'none' and t.platform == 'any' and t.interpreter in ('py3', 'py2.py3', f'cp{sys.version_info.major}{sys.version_info.minor}') for t in tags):
                continue
            rp = f.get('requires_python')
            if rp and Version('.'.join(map(str,sys.version_info[:3]))) not in SpecifierSet(rp):
                continue
            checksum = f.get('digests',{}).get('sha256','')
            if not re.fullmatch('[0-9a-f]{64}',checksum):
                continue
            candidates.append((ver, filename, f))
    if not candidates:
        raise QpkgError(f'Sem wheel Python puro compatível para {req}. Pacotes nativos não são suportados.')
    candidates.sort(key=lambda c:c[0], reverse=True)
    return candidates[0][2]

def unpack(wheel_bytes, filename, expected):
    if hashlib.sha256(wheel_bytes).hexdigest() != expected:
        raise QpkgError('SHA256 divergente: download rejeitado.')
    result = {}
    with zipfile.ZipFile(io.BytesIO(wheel_bytes)) as z:
        if len(z.infolist()) > MAX_FILES:
            raise QpkgError('Wheel contém arquivos demais.')
        total = 0
        for item in z.infolist():
            if item.is_dir():
                continue
            total += item.file_size
            if total > MAX_UNPACK or item.file_size > MAX_DOWNLOAD:
                raise QpkgError('Wheel excede limite de extração.')
            name = item.filename
            path = PurePosixPath(name)
            if ('\\' in name or path.is_absolute() or any(p in ('..','.') for p in path.parts) or
                len(path.parts) < 2 or '\x00' in name or path.parts[0].endswith('.data') or
                path.suffix.lower() in NATIVE_SUFFIXES or path.name in ('sitecustomize.py','usercustomize.py')):
                raise QpkgError('Wheel contém caminho ou arquivo não permitido: ' + name)
            # Unix symlinks and other special file types are rejected.
            mode = (item.external_attr >> 16) & 0o170000
            if mode not in (0, 0o100000):
                raise QpkgError('Wheel contém link ou arquivo especial: ' + name)
            result[name] = z.read(item)
    metadata = [v for k,v in result.items() if k.endswith('.dist-info/METADATA')]
    wheel_info = [v for k,v in result.items() if k.endswith('.dist-info/WHEEL')]
    if len(metadata) != 1 or len(wheel_info) != 1:
        raise QpkgError('Metadados do wheel inválidos.')
    wheel_msg = email.message_from_bytes(wheel_info[0])
    if wheel_msg.get('Root-Is-Purelib','').lower() != 'true':
        raise QpkgError('Wheel não é declarado como purelib.')
    return result, email.message_from_bytes(metadata[0])

def resolve(req, planned, installed, visiting, depth=0):
    if depth > 20 or len(planned) > 40:
        raise QpkgError('Limite de dependências excedido.')
    if req.url or req.extras:
        raise QpkgError('URLs diretas e extras ainda não são suportados.')
    key = norm(req.name)
    if key in installed:
        ver = Version(installed[key]['version'])
        if ver not in req.specifier:
            raise QpkgError(f'{key} instalado ({ver}) não atende {req.specifier}; remova-o primeiro.')
        return
    if key in planned:
        if Version(planned[key]['version']) not in req.specifier:
            raise QpkgError(f'Conflito nas dependências de {key}.')
        return
    if key in visiting:
        return
    visiting.add(key)
    print('Consultando PyPI:', str(req), flush=True)
    meta=pypi_json(key)
    file=find_wheel(req,meta)
    raw=https_get(file['url'])
    files,msg=unpack(raw,file['filename'],file['digests']['sha256'])
    version=str(msg.get('Version',''))
    if norm(msg.get('Name','')) != key or Version(version) not in req.specifier:
        raise QpkgError('Metadados inconsistentes com a solicitação.')
    # Verify no dependency execution as part of installation; only wheel files copied.
    deps=[]
    env=default_environment()
    for text in msg.get_all('Requires-Dist',[]):
        dep=Requirement(text)
        if dep.marker is None or dep.marker.evaluate(environment={**env,'extra':''}):
            deps.append(dep)
    planned[key]={'version':version,'files':files,'deps':[norm(x.name) for x in deps]}
    for dep in deps:
        resolve(dep,planned,installed,visiting,depth+1)
    visiting.remove(key)

def install(arg):
    request=Requirement(arg)
    if request.url or request.extras:
        raise QpkgError('Use apenas nome ou nome==versão, sem extras/URL.')
    init_dirs()
    reg=registry()
    planned={}
    resolve(request, planned, reg, set())
    if not planned:
        print('Pacote já instalado e compatível.'); return
    existing = {p for item in reg.values() for p in item.get('files',{})}
    incoming=set()
    for key, item in planned.items():
        for name in item['files']:
            if name in existing or name in incoming or checked_target(name).exists():
                raise QpkgError('Conflito de arquivo; instalação cancelada: '+name)
            incoming.add(name)
    # Download + verify + resolve all deps before any installation.
    changes=[]
    try:
        for key, item in planned.items():
            hashes={}
            for name, data in item['files'].items():
                target = checked_target(name)
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists():
                    raise QpkgError('Arquivo já existe: '+name)
                target.write_bytes(data)
                changes.append(target)
                hashes[name]=hashlib.sha256(data).hexdigest()
            reg[key]={'version':item['version'],'files':hashes,'deps':item['deps']}
        save(reg)
    except Exception:
        for file in reversed(changes):
            file.unlink(missing_ok=True)
        raise
    for key,item in planned.items():
        print(f'Instalado: {key} {item["version"]}')
    print('Pacotes disponíveis para importação no Python do QELTRAVYX.')

def remove(name):
    key=norm(name); init_dirs(); reg=registry()
    if key not in reg:
        raise QpkgError('Pacote não está instalado via qpkg: '+key)
    dependents=[k for k,v in reg.items() if k!=key and key in v.get('deps',[])]
    if dependents:
        raise QpkgError('Pacote necessário por: '+', '.join(dependents))
    files=reg[key].get('files',{})
    changed=[]
    for fname, digest in files.items():
        f=checked_target(fname)
        if f.is_symlink() or (f.exists() and hashlib.sha256(f.read_bytes()).hexdigest()!=digest):
            changed.append(fname)
    if changed:
        raise QpkgError('Arquivos alterados; remoção cancelada: '+ ', '.join(changed[:5]))
    for fname in files:
        checked_target(fname).unlink(missing_ok=True)
    del reg[key]
    save(reg)
    print('Removido:', key)

def main(argv):
    if not argv or argv[0] in ('help','--help','-h'):
        print('QELTRAVYX qpkg 0.8\n  qpkg list\n  qpkg install <pacote>\n  qpkg remove <pacote>\n  qpkg info <pacote>\n  qpkg doctor\nSuporta apenas wheels Python puros do PyPI, com SHA256. Não é pip.')
        return
    cmd,*args=argv
    if cmd == 'doctor' and not args:
        print('QPKG_OK')
        print('Python:',sys.version.split()[0],'| isolamento:',sys.flags.isolated)
        print('Pasta:',PKGS)
        print('Certificados:', 'OK' if CACERT.is_file() else 'AUSENTES')
    elif cmd == 'list' and not args:
        packages=registry()
        if not packages: print('Nenhum pacote instalado pelo qpkg.')
        for k,v in sorted(packages.items()):
            print(k, v['version'])
    elif cmd == 'info' and len(args)==1:
        k=norm(args[0]); v=registry().get(k)
        if v: print(f'{k} {v["version"]} | arquivos: {len(v["files"])} | dependências: {", ".join(v["deps"]) or "nenhuma"}')
        else: print('Não instalado:',k)
    elif cmd == 'install' and len(args)==1:
        install(args[0])
    elif cmd == 'remove' and len(args)==1:
        remove(args[0])
    else:
        raise QpkgError('Sintaxe inválida. Use: qpkg help')

if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (QpkgError, ValueError, OSError, json.JSONDecodeError, zipfile.BadZipFile) as exc:
        print('QPKG ERRO:',exc,file=sys.stderr)
        sys.exit(1)
