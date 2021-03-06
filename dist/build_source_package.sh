#!/bin/bash

# Generates OS-specific packaging with metadata fields filled in.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Parse version
# - version: Base tag name
# - plus_rev: Number of commits since tag (0 if building tag)
# - git_commit: git short commit ID of HEAD
# - full_version: ${version}.r${plus_rev}.git${git_commit}
compute_version() {
    local raw_version
    local components

    if [[ -n "${VERSION_OVERRIDE:-}" ]]; then
        raw_version=${VERSION_OVERRIDE}
    else
        raw_version=$(git describe --long)
    fi

    IFS='-' read -r -a components <<< "${raw_version}"

    version=${components[0]}
    plus_rev=${components[1]:-}
    git_commit=${components[2]:-}
    git_commit=${git_commit#g}

    full_version=${version}
    if [[ -n "${plus_rev}" ]]; then
        full_version+=.r${plus_rev}
    fi
    if [[ -n "${git_commit}" ]]; then
        full_version+=.git${git_commit}
    fi
}

check_tools() {
    local cmd missing=()

    for cmd in "${@}"; do
        if ! command -v "${cmd}" >/dev/null; then
            missing+=("${cmd}")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo >&2 "The following tools must be installed:"
        for cmd in "${missing[@]}"; do
            echo >&2 "- ${cmd}"
        done
        exit 1
    fi
}

# Build tarball to be used for all distro's packaging
build_tarball() {
    local prefix="ipmi-fan-control-${full_version}"
    tarball="${output_dir}/${prefix}.tar.gz"

    pushd "$(git rev-parse --show-toplevel)"
    git archive \
        --format tar.gz \
        --prefix "${prefix}/" \
        --output "${tarball}" \
        HEAD
    popd
}

# Build source RPM for Fedora/CentOS
build_srpm() {
    check_tools rpmbuild

    mkdir -p "${temp_dir}"/rpm/{SOURCES,SPECS}
    sed \
        -e "s/@VERSION@/${version}/g" \
        -e "s/@PLUS_REV@/${plus_rev}/g" \
        -e "s/@GIT_COMMIT@/${git_commit}/g" \
        -e "s/@TARBALL_NAME@/$(basename "${tarball}")/g" \
        < rpm/ipmi-fan-control.spec.in \
        > "${temp_dir}"/rpm/SPECS/ipmi-fan-control.spec
    cp ipmi-fan-control.service "${temp_dir}"/rpm/SOURCES/
    cp "${tarball}" "${temp_dir}"/rpm/SOURCES/

    rpmbuild \
        --define "_topdir ${temp_dir}/rpm" \
        -bs "${temp_dir}"/rpm/SPECS/ipmi-fan-control.spec

    mkdir -p "${output_dir}"/rpm
    cp -v "${temp_dir}"/rpm/SRPMS/*.src.rpm "${output_dir}"/rpm/
}

clean_up() {
    rm -r "${temp_dir}"
}

help() {
    echo "Usage: ${0} -t <target> [<option>...]"
    echo
    echo 'Options:'
    echo '  -t, --target  Type of source package to build'
    echo
    echo 'Valid targets:'
    echo '  tarball - Build a source tarball using "git archive"'
    echo '  srpm    - Build an SRPM'
}

parse_args() {
    local args target=
    if ! args=$(getopt -o ht: -l help,target: -n "${0}" -- "${@}"); then
        echo >&2 'Failed to parse arguments'
        help >&2
        exit 1
    fi

    eval set -- "${args}"

    while true; do
        case "${1}" in
        -h|--help)
            help
            exit
            ;;
        -t|--target)
            target=${2}
            shift 2
            ;;
        --)
            shift
            break
            ;;
        esac
    done

    if [[ "${#}" -ne 0 ]]; then
        echo >&2 "Unexpected arguments: ${*}"
        help >&2
        exit 1
    fi

    actions=()

    case "${target}" in
    tarball)
        actions+=(tarball)
        ;;
    srpm)
        actions+=(tarball srpm)
        ;;
    '')
        echo >&2 "No target specified"
        help >&2
        exit 1
        ;;
    *)
        echo >&2 "Unknown target: ${target}"
        help >&2
        exit 1
        ;;
    esac
}

###

parse_args "${@}"

output_dir=$(pwd)/output
mkdir -p "${output_dir}"

temp_dir=$(mktemp -d -p .)
trap clean_up EXIT

compute_version
echo "Version: ${version}"
echo "Commits since tag: ${plus_rev}"
echo "HEAD short commit: ${git_commit}"

for action in "${actions[@]}"; do
    build_"${action}"
done
