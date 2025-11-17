#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Git Repository Sync Script
# ============================================================================
# Syncs a git repository from source to target, handling large numbers of
# branches and tags efficiently.
#
# RECOMMENDED USAGE:
#
#   Initial Sync (large repos):
#     INIT=true ./sync2.sh
#     ↑ Optimized for initial migration (batched, parallel, skips commit checks)
#
#   Subsequent Syncs (default):
#     ./sync2.sh
#     ↑ Fast incremental sync using mirror push
#
# Advanced Usage:
#   DRY_RUN=true ./sync2.sh                 # Preview changes
#   INIT=true MAX_PARALLEL_JOBS=32 ./sync2.sh  # More aggressive initial sync
#   USE_MIRROR_PUSH=false ./sync2.sh        # Force batched mode for subsequent sync
#
# Environment Variables:
#   INIT               - Set to 'true' for initial sync (batched, parallel, default: false)
#   SOURCE_REPO        - Source repository URL
#   TARGET_REPO        - Target repository URL
#   MIRROR_DIR         - Local mirror directory
#   SSH_KEY            - Path to SSH private key
#   DRY_RUN            - Preview mode (true/false, default: false)
#   FORCE_PUSH         - Force push diverged refs (true/false, default: TRUE)
#   PRUNE_DELETED      - Delete refs from target that don't exist in source (true/false, default: TRUE)
#
#   Advanced (auto-configured by INIT mode):
#   BATCH_SIZE         - Refs per batch (INIT: 50, default: 100)
#   MAX_PARALLEL_JOBS  - Concurrent operations (INIT: 16, default: 8)
#   SKIP_COMMIT_CHECK  - Skip commit comparison (INIT: true, default: false)
#   USE_MIRROR_PUSH    - Use mirror push (INIT: false, default: true)
# ============================================================================

# ---------------------------
# Configuration (can be overridden via environment variables)
# ---------------------------
SOURCE_REPO="${SOURCE_REPO}"
TARGET_REPO="${TARGET_REPO}"
MIRROR_DIR="${MIRROR_DIR}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
DRY_RUN="${DRY_RUN:-false}"
PRUNE_DELETED="${PRUNE_DELETED:-true}"
FORCE_PUSH="${FORCE_PUSH:-true}"
SKIP_DIVERGED="${SKIP_DIVERGED:-true}"

# ---------------------------
# Mode Selection (INIT vs Subsequent)
# ---------------------------
INIT="${INIT:-false}"

if [ "$INIT" = true ]; then
    # Initial sync mode: Batched, parallel, optimized for large migrations
    BATCH_SIZE="${BATCH_SIZE:-50}"           # Smaller batches for better parallelism
    MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-16}"  # More parallel jobs
    SKIP_COMMIT_CHECK="${SKIP_COMMIT_CHECK:-true}"  # Skip commit checks (faster)
    USE_MIRROR_PUSH="${USE_MIRROR_PUSH:-false}"     # Don't use mirror (avoid GitHub limits)
else
    # Subsequent sync mode: Fast mirror push
    BATCH_SIZE="${BATCH_SIZE:-100}"
    MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-8}"
    SKIP_COMMIT_CHECK="${SKIP_COMMIT_CHECK:-false}"
    USE_MIRROR_PUSH="${USE_MIRROR_PUSH:-true}"  # Use mirror for speed
fi

# Temp files for parallel execution
REMOTE_REFS_CACHE=$(mktemp)
STATS_DIR=$(mktemp -d)
BRANCHES_PUSHED_FILE="$STATS_DIR/branches_pushed"
TAGS_PUSHED_FILE="$STATS_DIR/tags_pushed"
BRANCHES_SKIPPED_FILE="$STATS_DIR/branches_skipped"
TAGS_SKIPPED_FILE="$STATS_DIR/tags_skipped"
FAILED_PUSHES_FILE="$STATS_DIR/failed_pushes"
DIVERGED_REFS_FILE="$STATS_DIR/diverged_refs"

# Initialize stats files
echo "0" > "$BRANCHES_PUSHED_FILE"
echo "0" > "$TAGS_PUSHED_FILE"
echo "0" > "$BRANCHES_SKIPPED_FILE"
echo "0" > "$TAGS_SKIPPED_FILE"
touch "$FAILED_PUSHES_FILE"
touch "$DIVERGED_REFS_FILE"

trap 'rm -rf "$REMOTE_REFS_CACHE" "$STATS_DIR"' EXIT

# Job control
ACTIVE_JOBS=0
START_TIME=$(date +%s)

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

# ---------------------------
# Atomic stats helpers (for parallel execution)
# ---------------------------
atomic_increment() {
    local file="$1"
    local amount="${2:-1}"
    local lockfile="${file}.lock"

    # Fast file locking without sleep
    local retries=0
    while ! mkdir "$lockfile" 2>/dev/null; do
        retries=$((retries + 1))
        if [ $retries -gt 1000 ]; then
            # Fallback: remove stale lock after many retries
            rmdir "$lockfile" 2>/dev/null || true
        fi
    done

    local current=$(cat "$file")
    echo $((current + amount)) > "$file"
    rmdir "$lockfile"
}

atomic_append() {
    local file="$1"
    local value="$2"
    local lockfile="${file}.lock"

    # Fast file locking without sleep
    local retries=0
    while ! mkdir "$lockfile" 2>/dev/null; do
        retries=$((retries + 1))
        if [ $retries -gt 1000 ]; then
            rmdir "$lockfile" 2>/dev/null || true
        fi
    done

    echo "$value" >> "$file"
    rmdir "$lockfile"
}

# ---------------------------
# Job control helpers
# ---------------------------
wait_for_job_slot() {
    while [ "$ACTIVE_JOBS" -ge "$MAX_PARALLEL_JOBS" ]; do
        # Wait for any job to finish
        wait -n 2>/dev/null || true
        ACTIVE_JOBS=$((ACTIVE_JOBS - 1))
    done
}

wait_all_jobs() {
    log "Waiting for all parallel jobs to complete..."
    wait
    ACTIVE_JOBS=0
}

# ---------------------------
# Display configuration
# ---------------------------
if [ "$INIT" = true ]; then
    log "🚀 INIT MODE: Optimized for initial sync"
    log "   ├─ Batch size: $BATCH_SIZE"
    log "   ├─ Parallel jobs: $MAX_PARALLEL_JOBS"
    log "   ├─ Skip commit checks: $SKIP_COMMIT_CHECK"
    log "   └─ Use mirror push: $USE_MIRROR_PUSH"
else
    log "⚡ SUBSEQUENT MODE: Fast incremental sync"
    log "   ├─ Parallel jobs: $MAX_PARALLEL_JOBS"
    log "   └─ Use mirror push: $USE_MIRROR_PUSH"
fi

if [ "$FORCE_PUSH" = true ]; then
    log_warn "⚠️  FORCE PUSH MODE ENABLED - Will overwrite remote history!"
fi

if [ "$DRY_RUN" = true ]; then
    log "ℹ️  DRY RUN MODE - No changes will be pushed"
fi

# ---------------------------
# SSH agent setup
# ---------------------------
log "Setting up SSH authentication..."
if ! pgrep -u "$USER" ssh-agent >/dev/null; then
    log "Starting SSH agent..."
    eval "$(ssh-agent -s)"
fi

if [ ! -f "$SSH_KEY" ]; then
    log_error "SSH key not found at $SSH_KEY"
    exit 1
fi

if ! ssh-add -l | grep -q "$(ssh-keygen -lf "$SSH_KEY" | awk '{print $2}')"; then
    log "Adding SSH key $SSH_KEY to agent..."
    ssh-add "$SSH_KEY"
fi

# ---------------------------
# Clone or update mirror
# ---------------------------
if [ ! -d "$MIRROR_DIR" ]; then
    log "Cloning mirror from source..."
    git clone --mirror "$SOURCE_REPO" "$MIRROR_DIR"
else
    log "Updating existing mirror from source..."
    (
        cd "$MIRROR_DIR"
        git fetch origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' --prune
    )
fi

cd "$MIRROR_DIR"

# ---------------------------
# Configure remotes safely
# ---------------------------
log "Configuring remotes..."
# Keep 'origin' for fetching from source, but redirect pushes to target
# This prevents accidentally pushing back to the source repo
git remote set-url --push origin "$TARGET_REPO"

# Add explicit target remote for clarity (or update if it exists)
if git remote get-url new-origin >/dev/null 2>&1; then
    git remote set-url new-origin "$TARGET_REPO"
else
    git remote add new-origin "$TARGET_REPO"
fi


# Verify target repo is accessible
log "Verifying target repository access..."
if ! git ls-remote new-origin HEAD >/dev/null 2>&1; then
    log_error "Cannot access target repository: $TARGET_REPO"
    exit 1
fi

log "Pre-flight checks passed ✓"

# ---------------------------
# Fast mirror mode (skip all the batching logic)
# ---------------------------
# Mirror push handles ALL refs (branches, tags, notes, etc.) in a single operation.
# This is fastest for subsequent syncs with few changes, but may exceed GitHub
# limits on initial syncs with thousands of refs.
# ---------------------------
if [ "$USE_MIRROR_PUSH" = true ]; then
    if [ "$FORCE_PUSH" != true ]; then
        log_error "USE_MIRROR_PUSH requires FORCE_PUSH=true for safety"
        exit 1
    fi

    log "⚡ Using ultra-fast mirror mode (git push --mirror)..."
    log "   This pushes ALL refs (branches + tags + everything) in one operation"

    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would run: git push --mirror --force new-origin"
        exit 0
    else
        log "Pushing all refs in one operation..."
        if git push --mirror --force new-origin 2>&1; then
            END_TIME=$(date +%s)
            DURATION=$((END_TIME - START_TIME))
            MINUTES=$((DURATION / 60))
            SECONDS=$((DURATION % 60))

            echo ""
            log "=========================================="
            log "           SYNC SUMMARY"
            log "=========================================="
            log "Mode: Ultra-fast mirror push"
            log "Duration: ${MINUTES}m ${SECONDS}s"
            log "=========================================="
            log "✅ Mirror sync complete successfully!"
            exit 0
        else
            log_error "Mirror push failed"
            exit 1
        fi
    fi
fi

# ---------------------------
# Cache remote refs (huge performance improvement)
# ---------------------------
log "Fetching remote refs from target (this may take a moment)..."
git ls-remote new-origin > "$REMOTE_REFS_CACHE"
log "Cached $(wc -l < "$REMOTE_REFS_CACHE" | tr -d ' ') remote refs"
# ---------------------------
# Helper to push a batch
# ---------------------------
push_batch_impl() {
    local type="$1"
    shift
    local refs=("$@")

    local push_flags=()
    if [ "$FORCE_PUSH" = true ]; then
        push_flags+=(--force)
    fi

    log "Pushing batch of ${#refs[@]} $type(s)..."
    local push_output
    if push_output=$(git push new-origin "${push_flags[@]}" "${refs[@]}" 2>&1); then
        if [ "$type" = "branch" ]; then
            atomic_increment "$BRANCHES_PUSHED_FILE" "${#refs[@]}"
        else
            atomic_increment "$TAGS_PUSHED_FILE" "${#refs[@]}"
        fi
    else
        log_error "Failed to push batch"

        # Try pushing individually to identify which refs failed
        log "Retrying failed batch individually..."
        for ref in "${refs[@]}"; do
            local ref_output
            if ref_output=$(git push new-origin "${push_flags[@]}" "$ref" 2>&1); then
                log "✓ Successfully pushed: $ref"
                if [ "$type" = "branch" ]; then
                    atomic_increment "$BRANCHES_PUSHED_FILE" 1
                else
                    atomic_increment "$TAGS_PUSHED_FILE" 1
                fi
            else
                # Check if it's a non-fast-forward error
                if echo "$ref_output" | grep -q "non-fast-forward\|rejected"; then
                    if [ "$SKIP_DIVERGED" = true ]; then
                        log_warn "⊘ Skipped diverged $type: $ref (use FORCE_PUSH=true to override)"
                        atomic_append "$DIVERGED_REFS_FILE" "$type:$ref"
                        if [ "$type" = "branch" ]; then
                            atomic_increment "$BRANCHES_SKIPPED_FILE" 1
                        else
                            atomic_increment "$TAGS_SKIPPED_FILE" 1
                        fi
                    else
                        log_error "✗ Diverged $type: $ref"
                        atomic_append "$FAILED_PUSHES_FILE" "$type:$ref"
                    fi
                else
                    log_error "✗ Failed to push: $ref"
                    echo "$ref_output" | head -n 3 >&2
                    atomic_append "$FAILED_PUSHES_FILE" "$type:$ref"
                fi
            fi
        done
    fi
}

push_batch() {
    local type="$1"
    shift
    local refs=("$@")

    if [ "${#refs[@]}" -eq 0 ]; then
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would push ${#refs[@]} $type(s): ${refs[*]:0:5}..."
        return
    fi

    # Wait for available job slot
    wait_for_job_slot

    # Launch push in background
    push_batch_impl "$type" "${refs[@]}" &
    ACTIVE_JOBS=$((ACTIVE_JOBS + 1))
}

# ---------------------------
# Push updated branches
# ---------------------------
log "Checking branches for updates..."
BRANCHES=()
while IFS= read -r line; do BRANCHES+=("$line"); done < <(git for-each-ref --format='%(refname:short)' refs/heads/)
TOTAL_BRANCHES=${#BRANCHES[@]}
log "Found $TOTAL_BRANCHES local branches"

BATCH=()
CURRENT=0
for branch in "${BRANCHES[@]}"; do
    CURRENT=$((CURRENT + 1))
    LOCAL_REF="refs/heads/$branch"

    # Use cached remote refs instead of individual ls-remote calls
    REMOTE_REF=$(grep "refs/heads/$branch$" "$REMOTE_REFS_CACHE" | awk '{print $1}' || true)

    if [ -z "$REMOTE_REF" ]; then
        log "[$CURRENT/$TOTAL_BRANCHES] New branch: $branch"
        BATCH+=("$branch")
    else
        if [ "$SKIP_COMMIT_CHECK" = true ]; then
            # Fast mode: push all branches without checking commits
            BATCH+=("$branch")
        elif git cat-file -e "$LOCAL_REF" 2>/dev/null; then
            NEW_COMMITS=$(git rev-list "$REMOTE_REF".."$LOCAL_REF" --count 2>/dev/null || echo 0)
            if [ "$NEW_COMMITS" -gt 0 ]; then
                log "[$CURRENT/$TOTAL_BRANCHES] Branch $branch has $NEW_COMMITS new commit(s)"
                BATCH+=("$branch")
            else
                # Uncomment for verbose output
                # log "[$CURRENT/$TOTAL_BRANCHES] Branch $branch is up to date"
                :
            fi
        else
            log_warn "[$CURRENT/$TOTAL_BRANCHES] Skipping missing local ref: $LOCAL_REF"
        fi
    fi

    if [ "${#BATCH[@]}" -ge "$BATCH_SIZE" ]; then
        push_batch "branch" "${BATCH[@]}"
        BATCH=()
    fi
done

push_batch "branch" "${BATCH[@]}"

# Wait for all branch pushes to complete
wait_all_jobs

# ---------------------------
# Push updated tags
# ---------------------------
log "Checking tags for updates..."
TAGS=()
while IFS= read -r line; do TAGS+=("$line"); done < <(git tag)
TOTAL_TAGS=${#TAGS[@]}
log "Found $TOTAL_TAGS local tags"

BATCH=()
CURRENT=0
for tag in "${TAGS[@]}"; do
    CURRENT=$((CURRENT + 1))

    # Use cached remote refs instead of individual ls-remote calls
    REMOTE_TAG=$(grep "refs/tags/$tag$" "$REMOTE_REFS_CACHE" | awk '{print $1}' || true)
    LOCAL_TAG=$(git rev-parse "$tag" 2>/dev/null || true)

    if [ -z "$LOCAL_TAG" ]; then
        log_warn "[$CURRENT/$TOTAL_TAGS] Skipping invalid tag: $tag"
        continue
    fi

    if [ -z "$REMOTE_TAG" ]; then
        log "[$CURRENT/$TOTAL_TAGS] New tag: $tag"
        BATCH+=("$tag")
    elif [ "$SKIP_COMMIT_CHECK" = true ]; then
        # Fast mode: push all tags without checking
        BATCH+=("$tag")
    elif [ "$REMOTE_TAG" != "$LOCAL_TAG" ]; then
        log "[$CURRENT/$TOTAL_TAGS] Tag $tag has changed"
        BATCH+=("$tag")
    else
        # Uncomment for verbose output
        # log "[$CURRENT/$TOTAL_TAGS] Tag $tag is up to date"
        :
    fi

    if [ "${#BATCH[@]}" -ge "$BATCH_SIZE" ]; then
        push_batch "tag" "${BATCH[@]}"
        BATCH=()
    fi
done

push_batch "tag" "${BATCH[@]}"

# Wait for all tag pushes to complete
wait_all_jobs

# ---------------------------
# Handle deleted refs (optional)
# ---------------------------
if [ "$PRUNE_DELETED" = true ]; then
    log "Pruning deleted refs from target..."
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would run: git push new-origin --prune"
    else
        git push new-origin --prune
    fi
fi

# ---------------------------
# Summary report
# ---------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

# Read final stats from files
BRANCHES_PUSHED=$(cat "$BRANCHES_PUSHED_FILE")
TAGS_PUSHED=$(cat "$TAGS_PUSHED_FILE")
BRANCHES_SKIPPED=$(cat "$BRANCHES_SKIPPED_FILE")
TAGS_SKIPPED=$(cat "$TAGS_SKIPPED_FILE")
DIVERGED_REFS=()
if [ -s "$DIVERGED_REFS_FILE" ]; then
    while IFS= read -r line; do DIVERGED_REFS+=("$line"); done < "$DIVERGED_REFS_FILE"
fi
FAILED_PUSHES=()
if [ -s "$FAILED_PUSHES_FILE" ]; then
    while IFS= read -r line; do FAILED_PUSHES+=("$line"); done < "$FAILED_PUSHES_FILE"
fi

echo ""
log "=========================================="
log "           SYNC SUMMARY"
log "=========================================="
log "Branches pushed: $BRANCHES_PUSHED"
log "Branches skipped (diverged): $BRANCHES_SKIPPED"
log "Tags pushed: $TAGS_PUSHED"
log "Tags skipped (diverged): $TAGS_SKIPPED"
log "Failed pushes: ${#FAILED_PUSHES[@]}"
log "Duration: ${MINUTES}m ${SECONDS}s"
log "Parallel jobs: $MAX_PARALLEL_JOBS"
log "=========================================="

if [ "${#DIVERGED_REFS[@]}" -gt 0 ]; then
    echo ""
    log_warn "Diverged refs skipped (histories don't match):"
    for ref in "${DIVERGED_REFS[@]}"; do
        log_warn "  - $ref"
    done
    echo ""
    log "ℹ️  To force push these refs, run with: FORCE_PUSH=true"
    log "⚠️  WARNING: Force pushing will overwrite remote history!"
fi

if [ "${#FAILED_PUSHES[@]}" -gt 0 ]; then
    echo ""
    log_error "Some refs failed to push:"
    for ref in "${FAILED_PUSHES[@]}"; do
        log_error "  - $ref"
    done
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    log "DRY RUN complete - no changes were pushed"
else
    log "✅ Sync complete successfully!"
fi

