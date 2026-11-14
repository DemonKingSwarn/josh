libc :: #library,system "libc";

// POSIX does not bind these (they are in libutil-ish headers on glibc).
posix_openpt :: (oflag: s32) -> s32 #foreign libc;
grantpt      :: (fd: s32) -> s32 #foreign libc;
unlockpt     :: (fd: s32) -> s32 #foreign libc;
ptsname      :: (fd: s32) -> *u8 #foreign libc;
strlen       :: (s: *u8) -> u64 #foreign libc;
malloc       :: (size: u64) -> *u8 #foreign libc;
free         :: (ptr: *u8) -> void #foreign libc;
memcpy       :: (dst: *void, src: *void, n: u64) -> *void #foreign libc;

