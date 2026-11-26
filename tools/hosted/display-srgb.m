// SPDX-License-Identifier: GPL-2.0-only
// The main display's colour profile: print it; with "srgb" set it to the system's sRGB profile for this user, with
// "reset" take the custom profile away again.
#import <Cocoa/Cocoa.h>
#import <ColorSync/ColorSync.h>
int main(int argc, char **argv) { @autoreleasepool {
  CGDirectDisplayID d = CGMainDisplayID();
  CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(d);
  if (!u) { printf("no display UUID\n"); return 1; }
  if (argc > 1) {
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    if (!strcmp(argv[1], "srgb")) p[(__bridge id)kColorSyncDeviceDefaultProfileID] = [NSURL fileURLWithPath:@"/System/Library/ColorSync/Profiles/sRGB Profile.icc"];
    else p[(__bridge id)kColorSyncDeviceDefaultProfileID] = (__bridge id)kCFNull;
    p[(__bridge id)kColorSyncProfileUserScope] = (__bridge id)kCFPreferencesCurrentUser;
    printf("set: %d\n", ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, u, (__bridge CFDictionaryRef)p));
    [NSThread sleepForTimeInterval:1.0];
  }
  CGColorSpaceRef cs = CGDisplayCopyColorSpace(d);
  printf("display colour space: %s; NSScreen: %s\n", [(__bridge_transfer NSString *)CGColorSpaceCopyName(cs) UTF8String] ?: "(unnamed)", NSScreen.mainScreen.colorSpace.localizedName.UTF8String);
} return 0; }
