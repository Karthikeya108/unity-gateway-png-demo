#!/usr/bin/env bash
# Builds the MCP server image in ACR. Wheels are downloaded locally (PIP_INDEX_URL, e.g. a corporate proxy)
# and installed offline in the build, so the remote build agent never needs access to the package index.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-v1}"
PIP_INDEX="${PIP_INDEX_URL:-https://pypi.org/simple}"
ACR=$(terraform -chdir="$ROOT/infra/azure" output -raw acr_name)

rm -rf "$ROOT/mcp/wheels"
python3 -m pip download -q -d "$ROOT/mcp/wheels" -r "$ROOT/mcp/requirements.txt" --index-url "$PIP_INDEX" \
  --platform manylinux2014_x86_64 --platform manylinux_2_17_x86_64 --platform manylinux_2_28_x86_64 \
  --python-version 3.12 --implementation cp --only-binary=:all:

az acr build --registry "$ACR" --image "internal-mcp:$TAG" --platform linux/amd64 "$ROOT/mcp"
