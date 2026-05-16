#!/usr/bin/env bash
# claude-executor/bin/install-watcher.sh
#
# `claude-executor/systemd/watcher.service` を user-local の systemd
# に symlink して daemon-reload + enable + start する。
# = install-systemd-queue-runner.sh の watcher 版。
#
# 想定運用:
#   - dev マシン (leo): `bash claude-executor/bin/install-watcher.sh` 1 回で
#     merge-when-green watcher を常駐化。Claude session 切断 / WSL 再起動 / crash
#     後も systemd が自動復活させる (= nohup 単独だと SIGHUP で死ぬ問題の根治)。
#
# Usage:
#   bash claude-executor/bin/install-watcher.sh                 # install + enable + start
#   bash claude-executor/bin/install-watcher.sh --no-start      # enable のみ
#   bash claude-executor/bin/install-watcher.sh --no-linger     # loginctl enable-linger 呼ばない
#   bash claude-executor/bin/install-watcher.sh --uninstall     # symlink 削除 + disable
#
# 注意:
#   - 既存の nohup / setsid 起動 watcher process があれば pkill で停止してから
#     systemd 化する (= 二重起動防止)
#
# 参照: claude-executor/systemd/watcher.service
#       claude-executor/bin/install-queue-runner.sh (= 兄弟 script)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_UNIT="${REPO_ROOT}/claude-executor/systemd/watcher.service"
DST_DIR="${HOME}/.config/systemd/user"
DST_UNIT="${DST_DIR}/claude-executor-watcher.service"
SERVICE_NAME="claude-executor-watcher.service"

UNINSTALL=0
NO_LINGER=0
NO_START=0

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=1 ;;
    --no-linger) NO_LINGER=1 ;;
    --no-start)  NO_START=1 ;;
    --help|-h)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "[install-watcher] unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

log() {
  echo "[install-watcher] $*"
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  if systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1; then
    log "stopping $SERVICE_NAME"
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
  fi
  if systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    log "disabling $SERVICE_NAME"
    systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
  fi
  if [[ -L "$DST_UNIT" || -f "$DST_UNIT" ]]; then
    log "removing $DST_UNIT"
    rm -f "$DST_UNIT"
  fi
  systemctl --user daemon-reload 2>/dev/null || true
  log "uninstall done"
  exit 0
fi

if [[ ! -f "$SRC_UNIT" ]]; then
  log "ERROR: source unit not found: $SRC_UNIT"
  exit 3
fi

mkdir -p "$DST_DIR"

# 既存の nohup / setsid 起動 watcher があれば停止 (= systemd と二重稼働しない)
PIDS="$(pgrep -f '(merge-when-green\|watcher).sh.*--watch' 2>/dev/null || true)"
if [[ -n "$PIDS" ]]; then
  log "found existing watcher PIDs: $PIDS (stopping to avoid duplicate)"
  for p in $PIDS; do kill -TERM "$p" 2>/dev/null || true; done
  sleep 5
  STILL="$(pgrep -f '(merge-when-green\|watcher).sh.*--watch' 2>/dev/null || true)"
  if [[ -n "$STILL" ]]; then
    log "force-killing residual PIDs: $STILL"
    for p in $STILL; do kill -KILL "$p" 2>/dev/null || true; done
  fi
fi

# symlink
if [[ -L "$DST_UNIT" ]]; then
  current_target="$(readlink "$DST_UNIT")"
  if [[ "$current_target" == "$SRC_UNIT" ]]; then
    log "symlink already points to $SRC_UNIT (no change)"
  else
    log "replacing existing symlink ($current_target → $SRC_UNIT)"
    rm -f "$DST_UNIT"
    ln -s "$SRC_UNIT" "$DST_UNIT"
  fi
elif [[ -f "$DST_UNIT" ]]; then
  backup="${DST_UNIT}.bak.$(date +%Y%m%d-%H%M%S)"
  log "existing file detected, backing up to $backup"
  mv "$DST_UNIT" "$backup"
  ln -s "$SRC_UNIT" "$DST_UNIT"
else
  log "creating symlink $DST_UNIT → $SRC_UNIT"
  ln -s "$SRC_UNIT" "$DST_UNIT"
fi

log "systemctl --user daemon-reload"
systemctl --user daemon-reload || log "WARN: daemon-reload failed"

log "systemctl --user enable $SERVICE_NAME"
systemctl --user enable "$SERVICE_NAME" || log "WARN: enable failed"

# linger (= login session 無くても起動継続)
if [[ "$NO_LINGER" -eq 0 ]]; then
  current_user="$(id -un)"
  if command -v loginctl >/dev/null 2>&1; then
    is_linger="$(loginctl show-user "$current_user" -p Linger 2>/dev/null | cut -d= -f2 || echo no)"
    if [[ "$is_linger" != "yes" ]]; then
      log "loginctl enable-linger $current_user (sudo)"
      sudo loginctl enable-linger "$current_user" || log "WARN: enable-linger failed"
    else
      log "linger already enabled for $current_user"
    fi
  fi
fi

if [[ "$NO_START" -eq 0 ]]; then
  log "systemctl --user start $SERVICE_NAME"
  systemctl --user start "$SERVICE_NAME" || log "WARN: start failed"
fi

log "install done"
log "  status:    systemctl --user status $SERVICE_NAME"
log "  logs:      tail -f /home/neo/manademia/logs/merge-watcher.log"
log "  restart:   systemctl --user restart $SERVICE_NAME"
log "  uninstall: bash $0 --uninstall"
