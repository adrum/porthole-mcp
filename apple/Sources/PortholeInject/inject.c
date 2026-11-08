// Built into libPortholeInject.dylib, which porthole-mcp loads into a running
// Debug app (lldb attach + dlopen) or at launch (DYLD_INSERT_LIBRARIES).
#include <dlfcn.h>

__attribute__((constructor)) static void porthole_inject(void) {
    // RTLD_DEFAULT finds the app's own Porthole first when it already embeds
    // the harness, so the two never fight over one socket.
    void (*start)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "PortholeStart");
    if (start) start();
}
