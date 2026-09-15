#!/bin/zsh
# Source of truth for 英语长难句阅读器.app/Contents/MacOS/launcher
# Synced by: npm run sync:app

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCE_DIR="$BUNDLE_DIR/Resources"
INDEX_FILE="$RESOURCE_DIR/index.html"
PYTHON_BIN="${PYTHON_BIN:-python3}"
DEFAULT_PORT=8765
LOG_FILE="$HOME/.english_reader_app_server.log"
PID_FILE="$HOME/.english_reader_app_server.pid"
COSYVOICE_PYTHON="/Users/coty/miniconda3/envs/cosyvoice/bin/python"
COSYVOICE_SERVER="$RESOURCE_DIR/cosyvoice_server.py"
COSYVOICE_LOG="$HOME/.english_reader_cosyvoice.log"
COSYVOICE_PID="$HOME/.english_reader_cosyvoice.pid"
APP_MTIME="$(stat -f '%m' "$INDEX_FILE" 2>/dev/null || date +%s)"
URL="http://127.0.0.1:${DEFAULT_PORT}/index.html?v=${APP_MTIME}"
TMP_SERVER="$RESOURCE_DIR/reader_app_server.py"
EDGE_TTS_VENV="$RESOURCE_DIR/.edge-tts-venv"
EDGE_TTS_REQUIREMENTS="$RESOURCE_DIR/requirements.txt"

cleanup_old_server() {
  if [[ -f "$PID_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "${old_pid:-}" ]] && ps -p "$old_pid" >/dev/null 2>&1; then
      kill "$old_pid" >/dev/null 2>&1 || true
      sleep 1
    fi
  fi

  local pids
  pids="$(lsof -tiTCP:"$DEFAULT_PORT" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "${pids:-}" ]]; then
    echo "$pids" | xargs kill >/dev/null 2>&1 || true
    sleep 1
  fi
}

start_cosyvoice() {
  [[ -x "$COSYVOICE_PYTHON" ]] || return 0
  [[ -f "$COSYVOICE_SERVER" ]] || return 0

  if lsof -nP -iTCP:8766 -sTCP:LISTEN >/dev/null 2>&1; then
    return 0
  fi

  if [[ -f "$COSYVOICE_PID" ]]; then
    local old_cv
    old_cv="$(cat "$COSYVOICE_PID" 2>/dev/null || true)"
    if [[ -n "${old_cv:-}" ]] && ps -p "$old_cv" >/dev/null 2>&1; then
      kill "$old_cv" >/dev/null 2>&1 || true
      sleep 1
    fi
  fi

  nohup "$COSYVOICE_PYTHON" "$COSYVOICE_SERVER" >>"$COSYVOICE_LOG" 2>&1 </dev/null &
  local cv_pid=$!
  echo "$cv_pid" > "$COSYVOICE_PID"
  disown "$cv_pid" 2>/dev/null || true

  local waited=0
  while (( waited < 90 )); do
    if lsof -nP -iTCP:8766 -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    if ! ps -p "$cv_pid" >/dev/null 2>&1; then
      osascript -e "display alert \"CosyVoice 启动失败\" message \"进程已退出，请查看日志：${COSYVOICE_LOG}\"" as warning 2>/dev/null || true
      return 1
    fi
    sleep 1
    (( waited++ ))
  done
  osascript -e 'display alert "CosyVoice 启动较慢" message "模型仍在加载，语音可能稍后才能使用。"' as informational 2>/dev/null || true
  return 0
}

ensure_edge_tts() {
  local edge_python="$EDGE_TTS_VENV/bin/python"
  if [[ -x "$edge_python" ]] && "$edge_python" -c 'import edge_tts' >/dev/null 2>&1; then
    PYTHON_BIN="$edge_python"
    return 0
  fi

  if [[ ! -f "$EDGE_TTS_REQUIREMENTS" ]]; then
    osascript -e 'display alert "语音启动失败" message "应用内缺少 Edge TTS 依赖文件，请运行 npm run sync:app 后重试。" as critical'
    return 1
  fi

  "$PYTHON_BIN" -m venv "$EDGE_TTS_VENV" || {
    osascript -e 'display alert "语音启动失败" message "无法创建 Edge TTS 运行环境。" as critical'
    return 1
  }
  "$edge_python" -m pip install --disable-pip-version-check --quiet -r "$EDGE_TTS_REQUIREMENTS" || {
    osascript -e 'display alert "语音启动失败" message "首次安装 Edge TTS 失败，请检查网络后重新打开应用。" as critical'
    return 1
  }
  PYTHON_BIN="$edge_python"
}

if [[ ! -f "$INDEX_FILE" ]]; then
  osascript -e 'display alert "启动失败" message "应用包内缺少页面资源 index.html。" as critical'
  exit 1
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  osascript -e 'display alert "启动失败" message "未找到 python3，无法启动本地页面服务。" as critical'
  exit 1
fi

ensure_edge_tts || exit 1

if command -v ollama >/dev/null 2>&1; then
  if ! lsof -nP -iTCP:11434 -sTCP:LISTEN >/dev/null 2>&1; then
    nohup ollama serve >"$HOME/.english_reader_ollama.log" 2>&1 </dev/null &
    disown $! 2>/dev/null || true
    sleep 2
  fi
fi

cleanup_old_server

if [[ ! -f "$TMP_SERVER" ]]; then
  osascript -e 'display alert "启动失败" message "应用包内缺少 reader_app_server.py，请运行 npm run sync:app。" as critical'
  exit 1
fi

nohup "$PYTHON_BIN" "$TMP_SERVER" "$RESOURCE_DIR" "$DEFAULT_PORT" >>"$LOG_FILE" 2>&1 </dev/null &
SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"
disown "$SERVER_PID" 2>/dev/null || true

sleep 1

if ! lsof -nP -iTCP:"$DEFAULT_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  osascript -e 'display alert "启动失败" message "应用内页面服务未能正常启动。" as critical'
  exit 1
fi

open "$URL"
exit 0
