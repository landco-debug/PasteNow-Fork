#include <mach-o/dyld.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0) {
        fprintf(stderr, "PasteNow-Fork launcher: executable path too long\n");
        return 111;
    }

    char dirbuf[PATH_MAX];
    strlcpy(dirbuf, exe, sizeof(dirbuf));
    char *macos = dirname(dirbuf);

    char realbin[PATH_MAX];
    char dylib[PATH_MAX];
    snprintf(realbin, sizeof(realbin), "%s/PasteNow.real", macos);
    snprintf(dylib, sizeof(dylib), "%s/../Frameworks/PasteNowMultiPasteFix.dylib", macos);

    setenv("DYLD_INSERT_LIBRARIES", dylib, 1);
    setenv("PASTENOW_MULTIPASTE_FIX", "1", 1);

    argv[0] = realbin;
    execv(realbin, argv);
    perror("PasteNow-Fork launcher: execv");
    return 112;
}
