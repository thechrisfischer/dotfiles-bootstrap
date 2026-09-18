#!/bin/bash
# Public bootstrap entry for a private dotfiles repo (macOS).
#
# Host in thechrisfischer/dotfiles-bootstrap (public). Installs gh from Homebrew
# or a public GitHub release, gh auth login (device code over SSH), then pipes
# bootstrap-macos.sh from the private repo via authenticated gh api.
#
# One-liner:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/thechrisfischer/dotfiles-bootstrap/main/macos.sh)"

set -euo pipefail

DOTFILES_GITHUB="${DOTFILES_GITHUB:-thechrisfischer/dotfiles}"

_is_apple_silicon() {
    [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]] \
        || [[ "$(uname -m)" == "arm64" ]]
}

_maybe_reexec_arm64() {
    [[ "$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null || true)" == 1 ]] || return 0
    [[ "${DOTFILES_BOOTSTRAP_ARM64_REEXEC:-0}" != 1 ]] || return 0
    export DOTFILES_BOOTSTRAP_ARM64_REEXEC=1
    echo "→ Restarting bootstrap natively on Apple Silicon..."
    if [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
        exec /usr/bin/arch -arm64 /bin/bash -c "$BASH_EXECUTION_STRING"
    fi
    exec /usr/bin/arch -arm64 /bin/bash "$0" "$@"
}

_ensure_path_local_bin() {
    case ":${PATH}:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac
}

_install_gh_from_github_release() {
    local arch asset tag ver tmp extracted bindir url
    case "$(uname -m)" in
        arm64) arch=arm64 ;;
        x86_64) arch=amd64 ;;
        *) echo "Unsupported architecture for gh release: $(uname -m)" >&2; return 1 ;;
    esac

    command -v unzip &>/dev/null || {
        echo "unzip is required to install gh from release (install Xcode CLT or Homebrew gh)." >&2
        return 1
    }

    tag=$(curl -fsSL "https://api.github.com/repos/cli/cli/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1) || return 1
    [[ -n "$tag" ]] || return 1
    ver="${tag#v}"
    asset="gh_${ver}_macOS_${arch}.zip"
    url="https://github.com/cli/cli/releases/download/${tag}/${asset}"

    tmp=$(mktemp -d) || return 1
    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 \
            "$url" -o "$tmp/gh.zip" \
        || ! unzip -q "$tmp/gh.zip" -d "$tmp"; then
        rm -rf "$tmp"
        return 1
    fi
    extracted=$(find "$tmp" -type f -path '*/bin/gh' | head -1)
    [[ -n "$extracted" ]] || { rm -rf "$tmp"; return 1; }
    bindir="$HOME/.local/bin"
    mkdir -p "$bindir" || { rm -rf "$tmp"; return 1; }
    install -m 0755 "$extracted" "$bindir/gh"
    rm -rf "$tmp"
    xattr -d com.apple.quarantine "$bindir/gh" 2>/dev/null || true
    _ensure_path_local_bin
    hash -r 2>/dev/null || true
    gh --version &>/dev/null
}

_ensure_gh() {
    _ensure_path_local_bin
    if command -v gh &>/dev/null && gh --version &>/dev/null; then
        return 0
    fi
    if command -v brew &>/dev/null; then
        echo "→ Installing gh via Homebrew..."
        brew install gh
        return 0
    fi
    echo "→ Installing gh from GitHub release..."
    _install_gh_from_github_release
}

_bootstrap_gh_use_device_login() {
    [[ "${DOTFILES_GH_DEVICE_LOGIN:-0}" == 1 ]] && return 0
    [[ -n "${SSH_CONNECTION:-}" ]] && return 0
    [[ -z "${DISPLAY:-}" ]] && return 0
    return 1
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

    if _bootstrap_gh_use_device_login; then
        echo "→ GitHub device login (SSH/remote — use your laptop browser, not this Mac)"
        echo "   Open https://github.com/login/device and enter the one-time code gh prints."
        gh auth login -h github.com -p https --web=false --skip-ssh-key
    else
        echo "→ GitHub login (local browser — username/password or SSO)"
        gh auth login -h github.com -p https -w --skip-ssh-key
    fi
    gh auth setup-git
    echo "✅ GitHub authenticated"
}

_main() {
    [[ "$(uname -s)" == "Darwin" ]] || {
        echo "This entry script is for macOS only." >&2
        exit 1
    }
    command -v curl &>/dev/null || {
        echo "curl is required." >&2
        exit 1
    }

    _maybe_reexec_arm64 "$@"
    echo "=== dotfiles macOS bootstrap (public entry) ==="
    _ensure_gh
    _ensure_github_auth

    echo "→ Fetching bootstrap from ${DOTFILES_GITHUB} (uses gh keyring — no PAT)"
    exec bash -c "$(gh api -H "Accept: application/vnd.github.raw" \
        "repos/${DOTFILES_GITHUB}/contents/scripts/bootstrap-macos.sh")"
}

_main "$@"
