//
//  CKRecordZoneID.h
//  AgileCloudKit
//
//  Copyright (c) 2015 AgileBits Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface CKRecordZoneID : NSObject <NSSecureCoding, NSCopying>

/* Zone names must be 255 characters or less. Most UTF-8 characters are valid. */
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithZoneName:(NSString *)zoneName;
- (instancetype)initWithZoneName:(NSString *)zoneName ownerName:(NSString *)ownerName NS_DESIGNATED_INITIALIZER;

@property(nonatomic, readonly, strong) NSString *zoneName;
@property(nonatomic, readonly, strong) NSString *ownerName;

@end
