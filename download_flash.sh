#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_ID="${MODEL_ID:-deepseek-ai/DeepSeek-V4-Flash}" exec "${SCRIPT_DIR}/download_model.sh"
