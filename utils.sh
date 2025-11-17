#!/usr/bin/env bash
# ---------------------------
# Logging helper
# ---------------------------
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ❌ ERROR: $*" >&2
}

log_warn() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  WARNING: $*" >&2
}
