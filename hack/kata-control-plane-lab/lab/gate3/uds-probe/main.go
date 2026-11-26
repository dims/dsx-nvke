// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

// uds-probe is a small static tool for the gate 3 host socket test. It shows what a process
// sees for a Unix socket file and which errno connect() returns. It has three commands:
//
//	uds-probe stat <path>      lstat and statfs of the path
//	uds-probe connect <path>   socket(AF_UNIX, SOCK_STREAM) and connect(), with the errno
//	uds-probe listen <path>    bind and listen on the path, accept connections, print the peer
package main

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

func fsName(magic int64) string {
	names := map[int64]string{
		0x65735546: "fuse (virtio-fs in a Kata guest)",
		0x01021994: "tmpfs",
		0xEF53:     "ext2/ext3/ext4",
		0x794c7630: "overlayfs",
		0x58465342: "xfs",
		0x9123683E: "btrfs",
	}
	if n, ok := names[magic]; ok {
		return n
	}
	return "unknown"
}

func fileType(mode uint32) string {
	switch mode & syscall.S_IFMT {
	case syscall.S_IFSOCK:
		return "socket (S_IFSOCK)"
	case syscall.S_IFREG:
		return "regular file"
	case syscall.S_IFDIR:
		return "directory"
	case syscall.S_IFLNK:
		return "symlink"
	case syscall.S_IFCHR:
		return "character device"
	case syscall.S_IFBLK:
		return "block device"
	case syscall.S_IFIFO:
		return "fifo"
	}
	return "unknown"
}

func cmdStat(path string) int {
	var st syscall.Stat_t
	if err := syscall.Lstat(path, &st); err != nil {
		fmt.Printf("lstat %s: %v\n", path, describe(err))
		return 1
	}
	fmt.Printf("lstat %s: type=%s mode=%o uid=%d gid=%d dev=%d:%d ino=%d\n", path, fileType(st.Mode), st.Mode&0o7777, st.Uid, st.Gid,
		(st.Dev>>8)&0xfff, (st.Dev&0xff)|((st.Dev>>12)&0xfff00), st.Ino)
	var fs syscall.Statfs_t
	if err := syscall.Statfs(path, &fs); err != nil {
		fmt.Printf("statfs %s: %v\n", path, describe(err))
		return 1
	}
	fmt.Printf("statfs %s: f_type=0x%x (%s)\n", path, fs.Type, fsName(int64(fs.Type)))
	return 0
}

func describe(err error) string {
	var en syscall.Errno
	if errors.As(err, &en) {
		return fmt.Sprintf("errno=%d (%s) %q", int(en), errnoName(en), en.Error())
	}
	return err.Error()
}

func errnoName(en syscall.Errno) string {
	switch en {
	case syscall.ECONNREFUSED:
		return "ECONNREFUSED"
	case syscall.ENOENT:
		return "ENOENT"
	case syscall.EACCES:
		return "EACCES"
	case syscall.EPERM:
		return "EPERM"
	case syscall.ENOTSOCK:
		return "ENOTSOCK"
	case syscall.EOPNOTSUPP:
		return "EOPNOTSUPP"
	case syscall.ENXIO:
		return "ENXIO"
	case syscall.EADDRINUSE:
		return "EADDRINUSE"
	case syscall.EROFS:
		return "EROFS"
	case syscall.EPROTOTYPE:
		return "EPROTOTYPE"
	}
	return "other"
}

func cmdConnect(path string) int {
	fd, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		fmt.Printf("socket: %v\n", describe(err))
		return 1
	}
	defer syscall.Close(fd)
	if err := syscall.Connect(fd, &syscall.SockaddrUnix{Name: path}); err != nil {
		fmt.Printf("connect %s: FAILED %v\n", path, describe(err))
		return 1
	}
	fmt.Printf("connect %s: OK\n", path)
	if cred, err := syscall.GetsockoptUcred(fd, syscall.SOL_SOCKET, syscall.SO_PEERCRED); err == nil {
		fmt.Printf("peer of the socket (SO_PEERCRED): pid=%d uid=%d gid=%d\n", cred.Pid, cred.Uid, cred.Gid)
	}
	return 0
}

func cmdListen(path string) int {
	fd, err := syscall.Socket(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		fmt.Printf("socket: %v\n", describe(err))
		return 1
	}
	if err := syscall.Bind(fd, &syscall.SockaddrUnix{Name: path}); err != nil {
		fmt.Printf("bind %s: FAILED %v\n", path, describe(err))
		return 1
	}
	if err := syscall.Listen(fd, 8); err != nil {
		fmt.Printf("listen %s: FAILED %v\n", path, describe(err))
		return 1
	}
	fmt.Printf("listen %s: OK, pid %d\n", path, os.Getpid())
	for {
		nfd, _, err := syscall.Accept(fd)
		if err != nil {
			fmt.Printf("accept: %v\n", describe(err))
			return 1
		}
		if cred, err := syscall.GetsockoptUcred(nfd, syscall.SOL_SOCKET, syscall.SO_PEERCRED); err == nil {
			fmt.Printf("accepted a connection: peer pid=%d uid=%d gid=%d\n", cred.Pid, cred.Uid, cred.Gid)
		} else {
			fmt.Printf("accepted a connection\n")
		}
		syscall.Close(nfd)
	}
}

func main() {
	if len(os.Args) != 3 {
		fmt.Println("usage: uds-probe stat|connect|listen <path>")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "stat":
		os.Exit(cmdStat(os.Args[2]))
	case "connect":
		os.Exit(cmdConnect(os.Args[2]))
	case "listen":
		os.Exit(cmdListen(os.Args[2]))
	}
	fmt.Println("usage: uds-probe stat|connect|listen <path>")
	os.Exit(2)
}
