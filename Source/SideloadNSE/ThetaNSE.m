/*
 * Tiny sideload helper loaded into InstagramNotificationExtension.
 * Full Theta.dylib is too large for the NSE jetsam cap and fishhook cannot
 * patch LC_DYLD_CHAINED_FIXUPS, so this dylib only:
 *   - MSHookFunction SecItem* (remap Meta keychain groups onto the host app's)
 *   - Swizzle FB/UIC keychain accessGroup + app-group containerURL
 */

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <stdio.h>
#import <string.h>
#import <stdarg.h>
#import "fishhook.h"
#import "Source/SideloadNSE/ThetaHPKEKeyFile.h"

static NSString *gKeychainGroup;
static NSString *gWildcardKeychainGroup;
static int gSecLogLeft = 16;
static NSURL *gFakeGroupRoot;
static OSStatus (*real_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*real_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*real_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*real_SecItemDelete)(CFDictionaryRef);

static NSURL *(*orig_containerURL)(id, SEL, NSString *);
static BOOL (*orig_mkdir)(id, SEL, NSString *, BOOL, NSDictionary *, NSError **);
static NSString *(*orig_fbAccessGroup)(id, SEL);
static NSString *(*orig_uicAccessGroup)(id, SEL);
static id (*orig_lsInit4)(id, SEL, id, id, id, BOOL);
static id (*orig_uicStore)(id, SEL, id, id);
static void (*orig_didReceive)(id, SEL, id, id);

static void ThetaNSELog(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fprintf(stderr, "[ThetaNSE] %s\n", buf);
    fflush(stderr);
    os_log(os_log_create("com.theta.nse", "ThetaNSE"), "%{public}s", buf);
}

static NSString *ThetaNSEParentBundleID(void) {
    NSString *path = [[NSBundle mainBundle] bundlePath] ?: @"";
    if ([path.pathExtension isEqualToString:@"appex"]) {
        NSString *appDir = path.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        if ([appDir.pathExtension isEqualToString:@"app"]) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appDir stringByAppendingPathComponent:@"Info.plist"]];
            NSString *host = info[@"CFBundleIdentifier"];
            if ([host isKindOfClass:[NSString class]] && host.length) return host;
        }
    }
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSArray *suffixes = @[
        @".notificationextension",
        @".notificationcontentextension",
        @".InstagramNotificationExtension",
        @".shareextension",
    ];
    NSString *lower = bid.lowercaseString;
    for (NSString *suffix in suffixes) {
        if ([lower hasSuffix:suffix.lowercaseString]) return [bid substringToIndex:bid.length - suffix.length];
    }
    return bid;
}

static CFTypeRef ThetaNSECopyEntitlement(CFStringRef key) {
    typedef struct __SecTask *SecTaskRef;
    SecTaskRef (*create)(CFAllocatorRef) = (SecTaskRef (*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*copyEnt)(SecTaskRef, CFStringRef, CFErrorRef *) =
        (CFTypeRef (*)(SecTaskRef, CFStringRef, CFErrorRef *))dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copyEnt) return NULL;
    SecTaskRef task = create(NULL);
    if (!task) return NULL;
    CFTypeRef value = copyEnt(task, key, NULL);
    CFRelease(task);
    return value;
}

static NSString *ThetaNSETeamPrefix(void) {
    CFTypeRef appId = ThetaNSECopyEntitlement(CFSTR("application-identifier"));
    NSString *team = nil;
    if (appId && CFGetTypeID(appId) == CFStringGetTypeID()) {
        NSString *s = (__bridge NSString *)appId;
        NSRange dot = [s rangeOfString:@"."];
        if (dot.location != NSNotFound) team = [s substringToIndex:dot.location];
    }
    if (appId) CFRelease(appId);
    return team;
}

static NSArray<NSString *> *ThetaNSEEntitledKeychainGroups(void) {
    CFTypeRef raw = ThetaNSECopyEntitlement(CFSTR("keychain-access-groups"));
    NSArray *groups = nil;
    if (raw && CFGetTypeID(raw) == CFArrayGetTypeID())
        groups = [(__bridge NSArray *)raw copy];
    if (raw) CFRelease(raw);
    return groups ?: @[];
}

static BOOL ThetaNSEGroupIsWildcard(NSString *group) {
    return [group isKindOfClass:[NSString class]] && [group hasSuffix:@".*"];
}

static BOOL ThetaNSEGroupIsEntitled(NSString *group, NSArray<NSString *> *entitled) {
    if (!group.length) return NO;
    for (NSString *g in entitled) {
        if (![g isKindOfClass:[NSString class]]) continue;
        if ([g isEqualToString:group]) return YES;
        if (ThetaNSEGroupIsWildcard(g) && [group hasPrefix:[g substringToIndex:g.length - 1]]) return YES;
    }
    return NO;
}

static BOOL ThetaNSESkipGroup(CFStringRef group) {
    if (!group || CFGetTypeID(group) != CFStringGetTypeID()) return YES;
    if (CFStringHasPrefix(group, CFSTR("com.apple."))) return YES;
    if (gKeychainGroup.length &&
        CFStringCompare(group, (__bridge CFStringRef)gKeychainGroup, 0) == kCFCompareEqualTo) {
        return YES;
    }
    return NO;
}

static NSString *ThetaNSEHostAppPath(void) {
    NSString *path = [[NSBundle mainBundle] bundlePath] ?: @"";
    if ([path.pathExtension isEqualToString:@"appex"]) {
        return path.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    }
    return path;
}

static BOOL ThetaNSEServiceNeedsHostGroup(CFDictionaryRef dict) {
    CFTypeRef svc = CFDictionaryGetValue(dict, kSecAttrService);
    if (!svc || CFGetTypeID(svc) != CFStringGetTypeID()) return NO;
    char buf[256];
    if (!CFStringGetCString((CFStringRef)svc, buf, sizeof(buf), kCFStringEncodingUTF8)) return NO;
    for (char *p = buf; *p; p++)
        if (*p >= 'A' && *p <= 'Z') *p = (char)(*p - 'A' + 'a');
    return strstr(buf, "hpke") || strstr(buf, "notif");
}

static CFDictionaryRef ThetaNSERewriteDict(CFDictionaryRef dict, BOOL isQuery) {
    if (!dict || CFGetTypeID(dict) != CFDictionaryGetTypeID() || !gKeychainGroup.length) return NULL;
    CFTypeRef ag = CFDictionaryGetValue(dict, kSecAttrAccessGroup);
    BOOL rewriteGroup = ThetaNSEServiceNeedsHostGroup(dict) ||
                        ((ag != NULL) && !ThetaNSESkipGroup((CFStringRef)ag));
    BOOL hasSync = CFDictionaryContainsKey(dict, kSecAttrSynchronizable);
    if (!rewriteGroup && !hasSync) return NULL;
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dict);
    if (!copy) return NULL;
    if (rewriteGroup) {
        CFDictionarySetValue(copy, kSecAttrAccessGroup, (__bridge CFStringRef)gKeychainGroup);
    }
    if (hasSync) {
        if (isQuery) {
            CFDictionarySetValue(copy, kSecAttrSynchronizable, kSecAttrSynchronizableAny);
        } else {
            CFDictionarySetValue(copy, kSecAttrSynchronizable, kCFBooleanFalse);
        }
    }
    return copy;
}

static void ThetaNSELogSecStatus(const char *op, OSStatus st) {
    if (st == errSecSuccess || st == errSecItemNotFound || st == errSecDuplicateItem) return;
    ThetaNSELog("%s status=%d group=%s", op, (int)st, gKeychainGroup.UTF8String ?: "(null)");
}

static BOOL ThetaNSEBlobLooksHPKE(const char *s) {
    if (!s || !s[0]) return NO;
    for (const char *p = s; *p; p++) {
        char c = (*p >= 'A' && *p <= 'Z') ? (char)(*p - 'A' + 'a') : *p;
        if ((c == 'h' && strstr(p, "hpke")) || (c == 'n' && strstr(p, "notif"))) return YES;
    }
    return NO;
}

static void ThetaNSECopyCFString(CFDictionaryRef dict, CFStringRef key, char *out, size_t outLen) {
    out[0] = 0;
    if (!dict || outLen < 2) return;
    CFTypeRef v = CFDictionaryGetValue(dict, key);
    if (v && CFGetTypeID(v) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)v, out, (CFIndex)outLen, kCFStringEncodingUTF8);
}

static void ThetaNSELogQuery(const char *op, CFDictionaryRef query, OSStatus st) {
    char svc[160] = "";
    char acc[160] = "";
    char ag[160] = "";
    ThetaNSECopyCFString(query, kSecAttrService, svc, sizeof(svc));
    ThetaNSECopyCFString(query, kSecAttrAccount, acc, sizeof(acc));
    ThetaNSECopyCFString(query, kSecAttrAccessGroup, ag, sizeof(ag));
    BOOL interesting = (st != errSecSuccess && st != errSecItemNotFound && st != errSecDuplicateItem);
    if (ThetaNSEBlobLooksHPKE(svc) || ThetaNSEBlobLooksHPKE(acc) || ThetaHPKEDictIsHPKE(query))
        interesting = YES;
    if (gSecLogLeft > 0) {
        interesting = YES;
        gSecLogLeft--;
    }
    if (interesting)
        ThetaNSELog("%s svc=%s acc=%s ag=%s st=%d rewrite=%s",
                    op, svc[0] ? svc : "-", acc[0] ? acc : "-", ag[0] ? ag : "-",
                    (int)st, gKeychainGroup.UTF8String ?: "(null)");
}

static OSStatus hooked_CopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!real_SecItemCopyMatching) return (OSStatus)-4;
    CFDictionaryRef rewritten = ThetaNSERewriteDict(query, YES);
    OSStatus st = real_SecItemCopyMatching(rewritten ? rewritten : query, result);
    if (st != errSecSuccess && rewritten && gWildcardKeychainGroup.length &&
        ![gWildcardKeychainGroup isEqualToString:gKeychainGroup]) {
        CFMutableDictionaryRef alt = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, rewritten);
        if (alt) {
            CFDictionarySetValue(alt, kSecAttrAccessGroup, (__bridge CFStringRef)gWildcardKeychainGroup);
            OSStatus altSt = real_SecItemCopyMatching(alt, result);
            CFRelease(alt);
            if (altSt == errSecSuccess) {
                ThetaNSELog("keychain hit via wildcard group %s", gWildcardKeychainGroup.UTF8String);
                st = altSt;
            }
        }
    }
    if (st == -34018 && rewritten) {
        ThetaNSELog("missing keychain entitlement for group %s — add it to the NSE profile",
                    gKeychainGroup.UTF8String ?: "(null)");
        CFRelease(rewritten);
        rewritten = NULL;
        st = real_SecItemCopyMatching(query, result);
    }
    if (rewritten) CFRelease(rewritten);
    if (st != errSecSuccess) {
        OSStatus fileSt = ThetaHPKECopyMatching(query, result);
        if (fileSt == errSecSuccess) {
            ThetaNSELog("hpke key loaded from app-group file");
            return fileSt;
        }
    }
    ThetaNSELogQuery("SecItemCopyMatching", query, st);
    return st;
}

static OSStatus hooked_Add(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!real_SecItemAdd) return (OSStatus)-4;
    CFDictionaryRef rewritten = ThetaNSERewriteDict(attributes, NO);
    OSStatus st = real_SecItemAdd(rewritten ? rewritten : attributes, result);
    if (rewritten) CFRelease(rewritten);
    ThetaHPKESave(attributes);
    if (st == errSecDuplicateItem) return errSecSuccess;
    ThetaNSELogSecStatus("SecItemAdd", st);
    return st;
}

static OSStatus hooked_Update(CFDictionaryRef query, CFDictionaryRef attrs) {
    if (!real_SecItemUpdate) return (OSStatus)-4;
    CFDictionaryRef q = ThetaNSERewriteDict(query, YES);
    CFDictionaryRef a = ThetaNSERewriteDict(attrs, NO);
    OSStatus st = real_SecItemUpdate(q ? q : query, a ? a : attrs);
    if (q) CFRelease(q);
    if (a) CFRelease(a);
    ThetaHPKESaveFromQueryAndAttrs(query, attrs);
    return st;
}

static OSStatus hooked_Delete(CFDictionaryRef query) {
    if (!real_SecItemDelete) return (OSStatus)-4;
    CFDictionaryRef rewritten = ThetaNSERewriteDict(query, YES);
    OSStatus st = real_SecItemDelete(rewritten ? rewritten : query);
    if (rewritten) CFRelease(rewritten);
    return st;
}

static NSString *hook_accessGroup(id self, SEL _cmd) {
    if (gKeychainGroup.length) return gKeychainGroup;
    if (orig_fbAccessGroup) return orig_fbAccessGroup(self, _cmd);
    if (orig_uicAccessGroup) return orig_uicAccessGroup(self, _cmd);
    return nil;
}

static id hook_lsInit4(id self, SEL _cmd, id service, id group, id user, BOOL sync) {
    if (!orig_lsInit4) return nil;
    return orig_lsInit4(self, _cmd, service, gKeychainGroup.length ? gKeychainGroup : group, user, NO);
}

static id hook_uicStore(id self, SEL _cmd, id service, id group) {
    if (!orig_uicStore) return nil;
    return orig_uicStore(self, _cmd, service, gKeychainGroup.length ? gKeychainGroup : group);
}

static BOOL ThetaNSECanWrite(NSURL *url) {
    NSString *path = url.path;
    if (!path.length) return NO;
    NSString *probe = [path stringByAppendingPathComponent:@".theta_nse_probe"];
    BOOL ok = [@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (ok) [[NSFileManager defaultManager] removeItemAtPath:probe error:NULL];
    return ok;
}

static NSURL *hook_containerURL(id self, SEL _cmd, NSString *groupIdentifier) {
    if (orig_containerURL && groupIdentifier.length) {
        NSURL *realURL = orig_containerURL(self, _cmd, groupIdentifier);
        if (ThetaNSECanWrite(realURL)) return realURL;
    }
    if (!groupIdentifier || !gFakeGroupRoot) {
        return orig_containerURL ? orig_containerURL(self, _cmd, groupIdentifier) : nil;
    }
    NSURL *fake = [gFakeGroupRoot URLByAppendingPathComponent:groupIdentifier];
    [[NSFileManager defaultManager] createDirectoryAtURL:fake withIntermediateDirectories:YES attributes:nil error:NULL];
    return fake;
}

static BOOL hook_mkdir(id self, SEL _cmd, NSString *path, BOOL intermediates, NSDictionary *attrs, NSError **error) {
    if (!orig_mkdir) return NO;
    BOOL ok = orig_mkdir(self, _cmd, path, intermediates, attrs, error);
    if (ok) return YES;
    if (path && [path rangeOfString:@"MobileConfig" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        if (error) *error = nil;
        return YES;
    }
    return NO;
}

static void ThetaNSERebindAllNow(const char *why);
static void ThetaNSELogAppImages(const char *why);

static void ThetaNSESwizzle(Class cls, SEL sel, IMP neo, void **orig) {
    if (!cls || !sel || !neo) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) m = class_getClassMethod(cls, sel);
    if (!m) return;
    IMP prev = method_setImplementation(m, neo);
    if (orig && prev) *orig = (void *)prev;
}

typedef void (^ThetaNSEContentHandler)(id content);

static void ThetaNSELogInfoTree(id obj, NSString *path, int depth) {
    if (depth > 5 || !obj) return;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id key in [obj allKeys]) {
            NSString *next = path.length
                ? [NSString stringWithFormat:@"%@.%@", path, key]
                : [key description];
            ThetaNSELogInfoTree(obj[key], next, depth + 1);
        }
        return;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        ThetaNSELog("key %s = array(%lu)", path.UTF8String ?: "?", (unsigned long)[obj count]);
        NSArray *arr = obj;
        if (arr.count)
            ThetaNSELogInfoTree(arr.firstObject, [path stringByAppendingString:@"[0]"], depth + 1);
        return;
    }
    if ([obj isKindOfClass:[NSData class]]) {
        ThetaNSELog("key %s = data(%lu)", path.UTF8String ?: "?", (unsigned long)[obj length]);
        return;
    }
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = obj;
        ThetaNSELog("key %s = str(%lu)", path.UTF8String ?: "?", (unsigned long)s.length);
        return;
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        ThetaNSELog("key %s = %@", path, obj);
        return;
    }
    ThetaNSELog("key %s = %s", path.UTF8String ?: "?", class_getName(object_getClass(obj)));
}

static id (*orig_getEnc4)(id, SEL, id, id, id, NSError **);
static id hook_getEnc4(id self, SEL _cmd, id keyFor, id group, id accessible, NSError **err) {
    ThetaNSELog("getEnc4 for=%s group=%s rewrite=%s",
                [[keyFor description] UTF8String] ?: "-",
                [[group description] UTF8String] ?: "-",
                gKeychainGroup.UTF8String ?: "-");
    NSError *local = nil;
    id info = orig_getEnc4 ? orig_getEnc4(self, _cmd, keyFor, gKeychainGroup.length ? gKeychainGroup : group, accessible, &local) : nil;
    if (!info && orig_getEnc4)
        info = orig_getEnc4(self, _cmd, keyFor, nil, accessible, &local);
    ThetaNSELog("getEnc4 result=%p err=%s", info, local.localizedDescription.UTF8String ?: "-");
    if (!info && err) *err = local;
    return info;
}

static id (*orig_getEnc2)(id, SEL, id, NSError **);
static id hook_getEnc2(id self, SEL _cmd, id keyFor, NSError **err) {
    ThetaNSELog("getEnc2 for=%s", [[keyFor description] UTF8String] ?: "-");
    if (orig_getEnc4)
        return hook_getEnc4(self, @selector(getEncryptionInfoFor:accessGroup:secAttrAccessible:error:),
                            keyFor, gKeychainGroup, nil, err);
    return orig_getEnc2 ? orig_getEnc2(self, _cmd, keyFor, err) : nil;
}

static void hook_didReceive(id self, SEL _cmd, id request, ThetaNSEContentHandler handler) {
    gSecLogLeft = 32;
    ThetaNSERebindAllNow("didReceive");
    id content = nil;
    @try { content = [request valueForKey:@"content"]; } @catch (__unused NSException *e) {}
    id info = nil;
    @try { info = [content valueForKey:@"userInfo"]; } @catch (__unused NSException *e) {}
    if ([info isKindOfClass:[NSDictionary class]]) {
        ThetaNSELog("didReceive keys=%lu", (unsigned long)[info count]);
        ThetaNSELogInfoTree(info, @"", 0);
    }
    ThetaNSEContentHandler origHandler = handler;
    ThetaNSEContentHandler wrapped = ^(id notifContent) {
        NSUInteger titleLen = 0, bodyLen = 0;
        @try {
            titleLen = [[notifContent valueForKey:@"title"] length];
            bodyLen = [[notifContent valueForKey:@"body"] length];
        } @catch (__unused NSException *e) {}
        ThetaNSELog("contentHandler titleLen=%lu bodyLen=%lu",
                    (unsigned long)titleLen, (unsigned long)bodyLen);
        if (origHandler) origHandler(notifContent);
    };
    if (orig_didReceive) orig_didReceive(self, _cmd, request, wrapped);
}

static BOOL ThetaNSEMakeDataWritable(void *addr, size_t len) {
    vm_address_t page = (vm_address_t)addr & ~((vm_address_t)vm_page_size - 1);
    vm_size_t sz = (vm_address_t)addr + len - page;
    sz = (sz + vm_page_size - 1) & ~((vm_size_t)vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, sz, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        ThetaNSELog("data vm_protect kr=%d", (int)kr);
        return NO;
    }
    return YES;
}

static int ThetaNSEPatchSlots(void *start, size_t size, void *from, void *to) {
    if (!start || size < sizeof(void *) || !from || !to) return 0;
    int n = 0;
    uintptr_t p = ((uintptr_t)start + sizeof(void *) - 1) & ~(sizeof(void *) - 1);
    uintptr_t end = (uintptr_t)start + size;
    for (; p + sizeof(void *) <= end; p += sizeof(void *)) {
        void **slot = (void **)p;
        if (*slot != from) continue;
        if (!ThetaNSEMakeDataWritable(slot, sizeof(void *))) continue;
        *slot = to;
        n++;
    }
    return n;
}

static int ThetaNSERebindImage(const struct mach_header *mh, intptr_t slide, const char *name) {
    if (!mh || mh->magic != MH_MAGIC_64) return 0;
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    const uint8_t *cursor = (const uint8_t *)(mh64 + 1);
    int patched = 0;
    BOOL small = name && (strstr(name, ".appex") || strstr(name, "NotificationExtension"));
    struct {
        void *from;
        void *to;
    } pairs[] = {
        { (void *)SecItemCopyMatching, (void *)hooked_CopyMatching },
        { (void *)SecItemAdd, (void *)hooked_Add },
        { (void *)SecItemUpdate, (void *)hooked_Update },
        { (void *)SecItemDelete, (void *)hooked_Delete },
    };
    for (uint32_t i = 0; i < mh64->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        cursor += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strncmp(seg->segname, "__DATA", 6) != 0 &&
            strncmp(seg->segname, "__AUTH", 6) != 0) {
            continue;
        }
        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
            if (!small) {
                const char *sn = sect->sectname;
                if (!strstr(sn, "got") && !strstr(sn, "symbol_ptr") && !strstr(sn, "auth_ptr"))
                    continue;
            }
            void *start = (void *)(slide + sect->addr);
            for (size_t k = 0; k < sizeof(pairs) / sizeof(pairs[0]); k++)
                patched += ThetaNSEPatchSlots(start, (size_t)sect->size, pairs[k].from, pairs[k].to);
        }
    }
    return patched;
}

static BOOL ThetaNSEShouldRebindImage(const char *name) {
    if (!name) return YES;
    if (strstr(name, "ThetaNSE") || strstr(name, "CydiaSubstrate")) return NO;
    if (strstr(name, "/usr/lib/") || strstr(name, "/System/")) return NO;
    if (strstr(name, "Security.framework")) return NO;
    return YES;
}

static const char *ThetaNSENameForHeader(const struct mach_header *mh) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == mh) return _dyld_get_image_name(i);
    }
    Dl_info info;
    if (mh && dladdr(mh, &info) && info.dli_fname) return info.dli_fname;
    return NULL;
}

static int gRebindTotal;

static void ThetaNSEAddImage(const struct mach_header *mh, intptr_t slide) {
    const char *name = ThetaNSENameForHeader(mh);
    if (!ThetaNSEShouldRebindImage(name)) return;
    int n = ThetaNSERebindImage(mh, slide, name);
    gRebindTotal += n;
    BOOL interesting = n > 0 || !name ||
        (name && (strstr(name, "FB") || strstr(name, "Meta") ||
                  strstr(name, "HPKE") || strstr(name, "Instagram") || strstr(name, ".appex")));
    if (interesting)
        ThetaNSELog("rebound %d SecItem* slots in %s", n, name ?: "(unnamed)");
}

static void ThetaNSERebindAllNow(const char *why) {
    uint32_t count = _dyld_image_count();
    int extra = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!ThetaNSEShouldRebindImage(name)) continue;
        int n = ThetaNSERebindImage(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), name);
        if (n) {
            extra += n;
            ThetaNSELog("late rebound %d slots in %s (%s)", n, name ?: "?", why);
        }
    }
    ThetaNSELog("rebind-all %s extra=%d images=%u", why, extra, count);
}

static void ThetaNSELogAppImages(const char *why) {
    uint32_t count = _dyld_image_count();
    int app = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || strstr(name, "/usr/lib/") || strstr(name, "/System/")) continue;
        const char *base = strrchr(name, '/');
        ThetaNSELog("image %s", base ? base + 1 : name);
        app++;
    }
    ThetaNSELog("images %s app=%d total=%u", why, app, count);
}

static int ThetaNSERebindLoadedImages(void) {
    _dyld_register_func_for_add_image(ThetaNSEAddImage);
    return gRebindTotal;
}

static void ThetaNSEHookSecItem(void) {
    real_SecItemCopyMatching = SecItemCopyMatching;
    real_SecItemAdd = SecItemAdd;
    real_SecItemUpdate = SecItemUpdate;
    real_SecItemDelete = SecItemDelete;

    int slots = ThetaNSERebindLoadedImages();
    struct rebinding rebindings[] = {
        { "SecItemCopyMatching", (void *)hooked_CopyMatching, (void **)&real_SecItemCopyMatching },
        { "SecItemAdd", (void *)hooked_Add, (void **)&real_SecItemAdd },
        { "SecItemUpdate", (void *)hooked_Update, (void **)&real_SecItemUpdate },
        { "SecItemDelete", (void *)hooked_Delete, (void **)&real_SecItemDelete },
    };
    int fh = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    ThetaNSELog("SecItem* data-slots=%d fishhook=%d", slots, fh == 0 ? 1 : 0);
}

static NSString *ThetaNSEPreferredSharedGroup(NSArray<NSString *> *entitled) {
    NSString *team = ThetaNSETeamPrefix();
    NSString *parent = ThetaNSEParentBundleID();
    NSMutableArray<NSString *> *wanted = [NSMutableArray array];
    if (team.length) {
        [wanted addObject:[NSString stringWithFormat:@"%@.platformFamily", team]];
        [wanted addObject:[NSString stringWithFormat:@"%@.shared", team]];
        if (parent.length)
            [wanted addObject:[NSString stringWithFormat:@"%@.%@", team, parent]];
    }
    for (NSString *g in wanted) {
        if (ThetaNSEGroupIsEntitled(g, entitled)) return g;
    }
    for (NSString *g in entitled) {
        if ([g isKindOfClass:[NSString class]] && g.length && !ThetaNSEGroupIsWildcard(g) &&
            ![g hasPrefix:@"com.apple."]) {
            return g;
        }
    }
    return wanted.firstObject;
}

static void ThetaNSELoadGroup(void) {
    NSArray<NSString *> *entitled = ThetaNSEEntitledKeychainGroups();
    ThetaNSELog("entitled keychain groups (%lu): %s",
                (unsigned long)entitled.count,
                entitled.description.UTF8String ?: "(none)");

    // Same dummy probe as the main-app tweak: iOS returns the first entitled group.
    NSDictionary *dummy = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount : @"thetaNSEDummy",
        (__bridge id)kSecAttrService : @"thetaNSEDummy",
        (__bridge id)kSecReturnAttributes : @YES,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)dummy, &result);
    if (st == errSecItemNotFound) st = SecItemAdd((__bridge CFDictionaryRef)dummy, &result);
    if (st == 0 && result) {
        gKeychainGroup = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
        CFRelease(result);
    }

    if (ThetaNSEGroupIsWildcard(gKeychainGroup))
        gWildcardKeychainGroup = gKeychainGroup;

    /* A TEAM.* entitlement does not allow TEAM.platformFamily (-34018).
       Use the group iOS assigns on a dummy item (often the literal TEAM.*). */
    NSString *preferred = ThetaNSEPreferredSharedGroup(entitled);
    if (!gKeychainGroup.length && preferred.length)
        gKeychainGroup = preferred;

    if (entitled.count == 0)
        ThetaNSELog("no keychain-access-groups on NSE — using %s", gKeychainGroup.UTF8String ?: "(null)");
    else
        ThetaNSELog("shared keychain group %s (probe status=%d)",
                    gKeychainGroup.UTF8String ?: "(null)", (int)st);
}

__attribute__((constructor))
static void ThetaNSEInit(void) {
    static int once = 0;
    if (once) return;
    once = 1;
    @autoreleasepool {
        gFakeGroupRoot = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FakeGroupContainers"] isDirectory:YES];
        ThetaNSELoadGroup();
        ThetaNSEHookSecItem();

        ThetaNSESwizzle(objc_getClass("FBSDKKeychainStore"), @selector(accessGroup), (IMP)hook_accessGroup, (void **)&orig_fbAccessGroup);
        ThetaNSESwizzle(objc_getClass("FBKeychainItemController"), @selector(accessGroup), (IMP)hook_accessGroup, (void **)&orig_fbAccessGroup);
        ThetaNSESwizzle(objc_getClass("UICKeyChainStore"), @selector(accessGroup), (IMP)hook_accessGroup, (void **)&orig_uicAccessGroup);
        ThetaNSESwizzle(objc_getClass("LSKeychainItemController"),
                        @selector(initWithServiceID:accessGroup:userID:isSynchronizable:),
                        (IMP)hook_lsInit4, (void **)&orig_lsInit4);
        ThetaNSESwizzle(objc_getClass("UICKeyChainStore"),
                        @selector(keyChainStoreWithService:accessGroup:),
                        (IMP)hook_uicStore, (void **)&orig_uicStore);

        Class hpke = objc_getClass("_TtC21MetaPushEncryptionKit15MetaHPKEManager")
                  ?: objc_getClass("MetaHPKEManager");
        ThetaNSELog("MetaHPKEManager=%s handler=%s",
                    hpke ? class_getName(hpke) : "nil",
                    objc_getClass("IGNotificationExtensionHandler") ? "yes" : "nil");
        ThetaNSESwizzle(object_getClass(hpke),
                        @selector(getEncryptionInfoFor:accessGroup:secAttrAccessible:error:),
                        (IMP)hook_getEnc4, (void **)&orig_getEnc4);
        ThetaNSESwizzle(object_getClass(hpke),
                        @selector(getEncryptionInfoFor:error:),
                        (IMP)hook_getEnc2, (void **)&orig_getEnc2);

        Class fm = objc_getClass("NSFileManager");
        ThetaNSESwizzle(fm, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:),
                        (IMP)hook_mkdir, (void **)&orig_mkdir);
        ThetaNSESwizzle(fm, @selector(containerURLForSecurityApplicationGroupIdentifier:),
                        (IMP)hook_containerURL, (void **)&orig_containerURL);
        ThetaHPKESetContainerOrig((ThetaHPKEContainerURLFn)orig_containerURL);

        NSOperatingSystemVersion ver = [[NSProcessInfo processInfo] operatingSystemVersion];
        ThetaNSELog("iOS %ld.%ld.%ld", (long)ver.majorVersion, (long)ver.minorVersion, (long)ver.patchVersion);
        if (ver.majorVersion <= 16)
            ThetaNSELog("IG skips HPKE decrypt on iOS 16 and below — banners stay generic even with a working key");

        CFTypeRef appGroups = ThetaNSECopyEntitlement(CFSTR("com.apple.security.application-groups"));
        ThetaNSELog("application-groups: %s",
                    appGroups ? [(__bridge id)appGroups description].UTF8String : "(none)");
        if (appGroups) CFRelease(appGroups);

        ThetaHPKEDumpStatus();
        ThetaNSESwizzle(objc_getClass("FBNotificationService"),
                        @selector(didReceiveNotificationRequest:withContentHandler:),
                        (IMP)hook_didReceive, (void **)&orig_didReceive);
        if (!orig_didReceive)
            ThetaNSESwizzle(objc_getClass("UNNotificationServiceExtension"),
                            @selector(didReceiveNotificationRequest:withContentHandler:),
                            (IMP)hook_didReceive, (void **)&orig_didReceive);
        ThetaNSELogAppImages("init");
        ThetaNSELog("ready bundle=%s", [[NSBundle mainBundle] bundleIdentifier].UTF8String ?: "?");
    }
}
