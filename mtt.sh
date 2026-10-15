#!/bin/bash
# Hal Pomeranz (hrpomeranz@gmail.com) -- 2026-10-15
# Distributed under the Creative Commons Attribution-ShareAlike 4.0 license (CC BY-SA 4.0)
# Version: 3.2.1
#
# TODO clean this up
#shellcheck disable=SC2086
# TODO add support for renaming images with multiple volume groups

usage() {
    cat <<EOM
Automatically mount image files (libewf-tools is required for E01s,
xmount required for the -W/-V/-A options).

Use -U option to unmount what was previously mounted.

Usage: $0 [-D] [-W | -V/A newname ] [-E [-S chunksize]] [-d mountpoint] images
       $0 [-D] -U mountpoint

    -D          Output debugging details

    -d dir      Specify mounting point (default is "mount")
    -E	        Export E01s of partitions from image
    -S size     Specify the max segment size for E01 exports (in bytes)

    -W          Mount image with writable cache file
    -V newname  Change volume group name before mounting (implies -W)
    -A newname  Change VG name and all UUIDs before mounting (implies -W)

    -U dir      Unmount everything on dir
EOM
    exit 1;
}

# Unmounts everything, including deactivating volume groups and detatching
# loopback devices. Ends program when finished.
# 
do_unmount() {
    declare -A found_vgs
    declare -A raid_devs

    # See bottom of loop for inputs
    while read -r dev dir; do
	umount "$dir"
	[[ $Debug -gt 0 ]] && echo +++++ unmounted \"$dir\" \(device is \"$dev\"\)
	# Is this device part of a volume group?
	# Capture all unique volume group names
	vgname=$(lvdisplay -c $dev 2>/dev/null | cut -f2 -d:)
	if [[ -n $vgname ]]; then
	    found_vgs[$vgname]=1
	    [[ $Debug -gt 0 ]] && echo +++++ volume group name $vgname

	    # Get name of underlying block device
	    dev=$(pvdisplay -c 2>/dev/null | awk -F: "/$vgname/ {print \$1}" | sed 's/ *//')
	fi

	# Capture unique RAID devices
	if [[ $dev =~ ^/dev/md[0-9]* ]]; then
	    raid_devs[$dev]=1
	    [[ $Debug -gt 0 ]] && echo +++++ Found RAID device $dev
	fi
    done< <(df --output=source,target | grep -F "$UnmountDir" | sort -b -k2,2 -r)

    # "vgchange -a n" to deactivate all volume groups
    for vgname in "${!found_vgs[@]}"; do
	vgchange -a n $vgname >/dev/null 2>&1
	[[ $Debug -gt 0 ]] && echo +++++ vgchange -a n $vgname
    done

    # Stop RAID devices
    mdadm -S "${!raid_devs[@]}" 2>/dev/null
    [[ $Debug -gt 0 ]] && echo "+++++ Stopping RAID devices ${!raid_devs[*]}"
    
    # "losetup -d" on all loopback devices
    losetup -d $(losetup -a | grep -F "$UnmountDir" | cut -d: -f1) 2>/dev/null 
    [[ $Debug -gt 0 ]] && echo "+++++ Disconnecting loop devices"

    # Stop xmount process(es), save cache files, if necessary
    xmount_img=$(ls "$UnmountDir"/xmount/file*/*.dd 2>/dev/null)
    if [[ -n "$xmount_img" ]]; then
	umount "$UnmountDir"/xmount/file* 2>/dev/null
	[[ $Debug -gt 0 ]] &&
	    echo +++++ xmount: unmounting \"$xmount_img\"

	for cfile in "$UnmountDir"/xmount/cache*; do
	    [[ "$cfile" =~ _ ]] && continue    # skip other backups
	    newcfile="$cfile"_$(date '+%s')
	    mv "$cfile" "$newcfile" 2>/dev/null
	    [[ $Debug -gt 0 ]] &&
		echo ++++++ moving old xmount cache to "$newcfile"
	done
    fi

    # Stop ewfmount if necessary
    ewf_mounts=$(ls "$UnmountDir"/img/file*/ewf1 2>/dev/null)
    if [[ -n "$ewf_mounts" ]]; then
	umount "$UnmountDir/"img/file*
	[[ $Debug -gt 0 ]] &&
	    echo "+++++ ewfmount: unmounting \"$UnmountDir/img/file*\""
    fi

    exit 0
}

# Convert "file" output to fstab equivalent file system type.
# Using echo here because bash "return" can't return strings.
#
get_fs_type() {
    file_string=$1

    [[ "$file_string" == 'xfs' || "$file_string" =~ XFS ]] &&
	echo 'xfs' && return 0

    [[ "$file_string" =~ ext4 ]] && echo 'ext4' && return 0
    [[ "$file_string" =~ ext3 ]] && echo 'ext3' && return 0
    [[ "$file_string" =~ ext2 ]] && echo 'ext2' && return 0

    [[ "$file_string" == 'btrfs' || "$file_string" =~ BTRFS ]] &&
	echo 'btrfs' && return 0

    [[ "$file_string" == 'vfat' || "$file_string" =~ FAT ]] &&
	echo 'vfat' && return 0

    [[ "$file_string" =~ swap ]] && echo 'swap' && return 0
    [[ "$file_string" =~ DOS/MBR ]] && echo 'fulldisk' && return 0

    echo 'unknown' && return 1
}


# Sum up superblock data as unsigned 32-bit values (checksum field is null)
# Add data from devs[max_dev] array that follows superblock
# Make a 32 bit value by adding the upper 32 bits to the lower 32 bits
# Outputs little-endian hex value for new checksum
#
# See calc_sb_1_csum() function at
# https://github.com/md-raid-utilities/mdadm/blob/main/super1.c
#
calc_raid_checksum() {
    loop_device=$1
    new_supe=$2
    max_dev=$3

    new_checksum=0

    # Superblock data is in little-endian. Have to convert to big-endian
    # before adding into checksum
    for ((i=0; i < 64; i++)); do
	fourbytes=${new_supe:$((i*8)):8}
	fourbytes=$(echo $fourbytes | sed -E 's/(..)(..)(..)(..)/0x\4\3\2\1/')
	new_checksum=$((new_checksum + fourbytes))
    done

    # max_dev is the number of 16-bit values in the devs[] array
    # We have to convert it from little-endian first and then figure
    #    out how many 256 byte chunks we're going to read
    max_dev=$(echo $max_dev | sed -E 's/(..)(..)(..)(..)/0x\4\3\2\1/')
    num_chunks=$(( (max_dev * 2) / 256 ))

    # Keep adding to checksum value. Note the pipeline at the end of the
    # loop is giving us a list of four byte values in big-endian format
    # with the leading "0x" already added.
    while read -r fourbytes; do
	new_checksum=$((new_checksum + fourbytes))
    done< <(dd if="$loop_device" bs=256 skip=17 count="$num_chunks" 2>/dev/null | xxd -e -c 4 | awk '{print "0x"$2}')

    # Calculate final checksum value
    # Render as (big-endian) hex
    # Output as little-endian for calling function (with no leading "0x")
    new_checksum=$(( (new_checksum & 0x00000000ffffffff) + (new_checksum >> 32) ))
    printf "%08x" "$new_checksum" | sed -E 's/(..)(..)(..)(..)/\4\3\2\1/'
}

# Writes new RAID superblock to specified device with new name and UUID.
# Complications here due to having to calculate a correct checksum for
# the new superblock. In addition, we have to update the bitmap superblock
# with the new UUID (thankfully no checksum to compute here).
#
replace_raid_superblock() {
    loop_device=$1
    new_name=$2
    new_raid_uuid=$3

    # The RAID superblock (v1) is a 256 byte structure which is 4KiB from
    # the beginning of the volume. The data is in little-endian format.
    orig_supe=$(dd if="$loop_device" bs=256 skip=16 count=1 2>/dev/null | xxd -p | tr -d \\n)

    # Check that we have the right magic number
    if [[ ! "$orig_supe" =~ ^fc4e2ba9 ]]; then
	echo '*** RAID superblock format not recognized. No changes made!'
	return
    fi

    # Carve out bits that don't change
    orig_preamble=${orig_supe:0:32}
    orig_data=${orig_supe:128:304}

    # We need these values for later. We actually don't care about the
    # original checksum, but documenting its position for completeness.
    bitmap_offset=${orig_supe:192:8}
    # orig_checksum=${orig_supe:432:8}
    max_dev=${orig_supe:440:8}

    # Hex encode new name
    # Pad name field out to 32 bytes by adding nulls
    encoded_name=$(echo -n $new_name | od -An -w32 -tx1 | tr -d ' ')
    name_field=$(echo -n "$encoded_name$(printf '0%.s' {1..64})" | cut -c 1-64)

    # Assemble new superblock data with nulls for the checksum field
    # Calculate new checksum
    # Assemble final data to write back
    new_supe="${orig_preamble}${new_raid_uuid}${name_field}${orig_data}00000000${max_dev}$(printf '0%.s' {1..64})"
    new_checksum=$(calc_raid_checksum "$loop_device" "$new_supe" "$max_dev")
    new_supe="${orig_preamble}${new_raid_uuid}${name_field}${orig_data}${new_checksum}${max_dev}$(printf '0%.s' {1..64})"

    # Start creating data that will be written back to disk-- first we have
    # 4KiB of nulls and our new superblock data
    tmpfile="$TargetDir/.new_super_data"
    dd if=/dev/zero of="$tmpfile" bs=4096 count=1 2>/dev/null &&
	echo -n "$new_supe" | xxd -r -p >>"$tmpfile" &&
	cat <<EOM >>$CmdFile
dd if=/dev/zero of="$tmpfile" bs=4096 count=1
echo -n "$new_supe" | xxd -r -p >>"$tmpfile"
EOM

    # bitmap_offset is the number of 512 byte sectors after the RAID
    # superblock where the bitmap starts with its own bitmap-specific
    # superblock. We need to figure out this offset value and copy the
    # intervening data into our tmpfile (less one 256 byte chunk for
    # the new superblock we've already written).
    bitmap_offset=$(echo $bitmap_offset | sed -E 's/(..)(..)(..)(..)/0x\4\3\2\1/')
    chunk_count=$(( (bitmap_offset*2) - 1))   # in 256 byte chunks
    dd if="$loop_device" bs=256 skip=17 count=$chunk_count 2>/dev/null >>"$tmpfile" &&
	echo "dd if=\"$loop_device\" bs=256 skip=17 count=$chunk_count >>\"$tmpfile\"" >>$CmdFile

    # Now grab the bitmap superblock and swap in the new UUID (no checksum
    #    that we need to fiddle with)
    # Append the new bitmap superblock to our tmpfile
    orig_bit_supe=$(dd if="$loop_device" bs=256 skip=$((17+chunk_count)) count=1 2>/dev/null | xxd -p | tr -d \\n)
    echo "${orig_bit_supe:0:16}${new_raid_uuid}${orig_bit_supe:48}" |
	xxd -r -p >>"$tmpfile" &&
	echo "echo \"${orig_bit_supe:0:16}${new_raid_uuid}${orig_bit_supe:48}\" | xxd -r -p >>\"$tmpfile\"" >>$CmdFile

    # Overwrite the RAID info on disk with the data in our tmpfile
    dd if="$tmpfile" of="$loop_device" 2>/dev/null &&
	rm -f "$tmpfile" &&
	cat <<EOM >>$CmdFile
dd if="$tmpfile" of="$loop_device"
rm -f "$tmpfile"

EOM
    [[ $Debug -gt 0 ]] && echo "+++++ Wrote new superblock to $loop_device"
}

# Changes the UUID for a given volume-- LVM or local.
# Currently only supports EXT* and XFS file systems
# TODO: deal with btrfs and other file systems
change_vol_uuid() {
    device=$1
    
    orig_uuid=$(blkid $device | sed 's/.* UUID="//; s/".*//')
    uuid_change=0
    if [[ "${fs_type[$device]}" =~ ^ext[234] ]]; then
	# tune2fs will fail if device is not recently checked
	e2fsck -y -f $device >/dev/null 2>&1 &&
	    echo e2fsck -y -f $device >>"$CmdFile"
	(echo y | tune2fs -U random $device) >/dev/null 2>&1 &&
	    uuid_change=1 &&
	    echo -e tune2fs -U random $device\\n >>"$CmdFile"
    elif [[ "${fs_type[$device]}" == "xfs" ]]; then
	# xfs_admin fails if file system "dirty" (underplayed)
	tmpmnt="$TargetDir/files"
	mount -o noexec $device "$tmpmnt" &&
	    echo mount -o noexec $device \"$tmpmnt\" >>"$CmdFile"
	umount "$tmpmnt" &&
	    echo umount \"$tmpmnt\" >>"$CmdFile"
	xfs_admin -U generate $device >/dev/null 2>&1 &&
	    uuid_change=1 &&
	    echo -e xfs_admin -U generate $device\\n >>"$CmdFile"
    fi

    # Might be a swap device or something besides EXT* or XFS
    if [[ $uuid_change -gt 0 ]]; then
	new_uuid[$orig_uuid]=$(blkid $device | sed 's/.* UUID="//; s/".*//')
	[[ $Debug -gt 0 ]] && echo +++++ $device: Changing file system UUID from \"$orig_uuid\" to \"${new_uuid[$orig_uuid]}\"
    elif [[ $Debug -gt 0 ]]; then
	echo +++++ $device: UUID unchanged-- hope that is OK
    fi
}

# Mount device with appropriate options for various file systems.
# Currently only supports EXT[2-4], XFS, BTRFS, and FAT
#
mount_device() {
    device=$1
    targdir=$2
    fstype=$3                # could be from fstab or "file" output
    options=$4               # only relevant for BTRFS subvols

    [[ $Debug -gt 0 ]] && echo +++++ mount_device\($device, $targdir, $fstype\)

    orig_device="$device"
    if [[ -n "$NewVGName" ]]; then
	device=${device/$OldVGName/$NewVGName}
    fi
    if [[ $ChangeUUIDs -gt 0 && $device =~ ^UUID= ]]; then
	ouuid=${device#UUID=}
	[[ -n "${new_uuid[$ouuid]}" ]] &&
	    device=${device/$ouuid/${new_uuid[$ouuid]}}
    fi
    [[ $Debug -gt 0 ]] && [[ "$orig_device" != "$device" ]] &&
	echo +++++ Device \"$orig_device\" changed to \"$device\"
	    
    if [[ "$fstype" == 'btrfs' ]]; then
	extra=',noexec,norecovery'
	[[ $options =~ subvol= ]] && extra="$extra,$options"
    elif [[ "$fstype" =~ ext[34] ]]; then
	extra=',noexec,noload -t ext4'
	fstype=ext
    elif [[ "$fstype" == 'ext2' ]]; then
	extra=',noexec'
	fstype=ext
    elif [[ "$fstype" == 'xfs' ]]; then
	extra=',noexec,norecovery'
	fstype=xfs
    elif [[ "$fstype" == 'vfat' ]]; then
	extra=
    elif [[ "$fstype" == 'swap' ]]; then
	return
    else
	echo $device: skipping unexpected type \"$fstype\"
	return
    fi

    # Mount that file system!
    mount -o ro$extra $device "$targdir"
    echo mount -o ro$extra $device \"$targdir\" >>"$CmdFile"
    [[ $Debug -gt 0 ]] && echo +++++ mount -o ro$extra $device \"$targdir\"
}


############# Program starts here ###########################################

TargetDir='mount'
Debug=0
DoXmount=0
ChangeUUIDs=0
NewVGName=
OldVGName=
MakeExports=0
ChunkSize=4294967296                 # 4GB
UnmountDir=
while getopts "A:d:DES:U:V:W" opts; do
    case $opts in
	A) NewVGName=$OPTARG
	   ChangeUUIDs=1
	   DoXmount=1
	   ;;
	d) TargetDir=$OPTARG
	   ;;
        D) Debug=1
	   ;;
	E) MakeExports=1
           ;;
	S) ChunkSize=$OPTARG
	   ;;
	U) UnmountDir=$OPTARG
	   ;;
	V) NewVGName=$OPTARG
	   DoXmount=1
	   ;;
	W) DoXmount=1
	   ;;
        *) usage
           ;;
    esac
done
shift $((OPTIND - 1))

# do_unmount exits program once unmounting is finished
# Do a fixup here in case user specified "-U .../files/" rather than
#    just the toplevel directory
[[ -n "$UnmountDir" ]] && UnmountDir=${UnmountDir%%/files*} && do_unmount

if [[ $Debug -gt 0 ]]; then
    cat <<EOM
+++++ Image(s): $@
+++++ Dir: $TargetDir
+++++ Xmount=$DoXmount / ChangeUUIDs=$ChangeUUIDs / NewVGname=$NewVGName
+++++ Exports: $MakeExports
+++++ Debug: $Debug
EOM
fi

[[ "$TargetDir" =~ ^/ ]] || TargetDir=$(/bin/pwd)"/$TargetDir"
if [[ ! -d "$TargetDir" ]]; then
    echo Making $TargetDir, hope that is OK
    mkdir -p "$TargetDir" || usage
fi

# We will manually write a copy of all commands used to mount the image
# to this file
CmdFile="$TargetDir/MOUNTING"
cp /dev/null "$CmdFile"
mkdir -p "$TargetDir/files" &&
    echo mkdir -p \"$TargetDir/files\" >>"$CmdFile"

# Supplied image file(s) must be readable
# Make absolute paths so that commands in MOUNTING file will work anywhere
# TODO deal with somebody trying "mtt.sh ... foo.E*" rather than just "foo.E01"
bad_paths=0
declare FilePaths
for ifile in "$@"; do
    [[ "$ifile" =~ ^/ ]] || ifile=$(/bin/pwd)"/$ifile"

    if [[ ! -r "$ifile" ]]; then
	echo $ifile is not readable
	bad_paths=1
    fi

    FilePaths+=("$ifile")
done
[[ $bad_paths -gt 0 ]] && usage


##### Step 1:
##### -- Create raw image files if necessary
##### -- Set up loopback mounts to everything
##### -- Save "file" output for each loopback device
##### -- Deal with Linux software RAID sets
#
declare -A DevList
declare -A RaidLoops
for ((i=0; i < ${#FilePaths[@]}; i++)); do
    curr_image="${FilePaths[$i]}"
    curr_data=$(file -Ls "$curr_image")

    # Is this a (compressed) VMDK or other virtual disk? Try qemu-img
    if [[ "$curr_data" =~ VMware.*disk ]]; then
	echo Creating \"$curr_image.raw\"
	qemu-img convert "$curr_image" "$curr_image.raw"

	if [[ ! -f "$curr_image.raw" ]]; then
	    echo Failed to make \"$curr_image.raw\", aborting
	    exit 255
	fi
    
	curr_image="$curr_image.raw"
    fi

    # Is this an E01? If so, call ewfmount
    if [[ "$curr_data" =~ EWF ]]; then
	mkdir -p "$TargetDir/img/file$i"
	im_dir=$(dirname "$curr_image")
	im_name=$(basename "$curr_image")
	(cd "$im_dir" && ewfmount "$im_name" "$TargetDir/img/file$i") >/dev/null 2>&1
	[[ $Debug -gt 0 ]] && echo +++++ \(cd \"$im_dir\"\; ewfmount \"$im_name\" \"$TargetDir/img/file$i\"\)

	# No ewf1 file? Can't proceed
	if [[ ! -r "$TargetDir/img/file$i/ewf1" ]]; then
	    echo ewfmount failed, aborting
	    exit 255
	fi

	cat <<EOM >>"$CmdFile"
mkdir -p "$TargetDir/img/file$i"
(cd "$im_dir"; ewfmount "$im_name" "$TargetDir/img/file$i")

EOM
	# Next step will look at the ewf1 raw image
	curr_image="$TargetDir/img/file$i/ewf1"
    fi

    # Set up xmount cache if requested
    if [[ $DoXmount -gt 0 ]]; then
	mkdir -p "$TargetDir/xmount/file$i"
	[[ $Debug -gt 0 ]] && echo +++++ xmount --cache "$TargetDir/xmount/cache$i" --in raw "$curr_image" "$TargetDir/xmount/file$i"
	xmount --cache "$TargetDir/xmount/cache$i" --in raw "$curr_image" "$TargetDir/xmount/file$i"

	# did it work?
	exp_file=$(ls "$TargetDir/xmount/file$i/"*.dd 2>/dev/null)
	if [[ ! -r "$exp_file" ]]; then
	    echo xmount failed!
	    exit 255
	fi

	cat <<EOM >>"$CmdFile"
mkdir -p "$TargetDir/xmount/file$i"
xmount --cache "$TargetDir/xmount/cache$i" --in raw "$curr_image" "$TargetDir/xmount/file$i"

EOM
	# image file should now be xmount virtual disk
	curr_image="$exp_file"
    fi

    # "losetup -P" is magical:
    #   -- sets up loop devices to all partitions (e.g. /dev/loop0p1)
    #   -- runs vgscan to find LVM groups (but does not activate them)
    # losetup "-r" option depends on xmount choice
    if [[ $DoXmount -gt 0 ]]; then
	loop_opts='-fP'
    else
	loop_opts='-rfP'
    fi

    loop_device=$(losetup --show $loop_opts "$curr_image")
    echo -e losetup $loop_opts \"$curr_image\"\\n >>"$CmdFile"

    # Full disk images split into multiple partition devices
    loop_targs=$(ls "$loop_device"p* 2>/dev/null)
    [[ -z "$loop_targs" ]] && loop_targs=$loop_device

    # Populate info about each loop or RAID device
    # RAID devices are tricky because they don't activate until we've
    # set up all the loopback devices. So we put a placeholder in for now
    # and then address them after the outer loop ends (see below).
    for ldev in $loop_targs; do
	devinfo=$(file -Ls $ldev)
	if [[ "$devinfo" =~ Linux\ Software\ RAID ]]; then
	    raidname=$(echo $devinfo | sed 's/.*name=//; s/ .*//')
	    RaidLoops["$raidname"]="${RaidLoops[$raidname]},$ldev"
	    raiddev="/dev/md/$raidname"
	    [[ -n "${DevList[$raiddev]}" ]] && continue
	    DevList[$raiddev]='wait for activation'
	    [[ $Debug -gt 0 ]] && echo "+++++ RAID device: $raiddev"
	else
	    DevList[$ldev]=$devinfo
	    [[ $Debug -gt 0 ]] && echo "+++++ Loopback device: $ldev"
	fi
    done
done

# Do we have any RAID arrays we need to deal with?
#
if [[ ${#RaidLoops[*]} -gt 0 ]]; then
    # small pause while RAID devices are auto-assembled
    sleep 1 && echo 'sleep 1' >>$CmdFile

    if [[ $ChangeUUIDs -gt 0 ]]; then
	for name in "${!RaidLoops[@]}"; do
	    # Have to stop RAID devices to replace superblock info.
	    # We may have to disable an LVM volume before stopping md device.
	    vgname=$(pvdisplay -c "/dev/md/$name" 2>/dev/null | cut -d: -f2)
	    [[ -n "$vgname" ]] &&
		vgchange -a n "$vgname" >/dev/null 2>&1 &&
		echo "vgchange -a n \"$vgname\"" >>$CmdFile
	    mdadm -S "/dev/md/$name" 2>/dev/null &&
		echo mdadm -S "/dev/md/$name" >>$CmdFile

	    # Generate a new RAID device name and UUID
	    # Overwrite superblocks via loop devices
	    # Update info tracking arrays with new RAID name
	    new_name="$name$NewVGName"
	    new_raid_uuid=$(cat /dev/urandom | tr -dc 0-9a-f | head -c32)
	    [[ $Debug -gt 0 ]] && echo "+++++ Changing /dev/md/$name to /dev/md/$new_name, UUID $new_raid_uuid"
	    for ldev in $(echo "${RaidLoops[$name]}" | tr , ' '); do
		replace_raid_superblock "$ldev" "$new_name" "$new_raid_uuid"
	    done
	    RaidLoops["$new_name"]=${RaidLoops["$name"]}
	    DevList["/dev/md/$new_name"]='wait for activation'
	    unset RaidLoops["$name"] DevList["/dev/md/$name"]
	done

	# Flush file system cache, rescan to activate RAID units, pause
	echo 3 >/proc/sys/vm/drop_caches 
	mdadm -A --scan 2>/dev/null
	sleep 1
	cat <<EOM >>$CmdFile
echo 3 >/proc/sys/vm/drop_caches 
mdadm -A --scan 2>/dev/null
sleep 1

EOM
    fi	    
    
    # Get info about any (now hopefully active) RAID devices
    for name in "${!RaidLoops[@]}"; do
	DevList["/dev/md/$name"]=$(file -Ls "/dev/md/$name")
	[[ $Debug -gt 0 ]] && echo "+++++ RAID device: /dev/md/$name"
    done
fi


#####
##### Step 2:
##### -- Reset UUIDs etc if -A/-V specified
##### -- Activate LVM volume(s)
##### -- Attempt to identify potential root file system candidate
#
declare -A fs_type
declare -A new_uuid
root_dev=
root_type=

# If -A option was given, we need to change any LVM PV UUIDS here before
# the volumes are activated in the next step
if [[ $ChangeUUIDs -gt 0 ]]; then
    for ldev in "${!DevList[@]}"; do
	if [[ "${DevList[$ldev]}" =~ LVM2 ]]; then
	    [[ $Debug -gt 0 ]] && olduuid=$(pvdisplay -c $ldev | sed 's/.*://')

	    # Messing around with RAID might have caused LVM volumes
	    # to activate. We need to deactivate those before we can
	    # change the PV UUID.
	    vgname=$(pvdisplay -c $ldev | cut -d: -f2)
	    vgchange -a n "$vgname" >/dev/null 2>&1 &&
		echo "vgchange -a n \"$vgname\"" >>$CmdFile

	    # Now we can change the PV UUID
	    pvchange -u "$ldev" >/dev/null 2>&1 &&
		echo pvchange -u "$ldev" >>$CmdFile

	    if [[ $Debug -gt 0 ]]; then
		newuuid=$(pvdisplay -c $ldev | sed 's/.*://')
		echo "+++++ $ldev: Changing LVM PV UUID from \"$olduuid\" to \"$newuuid\""
	    fi
	fi
    done
fi

declare -A SeenVG
for ldev in "${!DevList[@]}"; do
    ptype="${DevList[$ldev]}"
    
    # Skip if partition table or swap
    [[ "$ptype" =~ (DOS/MBR|swap) ]] && continue

    # Deal with LVM volumes
    if [[ "$ptype" =~ LVM2 ]]; then
	# Get the volume group name
	vgname=$(pvdisplay -c $ldev 2>/dev/null | cut -f2 -d:)
	[[ $Debug -gt 0 ]] && echo "+++++ $ldev: volume group \"$vgname\""

	# Are we dealing with a duplicate volume name? Bail!
	# -V/-A can't work if duplicate name already present
	if [[ $(vgdisplay -c 2>/dev/null | cut -f1 -d: | grep -cF "$vgname") -gt 1 ]]; then
	    echo \*\*\* MAJOR ISSUE\!
	    echo \*\*\* Looks like there is already a volume group with the name \"$vgname\" mounted here.
	    echo \*\*\* We cannot mount this image until the other image is unmounted. Sorry\!
	    losetup -d $loop_device
	    UnmountDir=$TargetDir
	    do_unmount                # do_unmount() exits the program
	fi

	# Be careful not to trigger this code twice on split volumes
	[[ -n "${SeenVG[$vgname]}" ]] && continue
	SeenVG[$vgname]='yes'

	# Was -V or -A option given? Rename volume group
	if [[ -n "$NewVGName" ]]; then
	    [[ $Debug -gt 0 ]] && echo +++++ vgrename "$vgname" "$NewVGName"
	    vgrename "$vgname" "$NewVGName" >/dev/null 2>&1
	    OldVGName="$vgname"
	    vgname="$NewVGName"
	    SeenVG[$NewVGName]='yes'
	    echo vgrename "$OldVGName" "$NewVGName" >>"$CmdFile"
	fi

	# Was -A option given? Change volume group UUID
	[[ $ChangeUUIDs -gt 0 ]] &&
	    vgchange -u "$vgname" >/dev/null 2>&1 &&
	    echo vgchange -u "$vgname" >> $CmdFile
	
	# Need to activate the volume group ("vgchange -a y")
	vgchange -a y $vgname >/dev/null 2>&1 && 
	    echo -e vgchange -a y $vgname\\n >>"$CmdFile"

	# Now look at each device in the volume group and save the
	# "file" output into an associative array
	for device in $(lvdisplay -c $vgname 2>/dev/null | cut -f1 -d:); do
	    filestr=$(file -Ls $device)
	    fs_type[$device]=$(get_fs_type "$filestr")
	    [[ $Debug -gt 0 ]] && echo +++++ fs_type\[$device\] set to \"${fs_type[$device]}\"

	    # Could this be the root device? If so, note it.
	    if [[ -z $root_dev && $device =~ root$ ]]; then
		root_dev=$device
		root_type="${fs_type[$device]}"
		[[ $Debug -gt 0 ]] && echo +++++ $device is root device
	    fi

	    # Do we need to change UUIDs (-A option selected)?
	    [[ $ChangeUUIDs -gt 0 ]] && change_vol_uuid $device
	done
    
	# Done processing the LVM volume. Don't fall through.
	continue
    fi

    # If we get here then we're dealing with some sort of basic
    # file system. Record the "file" output and change the UUID if -A flag
    fs_type[$ldev]=$(get_fs_type "$ptype")
    [[ $Debug -gt 0 ]] && echo +++++ fs_type\[$ldev\] set to \"${fs_type[$ldev]}\"
    [[ $ChangeUUIDs -gt 0 ]] && change_vol_uuid $ldev
done

#####
##### Step 3: Let's mount those things!
##### -- If we only have one file system, just mount it
##### -- Otherwise look for root file system, use fstab to mount the rest
#
if [[ ${#fs_type[@]} -eq 1 ]]; then     # Only one partition?
    devname=${!fs_type[*]}
    fstype="${fs_type[$devname]}"
    mount_device "$devname" "$TargetDir/files" "$fstype"
else
    # Root volume needs to be mounted first to get to fstab
    if [[ -n "$root_dev" ]]; then     # One of the LVM volumes looks like root
	mount_device $root_dev "$TargetDir/files" "$root_type"
    else
        # We have to mount partitions until we find the fstab file
	[[ $Debug -gt 0 ]] && echo +++++ Root device cannot be inferred. Doing this the hard way.
	mv "$CmdFile" "$CmdFile.sav"
	for device in "${!fs_type[@]}"; do
	    mount_device $device "$TargetDir/files" "${fs_type[$device]}"
	    if [[ -f "$TargetDir/files/etc/fstab" ]]; then
		[[ $Debug -gt 0 ]] && echo +++++ $device is root device
		break
	    fi
	    umount "$TargetDir/files" 2>/dev/null
	done

	tail -1 "$CmdFile" >> "$CmdFile.sav"
	mv "$CmdFile.sav" "$CmdFile"
    fi

    # By the end of the "if" statement above, the root file system should
    # be mounted. No fstab file means we can't proceeed.
    if [[ ! -f "$TargetDir/files/etc/fstab" ]]; then
	echo Unable to locate fstab file. Giving up.
	exit 255
    fi

    # Mount all of the other partitions based on the fstab file in the
    # root file system
    awk '!/^ *#/ && $3 ~ /^(vfat|ext|xfs|btrfs)/' "$TargetDir/files/etc/fstab" |
	while read -r device mountpt fstype options; do
	    [[ $mountpt == '/' ]] && continue             # root was already mounted above
	    mount_device $device "$TargetDir/files$mountpt" $fstype $options
	done
fi

# Now that everything is active and mounted, make E01s of each partition
# if -E was specified
[[ $MakeExports -gt 0 ]] || exit 0
mkdir -p "$TargetDir/exported"

declare -A exported
df --output=source,target | grep -F "$TargetDir" | sort -b -k2,2 |
    while read -r expdev expdir; do

	# Careful not to repeat exports when dealing with BTRFS subvols
	[[ ${exported[$expdev]} -eq 1 ]] && continue

	# Get directory name without the mount point
	dir_orig=$(echo $expdir | sed "s,$TargetDir/files/*,,")
	[[ -z "$dir_orig" ]] && dir_orig="root"

	# Convert slashes to underscores for the export file name
	dir_noslash=${dir_orig//\//_}
	base_file=$(basename "$TargetDir")

	[[ $Debug -gt 0 ]] && echo +++++ $expdev , $expdir , $dir_orig , $dir_noslash

	# Use ewfacquire to make compressed image of this partition
	# Capture the output in <file>.txt as well as sending it to
	# the terminal
	echo Exporting /$dir_orig file system \($expdev\)
	[[ $Debug -gt 0 ]] && echo +++++ ewfacquire -u -c fast -S $ChunkSize -t \"$TargetDir/exported/$base_file-$dir_noslash\" $expdev
	ewfacquire -u -c fast -S $ChunkSize -t "$TargetDir/exported/$base_file-$dir_noslash" $expdev | tee "$TargetDir/exported/$base_file-$dir_noslash.txt"
	exported[$expdev]=1
    done
