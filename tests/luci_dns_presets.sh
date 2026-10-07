#!/usr/bin/env bash
set -euo pipefail

node "$(dirname "$0")/luci_dns_presets.js"
