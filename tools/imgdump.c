// imgdump <framework-binary-path> [classes|strings|methods <Class>]
// Loads a system framework (from the dyld shared cache) and dumps its ObjC class
// names or C strings, read from the loaded image in memory.
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *g_image_name;
static const struct mach_header_64 *find_image(const char *path) {
  const char *base = strrchr(path, '/');
  base = base ? base : path;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *name = _dyld_get_image_name(i);
    const char *b = strrchr(name, '/');
    if (b && strcmp(b, base) == 0 && strstr(name, "/System/")) {
      g_image_name = name;
      return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
  }
  return NULL;
}

static void dump_strings(const struct mach_header_64 *mh, const char *seg, const char *sect) {
  unsigned long size = 0;
  const char *p = (const char *)getsectiondata(mh, seg, sect, &size);
  if (!p) return;
  const char *end = p + size;
  while (p < end) {
    size_t n = strnlen(p, (size_t)(end - p));
    if (n >= 4) printf("%.*s\n", (int)n, p);
    p += n + 1;
  }
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: imgdump <path> classes|strings|methods <Class>\n");
    return 2;
  }
  if (!dlopen(argv[1], RTLD_LAZY)) {
    fprintf(stderr, "dlopen failed: %s\n", dlerror());
    return 1;
  }
  const struct mach_header_64 *mh = find_image(argv[1]);
  if (!mh) {
    fprintf(stderr, "image not found after dlopen\n");
    return 1;
  }
  if (strcmp(argv[2], "classes") == 0) {
    unsigned int n = 0;
    const char **names = objc_copyClassNamesForImage(g_image_name, &n);
    for (unsigned int i = 0; i < n; i++) printf("%s\n", names[i]);
    free(names);
  } else if (strcmp(argv[2], "strings") == 0) {
    dump_strings(mh, "__TEXT", "__cstring");
    dump_strings(mh, "__TEXT", "__oslogstring");
  } else if (strcmp(argv[2], "methods") == 0 && argc > 3) {
    Class c = objc_getClass(argv[3]);
    if (!c) return 1;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    for (unsigned int i = 0; i < n; i++) printf("-%s\n", sel_getName(method_getName(ms[i])));
    free(ms);
    ms = class_copyMethodList(object_getClass((id)c), &n);
    for (unsigned int i = 0; i < n; i++) printf("+%s\n", sel_getName(method_getName(ms[i])));
    free(ms);
    unsigned int pn = 0;
    objc_property_t *props = class_copyPropertyList(c, &pn);
    for (unsigned int i = 0; i < pn; i++) printf("@%s %s\n", property_getName(props[i]), property_getAttributes(props[i]));
    free(props);
  }
  return 0;
}
