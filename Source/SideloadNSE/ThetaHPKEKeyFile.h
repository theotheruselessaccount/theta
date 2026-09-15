#ifndef THETA_HPKE_KEY_FILE_H
#define THETA_HPKE_KEY_FILE_H

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef NSURL *(*ThetaHPKEContainerURLFn)(id self, SEL cmd, NSString *groupIdentifier);

void ThetaHPKESetContainerOrig(ThetaHPKEContainerURLFn fn);
void ThetaHPKEDumpStatus(void);
void ThetaHPKEMirrorKeychain(NSString *preferredGroup, NSString *wildcardGroup);
BOOL ThetaHPKEDictIsHPKE(CFDictionaryRef dict);
void ThetaHPKESave(CFDictionaryRef attributes);
void ThetaHPKESaveFromQueryAndAttrs(CFDictionaryRef query, CFDictionaryRef attrs);
OSStatus ThetaHPKECopyMatching(CFDictionaryRef query, CFTypeRef *result);

#ifdef __cplusplus
}
#endif

#endif
