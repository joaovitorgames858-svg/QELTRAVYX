import 'package:flutter/material.dart';

/// Acoes rapidas da Alpha 1.0.5. Os callbacks reutilizam os fluxos e
/// verificacoes existentes da pagina do agente; nao executa nada sozinho.
class AgentProHub extends StatelessWidget {
  final String? project;
  final bool busy;
  final bool canPrepareRepair;
  final VoidCallback onGenerate;
  final VoidCallback onPrepareRepair;
  final VoidCallback onRunTest;

  const AgentProHub({
    super.key,
    required this.project,
    required this.busy,
    required this.canPrepareRepair,
    required this.onGenerate,
    required this.onPrepareRepair,
    required this.onRunTest,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = project != null && !busy;
    return Card(
      color: const Color(0xFF142B34),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Row(
              children: <Widget>[
                Icon(Icons.auto_awesome, color: Color(0xFF8EE4BF)),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'AGENT IA PRO - Acoes rapidas',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              project == null
                  ? 'Selecione um projeto antes de usar as acoes.'
                  : 'Projeto ativo: $project',
              style: const TextStyle(color: Color(0xFFB7C8D9)),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: enabled ? onGenerate : null,
                  icon: const Icon(Icons.edit_note_outlined),
                  label: const Text('Gerar / editar codigo'),
                ),
                OutlinedButton.icon(
                  onPressed: enabled && canPrepareRepair
                      ? onPrepareRepair
                      : null,
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('Preparar correcao'),
                ),
                OutlinedButton.icon(
                  onPressed: enabled ? onRunTest : null,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Testar Python'),
                ),
              ],
            ),
            const SizedBox(height: 9),
            const Text(
              'Geracao usa o prompt e a chave API informados abaixo. '
              'Correcao fica disponivel apos um teste com erro. '
              'O teste Python continua exigindo confirmacao e a aplicacao '
              'de arquivos continua com previa e backup.',
              style: TextStyle(fontSize: 12, color: Color(0xFFB7C8D9)),
            ),
          ],
        ),
      ),
    );
  }
}
