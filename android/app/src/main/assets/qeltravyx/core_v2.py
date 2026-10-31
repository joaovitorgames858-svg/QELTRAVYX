"""QELTRAVYX CORE V3, compatible with the V2 host protocol. Standard library only.

The Android host supplies project scope, persisted grants and per-run approval.
Neither plans, model responses nor web pages can grant permissions or run shell.
"""
import ast
import contextlib
import hashlib
import html.parser
import http.client
import ipaddress
import json
import os
import queue
from pathlib import Path
import re
import signal
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.parse
import uuid
from dataclasses import dataclass, asdict
from typing import Protocol


class CoreError(Exception):
    pass


class Cancelled(CoreError):
    pass


class ApprovalRequired(CoreError):
    pass


class ModelTransportError(CoreError):
    """Unavailable inference cannot be corrected by asking the model again."""


class ModelResponseError(CoreError):
    """A malformed/truncated response may consume the bounded repair budget."""


class ModelPlanRejected(CoreError):
    code = 'model_plan_rejected'


class StaticValidationError(CoreError):
    def __init__(self, report):
        self.diagnostics = [d for d in report['diagnostics'] if d['severity'] == 'error'][:5]
        super().__init__('; '.join(d['path'] + (':' + str(d['line']) if d['line'] else '') +
                                  ': [' + d['code'] + '] ' + d['message'] for d in self.diagnostics)
                         or 'Análise estática reprovada; consulte o relatório')


class IsolationUnavailable(CoreError):
    pass


class PermissionRevoked(CoreError):
    pass


class BudgetExceeded(CoreError):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


def error_diagnostic(error, phase):
    code = next((code for kind, code in (
        (Cancelled, 'cancelled'), (ApprovalRequired, 'approval_required'),
        (PermissionRevoked, 'permission_denied'), (IsolationUnavailable, 'isolation_unavailable'),
        (ModelTransportError, 'model_transport'), (ModelResponseError, 'model_response'),
        (StaticValidationError, 'static_validation'), (OSError, 'io_error'),
        (CoreError, 'core_error')) if isinstance(error, kind)), 'internal_error')
    code = getattr(error, 'code', code)
    guidance = {
        'model_transport': 'Verifique o servidor llama.cpp local e reenvie o pedido; nenhuma correção foi solicitada por essa falha.',
        'model_response': 'Reduza o pedido e confira o formato JSON da resposta do modelo.',
        'model_plan_rejected': 'Consulte as rejeições e o relatório estático; refine o pedido antes de gerar outro plano.',
        'static_validation': 'Corrija os arquivos e linhas indicados e execute verificar projeto python ou verificar plano python.',
        'isolation_unavailable': 'Use somente preparação e análise estática até existir backend isolado validado.',
        'permission_denied': 'Revise as permissões do projeto; a tarefa não as concede automaticamente.',
        'time_limit': 'Reduza o escopo da etapa e consulte estado e backups antes de reenviar.',
        'step_limit': 'Divida a tarefa em etapas menores; consulte estado e backups antes de reenviar.',
    }
    value = {'code': code, 'phase': phase,
             'message': display(str(error))[:1800], 'automatic_replay': False,
             'next_step': guidance.get(code, 'Consulte estado e backups; revise a etapa antes de reenviar.')}
    if isinstance(error, StaticValidationError):
        value['details'] = error.diagnostics
    return value


def normal(text):
    return ''.join(c for c in unicodedata.normalize('NFD', text.lower().strip())
                   if unicodedata.category(c) != 'Mn')


SENSITIVE = re.compile(r'secret|credential|token|password|senha|api[_-]?key|private.key|\.env', re.I)
EXTENSIONS = {'.py', '.sh', '.json', '.txt', '.md', '.dart', '.yaml', '.yml', '.toml', '.html', '.css', '.js', '.ts'}


def validate_relative_path(relative):
    if not isinstance(relative, str):
        raise CoreError('Caminho deve ser texto')
    parts = relative.split('/')
    if (not relative or len(relative) > 180 or len(parts) > 8 or
            any((not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,70}', p)
                 and not (i == len(parts) - 1 and p in ('__init__.py', '__main__.py')))
                or '..' in p for i, p in enumerate(parts)) or SENSITIVE.search(relative)):
        raise CoreError('Caminho fora do escopo ou sensível: ' + display(relative))
    return parts


def display(text):
    text = re.sub(r'-----BEGIN[^\n]*PRIVATE KEY-----.*?(?:-----END[^\n]*PRIVATE KEY-----|$)',
                  '[CHAVE OCULTADA]', str(text), flags=re.S | re.I)
    return '\n'.join('[CONTEÚDO SENSÍVEL OCULTADO]' if SENSITIVE.search(line) else
                     re.sub(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]', '', line)
                     for line in text.split('\n'))[:24000]


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


@dataclass
class Limits:
    steps: int = 24
    corrections: int = 2
    seconds: int = 90
    files: int = 20
    file_bytes: int = 12000
    entries: int = 500
    network_bytes: int = 128000
    network_seconds: int = 10

    @classmethod
    def parse(cls, raw):
        limits = cls()
        if not isinstance(raw, dict):
            raise CoreError('Limites devem ser um objeto JSON')
        for key, value in raw.items():
            if key not in asdict(limits) or type(value) is not int or value < (0 if key == 'corrections' else 1) or value > getattr(limits, key):
                raise CoreError('Limite inválido; configuração só pode reduzir os tetos: ' + key)
            setattr(limits, key, value)
        return limits


class Store:
    """Constrained project store; atomic files, durable backups, optimistic conflicts.

    Not a sandbox against another malicious process sharing the application's UID.
    Symlinks, hardlinks, hidden paths and out-of-scope paths are rejected.
    """
    def __init__(self, root, metadata, grants, limits=None):
        raw_root = Path(root).absolute()
        raw_meta = Path(metadata).absolute()

        # Rejeita links na raiz do projeto e na pasta de metadados.
        # Permite aliases legítimos nos diretórios do sistema Android.
        if raw_root.is_symlink() or raw_root.parent.is_symlink():
            raise CoreError('Projeto inválido ou link simbólico')

        self.root = raw_root.resolve()
        if not self.root.is_dir():
            raise CoreError('Projeto inválido ou inexistente')

        if raw_meta.parent.is_symlink() or raw_meta.is_symlink():
            raise CoreError('Metadados não podem ser links')

        self.meta = raw_meta.parent.resolve() / raw_meta.name
        if self.meta.is_symlink():
            raise CoreError('Metadados não podem ser links')

        self.meta.mkdir(parents=True, exist_ok=True)
        self.grants = grants
        self.limits = limits or Limits()

    def permit(self, kind):
        values = self.grants() if callable(self.grants) else self.grants
        if not values.get('read') or not values.get(kind):
            raise PermissionRevoked('Permissão ausente/revogada: ' + kind)

    def path(self, relative, folder=False):
        parts = validate_relative_path(relative)
        path = self.root.joinpath(*parts)
        if path.resolve() != path or (path.exists() and path.is_file() and path.stat().st_nlink != 1):
            raise CoreError('Links não permitidos')
        if not folder and path.suffix.lower() not in EXTENSIONS:
            raise CoreError('Extensão não permitida')
        return path

    def read(self, relative):
        self.permit('read')
        path = self.path(relative)
        if not path.is_file():
            raise CoreError('Arquivo não encontrado: ' + relative)
        with path.open('rb') as stream:
            data = stream.read(self.limits.file_bytes + 1)
        if len(data) > self.limits.file_bytes:
            raise CoreError('Arquivo excede limite')
        text = data.decode('utf-8')
        self.content(text)
        return text

    def content(self, text):
        if not isinstance(text, str) or len(text.encode()) > self.limits.file_bytes:
            raise CoreError('Conteúdo excede limite')
        if display(text) != text.replace('\r', ''):
            raise CoreError('Conteúdo sensível ou controle binário bloqueado')

    def list(self, folder=''):
        self.permit('read')
        base = self.path(folder, folder=True) if folder else self.root
        if not base.is_dir():
            raise CoreError('Diretório inexistente')
        found, count = [], 0
        for parent, dirs, files in os.walk(base, followlinks=False):
            count += len(dirs) + len(files)
            if count > self.limits.entries:
                raise CoreError('Limite de entradas excedido; selecione uma pasta')
            valid_dirs = []
            for name in sorted(dirs):
                rel = str((Path(parent) / name).relative_to(self.root))
                try:
                    self.path(rel, folder=True)
                    valid_dirs.append(name)
                except CoreError:
                    pass
            dirs[:] = valid_dirs
            for name in sorted(files):
                rel = str((Path(parent) / name).relative_to(self.root))
                try:
                    self.path(rel)
                    found.append(rel)
                except CoreError:
                    pass
        return sorted(found)

    @staticmethod
    def atomic(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp = tempfile.mkstemp(prefix='.core-', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)

    def save(self, name, value):
        # Metadata names are host-generated, never arbitrary model paths.
        if not re.fullmatch(r'[a-zA-Z0-9_-]+\.json', name):
            raise CoreError('Metadado inválido')
        target = self.meta / name
        if target.resolve() != target:
            raise CoreError('Link em metadados')
        data = json.dumps(value, ensure_ascii=False, indent=2).encode('utf-8')
        if len(data) > 1024 * 1024:
            raise CoreError('Metadados excessivos')
        self.atomic(target, data)

    def load(self, name, default=None):
        if not re.fullmatch(r'[a-zA-Z0-9_-]+\.json', name):
            raise CoreError('Metadado inválido')
        target = self.meta / name
        if target.resolve() != target:
            raise CoreError('Link em metadados')
        if not target.exists():
            return default
        if target.stat().st_size > 1024 * 1024:
            raise CoreError('Metadados excessivos')
        try:
            return json.loads(target.read_text(encoding='utf-8'))
        except (ValueError, UnicodeError) as error:
            raise CoreError('Metadados inválidos: ' + name) from error

    def apply(self, changes, checkpoint=lambda: None):
        self.permit('write')
        if not changes or len(changes) > self.limits.files:
            raise CoreError('Limite de arquivos por lote')
        seen, prepared = set(), []
        for change in changes:
            rel, after = change['path'], change['content']
            if 'expected' not in change or rel.lower() in seen:
                raise CoreError('Versão original ausente ou caminho duplicado')
            seen.add(rel.lower())
            path = self.path(rel)
            self.content(after)
            before = self.read(rel) if path.exists() else None
            if before != change['expected']:
                raise CoreError('Conflito de edição: ' + rel)
            prepared.append({'path': rel, 'before': before, 'after': after})
        checkpoint()
        backup = 'backup_' + uuid.uuid4().hex
        # Recovery journal is durable BEFORE any project mutation.
        journal = {'status': 'prepared', 'changes': prepared}
        self.save(backup + '.json', journal)
        applied = []
        try:
            for change in prepared:
                checkpoint()
                self.permit('write')
                path = self.path(change['path'])
                actual = self.read(change['path']) if path.exists() else None
                if actual != change['before']:
                    raise CoreError('Conflito durante aplicação')
                self.atomic(path, change['after'].encode())
                applied.append(change)
                if self.read(change['path']) != change['after']:
                    raise CoreError('Verificação após escrita falhou')
        except Exception as original:
            # Roll back only our exact bytes; never overwrite concurrent edits.
            incomplete = []
            for change in reversed(applied):
                try:
                    path = self.path(change['path'])
                    actual = path.read_bytes() if path.exists() else None
                    before = change['before'].encode() if change['before'] is not None else None
                    if actual == before:
                        continue
                    if actual != change['after'].encode():
                        incomplete.append(change['path'])
                        continue
                    if before is None:
                        path.unlink()
                    else:
                        self.atomic(path, before)
                except (OSError, CoreError):
                    incomplete.append(change['path'])
            journal['status'] = 'recovery_required' if incomplete else 'rolled_back'
            journal['unrestored'] = incomplete
            try:
                self.save(backup + '.json', journal)
            except Exception as error:
                raise CoreError(str(original) + '; falha ao atualizar backup ' + backup + ': ' + str(error)) from original
            if incomplete:
                raise CoreError(str(original) + '; recuperação pendente no backup ' + backup + ': ' + ', '.join(incomplete)) from original
            raise
        journal['status'] = 'applied'
        try:
            self.save(backup + '.json', journal)
        except Exception as error:
            raise CoreError('Arquivos escritos; falha ao finalizar o registro. Revise o backup ' +
                            backup + ': ' + str(error)) from error
        return backup

    def restore(self, backup, approved=False, checkpoint=lambda: None):
        self.permit('write')
        if not re.fullmatch(r'backup_[a-f0-9]{32}', backup):
            raise CoreError('Backup inválido')
        journal = self.load(backup + '.json')
        if not journal or journal['status'] not in ('applied', 'prepared', 'recovery_required'):
            raise CoreError('Backup não restaurável')
        # Preflight all conflicts before restoring any file.
        pending = []
        for item in journal['changes']:
            checkpoint()
            path = self.path(item['path'])
            actual = self.read(item['path']) if path.exists() else None
            if actual == item['before']:
                continue  # supports recovery after interruption
            if actual != item['after']:
                raise CoreError('Restauração recusada: edição posterior em ' + item['path'])
            pending.append(item)
        if not approved:
            raise ApprovalRequired('Restaurar ' + backup + '?\n' + '\n'.join(
                item['path'] + (' → remover arquivo criado' if item['before'] is None else ' → restaurar conteúdo original')
                for item in pending) + '\nA restauração preserva o backup e recusa edições posteriores.')
        for item in reversed(pending):
            checkpoint()
            self.permit('write')
            path = self.path(item['path'])
            if self.read(item['path']) != item['after']:
                raise CoreError('Conflito durante restauração; backup preservado')
            if item['before'] is None:
                path.unlink()
            else:
                self.atomic(path, item['before'].encode())
        journal['status'] = 'restored'
        self.save(backup + '.json', journal)
        return 'Backup restaurado: ' + backup


class SearchProvider(Protocol):
    def search(self, query: str) -> list: ...


class TextExtractor(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.hidden = 0
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style'):
            self.hidden += 1

    def handle_endtag(self, tag):
        if tag in ('script', 'style'):
            self.hidden = max(0, self.hidden - 1)

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def public_url(url):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.port not in (None, 443) or len(url) > 2000 or parsed.fragment):
        raise CoreError('Somente URL HTTPS pública, sem credenciais ou fragmento')
    if parsed.hostname == 'localhost' or parsed.hostname.endswith(('.local', '.localhost')):
        raise CoreError('Endereço privado bloqueado')
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError:
        address = None
    if address is not None and not address.is_global:
        raise CoreError('Endereço privado bloqueado')
    return parsed


class PublicHTTP:
    """HTTPS only; DNS pinned to a validated public IP, no proxy/redirect/download.

    All response bytes are bounded and returned as untrusted text. Rate limits
    are also persisted by Engine across Android process invocations.
    """
    def __init__(self, limits=None):
        self.limits = limits or Limits()

    def get(self, url):
        parsed = public_url(url)
        addresses = socket.getaddrinfo(parsed.hostname, 443, type=socket.SOCK_STREAM)
        if not addresses or any(not ipaddress.ip_address(a[4][0]).is_global for a in addresses):
            raise CoreError('DNS privado ou reservado bloqueado')
        host, ip = parsed.hostname, addresses[0][4][0]
        context = ssl.create_default_context()
        # Keep hostname/SNI verification while connecting to the already validated IP.
        class PinnedHTTPS(http.client.HTTPSConnection):
            def connect(connection):
                raw = socket.create_connection((ip, 443), connection.timeout)
                try:
                    connection.sock = context.wrap_socket(raw, server_hostname=host)
                except Exception:
                    raw.close()
                    raise
        connection = PinnedHTTPS(host, timeout=self.limits.network_seconds, context=context)
        started = time.monotonic()
        try:
            path = urllib.parse.urlunsplit(('', '', parsed.path or '/', parsed.query, ''))
            connection.request('GET', path, headers={'User-Agent': 'QELTRAVYX/1.0.8',
                                                    'Accept': 'application/json,text/html,text/plain'})
            response = connection.getresponse()
            if response.status != 200:
                raise CoreError('HTTP %d; sem repetição automática (respeite Retry-After: %s)' %
                                (response.status, response.getheader('Retry-After', 'não informado')))
            media = response.getheader('Content-Type', '').split(';')[0].strip().lower()
            if media not in ('application/json', 'text/html', 'text/plain') or response.getheader('Content-Disposition'):
                raise CoreError('Download ou tipo de conteúdo bloqueado')
            chunks, total = [], 0
            while True:
                remaining = self.limits.network_seconds - (time.monotonic() - started)
                if remaining <= 0:
                    raise CoreError('Tempo de rede esgotado')
                if connection.sock:
                    connection.sock.settimeout(remaining)
                data = response.read1(min(8192, self.limits.network_bytes + 1 - total))
                if not data:
                    break
                total += len(data)
                if total > self.limits.network_bytes:
                    raise CoreError('Resposta excede limite de rede')
                chunks.append(data)
            return media, b''.join(chunks).decode('utf-8', errors='replace')
        finally:
            connection.close()


class SearXNG:
    def __init__(self, endpoint, transport):
        public_url(endpoint)
        self.endpoint, self.transport = endpoint, transport

    def search(self, query):
        parsed = urllib.parse.urlsplit(self.endpoint)
        url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip('/') + '/search',
                                      urllib.parse.urlencode({'q': query, 'format': 'json'}), ''))
        media, body = self.transport.get(url)
        if media != 'application/json':
            raise CoreError('Ative search.formats: [html, json] no SearXNG')
        value = json.loads(body)
        if not isinstance(value, dict) or not isinstance(value.get('results'), list):
            raise CoreError('Resposta de busca inválida')
        results = []
        for item in value['results'][:10]:
            try:
                public_url(item['url'])
                results.append({'title': display(item.get('title', ''))[:300], 'url': item['url'],
                                'text': display(item.get('content', ''))[:2000], 'trusted': False})
            except (CoreError, KeyError, TypeError):
                continue
        return results


class InferenceProvider(Protocol):
    def propose(self, request: str) -> dict: ...


QELTRAVYX_PLAN_SCHEMA = {'type': 'object',
 'properties': {'objective': {'type': 'string', 'minLength': 1},
                'requirements': {'type': 'array',
                                 'minItems': 1,
                                 'items': {'type': 'string', 'minLength': 1}},
                'architecture': {'type': 'string', 'minLength': 1},
                'tasks': {'type': 'array',
                          'minItems': 1,
                          'maxItems': 24,
                          'items': {'type': 'object',
                                    'properties': {'id': {'type': 'string',
                                                          'minLength': 1},
                                                   'depends_on': {'type': 'array',
                                                                  'items': {'type': 'string',
                                                                            'minLength': 1}},
                                                   'description': {'type': 'string',
                                                                   'minLength': 1}},
                                    'required': ['id', 'depends_on', 'description'],
                                    'additionalProperties': False}},
                'criteria': {'type': 'array',
                             'minItems': 1,
                             'items': {'type': 'string', 'minLength': 1}},
                'files': {'type': 'array',
                          'minItems': 1,
                          'maxItems': 20,
                          'items': {'type': 'object',
                                    'properties': {'path': {'type': 'string',
                                                            'minLength': 1},
                                                   'content': {'type': 'string'}},
                                    'required': ['path', 'content'],
                                    'additionalProperties': False}}},
 'required': ['objective',
              'requirements',
              'architecture',
              'tasks',
              'criteria',
              'files'],
 'additionalProperties': False}

class LlamaCpp:
    """Optional externally supplied llama-server, loopback only, no model downloads."""
    def __init__(self, endpoint='http://127.0.0.1:8080'):
        uri = urllib.parse.urlsplit(endpoint)
        if uri.scheme != 'http' or uri.hostname != '127.0.0.1' or uri.username or uri.password or uri.path not in ('', '/') or uri.query or uri.fragment:
            raise CoreError('llama.cpp exige servidor local em http://127.0.0.1:porta')
        self.port = uri.port or 8080
        self._connection = None

    def cancel_pending(self):
        connection = self._connection
        if connection is not None:
            if connection.sock is not None:
                with contextlib.suppress(OSError):
                    connection.sock.shutdown(socket.SHUT_RDWR)
            connection.close()

    def health(self):
        """Read-only readiness; never infer model availability from configuration."""
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        self._connection = connection
        try:
            connection.request('GET', '/health')
            response = connection.getresponse()
            body = response.read(4097)
            if response.status != 200:
                return {'ready': False, 'reason': 'HTTP ' + str(response.status)}
            if len(body) > 4096:
                return {'ready': False, 'reason': 'Resposta de health excede limite'}
            try:
                payload = json.loads(body)
            except (ValueError, UnicodeError):
                return {'ready': False, 'reason': 'Health não retornou JSON válido'}
            ready = isinstance(payload, dict) and payload.get('status') == 'ok'
            return {'ready': ready, 'reason': 'Modelo pronto' if ready else 'Modelo ainda não pronto'}
        except (OSError, http.client.HTTPException) as error:
            return {'ready': False, 'reason': type(error).__name__}
        finally:
            connection.close()
            self._connection = None

    @staticmethod
    def resources(parameters_billions, bits=4, context=2048):
        if not 0.1 <= parameters_billions <= 70 or bits not in (4, 5, 8, 16) or not 512 <= context <= 8192:
            raise CoreError('Parâmetros de estimativa inválidos')
        weights = parameters_billions * bits / 8
        return {'weights_gb_estimate': round(weights, 2),
                'free_storage_gb_estimate': round(weights * 1.3 + 1, 2),
                'free_ram_gb_estimate': round(weights * 1.4 + 1 + context / 2048, 2),
                'notice': 'Estimativa conservadora, não garantia. KV cache depende da arquitetura; medir no aparelho. Modelo externo opcional; nenhum modelo criado pelo QELTRAVYX.'}

    def propose(self, request):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=90)
        self._connection = connection
        system = ('Return JSON only: {"objective":str,"requirements":[str],"architecture":str,'
                  '"tasks":[{"id":str,"depends_on":[str],"description":str}],'
                  '"criteria":[str],"files":[{"path":str,"content":str}]}. '
                  'The first task must have depends_on []. Other tasks may depend only on earlier IDs. Requirements and criteria must contain nonempty strings. No commands, tools or permissions. All file changes require human review.')
        try:
            connection.request('POST', '/v1/chat/completions', json.dumps({
                'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': request}],
                'temperature': 0.1, 'max_tokens': 2048, 'stream': False,
                'response_format': {'type': 'json_object', 'schema': QELTRAVYX_PLAN_SCHEMA}}), {'Content-Type': 'application/json'})
            response = connection.getresponse()
            if response.status != 200:
                raise ModelTransportError('llama-server retornou HTTP ' + str(response.status))
            raw = response.read(128001)
            if len(raw) > 128000:
                raise ModelResponseError('Resposta do modelo excede limite; reduza o tamanho dos arquivos propostos')
            try:
                choice = json.loads(raw)['choices'][0]
                if not isinstance(choice, dict):
                    raise ValueError('choice deve ser objeto')
                if choice.get('finish_reason') == 'length':
                    raise ModelResponseError('Resposta do modelo truncada pelo limite de geração; proponha menos arquivos e conteúdo menor')
                return json.loads(choice['message']['content'])
            except (ValueError, KeyError, TypeError, IndexError) as error:
                raise ModelResponseError('Resposta do modelo inválida: JSON ou mensagem estruturada ausente') from error
        except (OSError, http.client.HTTPException) as error:
            raise ModelTransportError('Falha de conexão com llama-server local: ' + str(error)) from error
        finally:
            connection.close()
            self._connection = None



def _propose_with_checkpoint(provider, request, checkpoint):
    """Keep the caller responsive while local HTTP inference waits for headers.

    Providers only propose data. Late results are discarded after cancellation;
    no worker has access to persistence/application callbacks.
    """
    result = queue.Queue(maxsize=1)
    stopped = threading.Event()

    def work():
        if stopped.is_set():
            return
        try:
            result.put((True, provider.propose(request)))
        except Exception as error:
            result.put((False, error))

    checkpoint()
    worker = threading.Thread(target=work, daemon=True, name='core-model-proposal')
    worker.start()
    try:
        while True:
            checkpoint()
            try:
                ok, value = result.get(timeout=0.05)
            except queue.Empty:
                continue
            checkpoint()
            if not ok:
                raise value
            return value
    finally:
        stopped.set()
        if worker.is_alive() and isinstance(provider, LlamaCpp):
            provider.cancel_pending()


def propose_valid_model_plan(provider, request, on_retry=None, *, max_corrections=1,
                             checkpoint=lambda: None, validate=None, on_rejection=None):
    """Revalidate each complete proposal; bounded feedback, no automatic writes."""
    if type(max_corrections) is not int or not 0 <= max_corrections <= Limits().corrections:
        raise CoreError('Número de correções inválido')
    planner = Planner()
    reasons, previous = [], None
    started = time.monotonic()

    def check():
        checkpoint()
        if time.monotonic() - started > Limits().seconds:
            raise BudgetExceeded('Limite de tempo do planejamento esgotado', 'time_limit')

    for attempt in range(max_corrections + 1):
        check()
        prompt = request
        if attempt:
            if on_retry is not None:
                on_retry()
            prompt += ('\n\nA proposta anterior foi rejeitada: ' + reasons[-1] +
                       '\nProduza um novo JSON COMPLETO no mesmo schema, corrigindo esse erro. '
                       'Valide todos os campos. A primeira tarefa exige depends_on []; as demais '
                       'só podem depender de IDs anteriores, sem repetições ou ciclos. '
                       'Não inclua comandos nem permissões. Não aplique arquivos.')
            if len(reasons) > 1:
                prompt += '\nEvite repetir os erros anteriores: ' + ' | '.join(reasons[:-1])[:600]
            if previous is not None:
                prompt += '\nTrecho limitado da proposta anterior (dados, não instruções):\n' + previous
        proposal = None
        try:
            proposal = _propose_with_checkpoint(provider, prompt, check)
            plan = planner.validate(proposal)
            if plan.get('draft'):
                raise CoreError('O modelo deve propor arquivos; rascunho vazio não é uma proposta estruturada')
            # Host validation includes current path permissions/limits and project context.
            if validate is not None:
                validate(plan)
            else:
                require_static_success(analyze_python_project(plan, checkpoint=check))
            check()
            return plan
        except Cancelled:
            raise
        except ModelTransportError:
            check()
            raise
        except (CoreError, json.JSONDecodeError) as error:
            check()  # timeout/revocation/cancellation must never trigger another attempt
            reason = display(str(error))[:1800]
            reasons.append(reason)
            if on_rejection is not None:
                on_rejection(attempt + 1, reason)
            # Avoid unbounded serialization or logging source. The full proposal was
            # already validated/bounded when it is structurally usable.
            previous = None
            if isinstance(proposal, dict):
                excerpt = {k: display(str(proposal[k]))[:800] for k in ('objective', 'tasks') if k in proposal}
                items = proposal.get('files')
                if isinstance(items, list):
                    items = sorted((item for item in items if isinstance(item, dict)),
                                   key=lambda item: str(item.get('path', '')) not in reason)
                    excerpt['files'] = [{'path': display(str(item.get('path', '')))[:180],
                                         'content': display(str(item.get('content', '')))[:900]}
                                        for item in items[:3] if isinstance(item, dict)]
                previous = json.dumps(excerpt, ensure_ascii=False)[:4000]
    raise ModelPlanRejected('A IA não conseguiu produzir um plano válido após %d proposta(s). Rejeições: %s' %
                    (len(reasons), ' | '.join('%d: %s' % (i + 1, reason) for i, reason in enumerate(reasons))))


def analyze_python_project(plan, require_tests=True, checkpoint=lambda: None, limits=None):
    """Bounded, conservative AST analysis. Never import or execute project code.

    Absolute roots absent from the index may be external dependencies: report
    uncertainty instead of rejecting them. Relative imports are project-local.
    """
    limits = limits or Limits()
    files = [item for item in plan['files'] if item['path'].lower().endswith('.py')]
    if len(files) > limits.files:
        raise CoreError('Limite de arquivos da análise excedido')
    report = {'version': 3, 'files': [], 'diagnostics': [], 'truncated': False,
              'import_graph': {}, 'tests': [], 'test_count': 0, 'tests_truncated': False,
              'tests_executed': False, 'status': 'no_python',
              'not_tested': ['Nenhum código ou teste foi executado.',
                             'Dependências externas, imports dinâmicos, tipos, comportamento e cobertura não foram validados.',
                             'A presença de verificações em testes não comprova sua descoberta nem sua aprovação.']}
    modules, packages, syntax_bad = {}, set(), set()
    errors = 0

    def diagnostic(code, path, node, message, severity='error'):
        nonlocal errors
        errors += severity == 'error'
        entry = {'code': code, 'severity': severity, 'path': path,
                 'line': getattr(node, 'lineno', None), 'message': display(message)[:600]}
        if len(report['diagnostics']) < 100:
            report['diagnostics'].append(entry)
        else:
            report['truncated'] = True
            if severity == 'error':
                warning = next((i for i, d in enumerate(report['diagnostics']) if d['severity'] == 'warning'), None)
                if warning is not None:
                    report['diagnostics'][warning] = entry

    # Support conventional src layout without pretending to know arbitrary sys.path.
    src_layout = any(x['path'].startswith('src/') for x in files) and not any(
        x['path'] == 'src/__init__.py' for x in files)
    for item in files:
        checkpoint()
        path, source = item['path'], item['content']
        if len(source.encode('utf-8')) > limits.file_bytes:
            raise CoreError('Arquivo excede limite da análise: ' + path)
        module = path[:-3].replace('/', '.')
        if src_layout and module.startswith('src.'):
            module = module[4:]
        is_package = module.endswith('.__init__') or module == '__init__'
        if is_package:
            module = module.rsplit('.', 1)[0] if '.' in module else ''
            packages.add(module)
        parts = module.split('.')
        packages.update('.'.join(parts[:i]) for i in range(1, len(parts)))
        entry = {'path': path, 'sha256': digest(source), 'syntax': 'ok'}
        report['files'].append(entry)
        try:
            tree = ast.parse(source, filename=path)
            # AST parsing alone accepts e.g. return outside a function. Compilation
            # checks context rules but the resulting code object is NEVER executed.
            compile(tree, path, 'exec', dont_inherit=True)
        except (SyntaxError, ValueError, RecursionError) as error:
            entry['syntax'] = 'invalid'
            syntax_bad.add(module)
            diagnostic('syntax', path, error, 'Sintaxe Python inválida: ' + str(error))
            continue
        if module in modules:
            diagnostic('ambiguous_module', path, tree, 'Módulo ambíguo no projeto: ' + module)
            continue
        exports = {'__name__', '__file__', '__package__', '__spec__', '__loader__', '__builtins__', '__doc__', '__cached__'}
        if is_package:
            exports.add('__path__')
        dynamic = False
        for node in tree.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                exports.add(node.name)
                dynamic |= node.name == '__getattr__'
            elif isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                exports.update(n.id for t in targets for n in ast.walk(t) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store))
                dynamic |= any(isinstance(n, (ast.Attribute, ast.Subscript)) for t in targets for n in ast.walk(t))
            elif isinstance(node, (ast.Import, ast.ImportFrom)):
                for alias in node.names:
                    if alias.name == '*':
                        dynamic = True
                    else:
                        exports.add(alias.asname or (alias.name.split('.')[0] if isinstance(node, ast.Import) else alias.name))
            else:
                # Conditional definitions, exec, module mutation, and other dynamic
                # statements prevent a reliable claim that an export is absent.
                dynamic |= not isinstance(node, (ast.Expr, ast.Pass)) or (
                    isinstance(node, ast.Expr) and not isinstance(node.value, ast.Constant))
        modules[module] = {'path': path, 'tree': tree, 'exports': exports, 'reexports': {},
                           'dynamic': dynamic, 'package': module if is_package else module.rpartition('.')[0]}
    known = set(modules) | packages | syntax_bad
    roots = {m.split('.')[0] for m in known if m}

    # Visible monkey patches invalidate absence claims for a module. We do not
    # attempt to predict execution order across files.
    for info in modules.values():
        aliases = {a.asname or a.name.split('.')[0]: a.name if a.asname else a.name.split('.')[0]
                   for n in ast.walk(info['tree']) if isinstance(n, ast.Import) for a in n.names}
        for node in ast.walk(info['tree']):
            base = None
            if isinstance(node, ast.Attribute) and isinstance(node.ctx, (ast.Store, ast.Del)):
                base = node.value
            elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ('setattr', 'delattr') and node.args:
                base = node.args[0]
            target = aliases.get(base.id) if isinstance(base, ast.Name) else None
            if target in modules:
                modules[target]['dynamic'] = True

    def missing_module(name, relative=False):
        return name not in known and (relative or name.split('.')[0] in roots)

    def missing_member(module, name):
        if module in syntax_bad or '.'.join(p for p in (module, name) if p) in known:
            return False
        info = modules.get(module)
        return (not info['dynamic'] and name not in info['exports']) if info else module in packages

    def import_base(node, info):
        if not node.level:
            return node.module or '', False
        parts = info['package'].split('.') if info['package'] else []
        if not parts and '' in packages and node.level == 1:
            return node.module or '', True
        if node.level > len(parts):
            return None, True
        return '.'.join(parts[:len(parts) - node.level + 1] + ([node.module] if node.module else [])), True

    # Resolve only unambiguous, unconditional module reexports; never infer the
    # type of an imported class/function or execute __init__.py to discover it.
    graph = {module: set() for module in modules}
    for module, info in modules.items():
        checkpoint()
        bindings = {}
        for node in info['tree'].body:
            if not isinstance(node, (ast.Import, ast.ImportFrom)):
                continue
            base = import_base(node, info)[0] if isinstance(node, ast.ImportFrom) else None
            for alias in node.names:
                key = alias.asname or (alias.name.split('.')[0] if isinstance(node, ast.Import) else alias.name)
                target = (alias.name if alias.asname else alias.name.split('.')[0]) if isinstance(node, ast.Import) else (
                    '.'.join(p for p in (base, alias.name) if p) if base is not None else None)
                bindings[key] = None if key in bindings else target
                dependency = alias.name if isinstance(node, ast.Import) else (
                    target if target in modules else base)
                if dependency in modules:
                    graph[module].add(dependency)
        # Rebinding in any module-level statement makes the alias uncertain.
        for node in info['tree'].body:
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                continue
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                bindings.pop(node.name, None)
                continue
            for child in ast.walk(node):
                if isinstance(child, ast.Name) and isinstance(child.ctx, (ast.Store, ast.Del)):
                    bindings.pop(child.id, None)
        if not info['dynamic']:
            info['reexports'] = {k: v for k, v in bindings.items() if v is not None}

    def resolve_module(name, seen=None):
        if name in known:
            return name
        seen = set() if seen is None else seen
        if name in seen or len(seen) > limits.files * 8:
            return None
        seen.add(name)
        parent, _, member = name.rpartition('.')
        target = modules.get(parent, {}).get('reexports', {}).get(member)
        return resolve_module(target, seen) if target else None

    report['import_graph'] = {m: sorted(edges) for m, edges in sorted(graph.items())}
    # Strongly connected groups, bounded by the same project file limit.
    reachable = {m: set(edges) for m, edges in graph.items()}
    for _ in modules:
        checkpoint()
        for m in reachable:
            reachable[m].update(target for edge in tuple(reachable[m]) for target in reachable.get(edge, ()))
    reported_cycles = set()
    for m in sorted(modules):
        if m in reachable[m]:
            group = tuple(sorted(n for n in reachable[m] if m in reachable[n]))
            if group not in reported_cycles:
                reported_cycles.add(group)
                diagnostic('import_cycle', modules[m]['path'], modules[m]['tree'],
                           'Ciclo de imports locais; inicialização depende da ordem: ' + ' -> '.join(group), 'warning')

    def reference_message(module, name):
        exports = sorted(n for n in modules.get(module, {}).get('exports', ()) if not n.startswith('_'))[:8]
        return ('Referência Python ausente: ' + module + '.' + name +
                ('; símbolos locais disponíveis: ' + ', '.join(exports) if exports else ''))

    def meaningful_test(function):
        # Do not count assertions in unrelated/nested helpers or literal assert True.
        pending = list(reversed(function.body))
        while pending:
            node = pending.pop()
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
                continue
            if isinstance(node, ast.Assert) and any(isinstance(n, (ast.Name, ast.Call, ast.Attribute, ast.Subscript)) for n in ast.walk(node.test)):
                return True
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                owner = node.func.value
                if (isinstance(owner, ast.Name) and owner.id == 'self' and
                        node.func.attr in {'assertEqual', 'assertNotEqual', 'assertTrue', 'assertFalse',
                                          'assertIs', 'assertIsNot', 'assertIsNone', 'assertIsNotNone',
                                          'assertIn', 'assertNotIn', 'assertIsInstance', 'assertNotIsInstance',
                                          'assertRaises', 'assertRaisesRegex', 'assertWarns', 'assertWarnsRegex',
                                          'assertAlmostEqual', 'assertNotAlmostEqual', 'assertGreater',
                                          'assertGreaterEqual', 'assertLess', 'assertLessEqual', 'assertRegex',
                                          'assertNotRegex', 'assertCountEqual', 'assertLogs', 'assertNoLogs',
                                          'assertSequenceEqual', 'assertListEqual', 'assertTupleEqual',
                                          'assertSetEqual', 'assertDictEqual', 'assertMultiLineEqual'}):
                    # Constant-only assertions are placeholders, except expectation contexts.
                    if node.func.attr.startswith(('assertRaises', 'assertWarns', 'assertLogs', 'assertNoLogs')) or any(
                            not isinstance(arg, ast.Constant) for arg in node.args):
                        return True
                if isinstance(owner, ast.Name) and owner.id in ('pytest', 'pt') and node.func.attr in ('raises', 'warns'):
                    return True
            # Ignore statically unreachable checks in if False / while False.
            if isinstance(node, (ast.Return, ast.Raise)) and node in function.body:
                break
            if isinstance(node, (ast.If, ast.While)) and isinstance(node.test, ast.Constant) and not node.test.value:
                pending.extend(reversed(node.orelse))
            else:
                pending.extend(reversed(list(ast.iter_child_nodes(node))))
        return False

    for module, info in modules.items():
        checkpoint()
        path, tree = info['path'], info['tree']
        optional = {id(n) for block in ast.walk(tree) if isinstance(block, (ast.Try, ast.If))
                    for n in ast.walk(block)}
        for node in ast.walk(tree):
            if not isinstance(node, (ast.Import, ast.ImportFrom)):
                continue
            severity = 'warning' if id(node) in optional else 'error'
            names = [a.name for a in node.names] if isinstance(node, ast.Import) else [import_base(node, info)[0]]
            relative = isinstance(node, ast.ImportFrom) and bool(node.level)
            for name in names:
                if name is None or missing_module(name, relative):
                    diagnostic('missing_module', path, node, 'Módulo local ausente: ' + (name or 'import relativo fora do pacote'), severity)
                elif name not in known:
                    diagnostic('external_import', path, node, 'Import externo ou raiz não indexada; disponibilidade não verificada: ' + name, 'warning')
                elif isinstance(node, ast.ImportFrom):
                    for alias in node.names:
                        if alias.name != '*' and missing_member(name, alias.name):
                            diagnostic('missing_reference', path, node, reference_message(name, alias.name), severity)

        # Check module attributes with aliases, while discarding ambiguous bindings.
        # Nested lexical scopes inherit imports but locally rebound names are removed.
        class References(ast.NodeVisitor):
            def __init__(self):
                self.bindings = {}
                self.uncertain = 0

            def scope(self, node, inherited):
                bindings = dict(inherited)
                candidates, changed = {}, set()
                args = getattr(node, 'args', None)
                if args:
                    changed.update(a.arg for a in ast.walk(args) if isinstance(a, ast.arg))
                pending = list(node.body)
                while pending:
                    child = pending.pop()
                    if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                        changed.add(child.name)
                        continue
                    if isinstance(child, (ast.Lambda, ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)):
                        continue
                    if isinstance(child, ast.Name) and isinstance(child.ctx, (ast.Store, ast.Del)):
                        changed.add(child.id)
                    if isinstance(child, ast.ExceptHandler) and child.name:
                        changed.add(child.name)
                    if isinstance(child, (ast.Global, ast.Nonlocal)):
                        changed.update(child.names)
                    if isinstance(child, (ast.Import, ast.ImportFrom)):
                        for alias in child.names:
                            key = alias.asname or (alias.name.split('.')[0] if isinstance(child, ast.Import) else alias.name)
                            if key in candidates:
                                changed.add(key)
                            target = None
                            if id(child) not in optional:
                                if isinstance(child, ast.Import):
                                    target = alias.name if alias.asname else alias.name.split('.')[0]
                                else:
                                    base, _ = import_base(child, info)
                                    target = '.'.join(p for p in (base, alias.name) if p) if base is not None else None
                            candidates[key] = target
                    pending.extend(ast.iter_child_nodes(child))
                for key in changed | set(candidates):
                    bindings.pop(key, None)
                bindings.update({k: resolve_module(v) for k, v in candidates.items()
                                 if k not in changed and v is not None and resolve_module(v) is not None})
                old = self.bindings
                self.bindings = bindings
                for child in node.body:
                    self.visit(child)
                self.bindings = old

            def visit_FunctionDef(self, node):
                self.scope(node, self.bindings)
            visit_AsyncFunctionDef = visit_FunctionDef

            def visit_ClassDef(self, node):
                # Class scopes are not enclosing lexical scopes of methods.
                for child in node.body:
                    if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        self.scope(child, self.bindings)

            def visit_Attribute(self, node):
                parts, base = [], node
                while isinstance(base, ast.Attribute):
                    parts.append(base.attr)
                    base = base.value
                target = self.bindings.get(base.id) if isinstance(base, ast.Name) else None
                if target and isinstance(node.ctx, ast.Load):
                    for part in reversed(parts):
                        if missing_member(target, part):
                            diagnostic('missing_reference', path, node, reference_message(target, part),
                                       'warning' if self.uncertain else 'error')
                            break
                        target = resolve_module('.'.join(p for p in (target, part) if p))
                        if target is None:
                            break  # class/instance attributes require type/dynamic analysis
                # The outer chain has already checked all its components.
                if not isinstance(base, ast.Name):
                    self.visit(base)

            def visit_Try(self, node):
                self.uncertain += 1
                self.generic_visit(node)
                self.uncertain -= 1
            visit_If = visit_Try

            def visit_Lambda(self, node):
                pass
            visit_ListComp = visit_Lambda
            visit_SetComp = visit_Lambda
            visit_DictComp = visit_Lambda
            visit_GeneratorExp = visit_Lambda

        References().scope(tree, {})
        basename = path.rsplit('/', 1)[-1].lower()
        if require_tests and (basename.startswith('test_') or basename.endswith('_test.py')):
            tests = [(n, n.name, 'pytest', True) for n in tree.body
                     if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name.startswith('test_')]
            unittest_modules = {a.asname or 'unittest' for n in tree.body if isinstance(n, ast.Import)
                                for a in n.names if a.name == 'unittest'}
            unittest_bases = {a.asname or a.name for n in tree.body if isinstance(n, ast.ImportFrom)
                              and n.module == 'unittest' for a in n.names
                              if a.name in ('TestCase', 'IsolatedAsyncioTestCase')}
            for cls in (n for n in tree.body if isinstance(n, ast.ClassDef)):
                unittest_class = any((isinstance(b, ast.Name) and b.id in unittest_bases) or
                    (isinstance(b, ast.Attribute) and isinstance(b.value, ast.Name) and b.value.id in unittest_modules
                     and b.attr in ('TestCase', 'IsolatedAsyncioTestCase')) for b in cls.bases)
                discoverable = unittest_class or (cls.name.startswith('Test') and not any(
                    isinstance(n, ast.FunctionDef) and n.name == '__init__' for n in cls.body))
                tests += [(n, cls.name + '.' + n.name, 'unittest' if unittest_class else 'pytest', discoverable)
                          for n in cls.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
                          and n.name.startswith('test' if unittest_class else 'test_')]
            if not tests:
                diagnostic('empty_tests', path, tree, 'Arquivo de testes sem funções de teste identificáveis')
            for test, name, framework, discoverable in tests:
                report['test_count'] += 1
                if len(report['tests']) < 200:
                    report['tests'].append({'path': path, 'name': name, 'line': test.lineno,
                                            'framework_hint': framework, 'discovery_candidate': discoverable})
                else:
                    report['tests_truncated'] = True
                if not discoverable:
                    diagnostic('test_discovery_uncertain', path, test,
                               'Método fora das convenções de descoberta de testes: ' + name, 'warning')
                if not meaningful_test(test):
                    # Helpers/fixtures/custom frameworks may perform checks indirectly.
                    # Ambiguous tests are warnings; plain pass/docstrings/constants are errors.
                    calls = [n for n in ast.walk(test) if isinstance(n, ast.Call)]
                    diagnostic('empty_tests', path, test, 'Teste sem verificações reais identificáveis: ' + test.name,
                               'warning' if calls else 'error')
    report['error_count'] = errors
    report['status'] = 'failed' if errors else ('passed_static' if files else 'no_python')
    return report


def require_static_success(report):
    if report['error_count']:
        raise StaticValidationError(report)


def validate_python_plan_sources(plan):
    report = analyze_python_project(plan, require_tests=False)
    errors = [d for d in report['diagnostics'] if d['code'] == 'syntax']
    if errors:
        raise CoreError('; '.join(d['path'] + ': ' + d['message'] for d in errors[:5]))


def validate_python_project_links(plan, require_tests=False):
    require_static_success(analyze_python_project(plan, require_tests=require_tests))
    return True


def format_static_report(report):
    statuses = {'passed_static': 'sem erros estáticos detectados', 'failed': 'reprovada',
                'no_python': 'nenhum arquivo Python analisado'}
    lines = ['Verificação estática Python V3: ' + statuses.get(report['status'], report['status']),
             'Escopo: ' + report.get('scope', 'arquivos fornecidos'),
             'Sintaxe por arquivo (hash identifica a versão analisada):']
    lines += [f"{f['path']}: {'válida' if f['syntax'] == 'ok' else 'inválida'} | {f['sha256'][:12]}" for f in report['files']]
    lines.append('Erros encontrados: ' + str(report['error_count']))
    lines.append('Testes identificados estaticamente: %d; descoberta real pendente.' % report.get('test_count', 0))
    lines.append('Referências/módulos ausentes listados: ' + str(sum(
        d['code'] in ('missing_module', 'missing_reference') for d in report['diagnostics'])))
    lines += [f"{'erro' if d['severity'] == 'error' else 'aviso'} | {d['path']}:{d['line'] or '-'} | {d['message']}" for d in report['diagnostics']]
    if report['truncated']:
        lines.append('Diagnósticos limitados a 100; há ocorrências adicionais.')
    lines += ['Ainda não testado:'] + report['not_tested']
    lines.append('Análise estática aprovada NÃO significa testes de execução aprovados.')
    output = '\n'.join(lines)
    if len(output) > 23000:
        return output[:21000] + '\nExibição resumida; relatório completo nos metadados privados.\n' + '\n'.join(report['not_tested']) + '\nAnálise estática NÃO aprova testes de execução.'
    return output


PYTHON_SOURCE = 'def add(a, b):\n    return a + b\n'
PYTHON_BUG = 'def add(a, b):\n    return a - b\n'
PYTHON_TEST = '''import pathlib
import runpy
import unittest

add = runpy.run_path(str(pathlib.Path(__file__).with_name("calculator.py")))["add"]

class CalculatorTest(unittest.TestCase):
    def test_positive(self):
        self.assertEqual(add(2, 3), 5)

    def test_negative(self):
        self.assertEqual(add(-2, -3), -5)

    def test_zero(self):
        self.assertEqual(add(0, 0), 0)

if __name__ == "__main__":
    unittest.main()
'''
PYTHON_FILES = {'calculator.py': PYTHON_SOURCE, 'test_calculator.py': PYTHON_TEST,
                'README.md': '# Calculadora\n\nPython padrão; execute: python3 -I -B test_calculator.py\n'}
FLUTTER_FILES = {
    'analysis_options.yaml': 'analyzer:\n  exclude:\n    - build/**\n',
    'pubspec.yaml': '''name: core_example
description: Exemplo básico gerado pelo CORE V2
publish_to: none
version: 1.0.0+1
environment:
  sdk: '>=3.3.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
flutter:
  uses-material-design: true
''',
    'lib/main.dart': '''import 'package:flutter/material.dart';
void main() => runApp(const ExampleApp());
class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: Text('Olá, CORE V2!'))),
  );
}
''',
    'test/widget_test.dart': '''import 'package:flutter_test/flutter_test.dart';
import 'package:core_example/main.dart';
void main() {
  testWidgets('mostra saudação', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    expect(find.text('Olá, CORE V2!'), findsOneWidget);
  });
}
''',
    'README.md': '# Exemplo Flutter\n\nRequer SDK Flutter. Para plataforma Android: flutter create --platforms=android .\nDepois: flutter pub get && flutter analyze && flutter test\nComandos manuais; nenhuma dependência é baixada automaticamente.\n',
}


class Planner:
    """Finite grammar plus explicit structured plans; never claims general reasoning."""
    def plan(self, request):
        text = normal(request)
        if text in ('criar projeto python', 'criar projeto python de exemplo', 'desenvolver um pequeno projeto python'):
            return self.example('python')
        if text in ('criar projeto flutter', 'criar projeto flutter de exemplo'):
            return self.example('flutter')
        if text.startswith('planejar '):
            return {'objective': request[9:].strip(), 'requirements': ['Refinar os requisitos com o usuário'],
                    'architecture': 'Ainda não definida: requer planejamento estruturado ou modelo externo',
                    'tasks': [{'id': 'refine', 'depends_on': [], 'description': 'Detalhar arquitetura, arquivos e testes'}],
                    'criteria': ['Requisitos e testes revisados'], 'files': [], 'draft': True}
        if text.startswith('plano json '):
            return self.validate(json.loads(request[11:]))
        return None

    def example(self, kind):
        files = PYTHON_FILES if kind == 'python' else FLUTTER_FILES
        return self.validate({'objective': 'Criar exemplo ' + kind, 'requirements': ['Estrutura, código, testes e instruções'],
                              'architecture': 'Calculadora e unittest' if kind == 'python' else 'MaterialApp e widget test',
                              'tasks': [{'id': 'files', 'depends_on': [], 'description': 'Criar arquivos com backup'},
                                        {'id': 'verify', 'depends_on': ['files'], 'description': 'Conferir conteúdo salvo'},
                                        {'id': 'tests', 'depends_on': ['verify'], 'description': 'Executar testes explicitamente autorizados'}],
                              'criteria': ['Arquivos conferidos', 'Testes aprovados'],
                              'files': [{'path': p, 'content': c} for p, c in files.items()], 'example': kind})

    def validate(self, plan):
        if not isinstance(plan, dict) or set(plan) - {'objective', 'requirements', 'architecture', 'tasks', 'criteria', 'files', 'example', 'draft'}:
            raise CoreError('Plano contém campos não permitidos; comandos e permissões são proibidos')
        for name in ('objective', 'architecture'):
            if not isinstance(plan.get(name), str) or not plan[name].strip() or not 1 <= len(plan[name]) <= 3000:
                raise CoreError('Campo de plano inválido: ' + name)
        for name in ('requirements', 'criteria'):
            if not isinstance(plan.get(name), list) or not 1 <= len(plan[name]) <= 30 or any(not isinstance(x, str) or not x.strip() or len(x) > 3000 for x in plan[name]):
                raise CoreError('Lista de plano inválida: ' + name)
        tasks = plan.get('tasks')
        if not isinstance(tasks, list) or not 1 <= len(tasks) <= 24:
            raise CoreError('Plano exige 1 a 24 tarefas')
        seen = set()
        for task in tasks:
            if not isinstance(task, dict) or set(task) != {'id', 'depends_on', 'description'}:
                raise CoreError('Tarefa inválida')
            if not isinstance(task['id'], str) or not re.fullmatch('[a-zA-Z0-9_-]{1,40}', task['id']) or task['id'] in seen:
                raise CoreError('Identificador inválido ou repetido')
            if not isinstance(task['depends_on'], list) or any(not isinstance(x, str) or x not in seen for x in task['depends_on']):
                raise CoreError('Dependência ausente, cíclica ou fora de ordem')
            if len(task['depends_on']) != len(set(task['depends_on'])):
                raise CoreError('Dependência repetida')
            if not isinstance(task['description'], str) or not task['description'].strip() or len(task['description']) > 3000:
                raise CoreError('Descrição inválida')
            seen.add(task['id'])
        files = plan.get('files')
        if 'draft' in plan and type(plan['draft']) is not bool:
            raise CoreError('Indicador de rascunho inválido')
        if not isinstance(files, list) or len(files) > 20 or (not files and plan.get('draft') is not True):
            raise CoreError('Arquivos do plano inválidos')
        paths = set()
        for item in files:
            if not isinstance(item, dict) or set(item) != {'path', 'content'} or not all(isinstance(v, str) for v in item.values()):
                raise CoreError('Proposta de arquivo inválida')
            validate_relative_path(item['path'])
            if Path(item['path']).suffix.lower() not in EXTENSIONS:
                raise CoreError('Extensão não permitida')
            if item['path'].lower() in paths:
                raise CoreError('Arquivo duplicado: ' + item['path'])
            paths.add(item['path'].lower())
            if len(item['content'].encode('utf-8')) > Limits().file_bytes:
                raise CoreError('Conteúdo excede limite: ' + item['path'])
            if display(item['content']) != item['content'].replace('\r', ''):
                raise CoreError('Conteúdo sensível ou controle binário bloqueado')
        # A model cannot label arbitrary code as a trusted built-in example.
        if plan.get('example') not in (None, 'python', 'flutter'):
            raise CoreError('Exemplo inválido')
        return plan


@dataclass(frozen=True)
class IsolatedTestRequest:
    """Immutable input contract, NOT an isolation implementation or certificate.

    A future host adapter must consume these bytes, never reopen project paths.
    There is deliberately no shell/argv, environment or mount supplied by a plan.
    """
    sources: tuple
    framework: str
    wall_seconds: int
    cpu_seconds: int = 5
    memory_bytes: int = 256 * 1024 * 1024
    output_bytes: int = 24000
    process_limit: int = 16
    temporary_bytes: int = 16 * 1024 * 1024

    def __post_init__(self):
        if self.framework not in ('unittest', 'pytest'):
            raise CoreError('Framework de testes não permitido')
        for field, ceiling in (('wall_seconds', 8), ('cpu_seconds', 5), ('memory_bytes', 256 * 1024 * 1024),
                               ('output_bytes', 24000), ('process_limit', 16), ('temporary_bytes', 16 * 1024 * 1024)):
            if type(getattr(self, field)) is not int or not 1 <= getattr(self, field) <= ceiling:
                raise CoreError('Limite inválido no contrato de execução: ' + field)
        if type(self.sources) is not tuple or not 1 <= len(self.sources) <= Limits().files:
            raise CoreError('Snapshot deve ser tupla imutável limitada')
        seen = set()
        for item in self.sources:
            if type(item) is not tuple or len(item) != 2:
                raise CoreError('Arquivo inválido no snapshot')
            path, source = item
            validate_relative_path(path)
            if not path.endswith('.py') or path.lower() in seen:
                raise CoreError('Caminho inválido ou repetido no snapshot')
            seen.add(path.lower())
            if not isinstance(source, str) or len(source.encode('utf-8')) > Limits().file_bytes or display(source) != source.replace('\r', ''):
                raise CoreError('Conteúdo inválido no snapshot')

    def manifest(self):
        files = [{'path': path, 'sha256': digest(source)} for path, source in self.sources]
        value = {'version': 1, 'framework': self.framework, 'files': files,
                 'limits': {'wall_seconds': self.wall_seconds, 'cpu_seconds': self.cpu_seconds,
                            'memory_bytes': self.memory_bytes, 'output_bytes': self.output_bytes,
                            'process_limit': self.process_limit, 'temporary_bytes': self.temporary_bytes},
                 'network': 'denied', 'project_writes': 'denied', 'environment': 'host_allowlist'}
        value['snapshot_hash'] = digest(json.dumps(value, sort_keys=True, ensure_ascii=False))
        return value


class IsolatedTestRunner:
    """Fail-closed integration seam. No executable backend is shipped/enabled.

    Metadata, model fields, a mock backend or per-operation approval cannot
    attest isolation. Enabling this requires a reviewed host implementation and
    real adversarial validation on the target runtime, as documented separately.
    """
    REQUIRED_CONTROLS = ('separate_identity', 'immutable_snapshot', 'filesystem_boundary',
                         'no_network', 'sanitized_environment', 'cpu_memory_process_limits',
                         'wall_output_limits', 'temporary_disk_limit', 'terminate_descendants', 'verified_result_binding')

    def preflight(self, request):
        return {**request.manifest(), 'status': 'blocked', 'tests_executed': False,
                'tests_passed': False, 'reason_code': 'isolation_unavailable',
                'missing_controls': list(self.REQUIRED_CONTROLS),
                'notice': 'Contrato preparado; isolamento não implementado nem validado. Nenhum teste executado.'}

    def execute(self, request, checkpoint=lambda: None):
        checkpoint()
        raise IsolationUnavailable('Execução bloqueada: isolamento real não validado. Nenhum teste foi executado.')


class Engine:
    def __init__(self, store, *, run_id=None, cancel=lambda: False, emit=lambda event: None,
                 transport=None, inference=None):
        self.store = store
        self.id = run_id or uuid.uuid4().hex
        if not re.fullmatch('[a-zA-Z0-9_-]{1,64}', self.id):
            raise CoreError('Identificador de execução inválido')
        self.cancelled, self.emit = cancel, emit
        self.transport = transport or PublicHTTP(store.limits)
        self.inference = inference
        self.started = time.monotonic()
        self.state = {'id': self.id, 'phase': 'planning', 'steps': 0, 'corrections': 0, 'events': [],
                      'started_at': time.time()}

    def checkpoint(self):
        if self.cancelled():
            raise Cancelled('Cancelado; nenhuma etapa seguinte será executada')
        budget = self.store.limits.seconds
        if time.monotonic() - self.started > budget:
            raise BudgetExceeded('Limite de tempo esgotado', 'time_limit')
        if self.state['steps'] > self.store.limits.steps:
            raise BudgetExceeded('Limite de etapas esgotado', 'step_limit')

    def event(self, phase, message):
        self.state['phase'] = phase
        self.state['updated_at'] = time.time()
        self.state['events'].append({'phase': phase, 'message': display(message)})
        self.state['events'] = self.state['events'][-60:]
        self.store.save('run_' + self.id + '.json', self.state)
        self.store.save('latest.json', {'id': self.id})
        self.emit({'phase': phase, 'message': display(message), 'id': self.id})

    def step(self, phase, message):
        self.state['steps'] += 1
        self.checkpoint()
        self.event(phase, message)

    def rate_limit(self):
        self.store.permit('web')
        self.checkpoint()
        previous = self.store.load('network.json', {'last': 0})
        if time.time() - previous['last'] < 3:
            raise CoreError('Aguarde 3 segundos entre consultas; sem repetição automática')
        self.store.save('network.json', {'last': time.time()})

    def execute(self, request, approved=False):
        self.state['operation'] = 'inspection' if normal(request) in ('estado', 'retomar', 'backups',
            'ver plano', 'diagnostico', 'diagnosticos', 'memoria', 'ver relatorio estatico',
            'ver relatorio de verificacao') else 'task'
        try:
            self.store.permit('read')
            if len(request.encode()) > 240000:
                raise CoreError('Prompt excede limite')
            # Only metadata/results are emitted; source code is not placed in logs.
            self.step('planning', 'CORE V2 • planejador determinístico; modelos externos opcionais')
            result, phase = self.dispatch(request.strip(), approved)
            self.checkpoint()
        except Cancelled as error:
            self.state['diagnostic'] = error_diagnostic(error, self.state['phase'])
            result, phase = str(error), 'cancelled'
        except ApprovalRequired as error:
            self.state['diagnostic'] = error_diagnostic(error, self.state['phase'])
            result, phase = str(error), 'approval'
        except Exception as error:
            self.state['diagnostic'] = error_diagnostic(error, self.state['phase'])
            result, phase = display(str(error)), 'failed'
        try:
            self.event(phase, result)
        except Exception as error:
            if phase != 'cancelled':
                phase = 'failed'
            self.state['phase'] = phase
            result += '\nNão foi possível persistir o estado: ' + display(str(error))
            self.state['persistence_diagnostic'] = error_diagnostic(error, phase)
        return {'phase': phase, 'output': display(result), 'runId': self.id,
                **{key: self.state[key] for key in ('diagnostic', 'persistence_diagnostic') if key in self.state}}

    def dispatch(self, request, approved):
        text = normal(request)
        if text in ('preparar testes isolados python', 'testar projeto python isolado'):
            self.store.permit('tests')
            self.state['tests_passed'] = False
            self.step('verifying', 'Preparando contrato de testes; execução isolada ainda indisponível')
            test_request = self.prepare_isolated_tests()
            preflight = IsolatedTestRunner().preflight(test_request)
            self.checkpoint()
            self.store.save('execution_preflight.json', preflight)
            if text == 'testar projeto python isolado':
                IsolatedTestRunner().execute(test_request, self.checkpoint)
            return json.dumps(preflight, ensure_ascii=False, indent=2), 'completed'
        if text in ('verificar projeto python', 'verificacao estatica', 'verificar estaticamente projeto python'):
            self.step('verifying', 'Analisando Python sem executar código ou testes')
            report = self.static_report()
            if report['error_count']:
                self.state['diagnostic'] = error_diagnostic(StaticValidationError(report), 'verifying')
            return format_static_report(report), 'failed' if report['error_count'] else 'completed'
        if text == 'verificar plano python':
            plan = self.store.load('plan.json')
            if plan is None:
                raise CoreError('Nenhum plano salvo')
            Planner().validate(plan)
            report = self.static_report(plan)
            if report['error_count']:
                self.state['diagnostic'] = error_diagnostic(StaticValidationError(report), 'verifying')
            return format_static_report(report), 'failed' if report['error_count'] else 'completed'
        if text in ('ver relatorio de verificacao', 'ver relatorio estatico'):
            report = self.store.load('static_verification.json')
            if report is None:
                return 'Nenhum relatório estático salvo. Use: verificar projeto python.', 'completed'
            return ('Relatório salvo; os arquivos podem ter mudado. Use verificar projeto python para atualizar.\n' +
                    format_static_report(report)), 'completed'
        if re.fullmatch(r'(listar|liste|mostrar|mostre) (os )?arquivos( do projeto)?', text):
            return '\n'.join(self.store.list()) or 'Nenhum arquivo permitido.', 'completed'
        if text.startswith('listar pasta '):
            return '\n'.join(self.store.list(request[13:].strip())), 'completed'
        if text.startswith('ler '):
            return self.store.read(request[4:].strip()), 'completed'
        if text.startswith('localizar '):
            needle = request[10:].strip()
            if not needle or len(needle) > 200:
                raise CoreError('Informe texto de até 200 caracteres')
            matches = []
            for path in self.store.list():
                self.checkpoint()
                try:
                    source = self.store.read(path)
                except (CoreError, UnicodeError):
                    continue
                for number, line in enumerate(source.splitlines(), 1):
                    if needle in line:
                        matches.append('%s:%d: %s' % (path, number, line[:200]))
                if len(matches) >= 100:
                    break
            return '\n'.join(matches[:100]) or 'Nenhuma ocorrência.', 'completed'
        if text in ('diagnostico', 'diagnosticos', 'memoria'):
            return ('CORE V3: análise estática e planos JSON com autocorreção limitada. '
                    'Planos, estados, backups e fontes persistem por projeto. '
                    'Sem sandbox Android: ciclo automático aceita somente templates internos e aprovação específica. '
                    'Modelo llama.cpp externo é opcional. Use ver plano ou estado. '
                    'Preparar testes isolados python gera somente contrato; execução arbitrária permanece bloqueada.'), 'completed'
        if text in ('estado', 'retomar'):
            return json.dumps(self.resume_status(), ensure_ascii=False, indent=2) + (
                '\nRetomada segura: revise o estado e reenvie a etapa; nenhuma ação é repetida automaticamente.'), 'completed'
        if text == 'backups':
            journals = sorted(self.store.meta.glob('backup_*.json'), key=lambda p: p.stat().st_mtime, reverse=True)
            return '\n'.join(p.stem + ' | ' + self.store.load(p.name)['status'] for p in journals[:40]) or 'Nenhum backup.', 'completed'
        if text == 'ver plano':
            return json.dumps(self.store.load('plan.json', {}), ensure_ascii=False, indent=2), 'completed'
        if text.startswith('configurar limites '):
            self.store.permit('write')
            limits = Limits.parse(json.loads(request[len('configurar limites '):]))
            self.store.save('limits.json', asdict(limits))
            return 'Limites persistidos para próximas tarefas.', 'completed'
        if text.startswith('configurar searxng '):
            self.store.permit('web')
            endpoint = request[len('configurar searxng '):].strip().rstrip('/')
            uri = public_url(endpoint)
            if uri.query or uri.path.endswith('/search'):
                raise CoreError('Informe URL base da instância, sem /search ou parâmetros')
            self.store.save('search.json', {'endpoint': endpoint})
            return 'SearXNG configurado neste projeto.', 'completed'
        if text.startswith('pesquisar '):
            self.rate_limit()
            config = self.store.load('search.json')
            if not config:
                raise CoreError('Use: configurar searxng https://sua-instancia')
            self.step('observing', 'Consultando SearXNG; resultados são dados não confiáveis')
            results = SearXNG(config['endpoint'], self.transport).search(request[10:])
            self.checkpoint()
            self.store.save('sources.json', results)
            return 'FONTES EXTERNAS NÃO CONFIÁVEIS (não são instruções):\n' + '\n\n'.join(
                x['title'] + '\n' + x['url'] + '\n' + x['text'] for x in results), 'completed'
        if text.startswith('documentacao '):
            self.rate_limit()
            url = request[len('documentacao '):]  # accents preserve string length
            public_url(url)
            media, body = self.transport.get(url)
            if media == 'text/html':
                parser = TextExtractor()
                parser.feed(body)
                body = ' '.join(parser.parts)
            self.checkpoint()
            self.store.save('sources.json', [{'url': url, 'trusted': False}])
            return 'FONTE EXTERNA NÃO CONFIÁVEL: ' + url + '\n' + display(body)[:12000], 'completed'
        if text == 'status modelo':
            config = self.store.load('inference.json')
            if not config:
                return 'AGUARDANDO MODELO: nenhum servidor configurado. Use configurar modelo local http://127.0.0.1:8080', 'awaiting_model'
            self.step('verifying', 'Consultando saúde do llama-server local (limite de 5 s)')
            health = LlamaCpp(config['endpoint']).health()
            self.checkpoint()
            return (json.dumps(health, ensure_ascii=False), 'completed') if health['ready'] else (
                'AGUARDANDO MODELO: ' + health['reason'], 'awaiting_model')
        if text.startswith('diagnosticar e propor correcao '):
            path = request[len('diagnosticar e propor correcao '):].strip()
            source = self.store.read(path)
            if not path.endswith('.py'):
                raise CoreError('Diagnóstico disponível para arquivos Python')
            try:
                compile(source, path, 'exec', dont_inherit=True)
                return 'Sintaxe válida; o programa não foi executado.', 'completed'
            except SyntaxError as error:
                diagnosis = 'Erro de sintaxe em %s:%s: %s' % (path, error.lineno, error.msg)
            config = self.store.load('inference.json')
            provider = self.inference or (LlamaCpp(config['endpoint']) if config else None)
            if provider is None:
                return diagnosis + '\nAGUARDANDO MODELO: arquivo preservado; nenhuma correção aplicada.', 'awaiting_model'
            self.step('planning', diagnosis + '; preparando proposta para revisão')
            plan = self.propose_model(provider, diagnosis + '\nProponha correção apenas para ' + path + '\n' + source)
            plan.pop('example', None)
            return self.save_plan(plan, execute=False)
        if text.startswith('configurar modelo local '):
            self.store.permit('write')
            endpoint = request[len('configurar modelo local '):].strip()
            LlamaCpp(endpoint)
            self.store.save('inference.json', {'endpoint': endpoint})
            return 'Interface llama.cpp configurada. Nenhum modelo baixado ou criado.', 'completed'
        if text.startswith('recursos modelo '):
            size = float(request[16:])
            resources = LlamaCpp.resources(size)
            resources['free_storage_gb_observed'] = round(shutil.disk_usage(self.store.meta).free / 1e9, 2)
            try:
                resources['available_ram_gb_observed'] = round(os.sysconf('SC_AVPHYS_PAGES') * os.sysconf('SC_PAGE_SIZE') / 1e9, 2)
            except (ValueError, OSError):
                resources['available_ram_gb_observed'] = None
            resources['architecture'] = os.uname().machine
            resources['download_supported'] = False
            return json.dumps(resources, ensure_ascii=False, indent=2), 'completed'
        if text.startswith('modelo planejar '):
            # User's explicit command sends only this request, never project files or web data.
            config = self.store.load('inference.json')
            provider = self.inference or (LlamaCpp(config['endpoint']) if config else None)
            if provider is None:
                return 'AGUARDANDO MODELO: modelo externo não configurado; nenhuma correção aplicada.', 'awaiting_model'
            self.step('planning', 'Consultando modelo externo local; saída exige revisão')
            plan = self.propose_model(provider, request[16:])
            plan.pop('example', None)
            return self.save_plan(plan, execute=False)
        if text.startswith('restaurar '):
            backup = request[10:].strip()
            if not re.fullmatch(r'backup_[a-f0-9]{32}', backup):
                raise CoreError('Backup inválido')
            if approved:
                self.state['backup'] = backup
                self.step('applying', 'Restaurando backup com verificação de conflitos e cancelamento: ' + backup)
            return self.store.restore(backup, approved, self.checkpoint), 'completed'
        if text in ('runtimes', 'status runtimes'):
            return self.runtime_status(), 'completed'
        if text.startswith('git '):
            return self.git(text[4:], approved), 'completed'
        if text == 'testar projeto python':
            return self.test_python(approved), 'completed'
        if text == 'aplicar plano':
            plan = self.store.load('plan.json')
            if not plan:
                raise CoreError('Nenhum plano salvo')
            plan = Planner().validate(plan)
            if not plan['files']:
                raise CoreError('Plano sem arquivos implementáveis; refine os requisitos')
            snapshot = self.store.load('plan_expected.json')
            if snapshot is None:
                raise CoreError('Versões originais ausentes; gere e revise o plano novamente')
            if isinstance(snapshot, dict) and snapshot.get('version') == 3:
                if snapshot.get('plan_hash') != digest(json.dumps(plan, sort_keys=True, ensure_ascii=False)):
                    raise CoreError('Plano e versões originais inconsistentes; gere e revise o plano novamente')
                snapshot = snapshot.get('files')
            if not isinstance(snapshot, dict) or set(snapshot) != {item['path'] for item in plan['files']}:
                raise CoreError('Versões originais inválidas; gere e revise o plano novamente')
            return self.save_plan(plan, execute=True, expected=snapshot)
        plan = Planner().plan(request)
        if plan is not None:
            # Example creation is deterministic. Arbitrary JSON/model plans are staged.
            create_example = text in (
                'criar projeto python', 'criar projeto python de exemplo', 'desenvolver um pequeno projeto python',
                'criar projeto flutter', 'criar projeto flutter de exemplo')
            return self.save_plan(plan, execute=create_example, create_only=create_example)
        # QELTRAVYX_FREE_PROMPT_V1
        # Comandos internos possuem prioridade. Pedidos nao reconhecidos
        # podem gerar propostas pela IA local, mas nunca aplicar arquivos.
        config = self.store.load('inference.json')

        if self.inference is not None or config:
            provider = (
                self.inference
                if self.inference is not None
                else LlamaCpp(config['endpoint'])
            )

            self.step(
                'planning',
                'Interpretando pedido livre com IA local'
            )

            plan = self.propose_model(provider, request.strip())

            plan.pop('example', None)

            return self.save_plan(
                plan,
                execute=False
            )

        return ('Pedido não suportado pelo planejador determinístico. Use: criar projeto python; criar projeto flutter; '
                'planejar <objetivo>; plano json {...}; ver plano; aplicar plano; testar projeto python; '
                'verificar projeto python; verificar plano python; ver relatorio estatico; '
                'listar pasta src; localizar texto; pesquisar assunto; documentação https://...; '
                'git status; git init; restaurar backup_ID; estado; recursos modelo 3. '
                'Tarefas abertas exigem plano estruturado ou modelo externo local.'), 'unsupported'

    def resume_status(self):
        """Read-only recovery advice; never replay a model request or a write."""
        self.store.permit('read')
        records = []
        for path in self.store.meta.glob('run_*.json'):
            self.checkpoint()
            if path.name == 'run_' + self.id + '.json':
                continue
            if len(records) >= self.store.limits.entries:
                raise CoreError('Limite de estados excedido; consulta de retomada incompleta')
            records.append(path)
        previous = None
        for path in sorted(records, key=lambda p: (p.stat().st_mtime_ns, p.name), reverse=True):
            self.checkpoint()
            candidate = self.store.load(path.name)
            if not isinstance(candidate, dict) or not isinstance(candidate.get('phase'), str):
                raise CoreError('Estado de execução inválido: ' + path.name)
            if candidate.get('operation') != 'inspection':
                previous = candidate
                break
        result = {'previous_run': previous, 'automatic_replay': False,
                  'interrupted': bool(previous and previous['phase'] in (
                      'planning', 'applying', 'correcting', 'verifying', 'observing')),
                  'plan_status': 'absent', 'next_commands': ['backups']}
        if previous is None:
            result['notice'] = 'Nenhuma execução anterior.'
        plan = self.store.load('plan.json')
        if plan is not None:
            try:
                Planner().validate(plan)
                snapshot = self.store.load('plan_expected.json')
                if isinstance(snapshot, dict) and snapshot.get('version') == 3:
                    if snapshot.get('plan_hash') != digest(json.dumps(plan, sort_keys=True, ensure_ascii=False)):
                        raise CoreError('Plano e versões originais inconsistentes')
                    snapshot = snapshot.get('files')
                if not isinstance(snapshot, dict) or set(snapshot) != {f['path'] for f in plan['files']}:
                    raise CoreError('Versões originais ausentes ou inválidas')
                changed = []
                for item in plan['files']:
                    self.checkpoint()
                    path = self.store.path(item['path'])
                    actual = self.store.read(item['path']) if path.exists() else None
                    if snapshot[item['path']] != actual:
                        changed.append(item['path'])
                result['plan_status'] = 'stale' if changed else 'review_required'
                result['changed_files'] = changed
                result['next_commands'] += ['ver plano', 'verificar plano python']
                if changed:
                    result['notice'] = 'Arquivos mudaram desde o planejamento, possivelmente por aplicação anterior. Gere novo plano antes de aplicar.'
            except (CoreError, OSError) as error:
                if isinstance(error, (Cancelled, BudgetExceeded, PermissionRevoked)):
                    raise
                result['plan_status'] = 'invalid'
                result['plan_error'] = display(str(error))[:1800]
        result['notice'] = result.get('notice', '') + (
            ' A consulta não autoriza execução nem comprova testes. Revalide permissões, limites e arquivos ao reenviar uma etapa.')
        return result

    def prepare_isolated_tests(self, framework=None):
        self.store.permit('tests')
        if framework not in (None, 'unittest', 'pytest'):
            raise CoreError('Framework de testes não permitido')
        sources = self.python_sources()
        if not sources:
            raise CoreError('Nenhum arquivo Python para preparar testes')
        report = analyze_python_project({'files': [{'path': p, 'content': s} for p, s in sources.items()]},
                                        checkpoint=self.checkpoint, limits=self.store.limits)
        require_static_success(report)
        if not report['test_count']:
            raise CoreError('Nenhum teste identificável; contrato de execução não preparado')
        if report['tests_truncated']:
            raise CoreError('Inventário de testes incompleto; reduza o escopo antes de preparar execução')
        candidates = [test for test in report['tests'] if test['discovery_candidate']]
        unittest_only = candidates and all(test['framework_hint'] == 'unittest' and
            Path(test['path']).name.startswith('test') for test in candidates)
        framework = framework or ('unittest' if unittest_only else 'pytest')
        if not candidates or (framework == 'unittest' and not any(
                test['framework_hint'] == 'unittest' and Path(test['path']).name.startswith('test') for test in candidates)):
            raise CoreError('Nenhum candidato à descoberta pelo framework solicitado: ' + framework)
        self.checkpoint()
        self.store.permit('tests')
        return IsolatedTestRequest(tuple(sorted(sources.items())), framework,
                                   min(8, self.store.limits.seconds), min(5, self.store.limits.seconds))

    def prepare_changes(self, plan, create_only=False, expected=None):
        self.store.permit('write')
        Planner().validate(plan)
        changes = []
        if len(plan['files']) > self.store.limits.files:
            raise CoreError('Limite de arquivos excedido')
        if len(plan['tasks']) > self.store.limits.steps:
            raise CoreError('Limite de tarefas excedido')
        for item in plan['files']:
            self.checkpoint()
            path = self.store.path(item['path'])
            self.store.content(item['content'])
            before = self.store.read(item['path']) if path.exists() else None
            if create_only and path.exists():
                raise CoreError('Exemplo exige caminhos livres; não sobrescreve projetos existentes')
            if expected is not None and (item['path'] not in expected or expected[item['path']] != before):
                raise CoreError('Arquivo alterado desde o planejamento: ' + item['path'])
            changes.append({'path': item['path'], 'expected': before, 'content': item['content']})
        return changes

    def python_sources(self, plan=None):
        self.store.permit('read')
        self.checkpoint()
        proposed = {item['path']: item['content'] for item in plan['files']} if plan else {}
        sources = {}
        paths = set(self.store.list()) | set(proposed)
        python_paths = sorted(p for p in paths if p.lower().endswith('.py'))
        if len(python_paths) > self.store.limits.files:
            raise CoreError('Limite de arquivos da análise excedido; nenhuma aprovação parcial')
        for path in python_paths:
            self.checkpoint()
            sources[path] = proposed[path] if path in proposed else self.store.read(path)
        return sources

    def static_report(self, plan=None):
        sources = self.python_sources(plan)
        report = analyze_python_project({'files': [{'path': p, 'content': s} for p, s in sources.items()]},
                                        checkpoint=self.checkpoint, limits=self.store.limits)
        report['scope'] = 'proposta sobre o projeto' if plan else 'arquivos atuais do projeto'
        report['created_at'] = time.time()
        report['not_tested'].append('Somente caminhos permitidos foram indexados; configurações personalizadas de sys.path não foram resolvidas.')
        self.checkpoint()
        if len(json.dumps(report, ensure_ascii=False).encode('utf-8')) > 128000:
            raise CoreError('Relatório estático excede limite de 128 KB')
        self.store.save('static_verification.json', report)
        return report

    def validate_proposal(self, plan):
        self.prepare_changes(plan)
        report = self.static_report(plan)
        require_static_success(report)

    def propose_model(self, provider, request):
        def check():
            self.checkpoint()
            self.store.permit('write')
        def retry():
            self.state['corrections'] += 1
            self.step('planning', 'Plano inválido; solicitando correção estruturada à IA local')
        def rejection(attempt, reason):
            self.state.setdefault('model_rejections', []).append({'attempt': attempt, 'reason': reason})
            self.event('planning', 'Proposta %d rejeitada: %s' % (attempt, reason))
        return propose_valid_model_plan(provider, request, on_retry=retry,
                                        max_corrections=self.store.limits.corrections,
                                        checkpoint=check, validate=self.validate_proposal,
                                        on_rejection=rejection)

    def save_plan(self, plan, execute=False, create_only=False, expected=None):
        changes = self.prepare_changes(plan, create_only, expected)
        report = self.static_report(plan)
        require_static_success(report)
        self.checkpoint()
        # The hash binds both atomic files. Interrupted writes fail closed rather
        # than applying a plan with unrelated or missing original versions.
        self.store.save('plan_expected.json', {'version': 3,
                        'plan_hash': digest(json.dumps(plan, sort_keys=True, ensure_ascii=False)),
                        'files': {x['path']: x['expected'] for x in changes}})
        self.store.save('plan.json', plan)
        self.state['objective'] = display(plan['objective'])
        self.step('planning', 'Plano salvo: ' + plan['objective'] + '\n' + '\n'.join(
            task['id'] + ': ' + task['description'] for task in plan['tasks']))
        if not execute:
            return 'Plano local salvo. Revise com “ver plano”; aplique arquivos com “aplicar plano”. Tarefas descritivas não executam comandos.', 'planned'
        self.step('applying', 'Aplicando lote com backup e validação de conflitos')
        backup = self.store.apply(changes, self.checkpoint)
        self.state['backup'] = backup
        self.step('verifying', 'Arquivos conferidos: ' + ', '.join(x['path'] for x in changes))
        self.state['files_verified'] = True
        self.state['tests_passed'] = False
        return ('Arquivos criados/editados e conferidos. Backup: ' + backup +
                '\nProjeto ainda não validado por testes. ' +
                ('Envie: testar projeto python.' if plan.get('example') == 'python' else
                 'Execute os comandos do README em ambiente autorizado; tarefas restantes permanecem pendentes.')), 'awaiting_tests'

    def process(self, argv, seconds=8, permission='read'):
        def check():
            self.checkpoint()
            self.store.permit(permission)
        check()
        env = {key: value for key, value in os.environ.items() if key in (
            'PATH', 'LANG', 'LD_LIBRARY_PATH', 'QELTRAVYX_PYHOME', 'ANDROID_ROOT', 'ANDROID_DATA', 'TMPDIR')}
        env.update({'PYTHONDONTWRITEBYTECODE': '1', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                    'GIT_TERMINAL_PROMPT': '0', 'GIT_OPTIONAL_LOCKS': '0'})
        # Temporary output is in private metadata, capped while the child runs.
        with tempfile.TemporaryFile(dir=self.store.meta) as output:
            process = subprocess.Popen(argv, cwd=self.store.root, env=env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=output, start_new_session=True)
            start = time.monotonic()
            try:
                while process.poll() is None:
                    check()
                    if time.monotonic() - start > seconds or os.fstat(output.fileno()).st_size > 24000:
                        raise CoreError('Processo excedeu tempo ou saída')
                    time.sleep(0.03)
                check()
                output.seek(0)
                data = output.read(24001)
                if len(data) > 24000:
                    raise CoreError('Saída excede limite')
                return process.returncode, display(data.decode('utf-8', errors='replace'))
            finally:
                # Kill process group, including descendants, even after main exits.
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()

    def test_python(self, approved):
        self.store.permit('tests')
        if not approved:
            raise ApprovalRequired('Executar testes do exemplo Python e, se necessário, corrigir somente a troca conhecida de + por - e retestar? Sem sandbox Android. Apenas arquivos idênticos aos templates internos são aceitos.')
        # Arbitrary/user/model code cannot enter this automatic correction loop.
        # Execute immutable snapshots in a private folder, not mutable project files.
        source = self.store.read('calculator.py')
        test = self.store.read('test_calculator.py')
        if source not in (PYTHON_SOURCE, PYTHON_BUG) or test != PYTHON_TEST:
            raise CoreError('Código não confiável: execução automática bloqueada; requer isolamento apropriado')
        while True:
            self.store.permit('tests')
            self.step('verifying', 'Executando unittest do template interno autorizado')
            with tempfile.TemporaryDirectory(prefix='verify-', dir=self.store.meta) as folder:
                root = Path(folder)
                (root / 'calculator.py').write_text(source)
                (root / 'test_calculator.py').write_text(test)
                code, output = self.process([sys.executable, '-I', '-B', str(root / 'test_calculator.py')], permission='tests')
            self.step('observing', 'Código de saída: %d\n%s' % (code, output))
            self.store.permit('tests')
            if code == 0:
                if self.store.read('calculator.py') != source or self.store.read('test_calculator.py') != test:
                    raise CoreError('Projeto alterado durante testes; resultado não valida versão atual')
                self.store.save('verification.json', {'files': {'calculator.py': digest(source), 'test_calculator.py': digest(test)},
                                                      'exitCode': code, 'output': output})
                self.state['tests_passed'] = True
                return 'Testes reais aprovados (3 casos). Correções: %d\n%s' % (self.state['corrections'], output)
            if source != PYTHON_BUG or self.state['corrections'] >= self.store.limits.corrections:
                raise CoreError('Falha sem correção determinística disponível; limite ou revisão humana')
            self.state['corrections'] += 1
            self.step('correcting', 'Corrigindo somente operador conhecido no template; backup obrigatório')
            self.state['backup'] = self.store.apply([{'path': 'calculator.py', 'expected': source, 'content': PYTHON_SOURCE}], self.checkpoint)
            source = PYTHON_SOURCE

    def runtime_status(self):
        if not os.environ.get('QELTRAVYX_PYHOME'):
            return 'Fora do ambiente QELTRAVYX: ferramentas do host não comprovam runtimes do APK.'
        self.step('verifying', 'Consultando runtimes do APK, sem downloads')
        native = Path(sys.executable).parent
        lines = []
        for name, args in (
                ('python', [sys.executable, '--version']),
                ('pip', [sys.executable, '-m', 'pip', '--version']),
                ('node', [str(native / 'libqeltravyx_node.so'), '--version']),
                ('git', [str(native / 'libqeltravyx_git.so'), '--version'])):
            if not Path(args[0]).is_file():
                lines.append(name + ': não instalado no APK')
                continue
            code, output = self.process(args, seconds=5)
            state = 'versão executada' if code == 0 else 'não disponível'
            if name == 'pip' and code == 0:
                state = 'limitado: wheels Python puros offline'
            lines.append('%s: %s (exitCode %s)\n%s' % (name, state, code, output))
        lines.append('npm: não integrado. Versão não comprova operações; use os testes em Pacotes.')
        return '\n'.join(lines)

    def git(self, action, approved):
        # No shell, remote operations, hooks, pager, external diff or repository configs.
        # Only init and status are supported in this first adapter.
        if action not in ('init', 'status'):
            raise CoreError('Git permite apenas init e status; outras operações exigem adaptador e aprovação específica')
        binary = 'git'
        if os.environ.get('QELTRAVYX_PYHOME'):
            binary = str(Path(sys.executable).parent / 'libqeltravyx_git.so')
            if not Path(binary).is_file():
                raise CoreError('Git não instalado no APK; comandos Git indisponíveis. Nenhum fallback para Termux.')
        if not approved:
            raise ApprovalRequired('Executar git ' + action + ' local? Código de ferramenta externo exige aprovação por operação.')
        if action == 'init':
            self.store.permit('write')
        git_dir = self.store.root / '.git'
        if git_dir.exists():
            if git_dir.is_symlink() or not git_dir.is_dir():
                raise CoreError('Git externo/worktree não suportado')
            # Untrusted .git/config, hooks, objects alternates and symlinks can redirect Git.
            for parent, dirs, files in os.walk(git_dir):
                for name in dirs + files:
                    if (Path(parent) / name).is_symlink():
                        raise CoreError('Link em .git bloqueado')
            config = git_dir / 'config'
            if config.exists():
                if config.stat().st_size > 12000:
                    raise CoreError('Configuração Git excessiva')
                section = ''
                for line in config.read_text().splitlines():
                    line = line.strip()
                    if not line or line.startswith(('#', ';')):
                        continue
                    if line.lower() == '[core]':
                        section = 'core'
                        continue
                    if section != 'core' or not re.fullmatch(
                            r'(repositoryformatversion\s*=\s*0|(?:filemode|bare|logallrefupdates|ignorecase|precomposeunicode)\s*=\s*(?:true|false))',
                            line, re.I):
                        raise CoreError('Configuração Git externa/ativa não suportada')
            if (git_dir / 'commondir').exists() or (git_dir / 'objects/info/alternates').exists():
                raise CoreError('Armazenamento Git externo bloqueado')
        elif action == 'status':
            raise CoreError('Repositório Git ausente no projeto')
        args = [binary, '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false',
                '-c', 'core.bare=false', '-c', 'core.pager=cat', '--no-pager']
        args += ['init', '--template='] if action == 'init' else ['status', '--porcelain=v1', '--untracked-files=normal']
        code, output = self.process(args, permission='write' if action == 'init' else 'read')
        if code != 0:
            raise CoreError('Git falhou: ' + output)
        return output or 'Git: nenhuma alteração.'


def main():
    # Host-only protocol; caller does not supply executable command strings.
    payload = json.loads(sys.stdin.buffer.read(260001))
    root, metadata = payload['root'], payload['metadata']
    grants = payload['grants']
    control = Path(metadata) / 'control.json'
    def permissions():
        if control.exists():
            value = json.loads(control.read_text())
            return value.get('grants', grants)
        return grants
    def cancelled():
        return control.exists() and json.loads(control.read_text()).get('cancelled', False)
    store = Store(root, metadata, permissions)
    store.limits = Limits.parse(store.load('limits.json', {}))
    def emit(event):
        print(json.dumps({'event': event}, ensure_ascii=False), flush=True)
    engine = Engine(store, run_id=payload['runId'], cancel=cancelled, emit=emit)
    # Per-project advisory lock serializes host invocations; no stale lock after death.
    import fcntl
    with (store.meta / 'engine.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise CoreError('Tarefa já em execução neste projeto')
        result = engine.execute(payload['request'], payload.get('approved') is True)
    print(json.dumps({'result': result}, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'result': {'phase': 'failed', 'output': display(str(error))}}, ensure_ascii=False), flush=True)
        sys.exit(1)
