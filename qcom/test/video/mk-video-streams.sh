#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# mk-video-streams.sh <out dir>: the reference streams of the video-codec
# test (test-definitions automated/linux/video-codec) and the per-frame MD5
# of their software decode to NV12, which a hardware decode must reproduce:
#
#   h264-720p.h264   H.264 high, 1280x720, 2 B-frames, GOP 30 (x264)
#   hevc-720p.hevc   HEVC main, 1280x720, 2 B-frames, GOP 30 (x265)
#   vp9-480p.ivf     VP9 profile 0, 640x480, GOP 30 (libvpx)
#   <stream>.md5     one MD5 per decoded frame, in output order
#   README           the tools and the SHA-256 of each stream
#
# 60 frames of the FFmpeg testsrc2 pattern each. The encoders run
# single-threaded, so a given set of encoder versions always makes the same
# streams; the MD5s always match the streams they were made from.
#
# Needs a host ffmpeg with libx264, libx265 and libvpx (FFMPEG overrides
# the binary).
set -eu
out=${1:?usage: mk-video-streams.sh <out dir>}
case $out in /*) ;; *) out=$PWD/$out ;; esac
ff=${FFMPEG:-ffmpeg}
frames=60
for e in libx264 libx265 libvpx-vp9; do
	"$ff" -hide_banner -encoders 2>/dev/null | grep -q " $e " ||
		{ echo "$ff has no $e encoder" >&2; exit 1; }
done
tmp=$out.tmp
rm -rf "$tmp"
mkdir -p "$tmp"
cd "$tmp"
q="-hide_banner -loglevel error -y"
src() { echo "testsrc2=size=$1:rate=30"; }
# shellcheck disable=SC2086
"$ff" $q -f lavfi -i "$(src 1280x720)" -frames:v $frames -pix_fmt yuv420p \
	-c:v libx264 -threads 1 -profile:v high -bf 2 -g 30 -crf 23 \
	-f h264 h264-720p.h264
# shellcheck disable=SC2086
"$ff" $q -f lavfi -i "$(src 1280x720)" -frames:v $frames -pix_fmt yuv420p \
	-c:v libx265 -profile:v main \
	-x265-params "bframes=2:keyint=30:pools=none:frame-threads=1:log-level=error" \
	-crf 28 -f hevc hevc-720p.hevc
# shellcheck disable=SC2086
"$ff" $q -f lavfi -i "$(src 640x480)" -frames:v $frames -pix_fmt yuv420p \
	-c:v libvpx-vp9 -threads 1 -profile:v 0 -g 30 -b:v 1M \
	-f ivf vp9-480p.ivf
streams="h264-720p.h264 hevc-720p.hevc vp9-480p.ivf"
for s in $streams; do
	# shellcheck disable=SC2086
	"$ff" $q -i "$s" -fps_mode passthrough -pix_fmt nv12 -f framemd5 - |
		grep -v '^#' | awk -F, '{ gsub(/ /, "", $6); print $6 }' > "$s.md5"
	n=$(wc -l < "$s.md5")
	[ "$n" -eq $frames ] ||
		{ echo "$s: $n frames decoded, $frames encoded" >&2; exit 1; }
	echo "$s: $(wc -c < "$s") bytes, $n frames"
done
{
	"$ff" -hide_banner -version | head -n 1
	for s in $streams; do
		echo "$(sha256sum "$s" | cut -d' ' -f1)  $s"
	done
	echo "$frames frames of testsrc2 each; <stream>.md5: per-frame MD5 of the NV12 software decode"
} > README
cd /
rm -rf "$out"
mv "$tmp" "$out"
