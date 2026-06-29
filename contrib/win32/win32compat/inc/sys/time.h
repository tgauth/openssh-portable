#pragma once
#include <sys\utime.h>

#define utimbuf _utimbuf
#define utimes w32_utimes

#define timeval w32_timeval
struct timeval
{
    long long    tv_sec;
    long         tv_usec;
};

struct itimerval {
	struct timeval it_interval; /* Timer interval */
	struct timeval it_value;    /* Current value */
};

#define ITIMER_REAL 0

#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME 0
#endif
#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 1
#endif

typedef int clockid_t;

int usleep(unsigned int);
int gettimeofday(struct timeval *, void *);
int nanosleep(const struct timespec *, struct timespec *);
int clock_gettime(clockid_t, struct timespec *);
int w32_utimes(const char *, struct timeval *);