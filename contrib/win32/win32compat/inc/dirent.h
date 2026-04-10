// direntry functions in Windows platform like Ubix/Linux
// opendir(), readdir(), closedir().
// 	NT_DIR * nt_opendir(char *name) ;
// 	struct nt_dirent *nt_readdir(NT_DIR *dirp);
// 	int nt_closedir(NT_DIR *dirp) ;

#ifndef __DIRENT_H__
#define __DIRENT_H__

/* Undef the mkdir macro before including direct.h so the SDK's one-arg
 * mkdir declaration doesn't conflict with our two-arg w32_mkdir macro
 * already installed by sys/stat.h. Restore it afterward. */
#ifdef mkdir
#  undef mkdir
#  include <direct.h>
#  define mkdir w32_mkdir
#else
#  include <direct.h>
#endif
#include <io.h>
#include <fcntl.h>
#include "..\misc_internal.h"

struct dirent {
	int            d_ino;       /* Inode number */
	char           d_name[PATH_MAX]; /* Null-terminated filename */
};

typedef struct DIR_ DIR;

DIR * opendir(const char*);
int closedir(DIR*);
struct dirent *readdir(void*);

#endif