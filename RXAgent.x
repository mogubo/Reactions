// Reactions - RXAgent.x (phase 1A.3): the part that loads into imagent (ReactionsAgent.plist filters on the imagent
// executable). Phase 1A: DIAGNOSTICS ONLY. It changes no behaviour and sends nothing.
//
// imagent is the iOS 6 daemon that receives and decrypts iMessages. Newer iPhones send a tapback as an
// ordinary message whose (decrypted) payload is a property list with extra keys: amk (target message,
// "p:<part>/<GUID>"), amt (2000-2007 add, 3000-3007 remove), amrlc/amrln (range), ame (emoji), msi.
// Those keys come from public projects (OpenBubbles/rustpush) and must be verified on this device
// before anything is built on them. This file logs what really arrives:
//
//  1. Agent.log: every decoded property-list DICTIONARY that looks like an iMessage payload (has amk,
//     amt or msi, or both t and p). Logged: the key names, the value TYPES and lengths, and the values
//     of a short allowlist of technical keys only (amk, amt, amrlc, amrln, ame, ...). Never the text
//     (t, x), the participants (p) or the reacted-text summary inside msi (only its key names).
//     Plus a short call stack for the first captures, to find the method to hook in phase 1B.
//  2. AgentClasses.txt: classes, ivars and methods (runtime introspection, no class-dump needed) of
//     the loaded messaging images (iMessage.imservice, IMDaemonCore, ...), 30 s and 5 min after start.
//
// Safety: imagent must never crash (iMessage would stop until it restarts). The hooks call the
// original first, return its result untouched, test the type and two keys cheaply, and do every
// file write on a private serial queue inside @try. Re-entrancy (our own nested parse) is skipped.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <time.h>
#import <unistd.h>

#define RXA_DIR          @"/var/mobile/Library/Reactions"
#define RXA_LOG          @"/var/mobile/Library/Reactions/Agent.log"
#define RXA_CLASSES      @"/var/mobile/Library/Reactions/AgentClasses.txt"
#define RXA_LOG_MAX      (2ULL * 1024ULL * 1024ULL)   // Agent.log stops growing at 2 MB
#define RXA_STACKS_MAX   40                           // captures that also log a call stack

#pragma mark - Output

static dispatch_queue_t RXAQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.mbucc9000.reactions.agent", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *RXAStamp(void) {
    char buf[32];
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tmv);
    return [NSString stringWithUTF8String:buf];
}

static void RXAEnsureDir(void) {
    [[NSFileManager defaultManager] createDirectoryAtPath:RXA_DIR withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
}

static void RXALog(NSString *text) {
    if (!text) {
        return;
    }
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", RXAStamp(), text];
    dispatch_async(RXAQueue(), ^{
        @try {
            RXAEnsureDir();
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:RXA_LOG]) {
                [fm createFileAtPath:RXA_LOG contents:nil attributes:nil];
            }
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:RXA_LOG];
            if (!h) {
                return;
            }
            unsigned long long end = [h seekToEndOfFile];
            if (end < RXA_LOG_MAX) {
                [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            }
            [h closeFile];
        } @catch (NSException *e) {
        }
    });
}

#pragma mark - Payload description (privacy: types and lengths, allowlisted values only)

// Keys whose VALUES are logged: technical identifiers and numbers, no message content.
static NSSet *RXAVerbatimKeys(void) {
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithObjects:@"amk", @"amt", @"amrlc", @"amrln", @"ame", @"amc", @"pv", @"gv", @"v",
                @"r", @"tg", @"bid", @"are", @"arc", @"aogre", @"aogrs", @"iid", @"type", @"et", @"epi", @"emg", nil];
    });
    return keys;
}

// Registration body (what this iPhone declares to Apple): versions, service names, capability flags.
// Never push tokens, certificates, keys, validation data, phone numbers or e-mails (data -> length,
// other strings -> length, arrays of strings -> count).
static NSSet *RXARegistrationKeys(void) {
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithObjects:@"os-version", @"software-version", @"hardware-version", @"protocol-version",
                @"service", @"name", @"flags", @"version", @"client-data", @"capabilities", @"sub-services",
                @"language", @"region", nil];
    });
    return keys;
}

static NSSet *gRXAVerbatim;          // allowlist in use for the current description (main thread / caller)
static BOOL gRXADescendArrays;       // registration: describe dictionaries inside arrays

static NSString *RXADescribe(id value, BOOL verbatim, int depth);

static NSString *RXADescribeDict(NSDictionary *dict, int depth) {
    NSArray *keys = [[dict allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a description] compare:[b description]];
    }];
    NSMutableArray *items = [NSMutableArray array];
    for (id key in keys) {
        NSString *name = [key isKindOfClass:[NSString class]] ? key : [key description];
        BOOL verbatim = [(gRXAVerbatim ? gRXAVerbatim : RXAVerbatimKeys()) containsObject:name];
        NSString *desc = RXADescribe([dict objectForKey:key], verbatim, depth + 1);
        [items addObject:[NSString stringWithFormat:@"%@=%@", name, desc ? desc : @"?"]];
    }
    return [NSString stringWithFormat:@"{%@}", [items componentsJoinedByString:@", "]];
}

static NSString *RXADescribe(id value, BOOL verbatim, int depth) {
    if (!value) {
        return @"nil";
    }
    if ([value isKindOfClass:[NSString class]]) {
        if (verbatim) {
            return [NSString stringWithFormat:@"\"%@\"", value];
        }
        return [NSString stringWithFormat:@"str(%lu)", (unsigned long)[(NSString *)value length]];
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        // Numbers carry no message content (flags, versions, types, ranges, dates).
        return [NSString stringWithFormat:@"num(%@)", value];
    }
    if ([value isKindOfClass:[NSData class]]) {
        NSData *data = value;
        NSString *out = [NSString stringWithFormat:@"data(%lu)", (unsigned long)[data length]];
        // A nested binary plist (msi, ati, ...): show its structure with the same rules.
        if (depth < 3 && [data length] > 8 && memcmp([data bytes], "bplist", 6) == 0) {
            id nested = nil;
            @try {
                nested = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
            } @catch (NSException *e) {
                nested = nil;
            }
            if ([nested isKindOfClass:[NSDictionary class]]) {
                out = [out stringByAppendingFormat:@" bplist%@", RXADescribeDict(nested, depth)];
            }
        }
        return out;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        // Never string elements: "p" holds the participants' phone numbers / e-mails.
        NSArray *array = value;
        if (gRXADescendArrays && depth < 6) {
            NSMutableArray *items = [NSMutableArray array];
            for (id element in array) {
                if ([element isKindOfClass:[NSDictionary class]]) {
                    [items addObject:RXADescribeDict(element, depth)];
                } else if (verbatim && [element isKindOfClass:[NSString class]]) {
                    [items addObject:[NSString stringWithFormat:@"\"%@\"", element]];
                }
            }
            if ([items count]) {
                return [NSString stringWithFormat:@"array(%lu)[%@]", (unsigned long)[array count],
                        [items componentsJoinedByString:@", "]];
            }
        }
        return [NSString stringWithFormat:@"array(%lu)", (unsigned long)[array count]];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        return depth < (gRXADescendArrays ? 6 : 3) ? RXADescribeDict(value, depth) : @"dict";
    }
    if ([value isKindOfClass:[NSDate class]]) {
        return [NSString stringWithFormat:@"date(%.3f)", [(NSDate *)value timeIntervalSinceReferenceDate]];
    }
    return [NSString stringWithFormat:@"<%@>", NSStringFromClass([value class])];
}

#pragma mark - Capture

static pthread_key_t gRXAGuardKey;
static int gRXAStacks;

static BOOL RXALooksLikeMessage(CFDictionaryRef dict) {
    if (CFDictionaryContainsKey(dict, CFSTR("amk")) || CFDictionaryContainsKey(dict, CFSTR("amt")) ||
        CFDictionaryContainsKey(dict, CFSTR("msi"))) {
        return YES;
    }
    return CFDictionaryContainsKey(dict, CFSTR("t")) && CFDictionaryContainsKey(dict, CFSTR("p"));
}

static void RXAInspect(CFPropertyListRef result, const char *via) {
    if (!result || CFGetTypeID(result) != CFDictionaryGetTypeID()) {
        return;
    }
    if (pthread_getspecific(gRXAGuardKey)) {
        return;                                      // our own nested parse (msi) or a nested CF call
    }
    pthread_setspecific(gRXAGuardKey, (void *)1);
    @try {
        if (RXALooksLikeMessage((CFDictionaryRef)result)) {
            NSDictionary *dict = (__bridge NSDictionary *)result;
            BOOL reaction = [dict objectForKey:@"amk"] || [dict objectForKey:@"amt"];
            RXALog([NSString stringWithFormat:@"CAPTURE %@ via %s: %@", reaction ? @"REACTION" : @"message",
                    via, RXADescribeDict(dict, 0)]);
            if (gRXAStacks < RXA_STACKS_MAX) {
                gRXAStacks++;
                NSArray *stack = [NSThread callStackSymbols];
                NSUInteger n = MIN((NSUInteger)18, [stack count]);
                RXALog([NSString stringWithFormat:@"STACK\n  %@",
                        [[stack subarrayWithRange:NSMakeRange(0, n)] componentsJoinedByString:@"\n  "]]);
            }
        }
    } @catch (NSException *e) {
    }
    pthread_setspecific(gRXAGuardKey, NULL);
}

%hookf(CFPropertyListRef, CFPropertyListCreateWithData, CFAllocatorRef allocator, CFDataRef data,
       CFOptionFlags options, CFPropertyListFormat *format, CFErrorRef *error) {
    CFPropertyListRef result = %orig;
    RXAInspect(result, "CFPropertyListCreateWithData");
    return result;
}

%hookf(CFPropertyListRef, CFPropertyListCreateFromXMLData, CFAllocatorRef allocator, CFDataRef xmlData,
       CFOptionFlags mutabilityOption, CFStringRef *errorString) {
    CFPropertyListRef result = %orig;
    RXAInspect(result, "CFPropertyListCreateFromXMLData");
    return result;
}

#pragma mark - Registration (what iOS 6 declares to Apple's servers)

// Phase 1A.3: declare tapback support. iOS 27 strips amk/amt/ame from what it sends to the iPhone 5 (verified
// 2026-11-11), most likely because this device does not announce the capability when it registers. Modern
// devices put capability flags in client-data (top level on iOS 6; services[].users[].client-data in rustpush,
// src/ids/user.rs and src/imessage/aps_client.rs). Only the two tapback flags are added, and only into a
// client-data dictionary that already exists: nothing else changes. Off switch: create the file
// /var/mobile/Library/Reactions/no-declare (then re-register).
#define RXA_NO_DECLARE   @"/var/mobile/Library/Reactions/no-declare"
#define RXA_MADRID       @"com.apple.madrid"

static NSArray *RXATapbackFlags(void) {
    // "ack" = acknowledgment, Apple's internal name for tapbacks.
    return [NSArray arrayWithObjects:@"supports-ack-v1", @"supports-emoji-tapbacks", nil];
}

static NSDictionary *RXAWithTapbackFlags(NSDictionary *body, NSUInteger *added, NSUInteger *users) {
    // iOS 6 (verified 2026-11-11): one flat body per registration, client-data at the top level
    // {capabilities, client-data={public-message-identity-key, public-message-identity-version, show-peer-errors},
    //  device-name, hardware-version, os-version, software-version, validation-data}.
    id topClientData = [body objectForKey:@"client-data"];
    if ([topClientData isKindOfClass:[NSDictionary class]]) {
        (*users)++;
        NSMutableDictionary *newClientData = [topClientData mutableCopy];
        for (NSString *flag in RXATapbackFlags()) {
            if (![newClientData objectForKey:flag]) {
                [newClientData setObject:[NSNumber numberWithBool:YES] forKey:flag];
                (*added)++;
            }
        }
        if (*added == 0) {
            return body;
        }
        NSMutableDictionary *newBody = [body mutableCopy];
        [newBody setObject:newClientData forKey:@"client-data"];
        return newBody;
    }
    // Modern layout (rustpush): services[service=com.apple.madrid].users[].client-data.
    id services = [body objectForKey:@"services"];
    if (![services isKindOfClass:[NSArray class]]) {
        return body;
    }
    NSMutableArray *newServices = [NSMutableArray array];
    BOOL changed = NO;
    for (id service in (NSArray *)services) {
        if (![service isKindOfClass:[NSDictionary class]] ||
            ![[service objectForKey:@"service"] isEqual:RXA_MADRID] ||
            ![[service objectForKey:@"users"] isKindOfClass:[NSArray class]]) {
            [newServices addObject:service];
            continue;
        }
        NSMutableArray *newUsers = [NSMutableArray array];
        for (id user in (NSArray *)[service objectForKey:@"users"]) {
            id clientData = [user isKindOfClass:[NSDictionary class]] ? [user objectForKey:@"client-data"] : nil;
            if (![clientData isKindOfClass:[NSDictionary class]]) {
                [newUsers addObject:user];
                continue;
            }
            (*users)++;
            NSMutableDictionary *newClientData = [clientData mutableCopy];
            for (NSString *flag in RXATapbackFlags()) {
                if (![newClientData objectForKey:flag]) {
                    [newClientData setObject:[NSNumber numberWithBool:YES] forKey:flag];
                    (*added)++;
                }
            }
            NSMutableDictionary *newUser = [user mutableCopy];
            [newUser setObject:newClientData forKey:@"client-data"];
            [newUsers addObject:newUser];
        }
        NSMutableDictionary *newService = [service mutableCopy];
        [newService setObject:newUsers forKey:@"users"];
        [newServices addObject:newService];
        changed = YES;
    }
    if (!changed || *added == 0) {
        return body;
    }
    NSMutableDictionary *newBody = [body mutableCopy];
    [newBody setObject:newServices forKey:@"services"];
    return newBody;
}

static void RXALogRegistration(NSString *label, id body) {
    if ([body isKindOfClass:[NSDictionary class]] && [NSThread isMainThread]) {
        gRXAVerbatim = RXARegistrationKeys();
        gRXADescendArrays = YES;
        NSString *desc = RXADescribeDict(body, 0);
        gRXAVerbatim = nil;
        gRXADescendArrays = NO;
        RXALog([NSString stringWithFormat:@"REGISTRATION %@: %@", label, desc]);
    } else if (body) {
        RXALog([NSString stringWithFormat:@"REGISTRATION %@ class %@ (main %d)", label,
                NSStringFromClass([body class]), [NSThread isMainThread] ? 1 : 0]);
    }
}

%group RXARegistration
%hook FTRegistrationMessage
- (id)messageBody {
    id body = %orig;
    id result = body;
    @try {
        RXALogRegistration(@"body", body);
        if ([body isKindOfClass:[NSDictionary class]]) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:RXA_NO_DECLARE]) {
                RXALog(@"REGISTRATION declare: off (no-declare file present)");
            } else {
                NSUInteger added = 0, users = 0;
                result = RXAWithTapbackFlags(body, &added, &users);
                RXALog([NSString stringWithFormat:@"REGISTRATION declare: %lu flag(s) added for %lu user(s)",
                        (unsigned long)added, (unsigned long)users]);
                if (result != body) {
                    RXALogRegistration(@"sent", result);
                }
            }
        }
    } @catch (NSException *e) {
        gRXAVerbatim = nil;
        gRXADescendArrays = NO;
        result = body;
        RXALog(@"REGISTRATION declare failed: original body kept");
    }
    return result;
}
%end
%end

#pragma mark - Class listing (runtime introspection)

static BOOL RXAWantedImage(const char *path) {
    static const char *needles[] = {
        "iMessage.imservice", "SMS.imservice", "IMDaemonCore", "IMDPersistence", "IMDAppleServices",
        "IMDMessageServices", "IMFoundation", "MessageProtection", "IMCore.framework/IMCore",
        "FTServices", "Marco", "IMTransferServices",
    };
    for (size_t i = 0; i < sizeof(needles) / sizeof(needles[0]); i++) {
        if (strstr(path, needles[i])) {
            return YES;
        }
    }
    return NO;
}

static void RXAAppendMethods(NSMutableString *out, Class cls, char sign) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *types = method_getTypeEncoding(methods[i]);
        [out appendFormat:@"%c %s  %s\n", sign, sel_getName(method_getName(methods[i])), types ? types : ""];
    }
    free(methods);
}

static void RXADumpClasses(NSString *reason) {
    @try {
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"# Reactions agent class listing (%@), pid %d, %@\n", reason, (int)getpid(), RXAStamp()];
        uint32_t images = _dyld_image_count();
        NSUInteger total = 0;
        for (uint32_t i = 0; i < images; i++) {
            const char *path = _dyld_get_image_name(i);
            if (!path || !RXAWantedImage(path)) {
                continue;
            }
            unsigned int count = 0;
            const char **names = objc_copyClassNamesForImage(path, &count);
            [out appendFormat:@"\n### %s (%u classes)\n", path, count];
            for (unsigned int j = 0; j < count; j++) {
                Class cls = objc_getClass(names[j]);
                if (!cls) {
                    continue;
                }
                Class sup = class_getSuperclass(cls);
                [out appendFormat:@"\n@interface %s : %s\n", names[j], sup ? class_getName(sup) : "-"];
                unsigned int ivarCount = 0;
                Ivar *ivars = class_copyIvarList(cls, &ivarCount);
                for (unsigned int k = 0; k < ivarCount; k++) {
                    const char *type = ivar_getTypeEncoding(ivars[k]);
                    [out appendFormat:@"  ivar %s  %s\n", ivar_getName(ivars[k]), type ? type : ""];
                }
                free(ivars);
                RXAAppendMethods(out, object_getClass(cls), '+');
                RXAAppendMethods(out, cls, '-');
                [out appendString:@"@end\n"];
                total++;
            }
            free(names);
        }
        NSData *data = [out dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_async(RXAQueue(), ^{
            @try {
                RXAEnsureDir();
                [data writeToFile:RXA_CLASSES atomically:YES];
            } @catch (NSException *e) {
            }
        });
        RXALog([NSString stringWithFormat:@"class listing (%@): %lu classes, %lu bytes", reason,
                (unsigned long)total, (unsigned long)[data length]]);
    } @catch (NSException *e) {
        RXALog(@"class listing failed");
    }
}

#pragma mark - Start

%ctor {
    @autoreleasepool {
        pthread_key_create(&gRXAGuardKey, NULL);
        %init;
        if (objc_getClass("FTRegistrationMessage")) {
            %init(RXARegistration);
        } else {
            RXALog(@"FTRegistrationMessage not found: registration logging off");
        }
        RXALog([NSString stringWithFormat:@"agent loaded in imagent (pid %d), phase 1A.3 (diagnostics + tapback declaration)", (int)getpid()]);
        dispatch_queue_t bg = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), bg, ^{
            RXADumpClasses(@"30 s");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)), bg, ^{
            RXADumpClasses(@"5 min");
        });
    }
}
