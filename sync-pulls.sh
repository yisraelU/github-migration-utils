#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# GitHub Pull Request Sync Script
# ============================================================================
# Migrates pull requests from source GitHub instance to target.
# Recreates PRs with original title, body, labels, and metadata.
#
# PREREQUISITES:
#   - gh CLI installed and authenticated for BOTH GitHub instances
#   - Source and target repos must exist
#   - Branches must already be synced (use sync2.sh first)
#
# RECOMMENDED USAGE:
#   ./sync-pulls.sh                             # Sync all open PRs
#   STATE=all ./sync-pulls.sh                   # Sync ALL PRs (open, closed, merged)
#   STATE=closed ./sync-pulls.sh                # Sync only closed/merged PRs
#   DRY_RUN=true STATE=all ./sync-pulls.sh      # Preview without creating PRs
#   SKIP_BRANCH_CHECK=true STATE=all ./sync-pulls.sh  # Sync even if branches deleted
#
# NOTE: Closed/merged PRs will be created as OPEN, then automatically closed
# to match their original state (if PRESERVE_STATE=true, which is default)
#
# TIP: If closed PRs are being skipped due to missing branches, use SKIP_BRANCH_CHECK=true
#
# Environment Variables:
#   SOURCE_REPO              - Source repository (format: owner/repo)
#   TARGET_REPO              - Target repository (format: owner/repo)
#   SOURCE_HOST              - Source GitHub hostname
#   TARGET_HOST              - Target GitHub hostname 
#   STATE                    - PR state to sync: open, closed, merged, all (default: open)
#   DRY_RUN                  - Preview mode (true/false, default: false)
#   LIMIT                    - Max number of PRs to process (default: unlimited)
#   ASSIGN_ORIGINAL_AUTHOR   - Try to assign original author (true/false, default: true)
#   ADD_AUTHOR_COMMENT       - Add comment crediting author (true/false, default: true)
#   COPY_COMMENTS            - Copy all PR comments from source (true/false, default: true)
#   COPY_REVIEWS             - Copy PR reviews and review comments (true/false, default: true)
#   PRESERVE_STATE           - Close PRs that were closed/merged (true/false, default: true)
#   SKIP_BRANCH_CHECK        - Skip branch existence validation (true/false, default: false)
#   USERNAME_MAPPING_FILE    - Path to JSON file mapping source→target usernames (optional)
#
# NOTE: GitHub API doesn't allow setting PR author, so PRs will show the authenticated
# user as creator. However, the script prominently displays the original author in:
#   1. PR description header (highlighted)
#   2. PR assignee (if user exists on target)
#   3. First comment on the PR
#   4. Footer of PR description
# ============================================================================

# ---------------------------
# Configuration
# ---------------------------
SOURCE_REPO="${SOURCE_REPO}"
TARGET_REPO="${TARGET_REPO}"
SOURCE_HOST="${SOURCE_HOST}"
TARGET_HOST="${TARGET_HOST}"
STATE="${STATE:-open}"
DRY_RUN="${DRY_RUN:-false}"
LIMIT="${LIMIT:-9999999}"
ASSIGN_ORIGINAL_AUTHOR="${ASSIGN_ORIGINAL_AUTHOR:-true}"  # Try to assign original author
ADD_AUTHOR_COMMENT="${ADD_AUTHOR_COMMENT:-true}"  # Add comment crediting original author
COPY_COMMENTS="${COPY_COMMENTS:-true}"  # Copy all PR comments from source
COPY_REVIEWS="${COPY_REVIEWS:-true}"  # Copy PR reviews and review comments from source
PRESERVE_STATE="${PRESERVE_STATE:-true}"  # Close PRs that were originally closed/merged
SKIP_BRANCH_CHECK="${SKIP_BRANCH_CHECK:-false}"  # Skip branch existence check (useful if branches were deleted)
USERNAME_MAPPING_FILE="${USERNAME_MAPPING_FILE:-}"  # Optional JSON file mapping source→target usernames

# Stats
PRS_CREATED=0
PRS_SKIPPED=0
PRS_FAILED=0
REVIEWS_COPIED=0
REVIEW_COMMENTS_COPIED=0

# ---------------------------
# Loading Utils
# ---------------------------

source utils.sh

# ---------------------------
# Username mapping
# ---------------------------
# Global variable to store username mappings
declare -A USERNAME_MAP

# Load username mapping from JSON file
load_username_mapping() {
    if [ -n "$USERNAME_MAPPING_FILE" ] && [ -f "$USERNAME_MAPPING_FILE" ]; then
        log "Loading username mapping from: $USERNAME_MAPPING_FILE"

        # Parse JSON and populate associative array
        while IFS="=" read -r key value; do
            USERNAME_MAP["$key"]="$value"
            log "  [DEBUG] Loaded mapping: '$key' -> '$value'"
        done < <(jq -r 'to_entries | .[] | "\(.key)=\(.value)"' "$USERNAME_MAPPING_FILE" 2>/dev/null)

        local mapping_count="${#USERNAME_MAP[@]}"
        log "✓ Loaded $mapping_count username mapping(s)"

        # Show first few mappings as sample
        if [ $mapping_count -gt 0 ]; then
            log "Sample mappings:"
            local count=0
            for key in "${!USERNAME_MAP[@]}"; do
                log "  '$key' -> '${USERNAME_MAP[$key]}'"
                count=$((count + 1))
                [ $count -ge 3 ] && break
            done
        fi
    else
        if [ -n "$USERNAME_MAPPING_FILE" ]; then
            log_warn "Username mapping file not found: $USERNAME_MAPPING_FILE"
            log_warn "Proceeding without username mapping"
        fi
    fi
}

# Map username from source to target
# Usage: map_username "source-username"
# Returns: mapped username if found, otherwise original username
map_username() {
    local source_username="$1"
    local mapped_username="${USERNAME_MAP[$source_username]:-}"

    if [ -n "$mapped_username" ]; then
        echo "$mapped_username"
    else
        echo "$source_username"
    fi
}

# ---------------------------
# Pre-flight checks
# ---------------------------
log "Checking prerequisites..."

if ! command -v gh &> /dev/null; then
    log_error "gh CLI not found. Install from: https://cli.github.com/"
    exit 1
fi

# Test authentication for source
log "Testing authentication to source ($SOURCE_HOST)..."
if ! GH_HOST="$SOURCE_HOST" gh auth status &>/dev/null; then
    log_error "Not authenticated to $SOURCE_HOST"
    log_error "Run: GH_HOST=$SOURCE_HOST gh auth login"
    exit 1
fi

# Test authentication for target
log "Testing authentication to target ($TARGET_HOST)..."
if ! GH_HOST="$TARGET_HOST" gh auth status &>/dev/null; then
    log_error "Not authenticated to $TARGET_HOST"
    log_error "Run: GH_HOST=$TARGET_HOST gh auth login"
    exit 1
fi

log "✓ Prerequisites satisfied"

# Load username mapping if configured
load_username_mapping

# ---------------------------
# Display configuration
# ---------------------------
echo ""
log "=========================================="
log "        PULL REQUEST SYNC CONFIG"
log "=========================================="
log "Source: $SOURCE_REPO @ $SOURCE_HOST"
log "Target: $TARGET_REPO @ $TARGET_HOST"
log "State: $STATE"
log "Limit: $LIMIT PRs"
log "Dry run: $DRY_RUN"
log "Assign original author: $ASSIGN_ORIGINAL_AUTHOR"
log "Add author comment: $ADD_AUTHOR_COMMENT"
log "Copy comments: $COPY_COMMENTS"
log "Copy reviews: $COPY_REVIEWS"
log "Preserve state (close if closed): $PRESERVE_STATE"
log "Skip branch check: $SKIP_BRANCH_CHECK"
log "=========================================="
echo ""

if [ "$DRY_RUN" = true ]; then
    log "ℹ️  DRY RUN MODE - No PRs will be created"
fi

# ---------------------------
# Fetch PRs from source
# ---------------------------
log "Fetching pull requests from source..."

PR_DATA=$(GH_HOST="$SOURCE_HOST" gh pr list \
    --repo "$SOURCE_REPO" \
    --state "$STATE" \
    --limit "$LIMIT" \
    --json number,title,body,headRefName,baseRefName,state,author,labels,url \
    2>&1)

if [ $? -ne 0 ]; then
    log_error "Failed to fetch PRs from source:"
    echo "$PR_DATA" >&2
    exit 1
fi

PR_COUNT=$(echo "$PR_DATA" | jq 'length' 2>/dev/null || echo "0")

if [ "$PR_COUNT" -eq 0 ]; then
    log "No pull requests found with state: $STATE"
    exit 0
fi

log "Found $PR_COUNT pull request(s) to process"

# ---------------------------
# Process each PR
# ---------------------------
echo "$PR_DATA" | jq -c '.[]' | while read -r pr; do
    PR_NUMBER=$(echo "$pr" | jq -r '.number')
    PR_TITLE=$(echo "$pr" | jq -r '.title')
    PR_BODY=$(echo "$pr" | jq -r '.body // ""')
    PR_HEAD=$(echo "$pr" | jq -r '.headRefName')
    PR_BASE=$(echo "$pr" | jq -r '.baseRefName')
    PR_STATE=$(echo "$pr" | jq -r '.state')
    PR_AUTHOR=$(echo "$pr" | jq -r '.author.login')
    PR_URL=$(echo "$pr" | jq -r '.url')
    PR_LABELS=$(echo "$pr" | jq -r '.labels[].name' | tr '\n' ',' | sed 's/,$//')

    # Map username from source to target
    PR_AUTHOR_ORIGINAL="$PR_AUTHOR"
    PR_AUTHOR_MAPPED=$(map_username "$PR_AUTHOR")

    log ""
    log "──────────────────────────────────────"
    log "Processing PR #$PR_NUMBER: $PR_TITLE"
    log "  Author: $PR_AUTHOR_ORIGINAL"
    if [ "$PR_AUTHOR_ORIGINAL" != "$PR_AUTHOR_MAPPED" ]; then
        log "  Mapped to: $PR_AUTHOR_MAPPED"
    fi
    log "  Branches: $PR_HEAD → $PR_BASE"
    log "  State: $PR_STATE"

    # Check if branches exist on target using git ls-remote (more reliable)
    if [ "$SKIP_BRANCH_CHECK" = true ]; then
        log "  ⏭️  Skipping branch existence check (SKIP_BRANCH_CHECK=true)"
    else
        log "  Checking if branches exist on target..."

        # Construct git URL for target
        TARGET_GIT_URL="git@${TARGET_HOST}:${TARGET_REPO}.git"

        # Check head branch
        if git ls-remote --heads "$TARGET_GIT_URL" "refs/heads/$PR_HEAD" 2>/dev/null | grep -q "refs/heads/$PR_HEAD"; then
            HEAD_EXISTS="true"
        else
            HEAD_EXISTS="false"
        fi

        # Check base branch
        if git ls-remote --heads "$TARGET_GIT_URL" "refs/heads/$PR_BASE" 2>/dev/null | grep -q "refs/heads/$PR_BASE"; then
            BASE_EXISTS="true"
        else
            BASE_EXISTS="false"
        fi

        if [ "$HEAD_EXISTS" != "true" ]; then
            log_warn "  ⊘ Head branch '$PR_HEAD' does not exist on target - skipping"
            log_warn "     (Use SKIP_BRANCH_CHECK=true to create PR anyway)"
            PRS_SKIPPED=$((PRS_SKIPPED + 1))
            continue
        fi

        if [ "$BASE_EXISTS" != "true" ]; then
            log_warn "  ⊘ Base branch '$PR_BASE' does not exist on target - skipping"
            log_warn "     (Use SKIP_BRANCH_CHECK=true to create PR anyway)"
            PRS_SKIPPED=$((PRS_SKIPPED + 1))
            continue
        fi

        log "  ✓ Both branches exist on target"
    fi

    # Check if PR already exists
    log "  Checking if PR already exists on target..."
    log "  [DEBUG] Starting gh pr list command in background..."

    # Run gh command in background with manual timeout (30 seconds)
    (
        GH_HOST="$TARGET_HOST" gh pr list \
            --repo "$TARGET_REPO" \
            --head "$PR_HEAD" \
            --base "$PR_BASE" \
            --state all \
            --json number \
            --jq '.[0].number' 2>&1
    ) > /tmp/gh_pr_check_$$.txt &

    GH_PID=$!
    TIMEOUT=30
    ELAPSED=0

    log "  [DEBUG] Waiting for command (PID: $GH_PID, timeout: ${TIMEOUT}s)..."

    # Wait for command with timeout
    while kill -0 $GH_PID 2>/dev/null && [ $ELAPSED -lt $TIMEOUT ]; do
        sleep 1
        ELAPSED=$((ELAPSED + 1))
        # Log every 10 seconds
        if [ $((ELAPSED % 10)) -eq 0 ]; then
            log "  [DEBUG] Still waiting... (${ELAPSED}s elapsed)"
        fi
    done

    log "  [DEBUG] Wait loop finished. Elapsed: ${ELAPSED}s"

    # Check if process is still running (timed out)
    if kill -0 $GH_PID 2>/dev/null; then
        log_error "  Timeout checking for existing PR (${TIMEOUT}s limit exceeded)"
        log_error "  This may indicate network issues or problems with the target repository"
        kill -9 $GH_PID 2>/dev/null
        wait $GH_PID 2>/dev/null
        rm -f /tmp/gh_pr_check_$$.txt
        PRS_FAILED=$((PRS_FAILED + 1))
        continue
    fi

    log "  [DEBUG] Getting command result..."

    # Get the result
    wait $GH_PID 2>/dev/null
    EXISTING_PR_EXIT_CODE=$?
    EXISTING_PR_OUTPUT=$(cat /tmp/gh_pr_check_$$.txt 2>/dev/null || echo "")
    rm -f /tmp/gh_pr_check_$$.txt

    log "  [DEBUG] Exit code: $EXISTING_PR_EXIT_CODE, Output: '$EXISTING_PR_OUTPUT'"

    # Check if command had errors
    if [ $EXISTING_PR_EXIT_CODE -ne 0 ] && [ -n "$EXISTING_PR_OUTPUT" ]; then
        log_warn "  Error checking for existing PR: $EXISTING_PR_OUTPUT"
        log_warn "  Proceeding anyway..."
        EXISTING_PR=""
    else
        EXISTING_PR=$(echo "$EXISTING_PR_OUTPUT" | grep -E '^[0-9]+$' || echo "")
    fi

    log "  [DEBUG] Existing PR check result: '$EXISTING_PR'"

    # Check if PR already exists - if so, we'll skip creation but still process comments/reviews
    PR_ALREADY_EXISTS=false
    if [ -n "$EXISTING_PR" ] && [ "$EXISTING_PR" != "null" ]; then
        log "  ℹ️  PR already exists on target (#$EXISTING_PR) - will sync comments/reviews only"
        NEW_PR_NUMBER="$EXISTING_PR"
        PR_ALREADY_EXISTS=true
        PRS_SKIPPED=$((PRS_SKIPPED + 1))
    else
        log "  [DEBUG] No existing PR found, proceeding to create..."
    fi

    # Only create PR if it doesn't already exist
    if [ "$PR_ALREADY_EXISTS" = false ]; then
        log "  [DEBUG] Building PR body..."

        # Create PR body with original metadata (make author very prominent)
        # Add state badge if PR was closed/merged
        STATE_BADGE=""
        if [ "$PR_STATE" = "CLOSED" ]; then
            STATE_BADGE="🔴 **Status:** CLOSED"
        elif [ "$PR_STATE" = "MERGED" ]; then
            STATE_BADGE="🟣 **Status:** MERGED"
        fi

        log "  [DEBUG] State badge: '$STATE_BADGE'"
        log "  [DEBUG] Original PR body length: ${#PR_BODY} characters"

        # Build NEW_BODY safely without shell interpretation of PR_BODY content
        # Use printf to avoid issues with backticks and command substitutions in PR_BODY
        NEW_BODY=$(cat <<EOF
## 🔄 Migrated Pull Request

> **Original Author:** @${PR_AUTHOR_MAPPED}
> **Original PR:** ${PR_URL} (#${PR_NUMBER})
> **Source:** ${SOURCE_HOST}
$([ -n "$STATE_BADGE" ] && echo "> $STATE_BADGE")

---

${PR_BODY}

---

<sub>This PR was automatically migrated from ${SOURCE_HOST}. Original author: @${PR_AUTHOR_MAPPED}</sub>
EOF
)

        log "  [DEBUG] PR body built successfully (${#NEW_BODY} characters)"
    fi

    if [ "$DRY_RUN" = true ] && [ "$PR_ALREADY_EXISTS" = false ]; then
        log "  [DRY RUN] Would create PR:"
        log "    Title: $PR_TITLE"
        log "    Head: $PR_HEAD"
        log "    Base: $PR_BASE"
        log "    Original State: $PR_STATE"
        [ -n "$PR_LABELS" ] && log "    Labels: $PR_LABELS"
        if [ "$PRESERVE_STATE" = true ] && [ "$PR_STATE" != "OPEN" ]; then
            log "    Action: Would create as OPEN, then close to match original state"
        fi
        PRS_CREATED=$((PRS_CREATED + 1))
    elif [ "$PR_ALREADY_EXISTS" = false ]; then
        log "  Creating PR on target..."
        log "  [DEBUG] Preparing to call gh pr create..."
        log "  [DEBUG] Title: $PR_TITLE"
        log "  [DEBUG] Head: $PR_HEAD -> Base: $PR_BASE"

        # Create PR with timeout
        log "  [DEBUG] Executing gh pr create in background..."
        (
            GH_HOST="$TARGET_HOST" gh pr create \
                --repo "$TARGET_REPO" \
                --title "$PR_TITLE" \
                --body "$NEW_BODY" \
                --head "$PR_HEAD" \
                --base "$PR_BASE" 2>&1
        ) > /tmp/gh_pr_create_$$.txt &

        CREATE_PID=$!
        CREATE_TIMEOUT=60
        CREATE_ELAPSED=0

        log "  [DEBUG] Waiting for PR creation (PID: $CREATE_PID, timeout: ${CREATE_TIMEOUT}s)..."

        # Wait for command with timeout
        while kill -0 $CREATE_PID 2>/dev/null && [ $CREATE_ELAPSED -lt $CREATE_TIMEOUT ]; do
            sleep 1
            CREATE_ELAPSED=$((CREATE_ELAPSED + 1))
            if [ $((CREATE_ELAPSED % 10)) -eq 0 ]; then
                log "  [DEBUG] Still creating PR... (${CREATE_ELAPSED}s elapsed)"
            fi
        done

        log "  [DEBUG] Create wait loop finished. Elapsed: ${CREATE_ELAPSED}s"

        # Check if process is still running (timed out)
        if kill -0 $CREATE_PID 2>/dev/null; then
            log_error "  Timeout creating PR (${CREATE_TIMEOUT}s limit exceeded)"
            kill -9 $CREATE_PID 2>/dev/null
            wait $CREATE_PID 2>/dev/null
            rm -f /tmp/gh_pr_create_$$.txt
            PRS_FAILED=$((PRS_FAILED + 1))
            continue
        fi

        # Get the result
        wait $CREATE_PID 2>/dev/null
        CREATE_EXIT_CODE=$?
        NEW_PR_URL=$(cat /tmp/gh_pr_create_$$.txt 2>/dev/null || echo "")
        rm -f /tmp/gh_pr_create_$$.txt

        log "  [DEBUG] Create exit code: $CREATE_EXIT_CODE"
        log "  [DEBUG] Create output: $NEW_PR_URL"

        if [ $CREATE_EXIT_CODE -eq 0 ] && [ -n "$NEW_PR_URL" ]; then
            log "  ✓ Created: $NEW_PR_URL"
            NEW_PR_NUMBER=$(echo "$NEW_PR_URL" | grep -oE '[0-9]+$')

            # Try to assign original author if they exist on target
            if [ "$ASSIGN_ORIGINAL_AUTHOR" = true ]; then
                log "  Attempting to assign original author: @$PR_AUTHOR_MAPPED"
                if GH_HOST="$TARGET_HOST" gh pr edit "$NEW_PR_NUMBER" \
                    --repo "$TARGET_REPO" \
                    --add-assignee "$PR_AUTHOR_MAPPED" 2>/dev/null; then
                    log "  ✓ Assigned to @$PR_AUTHOR_MAPPED"
                else
                    log_warn "  Could not assign @$PR_AUTHOR_MAPPED (user may not exist on target)"
                fi
            fi

            # Add comment crediting original author
            if [ "$ADD_AUTHOR_COMMENT" = true ]; then
                CREDIT_COMMENT="👋 **Original Author:** @$PR_AUTHOR_MAPPED

This pull request was migrated from [$SOURCE_HOST/$SOURCE_REPO#$PR_NUMBER]($PR_URL).

Please direct any questions about the original implementation to @$PR_AUTHOR_MAPPED."

                if GH_HOST="$TARGET_HOST" gh pr comment "$NEW_PR_NUMBER" \
                    --repo "$TARGET_REPO" \
                    --body "$CREDIT_COMMENT" 2>/dev/null; then
                    log "  ✓ Added author credit comment"
                else
                    log_warn "  Could not add credit comment"
                fi
            fi

            # Add labels if any exist
            if [ -n "$PR_LABELS" ]; then
                log "  Adding labels: $PR_LABELS"

                # Try to add labels and capture error
                LABEL_ERROR=$(GH_HOST="$TARGET_HOST" gh pr edit "$NEW_PR_NUMBER" \
                    --repo "$TARGET_REPO" \
                    --add-label "$PR_LABELS" 2>&1)

                if [ $? -ne 0 ]; then
                    log_warn "  Failed to add labels: $LABEL_ERROR"
                else
                    log "  ✓ Labels added successfully"
                fi
            fi

            PRS_CREATED=$((PRS_CREATED + 1))
        else
            log_error "  ✗ Failed to create PR (exit code: $CREATE_EXIT_CODE)"
            log_error "  Error output: $NEW_PR_URL"
            PRS_FAILED=$((PRS_FAILED + 1))
        fi
    fi

    # Copy comments and reviews (runs for both new and existing PRs)
    if [ -n "$NEW_PR_NUMBER" ]; then
        # Copy comments from source PR
        if [ "$COPY_COMMENTS" = true ]; then
            log "  Fetching comments from source PR..."

            # Fetch comments using gh api (includes author, body, created date)
            COMMENTS_JSON=$(GH_HOST="$SOURCE_HOST" gh api \
                "/repos/$SOURCE_REPO/issues/$PR_NUMBER/comments" \
                --jq '.[] | {author: .user.login, body: .body, created_at: .created_at}' \
                2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")

            COMMENT_COUNT=$(echo "$COMMENTS_JSON" | jq 'length' 2>/dev/null || echo "0")

            if [ "$COMMENT_COUNT" -gt 0 ]; then
                log "  Found $COMMENT_COUNT comment(s) to copy"

                echo "$COMMENTS_JSON" | jq -c '.[]' | while read -r comment; do
                    COMMENT_AUTHOR=$(echo "$comment" | jq -r '.author')
                    COMMENT_AUTHOR_MAPPED=$(map_username "$COMMENT_AUTHOR")
                    COMMENT_BODY=$(echo "$comment" | jq -r '.body')
                    COMMENT_DATE=$(echo "$comment" | jq -r '.created_at')

                    # Format the migrated comment with attribution
                    MIGRATED_COMMENT="**@$COMMENT_AUTHOR_MAPPED** commented on $COMMENT_DATE:

---

$COMMENT_BODY

---

<sub>Migrated from original PR comment</sub>"

                    # Create comment on target PR
                    if GH_HOST="$TARGET_HOST" gh pr comment "$NEW_PR_NUMBER" \
                        --repo "$TARGET_REPO" \
                        --body "$MIGRATED_COMMENT" 2>/dev/null; then
                        log "  ✓ Copied comment from @$COMMENT_AUTHOR_MAPPED"
                    else
                        log_warn "  Failed to copy comment from @$COMMENT_AUTHOR_MAPPED"
                    fi
                done

                log "  ✓ Finished copying comments"
            else
                log "  No comments to copy"
            fi
        fi

        # Copy reviews and review comments from source PR
        if [ "$COPY_REVIEWS" = true ]; then
            log "  Fetching reviews from source PR..."

            # Fetch reviews using gh api
            REVIEWS_JSON=$(GH_HOST="$SOURCE_HOST" gh api \
                "/repos/$SOURCE_REPO/pulls/$PR_NUMBER/reviews" \
                --jq '.[] | {id: .id, author: .user.login, body: .body, state: .state, html_url: .html_url, submitted_at: .submitted_at}' \
                2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")

            REVIEW_COUNT=$(echo "$REVIEWS_JSON" | jq 'length' 2>/dev/null || echo "0")

            if [ "$REVIEW_COUNT" -gt 0 ]; then
                log "  Found $REVIEW_COUNT review(s) to copy"

                # Process each review
                echo "$REVIEWS_JSON" | jq -c '.[]' | while read -r review; do
                    REVIEW_AUTHOR=$(echo "$review" | jq -r '.author')
                    REVIEW_AUTHOR_MAPPED=$(map_username "$REVIEW_AUTHOR")

                    log "  [DEBUG] Review author: '$REVIEW_AUTHOR' -> '$REVIEW_AUTHOR_MAPPED'"
                    if [ "$REVIEW_AUTHOR" != "$REVIEW_AUTHOR_MAPPED" ]; then
                        log "  [DEBUG] Username was mapped!"
                    else
                        log "  [DEBUG] Username was NOT mapped (not found in mapping file or no mapping file)"
                    fi

                    REVIEW_BODY=$(echo "$review" | jq -r '.body // ""')
                    REVIEW_STATE=$(echo "$review" | jq -r '.state')
                    REVIEW_URL=$(echo "$review" | jq -r '.html_url')
                    REVIEW_DATE=$(echo "$review" | jq -r '.submitted_at')

                    # Map GitHub review states to event types
                    # Note: Convert all to COMMENT to avoid "can't approve own PR" errors
                    # The original state is preserved in the review body for reference
                    GH_EVENT="COMMENT"
                    STATE_EMOJI=""
                    case "$REVIEW_STATE" in
                        APPROVED)
                            STATE_EMOJI="✅"
                            ;;
                        CHANGES_REQUESTED)
                            STATE_EMOJI="🔴"
                            ;;
                        COMMENTED|DISMISSED|PENDING)
                            STATE_EMOJI="💬"
                            ;;
                        *)
                            STATE_EMOJI="💬"
                            ;;
                    esac

                    # Build review body with attribution
                    log "  [DEBUG] Building review body for @$REVIEW_AUTHOR_MAPPED..."
                    log "  [DEBUG] Review body length: ${#REVIEW_BODY} characters"
                    log "  [DEBUG] Review state: $REVIEW_STATE, Event: $GH_EVENT"

                    # Use heredoc to safely build review body
                    REVIEW_BODY_WITH_ATTR=$(cat <<EOF
**Original Review:** [\`@${REVIEW_AUTHOR_MAPPED}\`](${REVIEW_URL}) ${STATE_EMOJI} **${REVIEW_STATE}** on ${REVIEW_DATE}

---

${REVIEW_BODY}

---

<sub>This review was migrated from the source repository</sub>
EOF
)

                    log "  [DEBUG] Review body built successfully (${#REVIEW_BODY_WITH_ATTR} characters)"

                    # Create review on target PR with timeout
                    log "  Creating $REVIEW_STATE review from @$REVIEW_AUTHOR_MAPPED..."
                    log "  [DEBUG] Starting review creation API call..."

                    # Run gh api in background with timeout
                    (
                        GH_HOST="$TARGET_HOST" gh api \
                            "/repos/$TARGET_REPO/pulls/$NEW_PR_NUMBER/reviews" \
                            -X POST \
                            -f body="$REVIEW_BODY_WITH_ATTR" \
                            -f event="$GH_EVENT" 2>&1
                    ) > /tmp/gh_review_$$.txt &

                    REVIEW_PID=$!
                    REVIEW_TIMEOUT=30
                    REVIEW_ELAPSED=0

                    log "  [DEBUG] Review API call launched (PID: $REVIEW_PID, timeout: ${REVIEW_TIMEOUT}s)"

                    # Wait for command with timeout
                    while kill -0 $REVIEW_PID 2>/dev/null && [ $REVIEW_ELAPSED -lt $REVIEW_TIMEOUT ]; do
                        sleep 1
                        REVIEW_ELAPSED=$((REVIEW_ELAPSED + 1))
                        if [ $((REVIEW_ELAPSED % 10)) -eq 0 ]; then
                            log "  [DEBUG] Still creating review... (${REVIEW_ELAPSED}s elapsed)"
                        fi
                    done

                    log "  [DEBUG] Review wait loop finished. Elapsed: ${REVIEW_ELAPSED}s"

                    # Check if process is still running (timed out)
                    if kill -0 $REVIEW_PID 2>/dev/null; then
                        log_warn "  Timeout creating review from @$REVIEW_AUTHOR_MAPPED (${REVIEW_TIMEOUT}s limit exceeded)"
                        kill -9 $REVIEW_PID 2>/dev/null
                        wait $REVIEW_PID 2>/dev/null
                        rm -f /tmp/gh_review_$$.txt
                    else
                        # Get the result
                        wait $REVIEW_PID 2>/dev/null
                        REVIEW_EXIT_CODE=$?
                        REVIEW_RESULT=$(cat /tmp/gh_review_$$.txt 2>/dev/null || echo "")
                        rm -f /tmp/gh_review_$$.txt

                        log "  [DEBUG] Review exit code: $REVIEW_EXIT_CODE"
                        log "  [DEBUG] Review result: ${REVIEW_RESULT:0:200}"  # First 200 chars

                        if [ $REVIEW_EXIT_CODE -eq 0 ]; then
                            log "  ✓ Copied $REVIEW_STATE review from @$REVIEW_AUTHOR_MAPPED"
                            REVIEWS_COPIED=$((REVIEWS_COPIED + 1))
                        else
                            log_warn "  Failed to copy review from @$REVIEW_AUTHOR_MAPPED: $REVIEW_RESULT"
                        fi
                    fi
                done

                log "  ✓ Finished copying reviews"
            else
                log "  No reviews to copy"
            fi

            # Fetch and copy review comments (inline code comments)
            log "  Fetching review comments from source PR..."

            REVIEW_COMMENTS_JSON=$(GH_HOST="$SOURCE_HOST" gh api \
                "/repos/$SOURCE_REPO/pulls/$PR_NUMBER/comments" \
                --jq '.[] | {author: .user.login, body: .body, path: .path, commit_id: .commit_id, line: .line, side: .side, html_url: .html_url, created_at: .created_at}' \
                2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")

            REVIEW_COMMENT_COUNT=$(echo "$REVIEW_COMMENTS_JSON" | jq 'length' 2>/dev/null || echo "0")

            if [ "$REVIEW_COMMENT_COUNT" -gt 0 ]; then
                log "  Found $REVIEW_COMMENT_COUNT review comment(s) to copy"

                # Process each review comment
                echo "$REVIEW_COMMENTS_JSON" | jq -c '.[]' | while read -r comment; do
                    RC_AUTHOR=$(echo "$comment" | jq -r '.author')
                    RC_AUTHOR_MAPPED=$(map_username "$RC_AUTHOR")
                    RC_BODY=$(echo "$comment" | jq -r '.body')
                    RC_PATH=$(echo "$comment" | jq -r '.path')
                    RC_COMMIT=$(echo "$comment" | jq -r '.commit_id')
                    RC_LINE=$(echo "$comment" | jq -r '.line // empty')
                    RC_SIDE=$(echo "$comment" | jq -r '.side // "RIGHT"')
                    RC_URL=$(echo "$comment" | jq -r '.html_url')
                    RC_DATE=$(echo "$comment" | jq -r '.created_at')

                    # Skip if line is null/empty (can't create inline comment without line)
                    if [ -z "$RC_LINE" ] || [ "$RC_LINE" = "null" ]; then
                        log_warn "  No line number for comment from @$RC_AUTHOR_MAPPED on $RC_PATH - posting as regular comment"

                        FALLBACK_COMMENT="**[\`@$RC_AUTHOR_MAPPED\`]($RC_URL) commented on \`$RC_PATH\`** (commit: \`${RC_COMMIT:0:7}\`) on $RC_DATE

---

$RC_BODY

---

<sub>Migrated from original PR review comment (no line number available)</sub>"

                        if GH_HOST="$TARGET_HOST" gh pr comment "$NEW_PR_NUMBER" \
                            --repo "$TARGET_REPO" \
                            --body "$FALLBACK_COMMENT" 2>/dev/null; then
                            log "  ✓ Copied as regular comment from @$RC_AUTHOR_MAPPED"
                            REVIEW_COMMENTS_COPIED=$((REVIEW_COMMENTS_COPIED + 1))
                        else
                            log_warn "  Failed to copy review comment from @$RC_AUTHOR_MAPPED"
                        fi
                        continue
                    fi

                    # Build comment body with attribution
                    RC_BODY_WITH_ATTR="**[\`@$RC_AUTHOR_MAPPED\`]($RC_URL) commented on \`$RC_PATH:$RC_LINE\`** on $RC_DATE

---

$RC_BODY

---

<sub>Migrated from original PR review comment</sub>"

                    # Create inline review comment with proper API call
                    log "  Creating inline comment from @$RC_AUTHOR_MAPPED on $RC_PATH:$RC_LINE..."

                    # Run gh api in background with timeout
                    # Note: Use -F for line (number type), not -f (string type)
                    (
                        GH_HOST="$TARGET_HOST" gh api \
                            --method POST \
                            -H "Accept: application/vnd.github+json" \
                            "/repos/$TARGET_REPO/pulls/$NEW_PR_NUMBER/comments" \
                            -f body="$RC_BODY_WITH_ATTR" \
                            -f commit_id="$RC_COMMIT" \
                            -f path="$RC_PATH" \
                            -F line="$RC_LINE" \
                            -f side="$RC_SIDE" 2>&1
                    ) > /tmp/gh_review_comment_$$.txt &

                    RC_PID=$!
                    RC_TIMEOUT=30
                    RC_ELAPSED=0

                    # Wait for command with timeout
                    while kill -0 $RC_PID 2>/dev/null && [ $RC_ELAPSED -lt $RC_TIMEOUT ]; do
                        sleep 1
                        RC_ELAPSED=$((RC_ELAPSED + 1))
                    done

                    # Check if process is still running (timed out)
                    if kill -0 $RC_PID 2>/dev/null; then
                        log_warn "  Timeout creating inline comment from @$RC_AUTHOR_MAPPED (${RC_TIMEOUT}s)"
                        kill -9 $RC_PID 2>/dev/null
                        wait $RC_PID 2>/dev/null
                        rm -f /tmp/gh_review_comment_$$.txt
                        RC_EXIT_CODE=1
                        RC_RESULT="timeout"
                    else
                        # Get the result
                        wait $RC_PID 2>/dev/null
                        RC_EXIT_CODE=$?
                        RC_RESULT=$(cat /tmp/gh_review_comment_$$.txt 2>/dev/null || echo "")
                        rm -f /tmp/gh_review_comment_$$.txt
                    fi

                    if [ $RC_EXIT_CODE -eq 0 ]; then
                        log "  ✓ Copied inline comment from @$RC_AUTHOR_MAPPED"
                        REVIEW_COMMENTS_COPIED=$((REVIEW_COMMENTS_COPIED + 1))
                    else
                        # Fall back to regular comment if inline comment fails
                        log_warn "  Inline comment failed, falling back to regular comment..."

                        FALLBACK_COMMENT="**[\`@$RC_AUTHOR_MAPPED\`]($RC_URL) commented on \`$RC_PATH:$RC_LINE\`** (commit: \`${RC_COMMIT:0:7}\`) on $RC_DATE

---

$RC_BODY

---

<sub>Migrated from original PR review comment (inline comment creation failed, posted as regular comment)</sub>"

                        if GH_HOST="$TARGET_HOST" gh pr comment "$NEW_PR_NUMBER" \
                            --repo "$TARGET_REPO" \
                            --body "$FALLBACK_COMMENT" 2>/dev/null; then
                            log "  ✓ Copied as regular comment from @$RC_AUTHOR_MAPPED"
                            REVIEW_COMMENTS_COPIED=$((REVIEW_COMMENTS_COPIED + 1))
                        else
                            log_warn "  Failed to copy review comment from @$RC_AUTHOR_MAPPED"
                        fi
                    fi
                done

                log "  ✓ Finished copying review comments"
            else
                log "  No review comments to copy"
            fi
        fi

    fi

    # Close PR if original was closed or merged (only for newly created PRs)
    if [ "$PR_ALREADY_EXISTS" = false ] && [ -n "$NEW_PR_NUMBER" ] && [ "$PRESERVE_STATE" = true ] && [ "$PR_STATE" != "OPEN" ]; then
        log "  Original PR was $PR_STATE, closing migrated PR..."

        # Add closing comment explaining why it's closed
        CLOSE_REASON=""
        if [ "$PR_STATE" = "MERGED" ]; then
            CLOSE_REASON="This PR is closed because the original PR was **merged** in the source repository.

The merge commit exists in the branch history. This PR is preserved for historical/reference purposes."
        else
            CLOSE_REASON="This PR is closed because the original PR was **closed without merging** in the source repository.

This PR is preserved for historical/reference purposes."
        fi

        if GH_HOST="$TARGET_HOST" gh pr comment "$NEW_PR_NUMBER" \
            --repo "$TARGET_REPO" \
            --body "$CLOSE_REASON" 2>/dev/null; then
            log "  ✓ Added closure explanation comment"
        fi

        # Close the PR
        if GH_HOST="$TARGET_HOST" gh pr close "$NEW_PR_NUMBER" \
            --repo "$TARGET_REPO" 2>/dev/null; then
            log "  ✓ Closed PR to match original state ($PR_STATE)"
        else
            log_warn "  Could not close PR"
        fi
    fi
done

# ---------------------------
# Summary
# ---------------------------
echo ""
log "=========================================="
log "           SYNC SUMMARY"
log "=========================================="
log "PRs created: $PRS_CREATED"
log "PRs skipped: $PRS_SKIPPED"
log "PRs failed: $PRS_FAILED"
log "Reviews copied: $REVIEWS_COPIED"
log "Review comments copied: $REVIEW_COMMENTS_COPIED"
log "=========================================="

if [ "$DRY_RUN" = true ]; then
    log "DRY RUN complete - no PRs were created"
else
    log "✅ Pull request sync complete!"
fi

[ "$PRS_FAILED" -eq 0 ] || exit 1
