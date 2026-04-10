#pragma once

/*
 * Minimal ifaddrs declarations for builds where HAVE_IFADDRS_H is unset.
 * Call sites are typically gated by HAVE_IFADDRS_H.
 */
struct ifaddrs {
	struct ifaddrs *ifa_next;
	char *ifa_name;
	unsigned int ifa_flags;
	void *ifa_addr;
	void *ifa_netmask;
	void *ifa_dstaddr;
	void *ifa_data;
};

int getifaddrs(struct ifaddrs **ifap);
void freeifaddrs(struct ifaddrs *ifa);
