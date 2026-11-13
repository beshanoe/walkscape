// objcdis: disassemble an ObjC method from a system framework (dyld shared cache), in-process.
// usage: objcdis <fw-binary> [<fw-binary>...] -- '-[Class selector]' [maxInsns]
//        CLS=<Class> objcdis <fw-binary> ... -- @0xADDRESS [maxInsns]
// Uses LLVM's C disassembler from Xcode's libLTO (env LIBLTO overrides the path set at build time)
// and annotates objc_msgSend stubs (selector names), ADRP+ADD / ADRP+LDR targets (C strings,
// CFStrings, selectors, classes), call targets (dladdr) and ivar offsets loaded with LDRSW (names
// from the method's class, or from CLS in @address mode). Stops at the last return/tail call
// after the furthest forward branch; maxInsns (default 800) caps it.
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef DEFAULT_LIBLTO
#define DEFAULT_LIBLTO "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libLTO.dylib"
#endif

typedef void *LLVMDisasmContextRef;
typedef LLVMDisasmContextRef (*CreateDisasmCPUFeaturesFn)(const char *triple, const char *cpu, const char *features, void *info,
                                                          int tagType, void *getOpInfo, void *symbolLookup);
typedef size_t (*DisasmInsnFn)(LLVMDisasmContextRef, uint8_t *, uint64_t, uint64_t, char *, size_t);
typedef void (*InitFn)(void);

static const uint64_t PTR_MASK = 0x00007FFFFFFFFFFFull;

static int safe_read(uint64_t addr, void *out, size_t n) {
  mach_vm_size_t got = 0;
  kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)addr, n, (mach_vm_address_t)out, &got);
  return kr == KERN_SUCCESS && got == n;
}

static int read_cstr(uint64_t addr, char *buf, size_t cap) {
  if (!addr) return 0;
  size_t i = 0;
  for (; i + 1 < cap; i++) {
    char c;
    if (!safe_read(addr + i, &c, 1)) return 0;
    if (c == 0) break;
    if ((unsigned char)c < 0x20 && c != '\n' && c != '\t') return 0;
    buf[i] = c;
  }
  buf[i] = 0;
  return i >= 2;
}

static Class g_cls;
static Class *g_classes;
static unsigned int g_nclasses;
static int cmp_ptr(const void *a, const void *b) {
  uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;
  return x < y ? -1 : x > y;
}
static const char *class_name_if_class(uint64_t p) {
  uintptr_t key = (uintptr_t)p;
  Class *hit = bsearch(&key, g_classes, g_nclasses, sizeof(Class), cmp_ptr);
  return hit ? class_getName(*hit) : NULL;
}

// Describe what lives at addr: a class, a selector/C string, a CFString, or a symbol.
static void describe(uint64_t addr, char *out, size_t cap) {
  out[0] = 0;
  char s[200];
  const char *cn = class_name_if_class(addr);
  if (cn) {
    snprintf(out, cap, "class %s", cn);
    return;
  }
  if (read_cstr(addr, s, sizeof s)) {
    snprintf(out, cap, "\"%s\"", s);
    return;
  }
  // CFString constant: {isa, flags, cstr, len}
  uint64_t cf[4];
  if (safe_read(addr, cf, sizeof cf) && cf[3] > 0 && cf[3] < 4096 && read_cstr(cf[2] & PTR_MASK, s, sizeof s)) {
    snprintf(out, cap, "@\"%s\"", s);
    return;
  }
  // pointer to something (selref, classref, GOT)
  uint64_t p;
  if (safe_read(addr, &p, 8)) {
    p &= PTR_MASK;
    cn = class_name_if_class(p);
    if (cn) {
      snprintf(out, cap, "&class %s", cn);
      return;
    }
    if (read_cstr(p, s, sizeof s)) {
      snprintf(out, cap, "&\"%s\"", s);
      return;
    }
    Dl_info di;
    if (p && dladdr((void *)p, &di) && di.dli_sname) {
      snprintf(out, cap, "&%s", di.dli_sname);
      return;
    }
  }
  Dl_info di;
  if (dladdr((void *)addr, &di) && di.dli_sname) snprintf(out, cap, "%s+%llu", di.dli_sname, (unsigned long long)(addr - (uint64_t)di.dli_saddr));
}

static int64_t sext(uint64_t v, int bits) { return (int64_t)(v << (64 - bits)) >> (64 - bits); }

// Resolve a call target: objc_msgSend selector stub, import stub, or symbol.
static void describe_call(uint64_t target, char *out, size_t cap) {
  uint32_t ins[4];
  out[0] = 0;
  if (safe_read(target, ins, sizeof ins)) {
    // objc stub: adrp x1, page ; ldr x1, [x1, #off] ; ...
    if ((ins[0] & 0x9F00001F) == 0x90000001 && (ins[1] & 0xFFC003FF) == 0xF9400021) {
      uint64_t page = (target & ~0xFFFull) + (uint64_t)(sext(((ins[0] >> 29) & 3) | (((ins[0] >> 5) & 0x7FFFF) << 2), 21) << 12);
      uint64_t selref = page + ((ins[1] >> 10) & 0xFFF) * 8;
      uint64_t sel;
      char s[200];
      if (safe_read(selref, &sel, 8) && read_cstr(sel & PTR_MASK, s, sizeof s)) {
        snprintf(out, cap, "objc_msgSend$%s", s);
        return;
      }
    }
    // shared-cache optimized stub: adrp x1, page ; add x1, x1, #off (selector string directly)
    if ((ins[0] & 0x9F00001F) == 0x90000001 && (ins[1] & 0xFFC003FF) == 0x91000021) {
      uint64_t page = (target & ~0xFFFull) + (uint64_t)(sext(((ins[0] >> 29) & 3) | (((ins[0] >> 5) & 0x7FFFF) << 2), 21) << 12);
      char s[200];
      if (read_cstr(page + ((ins[1] >> 10) & 0xFFF), s, sizeof s)) {
        snprintf(out, cap, "objc_msgSend$%s", s);
        return;
      }
    }
    // import stub: adrp x16, page ; add x16, x16, #off ; ldr x16, [x16] ; braa  (or adrp; ldr x16,[x16,#off]; br)
    if ((ins[0] & 0x9F00001E) == 0x90000010) {
      uint32_t r = ins[0] & 0x1F;
      uint64_t page = (target & ~0xFFFull) + (uint64_t)(sext(((ins[0] >> 29) & 3) | (((ins[0] >> 5) & 0x7FFFF) << 2), 21) << 12);
      uint64_t slot = 0;
      if ((ins[1] & 0xFFC00000) == 0x91000000 && (ins[1] & 0x1F) == r) slot = page + ((ins[1] >> 10) & 0xFFF);
      else if ((ins[1] & 0xFFC00000) == 0xF9400000) slot = page + ((ins[1] >> 10) & 0xFFF) * 8;
      uint64_t fn;
      Dl_info di;
      if (slot && safe_read(slot, &fn, 8) && dladdr((void *)(fn & PTR_MASK), &di) && di.dli_sname) {
        snprintf(out, cap, "%s", di.dli_sname);
        return;
      }
    }
  }
  Dl_info di;
  if (dladdr((void *)target, &di) && di.dli_sname) snprintf(out, cap, "%s+%llu", di.dli_sname, (unsigned long long)(target - (uint64_t)di.dli_saddr));
}

int main(int argc, char **argv) {
  int i = 1;
  for (; i < argc && strcmp(argv[i], "--") != 0; i++) {
    if (!dlopen(argv[i], RTLD_LAZY)) fprintf(stderr, "dlopen %s: %s\n", argv[i], dlerror());
  }
  if (i + 1 >= argc) {
    fprintf(stderr, "usage: objcdis <fw>... -- '-[Class sel]'|@0xADDR [maxInsns]\n");
    return 2;
  }
  const char *spec = argv[i + 1];
  int maxInsns = i + 2 < argc ? atoi(argv[i + 2]) : 800;

  g_classes = objc_copyClassList(&g_nclasses);
  qsort(g_classes, g_nclasses, sizeof(Class), cmp_ptr);

  uint64_t start = 0;
  if (spec[0] == '@') {
    start = strtoull(spec + 1, NULL, 16);
    if (getenv("CLS")) g_cls = objc_getClass(getenv("CLS"));
  } else {
    char cls[256], sel[512];
    char kind = spec[0];
    if (sscanf(spec + 2, "%255s %511[^]]", cls, sel) != 2) {
      fprintf(stderr, "bad spec\n");
      return 2;
    }
    Class c = objc_getClass(cls);
    g_cls = c;
    if (!c) {
      fprintf(stderr, "no class %s\n", cls);
      return 1;
    }
    Method m = kind == '+' ? class_getClassMethod(c, sel_registerName(sel)) : class_getInstanceMethod(c, sel_registerName(sel));
    if (!m) {
      fprintf(stderr, "no method %s\n", spec);
      return 1;
    }
    start = (uint64_t)method_getImplementation(m) & PTR_MASK;
    printf("; %s  types=%s  imp=0x%llx\n", spec, method_getTypeEncoding(m), (unsigned long long)start);
  }

  const char *ltoPath = getenv("LIBLTO") ? getenv("LIBLTO") : DEFAULT_LIBLTO;
  void *lto = dlopen(ltoPath, RTLD_NOW);
  if (!lto) {
    fprintf(stderr, "libLTO: %s\n", dlerror());
    return 1;
  }
  InitFn init = (InitFn)dlsym(lto, "lto_initialize_disassembler");
  CreateDisasmCPUFeaturesFn create = (CreateDisasmCPUFeaturesFn)dlsym(lto, "LLVMCreateDisasmCPUFeatures");
  if (init) init();
  LLVMDisasmContextRef dc = create ? create("arm64e-apple-macos", "apple-m1", "+pauth", NULL, 0, NULL, NULL) : NULL;
  if (!dc) {
    fprintf(stderr, "LLVMCreateDisasm failed\n");
    return 1;
  }
  DisasmInsnFn dis = (DisasmInsnFn)dlsym(lto, "LLVMDisasmInstruction");

  uint64_t regs[32] = {0};
  int known[32] = {0};
  uint64_t maxTarget = start;
  uint64_t pc = start;
  for (int n = 0; n < maxInsns; n++, pc += 4) {
    uint32_t w;
    if (!safe_read(pc, &w, 4)) break;
    char text[256] = "";
    dis(dc, (uint8_t *)&w, 4, pc, text, sizeof text);
    char note[400] = "";
    int rd = w & 0x1F, rn = (w >> 5) & 0x1F;
    if ((w & 0x9F000000) == 0x90000000) {  // ADRP
      regs[rd] = (pc & ~0xFFFull) + (uint64_t)(sext(((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2), 21) << 12);
      known[rd] = 1;
    } else if ((w & 0xFF800000) == 0x91000000 && known[rn]) {  // ADD Xd, Xn, #imm
      uint64_t v = regs[rn] + (((w >> 10) & 0xFFF) << (((w >> 22) & 1) ? 12 : 0));
      describe(v, note, sizeof note);
      regs[rd] = v;
      known[rd] = 1;
    } else if ((w & 0xFFC00000) == 0xF9400000 && known[rn]) {  // LDR Xt, [Xn, #imm]
      uint64_t a = regs[rn] + ((w >> 10) & 0xFFF) * 8;
      describe(a, note, sizeof note);
      known[rd] = 0;
    } else if ((w & 0xFFC00000) == 0xB9800000 && known[rn] && g_cls) {  // LDRSW Xt, [Xn, #imm] (ivar offset)
      int32_t off;
      uint64_t a = regs[rn] + ((w >> 10) & 0xFFF) * 4;
      if (safe_read(a, &off, 4)) {
        for (Class k = g_cls; k && !note[0]; k = class_getSuperclass(k)) {
          unsigned int ni = 0;
          Ivar *iv = class_copyIvarList(k, &ni);
          for (unsigned int j = 0; j < ni; j++)
            if (ivar_getOffset(iv[j]) == off) { snprintf(note, sizeof note, "ivar %s (%s)", ivar_getName(iv[j]), ivar_getTypeEncoding(iv[j])); break; }
          free(iv);
        }
      }
      known[rd] = 0;
    } else if ((w & 0x7C000000) == 0x14000000) {  // B / BL
      uint64_t t = pc + (uint64_t)(sext(w & 0x3FFFFFF, 26) * 4);
      int isCall = (w >> 31) & 1;
      if (isCall || t < start || t > pc + 0x4000) describe_call(t, note, sizeof note);
      else if (t > maxTarget) maxTarget = t;
      for (int r = 0; r < 19; r++) known[r] = 0;
    } else if ((w & 0xFF000010) == 0x54000000 || (w & 0x7E000000) == 0x34000000 || (w & 0x7E000000) == 0x36000000) {
      // B.cond / CBZ / CBNZ / TBZ / TBNZ: track forward targets
      int64_t off = ((w & 0x7E000000) == 0x36000000) ? sext((w >> 5) & 0x3FFF, 14) * 4 : sext((w >> 5) & 0x7FFFF, 19) * 4;
      uint64_t t = pc + (uint64_t)off;
      if (t > maxTarget) maxTarget = t;
    } else if ((w & 0xFFE0FFE0) == 0xAA0003E0) {  // MOV Xd, Xm
      int rm = (w >> 16) & 0x1F;
      regs[rd] = regs[rm];
      known[rd] = known[rm];
    } else {
      if (rd < 32 && (w & 0x1F000000) != 0x1F000000) known[rd] = 0;
    }
    printf("%llx:%s%s%s\n", (unsigned long long)pc, text, note[0] ? "    ; " : "", note);
    int isRet = (w & 0xFFFFFC1F) == 0xD65F0000 || w == 0xD65F0BFF || w == 0xD65F0FFF;
    int isTail = (w & 0xFC000000) == 0x14000000 || (w & 0xFFFFF800) == 0xD61F0800 || (w & 0xFFFFFC1F) == 0xD61F0000;
    if ((isRet || isTail) && pc >= maxTarget) break;
  }
  return 0;
}
