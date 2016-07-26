//
//  ReportInterpreter.m
//  Sentry
//
//  Created by Karl on 2016-07-11.
//

#import "ReportInterpreter.h"
#import "Container+DeepSearch.h"

@interface ReportInterpreter ()
@property NSDictionary *report;
@property NSInteger crashedThreadIndex;
@property NSDictionary *exceptionContext;
@property NSArray *binaryImages;
@property NSArray *threads;
@property NSDictionary *systemContext;
@property NSDictionary *reportContext;
@property NSString *platform;
@end

@implementation ReportInterpreter

+ (instancetype)interpreterForReport:(NSDictionary *)report
{
    return [[ReportInterpreter alloc] initWithReport:report];
}

- (instancetype)initWithReport:(NSDictionary *)report
{
    if((self = [super init]))
    {
        self.report = report;
        self.platform = @"TODO";
        self.binaryImages = report[@"binary_images"];
        self.systemContext = report[@"system"];
        self.reportContext = report[@"report"];
        NSDictionary *crashContext = report[@"crash"];
        self.exceptionContext = crashContext[@"error"];
        self.threads = crashContext[@"threads"];
        for(NSUInteger i = 0; i < self.threads.count; i++)
        {
            NSDictionary *thread = self.threads[i];
            if(thread[@"crashed"])
            {
                self.crashedThreadIndex = i;
                break;
            }
        }
    }
    return self;
}

static inline id safeNil(id value)
{
    return value ?: [NSNull null];
}

static inline NSString *hexAddress(NSNumber *value)
{
    return [NSString stringWithFormat:@"0x%016llx", value.unsignedLongLongValue];
}

- (BOOL) isCustomReport
{
    NSString *reportType = [self.report objectForKeyPath:@"report/type"];
    return [reportType isEqualToString:@"custom"];
}

- (NSString *)deviceName
{
    return nil; // TODO
}

- (NSString *)family
{
    NSString *systemName = self.systemContext[@"system_name"];
    NSArray *components = [systemName componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return components[0];
}

- (BOOL) isRunningOnAMac
{
    return [self.systemContext[@"cpu_arch"] isEqualToString:@"x86"] && ![self.systemContext[@"build_type"] isEqualToString:@"simulator"];
}

- (NSString *)model
{
    if(self.isRunningOnAMac)
    {
        return self.systemContext[@"model"];
    }
    return self.systemContext[@"machine"];
}

- (NSString *)modelID
{
    if(self.isRunningOnAMac)
    {
        return nil;
    }
    return self.systemContext[@"model"];
}

- (NSString *)batteryLevel
{
    return nil; // Not recording this yet
}

- (NSString *)orientation
{
    return nil; // Not recording this yet
}

- (NSDictionary *)deviceContext
{
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"name"] = self.deviceName;
    result[@"family"] = self.family;
    result[@"model"] = self.model;
    result[@"model_id"] = self.modelID;
    result[@"architecture"] = self.systemContext[@"cpu_arch"];
    result[@"battery_level"] = self.batteryLevel;
    result[@"orientation"] = self.orientation;
    return result;
}

- (NSDictionary *)osContext
{
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"name"] = self.systemContext[@"system_name"];
    result[@"version"] = self.systemContext[@"system_version"];
    result[@"build"] = self.systemContext[@"os_version"];
    result[@"kernel_version"] = self.systemContext[@"kernel_version"];
    result[@"rooted"] = self.systemContext[@"jailbroken"];
    return result;
}

- (NSDictionary *)runtimeContext
{
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"name"] = self.systemContext[@"CFBundleName"];
    result[@"version"] = self.systemContext[@"CFBundleVersion"];
    return result;
}

- (NSArray *) rawStackTraceForThreadIndex:(NSInteger)threadIndex
{
    NSDictionary *thread = self.threads[threadIndex];
    return thread[@"backtrace"][@"contents"];
}

- (NSDictionary *)binaryImageForAddress:(uintptr_t) address
{
    for(NSDictionary *binaryImage in self.binaryImages)
    {
        uintptr_t imageStart = (uintptr_t)[binaryImage[@"image_addr"] unsignedLongLongValue];
        uintptr_t imageEnd = imageStart + (uintptr_t)[binaryImage[@"image_size"] unsignedLongLongValue];
        if(address >= imageStart && address < imageEnd)
        {
            return binaryImage;
        }
    }
    return nil;
}

- (NSDictionary *)threadAtIndex:(NSInteger)threadIndex
{
    NSMutableDictionary *result = [NSMutableDictionary new];
    NSDictionary *thread = self.threads[threadIndex];
    result[@"stacktrace"] = [self stackTraceForThreadIndex:threadIndex showRegisters:NO];
    result[@"id"] = thread[@"index"];
    result[@"crashed"] = thread[@"crashed"];
    result[@"current"] = thread[@"current_thread"];
    result[@"name"] = thread[@"name"];
    if(!result[@"name"])
    {
        result[@"name"] = thread[@"dispatch_queue"];
    }
    return result;
}

- (NSDictionary *)stackFrameAtIndex:(NSInteger)frameIndex inThreadIndex:(NSInteger)threadIndex showRegisters:(BOOL)showRegisters
{
    NSDictionary *frame = [self rawStackTraceForThreadIndex:threadIndex][frameIndex];
    uintptr_t instructionAddress = (uintptr_t)[frame[@"instruction_addr"] unsignedLongLongValue];
    NSDictionary *binaryImage = [self binaryImageForAddress:instructionAddress];
    BOOL isAppImage = [binaryImage[@"name"] containsString:@"/Bundle/Application/"];
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"function"] = frame[@"symbol_name"];
    result[@"package"] = binaryImage[@"name"];
    result[@"image_addr"] = hexAddress(binaryImage[@"image_addr"]);
    result[@"platform"] = self.platform;
    result[@"instruction_addr"] = hexAddress(frame[@"instruction_addr"]);
    result[@"symbol_addr"] = hexAddress(frame[@"symbol_addr"]);
    result[@"in_app"] = [NSNumber numberWithBool:isAppImage];
    if(showRegisters)
    {
        result[@"vars"] = frame[@"registers"][@"basic"];
    }
    return result;
}

- (NSDictionary *)stackTraceForThreadIndex:(NSInteger)threadIndex showRegisters:(BOOL)showRegisters
{
    NSInteger frameCount = [self rawStackTraceForThreadIndex:threadIndex].count;
    int skipped = (int)[self.threads[threadIndex][@"backtrace"][@"skipped"] integerValue];
    NSMutableArray *frames = [NSMutableArray arrayWithCapacity:frameCount];
    for(NSInteger i = frameCount - 1; i >= 0; i--)
    {
        [frames addObject:[self stackFrameAtIndex:i inThreadIndex:threadIndex showRegisters:showRegisters]];
    }
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"frames"] = frames;
    if(skipped > 0)
    {
        result[@"frames_omitted"] = @[@"1", [NSString stringWithFormat:@"%d", skipped + 1]];
    }
    return result;
}

- (NSArray *)images
{
    NSMutableArray *result = [NSMutableArray new];
    for(NSDictionary *sourceImage in self.binaryImages)
    {
        NSMutableDictionary *image = [NSMutableDictionary new];
        image[@"type"] = @"apple";
        image[@"cpu_type"] = sourceImage[@"cpu_type"];
        image[@"cpu_subtype"] = sourceImage[@"cpu_subtype"];
        image[@"image_addr"] = hexAddress(sourceImage[@"image_addr"]);
        image[@"image_size"] = sourceImage[@"image_size"];
        image[@"image_vmaddr"] = hexAddress(sourceImage[@"image_vmaddr"]);
        image[@"name"] = sourceImage[@"name"];
        image[@"uuid"] = sourceImage[@"uuid"];
        [result addObject:image];
    }
    return result;
}

- (NSDictionary *)exceptionInterface
{
    NSMutableDictionary *result = [NSMutableDictionary new];
    NSString *type = self.exceptionContext[@"type"];;
    NSString *value = self.exceptionContext[@"reason"];
    NSDictionary *crashedThread = self.threads[self.crashedThreadIndex];

    if([type isEqualToString:@"nsexception"])
    {
        type = self.exceptionContext[@"nsexception"][@"name"];
    }
    if([type isEqualToString:@"cpp_exception"])
    {
        type = self.exceptionContext[@"cpp_exception"][@"name"];
    }
    if([type isEqualToString:@"mach"])
    {
        type = self.exceptionContext[@"mach"][@"exception_name"];
        value = [NSString stringWithFormat:@"Exception %@, Code %@, Subcode %@",
                 self.exceptionContext[@"mach"][@"exception"],
                 self.exceptionContext[@"mach"][@"code"],
                 self.exceptionContext[@"mach"][@"subcode"]];
    }
    if([type isEqualToString:@"signal"])
    {
        type = self.exceptionContext[@"signal"][@"name"];
        value = [NSString stringWithFormat:@"Signal %@, Code %@",
                 self.exceptionContext[@"mach"][@"signal"],
                 self.exceptionContext[@"mach"][@"code"]];
    }
    if([type isEqualToString:@"user"])
    {
        type = self.exceptionContext[@"user_reported"][@"name"];
        // TODO: with custom stack
        // TODO: also platform field for customs stack
    }

    result[@"type"] = type;
    result[@"value"] = value;
    result[@"thread_id"] = crashedThread[@"index"];
    result[@"stacktrace"] = [self stackTraceForThreadIndex:self.crashedThreadIndex showRegisters:YES];
    return result;
}

- (NSArray *)threadsInterface
{
    NSMutableArray *result = [NSMutableArray new];
    for(NSInteger threadIndex = 0; threadIndex < self.threads.count; threadIndex++)
    {
        [result addObject:[self threadAtIndex:threadIndex]];
    }
    return result;
}

- (NSDictionary *)contextsInterface
{
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"device"] = self.deviceContext;
    result[@"os"] = self.osContext;
    result[@"runtime"] = self.runtimeContext;
    return result;
}

- (NSDictionary *)breadcrumbsInterface
{
    return [self.report objectForKeyPath:@"user/breadcrumbs"];
}

- (NSDictionary *)debugInterface
{
    NSMutableDictionary *result = [NSMutableDictionary new];
    // TODO: sdk_info - Do outside?
    result[@"images"] = self.images;
    return result;
}

- (NSDictionary *)requiredAttributes
{
    NSMutableDictionary *attributes = [NSMutableDictionary new];
    
    NSString *level;
    
    if(self.isCustomReport)
    {
        level = self.report[@"level"];
    }
    else
    {
        level = @"fatal";
    }
    
    attributes[@"event_id"] = [[self.report objectForKeyPath:@"report/id"] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    attributes[@"timestamp"] = [self.report objectForKeyPath:@"report/timestamp"];
    attributes[@"platform"] = @"cocoa";
    attributes[@"level"] = level;
    
    return attributes;
}

- (NSDictionary *)optionalAttributes
{
    NSString *unset = nil;
    
    NSMutableDictionary *attributes = [NSMutableDictionary new];
    
    attributes[@"logger"] = unset;
    attributes[@"release"] = [self.report objectForKeyPath:@"system/CFBundleVersion"];
    attributes[@"tags"] = [self.report objectForKeyPath:@"user/tags"];
    attributes[@"extra"] = [self.report objectForKeyPath:@"user/extra"];
    attributes[@"fingerprint"] = [self.report objectForKeyPath:@"user/fingerprint"];
    
    return attributes;
}

@end
