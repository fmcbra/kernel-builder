#!/bin/bash

# Script filename
SCRIPT_NAME="${0##*/}"

# Set a restrictive umask that clears all permission bits for others
umask 0007

# Read in default configuration
if [[ -f /etc/default/kernel-builder ]]
then
  source /etc/default/kernel-builder || exit 1
fi

# Defaults
export TMPDIR="${TMPDIR:-/scratch}"
KORG_URL="${KORG_URL:-https://cdn.kernel.org/pub/linux/kernel}"
LOG_DIR="${LOG_DIR:-/var/log/kernel-builder}"
DISTFILE_DIR="${DISTFILE_DIR:-/var/tmp/distfiles}"
DEB_DIR="${DEB_DIR:-/var/lib/kernel-builder/debs}"

# Ensure $TMPDIR exists
if ! [[ -d $TMPDIR ]]
then
  mkdir -p "$TMPDIR" || exit 1
fi

# Work directory rooted in $TMPDIR
WORK_DIR="$(mktemp -d -p "$TMPDIR" "$SCRIPT_NAME.XXXXXXXX")"
[[ $? -eq 0 ]] || exit 1

## {{{ function _exit_handler_tmpfs()
function _exit_handler_tmpfs()
{
  local re="^none on $TMPDIR/kernel-builder.*/build type tmpfs"
  local m="$(mount 2>&1 |grep -q "^none on $re type tmpfs")"
  [[ -n $m ]] || return

  local m_tmpfs=$(mount |grep "^none on $re" |awk '{print $3}')
  echo >&2 "$SCRIPT_NAME: unmounting $m_tmpfs"
  wrap umount -f $m_tmpfs
}
## }}}

## {{{ function exit_handler()
function exit_handler()
{
  [[ $USAGE -eq 1 ]] && return

  [[ $KEEP_WORK_DIR -eq 1 ]] && return
  [[ -d $WORK_DIR ]] || return

  [[ $TMPFS -eq 1 ]] && _exit_handler_tmpfs

  echo >&2 "$SCRIPT_NAME: cleaning up..."

  if [[ -f $WORK_DIR/build.log ]]
  then
    echo >&2 "$SCRIPT_NAME: preserving build.log as $WORK_DIR.log"
    mv -f "$WORK_DIR/build.log" "$WORK_DIR.log"
  fi

  echo >&2 "$SCRIPT_NAME: deleting directory $WORK_DIR"
  rm -rf "$WORK_DIR"
}
## }}}

## {{{ function die()
function die()
{
  echo >&2 "$SCRIPT_NAME: error:" "$@"
  exit 1
}
## }}}

## {{{ function debug()
function debug()
{
  [[ -n $DEBUG ]] && echo >&2 "debug: ${FUNCNAME[1]}():" "$@"
}
## }}}

## {{{ function wrap()
function wrap()
{
  [[ $# -lt 2 ]] && die "function wrap() requires 2 or more arguments (got $#)"

  local cmd="$1"; shift
  local log_file=
  if [[ ${cmd/\//} == $cmd ]]
  then
    # $cmd does not contain a '/'
    log_file="$(mktemp -p $WORK_DIR "$cmd.output.XXXXXXXX")"
  else
    # $cmd does contain a '/', e.g. a leading '/usr/bin/'
    log_file="$(mktemp -p $WORK_DIR "$(basename "$cmd").output.XXXXXXXX")"
  fi

  local ret=$?
  [[ $ret -ne 0 ]] && die "mktemp(1) failed"

  set -- $@
  debug "pwd='$(pwd)'"
  debug "executing: $cmd" "$@"
  "$cmd" "$@" > "$log_file" 2>&1
  local ret=$?

  if [[ $ret -eq 0 ]]
  then
    # $cmd succeeded, delete temporary output log file
    rm -f "$log_file"
    return 0
  fi

  echo >&2 "$SCRIPT_NAME: executed: $cmd" "$@"
  echo >&2 "$SCRIPT_NAME: error: $cmd returned non-zero exit status $ret"
  echo -e >&2 "$cmd output:"
  sed -e 's,^,  ,g' < "$log_file"
  die "wrap(): $cmd failed"
}
## }}}

## {{{ function _gpg_recv_keys()
function _gpg_recv_keys()
{
  # FIXME: remove this hack and make keys which are to be imported part of the
  # configuration in the new UI

  local key
  for key in $GPG_RECV_KEYS
  do
    wrap gpg2 --keyserver $GPG_KEYSERVER --recv-keys $key
  done
}
## }}}

## {{{ function tarball_download()
function tarball_download()
{

  # Check if tarball and signature file for this kernel release has already
  # been downloaded
  local distfiles=0
  [[ -f $DISTFILE_DIR/linux-$KV.tar.sign ]] && ((distfiles += 1))
  [[ -f $DISTFILE_DIR/linux-$KV.tar.xz ]] && ((distfiles += 1))
  [[ $distfiles -eq 2 ]] && return

  wrap cd "$WORK_DIR"

  local file=
  local major="${KV%%.*}"

  for file in "linux-$KV".tar.{sign,xz}
  do
    local url="$KORG_URL/v$major.x/$file"
    local tmp_file="$(mktemp -p "$WORK_DIR" download.XXXXXX)"
    [[ $? -eq 0 ]] || die "mktemp(1) failed"

    echo ">> Downloading $url"
    wrap wget --quiet --output-document "$tmp_file" "$url"
    wrap mv -f "$tmp_file" "$WORK_DIR/$file"
  done

  local tz="$WORK_DIR/linux-$KV.tar.xz"
  local tb="$WORK_DIR/$(basename "$tz" .xz)"
  local ts="$WORK_DIR/$(basename "$tz" .xz).sign"

  echo ">> Extracting $tz"
  wrap unxz -d -k "$tz"

  [[ -n $GPG_RECV_KEYS ]] && _gpg_recv_keys

  echo ">> Verifying gpg2 signature of file $tb"
  wrap gpg2 --verify "$ts" "$tb"

  echo ">> Moving downloaded files to $DISTFILE_DIR"
  wrap mv -f "$ts" "$DISTFILE_DIR/$(basename "$ts")"
  wrap mv -f "$tz" "$DISTFILE_DIR/$(basename "$tz")"
  wrap rm -f "$tb"
}
## }}}

## {{{ function tarball_extract()
function tarball_extract()
{
  local tz="linux-$KV.tar.xz"
  local tb="$(basename "$tz" .xz)"
  local ts="$tb.sign"

  debug "tz='$tz'"
  debug "tb='$tb'"
  debug "ts='$ts'"

  wrap cd "$WORK_DIR"

  # Ensure the tarball and signature file have been downloaded
  local file=
  for file in "$DISTFILE_DIR/$ts" "$DISTFILE_DIR/$tz"
  do
    [[ -f $file ]] || die "distfile $file doesn't exist"
  done

  echo ">> Extracting cached $DISTFILE_DIR/$tz"

  local bd="$WORK_DIR/build/linux"
  [[ -d $bd ]] || wrap mkdir -m 0750 -p "$bd"
  wrap tar Jxf "$DISTFILE_DIR/$tz" -C "$bd"
}
## }}}

## {{{ function kernel_configure()
function kernel_configure()
{
  wrap cd "$WORK_DIR/build/linux/linux-$KV"

  wrap cp -L "$KCONFIG" .config
  yes '' |make oldconfig $MAKE_OPTS >/dev/null 2>&1

  [[ $? -eq 0 ]] || die "make(1) oldconfig failed"
}
## }}}

## {{{ function _vmlinux_extract_version()
function _vmlinux_extract_version()
{
  # FIXME: add code to "main()" which checks as early as possible if required
  # toolchain binaries are available
  local strings=strings
  [[ -n $CROSS_ARCH ]] && strings=${CROSS_TOOLCHAIN}-strings

  $strings vmlinux 2>/dev/null |grep '^Linux version ' |awk '{print $3}'
}
## }}}

## {{{ function kernel_build()
function kernel_build()
{
  local ncpu=$(cat /proc/cpuinfo |grep ^processor |wc -l)

  wrap cd "$WORK_DIR/build/linux/linux-$KV"

  if [[ -z $JOBS ]]
  then
    ((ncpu *= 2))
    JOBS=$ncpu
  fi

  # FIXME: expand this (and other?) code which related to ccache such that we
  # (a) check ccache is available in PATH and (b) allow the user to specify an
  # alternate location for the ccache binaries
  PATH="/usr/lib/ccache:$PATH"
  [[ -n $DISTCC_BIN_DIR ]] && PATH="$DISTCC_BIN_DIR:$PATH"
  export PATH

  time make -j$JOBS $MAKE_OPTS bindeb-pkg
  [[ $? -eq 0 ]] || die "make(1) bindeb-pkg failed"

  # FIXME: add code to "main()" which checks as early as possible if required
  # toolchain binaries are available
  local strings=strings
  [[ -n $CROSS_ARCH ]] && strings=${CROSS_TOOLCHAIN}-strings

  export BUILT_KV=$(_vmlinux_extract_version)
  [[ -z $BUILT_KV ]] \
    && die "unable to extract version string from built kernel '$(pwd)/vmlinux'"

  wrap cd "$TMPDIR"

  # FIXME: unsure why this "mkdir(1)" invokation is here...
  [[ -d $LOG_DIR ]] || wrap mkdir -m 0750 "$LOG_DIR"
}
## }}}

## {{{ function archive_debs()
function archive_debs()
{
  [[ -d $DEB_DIR ]] || wrap mkdir -p -m0750 "$DEB_DIR"
  wrap mkdir "$DEB_DIR/$BUILT_KV"

  local saved_ifs="$IFS"
  LFS=$(echo -e '\n')

  local deb=
  find "$WORK_DIR/build/linux" -maxdepth 1 -type f -name \*.deb |while read deb
  do
    local deb_filename="$(basename "$deb")"
    wrap mv -f "$deb" "$DEB_DIR/$BUILT_KV/$deb_filename"
  done

  LFS="$saved_ifs"
}
## }}}

## {{{ function usage()
function usage()
{
  USAGE=1
  echo "Usage: $SCRIPT_NAME [options] <kernel-version>"
  echo
  echo "General options:"
  echo
  echo "  -h, --help        "
  echo "  --kconfig=PATH    "
  echo "  --work-dir=PATH   "
  echo "  --tmpfs           "
  echo "  --keep-work-dir   "
  echo
  echo "Compilation-related options:"
  echo
  echo "  --distcc-bin-dir=PATH"
  echo
  echo "Cross-compilation options:"
  echo
  echo "  --cross-arch=ARCH"
  echo "  --cross-toolchain=TRIPLE"
  exit 0
}
## }}}

## {{{ function usage_error()
function usage_error()
{
  USAGE=1
  echo >&2 "Usage: $SCRIPT_NAME [options] <kernel-version>"
  exit 1
}
## }}}

## {{{ function get_build_log_id()
function get_build_log_id()
{
  local date=$(date +%Y%m%d)
  local counter=0
  local log_id=

  while :
  do
    log_id=$date-$(printf %03d $counter)
    local log_file="$LOG_DIR/build.log-$log_id"
    [[ -f $log_file ]] || break
    ((counter += 1))
  done

  echo $log_id
}
## }}}

## {{{ function do_build()
function do_build()
{
  [[ -z $KCONFIG ]] && KCONFIG="/boot/config-$KV_CUR"
  if ! [[ -f $KCONFIG ]]
  then
    echo >&2 "$SCRIPT_NAME: error: kernel .config file '$KCONFIG' doesn't exist"
    return 1
  fi

  # Ensure various state directories exist
  local path=
  for path in "$LOG_DIR" "$DISTFILE_DIR" "$DEB_DIR"
  do
    [[ -d $path ]] || wrap mkdir -p -m 0750 "$path"
  done

  echo
  echo "Building kernel $KV"
  echo

  echo ">> Installing build dependencies"
  wrap apt-get install -y \
    bc bison build-essential ccache dirmngr dpkg-dev fakeroot flex gnupg2 \
    ncurses-dev lib{ssl,elf}-dev pkg-config zlib1g-dev xz-utils

  echo ">> Extracting tarball"
  tarball_download
  tarball_extract

  echo ">> Configuring kernel $KV"
  kernel_configure
  kernel_build

  local build_log_file="$LOG_DIR/build-$(get_build_log_id)"

  echo ">> Saving build log to file $build_log_file"
  wrap cp -f "$WORK_DIR/build.log" "$build_log_file"
  wrap chmod 0640 "$build_log_file"

  echo ">> Archiving .deb's for kernel $KV to $DEB_DIR"
  archive_debs

  # If we don't change directory to somewhere other than the tmpfs, the umount
  # will fail
  cd "$TMPDIR"

  return 0
}
## }}}

## {{{ function main()
function main()
{
  KCONFIG=          # Kernel .config, defaults to /boot/config-$KV_CUR
  KEEP_WORK_DIR=0   # Don't delete $WORK_DIR
  TMPFS=0           # Build kernel in a tmpfs
  JOBS=             # Argument to pass to make's -j (jobs) option
  CROSS_ARCH=       # Cross-compilation target architecture (e.g. arm64)
  CROSS_TOOLCHAIN=  # Cross-compilation toolchain (e.g. aarch64-linux-gnu)
  MAKE_OPTS=        # Options to make along to make(1)
  DISTCC_BIN_DIR=   # Path where distcc compiler binaries are located
                    # (/usr/lib/distcc on Debian)

  while [[ $# -gt 0 ]]
  do
    local arg="$1"; shift
    if [[ ${arg:0:1} != - ]]
    then
      set -- "$arg" "$@"
      break
    fi

    case "$arg" in
      --)
        break 2
        ;;
      -h|--help)
        usage
        ;;
      -j*)
        if [[ $arg == -j ]]
        then
          [[ -z $1 ]] && die "option '-j' requires an argument"
          arg="$1"
          shift
        else
          arg="${arg/-j/}"
          [[ -z $arg ]] && die "option '-j' requires an argument"
        fi
        JOBS="$arg"
        ;;
      --kconfig*)
        if [[ $arg == --kconfig ]]
        then
          [[ -z $1 ]] && die "option '--kconfig' requires an argument"
          arg="$1"
          shift
        elif [[ ${arg:0:10} == --kconfig= ]]
        then
         arg="${arg/--kconfig=/}"
        else
          die "invalid option '$arg'"
        fi
        KCONFIG="$arg"
        ;;
      --work-dir*)
        if [[ $arg == --work-dir ]]
        then
          [[ -z $1 ]] && die "option '--work-dir' requires an argument"
          arg="$1"
          shift
        elif [[ ${arg:0:11} == --work-dir= ]]
        then
         arg="${arg/--work-dir=/}"
        else
          die "invalid option '$arg'"
        fi
        # FIXME: due to the passage of time, one cannot remember why the below
        # "rm -rf" is there and should be revisited ASAP
        [[ -d $WORK_DIR ]] && rm -rf "$WORK_DIR"
        WORK_DIR="$arg"
        ;;
      --distcc-bin-dir*)
        if [[ $arg == --distcc-bin-dir ]]
        then
          [[ -z $1 ]] && die "option '--distcc-bin-dir' requires an argument"
          arg="$1"
          shift
        elif [[ ${arg:0:17} == --distcc-bin-dir= ]]
        then
         arg="${arg/--distcc-bin-dir=/}"
        else
          die "invalid option '$arg'"
        fi
        DISTCC_BIN_DIR="$arg"
        ;;
      --cross-arch*)
        if [[ $arg == --cross-arch ]]
        then
          [[ -z $1 ]] && die "option '--cross-arch' requires an argument"
          arg="$1"
          shift
        elif [[ ${arg:0:13} == --cross-arch= ]]
        then
         arg="${arg/--cross-arch=/}"
        else
          die "invalid option '$arg'"
        fi
        case "$arg" in
          arm64) ;;
          *)
            die "cross-compilation target arch '$arg' is not supported" ;;
        esac
        CROSS_ARCH=$arg
        ;;
      --cross-toolchain*)
        if [[ $arg == --cross-toolchain ]]
        then
          [[ -z $1 ]] && die "option '--cross-toolchain' requires an argument"
          arg="$1"
          shift
        elif [[ ${arg:0:18} == --cross-toolchain= ]]
        then
         arg="${arg/--cross-toolchain=/}"
        else
          die "invalid option '$arg'"
        fi
        case "$arg" in
          aarch64-linux-gnu) ;;
          *)
            die "cross-compilation target arch '$arg' is not supported" ;;
        esac
        CROSS_TOOLCHAIN=$arg
        ;;
      --keep-work-dir)
        KEEP_WORK_DIR=1
        ;;
      --tmpfs)
        TMPFS=1
        ;;
      *)
        die "unrecognised option '$arg'"
    esac
  done

  if [[ -n $DISTCC_BIN_DIR ]]
  then
    [[ -d $DISTCC_BIN_DIR ]] || die "directory '$DISTCC_BIN_DIR' doesn't exist"
  fi

  # Option --cross-arch requires --cross-toolchain and vice versa
  [[ -n $CROSS_ARCH && -z $CROSS_TOOLCHAIN ]] \
    && die "option '--cross-arch' requires '--cross-toolchain'"
  [[ -n $CROSS_TOOLCHAIN && -z $CROSS_ARCH ]] \
    && die "option '--cross-toolchain' requires '--cross-arch'"

  [[ -n $CROSS_ARCH ]] && \
    MAKE_OPTS="'ARCH=$CROSS_ARCH' CROSS_COMPILE='${CROSS_TOOLCHAIN}-'"

  [[ $# -eq 1 ]] || usage
  [[ -n $1 ]] || usage

  KV="$1"               # Upstream kernel version which we're about to build
  KV_CUR="$(uname -r)"  # Version of the currently running kernel

  if [[ $TMPFS -eq 1 ]]
  then
    local bd="$WORK_DIR/build/linux"
    [[ -d $bd ]] || wrap mkdir -m 0750 -p "$bd"
    wrap mount -t tmpfs -o size=100% none "$bd"
  fi

  # Before doing any of the heavy lifting, change TMPDIR environment variable
  # to $WORK_DIR/tmp
  wrap mkdir -m 1777 "$WORK_DIR/tmp"
  export TMPDIR="$WORK_DIR/tmp"

  do_build "$@"
  local ret=$?

  return $ret
}
## }}}

# Re-execute appending stdout/stderr to temporary log file
exec > >(tee -a "$WORK_DIR/build.log") 2>&1

# Trap SIGINT, SIGTERM and exit builtin
trap exit_handler INT TERM EXIT

# Ensure $DISTFILE_DIR exists
# FIXME: variables should be quoted below; this logic should also be combined
# with that near the beggining of "do_build()"
if ! [[ -d $DISTFILE_DIR ]]
then
  mkdir -m 0750 $DISTFILE_DIR || exit 1
fi

main "$@"
exit $?

## vim: ts=2 sw=2 et fdm=marker :
