import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class RuntimeStatusPanel extends StatefulWidget {
  const RuntimeStatusPanel({super.key});
  static const channel = MethodChannel('qeltravyx/runtimes');
  @override
  State<RuntimeStatusPanel> createState() => _RuntimeStatusPanelState();
}

class _RuntimeStatusPanelState extends State<RuntimeStatusPanel> {
  List<Map<String, dynamic>> _items = [];
  bool _busy = false;
  String? _result;
  @override
  void initState() {
    super.initState();
    _inspect();
  }

  Future<void> _inspect() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final rows = await RuntimeStatusPanel.channel.invokeListMethod<dynamic>(
        'inspect',
      );
      if (mounted) {
        setState(
          () => _items = [
            for (final row in rows ?? []) Map<String, dynamic>.from(row as Map),
          ],
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _items = [];
          _result = 'Inspeção indisponível: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testRuntime(String name) async {
    setState(() => _busy = true);
    try {
      final result = await RuntimeStatusPanel.channel
          .invokeMapMethod<String, dynamic>(
            name == 'python' ? 'testPython' : 'testRuntime',
            name == 'python' ? null : {'name': name},
          );
      if (mounted) {
        setState(
          () => _result = result == null
              ? 'Sem evidência retornada.'
              : 'Diagnóstico $name pelo APK\nSaída: ${result['exitCode']} • ${result['durationMs']} ms • timeout: ${result['timedOut']}\n${result['output']}',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _result = 'Teste não concluído: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              'Runtimes do APK',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            onPressed: _busy ? null : _inspect,
            tooltip: 'Inspecionar runtimes',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      const Text(
        'Instalado significa que --version executou no ambiente do app. Limitado indica restrições de uso. Consulte o diagnóstico para testar operações reais.',
      ),
      if (_busy) const LinearProgressIndicator(),
      for (final item in _items)
        ListTile(
          dense: true,
          title: Text('${item['name']} • ${item['status']}'),
          subtitle: Text('${item['reason']}'),
        ),
      OutlinedButton(
        onPressed: _busy ? null : () => _testRuntime('python'),
        child: const Text('Testar Python neste APK'),
      ),
      Wrap(
        spacing: 8,
        children: [
          for (final name in ['pip', 'node', 'npm', 'git'])
            OutlinedButton(
              onPressed: _busy ? null : () => _testRuntime(name),
              child: Text('Testar $name neste APK'),
            ),
        ],
      ),
      const Text(
        'pip: instalação offline e import em outro processo (pode levar até 90 s); npm: instalação/import offline (até 60 s), scripts bloqueados; Node: script e arquivos; Git: repositório e commit locais. Nenhum pacote é baixado.',
      ),
      if (_result != null)
        SelectableText(
          _result!,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      const Divider(height: 32),
    ],
  );
}
