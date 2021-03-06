//
//  VICacheManager.m
//  VIMediaCacheDemo
//
//  Created by Vito on 4/21/16.
//  Copyright © 2016 Vito. All rights reserved.
//

#import "VICacheManager.h"
#import "VIMediaDownloader.h"

NSString *VICacheManagerDidUpdateCacheNotification = @"VICacheManagerDidUpdateCacheNotification";
NSString *VICacheManagerDidFinishCacheNotification = @"VICacheManagerDidFinishCacheNotification";

NSString *VICacheConfigurationKey = @"VICacheConfigurationKey";
NSString *VICacheFinishedErrorKey = @"VICacheFinishedErrorKey";

static NSString *kMCMediaCacheDirectory;
static NSTimeInterval kMCMediaCacheNotifyInterval;
static unsigned long long kMCMediaCacheMaxSize;

@implementation VICacheManager

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self setCacheDirectory:[NSTemporaryDirectory() stringByAppendingPathComponent:@"vimedia"]];
        [self setCacheUpdateNotifyInterval:0.1];
        [self setMaxCacheSize: 1024 * 512];
    });
}

#pragma mark - Getter & Setter

+ (void)setCacheDirectory:(NSString *)cacheDirectory {
    kMCMediaCacheDirectory = cacheDirectory;
}

+ (NSString *)cacheDirectory {
    return kMCMediaCacheDirectory;
}

+ (NSTimeInterval)cacheUpdateNotifyInterval {
    return kMCMediaCacheNotifyInterval;
}

+ (void)setCacheUpdateNotifyInterval:(NSTimeInterval)interval {
    kMCMediaCacheNotifyInterval = interval;
}

+ (unsigned long long)maxCacheSize {
    return kMCMediaCacheMaxSize;
}

+ (void)setMaxCacheSize:(unsigned long long)size {
    kMCMediaCacheMaxSize = size;
}

+ (NSString *)cachedFilePathForURL:(NSURL *)url {
    return [[self cacheDirectory] stringByAppendingPathComponent:[url lastPathComponent]];
}

+ (VICacheConfiguration *)cacheConfigurationForURL:(NSURL *)url {
    NSString *filePath = [self cachedFilePathForURL:url];
    VICacheConfiguration *configuration = [VICacheConfiguration configurationWithFilePath:filePath];
    return configuration;
}

#pragma mark - Cache Clean

+ (void)cleanAllCacheWithError:(NSError **)error {
    [self cleanCacheWithSize:LONG_MAX error:error];
}

+ (unsigned long long)cleanCacheWithSize:(unsigned long long)size error:(NSError **)error {
    if (size <= 0) {
        return 0;
    }

    // Find downloaing file
    NSMutableSet *downloadingFiles = [NSMutableSet set];
    [[[VIMediaDownloaderStatus shared] urls] enumerateObjectsUsingBlock:^(NSURL * _Nonnull obj, BOOL * _Nonnull stop) {
        NSString *file = [self cachedFilePathForURL:obj];
        [downloadingFiles addObject:file];
        NSString *configurationPath = [VICacheConfiguration configurationFilePathForFilePath:file];
        [downloadingFiles addObject:configurationPath];
    }];

    // Remove files
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *cacheDirectory = [self cacheDirectory];
    NSArray *filePaths = [self _vi_sortedFilePathsOfDirectoryPath:cacheDirectory];

    unsigned long long cleanedSize = 0;
    if (filePaths.count) {
        for (NSString *path in filePaths) {
            NSString *filePath = [cacheDirectory stringByAppendingPathComponent:path];
            if ([downloadingFiles containsObject:filePath]) {
                continue;
            }

            unsigned long long aSize = [self _vi_sizeOfFileManager:fileManager filePath:filePath error:error];
            if (aSize == -1) {
                break;
            }

            if (![fileManager removeItemAtPath:filePath error:error]) {
                break;
            }

            cleanedSize += aSize;
            if (cleanedSize >= size) {
                break;
            }
        }
    }

    return cleanedSize;
}

/**
 Get file path array of the dir sorted by `NSFileCreationDate` in ascending order.
 */
+ (NSArray<NSString *> *)_vi_sortedFilePathsOfDirectoryPath:(NSString *)dirPath {
    NSArray *subPaths = [[NSFileManager defaultManager] subpathsAtPath:dirPath];
    NSArray *sortedPaths = [subPaths sortedArrayUsingComparator:^(NSString *subPath1, NSString *subPath2) {
        NSString *filePath1 = [dirPath stringByAppendingPathComponent:subPath1];
        NSString *filePath2 = [dirPath stringByAppendingPathComponent:subPath2];
        return [[self _vi_creationDateOfFilePath:filePath1] compare:[self _vi_creationDateOfFilePath:filePath2]];
    }];

    return sortedPaths;
}

+ (id)_vi_creationDateOfFilePath:(NSString *)filePath {
    NSDictionary *fileInfo = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    return [fileInfo objectForKey:NSFileCreationDate];
}

+ (void)cleanCacheForURL:(NSURL *)url error:(NSError **)error {
    if ([[VIMediaDownloaderStatus shared] containsURL:url]) {
        NSString *description = [NSString stringWithFormat:NSLocalizedString(@"Clean cache for url `%@` can't be done, because it's downloading", nil), url];
        *error = [NSError errorWithDomain:@"com.mediadownload" code:2 userInfo:@{NSLocalizedDescriptionKey: description}];
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *filePath = [self cachedFilePathForURL:url];

    if ([fileManager fileExistsAtPath:filePath]) {
        if (![fileManager removeItemAtPath:filePath error:error]) {
            return;
        }
    }

    NSString *configurationPath = [VICacheConfiguration configurationFilePathForFilePath:filePath];
    if ([fileManager fileExistsAtPath:configurationPath]) {
        if (![fileManager removeItemAtPath:configurationPath error:error]) {
            return;
        }
    }
}

#pragma mark - Utils

+ (unsigned long long)calculateCachedSizeWithError:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *cacheDirectory = [self cacheDirectory];
    NSArray *files = [fileManager contentsOfDirectoryAtPath:cacheDirectory error:error];
    unsigned long long size = 0;
    if (files) {
        for (NSString *path in files) {
            NSString *filePath = [cacheDirectory stringByAppendingPathComponent:path];
            unsigned long long aSize = [self _vi_sizeOfFileManager:fileManager filePath:filePath error:error];
            if (aSize == -1) {
                size = -1;
                break;
            }

            size += aSize;
        }
    }
    return size;
}

+ (unsigned long long)_vi_sizeOfFileManager:(NSFileManager *)fm filePath:(NSString *)filePath error:(NSError **)error {
    NSDictionary<NSFileAttributeKey, id> *attribute = [fm attributesOfItemAtPath:filePath error:error];
    if (!attribute) {
        return -1;
    }
    return [attribute fileSize];
}

+ (BOOL)addCacheFile:(NSString *)filePath forURL:(NSURL *)url error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSString *cachePath = [VICacheManager cachedFilePathForURL:url];
    NSString *cacheFolder = [cachePath stringByDeletingLastPathComponent];
    if (![fileManager fileExistsAtPath:cacheFolder]) {
        if (![fileManager createDirectoryAtPath:cacheFolder
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:error]) {
            return NO;
        }
    }

    if (![fileManager copyItemAtPath:filePath toPath:cachePath error:error]) {
        return NO;
    }

    if (![VICacheConfiguration createAndSaveDownloadedConfigurationForURL:url error:error]) {
        [fileManager removeItemAtPath:cachePath error:nil]; // if remove failed, there is nothing we can do.
        return NO;
    }
    
    return YES;
}

@end
