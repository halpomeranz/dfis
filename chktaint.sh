#!/bin/bash
# Hal Pomeranz (hrpomeranz@gmail.com) -- November 2024
# Distributed under the Creative Commons Attribution-ShareAlike 4.0 license (CC BY-SA 4.0)
#
# Tool to interpret the value in /proc/sys/kernel/tainted
# Inspired by https://docs.kernel.org/admin-guide/tainted-kernels.html#decoding-tainted-state-at-runtime

TaintMessage=(
'proprietary module was loaded'
'module was force loaded'
'kernel running on an out of specification system'
'module was force unloaded'
'processor reported a Machine Check Exception (MCE)'
'bad page referenced or some unexpected page flags'
'taint requested by userspace application'
'kernel died recently, i.e. there was an OOPS or BUG'
'ACPI table overridden by user'
'kernel issued warning'
'staging driver was loaded'
'workaround for bug in platform firmware applied'
'externally-built (“out-of-tree”) module was loaded'
'unsigned module was loaded'
'soft lockup occurred'
'kernel has been live patched'
'auxiliary taint, defined for and used by distros'
'kernel was built with the struct randomization plugin'
'an in-kernel test has been run'
)

TaintVal=$(cat /proc/sys/kernel/tainted)
for i in {0..18}; do 
    [[ $(($TaintVal>>$i & 1)) -eq 1 ]] && echo ${TaintMessage[$i]}
done

