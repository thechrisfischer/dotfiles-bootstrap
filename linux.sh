#!/bin/bash
# Public bootstrap entry for a private dotfiles repo.
#
# Host this file in a public repo (thechrisfischer/dotfiles-bootstrap) so curl
# works without a PAT. Installs gh from public GitHub releases, runs
# gh auth login (browser username/password/SSO), then pipes bootstrap-linux.sh
# from the private repo via authenticated gh api.
#
# One-liner (after publishing to dotfiles-bootstrap):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/thechrisfischer/dotfiles-bootstrap/main/linux.sh)"

set -euo pipefail

DOTFILES_GITHUB="${DOTFILES_GITHUB:-thechrisfischer/dotfiles}"

_ensure_path_local_bin() {
    case ":${PATH}:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac
}

_install_gh_from_github_release() {
    local arch asset tag ver tmp extracted bindir url
    case "$(uname -m)" in
        arm64|aarch64) arch=arm64 ;;
        x86_64|amd64) arch=amd64 ;;
        *) echo "Unsupported architecture for gh release: $(uname -m)" >&2; return 1 ;;
    esac

    tag=$(curl -fsSL "https://api.github.com/repos/cli/cli/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1) || return 1
    [[ -n "$tag" ]] || return 1
    ver="${tag#v}"
    asset="gh_${ver}_linux_${arch}.tar.gz"
    url="https://github.com/cli/cli/releases/download/${tag}/${asset}"

    tmp=$(mktemp -d) || return 1
    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 \
            "$url" -o "$tmp/gh.tar.gz" \
        || ! tar -xzf "$tmp/gh.tar.gz" -C "$tmp"; then
        rm -rf "$tmp"
        return 1
    fi
    extracted=$(find "$tmp" -type f -path '*/bin/gh' | head -1)
    [[ -n "$extracted" ]] || { rm -rf "$tmp"; return 1; }
    bindir="$HOME/.local/bin"
    mkdir -p "$bindir" || { rm -rf "$tmp"; return 1; }
    install -m 0755 "$extracted" "$bindir/gh"
    rm -rf "$tmp"
    _ensure_path_local_bin
    hash -r 2>/dev/null || true
    gh --version &>/dev/null
}

_ensure_gh() {
    _ensure_path_local_bin
    if command -v gh &>/dev/null && gh --version &>/dev/null; then
        return 0
    fi
    echo "→ Installing gh from GitHub release..."
    _install_gh_from_github_release
}

_ensure_github_auth() {
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        printf '%s\n' "$GITHUB_TOKEN" | gh auth login -h github.com --with-token
        unset GITHUB_TOKEN
        gh auth setup-git
        echo "✅ GitHub authenticated via GITHUB_TOKEN"
        return 0
    fi

    if gh auth status &>/dev/null 2>&1; then
        echo "✅ GitHub already authenticated"
        return 0
    fi

    echo "→ GitHub login (browser — username/password or SSO; no PAT required)"
    gh auth login -h github.com -p https -w
    gh auth setup-git
    echo "✅ GitHub authenticated"
}

_main() {
    [[ "$(uname -s)" == "Linux" ]] || {
        echo "This entry script is for Linux only." >&2
        exit 1
    }
    command -v curl &>/dev/null || {
        echo "curl is required." >&2
        exit 1
    }

    echo "=== dotfiles Linux bootstrap (public entry) ==="
    _ensure_gh
    _ensure_github_auth

    echo "→ Fetching bootstrap from ${DOTFILES_GITHUB} (uses gh keyring — no PAT)"
    exec bash -c "$(gh api -H "Accept: application/vnd.github.raw" \
        "repos/${DOTFILES_GITHUB}/contents/scripts/bootstrap-linux.sh")"
}

_main "$@"
