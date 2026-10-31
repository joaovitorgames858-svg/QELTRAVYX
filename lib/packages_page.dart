import 'dart:convert';

import 'runtime_status_panel.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Visual companion to the QPKG CLI; commands execute in the visible PTY.
/// It NEVER installs or removes packages directly: the confirmed command is
/// returned to the active PTY so users can watch qpkg validation and errors.
class QeltravyxPackagesPage extends StatefulWidget {
  const QeltravyxPackagesPage({super.key});

  @override
  State<QeltravyxPackagesPage> createState() => _QeltravyxPackagesPageState();
}

class _QeltravyxPackagesPageState extends State<QeltravyxPackagesPage> {
  static const _bridge = MethodChannel('qeltravyx/packages');
  static const _green = Color(0xFF43E7AB);
  static final _namePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$');
  final _name = TextEditingController();
  Map<String, String> _installed = {};
  bool _loading = false;
  bool _searching = false;
  String? _searchedName;
  String? _searchedVersion;
  String? _searchedDescription;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _bridge.invokeMapMethod<String, String>('installed');
      if (!mounted) return;
      setState(() => _installed = Map<String, String>.from(items ?? {}));
    } catch (e) {
      if (mounted)
        setState(() => _error = 'Não foi possível consultar os pacotes: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _search() async {
    final name = _name.text.trim();
    if (!_namePattern.hasMatch(name)) {
      setState(
        () => _error = 'Nome inválido. Use letras, números, ponto, _ ou -.',
      );
      return;
    }
    if (_searching) return;
    setState(() {
      _searching = true;
      _error = null;
      _searchedName = null;
      _searchedVersion = null;
      _searchedDescription = null;
    });
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(
        Uri.https('pypi.org', '/pypi/$name/json'),
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw const FormatException('Pacote não encontrado no PyPI.');
      }
      final buffer = BytesBuilder(copy: false);
      await for (final piece in response.timeout(const Duration(seconds: 20))) {
        buffer.add(piece);
        if (buffer.length > 2 * 1024 * 1024) {
          throw const FormatException(
            'Resposta do PyPI excedeu o limite permitido.',
          );
        }
      }
      final data = jsonDecode(utf8.decode(buffer.takeBytes()));
      if (data is! Map || data['info'] is! Map) {
        throw const FormatException('Resposta inesperada do PyPI.');
      }
      final info = data['info'] as Map;
      if (!mounted) return;
      setState(() {
        _searchedName = (info['name'] ?? name).toString();
        _searchedVersion = (info['version'] ?? '?').toString();
        _searchedDescription = (info['summary'] ?? '').toString();
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Falha na consulta: $e');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _searching = false);
    }
  }

  void _install(String name) {
    if (!_namePattern.hasMatch(name)) return;
    Navigator.of(context).pop('qpkg install --allow-network $name');
  }

  Future<void> _remove(String name) async {
    if (!_namePattern.hasMatch(name)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover pacote?'),
        content: Text(
          'O QPKG tentará remover "$name". Pacotes exigidos por outras bibliotecas ou com arquivos alterados serão protegidos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.of(context).pop('qpkg remove $name');
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _installed.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final queriedName = _searchedName;
    final safeQuery = queriedName != null && _namePattern.hasMatch(queriedName);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF10192A),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Runtimes e pacotes',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              'QELTRAVYX • QPKG 0.10',
              style: TextStyle(fontSize: 11, color: Color(0xFF97A7BA)),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Atualizar lista',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const RuntimeStatusPanel(),
            const Text(
              'Consultar PyPI por HTTPS (usa internet)',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    maxLength: 100,
                    decoration: const InputDecoration(
                      hintText: 'Ex.: colorama',
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: _searching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Consultar'),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            if (queriedName != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        queriedName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      Text(
                        'Versão no PyPI: ${_searchedVersion ?? "?"}',
                        style: const TextStyle(color: _green),
                      ),
                      if ((_searchedDescription ?? '').isNotEmpty)
                        Text(
                          _searchedDescription!,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: 8),
                      const Text(
                        'A consulta não garante compatibilidade. O QPKG verifica se existe wheel Python puro e valida as dependências antes de instalar.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF97A7BA),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: safeQuery
                            ? () => _install(queriedName)
                            : null,
                        icon: const Icon(Icons.download),
                        label: const Text('Autorizar download e instalar'),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Pacotes instalados',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  '${entries.length}',
                  style: const TextStyle(color: _green),
                ),
              ],
            ),
            if (_loading) const LinearProgressIndicator(),
            if (!_loading && entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'Nenhum pacote instalado pelo QPKG.',
                  style: TextStyle(color: Color(0xFF97A7BA)),
                ),
              ),
            for (final entry in entries)
              Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.inventory_2_outlined,
                    color: _green,
                  ),
                  title: Text(entry.key),
                  subtitle: Text('Versão ${entry.value}'),
                  trailing: IconButton(
                    tooltip: 'Remover ${entry.key}',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(entry.key),
                  ),
                  onTap: () => Navigator.pop(context, 'qpkg info ${entry.key}'),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              'Instalações e remoções são executadas na sessão do terminal, com a validação de segurança do QPKG. Volte a esta tela e toque em atualizar para consultar o resultado.',
              style: TextStyle(fontSize: 12, color: Color(0xFF97A7BA)),
            ),
          ],
        ),
      ),
    );
  }
}
