#pragma once

/* netgroup is unavailable on Windows; keep declaration for guarded call sites. */
int innetgr(const char *netgroup, const char *host, const char *user, const char *domain);
