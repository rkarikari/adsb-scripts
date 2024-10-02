#!/bin/bash

set -e
trap 'echo "[ERROR] Error in line $LINENO when executing: $BASH_COMMAND"' ERR

NAME=zram0
DEV=/dev/$NAME

if { mount; cat /proc/swaps; } | grep -qs "$DEV"; then
    echo "zram-swap.sh: $DEV is already mounted or used as swap, no actions performed."
    exit 0
fi

modprobe zram

# reset the device to ensure we can set the parameters
echo 1 > "/sys/block/$NAME/reset"

# https://github.com/lz4/lz4?tab=readme-ov-file#benchmarks
# Core i7-9700K single thread
# Compressor            Ratio   Compression Decompression
# LZ4 default (v1.9.0)  2.101   780 MB/s    4970 MB/s
# Zstandard 1.4.0 -1    2.883   515 MB/s    1380 MB/s

echo zstd > "/sys/block/$NAME/comp_algorithm"
# lz4 is quicker but less compression
#echo lz4 > "/sys/block/$NAME/comp_algorithm"

# use 1/4 of memory
use=$(( $(grep -e MemTotal /proc/meminfo | tr -s ' ' | cut -d' ' -f2) / 4 ))

# use at least 256M for systems with small memory
min=$(( 256 * 1024 ))

if (( use < min )); then
    size=$min
else
    size=$use
fi

# zram maximum memory usage
echo $(( size ))K > "/sys/block/$NAME/mem_limit"

# disk size
# let's make this 3x the memory limit in case we get good compression
echo $(( 4 * size ))K > "/sys/block/$NAME/disksize"

mkswap "$DEV"
swapon -p 100 "$DEV"

# turn off file based swap
TURNOFF=$(grep </proc/swaps -F -v -e zram -e Filename | cut -d' ' -f1)
if [[ -n $TURNOFF ]]; then
    swapoff $TURNOFF || true
fi

if ! grep </proc/swaps -qs -F -v -e zram -e Filename; then

    # for zram swap, most guides reommend the following:
    # swappiness 200, watermark_scale_factor 125, watermark_boost_factor 0
    #
    # swappiness
    # if zram is the only swap, increase swappiness (default swappiness 60)
    # zram guides propose 200 but that seems excessive
    echo 100 > /proc/sys/vm/swappiness

    # watermark_scale_factor
    # This factor controls the aggressiveness of kswapd. It defines the amount
    # of memory left in a node/system before kswapd is woken up and how much
    # memory needs to be free before kswapd goes back to sleep.
    # 60: 0.6 percent free memory (default 10 / 0.1%)
    echo 60 > /proc/sys/vm/watermark_scale_factor

    # watermark_boost_factor
    # this has to do with reclaiming on fragmentation, swap on zram guides seem to disable this but don't give a reason
    echo 0 > /proc/sys/vm/watermark_boost_factor

    # disable readahead for reading from swap (default is 3 which means 2^3 = 8 pages)
    echo 0 > /proc/sys/vm/page-cluster
fi
