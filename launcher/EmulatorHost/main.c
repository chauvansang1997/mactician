#import <AppKit/AppKit.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void prepare_application_identity(void) {
    @autoreleasepool {
        // Register the bundle before exec so Launch Services keeps its Dock icon
        // instead of rebinding the process to qemu-system-aarch64.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSString *icon_path = [[NSBundle mainBundle] pathForResource:@"EmulatorIcon" ofType:@"icns"];
        if (icon_path != nil) {
            NSImage *icon = [[NSImage alloc] initWithContentsOfFile:icon_path];
            if (icon != nil) {
                [NSApp setApplicationIconImage:icon];
            }
            [icon release];
        }
    }
}

int main(int argc, char *argv[]) {
    const char *emulator = getenv("TFT_EMULATOR");
    if (emulator == NULL || emulator[0] == '\0' || access(emulator, X_OK) != 0) {
        fputs("Mactician Game Host could not find its Android Emulator executable.\n", stderr);
        return EXIT_FAILURE;
    }

    prepare_application_identity();
    argv[0] = (char *)emulator;
    execv(emulator, argv);

    fprintf(stderr, "Mactician Game Host could not start Android Emulator: %s\n", strerror(errno));
    return EXIT_FAILURE;
}
