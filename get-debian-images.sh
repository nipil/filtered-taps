#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://cloud.debian.org/images/cloud}"
OUTPUT_DIR="${OUTPUT_DIR:-./images}"
ARCH="${ARCH:-amd64}"
EXTENSION="${EXTENSION:-qcow2}"

mkdir --parents "$OUTPUT_DIR"

cleanup() {
    if [[ -n "${TMP_IMAGE:-}" ]]; then
        rm --force -- "$TMP_IMAGE"
    fi

    if [[ -n "${TMP_CHECKSUMS:-}" ]]; then
        rm --force -- "$TMP_CHECKSUMS"
    fi
}

trap cleanup EXIT HUP INT TERM

download_debian_image() {
    local version="$1"
    local image_type="$2"

    local base="${BASE_URL}/${version}"
    local release_dir
    local image
    local dest

    [[ -n "$version" ]] || {
        echo "ERROR: missing Debian version" >&2
        return 1
    }

    [[ -n "$image_type" ]] || {
        echo "ERROR: missing image type" >&2
        return 1
    }

    echo "Checking Debian ${version} ${image_type} ${ARCH}.${EXTENSION}..."

    # Find newest numbered release directory.
    release_dir=$(
        curl \
            --fail \
            --silent \
            --show-error \
            --location \
            "$base/" |
            grep \
                --only-matching \
                --extended-regexp \
                'href="[0-9]{8}-[0-9]+/"' |
            sed \
                --regexp-extended \
                's/href="([^"]+)\/"/\1/' |
            sort \
                --version-sort |
            tail \
                --lines=1
    )

    [[ -n "$release_dir" ]] || {
        echo "ERROR: no release found for ${version}" >&2
        return 1
    }

    echo "Latest release: $release_dir"

    local release_url="${base}/${release_dir}"

    # Find the requested image.
    image=$(
        curl \
            --fail \
            --silent \
            --show-error \
            --location \
            "$release_url/" |
            grep \
                --only-matching \
                --extended-regexp \
                "href=\"[^\"]*${image_type}[^\"]*${ARCH}[^\"]*\.${EXTENSION}\"" |
            sed \
                --regexp-extended \
                's/href="([^"]+)"/\1/' |
            head \
                --lines=1
    )

    [[ -n "$image" ]] || {
        echo "ERROR: no ${image_type} ${ARCH}.${EXTENSION} image found" >&2
        return 1
    }

    dest="${OUTPUT_DIR}/debian-${version}-${image_type}-${ARCH}-${release_dir}.${EXTENSION}"

    if [[ -f "$dest" ]]; then
        echo "Already downloaded: $dest"
        return 0
    fi

    TMP_IMAGE="${dest}.tmp"
    TMP_CHECKSUMS="${dest}.sha512.tmp"

    echo "Image: $image"
    echo "Downloading SHA512SUMS..."

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --output "$TMP_CHECKSUMS" \
        "$release_url/SHA512SUMS"

    local checksum

    checksum=$(
        grep \
            --fixed-strings \
            " $image" \
            "$TMP_CHECKSUMS" |
            awk '{print $1}' |
            head \
                --lines=1
    )

    [[ -n "$checksum" ]] || {
        echo "ERROR: no SHA512 checksum found for $image" >&2
        return 1
    }

    echo "Downloading: $image"

    curl \
        --fail \
        --location \
        --retry 5 \
        --retry-delay 2 \
        --output "$TMP_IMAGE" \
        "$release_url/$image"

    echo "Verifying SHA512..."

    printf '%s  %s\n' "$checksum" "$TMP_IMAGE" |
        sha512sum \
            --check \
            --status

    echo "SHA512 verification successful."

    # The final filename appears only after successful verification.
    mv \
        -- "$TMP_IMAGE" "$dest"

    echo "NEW IMAGE: $dest"

    # Downstream actions can go here, or the caller can use the
    # function's return status / output.
}

download_debian_image trixie genericcloud
