#define _GNU_SOURCE
#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

static void raise_errno(JNIEnv *env, const char *context) {
    char message[256];
    snprintf(message, sizeof message, "%s: %s", context, strerror(errno));
    jclass ex = (*env)->FindClass(env, "java/lang/RuntimeException");
    if (ex) (*env)->ThrowNew(env, ex, message);
}

JNIEXPORT jintArray JNICALL
Java_dev_qeltravyx_qeltravyx_MainActivity_nativeCreatePty(
    JNIEnv *env, jobject self, jstring home_j, jstring libs_j, jint rows, jint cols) {
    (void)self;
    // Make owned copies before fork; do not call JNI APIs in the child.
    const char *home_utf = (*env)->GetStringUTFChars(env, home_j, NULL);
    if (!home_utf) return NULL;
    const char *libs_utf = (*env)->GetStringUTFChars(env, libs_j, NULL);
    if (!libs_utf) {
        (*env)->ReleaseStringUTFChars(env, home_j, home_utf);
        return NULL;
    }
    char home[4096];
    char libs[4096];
    if (strlen(home_utf) >= sizeof home || strlen(libs_utf) >= sizeof libs) {
        (*env)->ReleaseStringUTFChars(env, home_j, home_utf);
        (*env)->ReleaseStringUTFChars(env, libs_j, libs_utf);
        jclass ex = (*env)->FindClass(env, "java/lang/IllegalArgumentException");
        if (ex) (*env)->ThrowNew(env, ex, "Caminho Android muito longo");
        return NULL;
    }
    strcpy(home, home_utf);
    strcpy(libs, libs_utf);
    (*env)->ReleaseStringUTFChars(env, home_j, home_utf);
    (*env)->ReleaseStringUTFChars(env, libs_j, libs_utf);
    char profile_path[4096];
    char workspace_path[4096];
    char tmp_path[4096];
    char toolbox_path[4096];
    if (snprintf(profile_path, sizeof profile_path, "%s/.qeltravyx/profile.sh", home) >= (int)sizeof profile_path ||
        snprintf(workspace_path, sizeof workspace_path, "%s/workspace", home) >= (int)sizeof workspace_path ||
        snprintf(tmp_path, sizeof tmp_path, "%s/workspace/tmp", home) >= (int)sizeof tmp_path ||
        snprintf(toolbox_path, sizeof toolbox_path, "%s/libqeltravyx_toolbox.so", libs) >= (int)sizeof toolbox_path) {
        jclass ex = (*env)->FindClass(env, "java/lang/IllegalArgumentException");
        if (ex) (*env)->ThrowNew(env, ex, "Caminho de ferramentas muito longo");
        return NULL;
    }
    int master = open("/dev/ptmx", O_RDWR | O_CLOEXEC);
    if (master < 0) {
        raise_errno(env, "open /dev/ptmx");
        return NULL;
    }
    char slave_path[128];
    if (grantpt(master) != 0 || unlockpt(master) != 0 ||
        ptsname_r(master, slave_path, sizeof slave_path) != 0) {
        raise_errno(env, "configure PTY");
        close(master);
        return NULL;
    }
    struct winsize sz = {0};
    sz.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    sz.ws_col = (unsigned short)(cols > 0 ? cols : 80);
    ioctl(master, TIOCSWINSZ, &sz);
    pid_t child = fork();
    if (child < 0) {
        raise_errno(env, "fork PTY");
        close(master);
        return NULL;
    }
    if (child == 0) {
        close(master);
        sigset_t all;
        sigfillset(&all);
        sigprocmask(SIG_UNBLOCK, &all, NULL);
        signal(SIGPIPE, SIG_DFL);
        if (setsid() < 0) _exit(121);
        int slave = open(slave_path, O_RDWR);
        if (slave < 0) _exit(122);
        ioctl(slave, TIOCSCTTY, 0);
        struct termios t;
        if (tcgetattr(slave, &t) == 0) {
            t.c_iflag &= ~(IXON | IXOFF);
#ifdef IUTF8
            t.c_iflag |= IUTF8;
#endif
            tcsetattr(slave, TCSANOW, &t);
        }
        if (dup2(slave, STDIN_FILENO) < 0 ||
            dup2(slave, STDOUT_FILENO) < 0 ||
            dup2(slave, STDERR_FILENO) < 0) _exit(123);
        if (slave > 2) close(slave);
        for (int fd = 3; fd < 1024; ++fd) close(fd);
        clearenv();
        setenv("HOME", home, 1);
        setenv("PWD", home, 1);
        setenv("TMPDIR", tmp_path, 1);
        setenv("ENV", profile_path, 1);
        setenv("QELTRAVYX_WORKSPACE", workspace_path, 1);
        setenv("QELTRAVYX_TOOLBOX", toolbox_path, 1);
        setenv("QELTRAVYX_VERSION", "0.4.0", 1);
        setenv("PATH", "/system/bin:/system/xbin", 1);
        setenv("TERM", "xterm-256color", 1);
        setenv("LANG", "C.UTF-8", 1);
        if (chdir(home) != 0) _exit(124);
        char *const argv[] = {"sh", "-i", NULL};
        execv("/system/bin/sh", argv);
        _exit(127);
    }
    jint values[2] = {(jint)master, (jint)child};
    jintArray result = (*env)->NewIntArray(env, 2);
    if (!result) { kill(child, SIGHUP); close(master); return NULL; }
    (*env)->SetIntArrayRegion(env, result, 0, 2, values);
    return result;
}

JNIEXPORT jboolean JNICALL
Java_dev_qeltravyx_qeltravyx_MainActivity_nativeResizePty(
    JNIEnv *env, jobject self, jint fd, jint rows, jint cols) {
    (void)env; (void)self;
    struct winsize sz = {0};
    sz.ws_row = (unsigned short)rows;
    sz.ws_col = (unsigned short)cols;
    return ioctl(fd, TIOCSWINSZ, &sz) == 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_dev_qeltravyx_qeltravyx_MainActivity_nativeSignalPty(
    JNIEnv *env, jobject self, jint pid) {
    (void)env; (void)self;
    if (pid > 0) { kill(-(pid_t)pid, SIGHUP); kill((pid_t)pid, SIGHUP); }
}

JNIEXPORT jint JNICALL
Java_dev_qeltravyx_qeltravyx_MainActivity_nativeWaitPty(
    JNIEnv *env, jobject self, jint pid) {
    (void)env; (void)self;
    int status = 0;
    pid_t done;
    do { done = waitpid((pid_t)pid, &status, 0); } while (done < 0 && errno == EINTR);
    return (jint)(done < 0 ? -1 : status);
}
