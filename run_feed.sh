#!/usr/bin/env bash
# Local replica of the "Run Feed Processor" workflow.
#   ./run_feed.sh --setup   one-time: apt packages + KVM group (needs sudo, interactive)
#   ./run_feed.sh           normal run (cron-safe, no sudo)
#
# Cached between runs: Android SDK, system image, AVD (+ quick-boot snapshot),
# cmdline-tools zip, Python venv (rebuilt only when requirements.txt changes), pip cache.

set -euo pipefail

# ---------- config ----------
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/feed-runner}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"

AVD_NAME="ci"
API_LEVEL="33"
SYS_IMAGE="system-images;android-${API_LEVEL};google_apis;x86_64"
EMU_RAM_MB="2048"
CMDLINE_TOOLS_URL="${CMDLINE_TOOLS_URL:-https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip}"
APK_FILE="dudetv_3.2v.apk"
BOOT_TIMEOUT_S=600        # max wait for emulator boot
SCRIPT_TIMEOUT="30m"      # max runtime of fetch_and_decrypt.py
DO_GIT_PUSH="${DO_GIT_PUSH:-1}"

LOG_DIR="$CACHE_DIR/logs"
VENV_DIR="$CACHE_DIR/venv"
LOCK_FILE="$CACHE_DIR/run.lock"
mkdir -p "$CACHE_DIR" "$LOG_DIR" "$CACHE_DIR/downloads"

# ---------- one-time setup ----------
if [[ "${1:-}" == "--setup" ]]; then
  sudo apt update
  sudo apt install -y openjdk-17-jdk qemu-kvm unzip wget python3-venv cpu-checker git
  kvm-ok || true
  sudo usermod -aG kvm "$USER"
  echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger --name-match=kvm
  echo "Setup done. Log out and back in, then run without --setup."
  exit 0
fi

# ---------- logging + single-instance lock ----------
exec > >(tee -a "$LOG_DIR/run_$(date +%Y%m%d).log") 2>&1
echo "=== Run started $(date -Is) ==="
find "$LOG_DIR" -name 'run_*.log' -mtime +7 -delete

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Previous run still active. Exiting."
  exit 0
fi

# ---------- prerequisites ----------
for bin in java python3.12 git unzip wget; do
  command -v "$bin" >/dev/null || { echo "Missing: $bin (run ./run_feed.sh --setup)"; exit 1; }
done
[[ -r /dev/kvm && -w /dev/kvm ]] || { echo "/dev/kvm not accessible (run --setup, then re-login)"; exit 1; }

# ---------- Android SDK (cached) ----------
if [[ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]]; then
  ZIP="$CACHE_DIR/downloads/$(basename "$CMDLINE_TOOLS_URL")"
  if [[ ! -f "$ZIP" ]]; then
    wget -q --show-progress -O "$ZIP.part" "$CMDLINE_TOOLS_URL"
    mv -f "$ZIP.part" "$ZIP"
  fi
  rm -rf "$ANDROID_HOME/cmdline-tools"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  unzip -q "$ZIP" -d "$ANDROID_HOME/cmdline-tools"
  mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
fi

if [[ ! -x "$ANDROID_HOME/emulator/emulator" || ! -d "$ANDROID_HOME/system-images/android-${API_LEVEL}/google_apis/x86_64" || ! -d "$ANDROID_HOME/platforms/android-${API_LEVEL}" ]]; then
  yes | sdkmanager --licenses >/dev/null || true
  sdkmanager "platform-tools" "emulator" "platforms;android-${API_LEVEL}" "$SYS_IMAGE"
fi

if ! avdmanager list avd | grep -q "Name: ${AVD_NAME}$"; then
  echo no | avdmanager create avd -n "$AVD_NAME" -k "$SYS_IMAGE" -d pixel_5 --force
fi

# ---------- Python venv (cached; rebuilt only if requirements.txt changed) ----------
cd "$REPO_DIR"
export PIP_CACHE_DIR="$CACHE_DIR/pip"
REQ_HASH="$(sha256sum requirements.txt | cut -d' ' -f1)"
if [[ ! -x "$VENV_DIR/bin/python" || "$(cat "$VENV_DIR/.req_hash" 2>/dev/null || true)" != "$REQ_HASH" ]]; then
  python3.12 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install -r requirements.txt
  echo "$REQ_HASH" > "$VENV_DIR/.req_hash"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

# ---------- emulator ----------
EMU_PID=""
cleanup() {
  adb emu kill >/dev/null 2>&1 || true
  [[ -n "$EMU_PID" ]] && { sleep 5; kill "$EMU_PID" >/dev/null 2>&1 || true; }
}
trap cleanup EXIT

adb start-server
nohup emulator -avd "$AVD_NAME" -memory "$EMU_RAM_MB" -no-window -gpu swiftshader_indirect \
  -noaudio -no-boot-anim -camera-back none -no-snapshot-save >"$LOG_DIR/emulator.log" 2>&1 &
EMU_PID=$!

timeout "$BOOT_TIMEOUT_S" adb wait-for-device
SECONDS=0
until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
  (( SECONDS > BOOT_TIMEOUT_S )) && { echo "Emulator boot timeout"; exit 1; }
  sleep 2
done

adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell wm dismiss-keyguard

# Save a clean post-boot snapshot once; later runs load it instead of cold booting.
if ! adb emu avd snapshot list 2>/dev/null | grep -q "default_boot"; then
  echo "Saving default_boot snapshot (one-time)..."
  adb emu avd snapshot save default_boot || echo "Snapshot save failed; continuing."
fi

# ---------- workflow script step ----------
adb install -r -g "$APK_FILE"
adb shell pm grant com.sportzx.live android.permission.POST_NOTIFICATIONS || true
timeout "$SCRIPT_TIMEOUT" python fetch_and_decrypt.py

cleanup
EMU_PID=""

# ---------- commit and push ----------
if [[ "$DO_GIT_PUSH" == "1" ]]; then
  git add -f public_decrypted/ config.json
  if git diff --cached --quiet; then
    echo "No changes to commit."
  else
    git commit -m "chore: update decrypted data feeds [skip ci]"
    git pull --rebase --autostash
    git push
  fi
fi

echo "=== Run finished $(date -Is) ==="
