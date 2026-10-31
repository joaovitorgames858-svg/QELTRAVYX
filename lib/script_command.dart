/// Shell quoting is applied to every argument individually, including paths.
String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String scriptCommand(String path, List<String> arguments) {
  if (!path.startsWith('/') ||
      path.contains('\u0000') ||
      arguments.any((a) => a.contains('\u0000'))) {
    throw const FormatException('Caminho/argumentos inválidos');
  }
  final runtime = path.endsWith('.py')
      ? 'python'
      : path.endsWith('.js')
      ? 'node'
      : null;
  if (runtime == null) {
    throw const FormatException('Selecione um arquivo .py ou .js');
  }
  final directory = path.lastIndexOf('/') == 0
      ? '/'
      : path.substring(0, path.lastIndexOf('/'));
  final invocation = [
    runtime,
    shellQuote(path),
    ...arguments.map(shellQuote),
  ].join(' ');
  // Subshell preserves the interactive session's cwd; real status is reported.
  return '(cd ${shellQuote(directory)} && $invocation; _q_exit=\$?; printf "\\n[exit=%s]\\n" "\$_q_exit"; exit "\$_q_exit")';
}
