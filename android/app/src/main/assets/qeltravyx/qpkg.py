#!/usr/bin/env python3
"""QELTRAVYX qpkg 0.10: install pure-Python PyPI wheels into app-private storage.

This is not pip. Native wheels and source distributions are intentionally rejected.
"""
from __future__ import annotations

import email
import contextlib
import fcntl
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
PKGS = HOME / 'workspace' / 'packages'
STATE = HOME / 'workspace' / '.qpkg'
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
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise QpkgError('Nome de pacote inválido.')
    return canonicalize_name(name)

def init_dirs():
    # Refuse a redirected package directory, even if it already exists.
    for directory in (HOME / 'workspace', PKGS, STATE):
        if directory.is_symlink() or directory.resolve() != directory:
            raise QpkgError('Pastas gerenciadas não podem ser links simbólicos.')
        directory.mkdir(parents=True, exist_ok=True)


def checked_target(name):
    if (not isinstance(name, str) or not name or '\\' in name or '\x00' in name or
            any(part in ('', '..', '.') for part in name.split('/'))):
        raise QpkgError('Caminho inválido no registro.')
    target = PKGS.joinpath(*name.split('/'))
    if target.resolve() != target or not target.is_relative_to(PKGS):
        raise QpkgError('Link/caminho externo bloqueado.')
    if target.exists() and (not target.is_file() or target.stat().st_nlink != 1):
        raise QpkgError('Arquivo especial/hardlink bloqueado.')
    return target


@contextlib.contextmanager
def transaction_lock():
    init_dirs()
    lock = STATE / 'lock'
    if lock.is_symlink():
        raise QpkgError('Link no lock bloqueado.')
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if (STATE / 'pending.json').exists():
            raise QpkgError('Transação interrompida: preserve os arquivos e revise .qpkg/pending.json antes de continuar.')
        yield
    finally:
        os.close(fd)


def registry():
    if INDEX.is_symlink() or STATE.resolve() != STATE or PKGS.resolve() != PKGS:
        raise QpkgError('Link no estado/pacotes bloqueado.')
    if not INDEX.exists():
        return {}
    if INDEX.stat().st_size > 4 * 1024 * 1024:
        raise QpkgError('Registro excessivo.')
    content = json.loads(INDEX.read_text(encoding='utf-8'))
    if not isinstance(content, dict):
        raise QpkgError('Registro de pacotes inválido.')
    count = 0
    for key, item in content.items():
        if norm(key) != key or not isinstance(item, dict) or not isinstance(item.get('files'), dict) or not isinstance(item.get('deps'), list):
            raise QpkgError('Entrada inválida no registro.')
        Version(item.get('version', ''))
        for name, digest in item['files'].items():
            checked_target(name)
            if not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest):
                raise QpkgError('Hash inválido no registro.')
            count += 1
            if count > 50000:
                raise QpkgError('Registro excessivo.')
    return content

def save(data):
    tmp = None
    try:
        with tempfile.NamedTemporaryFile('w', encoding='utf8', dir=STATE, delete=False) as f:
            tmp = Path(f.name)
            json.dump(data, f, indent=2, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, INDEX)
    finally:
        if tmp is not None:
            tmp.unlink(missing_ok=True)


def validate_url(url):
    parsed = urllib.parse.urlparse(url)
    if (parsed.scheme != 'https' or parsed.hostname not in ALLOWED_HOSTS or
            parsed.username is not None or parsed.password is not None or
            parsed.port not in (None, 443)):
        raise QpkgError('Origem externa não autorizada.')
    return url


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Validate BEFORE following, including intermediate redirects.
        validate_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def https_get(url, cap=MAX_DOWNLOAD):
    validate_url(url)
    if not CACERT.is_file():
        raise QpkgError('Certificados HTTPS ausentes do QELTRAVYX.')
    ctx = ssl.create_default_context(cafile=str(CACERT))
    opener = urllib.request.build_opener(SafeRedirect(), urllib.request.HTTPSHandler(context=ctx))
    req = urllib.request.Request(url, headers={'User-Agent':'QELTRAVYX-qpkg/0.10', 'Accept':'application/json, */*'})
    with opener.open(req, timeout=35) as stream:
        validate_url(stream.url)
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
    if len(wheel_bytes) > MAX_DOWNLOAD:
        raise QpkgError('Wheel excede limite de download.')
    _, _, _, tags = parse_wheel_filename(filename)
    if not any(t.abi == 'none' and t.platform == 'any' and t.interpreter in ('py3', 'py2.py3') for t in tags):
        raise QpkgError('Apenas wheel universal Python puro.')
    if hashlib.sha256(wheel_bytes).hexdigest() != expected:
        raise QpkgError('SHA256 divergente: download rejeitado.')
    result = {}
    with zipfile.ZipFile(io.BytesIO(wheel_bytes)) as z:
        if len(z.infolist()) > MAX_FILES:
            raise QpkgError('Wheel contém arquivos demais.')
        total = 0
        seen = set()
        for item in z.infolist():
            name = item.filename.rstrip('/') if item.is_dir() else item.filename
            if (not name or name in seen or '\\' in name or '\x00' in name or
                    any(p in ('', '.', '..') for p in name.split('/'))):
                raise QpkgError('Caminho duplicado/inválido no wheel.')
            seen.add(name)
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

def apply_planned(planned, reg):
    existing = {p for item in reg.values() for p in item.get('files', {})}
    incoming = set()
    for item in planned.values():
        for name in item['files']:
            if name in existing or name in incoming or checked_target(name).exists():
                raise QpkgError('Conflito de arquivo; instalação cancelada: ' + name)
            incoming.add(name)
    # Stage complete verified bytes before publishing. An interrupted process leaves
    # a journal and blocks future mutations, rather than silently claiming success.
    changes = []
    journal = STATE / 'pending.json'
    with tempfile.TemporaryDirectory(prefix='install-', dir=STATE) as tmp:
        staging = Path(tmp)
        for item in planned.values():
            for name, data in item['files'].items():
                target = staging / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        journal.write_text(json.dumps({'operation': 'install', 'files': sorted(incoming)}))
        try:
            updated = dict(reg)
            for key, item in planned.items():
                hashes = {}
                for name, data in item['files'].items():
                    target = checked_target(name)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    # Atomic no-clobber publication on the same private filesystem.
                    os.link(staging / name, target)
                    changes.append(target)
                    (staging / name).unlink()
                    hashes[name] = hashlib.sha256(data).hexdigest()
                updated[key] = {'version': item['version'], 'files': hashes, 'deps': item['deps']}
            save(updated)
        except BaseException:
            for file in reversed(changes):
                file.unlink(missing_ok=True)
            journal.unlink()
            raise
        journal.unlink()
    for key, item in planned.items():
        print(f'Instalado: {key} {item["version"]}')


def install(arg):
    request = Requirement(arg)
    if request.url or request.extras:
        raise QpkgError('Use apenas nome ou nome==versão, sem extras/URL.')
    with transaction_lock():
        reg = registry()
        planned = {}
        resolve(request, planned, reg, set())
        if not planned:
            print('Pacote já instalado e compatível.'); return
        apply_planned(planned, reg)


def install_local(filename, expected):
    path = Path(filename)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_DOWNLOAD:
        raise QpkgError('Wheel local inválido/excessivo.')
    with path.open('rb') as stream:
        files, metadata = unpack(stream.read(MAX_DOWNLOAD + 1), path.name, expected)
    key, version = norm(metadata['Name']), str(Version(metadata['Version']))
    wheel_name, wheel_version, _, _ = parse_wheel_filename(path.name)
    if key != wheel_name or Version(version) != wheel_version:
        raise QpkgError('Metadados não correspondem ao nome do wheel.')
    requires_python = metadata.get('Requires-Python')
    if requires_python and Version('.'.join(map(str, sys.version_info[:3]))) not in SpecifierSet(requires_python):
        raise QpkgError('Versão de Python incompatível.')
    with transaction_lock():
        reg = registry()
        deps = []
        for value in metadata.get_all('Requires-Dist', []):
            dep = Requirement(value)
            if dep.marker is not None and not dep.marker.evaluate(environment={**default_environment(), 'extra': ''}):
                continue
            if dep.url or dep.extras or norm(dep.name) not in reg or Version(reg[norm(dep.name)]['version']) not in dep.specifier:
                raise QpkgError('Dependência local ausente/incompatível: ' + str(dep))
            deps.append(norm(dep.name))
        if key in reg:
            if reg[key]['version'] != version:
                raise QpkgError('Upgrade preservado/bloqueado: substituição requer migração revisada.')
            hashes = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
            if hashes != reg[key]['files'] or any(not checked_target(n).is_file() or hashlib.sha256(checked_target(n).read_bytes()).hexdigest() != h for n, h in hashes.items()):
                raise QpkgError('Reinstall bloqueado: conteúdo alterado; arquivos preservados.')
            print('Pacote já instalado e íntegro.'); return
        apply_planned({key: {'version': version, 'files': files, 'deps': deps}}, reg)


def catalog():
    print('QPKG 0.10 | catálogo local; presença não comprova execução')
    print('Python wheels: install-local ARQUIVO.whl SHA256; sem rede/scripts')
    print('pip: política offline própria; consulte pip --version')
    print('npm/Node/Git: empacotamento nativo via APK; consulte Runtimes e execute os smokes')
    print('apt/pkg: indisponível; nenhum bootstrap Android instalado')
    for name, item in sorted(registry().items()):
        print(name, item['version'], '| integrity:', 'registrada, use verify')


def verify_installed():
    failures = []
    for key, item in registry().items():
        for name, expected in item['files'].items():
            file = checked_target(name)
            if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
                failures.append(key + ': ' + name)
    if failures:
        raise QpkgError('Integridade divergente: ' + ', '.join(failures[:5]))
    print('Integridade dos arquivos registrados: OK')


def remove_unlocked(name):
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
    journal = STATE / 'pending.json'
    # Persistent backup survives an interrupted/failed rollback; never discard the
    # only copy of pre-existing user files on an error path.
    staging = Path(tempfile.mkdtemp(prefix='remove-', dir=STATE))
    saved = []
    journal.write_text(json.dumps({'operation': 'remove', 'package': key, 'files': files, 'backup': staging.name}))
    try:
        for fname in files:
            source = checked_target(fname)
            if not source.exists():
                continue
            backup = staging / fname
            backup.parent.mkdir(parents=True, exist_ok=True)
            os.link(source, backup)
            saved.append((source, backup))
            source.unlink()
        updated = dict(reg)
        del updated[key]
        save(updated)
    except BaseException:
        # If any restoration fails, keep journal + backup for manual recovery.
        for source, backup in reversed(saved):
            if not source.exists():
                os.link(backup, source)
        shutil.rmtree(staging)
        journal.unlink()
        raise
    shutil.rmtree(staging)
    journal.unlink()
    print('Removido:', key)


def main(argv):
    if not argv or argv[0] in ('help','--help','-h'):
        print('QELTRAVYX qpkg 0.10\n  qpkg list\n  qpkg install --allow-network <pacote>\n  qpkg install-local ARQUIVO.whl SHA256\n  qpkg catalog\n  qpkg verify\n  qpkg remove <pacote>\n  qpkg info <pacote>\n  qpkg doctor\nSuporta apenas wheels Python puros do PyPI, com SHA256. Não é pip.')
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
    elif cmd == 'catalog' and not args:
        catalog()
    elif cmd == 'verify' and not args:
        verify_installed()
    elif cmd == 'install-local' and len(args) == 2:
        install_local(*args)
    elif cmd == 'install' and len(args) == 2 and args[0] == '--allow-network':
        install(args[1])
    elif cmd == 'install':
        raise QpkgError('Rede requer consentimento explícito: qpkg install --allow-network NOME. Para offline use install-local.')
    elif cmd == 'remove' and len(args)==1:
        with transaction_lock():
            remove_unlocked(args[0])
    else:
        raise QpkgError('Sintaxe inválida. Use: qpkg help')

if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except KeyboardInterrupt:
        print('QPKG cancelado; verifique pending.json se houver interrupção abrupta.', file=sys.stderr)
        sys.exit(130)
    except (QpkgError, ValueError, OSError, json.JSONDecodeError, zipfile.BadZipFile) as exc:
        print('QPKG ERRO:',exc,file=sys.stderr)
        sys.exit(1)
