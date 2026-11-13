#!/usr/bin/env bash

release_api_get_retry() {
    local endpoint="$1"
    shift
    local attempt=1 response delay

    while (( attempt <= 5 )); do
        if response="$(gh api "$endpoint" "$@" 2>&1)"; then
            printf '%s\n' "$response"
            return 0
        fi
        if [[ "$response" != *"(HTTP 404)"* ]]; then
            printf '%s\n' "$response" >&2
            return 1
        fi
        if (( attempt == 5 )); then
            printf 'GitHub API still returned 404 after %d attempts: %s\n' "$attempt" "$endpoint" >&2
            printf '%s\n' "$response" >&2
            return 44
        fi

        delay=$((1 << (attempt - 1)))
        printf 'GitHub API returned 404 on attempt %d/5; retrying in %ds: %s\n' \
            "$attempt" "$delay" "$endpoint" >&2
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

release_verify_tag() {
    local repository="$1"
    local tag="$2"
    local expected_sha="$3"
    local tag_sha

    if ! tag_sha="$(release_api_get_retry "repos/${repository}/commits/${tag}" --jq .sha)"; then
        return 1
    fi
    if [[ "$tag_sha" != "$expected_sha" ]]; then
        printf 'Tag %s points to %s, expected %s\n' "$tag" "$tag_sha" "$expected_sha" >&2
        return 1
    fi
}

release_ensure_tag() {
    local repository="$1"
    local tag="$2"
    local release_sha="$3"
    local tag_exists="$4"
    local response

    case "$tag_exists" in
        true)
            ;;
        false)
            if ! response="$(gh api --method POST "repos/${repository}/git/refs" \
                -f "ref=refs/tags/${tag}" -f "sha=${release_sha}" 2>&1)"; then
                if release_verify_tag "$repository" "$tag" "$release_sha"; then
                    return 0
                fi
                printf 'Creating tag %s failed: %s\n' "$tag" "$response" >&2
                return 1
            fi
            ;;
        *)
            printf 'Invalid release tag-exists state: %s\n' "$tag_exists" >&2
            return 1
            ;;
    esac

    release_verify_tag "$repository" "$tag" "$release_sha"
}
