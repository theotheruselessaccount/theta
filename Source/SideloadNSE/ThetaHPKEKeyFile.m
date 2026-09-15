#import "Source/SideloadNSE/ThetaHPKEKeyFile.h"
#import <stdarg.h>
#import <dlfcn.h>
#import <os/log.h>
#import <stdio.h>

static ThetaHPKEContainerURLFn gContainerOrig;
static NSURL *gStoreDir;
static BOOL gStoreResolved;

static void ThetaHPKELog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void ThetaHPKELog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "[ThetaHPKE] %s\n", msg.UTF8String ?: "");
    fflush(stderr);
    os_log(os_log_create("com.theta.nse", "ThetaHPKE"), "%{public}s", msg.UTF8String ?: "");
}

static BOOL ThetaHPKECanWrite(NSURL *url) {
    if (!url.path.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if (![fm createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:&err]) {
        if (![fm fileExistsAtPath:url.path]) return NO;
    }
    NSString *probe = [url.path stringByAppendingPathComponent:@".theta_hpke_probe"];
    BOOL ok = [@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (ok) [fm removeItemAtPath:probe error:NULL];
    return ok;
}

static NSString *ThetaHPKECString(CFDictionaryRef dict, CFStringRef key) {
    if (!dict) return nil;
    CFTypeRef v = CFDictionaryGetValue(dict, key);
    if (!v || CFGetTypeID(v) != CFStringGetTypeID()) return nil;
    return (__bridge NSString *)v;
}

BOOL ThetaHPKEDictIsHPKE(CFDictionaryRef dict) {
    NSString *svc = ThetaHPKECString(dict, kSecAttrService);
    NSString *acc = ThetaHPKECString(dict, kSecAttrAccount);
    NSString *blob = [[NSString stringWithFormat:@"%@ %@", svc ?: @"", acc ?: @""] lowercaseString];
    return [blob containsString:@"hpke"] || [blob containsString:@"notif"];
}

void ThetaHPKESetContainerOrig(ThetaHPKEContainerURLFn fn) {
    gContainerOrig = fn;
    gStoreDir = nil;
    gStoreResolved = NO;
}

static NSArray<NSString *> *ThetaHPKEEntitledAppGroups(void) {
    typedef struct __SecTask *SecTaskRef;
    SecTaskRef (*create)(CFAllocatorRef) = (SecTaskRef (*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*copyEnt)(SecTaskRef, CFStringRef, CFErrorRef *) =
        (CFTypeRef (*)(SecTaskRef, CFStringRef, CFErrorRef *))dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copyEnt) return @[];
    SecTaskRef task = create(NULL);
    if (!task) return @[];
    CFTypeRef raw = copyEnt(task, CFSTR("com.apple.security.application-groups"), NULL);
    CFRelease(task);
    NSArray *groups = @[];
    if (raw && CFGetTypeID(raw) == CFArrayGetTypeID())
        groups = [(__bridge NSArray *)raw copy];
    if (raw) CFRelease(raw);
    return groups ?: @[];
}

static NSURL *ThetaHPKETryGroup(id fm, SEL sel, NSString *gid) {
    if (!gid.length) return nil;
    NSURL *root = nil;
    if (gContainerOrig) {
        root = gContainerOrig(fm, sel, gid);
    } else {
        root = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
    }
    if (!root) return nil;
    NSURL *dir = [root URLByAppendingPathComponent:@"Library/Application Support/ThetaHPKE" isDirectory:YES];
    if (!ThetaHPKECanWrite(dir)) {
        ThetaHPKELog(@"group %@ not writable %@", gid, dir.path);
        return nil;
    }
    return dir;
}

static NSURL *ThetaHPKESharedDirectory(void) {
    if (gStoreResolved) return gStoreDir;
    gStoreResolved = YES;
    id fm = [NSFileManager defaultManager];
    SEL sel = @selector(containerURLForSecurityApplicationGroupIdentifier:);

    NSArray<NSString *> *official = @[
        @"group.com.burbn.instagram",
        @"group.com.burbn.family",
        @"group.com.facebook.family",
    ];
    for (NSString *gid in official) {
        NSURL *dir = ThetaHPKETryGroup(fm, sel, gid);
        if (dir) {
            gStoreDir = dir;
            ThetaHPKELog(@"shared store %@", dir.path);
            return gStoreDir;
        }
    }

    NSArray<NSString *> *entitled = [[ThetaHPKEEntitledAppGroups() sortedArrayUsingSelector:@selector(compare:)] copy];
    ThetaHPKELog(@"official app-groups nil; entitled (%lu): %@", (unsigned long)entitled.count, entitled);
    for (NSString *gid in entitled) {
        if (![gid isKindOfClass:[NSString class]]) continue;
        NSURL *dir = ThetaHPKETryGroup(fm, sel, gid);
        if (dir) {
            gStoreDir = dir;
            ThetaHPKELog(@"shared store %@ (sideload group %@)", dir.path, gid);
            return gStoreDir;
        }
    }
    ThetaHPKELog(@"no writable app-group container — HPKE file fallback unavailable");
    return nil;
}

void ThetaHPKEDumpStatus(void) {
    gStoreResolved = NO;
    gStoreDir = nil;
    (void)ThetaHPKESharedDirectory();
}

void ThetaHPKEMirrorKeychain(NSString *preferredGroup, NSString *wildcardGroup) {
    NSArray<NSString *> *services = @[
        @"com.instagram.notifications.hpke",
        @"instagram.notifications.hpke",
        @"com.instagram.hpke",
    ];
    NSMutableArray *groups = [NSMutableArray arrayWithObject:[NSNull null]];
    if (preferredGroup.length) [groups addObject:preferredGroup];
    if (wildcardGroup.length && ![wildcardGroup isEqualToString:preferredGroup])
        [groups addObject:wildcardGroup];
    int found = 0;
    for (NSString *svc in services) {
        for (id group in groups) {
            NSMutableDictionary *query = [@{
                (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService : svc,
                (__bridge id)kSecReturnData : @YES,
                (__bridge id)kSecReturnAttributes : @YES,
                (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitAll,
            } mutableCopy];
            if (group != [NSNull null])
                query[(__bridge id)kSecAttrAccessGroup] = group;
            CFTypeRef result = NULL;
            OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
            if (st == errSecSuccess && result) {
                NSArray *items = CFGetTypeID(result) == CFArrayGetTypeID()
                    ? (__bridge NSArray *)result
                    : @[ (__bridge id)result ];
                for (id item in items) {
                    if ([item isKindOfClass:[NSDictionary class]]) {
                        ThetaHPKESave((__bridge CFDictionaryRef)item);
                        found++;
                    } else if ([item isKindOfClass:[NSData class]]) {
                        NSMutableDictionary *attrs = [query mutableCopy];
                        attrs[(__bridge id)kSecValueData] = item;
                        ThetaHPKESave((__bridge CFDictionaryRef)attrs);
                        found++;
                    }
                }
                CFRelease(result);
            } else {
                ThetaHPKELog(@"mirror svc=%@ group=%@ st=%d", svc,
                             group == [NSNull null] ? @"(default)" : group, (int)st);
            }
        }
    }
    ThetaHPKELog(@"mirror done found=%d store=%@", found, gStoreDir.path ?: @"(none)");
}

static NSString *ThetaHPKEFileName(NSString *service, NSString *account) {
    NSString *raw = [NSString stringWithFormat:@"%@|%@", service ?: @"", account ?: @""];
    NSUInteger hash = raw.hash;
    return [NSString stringWithFormat:@"%lx.plist", (unsigned long)hash];
}

static NSURL *ThetaHPKEFileURL(CFDictionaryRef dict) {
    NSURL *dir = ThetaHPKESharedDirectory();
    if (!dir) return nil;
    NSString *svc = ThetaHPKECString(dict, kSecAttrService);
    NSString *acc = ThetaHPKECString(dict, kSecAttrAccount);
    if (!svc.length) return nil;
    return [dir URLByAppendingPathComponent:ThetaHPKEFileName(svc, acc)];
}

static void ThetaHPKEWriteDict(CFDictionaryRef dict) {
    NSURL *url = ThetaHPKEFileURL(dict);
    if (!url) return;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *svc = ThetaHPKECString(dict, kSecAttrService);
    NSString *acc = ThetaHPKECString(dict, kSecAttrAccount);
    if (svc) out[@"service"] = svc;
    if (acc) out[@"account"] = acc;
    CFTypeRef data = CFDictionaryGetValue(dict, kSecValueData);
    if (data && CFGetTypeID(data) == CFDataGetTypeID()) {
        out[@"data"] = (__bridge NSData *)data;
    }
    CFTypeRef generic = CFDictionaryGetValue(dict, kSecAttrGeneric);
    if (generic && CFGetTypeID(generic) == CFDataGetTypeID()) {
        out[@"generic"] = (__bridge NSData *)generic;
    }
    NSError *err = nil;
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:out
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:&err];
    if (!plist || ![plist writeToURL:url atomically:YES]) {
        ThetaHPKELog(@"failed to write %@: %@", url.path, err);
        return;
    }
    if (svc.length) {
        NSString *safe = [[svc componentsSeparatedByCharactersInSet:
                           [[NSCharacterSet alphanumericCharacterSet] invertedSet]]
                          componentsJoinedByString:@"_"];
        NSURL *alias = [[url URLByDeletingLastPathComponent]
                        URLByAppendingPathComponent:[safe stringByAppendingString:@".plist"]];
        [plist writeToURL:alias atomically:YES];
    }
    ThetaHPKELog(@"saved svc=%@ acc=%@", svc, acc);
}

void ThetaHPKESave(CFDictionaryRef attributes) {
    if (!ThetaHPKEDictIsHPKE(attributes)) return;
    ThetaHPKEWriteDict(attributes);
}

void ThetaHPKESaveFromQueryAndAttrs(CFDictionaryRef query, CFDictionaryRef attrs) {
    if (!ThetaHPKEDictIsHPKE(query) && !ThetaHPKEDictIsHPKE(attrs)) return;
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    if (query) [merged addEntriesFromDictionary:(__bridge NSDictionary *)query];
    if (attrs) [merged addEntriesFromDictionary:(__bridge NSDictionary *)attrs];
    ThetaHPKEWriteDict((__bridge CFDictionaryRef)merged);
}

static NSURL *ThetaHPKEFindStoredURL(CFDictionaryRef query) {
    NSURL *exact = ThetaHPKEFileURL(query);
    if (exact && [[NSFileManager defaultManager] fileExistsAtPath:exact.path]) return exact;
    NSURL *dir = ThetaHPKESharedDirectory();
    if (!dir) return nil;
    NSString *want = ThetaHPKECString(query, kSecAttrService).lowercaseString;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dir
                                                  includingPropertiesForKeys:nil
                                                                     options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                       error:NULL];
    for (NSURL *file in files) {
        if (![file.pathExtension isEqualToString:@"plist"]) continue;
        NSDictionary *stored = [NSDictionary dictionaryWithContentsOfURL:file];
        NSString *svc = [stored[@"service"] description].lowercaseString;
        if (want.length && [svc isEqualToString:want]) return file;
        if (!want.length && [svc containsString:@"hpke"]) return file;
    }
    return exact;
}

OSStatus ThetaHPKECopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!ThetaHPKEDictIsHPKE(query)) return errSecItemNotFound;
    NSURL *url = ThetaHPKEFindStoredURL(query);
    if (!url) return errSecItemNotFound;
    NSData *raw = [NSData dataWithContentsOfURL:url];
    if (!raw.length) return errSecItemNotFound;
    NSDictionary *stored = [NSPropertyListSerialization propertyListWithData:raw
                                                                    options:NSPropertyListImmutable
                                                                     format:NULL
                                                                      error:NULL];
    if (![stored isKindOfClass:[NSDictionary class]] || !stored.count) return errSecItemNotFound;

    BOOL wantData = CFDictionaryContainsKey(query, kSecReturnData) &&
                    CFBooleanGetValue((CFBooleanRef)CFDictionaryGetValue(query, kSecReturnData));
    BOOL wantAttrs = CFDictionaryContainsKey(query, kSecReturnAttributes) &&
                     CFBooleanGetValue((CFBooleanRef)CFDictionaryGetValue(query, kSecReturnAttributes));
    if (!wantData && !wantAttrs) wantData = YES;

    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    id svc = stored[@"service"];
    id acc = stored[@"account"];
    id gen = stored[@"generic"];
    if (svc) attrs[(__bridge id)kSecAttrService] = svc;
    if (acc) attrs[(__bridge id)kSecAttrAccount] = acc;
    if (gen) attrs[(__bridge id)kSecAttrGeneric] = gen;
    NSData *data = stored[@"data"];

    if (result) {
        if (wantData && !wantAttrs) {
            *result = data ? CFBridgingRetain(data) : NULL;
            if (!data) return errSecItemNotFound;
        } else {
            if (wantData && data) attrs[(__bridge id)kSecValueData] = data;
            *result = CFBridgingRetain(attrs);
        }
    }
    ThetaHPKELog(@"loaded svc=%@ bytes=%lu", svc, (unsigned long)data.length);
    return errSecSuccess;
}
