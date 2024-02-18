#!/bin/bash

set -eu -o pipefail

have_cpu_feature() {
	local feature="$1"
	local tag
	case $ARCH in
	arm*|aarch*)
		tag="Features"
		;;
	*)
		tag="flags"
		;;
	esac
	grep -q "^$tag"$'[ \t]'"*:.*\<$feature\>" /proc/cpuinfo
}

have_cpu_features() {
	local feature
	for feature; do
		have_cpu_feature "$feature" || return 1
	done
}

make_and_test() {
	# Build the checksum program and tests.  Set the special test support
	# flag to get support for LIBDEFLATE_DISABLE_CPU_FEATURES.
	rm -rf build
	CFLAGS="$CFLAGS -DTEST_SUPPORT__DO_NOT_USE=1" \
		cmake -B build -G Ninja -DLIBDEFLATE_BUILD_TESTS=1 > /dev/null
	cmake --build build > /dev/null

	# Run the checksum tests, for good measure.  (This isn't actually part
	# of the benchmarking.)
	./build/programs/test_checksums > /dev/null
}

__do_benchmark() {
	local impl="$1" speed
	shift
	local flags=("$@")

	speed=$(./build/programs/checksum "${CKSUM_FLAGS[@]}" \
		"${flags[@]}" -t "$FILE" | \
		grep -o '[0-9]\+ MB/s' | grep -o '[0-9]\+')
	printf "%-60s%-10s\n" "$CKSUM_NAME ($impl)" "$speed"
}

do_benchmark() {
	local impl="$1"

	if [ "$impl" = zlib ]; then
		__do_benchmark "$impl" "-Z"
	else
		CFLAGS="${EXTRA_CFLAGS[*]}" make_and_test
		__do_benchmark "libdeflate, $impl"
		if [ "$ARCH" = x86_64 ]; then
			CFLAGS="-m32 ${EXTRA_CFLAGS[*]}" make_and_test
			__do_benchmark "libdeflate, $impl, 32-bit"
		fi
	fi
}

sort_by_speed() {
	awk '{print $NF, $0}' | sort -nr | cut -f2- -d' '
}

disable_cpu_feature() {
	local name="$1"
	shift
	local extra_cflags=("$@")

	LIBDEFLATE_DISABLE_CPU_FEATURES+=",$name"
	EXTRA_CFLAGS+=("${extra_cflags[@]}")
}

cleanup() {
	if $USING_TMPFILE; then
		rm "$FILE"
	fi
}

ARCH="$(uname -m)"
USING_TMPFILE=false

if (( $# > 1 )); then
	echo "Usage: $0 [FILE]" 1>&2
	exit 1
fi

trap cleanup EXIT

if (( $# == 0 )); then
	# Generate default test data file.
	FILE=$(mktemp -t checksum_testdata.XXXXXXXXXX)
	USING_TMPFILE=true
	echo "Generating 100 MB test file: $FILE"
	head -c 100000000 /dev/urandom > "$FILE"
else
	FILE="$1"
fi

cat << EOF
Method                                                      Speed (MB/s)
------                                                      ------------
EOF

# CRC-32
CKSUM_NAME="CRC-32"
CKSUM_FLAGS=()
EXTRA_CFLAGS=()
export LIBDEFLATE_DISABLE_CPU_FEATURES=""
{
case $ARCH in
i386|x86_64)
	if have_cpu_features vpclmulqdq avx512f avx512vl; then
		do_benchmark "VPCLMULQDQ/AVX512F/AVX512VL"
		disable_cpu_feature "avx512f" "-mno-avx512f"
	fi
	if have_cpu_features vpclmulqdq avx512vl; then
		do_benchmark "VPCLMULQDQ/AVX512VL"
		disable_cpu_feature "avx512vl" "-mno-avx512vl"
	fi
	if have_cpu_features vpclmulqdq avx2; then
		do_benchmark "VPCLMULQDQ/AVX2"
		disable_cpu_feature "vpclmulqdq" "-mno-vpclmulqdq"
	fi
	if have_cpu_features pclmulqdq avx; then
		do_benchmark "PCLMULQDQ/AVX"
		disable_cpu_feature "avx" "-mno-avx"
	fi
	if have_cpu_feature pclmulqdq; then
		do_benchmark "PCLMULQDQ"
		disable_cpu_feature "pclmulqdq" "-mno-pclmul"
	fi
	;;
arm*|aarch*)
	if have_cpu_feature crc32; then
		do_benchmark "ARM"
		disable_cpu_feature "crc32" "-march=armv8-a+nocrc"
	fi
	if have_cpu_feature pmull; then
		do_benchmark "PMULL"
		disable_cpu_feature "pmull" "-march=armv8-a+nocrc+nocrypto"
	fi
	;;
esac
do_benchmark "generic"
do_benchmark "zlib"
} | sort_by_speed

# Adler-32
CKSUM_NAME="Adler-32"
CKSUM_FLAGS=(-A)
EXTRA_CFLAGS=()
export LIBDEFLATE_DISABLE_CPU_FEATURES=""
echo
{
case $ARCH in
i386|x86_64)
	if have_cpu_feature avx2; then
		do_benchmark "AVX2"
		disable_cpu_feature "avx2" "-mno-avx2"
	fi
	if have_cpu_feature sse2; then
		do_benchmark "SSE2"
		disable_cpu_feature "sse2" "-mno-sse2"
	fi
	;;
arm*)
	if have_cpu_feature neon; then
		do_benchmark "NEON"
		disable_cpu_feature "neon" "-mfpu=vfpv3"
	fi
	;;
aarch*)
	if have_cpu_feature asimd; then
		do_benchmark "NEON"
		disable_cpu_feature "neon" "-march=armv8-a+nosimd"
	fi
	;;
esac
do_benchmark "generic"
do_benchmark "zlib"
} | sort_by_speed
