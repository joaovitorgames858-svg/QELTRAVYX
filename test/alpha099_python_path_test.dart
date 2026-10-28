import 'package:flutter_test/flutter_test.dart';

import '../lib/agent_python_path.dart';

void main() {
  test('permite executar script Python dentro do projeto', () {
    expect(
      AgentPythonPath.validate(' laboratorio095/gerado098.py '),
      'laboratorio095/gerado098.py',
    );
    expect(AgentPythonPath.validate('main.py'), 'main.py');
  });
  test('bloqueia extensoes que nao sao Python', () {
    for (final path in ['run.sh', 'config.json', 'arquivo.txt']) {
      expect(() => AgentPythonPath.validate(path), throwsFormatException);
    }
  });
  test('bloqueia caminhos externos e links nao convencionais', () {
    for (final path in [
      '../secrets.py',
      '/tmp/run.py',
      'pasta/../../run.py',
      'pasta\\script.py',
      '.oculto.py',
      'pasta//script.py',
    ]) {
      expect(() => AgentPythonPath.validate(path), throwsFormatException);
    }
  });
}
