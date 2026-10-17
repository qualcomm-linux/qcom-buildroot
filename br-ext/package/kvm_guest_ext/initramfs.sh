#!/bin/sh
# initramfs.sh <readelf> <strip> <target dir> <init> <stage dir>: copy the
# target's BusyBox and the shared libraries it loads to <stage dir>, strip
# them, and print the gen_init_cpio list of the guest initramfs.
set -eu
readelf=$1 strip=$2 target=$3 init=$4 stage=$5

needed() {
	"${readelf}" -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p'
}

# stage <target file> <guest path>
stage() {
	mkdir -p "${stage}${2%/*}"
	cp -L "$1" "${stage}$2"
	${strip} "${stage}$2"
	echo "file $2 ${stage}$2 0755 0 0"
}

rm -rf "${stage}"
cat <<EOT
dir /bin 0755 0 0
dir /dev 0755 0 0
dir /lib 0755 0 0
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /tmp 1777 0 0
nod /dev/console 0600 0 0 c 5 1
file /init ${init} 0755 0 0
slink /bin/sh busybox 0777 0 0
EOT
# The dynamic loader searches /lib64 on 64-bit targets, where /lib64 is a
# link to /lib.
if [ -L "${target}/lib64" ]; then
	echo "slink /lib64 $(readlink "${target}/lib64") 0777 0 0"
fi
stage "${target}/bin/busybox" /bin/busybox

interp="$("${readelf}" -l "${target}/bin/busybox" |
	sed -n 's/.*program interpreter: \(.*\)\]$/\1/p')"
libs="${interp##*/} $(needed "${target}/bin/busybox")"
seen=""
while [ -n "${libs}" ]; do
	next=""
	for lib in ${libs}; do
		case " ${seen} " in *" ${lib} "*) continue ;; esac
		seen="${seen} ${lib}"
		for f in "${target}/lib/${lib}" "${target}/usr/lib/${lib}" ""; do
			[ -z "${f}" ] || [ -e "${f}" ] && break
		done
		[ -n "${f}" ] || { echo "initramfs.sh: ${lib} not found" >&2; exit 1; }
		stage "${f}" "/lib/${lib}"
		next="${next} $(needed "${f}")"
	done
	libs="${next}"
done
