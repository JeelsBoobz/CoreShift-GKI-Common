#!/usr/bin/env bash
set -euo pipefail

if ! command -v ccache >/dev/null 2>&1; then
  echo "ccache is required but not installed. Run ./scripts/install-build-tools.sh first." >&2
  exit 1
fi

CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-10G}"
CCACHE_BASEDIR="${CCACHE_BASEDIR:-$PWD}"
CCACHE_NOHASHDIR="${CCACHE_NOHASHDIR:-true}"
CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-none}"
CCACHE_IGNOREOPTIONS="${CCACHE_IGNOREOPTIONS:---sysroot*}"
CCACHE_COMPRESSION="${CCACHE_COMPRESSION:-true}"
CCACHE_COMPRESSION_LEVEL="${CCACHE_COMPRESSION_LEVEL:-3}"
CCACHE_DIRECT="${CCACHE_DIRECT:-true}"
CCACHE_FILE_CLONE="${CCACHE_FILE_CLONE:-true}"
CCACHE_INODE_CACHE="${CCACHE_INODE_CACHE:-true}"
CCACHE_UMASK="${CCACHE_UMASK:-002}"
CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-file_macro,time_macros,include_file_mtime,include_file_ctime,pch_defines,system_headers,locale}"
CCACHE_IS_KERNEL_COMPILING="${CCACHE_IS_KERNEL_COMPILING:-true}"
CORESHIFT_CCACHE_ZERO_STATS="${CORESHIFT_CCACHE_ZERO_STATS:-1}"

set_ccache_config_if_supported() {
  local key="$1"
  local value="$2"
  if ! ccache --set-config "${key}=${value}" >/dev/null 2>&1; then
    echo "Warning: installed ccache does not support config key ${key}" >&2
  fi
}

mkdir -p "$CCACHE_DIR"

export CCACHE_DIR
export CCACHE_MAXSIZE
export CCACHE_BASEDIR
export CCACHE_NOHASHDIR
export CCACHE_COMPILERCHECK
export CCACHE_IGNOREOPTIONS
export CCACHE_COMPRESSION
export CCACHE_COMPRESSION_LEVEL
export CCACHE_DIRECT
export CCACHE_FILE_CLONE
export CCACHE_INODE_CACHE
export CCACHE_UMASK
export CCACHE_SLOPPINESS
export CCACHE_IS_KERNEL_COMPILING
export USE_CCACHE=1

set_ccache_config_if_supported "max_size" "$CCACHE_MAXSIZE"
set_ccache_config_if_supported "compression" "$CCACHE_COMPRESSION"
set_ccache_config_if_supported "compression_level" "$CCACHE_COMPRESSION_LEVEL"
set_ccache_config_if_supported "compiler_check" "$CCACHE_COMPILERCHECK"
set_ccache_config_if_supported "direct_mode" "$CCACHE_DIRECT"
set_ccache_config_if_supported "file_clone" "$CCACHE_FILE_CLONE"
set_ccache_config_if_supported "inode_cache" "$CCACHE_INODE_CACHE"
set_ccache_config_if_supported "umask" "$CCACHE_UMASK"
set_ccache_config_if_supported "sloppiness" "$CCACHE_SLOPPINESS"
set_ccache_config_if_supported "ignore_options" "$CCACHE_IGNOREOPTIONS"
set_ccache_config_if_supported "is_kernel_compiling" "$CCACHE_IS_KERNEL_COMPILING"

if find "$CCACHE_DIR" -mindepth 1 -print -quit >/dev/null 2>&1; then
  echo "Restored ccache contents found"
  ccache -s || true
  touch_stamp="$(date -d '1 day ago' +%Y%m%d%H%M)"
  find "$CCACHE_DIR" -type f -exec touch -t "$touch_stamp" {} + || true
else
  echo "No existing ccache contents found"
fi

if [ "${CORESHIFT_CCACHE_DEBUG:-0}" = "1" ]; then
  CCACHE_LOGFILE="${CCACHE_LOGFILE:-$PWD/ccache.log}"
  export CCACHE_LOGFILE
  echo "CCACHE_LOGFILE=$CCACHE_LOGFILE"
fi

if [ "$CORESHIFT_CCACHE_ZERO_STATS" = "1" ]; then
  ccache --zero-stats || ccache -z || true
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "CCACHE_DIR=$CCACHE_DIR" >> "$GITHUB_ENV"
  echo "CCACHE_MAXSIZE=$CCACHE_MAXSIZE" >> "$GITHUB_ENV"
  echo "CCACHE_BASEDIR=$CCACHE_BASEDIR" >> "$GITHUB_ENV"
  echo "CCACHE_NOHASHDIR=$CCACHE_NOHASHDIR" >> "$GITHUB_ENV"
  echo "CCACHE_COMPILERCHECK=$CCACHE_COMPILERCHECK" >> "$GITHUB_ENV"
  echo "CCACHE_IGNOREOPTIONS=$CCACHE_IGNOREOPTIONS" >> "$GITHUB_ENV"
  echo "CCACHE_COMPRESSION=$CCACHE_COMPRESSION" >> "$GITHUB_ENV"
  echo "CCACHE_COMPRESSION_LEVEL=$CCACHE_COMPRESSION_LEVEL" >> "$GITHUB_ENV"
  echo "CCACHE_DIRECT=$CCACHE_DIRECT" >> "$GITHUB_ENV"
  echo "CCACHE_FILE_CLONE=$CCACHE_FILE_CLONE" >> "$GITHUB_ENV"
  echo "CCACHE_INODE_CACHE=$CCACHE_INODE_CACHE" >> "$GITHUB_ENV"
  echo "CCACHE_UMASK=$CCACHE_UMASK" >> "$GITHUB_ENV"
  echo "CCACHE_SLOPPINESS=$CCACHE_SLOPPINESS" >> "$GITHUB_ENV"
  echo "CCACHE_IS_KERNEL_COMPILING=$CCACHE_IS_KERNEL_COMPILING" >> "$GITHUB_ENV"
  echo "USE_CCACHE=1" >> "$GITHUB_ENV"
  if [ -n "${CCACHE_LOGFILE:-}" ]; then
    echo "CCACHE_LOGFILE=$CCACHE_LOGFILE" >> "$GITHUB_ENV"
  fi
fi

ccache --version
echo "CCACHE_DIR=$CCACHE_DIR"
echo "CCACHE_MAXSIZE=$CCACHE_MAXSIZE"
echo "CCACHE_BASEDIR=$CCACHE_BASEDIR"
echo "CCACHE_NOHASHDIR=$CCACHE_NOHASHDIR"
echo "CCACHE_COMPILERCHECK=$CCACHE_COMPILERCHECK"
echo "CCACHE_IGNOREOPTIONS=$CCACHE_IGNOREOPTIONS"
echo "CCACHE_COMPRESSION=$CCACHE_COMPRESSION"
echo "CCACHE_COMPRESSION_LEVEL=$CCACHE_COMPRESSION_LEVEL"
echo "CCACHE_DIRECT=$CCACHE_DIRECT"
echo "CCACHE_FILE_CLONE=$CCACHE_FILE_CLONE"
echo "CCACHE_INODE_CACHE=$CCACHE_INODE_CACHE"
echo "CCACHE_UMASK=$CCACHE_UMASK"
echo "CCACHE_SLOPPINESS=$CCACHE_SLOPPINESS"
echo "CCACHE_IS_KERNEL_COMPILING=$CCACHE_IS_KERNEL_COMPILING"
ccache -p || true
ccache -s || true
