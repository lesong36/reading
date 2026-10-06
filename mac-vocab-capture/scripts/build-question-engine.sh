#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$PROJECT_DIR/question-engine"
ENGINE_BUILD_DIR="$PROJECT_DIR/build/langchain"
QUESTION_UV="${QUESTION_ENGINE_UV:-$(command -v uv || true)}"
if [[ -z "$QUESTION_UV" ]]; then
  echo "打包问答引擎需要 uv。请先按 https://docs.astral.sh/uv/ 安装。" >&2
  exit 1
fi

# A managed interpreter makes the frozen helper independent of Homebrew paths.
"$QUESTION_UV" sync --project "$ENGINE_DIR" --frozen --extra build \
  --python "${QUESTION_ENGINE_PYTHON:-3.13}" --python-preference only-managed
mkdir -p "$ENGINE_BUILD_DIR"
"$ENGINE_DIR/.venv/bin/python" -m PyInstaller \
  --noconfirm --onedir --name QuestionEngine --contents-directory runtime \
  --distpath "$ENGINE_BUILD_DIR/dist" --workpath "$ENGINE_BUILD_DIR/work" \
  --specpath "$ENGINE_BUILD_DIR" \
  --recursive-copy-metadata langchain \
  --recursive-copy-metadata langchain-openai \
  --recursive-copy-metadata langchain-anthropic \
  --collect-submodules langchain_openai --collect-submodules langchain_anthropic \
  --hidden-import _scproxy \
  --collect-data certifi \
  "$ENGINE_DIR/question_engine.py"

echo "$ENGINE_BUILD_DIR/dist/QuestionEngine"
