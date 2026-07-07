#!/bin/bash
# Rebuilds the offline editor bundle into Resources/dist.
set -euo pipefail
cd "$(dirname "$0")/../Editor"
npm install
npm run build
