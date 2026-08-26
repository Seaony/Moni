#import "SensorBridge.h"

#include "../ThirdParty/CZstd/zstd.h"

static const NSUInteger MoniZstdMaximumDecompressedSize = 2ULL * 1024 * 1024 * 1024;

NSData * _Nullable MoniZstdDecompressFrames(NSData *source) {
    if (source.length == 0) {
        return [NSData data];
    }

    NSMutableData *output = [NSMutableData data];
    const uint8_t *bytes = source.bytes;
    NSUInteger offset = 0;
    while (offset < source.length) {
        const void *frame = bytes + offset;
        size_t remaining = source.length - offset;
        size_t frameSize = ZSTD_findFrameCompressedSize(frame, remaining);
        if (ZSTD_isError(frameSize) || frameSize == 0 || frameSize > remaining) {
            return nil;
        }

        unsigned long long contentSize = ZSTD_getFrameContentSize(frame, frameSize);
        if (contentSize == ZSTD_CONTENTSIZE_ERROR) {
            return nil;
        }

        NSUInteger destinationSize;
        if (contentSize == ZSTD_CONTENTSIZE_UNKNOWN) {
            destinationSize = MIN(MAX(frameSize * 64, 64 * 1024), 64 * 1024 * 1024);
        } else {
            if (contentSize > MoniZstdMaximumDecompressedSize) {
                return nil;
            }
            destinationSize = MAX((NSUInteger)contentSize, 1);
        }
        if (output.length > MoniZstdMaximumDecompressedSize - destinationSize) {
            return nil;
        }

        NSMutableData *destination = [NSMutableData dataWithLength:destinationSize];
        size_t written = ZSTD_decompress(destination.mutableBytes, destinationSize, frame, frameSize);
        if (ZSTD_isError(written)) {
            return nil;
        }
        [output appendBytes:destination.bytes length:written];
        offset += frameSize;
    }
    return output;
}
