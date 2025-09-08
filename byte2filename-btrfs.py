#!/usr/bin/python3
# Hal Pomeranz (hrpomeranz@gmail.com) - 2025-09-05
#
# Adapted from https://github.com/Hi-Angel/scripts/blob/master/btrfs-physical-to-logical-mapping.py
# and examples from https://github.com/knorrie/python-btrfs as noted below

import btrfs
import errno
import sys


def get_dev_extent(fs, devid, paddr, path):
    # we can't just simply search backwards... :|
    tree = btrfs.ctree.DEV_TREE_OBJECTID
    min_key = btrfs.ctree.Key(devid, btrfs.ctree.DEV_EXTENT_KEY, 0)
    max_key = btrfs.ctree.Key(devid, btrfs.ctree.DEV_EXTENT_KEY, paddr)
    for header, data in btrfs.ioctl.search_v2(fs.fd, tree, min_key, max_key):
        pass
    return btrfs.ctree.DevExtent(header, data)

# from https://github.com/knorrie/python-btrfs/blob/master/examples/show_default_subvolid.py
def get_fs_subvolid(fs):
    min_key = btrfs.ctree.Key(btrfs.ctree.ROOT_TREE_DIR_OBJECTID, btrfs.ctree.DIR_ITEM_KEY, 0)
    max_key = btrfs.ctree.Key(btrfs.ctree.ROOT_TREE_DIR_OBJECTID, btrfs.ctree.DIR_ITEM_KEY, btrfs.ctree.ULLONG_MAX)
    for header, data in btrfs.ioctl.search_v2(fs.fd, btrfs.ctree.ROOT_TREE_OBJECTID, min_key, max_key, nr_items=1):
        for dir_item in btrfs.ctree.DirItemList(header, data):
             return dir_item.location.objectid

# from https://github.com/knorrie/python-btrfs/blob/master/examples/show_subvolumes.py         
def get_subvol_path(fs, parent, subvol_id):
    min_key = btrfs.ctree.Key(parent, btrfs.ctree.ROOT_REF_KEY, 0)
    max_key = btrfs.ctree.Key(parent, btrfs.ctree.ROOT_REF_KEY + 1, 0) - 1
    for header, data in btrfs.ioctl.search_v2(fs.fd, btrfs.ctree.ROOT_TREE_OBJECTID, min_key, max_key):
        ref = btrfs.ctree.RootRef(header, data)
        if ref.tree != subvol_id:
            continue
        path = (btrfs.ioctl.ino_lookup(fs.fd, ref.parent_tree, ref.dirid).name_bytes +
                ref.name).decode()
        return path



def main():
    if len(sys.argv) != 3:
        print("Usage: {} <byte offset> <BTRFS mount point>".format(sys.argv[0]))
        exit(1)
    paddr = int(sys.argv[1])
    path = sys.argv[2]

    with btrfs.FileSystem(path) as fs:
        for device in fs.devices():
            devid = device.devid
            dev_extent = get_dev_extent(fs, devid, paddr, path)
            offset_into = paddr - dev_extent.paddr
            logaddr = dev_extent.chunk_offset + offset_into

            inodes = []
            try:
                inodes, bytes_missed = btrfs.ioctl.logical_to_ino_v2(fs.fd, logaddr)
            except IOError as e:
                if e.errno == errno.ENOENT:
                    print(str(logaddr) + "::")

            for inode in inodes:
                relpath = btrfs.ioctl.ino_lookup(fs.fd, treeid=inode.root, objectid=inode.inum)[1][:-1].decode('ASCII')
                svpath = get_subvol_path(fs, get_fs_subvolid(fs), inode.root)
                print(str(logaddr) + ':' + str(inode.inum) + ':/' + svpath + '/' +relpath)

if __name__ == '__main__':
    main()
