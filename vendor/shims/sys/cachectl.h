/* An empty <sys/cachectl.h> for building libmdbx with Zig.
 *
 * Zig's generic glibc headers ship a <sys/cachectl.h> that only MIPS has (it
 * includes <asm/cachectl.h>, absent elsewhere). libmdbx includes the header
 * whenever it exists, and needs it only on MIPS, where ZypherDB is not built. */
