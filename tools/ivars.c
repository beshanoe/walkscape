// ivars <framework-binary> <Class>
// Loads a system framework and prints the instance variables of a class and its superclasses:
// offset, name, type encoding. Used to find ivars such as PTBackgroundReplacement._transitionDuration.
#include <dlfcn.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: ivars <framework-binary> <Class>\n");
    return 2;
  }
  if (!dlopen(argv[1], RTLD_LAZY)) {
    fprintf(stderr, "dlopen failed: %s\n", dlerror());
    return 1;
  }
  Class cls = objc_getClass(argv[2]);
  if (!cls) {
    fprintf(stderr, "no class %s\n", argv[2]);
    return 1;
  }
  for (Class k = cls; k; k = class_getSuperclass(k)) {
    unsigned int n = 0;
    Ivar *iv = class_copyIvarList(k, &n);
    for (unsigned int i = 0; i < n; i++) printf("%td %s %s\n", ivar_getOffset(iv[i]), ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]));
    free(iv);
  }
  return 0;
}
