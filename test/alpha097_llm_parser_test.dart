import 'package:flutter_test/flutter_test.dart';

import '../lib/agent_llm_client.dart';

void main() {
  test('extrai blocos de texto da Responses API', () {
    final result = QeltravyxAgentLlmClient.extractResponse({
      'output': [
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': 'Analise do arquivo.'},
            {'type': 'output_text', 'text': 'Sugestao de teste.'},
          ],
        },
      ],
    });
    expect(result, 'Analise do arquivo.\n\nSugestao de teste.');
  });

  test('rejeita retorno sem conteudo textual', () {
    expect(
      () => QeltravyxAgentLlmClient.extractResponse({'output': []}),
      throwsFormatException,
    );
  });
}
