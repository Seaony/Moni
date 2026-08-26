#import "SensorBridge.h"

#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <dlfcn.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;

#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

#define MoniIOHIDEventFieldBase(type) (type << 16)
#define MoniIOHIDEventTypeTemperature 15

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

typedef CFDictionaryRef (*MoniCopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef IOReportSubscriptionRef (*MoniCreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*MoniCreateSamples)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFStringRef (*MoniChannelString)(CFDictionaryRef);
typedef int64_t (*MoniSimpleIntegerValue)(CFDictionaryRef, int32_t);

typedef struct {
    MoniCopyChannelsInGroup copyChannelsInGroup;
    MoniCreateSubscription createSubscription;
    MoniCreateSamples createSamples;
    MoniChannelString channelGetGroup;
    MoniChannelString channelGetName;
    MoniChannelString channelGetUnit;
    MoniSimpleIntegerValue simpleGetIntegerValue;
} MoniIOReportFunctions;

static MoniIOReportFunctions MoniLoadIOReport(void) {
    static MoniIOReportFunctions functions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/usr/lib/libIOReport.dylib",
            RTLD_LAZY | RTLD_LOCAL
        );
        if (handle == NULL) {
            return;
        }
        functions.copyChannelsInGroup = dlsym(handle, "IOReportCopyChannelsInGroup");
        functions.createSubscription = dlsym(handle, "IOReportCreateSubscription");
        functions.createSamples = dlsym(handle, "IOReportCreateSamples");
        functions.channelGetGroup = dlsym(handle, "IOReportChannelGetGroup");
        functions.channelGetName = dlsym(handle, "IOReportChannelGetChannelName");
        functions.channelGetUnit = dlsym(handle, "IOReportChannelGetUnitLabel");
        functions.simpleGetIntegerValue = dlsym(handle, "IOReportSimpleGetIntegerValue");
    });
    return functions;
}

NSDictionary<NSString *, NSNumber *> *MoniAppleSiliconTemperatureSensors(void) {
    static IOHIDEventSystemClientRef client = NULL;
    static CFArrayRef services = NULL;
    static NSArray *names = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *matching = @{
            @"PrimaryUsagePage": @(0xff00),
            @"PrimaryUsage": @(0x0005),
        };
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (client == NULL) {
            return;
        }
        IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)matching);
        services = IOHIDEventSystemClientCopyServices(client);
        if (services == NULL) {
            CFRelease(client);
            client = NULL;
            return;
        }

        NSMutableArray *loadedNames = [NSMutableArray arrayWithCapacity:(NSUInteger)CFArrayGetCount(services)];
        for (CFIndex index = 0; index < CFArrayGetCount(services); index++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
            CFTypeRef property = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            NSString *name = property == NULL ? nil : CFBridgingRelease(property);
            [loadedNames addObject:name ?: NSNull.null];
        }
        names = loadedNames.copy;
    });

    if (services == NULL || names == nil) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
    for (CFIndex index = 0; index < CFArrayGetCount(services); index++) {
        id name = names[(NSUInteger)index];
        if (![name isKindOfClass:NSString.class]) {
            continue;
        }

        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, MoniIOHIDEventTypeTemperature, 0, 0);
        if (event == NULL) {
            continue;
        }
        double value = IOHIDEventGetFloatValue(
            event,
            MoniIOHIDEventFieldBase(MoniIOHIDEventTypeTemperature)
        );
        CFRelease(event);
        if (value >= 0 && value <= 110) {
            result[name] = @(value);
        }
    }
    return result.count == 0 ? nil : result;
}

NSDictionary<NSString *, NSNumber *> *MoniAppleSiliconEnergyCounters(void) {
    MoniIOReportFunctions functions = MoniLoadIOReport();
    if (functions.copyChannelsInGroup == NULL ||
        functions.createSubscription == NULL ||
        functions.createSamples == NULL ||
        functions.channelGetGroup == NULL ||
        functions.channelGetName == NULL ||
        functions.channelGetUnit == NULL ||
        functions.simpleGetIntegerValue == NULL) {
        return nil;
    }

    static CFMutableDictionaryRef channels = NULL;
    static IOReportSubscriptionRef subscription = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CFDictionaryRef copied = functions.copyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
        if (copied == NULL) {
            return;
        }
        channels = CFDictionaryCreateMutableCopy(
            kCFAllocatorDefault,
            CFDictionaryGetCount(copied),
            copied
        );
        CFRelease(copied);
        if (channels == NULL || !CFDictionaryContainsKey(channels, CFSTR("IOReportChannels"))) {
            return;
        }
        CFMutableDictionaryRef subscribedChannels = NULL;
        subscription = functions.createSubscription(NULL, channels, &subscribedChannels, 0, NULL);
        if (subscribedChannels != NULL) {
            CFRelease(subscribedChannels);
        }
    });

    if (channels == NULL || subscription == NULL) {
        return nil;
    }

    CFDictionaryRef sample = functions.createSamples(subscription, channels, NULL);
    if (sample == NULL) {
        return nil;
    }
    NSDictionary *dictionary = CFBridgingRelease(sample);
    NSArray *items = dictionary[@"IOReportChannels"];
    if (![items isKindOfClass:NSArray.class]) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
    for (id value in items) {
        CFDictionaryRef channel = (__bridge CFDictionaryRef)value;
        NSString *group = (__bridge NSString *)functions.channelGetGroup(channel);
        NSString *name = (__bridge NSString *)functions.channelGetName(channel);
        NSString *unit = (__bridge NSString *)functions.channelGetUnit(channel);
        if (![group isEqualToString:@"Energy Model"] || name.length == 0 || unit.length == 0) {
            continue;
        }

        double joules = (double)functions.simpleGetIntegerValue(channel, 0);
        if ([unit isEqualToString:@"mJ"]) {
            joules /= 1e3;
        } else if ([unit isEqualToString:@"uJ"]) {
            joules /= 1e6;
        } else if ([unit isEqualToString:@"nJ"]) {
            joules /= 1e9;
        } else {
            continue;
        }

        if ([name hasSuffix:@"CPU Energy"]) {
            result[@"CPU"] = @(joules);
        } else if ([name hasSuffix:@"GPU Energy"]) {
            result[@"GPU"] = @(joules);
        } else if ([name hasPrefix:@"ANE"]) {
            result[@"ANE"] = @(joules);
        } else if ([name hasPrefix:@"DRAM"]) {
            result[@"RAM"] = @(joules);
        } else if ([name hasPrefix:@"PCI"] && [name hasSuffix:@"Energy"]) {
            result[@"PCI"] = @(joules);
        }
    }
    return result.count == 0 ? nil : result;
}
