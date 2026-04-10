#include "crtheaders.h"
#ifdef TIME_H
#include TIME_H
#else
#include <time.h>
#endif

#define localtime w32_localtime
#define ctime w32_ctime

struct tm *localtime_r(const time_t *, struct tm *);
struct tm *w32_localtime(const time_t* sourceTime);
char *w32_ctime(const time_t* sourceTime);
