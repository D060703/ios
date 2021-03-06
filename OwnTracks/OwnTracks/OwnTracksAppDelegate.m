//
//  OwnTracksAppDelegate.m
//  OwnTracks
//
//  Created by Christoph Krey on 03.02.14.
//  Copyright (c) 2014 OwnTracks. All rights reserved.
//

#import "OwnTracksAppDelegate.h"
#import "CoreData.h"
#import "Friend+Create.h"
#import "Location+Create.h"
#import "AlertView.h"
#import "LocationManager.h"

@interface OwnTracksAppDelegate()
@property (strong, nonatomic) NSTimer *disconnectTimer;
@property (strong, nonatomic) NSTimer *activityTimer;
@property (strong, nonatomic) UIAlertView *alertView;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property (strong, nonatomic) void (^completionHandler)(UIBackgroundFetchResult);
@property (strong, nonatomic) CoreData *coreData;
@property (strong, nonatomic) NSString *processingMessage;
@property (strong, nonatomic) CMStepCounter *stepCounter;
@property (strong, nonatomic) CMPedometer *pedometer;
@end

#define BACKGROUND_DISCONNECT_AFTER 8.0
#define REMINDER_AFTER 300.0
#define MAX_OTHER_LOCATIONS 1

#ifdef DEBUG
#define DEBUGAPP TRUE
#else
#define DEBUGAPP FALSE
#endif

@implementation OwnTracksAppDelegate

#pragma ApplicationDelegate

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    if (DEBUGAPP) {
        NSLog(@"willFinishLaunchingWithOptions");
        NSEnumerator *enumerator = [launchOptions keyEnumerator];
        NSString *key;
        while ((key = [enumerator nextObject])) {
            NSLog(@"%@:%@", key, [[launchOptions objectForKey:key] description]);
        }
    }
    
    self.backgroundTask = UIBackgroundTaskInvalid;
    self.completionHandler = nil;
    
    
    if ([[[UIDevice currentDevice] systemVersion] compare:@"7.0"] != NSOrderedAscending) {
        if (DEBUGAPP) NSLog(@"setMinimumBackgroundFetchInterval %f", UIApplicationBackgroundFetchIntervalMinimum);
        [application setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalMinimum];
    }

    if ([[[UIDevice currentDevice] systemVersion] compare:@"8.0"] != NSOrderedAscending) {
        UIUserNotificationSettings *settings = [UIUserNotificationSettings settingsForTypes:
                                                UIUserNotificationTypeAlert |
                                                UIUserNotificationTypeBadge |
                                                UIUserNotificationTypeSound
                                                                                 categories:[NSSet setWithObjects:nil]];
        if (DEBUGAPP) NSLog(@"registerUserNotificationSettings %@", settings);
        [application registerUserNotificationSettings:settings];
    }
    
    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    if (DEBUGAPP) {
        NSLog(@"didFinishLaunchingWithOptions");
        NSEnumerator *enumerator = [launchOptions keyEnumerator];
        NSString *key;
        while ((key = [enumerator nextObject])) {
            NSLog(@"%@:%@", key, [[launchOptions objectForKey:key] description]);
        }
    }
    /*
     * Core Data using UIManagedDocument
     */
    
    self.coreData = [[CoreData alloc] init];
    UIDocumentState state;
    
    do {
        state = self.coreData.documentState;
        if (state & UIDocumentStateClosed || ![CoreData theManagedObjectContext]) {
            NSLog(@"documentState 0x%02lx theManagedObjectContext %@",
                  (long)self.coreData.documentState,
                  [CoreData theManagedObjectContext]);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    } while (state & UIDocumentStateClosed || ![CoreData theManagedObjectContext]);
    
    /*
     * Settings
     */
    
    self.settings = [[Settings alloc] init];
    
    /*
     * MQTT connection
     */
    
    self.connection = [[Connection alloc] init];
    self.connection.delegate = self;
    
    [self connect];
    
    // Register for battery level and state change notifications.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(batteryLevelChanged:)
                                                 name:UIDeviceBatteryLevelDidChangeNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(batteryStateChanged:)
                                                 name:UIDeviceBatteryStateDidChangeNotification object:nil];
    
    
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:TRUE];
    
    LocationManager *lm = [LocationManager sharedInstance];
    lm.delegate = self;
    lm.monitoring = [self.settings intForKey:@"monitoring_preference"];
    lm.ranging = [self.settings boolForKey:@"ranging_preference"];
    lm.minDist = [self.settings doubleForKey:@"mindist_preference"];
    lm.minTime = [self.settings doubleForKey:@"mintime_preference"];
    [[LocationManager sharedInstance] start];
    
    return YES;
}

- (void)saveContext
{
    NSManagedObjectContext *managedObjectContext = [CoreData theManagedObjectContext];
    if (managedObjectContext != nil) {
        if ([managedObjectContext hasChanges]) {
            NSError *error = nil;
            if (DEBUGAPP) NSLog(@"save");
            if (![managedObjectContext save:&error]) {
                NSString *message = [NSString stringWithFormat:@"%@", error.localizedDescription];
                if (DEBUGAPP) NSLog(@"%@", message);
                [AlertView alert:@"save" message:[message substringToIndex:128]];
            }
        }
    }
}

- (void)batteryLevelChanged:(NSNotification *)notification
{
    if (DEBUGAPP) NSLog(@"batteryLevelChanged %.0f", [UIDevice currentDevice].batteryLevel);
    // No, we do not want to switch off location monitoring when battery gets low
}

- (void)batteryStateChanged:(NSNotification *)notification
{
    if (DEBUGAPP) {
        const NSDictionary *states = @{
                                       @(UIDeviceBatteryStateUnknown): @"unknown",
                                       @(UIDeviceBatteryStateUnplugged): @"unplugged",
                                       @(UIDeviceBatteryStateCharging): @"charging",
                                       @(UIDeviceBatteryStateFull): @"full"
                                       };
        
        NSLog(@"batteryStateChanged %@ (%ld)",
              states[@([UIDevice currentDevice].batteryState)],
              (long)[UIDevice currentDevice].batteryState);
    }
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication
         annotation:(id)annotation
{
    if (DEBUGAPP) NSLog(@"openURL %@ from %@ annotation %@", url, sourceApplication, annotation);
    
    if (url) {
        NSInputStream *input = [NSInputStream inputStreamWithURL:url];
        if ([input streamError]) {
            self.processingMessage = [NSString stringWithFormat:@"inputStreamWithURL %@ %@", [input streamError], url];
            return FALSE;
        }
        [input open];
        if ([input streamError]) {
            self.processingMessage = [NSString stringWithFormat:@"open %@ %@", [input streamError], url];
            return FALSE;
        }
        
        NSError *error;
        NSString *extension = [url pathExtension];
        if ([extension isEqualToString:@"otrc"] || [extension isEqualToString:@"mqtc"]) {
            error = [self.settings fromStream:input];
        } else if ([extension isEqualToString:@"otrw"] || [extension isEqualToString:@"mqtw"]) {
            error = [self.settings waypointsFromStream:input];
        } else {
            error = [NSError errorWithDomain:@"OwnTracks" code:2 userInfo:@{@"extension":extension}];
        }
        
        if (error) {
            self.processingMessage = [NSString stringWithFormat:@"Error processing file %@: %@",
                                      [url lastPathComponent],
                                      error.localizedDescription];
            return FALSE;
        }
        self.processingMessage = [NSString stringWithFormat:@"File %@ successfully processed)",
                                  [url lastPathComponent]];
    }
    return TRUE;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    if (DEBUGAPP) NSLog(@"applicationWillResignActive");
    [self saveContext];
    [[LocationManager sharedInstance] wakeup];
    [self.connection disconnect];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    if (DEBUGAPP) NSLog(@"applicationDidEnterBackground");
    self.backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
                               if (DEBUGAPP) NSLog(@"BackgroundTaskExpirationHandler");
                               /*
                                * we might end up here if the connection could not be closed within the given
                                * background time
                                */
                               if (self.backgroundTask) {
                                   [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
                                   self.backgroundTask = UIBackgroundTaskInvalid;
                               }
                           }];
    if ([UIApplication sharedApplication].applicationIconBadgeNumber) {
        [self notification:@"Undelivered messages. Tap to restart"
                     after:REMINDER_AFTER
                  userInfo:@{@"notify": @"undelivered"}];
    }
}


- (void)applicationWillEnterForeground:(UIApplication *)application
{
    if (DEBUGAPP) NSLog(@"applicationWillEnterForeground");
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    if (DEBUGAPP) NSLog(@"applicationDidBecomeActive");
    
    if (self.processingMessage) {
        [AlertView alert:@"openURL" message:self.processingMessage];
        self.processingMessage = nil;
        [self reconnect];
    }
    
    if (self.coreData.documentState) {
        NSString *message = [NSString stringWithFormat:@"documentState 0x%02lx %@",
                             (long)self.coreData.documentState,
                             self.coreData.fileURL];
        [AlertView alert:@"CoreData" message:message];
    }
    
    [self.connection connectToLast];
    
    [[LocationManager sharedInstance] wakeup];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    if (DEBUGAPP) NSLog(@"applicationWillTerminate");
    [[LocationManager sharedInstance] stop];
    [self saveContext];
    [self notification:@"App terminated. Tap to restart" after:REMINDER_AFTER userInfo:nil];
}

- (void)application:(UIApplication *)app didReceiveLocalNotification:(UILocalNotification *)notification
{
    if (DEBUGAPP) NSLog(@"didReceiveLocalNotification %@", notification.alertBody);
    if (notification.userInfo) {
        if ([notification.userInfo[@"notify"] isEqualToString:@"friend"]) {
            [AlertView alert:@"Friend Notification" message:notification.alertBody dismissAfter:2.0];
        }
    }
}

- (void)application:(UIApplication *)application didRegisterUserNotificationSettings:(UIUserNotificationSettings *)notificationSettings {
    if (DEBUGAPP) NSLog(@"didRegisterUserNotificationSettings %@", notificationSettings);
}

- (void)application:(UIApplication *)application performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    if (DEBUGAPP) NSLog(@"performFetchWithCompletionHandler");

    self.completionHandler = completionHandler;
    if ([LocationManager sharedInstance].monitoring) {
        [self publishLocation:[LocationManager sharedInstance].location automatic:TRUE addon:@{@"t":@"p"}];
    } else {
        [self.connection connectToLast];
        [self startBackgroundTimer];
    }
}

/*
 *
 * LocationManagerDelegate
 *
 */

- (void)newLocation:(CLLocation *)location {
    [self publishLocation:location automatic:YES addon:nil];
}

- (void)timerLocation:(CLLocation *)location {
    [self publishLocation:location automatic:YES addon:@{@"t": @"t"}];
}

- (void)regionEvent:(CLRegion *)region enter:(BOOL)enter {
    NSString *message = [NSString stringWithFormat:@"%@ %@", (enter ? @"Entering" : @"Leaving"), region.identifier];
    [self notification:message userInfo:nil];

    NSMutableDictionary *addon = [[NSMutableDictionary alloc] init];
    [addon setObject:enter ? @"enter" : @"leave" forKey:@"event" ];

    if ([region isKindOfClass:[CLCircularRegion class]]) {
        [addon setObject:@"c" forKey:@"t" ];
    } else {
        [addon setObject:@"b" forKey:@"t" ];
    }
    
    for (Location *location in [Location allWaypointsOfTopic:[self.settings theGeneralTopic]
                                      inManagedObjectContext:[CoreData theManagedObjectContext]]) {
        if ([region.identifier isEqualToString:location.region.identifier]) {
            location.remark = location.remark; // this touches the location and updates the overlay
            if ([location.share boolValue]) {
                [addon setValue:region.identifier forKey:@"desc"];
            }
        }
    }
    
    [self publishLocation:[LocationManager sharedInstance].location automatic:TRUE addon:addon];
}

- (void)regionState:(CLRegion *)region inside:(BOOL)inside {
    [self.delegate regionState:region inside:inside];
}

- (void)beaconInRange:(CLBeacon *)beacon {
    NSDictionary *jsonObject = @{
                                 @"_type": @"beacon",
                                 @"tst": @(floor([[LocationManager sharedInstance].location.timestamp timeIntervalSince1970])),
                                 @"uuid": [beacon.proximityUUID UUIDString],
                                 @"major": beacon.major,
                                 @"minor": beacon.minor,
                                 @"prox": @(beacon.proximity),
                                 @"acc": @(round(beacon.accuracy)),
                                 @"rssi": @(beacon.rssi)
                                 };
    
    long msgID = [self.connection sendData:[self jsonToData:jsonObject]
                                     topic:[[self.settings theGeneralTopic] stringByAppendingString:@"/beacons"]
                                       qos:[self.settings intForKey:@"qos_preference"]
                                    retain:NO];
    
    if (msgID <= 0) {
        if (DEBUGAPP) {
            NSString *message = [NSString stringWithFormat:@"Beacon %@",
                                 (msgID == -1) ? @"queued" : @"sent"];
            [self notification:message userInfo:nil];
        }
    }
    
    [self.delegate beaconInRange:beacon];
}

#pragma ConnectionDelegate

- (void)showState:(NSInteger)state
{
    self.connectionState = @(state);
    
    /**
     ** This is a hack to ensure the connection gets gracefully closed at the server
     **
     ** If the background task is ended, occasionally the disconnect message is not received well before the server senses the tcp disconnect
     **/
    
    if (state == state_closed) {
        if (self.backgroundTask) {
#ifdef DEBUG
            NSLog(@"endBackGroundTask");
#endif
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        }
        if (self.completionHandler) {
#ifdef DEBUG
            NSLog(@"completionHandler");
#endif
            self.completionHandler(UIBackgroundFetchResultNewData);
            self.completionHandler = nil;
        }
    }
}

- (void)handleMessage:(NSData *)data onTopic:(NSString *)topic retained:(BOOL)retained
{
    NSArray *topicComponents = [topic componentsSeparatedByCharactersInSet:
                                [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSArray *baseComponents = [[self.settings theGeneralTopic] componentsSeparatedByCharactersInSet:
                               [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    
    NSString *device = @"";
    BOOL ownDevice = true;
    
    for (int i = 0; i < [baseComponents count]; i++) {
        if (device.length) {
            device = [device stringByAppendingString:@"/"];
        }
        device = [device stringByAppendingString:topicComponents[i]];
        if (![baseComponents[i] isEqualToString:topicComponents [i]]) {
            ownDevice = false;
        }
    }
    
    if (ownDevice) {
        
        NSError *error;
        NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (dictionary) {
            if ([dictionary[@"_type"] isEqualToString:@"cmd"]) {
#ifdef DEBUG
                NSLog(@"App msg received cmd:%@", dictionary[@"action"]);
#endif
                if ([self.settings boolForKey:@"cmd_preference"]) {
                    if ([dictionary[@"action"] isEqualToString:@"dump"]) {
                        [self dumpTo:topic];
                    } else if ([dictionary[@"action"] isEqualToString:@"reportLocation"]) {
                        if ([LocationManager sharedInstance].monitoring || [self.settings boolForKey:@"allowremotelocation_preference"]) {
                            [self publishLocation:[LocationManager sharedInstance].location automatic:NO addon:@{@"t":@"r"}];
                        }
                    } else if ([dictionary[@"action"] isEqualToString:@"reportSteps"]) {
                        [self stepsFrom:dictionary[@"from"] to:dictionary[@"to"]];
                    } else {
#ifdef DEBUG
                        NSLog(@"unknown action %@", dictionary[@"action"]);
#endif
                    }
                }
            } else if ([dictionary[@"_type"] isEqualToString:@"waypoint"]) {
                // received own waypoint
            } else if ([dictionary[@"_type"] isEqualToString:@"beacon"]) {
                // received own beacon
            } else if ([dictionary[@"_type"] isEqualToString:@"location"]) {
                // received own beacon
            } else {
#ifdef DEBUG
                NSLog(@"unknown record type %@", dictionary[@"_type"]);
#endif
            }
        } else {
#ifdef DEBUG
            NSLog(@"illegal json %@", error.localizedDescription);
#endif
        }
        
    } else /* not ownDevice */ {
        
        if (data.length) {
            
            NSError *error;
            NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (dictionary) {
                if ([dictionary[@"_type"] isEqualToString:@"location"] ||
                    [dictionary[@"_type"] isEqualToString:@"waypoint"]) {
#ifdef DEBUG
                    NSLog(@"App json received lat:%@ lon:%@ acc:%@ tst:%@ alt:%@ vac:%@ cog:%@ vel:%@ tid:%@ rad:%@ event:%@ desc:%@",
                          dictionary[@"lat"],
                          dictionary[@"lon"],
                          dictionary[@"acc"],
                          dictionary[@"tst"],
                          dictionary[@"alt"],
                          dictionary[@"vac"],
                          dictionary[@"cog"],
                          dictionary[@"vel"],
                          dictionary[@"tid"],
                          dictionary[@"rad"],
                          dictionary[@"event"],
                          dictionary[@"desc"]
                          );
#endif
                    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(
                                                                                   [dictionary[@"lat"] doubleValue],
                                                                                   [dictionary[@"lon"] doubleValue]
                                                                                   );
                    
                    CLLocation *location = [[CLLocation alloc] initWithCoordinate:coordinate
                                                                         altitude:[dictionary[@"alt"] intValue]
                                                               horizontalAccuracy:[dictionary[@"acc"] doubleValue]
                                                                 verticalAccuracy:[dictionary[@"vac"] intValue]
                                                                           course:[dictionary[@"cog"] intValue]
                                                                            speed:[dictionary[@"vel"] intValue]
                                                                        timestamp:[NSDate dateWithTimeIntervalSince1970:[dictionary[@"tst"] doubleValue]]];
                    
                    Location *newLocation = [Location locationWithTopic:device
                                                                    tid:dictionary[@"tid"]
                                                              timestamp:location.timestamp
                                                             coordinate:location.coordinate
                                                               accuracy:location.horizontalAccuracy
                                                               altitude:location.altitude
                                                       verticalaccuracy:location.verticalAccuracy
                                                                  speed:location.speed
                                                                 course:location.course                                                               automatic:[dictionary[@"_type"] isEqualToString:@"location"] ? TRUE : FALSE
                                                                 remark:dictionary[@"desc"]
                                                                 radius:[dictionary[@"rad"] doubleValue]
                                                                  share:NO
                                                 inManagedObjectContext:[CoreData theManagedObjectContext]];
                    
                    if (retained) {
#ifdef DEBUG
                        NSLog(@"App ignoring retained event");
#endif
                    } else {
                        NSString *event = dictionary[@"event"];
                        
                        if (event) {
                            if ([event isEqualToString:@"enter"] || [event isEqualToString:@"leave"]) {
                                NSString *name = [newLocation.belongsTo name];
                                [self notification:[NSString stringWithFormat:@"%@ %@s %@",
                                                    name ? name : newLocation.belongsTo.topic,
                                                    event,
                                                    newLocation.remark]
                                          userInfo:@{@"notify": @"friend"}];
                            }
                        }
                    }
                    
                    [self limitLocationsWith:newLocation.belongsTo toMaximum:MAX_OTHER_LOCATIONS];
                    
                } else {
#ifdef DEBUG
                    NSLog(@"unknown record type %@)", dictionary[@"_type"]);
#endif
                    // data other than json _type location/waypoint is silently ignored
                }
            } else {
#ifdef DEBUG
                NSLog(@"illegal json %@)", error.localizedDescription);
#endif
                // data other than json is silently ignored
            }
        } else /* data.length == 0 -> delete friend */ {
            Friend *friend = [Friend existsFriendWithTopic:device inManagedObjectContext:[CoreData theManagedObjectContext]];
            if (friend) {
                [[CoreData theManagedObjectContext] deleteObject:friend];
            }
        }
    }
    [self saveContext];
}

- (void)messageDelivered:(UInt16)msgID
{
#ifdef DEBUG_LOW_LEVEL
    NSString *message = [NSString stringWithFormat:@"Message delivered id=%u", msgID];
    [self notification:message userInfo:nil];
#endif
}

- (void)totalBuffered:(NSUInteger)count
{
    self.connectionBuffered = @(count);

    [UIApplication sharedApplication].applicationIconBadgeNumber = count;
}

- (void)dumpTo:(NSString *)topic
{
    NSDictionary *dumpDict = @{
                               @"_type":@"dump",
                               @"configuration":[self.settings toDictionary],
                               };
#ifdef DEBUG
    NSLog(@"App sending dump to:%@", topic);
#endif
    
    long msgID = [self.connection sendData:[self jsonToData:dumpDict]
                                     topic:topic
                                       qos:[self.settings intForKey:@"qos_preference"]
                                    retain:NO];
    
    if (msgID <= 0) {
#ifdef DEBUG
        NSString *message = [NSString stringWithFormat:@"Dump %@",
                             (msgID == -1) ? @"queued" : @"sent"];
        [self notification:message userInfo:nil];
#endif
    }

}

- (void)stepsFrom:(NSNumber *)from to:(NSNumber *)to
{
    NSDate *toDate;
    NSDate *fromDate;
    if (to && [to isKindOfClass:[NSNumber class]]) {
        toDate = [NSDate dateWithTimeIntervalSince1970:[to doubleValue]];
    } else {
        toDate = [NSDate date];
    }
    if (from && [from isKindOfClass:[NSNumber class]]) {
        fromDate = [NSDate dateWithTimeIntervalSince1970:[from doubleValue]];
    } else {
        NSDateComponents *components = [[NSCalendar currentCalendar]
                                        components: NSCalendarUnitDay |
                                        NSCalendarUnitHour |
                                        NSCalendarUnitMinute |
                                        NSCalendarUnitSecond |
                                        NSCalendarUnitMonth |
                                        NSCalendarUnitYear
                                        fromDate:toDate];
        components.hour = 0;
        components.minute = 0;
        components.second = 0;
        
        fromDate = [[NSCalendar currentCalendar] dateFromComponents:components];
    }
    
    if ([[[UIDevice currentDevice] systemVersion] compare:@"8.0"] != NSOrderedAscending) {
#ifdef DEBUG
        NSLog(@"isStepCountingAvailable %d", [CMPedometer isStepCountingAvailable]);
        NSLog(@"isFloorCountingAvailable %d", [CMPedometer isFloorCountingAvailable]);
        NSLog(@"isDistanceAvailable %d", [CMPedometer isDistanceAvailable]);
#endif
        if (!self.pedometer) {
            self.pedometer = [[CMPedometer alloc] init];
        }
        [self.pedometer queryPedometerDataFromDate:fromDate
                                            toDate:toDate
                                       withHandler:^(CMPedometerData *pedometerData, NSError *error) {
#ifdef DEBUG
             NSLog(@"StepCounter queryPedometerDataFromDate handler %ld %ld %ld %ld %@",
                   [pedometerData.numberOfSteps longValue],
                   [pedometerData.floorsAscended longValue],
                   [pedometerData.floorsDescended longValue],
                   [pedometerData.distance longValue],
                   error.localizedDescription);
#endif
             dispatch_async(dispatch_get_main_queue(), ^{
                 
                 NSMutableDictionary *jsonObject = [[NSMutableDictionary alloc] init];
                 [jsonObject addEntriesFromDictionary:@{
                                              @"_type": @"steps",
                                              @"tst": @(floor([[NSDate date] timeIntervalSince1970])),
                                              @"from": @(floor([fromDate timeIntervalSince1970])),
                                              @"to": @(floor([toDate timeIntervalSince1970])),
                                              }];
                  if (pedometerData) {
                      [jsonObject setObject:pedometerData.numberOfSteps forKey:@"steps"];
                      if (pedometerData.floorsAscended) {
                          [jsonObject setObject:pedometerData.floorsAscended forKey:@"floorsup"];
                      }
                      if (pedometerData.floorsDescended) {
                          [jsonObject setObject:pedometerData.floorsDescended forKey:@"floorsdown"];
                      }
                      if (pedometerData.distance) {
                          [jsonObject setObject:pedometerData.distance forKey:@"distance"];
                      }
                  } else {
                      [jsonObject setObject:@(-1) forKey:@"steps"];
                  }
                 
                 [self.connection sendData:[self jsonToData:jsonObject]
                                     topic:[[self.settings theGeneralTopic] stringByAppendingString:@"/steps"]
                                       qos:[self.settings intForKey:@"qos_preference"]
                                    retain:NO];
             });
         }];
        
    } else if ([[[UIDevice currentDevice] systemVersion] compare:@"7.0"] != NSOrderedAscending) {
#ifdef DEBUG
        NSLog(@"isStepCountingAvailable %d", [CMStepCounter isStepCountingAvailable]);
#endif
        if (!self.stepCounter) {
            self.stepCounter = [[CMStepCounter alloc] init];
        }
        [self.stepCounter queryStepCountStartingFrom:fromDate
                                                  to:toDate
                                             toQueue:[[NSOperationQueue alloc] init]
                                         withHandler:^(NSInteger steps, NSError *error)
         {
#ifdef DEBUG
             NSLog(@"StepCounter queryStepCountStartingFrom handler %ld %@", (long)steps, error.localizedDescription);
#endif
             dispatch_async(dispatch_get_main_queue(), ^{
                 
                 NSDictionary *jsonObject = @{
                                              @"_type": @"steps",
                                              @"tst": @(floor([[NSDate date] timeIntervalSince1970])),
                                              @"from": @(floor([fromDate timeIntervalSince1970])),
                                              @"to": @(floor([toDate timeIntervalSince1970])),
                                              @"steps": error ? @(-1) : @(steps)
                                              };
                 
                 [self.connection sendData:[self jsonToData:jsonObject]
                                     topic:[[self.settings theGeneralTopic] stringByAppendingString:@"/steps"]
                                       qos:[self.settings intForKey:@"qos_preference"]
                                    retain:NO];
             });
         }];
    } else {
        NSDictionary *jsonObject = @{
                                     @"_type": @"steps",
                                     @"tst": @(floor([[NSDate date] timeIntervalSince1970])),
                                     @"from": @(floor([fromDate timeIntervalSince1970])),
                                     @"to": @(floor([toDate timeIntervalSince1970])),
                                     @"steps": @(-1)
                                     };
        
        [self.connection sendData:[self jsonToData:jsonObject]
                            topic:[[self.settings theGeneralTopic] stringByAppendingString:@"/steps"]
                              qos:[self.settings intForKey:@"qos_preference"]
                           retain:NO];
    }
}

#pragma actions

- (void)sendNow
{
    if (DEBUGAPP) NSLog(@"App sendNow");
    [self publishLocation:[LocationManager sharedInstance].location automatic:FALSE addon:@{@"t":@"u"}];
}

- (void)connectionOff
{
    if (DEBUGAPP) NSLog(@"App connectionOff");
    [self.connection disconnect];
}

- (void)reconnect
{
#ifdef DEBUG
    NSLog(@"App reconnect");
#endif
    
    [self.connection disconnect];
    [self connect];
}

- (void)publishLocation:(CLLocation *)location automatic:(BOOL)automatic addon:(NSDictionary *)addon
{
    Location *newLocation = [Location locationWithTopic:[self.settings theGeneralTopic]
                                                    tid:[self.settings stringForKey:@"trackerid_preference"]
                                              timestamp:location.timestamp
                                             coordinate:location.coordinate
                                               accuracy:location.horizontalAccuracy
                                               altitude:location.altitude
                                       verticalaccuracy:location.verticalAccuracy
                                                  speed:(location.speed == -1) ? -1 : location.speed * 3600.0 / 1000.0
                                                 course:location.course
                                              automatic:automatic
                                                 remark:nil
                                                 radius:0
                                                  share:NO
                                 inManagedObjectContext:[CoreData theManagedObjectContext]];
    
    NSData *data = [self encodeLocationData:newLocation type:@"location" addon:addon];
    
    long msgID = [self.connection sendData:data
                                     topic:[self.settings theGeneralTopic]
                                       qos:[self.settings intForKey:@"qos_preference"]
                                    retain:[self.settings boolForKey:@"retain_preference"]];
    
    if (msgID <= 0) {
#ifdef DEBUG_LOW_LEVEL
        NSString *message = [NSString stringWithFormat:@"Location %@",
                             (msgID == -1) ? @"queued" : @"sent"];
        [self notification:message userInfo:nil];
#endif
    }
    
    [self limitLocationsWith:newLocation.belongsTo toMaximum:[self.settings intForKey:@"positions_preference"]];
    [self startBackgroundTimer];
    [self saveContext];
}

- (void)startBackgroundTimer
{
    /**
     *   In background, set timer to disconnect after BACKGROUND_DISCONNECT_AFTER sec. IOS will suspend app after 10 sec.
     **/
    
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        if (self.disconnectTimer && self.disconnectTimer.isValid) {
#ifdef DEBUG
            NSLog(@"App timer still running %@", self.disconnectTimer.fireDate);
#endif
        } else {
            self.disconnectTimer = [NSTimer timerWithTimeInterval:BACKGROUND_DISCONNECT_AFTER
                                                           target:self
                                                         selector:@selector(disconnectInBackground)
                                                         userInfo:Nil repeats:FALSE];
            NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
            [runLoop addTimer:self.disconnectTimer
                      forMode:NSDefaultRunLoopMode];
#ifdef DEBUG
            NSLog(@"App timerWithTimeInterval %@", self.disconnectTimer.fireDate);
#endif
        }
    }
}

- (void)sendEmpty:(Friend *)friend
{
    long msgID = [self.connection sendData:nil
                                     topic:friend.topic
                                       qos:[self.settings intForKey:@"qos_preference"]
                                    retain:YES];
    
    if (msgID <= 0) {
#ifdef DEBUG
        NSString *message = [NSString stringWithFormat:@"Delete send for %@ %@",
                             friend.topic,
                             (msgID == -1) ? @"queued" : @"sent"];
        [self notification:message userInfo:nil];
#endif
    }
}

- (void)sendWayPoint:(Location *)location
{
    NSMutableDictionary *addon = [[NSMutableDictionary alloc]init];
    
    if (location.remark) {
        [addon setValue:location.remark forKey:@"desc"];
    }
    
    NSData *data = [self encodeLocationData:location
                                       type:@"waypoint" addon:addon];
    
    long msgID = [self.connection sendData:data
                                     topic:[[self.settings theGeneralTopic] stringByAppendingString:@"/waypoints"]
                                       qos:[self.settings intForKey:@"qos_preference"]
                                    retain:NO];
    
    if (msgID <= 0) {
#ifdef DEBUG
        NSString *message = [NSString stringWithFormat:@"Waypoint %@",
                             (msgID == -1) ? @"queued" : @"sent"];
        [self notification:message userInfo:nil];
#endif
    }
    [self saveContext];
}

- (void)limitLocationsWith:(Friend *)friend toMaximum:(NSInteger)max
{
    NSArray *allLocations = [Location allAutomaticLocationsWithFriend:friend
                                               inManagedObjectContext:[CoreData theManagedObjectContext]];
    
    for (NSInteger i = [allLocations count]; i > max; i--) {
        Location *location = allLocations[i - 1];
        [[CoreData theManagedObjectContext] deleteObject:location];
    }
}

#pragma internal helpers

- (void)notification:(NSString *)message userInfo:(NSDictionary *)userInfo
{
#ifdef DEBUG
    NSLog(@"App notification %@ userinfo %@", message, userInfo);
#endif
    
    UILocalNotification *notification = [[UILocalNotification alloc] init];
    notification.alertBody = message;
    notification.alertLaunchImage = @"itunesArtwork.png";
    notification.userInfo = userInfo;
    [[UIApplication sharedApplication] presentLocalNotificationNow:notification];

}

- (void)notification:(NSString *)message after:(NSTimeInterval)after userInfo:(NSDictionary *)userInfo
{
#ifdef DEBUG
    NSLog(@"App notification %@ userinfo %@ after %f", message, userInfo, after);
#endif
    
    UILocalNotification *notification = [[UILocalNotification alloc] init];
    notification.alertBody = message;
    notification.alertLaunchImage = @"itunesArtwork.png";
    notification.userInfo = userInfo;
    notification.fireDate = [NSDate dateWithTimeIntervalSinceNow:after];
    [[UIApplication sharedApplication] scheduleLocalNotification:notification];
}

- (void)connect
{
    [self.connection connectTo:[self.settings stringForKey:@"host_preference"]
                          port:[self.settings intForKey:@"port_preference"]
                           tls:[self.settings boolForKey:@"tls_preference"]
                     keepalive:[self.settings intForKey:@"keepalive_preference"]
                         clean:[self.settings intForKey:@"clean_preference"]
                          auth:[self.settings boolForKey:@"auth_preference"]
                          user:[self.settings stringForKey:@"user_preference"]
                          pass:[self.settings stringForKey:@"pass_preference"]
                     willTopic:[self.settings theWillTopic]
                          will:[self jsonToData:@{
                                                  @"tst": [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]],
                                                  @"_type": @"lwt"}]
                       willQos:[self.settings intForKey:@"willqos_preference"]
                willRetainFlag:[self.settings boolForKey:@"willretain_preference"]
                  withClientId:[self.settings theClientId]];
}

- (void)disconnectInBackground
{
#ifdef DEBUG
    NSLog(@"App disconnectInBackground");
#endif
    [[LocationManager sharedInstance] sleep];
    
    self.disconnectTimer = nil;
    
    [self.connection disconnect];
    
    NSInteger number = [UIApplication sharedApplication].applicationIconBadgeNumber;
    if (number) {
        [self notification:[NSString stringWithFormat:@"OwnTracks has %ld undelivered message%@",
                            (long)number,
                            (number > 1) ? @"s" : @""]
                     after:0
                  userInfo:@{@"notify": @"undelivered"}];
    }
}

- (NSData *)jsonToData:(NSDictionary *)jsonObject
{
    NSData *data;
    
    if ([NSJSONSerialization isValidJSONObject:jsonObject]) {
        NSError *error;
        data = [NSJSONSerialization dataWithJSONObject:jsonObject options:0 /* not pretty printed */ error:&error];
        if (!data) {
            NSString *message = [NSString stringWithFormat:@"%@ %@", error.localizedDescription, [jsonObject description]];
            [AlertView alert:@"dataWithJSONObject" message:message];
        }
    } else {
        NSString *message = [NSString stringWithFormat:@"%@", [jsonObject description]];
        [AlertView alert:@"isValidJSONObject" message:message];
    }
    return data;
}


- (NSData *)encodeLocationData:(Location *)location type:(NSString *)type addon:(NSDictionary *)addon
{
    NSMutableDictionary *jsonObject = [@{
                                         @"lat": [NSString stringWithFormat:@"%g", location.coordinate.latitude],
                                         @"lon": [NSString stringWithFormat:@"%g", location.coordinate.longitude],
                                         @"tst": [NSString stringWithFormat:@"%.0f", [location.timestamp timeIntervalSince1970]],
                                         @"_type": [NSString stringWithFormat:@"%@", type]
                                         } mutableCopy];
    
    
    double acc = [location.accuracy doubleValue];
    if (acc > 0) {
        [jsonObject setValue:[NSString stringWithFormat:@"%.0f", acc] forKey:@"acc"];
    }
    
    if ([self.settings boolForKey:@"extendeddata_preference"]) {
        int alt = [location.altitude intValue];
        [jsonObject setValue:@(alt) forKey:@"alt"];
        
        int vac = [location.verticalaccuracy intValue];
        [jsonObject setValue:@(vac) forKey:@"vac"];
        
        int vel = [location.speed intValue];
        [jsonObject setValue:@(vel) forKey:@"vel"];
        
        int cog = [location.course intValue];
        [jsonObject setValue:@(cog) forKey:@"cog"];
    }
    
    [jsonObject setValue:[location.belongsTo getEffectiveTid] forKeyPath:@"tid"];
    
    double rad = [location.regionradius doubleValue];
    if (rad > 0) {
        [jsonObject setValue:[NSString stringWithFormat:@"%.0f", rad] forKey:@"rad"];
    }
    
    if (addon) {
        [jsonObject addEntriesFromDictionary:addon];
    }
    
    if ([type isEqualToString:@"location"]) {
        [jsonObject setValue:[NSString stringWithFormat:@"%.0f", [UIDevice currentDevice].batteryLevel != -1.0 ?
                              [UIDevice currentDevice].batteryLevel * 100.0 : -1.0] forKey:@"batt"];
    }
    
    return [self jsonToData:jsonObject];
}

@end
