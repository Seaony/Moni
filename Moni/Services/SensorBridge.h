#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> * _Nullable MoniAppleSiliconTemperatureSensors(void);
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> * _Nullable MoniAppleSiliconEnergyCounters(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable MoniNVMeSMARTData(void);
FOUNDATION_EXPORT NSData * _Nullable MoniZstdDecompressFrames(NSData *source);
FOUNDATION_EXPORT NSData * _Nullable MoniZstdDecompressFirstFrame(NSData *source);

NS_ASSUME_NONNULL_END
