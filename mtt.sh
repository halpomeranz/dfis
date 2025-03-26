#!/bin/bash
# Hal Pomeranz (hrpomeranz@gmail.com) -- 2025-03-26
# Distributed under the Creative Commons Attribution-ShareAlike 4.0 license (CC BY-SA 4.0)
# Version: 1.1.0

usage() {
    cat <<EOM
Automatically mount image files (libewf-tools is required for E01s). 
Use -U option to unmount what was previously mounted.

Usage: $0 [-D] [-E -S chunksize] [-d mountpoint] image
       $0 [-D] -U mountpoint

    -D       Output debugging details

    -d dir    Specify mounting point (default is "mount")
    -E	      Export E01s of partitions from image
    -S size   Specify the max segment size for EO1 exports (in bytes)

    -U dir    Unmount everything on dir
EOM
    exit 1;
}

# Unmounts everything, including deactivating volume groups and detatching loopback devices
# Ends program when finished
#
do_unmount() {
    declare -A found_vgs
    declare -A loop_devs

    # See bottom of loop for inputs
    while read dev dir; do
	umount "$dir"
	[[ $Debug -gt 0 ]] && echo +++++ unmounted \"$dir\" \(device is \"$dev\"\)

	# Capture unique loopback devices ("/dev/loop0" not "/dev/loop0p1")
	if [[ $dev =~ ^/dev/loop[0-9] ]]; then
	    maindev=$(echo $dev | sed 's,\(/dev/loop[0-9]*\)p[0-9]*,\1,')
	    loop_devs[$maindev]=1
	    [[ $Debug -gt 0 ]] && echo +++++ loop device $maindev
	fi

	# Is this device part of a volume group? Capture all unique volume group names
	vgname=$(lvdisplay -c $dev 2>/dev/null | cut -f2 -d:)
	if [[ -n $vgname ]]; then
	    found_vgs[$vgname]=1
	    [[ $Debug -gt 0 ]] && echo +++++ volume group name $vgname
	fi
    done< <(df --output=source,target | grep -F "$UnmountDir" | sort -b -k2,2 -r)

    # "vgchange -a n" to deactivate all volume groups
    for vgname in ${!found_vgs[@]}; do
	vgchange -a n $vgname >/dev/null 2>&1
	[[ $Debug -gt 0 ]] && echo +++++ vgchange -a n $vgname
    done

    # "losetup -d" on all loopback devices
    for dev in ${!loop_devs[@]}; do
	losetup -d $dev 2>/dev/null 
	[[ $Debug -gt 0 ]] && echo +++++ losetup -d $dev
    done

    # unmount to stop any ewfmount processes that are running
    if [[ -f "$UnmountDir/img/ewf1" ]]; then
	umount "$UnmountDir/img"
	[[ $Debug -gt 0 ]] && echo +++++ unmounting \"$UnmountDir/img\"
    fi

    exit 0
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

    if [[ "$fstype" == 'btrfs' || "$fstype" =~ BTRFS ]]; then
	extra=',noexec,norecovery'
	[[ $options =~ subvol= ]] && extra="$extra,$options"
    elif [[ "$fstype" =~ ext[34] ]]; then
	extra=',noexec,noload -t ext4'
    elif [[ "$fstype" =~ ext2 ]]; then
	extra=',noexec'
    elif [[ "$fstype" == 'xfs' || "$fstype" =~ XFS ]]; then
	extra=',noexec,norecovery'
    elif [[ "$fstype" == 'vfat' || "$fstype" =~ FAT ]]; then
	extra=
    elif [[ "$fstype" =~ (swap|DOS/MBR) ]]; then
	return
    else
	echo $device: $fstype
	echo I do not know what this is. Skipping.
	return
    fi
	    
    mount -o ro$extra $device "$targdir"
    echo mount -o ro$extra $device \"$targdir\" >>"$CmdFile"
    [[ $Debug -gt 0 ]] && echo +++++ mount -o ro$extra $device \"$targdir\"
}


############# Program starts here ##############################################

TargetDir='mount'
Debug=0
MakeExports=0
ChunkSize=4294967296                 # 4GB
UnmountDir=
while getopts "d:DES:U:" opts; do
    case $opts in
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
        *) usage
           ;;
    esac
done

# do_unmount exits program once unmounting is finished
[[ -n "$UnmountDir" ]] && do_unmount

shift $(($OPTIND-1))
Image=$1

if [[ $Debug -gt 0 ]]; then
    cat <<EOM
+++++ Image: $Image
+++++ Dir: $TargetDir
+++++ Exports: $MakeExports
+++++ Debug: $Debug
EOM
fi

# Make absolute paths so that commands in MOUNTING file will work anywhere
# Supplied image file must be readable
[[ "$Image" =~ ^/ ]] || Image=$(/bin/pwd)"/$Image"
[[ -r "$Image" ]] || usage

[[ "$TargetDir" =~ ^/ ]] || TargetDir=$(/bin/pwd)"/$TargetDir"
if [[ ! -d "$TargetDir" ]]; then
    echo Making $TargetDir, hope that is OK
    mkdir -p "$TargetDir" || usage
fi

# We will manually write a copy of all commands used to mount the image to this file
CmdFile="$TargetDir/MOUNTING"
cp /dev/null "$CmdFile"
mkdir -p "$TargetDir/files"
echo mkdir -p \"$TargetDir/files\" >>"$CmdFile"


# OK, time to start mounthing things!
#
# Step 1 -- Is this an E01? If so, call ewfmount
curr_image="$Image"
curr_data=$(file -Ls "$Image")
if [[ "$curr_data" =~ EWF ]]; then
    mkdir -p "$TargetDir/img"
    im_dir=$(dirname "$curr_image")
    im_name=$(basename "$curr_image")
    (cd "$im_dir"; ewfmount "$im_name" "$TargetDir/img") >/dev/null 2>&1
    [[ $Debug -gt 0 ]] && echo +++++ \(cd \"$im_dir\"\; ewfmount \"$im_name\" \"$TargetDir/img\"\)

    # No ewf1 file? Can't proceed
    if [[ ! -r "$TargetDir/img/ewf1" ]]; then
	echo ewfmount failed, aborting
	exit 255
    fi

    cat <<EOM >>"$CmdFile"
mkdir -p "$TargetDir/img"
(cd "$im_dir"; ewfmount "$im_name" "$TargetDir/img")

EOM
    # Next step will look at the ewf1 raw image
    curr_image="$TargetDir/img/ewf1"
    curr_data=$(file -Ls "$TargetDir/img/ewf1")
fi


# Step 2 -- Is this a full disk image?
if [[ "$curr_data" =~ DOS/MBR ]]; then
    declare -A fs_type

    # "losetup -P" is magical:
    #   -- sets up loop devices to all partitions (e.g. /dev/loop0p1)
    #   -- runs vgscan to find LVM groups (but does not activate them)
    #
    loop_device=$(losetup --show -rfP "$curr_image")
    echo -e losetup -rfP \"$curr_image\"\\n >>"$CmdFile"
    [[ $Debug -gt 0 ]] && echo +++++ Loopback device is $loop_device

    # Now iterate over each partition
    root_dev=
    root_type=
    for part in ${loop_device}p*; do
	ptype=$(file -Ls $part)

	# Skip if partition table or swap
	[[ "$ptype" =~ (DOS/MBR|swap) ]] && continue

	# Deal with LVM volumes
	if [[ "$ptype" =~ LVM2 ]]; then
	    # Get the volume group name
	    vgname=$(pvdisplay -c $part 2>/dev/null | cut -f2 -d:)

	    # Are we dealing with a duplicate volume name? Bail!
	    if [[ $(vgdisplay -c 2>/dev/null | cut -f1 -d: | grep -F "$vgname" | wc -l) -gt 1 ]]; then
		echo \*\*\* MAJOR ISSUE\!
		echo \*\*\* Looks like there is already a volume group with the name \"$vgname\" mounted here.
		echo \*\*\* We cannot mount this image until the other image is unmounted. Sorry\!
		losetup -d $loop_device
		UnmountDir=$TargetDir
		do_unmount                # do_unmount() exits the program
	    fi

	    # Need to activate the volume group ("vgchange -a y")
	    vgchange -a y $vgname >/dev/null 2>&1
	    echo -e vgchange -a y $vgname\\n >>"$CmdFile"

	    # Now look at each device in the volume group and save the "file" output into an associative array
	    for device in $(lvdisplay -c $vgname | cut -f1 -d:); do
		fs_type[$device]=$(file -Ls $device)
		[[ $Debug -gt 0 ]] && echo +++++ fs_type\[$device\] set to \"${fs_type[$device]}\"

		# Could this be the root device? If so, note it.
		if [[ -z $root_dev && $device =~ root$ ]]; then
		    root_dev=$device
		    root_type="${fs_type[$device]}"
		    [[ $Debug -gt 0 ]] && echo +++++ $device is root device
		fi
	    done

	    # Done processing the LVM volume. Don't fall through.
	    continue
	fi

	# If we get here then we're dealing with some sort of basic file system. Record the "file" output.
	fs_type[$part]="$ptype"
	[[ $Debug -gt 0 ]] && echo +++++ fs_type\[$part\] set to \"${fs_type[$part]}\"
    done

    # Root volume needs to be mounted first. 
    if [[ -n "$root_dev" ]]; then               # One of the LVM volumes looked like the root file system
	mount_device $root_dev "$TargetDir/files" "$root_type"
    else
	if [[ ${#fs_type[@]} -eq 1 ]]; then     # Only one partition? It's got to be the root file system
	    root_dev=${!fs_type[@]}
	    root_type="${fs_type[$root_dev]}"
	    mount_device $root_dev "$TargetDir/files" "$root_type"
	else                                    # We have to mount partitions until we find the fstab file
	    [[ $Debug -gt 0 ]] && echo +++++ Root device cannot be inferred. Doing this the hard way.
	    mv "$CmdFile" "$CmdFile.sav"
	    for device in ${!fs_type[@]}; do
		mount_device $device "$TargetDir/files" "${fs_type[$device]}"
		if [[ -f "$TargetDir/files/etc/fstab" ]]; then
		    [[ $Debug -gt 0 ]] && echo +++++ $device is root device
		    break
		fi
		umount "$TargetDir/files"
	    done
	    tail -1 "$CmdFile" >> "$CmdFile.sav"
	    mv "$CmdFile.sav" "$CmdFile"
	fi
    fi

    # By the end of the "if" statement above, the root file system should be mounted
    # No fstab file means we can't proceeed
    if [[ ! -f "$TargetDir/files/etc/fstab" ]]; then
	echo Unable to locate fstab file. Giving up.
	exit 255
    fi

    # Mount all of the other partitions based on the fstab file in the root file system
    awk '!/^ *#/ && $3 ~ /^(vfat|ext|xfs|btrfs)/' "$TargetDir/files/etc/fstab" |
	while read device mountpt fstype options; do
	    [[ $mountpt == '/' ]] && continue             # root was already mounted above
	    mount_device $device "$TargetDir/files$mountpt" $fstype $options
	done

    # Now that everything is active and mounted, make E01s of each partition if -E was specified
    if [[ $MakeExports -eq 1 ]]; then
	mkdir -p "$TargetDir/exported"

	declare -A exported
	df --output=source,target | grep -F "$TargetDir" | sort -b -k2,2 |
	    while read expdev expdir; do

		# Be careful not to repeat exports when dealing with BTRFS subvols
		[[ ${exported[$expdev]} -eq 1 ]] && continue

		# Get directory name without the mount point
		dir_orig=$(echo $expdir | sed "s,$TargetDir/files/*,,")
		[[ -z "$dir_orig" ]] && dir_orig="root"

		# Convert slashes to underscores to be used in the export file name
		dir_noslash=$(echo $dir_orig | sed 's,/,_,g');
		base_file=$(basename "$Image")

		[[ $Debug -gt 0 ]] && echo +++++ $expdev , $expdir , $dir_orig , $dir_noslash

		# Use ewfacquire to make compressed image of this partition
		# Capture the output in <file>.txt as well as sending it to the terminal
		echo Exporting /$dir_orig file system \($expdev\)
		[[ $Debug -gt 0 ]] && echo +++++ ewfacquire -u -c fast -S $ChunkSize -t \"$TargetDir/exported/$base_file-$dir_noslash\" $expdev
		ewfacquire -u -c fast -S $ChunkSize -t "$TargetDir/exported/$base_file-$dir_noslash" $expdev |
		    tee "$TargetDir/exported/$base_file-$dir_noslash.txt"
		exported[$expdev]=1
	    done
    fi

    # Done dealing with this full disk image. Don't fall through.
    exit 0
fi

# If we get here, it must be a logical image. Mount it and be done.
# No point in exporting this since it's already a single partition image.
mount_device "$curr_image" "$TargetDir/files" "$curr_data"
