#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>

static int present_directory(const char *path) {
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}
static int print_info(void) {
    struct utsname u;
    if (uname(&u) < 0) { perror("uname"); return 1; }
    printf("QELTRAVYX TOOLBOX 0.4.0\n");
    printf("Android: %s | kernel: %s\n", u.sysname, u.release);
    printf("Arquitetura: %s | uid=%ld\n", u.machine, (long)getuid());
    printf("Executavel nativo proprio, empacotado no APK.\n");
    printf("Shell: /system/bin/sh (nao e distribuicao Linux completa).\n");
    return 0;
}
static int doctor(void) {
    const char *home = getenv("HOME");
    const char *workspace = getenv("QELTRAVYX_WORKSPACE");
    const char *binary = getenv("QELTRAVYX_TOOLBOX");
    int fail = 0;
    printf("=== QELTRAVYX 0.4 | DIAGNOSTICO ===\n");
    printf("HOME: %s\n", home ? home : "nao definido");
    printf("WORKSPACE: %s\n", workspace ? workspace : "nao definido");
    printf("TOOLBOX: %s\n", binary ? binary : "nao definido");
    if (!present_directory(home)) { puts("FALHA: HOME inacessivel"); fail = 1; }
    else puts("OK: HOME");
    if (!present_directory(workspace)) { puts("FALHA: WORKSPACE inacessivel"); fail = 1; }
    else puts("OK: WORKSPACE");
    if (!binary || access(binary, X_OK) != 0) {
        puts("FALHA: toolbox nao executavel"); fail = 1;
    } else puts("OK: utilitario ARM64 executavel");
    puts("Nota: Python, Bash, Node, Git e Codex nao foram instalados.");
    puts(fail ? "STATUS: VERIFICAR" : "STATUS: OK");
    return fail;
}
int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "help";
    if (strcmp(cmd, "info") == 0 || strcmp(cmd, "version") == 0) return print_info();
    if (strcmp(cmd, "doctor") == 0) return doctor();
    if (strcmp(cmd, "help") == 0) {
        puts("QELTRAVYX Toolbox 0.4.0 — ajuda\n"
             "  qnative info     Identificacao da ferramenta nativa\n"
             "  qnative doctor   Teste de pastas e executavel\n"
             "  qnative help     Esta ajuda");
        return 0;
    }
    fprintf(stderr, "Comando desconhecido: %s (use qnative help)\n", cmd);
    return 2;
}
