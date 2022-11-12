#!/bin/bash

# shellcheck disable=SC1007
# shellcheck disable=SC1090
# shellcheck disable=SC2034
# shellcheck disable=SC2046
# shellcheck disable=SC2053
# shellcheck disable=SC2059
# shellcheck disable=SC2068
# shellcheck disable=SC2124
# shellcheck disable=SC2128
# shellcheck disable=SC2155
# shellcheck disable=SC2164
# shellcheck disable=SC2188
# shellcheck disable=SC2206
# shellcheck disable=SC2242

############################## 环境配置 ##################################
# The following modules are loaded before any boot hooks are
# run.  Advanced users may wish to specify all system modules
# in this array.  For instance:
#     MODULES=(piix ide_disk reiserfs)
MODULES=()

# BINARIES
# This setting includes any additional binaries a given user may
# wish into the CPIO image.  This is run last, so it may be used to
# override the actual binaries included by a given hook
# BINARIES are dependency parsed, so you may safely ignore libraries
BINARIES=()

# FILES
# This setting is similar to BINARIES above, however, files are added
# as-is and are not parsed in any way.  This is useful for config files.
FILES=()

# HOOKS
# This is the most important setting in this file.  The HOOKS control the
# modules and scripts added to the image, and what happens at boot time.
# Order is important, and it is recommended that you do not change the
# order in which HOOKS are added.  Run 'mkinitcpio -H <hook name>' for
# help on a given hook.
# 'base' is _required_ unless you know precisely what you are doing.
# 'udev' is _required_ in order to automatically load modules
# 'filesystems' is _required_ unless you specify your fs modules in MODULES
# Examples:
##   This setup specifies all modules in the MODULES setting above.
##   No raid, lvm2, or encrypted root is needed.
#    HOOKS=(base)
#
##   This setup will autodetect all modules for your system and should
##   work as a sane default
#    HOOKS=(base udev autodetect block filesystems)
#
##   This setup will generate a 'full' image which supports most systems.
##   No autodetection is done.
#    HOOKS=(base udev block filesystems)
#
##   This setup assembles a pata mdadm array with an encrypted root FS.
##   Note: See 'mkinitcpio -H mdadm' for more information on raid devices.
#    HOOKS=(base udev block mdadm encrypt filesystems)
#
##   This setup loads an lvm2 volume group on a usb device.
#    HOOKS=(base udev block lvm2 filesystems)
#
##   NOTE: If you have /usr on a separate partition, you MUST include the
#    usr, fsck and shutdown hooks.
HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)

# COMPRESSION
# Use this to compress the initramfs image. By default, zstd compression
# is used. Use 'cat' to create an uncompressed image.
#COMPRESSION="zstd"
#COMPRESSION="gzip"
#COMPRESSION="bzip2"
#COMPRESSION="lzma"
#COMPRESSION="xz"
#COMPRESSION="lzop"
#COMPRESSION="lz4"

# COMPRESSION_OPTIONS
# Additional options for the compressor
#COMPRESSION_OPTIONS=()



########################################################################


############################# 全局变量  ##################################
currentDir=$(dirname $(realpath -- "$0"))

declare -r version=31
shopt -s extglob

############################ functions #################################
_msg()
{
    local _msg="${@}"
    printf "${_msg}\n" >&2
}

_msg_main()
{
    local _msg="${@}"
    printf "${_color_blue}===>${_color_none} ${_color_bold}${_msg}${_color_none}\n" >&2
}

_msg_info()
{
    local _msg="${@}"
    printf "  ${_color_blue}->${_color_none} ${_msg}\n" >&2
}

# 输出信息
_msg_info_pure()
{
    local _msg="${@}"
    printf " ${_color_bold}${_msg}${_color_none}\n" >&2
}

# 输出警告
_msg_warning()
{
    local _msg="${@}"
    printf "${_color_yellow}==> WARNING:$_color_none $_color_bold${_msg}$_color_none\n" >&2
}

# 输出错误
_msg_error()
{
    local _msg="${@}"
    printf "${_color_red}==> ERROR:${_color_none} ${_color_bold}${_msg}${_color_none}\n" >&2
    exit -1
}



### globals within mkinitcpio, but not intended to be used by hooks

# needed files/directories
_f_functions=/usr/lib/initcpio/functions
_f_config=/etc/mkinitcpio.conf
_d_hooks=/etc/initcpio/hooks:/usr/lib/initcpio/hooks
_d_install=/etc/initcpio/install:/usr/lib/initcpio/install
_d_flag_hooks=
_d_flag_install=
_d_firmware=({/usr,}/lib/firmware/updates {/usr,}/lib/firmware)
_d_presets=/etc/mkinitcpio.d

# options and runtime data
_optmoduleroot= _optgenimg=
_optcompress= _opttargetdir=
_optosrelease=
_optuefi= _optmicrocode=() _optcmdline= _optsplash= _optkernelimage= _optuefistub=
_optshowautomods=0 _optsavetree=0 _optshowmods=0
_optquiet=1 _optcolor=1
_optskiphooks=() _optaddhooks=() _hooks=()  _optpreset=()
declare -A _runhooks _addedmodules _modpaths _autodetect_cache

# export a sane PATH
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

# Sanitize environment further
# GREP_OPTIONS="--color=always" will break everything
# CDPATH can affect cd and pushd
# LIBMOUNT_* options can affect findmnt and other tools
unset GREP_OPTIONS CDPATH "${!LIBMOUNT_@}"

usage() {
    cat <<EOF
mkinitcpio $version
usage: ${0##*/} [options]

  Options:
   -A, --addhooks <hooks>       Add specified hooks, comma separated, to image
   -c, --config <config>        Use alternate config file. (default: /etc/mkinitcpio.conf)
   -g, --generate <path>        Generate cpio image and write to specified path
   -H, --hookhelp <hookname>    Display help for given hook and exit
   -h, --help                   Display this message and exit
   -k, --kernel <kernelver>     Use specified kernel version (default: $(uname -r))
   -L, --listhooks              List all available hooks
   -M, --automods               Display modules found via autodetection
   -n, --nocolor                Disable colorized output messages
   -p, --preset <file>          Build specified preset from /etc/mkinitcpio.d
   -P, --allpresets             Process all preset files in /etc/mkinitcpio.d
   -r, --moduleroot <dir>       Root directory for modules (default: /)
   -S, --skiphooks <hooks>      Skip specified hooks, comma-separated, during build
   -s, --save                   Save build directory. (default: no)
   -d, --generatedir <dir>      Write generated image into <dir>
   -t, --builddir <dir>         Use DIR as the temporary build directory
   -D, --hookdir <dir>          Specify where to look for hooks
   -U, --uefi <path>            Build an UEFI executable
   -V, --version                Display version information and exit
   -v, --verbose                Verbose output (default: no)
   -z, --compress <program>     Use an alternate compressor on the image

  Options for UEFI executable (-U, --uefi):
   --cmdline <path>             Set kernel command line from file
                                (default: /etc/kernel/cmdline or /proc/cmdline)
   --microcode <path>           Location of microcode
   --osrelease <path>           Include os-release (default: /etc/os-release)
   --splash <path>              Include bitmap splash
   --kernelimage <path>         Kernel image
   --uefistub <path>            Location of UEFI stub loader

EOF
}

version() {
    cat <<EOF
mkinitcpio $version
EOF
}

cleanup() {
    local err=${1:-$?}

    if [[ $_d_workdir ]]; then
        # when _optpreset is set, we're in the main loop, not a worker process
        if (( _optsavetree )) && [[ -z ${_optpreset[*]} ]]; then
            printf '%s\n' "${!_autodetect_cache[@]}" > "$_d_workdir/autodetect_modules"
            msg "build directory saved in %s" "$_d_workdir"
        else
            rm -rf "$_d_workdir"
        fi
    fi

    exit "$err"
}

resolve_kernver() {
    local kernel=$1 arch=

    if [[ -z $kernel ]]; then
        uname -r
        return 0
    fi

    if [[ ${kernel:0:1} != / ]]; then
        echo "$kernel"
        return 0
    fi

    if [[ ! -e $kernel ]]; then
        error "specified kernel image does not exist: \`%s'" "$kernel"
        return 1
    fi

    kver "$kernel" && return

    error "invalid kernel specified: \`%s'" "$1"

    arch=$(uname -m)
    if [[ $arch != @(i?86|x86_64) ]]; then
        error "kernel version extraction from image not supported for \`%s' architecture" "$arch"
        error "there's a chance the generic version extractor may work with a valid uncompressed kernel image"
    fi

    return 1
}

hook_help() {
    local resolved script=$(PATH=$_d_install type -p "$1")

    # this will be true for broken symlinks as well
    if [[ -z $script ]]; then
        error "Hook '%s' not found" "$1"
        return 1
    fi

    if resolved=$(readlink "$script") && [[ ${script##*/} != "${resolved##*/}" ]]; then
        msg "This hook is deprecated. See the '%s' hook" "${resolved##*/}"
        return 0
    fi

    . "$script"
    if ! declare -f help >/dev/null; then
        error "No help for hook $1"
        return 1
    fi

    msg "Help for hook '$1':"
    help

    list_hookpoints "$1"
}

hook_list() {
    local p hook resolved
    local -a paths hooklist depr
    local ss_ordinals=(¹ ² ³ ⁴ ⁵ ⁶ ⁷ ⁸ ⁹)

    IFS=: read -ra paths <<<"$_d_install"

    for path in "${paths[@]}"; do
        for hook in "$path"/*; do
            [[ -e $hook || -L $hook ]] || continue

            # handle deprecated hooks and point to replacement
            if resolved=$(readlink "$hook") && [[ ${hook##*/} != "${resolved##*/}" ]]; then
                resolved=${resolved##*/}

                if ! index_of "$resolved" "${depr[@]}"; then
                    # deprecated hook
                    depr+=("$resolved")
                    _idx=$(( ${#depr[*]} - 1 ))
                fi

                hook+=${ss_ordinals[_idx]}
            fi

            hooklist+=("${hook##*/}")
        done
    done

    msg "Available hooks"
    printf '%s\n' "${hooklist[@]}" | sort -u | column -c"$(tput cols)"

    if (( ${#depr[*]} )); then
        echo
        for p in "${!depr[@]}"; do
            printf $'%s This hook is deprecated in favor of \'%s\'\n' \
                "${ss_ordinals[p]}" "${depr[p]}"
        done
    fi
}

compute_hookset() {
    local h

    for h in "${HOOKS[@]}" "${_optaddhooks[@]}"; do
        in_array "$h" "${_optskiphooks[@]}" && continue
        _hooks+=("$h")
    done
}

build_image() {
    local out=$1 compress=$2 errmsg pipestatus

    case $compress in
        cat)
            msg "Creating uncompressed initcpio image: %s" "$out"
            unset COMPRESSION_OPTIONS
            ;;
        *)
            msg "Creating %s-compressed initcpio image: %s" "$compress" "$out"
            ;;&
        xz)
            COMPRESSION_OPTIONS=('--check=crc32' "${COMPRESSION_OPTIONS[@]}")
            ;;
        lz4)
            COMPRESSION_OPTIONS=('-l' "${COMPRESSION_OPTIONS[@]}")
            ;;
        zstd)
            COMPRESSION_OPTIONS=('-T0' "${COMPRESSION_OPTIONS[@]}")
            ;;
    esac

    pushd "$BUILDROOT" >/dev/null

    # Reproducibility: set all timestamps to 0
    find . -mindepth 1 -execdir touch -hcd "@0" "{}" +

    # If this pipeline changes, |pipeprogs| below needs to be updated as well.
    find . -mindepth 1 -printf '%P\0' |
            sort -z |
            LANG=C bsdtar --uid 0 --gid 0 --null -cnf - -T - |
            LANG=C bsdtar --null -cf - --format=newc @- |
            $compress "${COMPRESSION_OPTIONS[@]}" > "$out"

    pipestatus=("${PIPESTATUS[@]}")
    pipeprogs=('find' 'sort' 'bsdtar (step 1)' 'bsdtar (step 2)' "$compress")

    popd >/dev/null

    for (( i = 0; i < ${#pipestatus[*]}; ++i )); do
        if (( pipestatus[i] )); then
            errmsg="${pipeprogs[i]} reported an error"
            break
        fi
    done

    if (( _builderrors )); then
        warning "errors were encountered during the build. The image may not be complete."
    fi

    if [[ $errmsg ]]; then
        error "Image generation FAILED: %s" "$errmsg"
    elif (( _builderrors == 0 )); then
        msg "Image generation successful"
    fi
}

build_uefi(){
    local out=$1 initramfs=$2 cmdline=$3 osrelease=$4 splash=$5 kernelimg=$6 uefistub=$7 microcode=(${@:7}) errmsg=
    OBJCOPYARGS=()

    msg "Creating UEFI executable: %s" "$out"

    if [[ -z "$uefistub" ]]; then
        for stub in {/usr,}/lib/{systemd/boot/efi,gummiboot}/linux{x64,ia32}.efi.stub; do
            if [[ -f "$stub" ]]; then
                uefistub="$stub"
                msg2 "Using UEFI stub: %s" "$uefistub"
                break
            fi
        done
    elif [[ ! -f "$uefisub" ]]; then
        error "UEFI stub '%s' not found" "$uefistub"
        return 1
    fi

    if [[ -z "$kernelimg" ]]; then
        for img in "/lib/modules/$KERNELVERSION/vmlinuz" "/boot/vmlinuz-$KERNELVERSION" "/boot/vmlinuz-linux"; do
            if [[ -f "$img" ]]; then
                kernelimg="$img"
                msg2 "Using kernel image: %s" "$kernelimg"
                break
            fi
        done
    fi
    if [[ ! -f "$kernelimg" ]]; then
        error "Kernel image '%s' not found" "$kernelimage"
        return 1
    fi

    if [[ -z "$cmdline" ]]; then
        if [[ -f "/etc/kernel/cmdline" ]]; then
            cmdline="/etc/kernel/cmdline"
        elif [[ -f "/usr/lib/kernel/cmdline" ]]; then
            cmdline="/usr/lib/kernel/cmdline"
        else
            warning "Note: /etc/kernel/cmdline does not exist and --cmdline is unset!"
            cmdline="/proc/cmdline"
            warning "Reusing current kernel cmdline from $cmdline"
        fi
        msg2 "Using cmdline file: %s" "$cmdline"
    fi
    if [[ ! -f "$cmdline" ]]; then
        error "Kernel cmdline file '%s' not found" "$cmdline"
        return 1
    fi

    if [[ -z "$osrelease" ]]; then
        if [[ -f "/etc/os-release" ]]; then
            osrelease="/etc/os-release"
        elif [[ -f "/usr/lib/os-release" ]]; then
            osrelease="/usr/lib/os-release"
        fi
        msg2 "Using os-release file: %s" "$osrelease"
    fi
    if [[ ! -f "$osrelease" ]]; then
        error "os-release file '%s' not found" "$osrelease"
        return 1
    fi

    if [[ -z "$initramfs" ]]; then
        error "Initramfs '%s' not found" "$initramfs"
        return 1
    fi

    if [[ -n "$splash" ]]; then
        OBJCOPYARGS+=(--add-section .splash="$splash" --change-section-vma .splash=0x40000)
        msg2 "Using splash image: %s" "$splash"
    fi

    for image in "${microcode[@]}"; do
        msg2 "Using microcode image: %s" "$image"
    done

    objcopy \
        --add-section .osrel="$osrelease" --change-section-vma .osrel=0x20000 \
        --add-section .cmdline=<(grep '^[^#]' "$cmdline" | tr -s '\n' ' ') --change-section-vma .cmdline=0x30000 \
        --add-section .linux="$kernelimg" --change-section-vma .linux=0x2000000 \
        --add-section .initrd=<(cat ${microcode[@]} "$initramfs") --change-section-vma .initrd=0x3000000 \
        ${OBJCOPYARGS[@]} "$uefistub" "$out"

    status=$?
    if (( $status )) ; then
        error "UEFI executable generation FAILED"
    else
        msg "UEFI executable generation successful"
    fi
}

process_preset() (
    local preset=$1 preset_cli_options=$2 preset_image= preset_options=
    local -a preset_mkopts preset_cmd
    if (( MKINITCPIO_PROCESS_PRESET )); then
        error "You appear to be calling a preset from a preset. This is a configuration error."
        cleanup 1
    fi

    # allow path to preset file, else resolve it in $_d_presets
    if [[ $preset != */* ]]; then
        printf -v preset '%s/%s.preset' "$_d_presets" "$preset"
    fi

    . "$preset" || die "Failed to load preset: \`%s'" "$preset"

    (( ! ${#PRESETS[@]} )) && warning "Preset file \`%s' is empty or does not contain any presets." "$preset"

    # Use -m and -v options specified earlier
    (( _optquiet )) || preset_mkopts+=(-v)
    (( _optcolor )) || preset_mkopts+=(-n)

    (( _optsavetree )) && preset_mkopts+=(-s)

    ret=0
    for p in "${PRESETS[@]}"; do
        msg "Building image from preset: $preset: '$p'"
        preset_cmd=("${preset_mkopts[@]}")

        preset_kver=${p}_kver
        if [[ ${!preset_kver:-$ALL_kver} ]]; then
            preset_cmd+=(-k "${!preset_kver:-$ALL_kver}")
        else
            warning "No kernel version specified. Skipping image \`%s'" "$p"
            continue
        fi

        preset_config=${p}_config
        if [[ ${!preset_config:-$ALL_config} ]]; then
            preset_cmd+=(-c "${!preset_config:-$ALL_config}")
        else
            warning "No configuration file specified. Skipping image \`%s'" "$p"
            continue
        fi

        preset_image=${p}_image
        if [[ ${!preset_image} ]]; then
            preset_cmd+=(-g "${!preset_image}")
        else
            warning "No image file specified. Skipping image \`%s'" "$p"
            continue
        fi

        preset_options=${p}_options
        if [[ ${!preset_options} ]]; then
            preset_cmd+=(${!preset_options}) # intentional word splitting
        fi

        preset_efi_image=${p}_efi_image
        if [[ ${!preset_efi_image:-$ALL_efi_image} ]]; then
            preset_cmd+=(-U "${!preset_efi_image:-$ALL_efi_image}")
        fi

        preset_microcode=${p}_microcode[@]
        if [[ ${!preset_microcode:-$ALL_microcode} ]]; then
            for mc in "${!preset_microcode:-${ALL_microcode[@]}}"; do
                preset_cmd+=(--microcode "$mc")
            done
        fi

        preset_cmd+=($OPTREST)
        msg2 "${preset_cmd[*]}"
        MKINITCPIO_PROCESS_PRESET=1 "$0" "${preset_cmd[@]}"
        (( $? )) && ret=1
    done

    exit $ret
)

preload_builtin_modules() {
    local modname field value path

    # Prime the _addedmodules list with the builtins for this kernel. We prefer
    # the modinfo file if it exists, but this requires a recent enough kernel
    # and kmod>=27.

    if [[ -r $_d_kmoduledir/modules.builtin.modinfo ]]; then
        while IFS=.= read -rd '' modname field value; do
            _addedmodules[${modname//-/_}]=2
            case $field in
                alias)
                    _addedmodules["${value//-/_}"]=2
                    ;;
            esac
        done <"$_d_kmoduledir/modules.builtin.modinfo"

    elif [[ -r $_d_kmoduledir/modules.builtin ]]; then
        while IFS=/ read -ra path; do
            modname=${path[-1]%.ko}
            _addedmodules["${modname//-/_}"]=2
        done <"$_d_kmoduledir/modules.builtin"
    fi
}

## _f_function
parseopts() {
    local opt= optarg= i= shortopts=$1
    local -a longopts=() unused_argv=()

    shift
    while [[ $1 && $1 != '--' ]]; do
        longopts+=("$1")
        shift
    done
    shift

    longoptmatch() {
        local o longmatch=()
        for o in "${longopts[@]}"; do
            if [[ ${o%:} = "$1" ]]; then
                longmatch=("$o")
                break
            fi
            [[ ${o%:} = "$1"* ]] && longmatch+=("$o")
        done

        case ${#longmatch[*]} in
            1)
                # success, override with opt and return arg req (0 == none, 1 == required)
                opt=${longmatch%:}
                if [[ $longmatch = *: ]]; then
                    return 1
                else
                    return 0
                fi ;;
            0)
                # fail, no match found
                return 255 ;;
            *)
                # fail, ambiguous match
                printf "%s: option '%s' is ambiguous; possibilities:%s\n" "${0##*/}" \
                    "--$1" "$(printf " '%s'" "${longmatch[@]%:}")"
                return 254 ;;
        esac
    }

    while (( $# )); do
        case $1 in
            --) # explicit end of options
                shift
                break
                ;;
            -[!-]*) # short option
                for (( i = 1; i < ${#1}; i++ )); do
                    opt=${1:i:1}

                    # option doesn't exist
                    if [[ $shortopts != *$opt* ]]; then
                        printf "%s: invalid option -- '%s'\n" "${0##*/}" "$opt"
                        OPTRET=(--)
                        return 1
                    fi

                    OPTRET+=("-$opt")
                    # option requires optarg
                    if [[ $shortopts = *$opt:* ]]; then
                        # if we're not at the end of the option chunk, the rest is the optarg
                        if (( i < ${#1} - 1 )); then
                            OPTRET+=("${1:i+1}")
                            break
                        # if we're at the end, grab the the next positional, if it exists
                        elif (( i == ${#1} - 1 )) && [[ $2 ]]; then
                            OPTRET+=("$2")
                            shift
                            break
                        # parse failure
                        else
                            printf "%s: option '%s' requires an argument\n" "${0##*/}" "-$opt"
                            OPTRET=(--)
                            return 1
                        fi
                    fi
                done
                ;;
            --?*=*|--?*) # long option
                IFS='=' read -r opt optarg <<< "${1#--}"
                longoptmatch "$opt"
                case $? in
                    0)
                        if [[ $optarg ]]; then
                            printf "%s: option '--%s' doesn't allow an argument\n" "${0##*/}" "$opt"
                            OPTRET=(--)
                            return 1
                        else
                            OPTRET+=("--$opt")
                        fi
                        ;;
                    1)
                        # --longopt=optarg
                        if [[ $optarg ]]; then
                            OPTRET+=("--$opt" "$optarg")
                        # --longopt optarg
                        elif [[ $2 ]]; then
                            OPTRET+=("--$opt" "$2" )
                            shift
                        else
                            printf "%s: option '--%s' requires an argument\n" "${0##*/}" "$opt"
                            OPTRET=(--)
                            return 1
                        fi
                        ;;
                    254)
                        # ambiguous option -- error was reported for us by longoptmatch()
                        OPTRET=(--)
                        return 1
                        ;;
                    255)
                        # parse failure
                        printf "%s: unrecognized option '%s'\n" "${0##*/}" "--$opt"
                        OPTRET=(--)
                        return 1
                        ;;
                esac
                ;;
            *) # non-option arg encountered, add it as a parameter
                unused_argv+=("$1")
                ;;
        esac
        shift
    done

    # add end-of-opt terminator and any leftover positional parameters
    OPTRET+=('--' "${unused_argv[@]}" "$@")
    unset longoptmatch

    return 0
}

kver_x86() {
    # scrape the version out of the kernel image. locate the offset
    # to the version string by reading 2 bytes out of image at at
    # address 0x20E. this leads us to a string of, at most, 128 bytes.
    # read the first word from this string as the kernel version.
    local kver offset=$(hexdump -s 526 -n 2 -e '"%0d"' "$1")
    [[ $offset = +([0-9]) ]] || return 1

    read kver _ < \
        <(dd if="$1" bs=1 count=127 skip=$(( offset + 0x200 )) 2>/dev/null)

    printf '%s' "$kver"
}

kver_generic() {
    # For unknown architectures, we can try to grep the uncompressed
    # image for the boot banner.
    # This should work at least for ARM when run on /boot/Image. On
    # other architectures it may be worth trying rather than bailing,
    # and inform the user if none was found.

    # Loosely grep for `linux_banner`:
    # https://elixir.bootlin.com/linux/v5.7.2/source/init/version.c#L46
    local kver=

    read _ _ kver _ < <(grep -m1 -aoE 'Linux version .(\.[-[:alnum:]]+)+' "$1")

    printf '%s' "$kver"
}

kver() {
    # this is intentionally very loose. only ensure that we're
    # dealing with some sort of string that starts with something
    # resembling dotted decimal notation. remember that there's no
    # requirement for CONFIG_LOCALVERSION to be set.
    local kver re='^[[:digit:]]+(\.[[:digit:]]+)+'

    local arch=$(uname -m)
    if [[ $arch == @(i?86|x86_64) ]]; then
        kver=$(kver_x86 "$1")
    else
        kver=$(kver_generic "$1")
    fi

    [[ $kver =~ $re ]] || return 1

    printf '%s' "$kver"
}

plain() {
    local mesg=$1; shift
    printf "    $_color_bold$mesg$_color_none\n" "$@" >&1
}

quiet() {
    (( _optquiet )) || plain "$@"
}

msg() {
    local mesg=$1; shift
    printf "$_color_green==>$_color_none $_color_bold$mesg$_color_none\n" "$@" >&1
}

msg2() {
    local mesg=$1; shift
    printf "  $_color_blue->$_color_none $_color_bold$mesg$_color_none\n" "$@" >&1
}

warning() {
    local mesg=$1; shift
    printf "$_color_yellow==> WARNING:$_color_none $_color_bold$mesg$_color_none\n" "$@" >&2
}

error() {
    local mesg=$1; shift
    printf "$_color_red==> ERROR:$_color_none $_color_bold$mesg$_color_none\n" "$@" >&2
    return 1
}

die() {
    error "$@"
    cleanup 1
}

map() {
    local r=0
    for _ in "${@:2}"; do
        "$1" "$_" || (( $# > 255 ? r=1 : ++r ))
    done
    return $r
}

arrayize_config() {
    set -f
    [[ ${MODULES@a} != *a* ]] && MODULES=($MODULES)
    [[ ${BINARIES@a} != *a* ]] && BINARIES=($BINARIES)
    [[ ${FILES@a} != *a* ]] && FILES=($FILES)
    [[ ${HOOKS@a} != *a* ]] && HOOKS=($HOOKS)
    [[ ${COMPRESSION_OPTIONS@a} != *a* ]] && COMPRESSION_OPTIONS=($COMPRESSION_OPTIONS)
    set +f
}

in_array() {
    # Search for an element in an array.
    #   $1: needle
    #   ${@:2}: haystack

    local item= needle=$1; shift

    for item in "$@"; do
        [[ $item = $needle ]] && return 0 # Found
    done
    return 1 # Not Found
}

index_of() {
    # get the array index of an item. sets the global var _idx with
    # index and returns 0 if found, otherwise returns 1.
    local item=$1; shift

    for (( _idx=1; _idx <= $#; _idx++ )); do
        if [[ $item = ${!_idx} ]]; then
            (( --_idx ))
            return 0
        fi
    done

    # not found
    unset _idx
    return 1
}

funcgrep() {
    awk -v funcmatch="$1" '
        /^[[:space:]]*[[:alnum:]_]+[[:space:]]*\([[:space:]]*\)/ {
            match($1, funcmatch)
            print substr($1, RSTART, RLENGTH)
        }' "$2"
}

list_hookpoints() {
    local funcs script

    script=$(PATH=$_d_hooks type -P "$1") || return 0

    mapfile -t funcs < <(funcgrep '^run_[[:alnum:]_]+' "$script")

    echo
    msg "This hook has runtime scripts:"
    in_array run_earlyhook "${funcs[@]}" && msg2 "early hook"
    in_array run_hook "${funcs[@]}" && msg2 "pre-mount hook"
    in_array run_latehook "${funcs[@]}" && msg2 "post-mount hook"
    in_array run_cleanuphook "${funcs[@]}" && msg2 "cleanup hook"
}

modprobe() {
    command modprobe -d "$_optmoduleroot" -S "$KERNELVERSION" "$@"
}

auto_modules() {
    # Perform auto detection of modules via sysfs.

    local mods=

    mapfile -t mods < <(find /sys/devices -name uevent \
        -exec sort -u {} + | awk -F= '$1 == "MODALIAS" && !_[$0]++')
    mapfile -t mods < <(modprobe -qaR "${mods[@]#MODALIAS=}")

    (( ${#mods[*]} )) && printf "%s\n" "${mods[@]//-/_}"
}

all_modules() {
    # Add modules to the initcpio, filtered by grep.
    #   $@: filter arguments to grep
    #   -f FILTER: ERE to filter found modules

    local -i count=0
    local mod= OPTIND= OPTARG= filter=()

    while getopts ':f:' flag; do
        case $flag in f) filter+=("$OPTARG") ;; esac
    done
    shift $(( OPTIND - 1 ))

    while read -r -d '' mod; do
        (( ++count ))

        for f in "${filter[@]}"; do
            [[ $mod =~ $f ]] && continue 2
        done

        mod=${mod##*/}
        mod="${mod%.ko*}"
        printf '%s\n' "${mod//-/_}"
    done < <(find "$_d_kmoduledir" -name '*.ko*' -print0 2>/dev/null | grep -EZz "$@")

    (( count ))
}

add_all_modules() {
    # Add modules to the initcpio.
    #   $@: arguments to all_modules

    local mod mods

    mapfile -t mods < <(all_modules "$@")
    map add_module "${mods[@]}"

    return $(( !${#mods[*]} ))
}

add_checked_modules() {
    # Add modules to the initcpio, filtered by the list of autodetected
    # modules.
    #   $@: arguments to all_modules

    local mod mods

    if (( ${#_autodetect_cache[*]} )); then
        mapfile -t mods < <(all_modules "$@" | grep -xFf <(printf '%s\n' "${!_autodetect_cache[@]}"))
    else
        mapfile -t mods < <(all_modules "$@")
    fi

    map add_module "${mods[@]}"

    return $(( !${#mods[*]} ))
}

add_firmware() {
    # add a firmware file to the image.
    #   $1: firmware path fragment

    local fw fwpath r=1

    for fw; do
        for fwpath in "${_d_firmware[@]}"; do
            if [[ -f $fwpath/$fw.xz ]]; then
                add_file "$fwpath/$fw.xz" "$fwpath/$fw.xz" 644 && r=0
                break
            elif [[ -f $fwpath/$fw ]]; then
                add_file "$fwpath/$fw" "$fwpath/$fw" 644 && r=0
                break
            fi
        done
    done

    return $r
}

add_module() {
    # Add a kernel module to the initcpio image. Dependencies will be
    # discovered and added.
    #   $1: module name

    local target= module= softdeps= deps= field= value= firmware=()
    local ign_errors=0 found=0

    [[ $KERNELVERSION == none ]] && return 0

    if [[ $1 = *\? ]]; then
        ign_errors=1
        set -- "${1%?}"
    fi

    target=${1%.ko*} target=${target//-/_}

    # skip expensive stuff if this module has already been added
    (( _addedmodules["$target"] == 1 )) && return

    while IFS=':= ' read -r -d '' field value; do
        case "$field" in
            filename)
                # Only add modules with filenames that look like paths (e.g.
                # it might be reported as "(builtin)"). We'll defer actually
                # checking whether or not the file exists -- any errors can be
                # handled during module install time.
                if [[ $value = /* ]]; then
                    found=1
                    module=${value##*/} module=${module%.ko*}
                    quiet "adding module: %s (%s)" "$module" "$value"
                    _modpaths["$value"]=1
                    _addedmodules["${module//-/_}"]=1
                fi
                ;;
            depends)
                IFS=',' read -r -a deps <<< "$value"
                map add_module "${deps[@]}"
                ;;
            firmware)
                firmware+=("$value")
                ;;
            softdep)
                read -ra softdeps <<<"$value"
                for module in "${softdeps[@]}"; do
                    [[ $module == *: ]] && continue
                    add_module "$module?"
                done
                ;;
        esac
    done < <(modinfo -b "$_optmoduleroot" -k "$KERNELVERSION" -0 "$target" 2>/dev/null)

    if (( !found )); then
        (( ign_errors || _addedmodules["$target"] )) && return 0
        error "module not found: \`%s'" "$target"
        return 1
    fi

    if (( ${#firmware[*]} )); then
        add_firmware "${firmware[@]}" ||
            warning 'Possibly missing firmware for module: %s' "$target"
    fi

    # handle module quirks
    case $target in
        fat)
            add_module "nls_ascii?" # from CONFIG_FAT_DEFAULT_IOCHARSET
            add_module "nls_cp437?" # from CONFIG_FAT_DEFAULT_CODEPAGE
            ;;
        ocfs2)
            add_module "configfs?"
            ;;
        btrfs)
            add_module "libcrc32c?"
            ;;
        f2fs)
            add_module "crypto-crc32?"
            ;;
        ext4)
            add_module "crypto-crc32c?"
            ;;
    esac
}

add_full_dir() {
    # Add a directory and all its contents, recursively, to the initcpio image.
    # No parsing is performed and the contents of the directory is added as is.
    #   $1: path to directory
    #   $2: glob pattern to filter file additions (optional)
    #   $3: path prefix that will be stripped off from the image path (optional)

    local f= filter=${2:-*} strip_prefix=$3

    if [[ -n $1 && -d $1 ]]; then
        add_dir "$1"

        for f in "$1"/*; do
            if [[ -L $f ]]; then
                if [[ $f = $filter ]]; then
                    add_symlink "${f#$strip_prefix}" "$(readlink "$f")"
                fi
            elif [[ -d $f ]]; then
                add_full_dir "$f" "$filter" "$strip_prefix"
            elif [[ -f $f ]]; then
                if [[ $f = $filter ]]; then
                    add_file "$f" "${f#$strip_prefix}"
                fi
            fi
        done
    fi
}

add_dir() {
    # add a directory (with parents) to $BUILDROOT
    #   $1: pathname on initcpio
    #   $2: mode (optional)

    if [[ -z $1 || $1 != /?* ]]; then
        return 1
    fi

    local path=$1 mode=${2:-755}

    if [[ -d $BUILDROOT$1 ]]; then
        # ignore dir already exists
        return 0
    fi

    quiet "adding dir: %s" "$path"
    command install -dm$mode "$BUILDROOT$path"
}

add_symlink() {
    # Add a symlink to the initcpio image. There is no checking done
    # to ensure that the target of the symlink exists.
    #   $1: pathname of symlink on image
    #   $2: absolute path to target of symlink (optional, can be read from $1)

    local name=$1 target=$2

    (( $# == 1 || $# == 2 )) || return 1

    if [[ -z $target ]]; then
        target=$(readlink -f "$name")
        if [[ -z $target ]]; then
            error 'invalid symlink: %s' "$name"
            return 1
        fi
    fi

    add_dir "${name%/*}"

    if [[ -L $BUILDROOT$1 ]]; then
        quiet "overwriting symlink %s -> %s" "$name" "$target"
    else
        quiet "adding symlink: %s -> %s" "$name" "$target"
    fi
    ln -sfn "$target" "$BUILDROOT$name"
}

add_file() {
    # Add a plain file to the initcpio image. No parsing is performed and only
    # the singular file is added.
    #   $1: path to file
    #   $2: destination on initcpio (optional, defaults to same as source)
    #   $3: mode

    (( $# )) || return 1

    # determine source and destination
    local src=$1 dest=${2:-$1} mode=

    if [[ ! -f $src ]]; then
        error "file not found: \`%s'" "$src"
        return 1
    fi

    mode=${3:-$(stat -c %a "$src")}
    if [[ -z $mode ]]; then
        error "failed to stat file: \`%s'." "$src"
        return 1
    fi

    if [[ -e $BUILDROOT$dest ]]; then
        quiet "overwriting file: %s" "$dest"
    else
        quiet "adding file: %s" "$dest"
    fi
    command install -Dm$mode "$src" "$BUILDROOT$dest"
}

add_runscript() {
    # Adds a runtime script to the initcpio image. The name is derived from the
    # script which calls it as the basename of the caller.

    local funcs fn script hookname=${BASH_SOURCE[1]##*/}

    if ! script=$(PATH=$_d_hooks type -P "$hookname"); then
        error "runtime script for \`%s' not found" "$hookname"
        return
    fi

    add_file "$script" "/hooks/$hookname" 755

    mapfile -t funcs < <(funcgrep '^run_[[:alnum:]_]+' "$script")

    for fn in "${funcs[@]}"; do
        case $fn in
            run_earlyhook)
                _runhooks['early']+=" $hookname"
                ;;
            run_hook)
                _runhooks['hooks']+=" $hookname"
                ;;
            run_latehook)
                _runhooks['late']+=" $hookname"
                ;;
            run_cleanuphook)
                _runhooks['cleanup']="$hookname ${_runhooks['cleanup']}"
                ;;
        esac
    done
}

add_binary() {
    # Add a binary file to the initcpio image. library dependencies will
    # be discovered and added.
    #   $1: path to binary
    #   $2: destination on initcpio (optional, defaults to same as source)

    local -a sodeps
    local line= regex= binary= dest= mode= sodep= resolved=

    if [[ ${1:0:1} != '/' ]]; then
        binary=$(type -P "$1")
    else
        binary=$1
    fi

    if [[ ! -f $binary ]]; then
        error "file not found: \`%s'" "$1"
        return 1
    fi

    dest=${2:-$binary}
    mode=$(stat -c %a "$binary")

    # always add the binary itself
    add_file "$binary" "$dest" "$mode"

    # negate this so that the RETURN trap is not fired on non-binaries
    ! lddout=$(ldd "$binary" 2>/dev/null) && return 0

    # resolve sodeps
    regex='^(|.+ )(/.+) \(0x[a-fA-F0-9]+\)'
    while read -r line; do
        if [[ $line =~ $regex ]]; then
            sodep=${BASH_REMATCH[2]}
        elif [[ $line = *'not found' ]]; then
            error "binary dependency \`%s' not found for \`%s'" "${line%% *}" "$1"
            (( ++_builderrors ))
            continue
        fi

        if [[ -f $sodep && ! -e $BUILDROOT$sodep ]]; then
            add_file "$sodep" "$sodep" "$(stat -Lc %a "$sodep")"
        fi
    done <<< "$lddout"

    return 0
}

add_udev_rule() {
    # Add an udev rules file to the initcpio image. Dependencies on binaries
    # will be discovered and added.
    #   $1: path to rules file (or name of rules file)

    local rules="$1" rule= key= value= binary=

    if [[ ${rules:0:1} != '/' ]]; then
        rules=$(PATH=/usr/lib/udev/rules.d:/lib/udev/rules.d type -P "$rules")
    fi
    if [[ -z $rules ]]; then
        # complain about not found rules
        return 1
    fi

    add_file "$rules" /usr/lib/udev/rules.d/"${rules##*/}"

    while IFS=, read -ra rule; do
        # skip empty lines, comments
        [[ -z $rule || $rule = @(+([[:space:]])|#*) ]] && continue

        for pair in "${rule[@]}"; do
            IFS=' =' read -r key value <<< "$pair"
            case $key in
                RUN@({program}|+)|IMPORT{program}|ENV{REMOVE_CMD})
                    # strip quotes
                    binary=${value//[\"\']/}
                    # just take the first word as the binary name
                    binary=${binary%% *}
                    [[ ${binary:0:1} == '$' ]] && continue
                    if [[ ${binary:0:1} != '/' ]]; then
                        binary=$(PATH=/usr/lib/udev:/lib/udev type -P "$binary")
                    fi
                    add_binary "$binary"
                    ;;
            esac
        done
    done <"$rules"
}

parse_config() {
    # parse key global variables set by the config file.

    map add_module "${MODULES[@]}"
    map add_binary "${BINARIES[@]}"
    map add_file "${FILES[@]}"

    tee "$BUILDROOT/buildconfig" < "$1" | {
        # When MODULES is not an array (but instead implicitly converted at
        # startup), sourcing the config causes the string value of MODULES
        # to be assigned as MODULES[0]. Avoid this by explicitly unsetting
        # MODULES before re-sourcing the config.
        unset MODULES

        . /dev/stdin

        # arrayize MODULES if necessary.
        [[ ${MODULES@a} != *a* ]] && read -ra MODULES <<<"${MODULES//-/_}"

        for mod in "${MODULES[@]%\?}"; do
            mod=${mod//-/_}
            # only add real modules (2 == builtin)
            (( _addedmodules["$mod"] == 1 )) && add+=("$mod")
        done
        (( ${#add[*]} )) && printf 'MODULES="%s"\n' "${add[*]}"

        printf '%s="%s"\n' \
            'EARLYHOOKS' "${_runhooks['early']# }" \
            'HOOKS' "${_runhooks['hooks']# }" \
            'LATEHOOKS' "${_runhooks['late']# }" \
            'CLEANUPHOOKS' "${_runhooks['cleanup']% }"
    } >"$BUILDROOT/config"
}

#
# 创建一个临时目录，并在临时目录下创建标准的文件系统
#
initialize_buildroot() {
    local workdir= kernver=$1 arch=$(uname -m) buildroot

    if ! workdir=$(mktemp -d --tmpdir mkinitcpio.XXXXXX); then
        _msg_error "Failed to create temporary working directory in ${TMPDIR:-/tmp}" 1
    fi
    buildroot=${2:-$workdir/root}

    if [[ ! -w ${2:-$workdir} ]]; then
        _msg_error "Unable to write to build root: $buildroot" 1
    fi

    # base directory structure
    install -dm755 "$buildroot"/{new_root,proc,sys,dev,run,tmp,var,etc,usr/{local,lib,bin}}
    ln -s "usr/lib" "$buildroot/lib"
    ln -s "../lib"  "$buildroot/usr/local/lib"
    ln -s "bin"     "$buildroot/usr/sbin"
    ln -s "usr/bin" "$buildroot/bin"
    ln -s "usr/bin" "$buildroot/sbin"
    ln -s "../bin"  "$buildroot/usr/local/bin"
    ln -s "../bin"  "$buildroot/usr/local/sbin"
    ln -s "/run"    "$buildroot/var/run"

    case $arch in
        x86_64)
            ln -s "lib"     "$buildroot/usr/lib64"
            ln -s "usr/lib" "$buildroot/lib64"
            ;;
    esac

    # 将 mkinitcpio 的版本号加入到 initramfs 根目录
    printf '%s' "$version" >"$buildroot/VERSION"

    # 创建 kernel module 路径
    [[ $kernver != none ]] && install -dm755 "$buildroot/usr/lib/modules/$kernver/kernel"

    # mount tables
    ln -s /proc/self/mounts "$buildroot/etc/mtab"
    >"$buildroot/etc/fstab"

    # indicate that this is an initramfs
    >"$buildroot/etc/initrd-release"

    # add a blank ld.so.conf to keep ldconfig happy
    >"$buildroot/etc/ld.so.conf"

    printf '%s' "$workdir"

    _msg_info_pure ""
    _msg_info " [function] initialize_buildroot"
    _msg_info_pure "                              arch: ${arch}"
    _msg_info_pure "                           workdir: ${workdir}"
    _msg_info_pure "                    build root dir: ${buildroot}"
    _msg_info_pure "                    kernel version: ${kernver}"
    _msg_info_pure "      create directories and files: \"${buildroot}\" => /{new_root,proc,sys,dev,run,tmp,var,etc,usr/{local,lib,bin}}"
    _msg_info_pure " create kernel modules directories: ${buildroot}/usr/lib/modules/$kernver/kernel"
    _msg_info_pure "      create others file/directory: ${buildroot}/VERSION"
    _msg_info_pure "                                    ${buildroot}/etc/mtab"
    _msg_info_pure "                                    ${buildroot}/etc/fstab"
    _msg_info_pure "                                    ${buildroot}/etc/initrd-release"
    _msg_info_pure "                                    ${buildroot}/etc/ld.so.conf"
    _msg_info_pure "                                    ..."
    _msg_info_pure ""
}

run_build_hook() {
    local hook=$1 script= resolved=
    local MODULES=() BINARIES=() FILES=() SCRIPT=

    # find script in install dirs
    if ! script=$(PATH=$_d_install type -P "$hook"); then
        _msg_error "Hook '$hook' cannot be found"
        return 1
    fi

    # check for deprecation
    if resolved=$(readlink -e "$script") && [[ ${script##*/} != "${resolved##*/}" ]]; then
        _msg_warning "Hook '${script##*/}' is deprecated. Replace it with '${resolved##*/}' in your config"
        script=$resolved
    fi

    # source
    unset -f build
    if ! . "$script"; then
        _msg_error "Failed to read $script"
        return 1
    fi

    if ! declare -f build >/dev/null; then
        _msg_error "Hook '$script' has no build function"
        return 1
    fi

    # run
    if (( _optquiet )); then
        _msg_info "Running build hook: [${script##*/}]"
    else
        _msg_info "Running build hook: [$script]"
    fi
    build

    # if we made it this far, return successfully. Hooks can
    # do their own error catching if it's severe enough, and
    # we already capture errors from the add_* functions.
    return 0
}

try_enable_color() {
    local colors

    if ! colors=$(tput colors 2>/dev/null); then
        echo "Failed to enable color. Check your TERM environment variable"
        return
    fi

    if (( colors > 0 )) && tput setaf 0 &>/dev/null; then
        _color_none=$(tput sgr0)
        _color_bold=$(tput bold)
        _color_blue=$_color_bold$(tput setaf 4)
        _color_green=$_color_bold$(tput setaf 2)
        _color_red=$_color_bold$(tput setaf 1)
        _color_yellow=$_color_bold$(tput setaf 3)
    fi
}

install_modules() {
    local m moduledest=$BUILDROOT/lib/modules/$KERNELVERSION
    local -a xz_comp gz_comp zst_comp

    [[ $KERNELVERSION == none ]] && return 0

    if (( $# == 0 )); then
        warning "No modules were added to the image. This is probably not what you want."
        return 0
    fi

    cp "$@" "$moduledest/kernel"

    # unzip modules prior to recompression
    for m in "$@"; do
        case $m in
            *.xz)
                xz_comp+=("$moduledest/kernel/${m##*/}")
                ;;
            *.gz)
                gz_comp+=("$moduledest/kernel/${m##*/}")
                ;;
            *.zst)
                zst_comp+=("$moduledest/kernel/${m##*/}")
                ;;
        esac
    done
    (( ${#xz_comp[*]} )) && xz -d "${xz_comp[@]}"
    (( ${#gz_comp[*]} )) && gzip -d "${gz_comp[@]}"
    (( ${#zst_comp[*]} )) && zstd -d --rm -q "${zst_comp[@]}"

    msg "Generating module dependencies"
    install -m644 -t "$moduledest" "$_d_kmoduledir"/modules.builtin

    # we install all modules into kernel/, making the .order file incorrect for
    # the module tree. munge it, so that we have an accurate index. This avoids
    # some rare and subtle issues with module loading choices when an alias
    # resolves to multiple modules, only one of which can claim a device.
    awk -F'/' '{ print "kernel/" $NF }' \
        "$_d_kmoduledir"/modules.order >"$moduledest/modules.order"

    depmod -b "$BUILDROOT" "$KERNELVERSION"

    # remove all non-binary module.* files (except devname for on-demand module loading)
    rm "$moduledest"/modules.!(*.bin|devname|softdep)
}


############################ main ####################################
try_enable_color
_msg_main "mkinitcpio start running ..."

trap 'cleanup 130' INT
trap 'cleanup 143' TERM

_opt_short='A:c:D:g:H:hk:nLMPp:r:S:sd:t:U:Vvz:'
_opt_long=('add:' 'addhooks:' 'config:' 'generate:' 'hookdir': 'hookhelp:' 'help'
          'kernel:' 'listhooks' 'automods' 'moduleroot:' 'nocolor' 'allpresets'
          'preset:' 'skiphooks:' 'save' 'generatedir:' 'builddir:' 'version' 'verbose' 'compress:'
          'uefi:' 'microcode:' 'splash:' 'kernelimage:' 'uefistub:' 'cmdline:' 'osrelease:')

parseopts "$_opt_short" "${_opt_long[@]}" -- "$@" || exit 1
set -- "${OPTRET[@]}"
unset _opt_short _opt_long OPTRET

while :; do
    case $1 in
        # --add remains for backwards compat
        -A|--add|--addhooks)
            shift
            IFS=, read -r -a add <<< "$1"
            _optaddhooks+=("${add[@]}")
            unset add
            ;;
        -c|--config)
            shift
            _f_config=$1
            ;;
        --cmdline)
            shift
            _optcmdline=$1
            ;;
        -k|--kernel)
            shift
            KERNELVERSION=$1
            ;;
        -s|--save)
            _optsavetree=1
            ;;
        -d|--generatedir)
            shift
            _opttargetdir=$1
            ;;
        -g|--generate)
            shift
            [[ -d $1 ]] && die "Invalid image path -- must not be a directory"
            if ! _optgenimg=$(readlink -f "$1") || [[ ! -e ${_optgenimg%/*} ]]; then
                die "Unable to write to path: \`%s'" "$1"
            fi
            ;;
        -h|--help)
            usage
            cleanup 0
            ;;
        -V|--version)
            version
            cleanup 0
            ;;
        -p|--preset)
            shift
            _optpreset+=("$1")
            ;;
        -n|--nocolor)
            _optcolor=0
            ;;
        -U|--uefi)
            shift
            [[ -d $1 ]] && die "Invalid image path -- must not be a directory"
            if ! _optuefi=$(readlink -f "$1") || [[ ! -e ${_optuefi%/*} ]]; then
                die "Unable to write to path: \`%s'" "$1"
            fi
            ;;
        -v|--verbose)
            _optquiet=0
            ;;
        -S|--skiphooks)
            shift
            IFS=, read -r -a skip <<< "$1"
            _optskiphooks+=("${skip[@]}")
            unset skip
            ;;
        -H|--hookhelp)
            shift
            hook_help "$1"
            exit
            ;;
        -L|--listhooks)
            hook_list
            exit 0
            ;;
        --splash)
            shift
            [[ -f $1 ]] || die "Invalid file -- must be a file"
            _optsplash=$1
            ;;
        --kernelimage)
            shift
             _optkernelimage=$1
            ;;
        --uefistub)
            shift
             _optkernelimage=$1
            ;;
        -M|--automods)
            _optshowautomods=1
            ;;
        --microcode)
            shift
            _optmicrocode+=($1)
            ;;
        -P|--allpresets)
            _optpreset=("$_d_presets"/*.preset)
            [[ -e ${_optpreset[0]} ]] || die "No presets found in $_d_presets"
            ;;
        --osrelease)
            shift
            [[ ! -f $1 ]] && die "Invalid file -- must be a file"
            _optosrelease=$1
            ;;
        -t|--builddir)
            shift
            export TMPDIR=$1
            ;;
        -z|--compress)
            shift
            _optcompress=$1
            ;;
        -r|--moduleroot)
            shift
            _optmoduleroot=$1
            ;;
        -D|--hookdir)
            shift
            _d_flag_hooks+="$1/hooks:"
            _d_flag_install+="$1/install:"
            ;;
        --)
            shift
            break 2
            ;;
    esac
    shift
done

OPTREST="$@"

if [[ -n $_d_flag_hooks && -n $_d_flag_install ]]; then
    _d_hooks=${_d_flag_hooks%:}
    _d_install=${_d_flag_install%:}
fi


# If we specified --uefi but no -g we want to create a temporary initramfs which will be used with the efi executable.
if [[ $_optuefi && $_optgenimg == "" ]]; then
    tmpfile=$(mktemp -t mkinitcpio.XXXXXX)
    trap "rm $tmpfile" EXIT
    _optgenimg="$tmpfile"
fi

# insist that /proc and /dev be mounted (important for chroots)
# NOTE: avoid using mountpoint for this -- look for the paths that we actually
# use in mkinitcpio. Avoids issues like FS#26344.
[[ -e /proc/self/mountinfo ]] || die "/proc must be mounted!"
[[ -e /dev/fd ]] || die "/dev must be mounted!"

# use preset $_optpreset (exits after processing)
if (( ${#_optpreset[*]} )); then
    map process_preset "${_optpreset[@]}"
    exit
fi

if [[ $KERNELVERSION != 'none' ]]; then
    KERNELVERSION=$(resolve_kernver "$KERNELVERSION") || cleanup 1
    _d_kmoduledir=$_optmoduleroot/lib/modules/$KERNELVERSION
    [[ -d $_d_kmoduledir ]] || die "'$_d_kmoduledir' is not a valid kernel module directory"
fi

_d_workdir=$(initialize_buildroot "$KERNELVERSION" "$_opttargetdir") || cleanup 1
BUILDROOT=${_opttargetdir:-$_d_workdir/root}

# mkinitcpio 配置信息 </etc/mkinitcpio.conf>
arrayize_config
# FIXME:// 打印配置信息

# 获取 hook 集合
# after returning, hooks are populated into the array '_hooks'
# HOOKS should not be referenced from here on
compute_hookset
# FIXME:// 打印 hook 集合

if (( ${#_hooks[*]} == 0 )); then
    _msg_error "Invalid config: No hooks found"
fi

if (( _optshowautomods )); then
    _msg_info "Modules autodetected"
    PATH=$_d_install . 'autodetect'
    build
    printf '%s\n' "${!_autodetect_cache[@]}" | sort
    cleanup 0
fi

if [[ $_optgenimg ]]; then
    # check for permissions. if the image doesn't already exist,
    # then check the directory
    if [[ ( -e $_optgenimg && ! -w $_optgenimg ) ||
            ( ! -d ${_optgenimg%/*} || ! -w ${_optgenimg%/*} ) ]]; then
        _msg_error "Unable to write to $_optgenimg"
    fi

    _optcompress=${_optcompress:-${COMPRESSION:-zstd}}
    if ! type -P "$_optcompress" >/dev/null; then
        _msg_warning "Unable to locate compression method: $_optcompress"
        _optcompress=cat
    fi

    _msg_main "Starting build: %s" "$KERNELVERSION"
elif [[ $_opttargetdir ]]; then
    _msg_main "Starting build: %s" "$KERNELVERSION"
else
    _msg_main "Starting dry run: %s" "$KERNELVERSION"
fi

# set functrace and trap to catch errors in add_* functions
declare -i _builderrors=0
set -o functrace
trap '(( $? )) && [[ $FUNCNAME = add_* ]] && (( ++_builderrors ))' RETURN


preload_builtin_modules

map run_build_hook "${_hooks[@]}" || (( ++_builderrors ))

# process config file
parse_config "$_f_config"

# switch out the error handler to catch all errors
trap -- RETURN
trap '(( ++_builderrors ))' ERR
set -o errtrace

_msg_main "Installing modules ..."
install_modules "${!_modpaths[@]}"

# unset errtrace and trap
set +o functrace
set +o errtrace
trap -- ERR

# this is simply a nice-to-have -- it doesn't matter if it fails.
_msg_info "generate '${BUILDROOT}/ld.so.cache'"
ldconfig -r "$BUILDROOT" &>/dev/null

# Set umask to create initramfs images and EFI images as 600
umask 077

if [[ $_optgenimg ]]; then
    build_image "$_optgenimg" "$_optcompress"
elif [[ $_opttargetdir ]]; then
    _msg_info "Build complete."
else
    _msg_info "Dry run complete, use -g IMAGE to generate a real image"
fi

if [[ $_optuefi && $_optgenimg ]]; then
    build_uefi "$_optuefi" "$_optgenimg" "$_optcmdline" "$_optosrelease" "$_optsplash" "$_optkernelimage" "$_optuefistub" "${_optmicrocode[@]}"
fi

_msg_main "Clean up ${_d_workdir}"
#cleanup $(( !!_builderrors ))

_msg_main "Finished!"
_msg_info_pure ""

# vim: set ft=sh ts=4 sw=4 et:
