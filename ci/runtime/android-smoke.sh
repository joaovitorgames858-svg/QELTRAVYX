#!/system/bin/sh
# Run only inside a developer-authorized scratch directory on Android.
# Arguments are absolute paths to the packaged executable and smoke asset directory.
set -eu
q_node="$1"
q_assets="$2"
case "$q_node" in /*/libqeltravyx_node.so) ;; *) exit 64 ;; esac
[ ! -e node-write.txt ] && [ ! -e node-renamed.txt ]
"$q_node" --version
printf 'entrada-ok\n' | "$q_node" "$q_assets/node_smoke.js" 'argumento ç'
# npm smoke also needs qel-js-demo-1.0.0.tgz in this scratch cwd.
# Use the in-app Runtimes panel for the isolated npm and Git smoke.
