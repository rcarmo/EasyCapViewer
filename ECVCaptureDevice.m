/* Copyright (c) 2009-2011, Ben Trask
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY BEN TRASK ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL BEN TRASK BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. */
#import "ECVCaptureDevice.h"
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOMessage.h>
#import <mach/mach_time.h>

// Models
#import "ECVVideoStorage.h"
#import "ECVDeinterlacingMode.h"
#import "ECVVideoFrame.h"

// Controllers
#if !defined(ECV_NO_CONTROLLERS)
#import "ECVController.h"
#import "ECVCaptureController.h"
#endif

// Other Sources
#import "ECVAudioDevice.h"
#import "ECVAudioPipe.h"
#import "ECVDebug.h"
#import "ECVFoundationAdditions.h"
#import "ECVReadWriteLock.h"

// External
#import "BTUserDefaults.h"

#define ECVNanosecondsPerMillisecond 1e6

NSString *const ECVDeinterlacingModeKey = @"ECVDeinterlacingMode";
NSString *const ECVBrightnessKey = @"ECVBrightness";
NSString *const ECVContrastKey = @"ECVContrast";
NSString *const ECVHueKey = @"ECVHue";
NSString *const ECVSaturationKey = @"ECVSaturation";

NSString *const ECVCaptureDeviceErrorDomain = @"ECVCaptureDeviceError";

NSString *const ECVCaptureDeviceVolumeDidChangeNotification = @"ECVCaptureDeviceVolumeDidChange";

static NSString *const ECVVolumeKey = @"ECVVolume";
static NSString *const ECVAudioInputUIDKey = @"ECVAudioInputUID";
static NSString *const ECVUpconvertsFromMonoKey = @"ECVUpconvertsFromMono";

typedef struct {
	IOUSBLowLatencyIsocFrame *list;
	UInt8 *data;
} ECVTransfer;

enum {
	ECVNotPlaying,
	ECVStartPlaying,
	ECVPlaying,
	ECVStopPlaying
}; // _playLock

@interface ECVCaptureDevice(Private)

#if !defined(ECV_NO_CONTROLLERS)
- (void)_startPlayingForControllers;
- (void)_stopPlayingForControllers;
#endif

@end

static NSMutableArray *ECVDeviceClasses = nil;
static NSDictionary *ECVDevicesDictionary = nil;

static void ECVDeviceRemoved(ECVCaptureDevice *device, io_service_t service, uint32_t messageType, void *messageArgument)
{
	if(kIOMessageServiceIsTerminated == messageType) [device performSelector:@selector(noteDeviceRemoved) withObject:nil afterDelay:0.0f inModes:[NSArray arrayWithObject:NSDefaultRunLoopMode]]; // Make sure we don't do anything during a special run loop mode (eg. NSModalPanelRunLoopMode).
}
static void ECVDoNothing(void *refcon, IOReturn result, void *arg0) {}

@implementation ECVCaptureDevice

#pragma mark +ECVCaptureDevice

+ (NSArray *)deviceClasses
{
	return [[ECVDeviceClasses copy] autorelease];
}
+ (void)registerDeviceClass:(Class)cls
{
	if(!cls) return;
	if([ECVDeviceClasses indexOfObjectIdenticalTo:cls] != NSNotFound) return;
	[ECVDeviceClasses addObject:cls];
}
+ (void)unregisterDeviceClass:(Class)cls
{
	if(!cls) return;
	[ECVDeviceClasses removeObjectIdenticalTo:cls];
}

#pragma mark -

+ (NSDictionary *)deviceDictionary
{
	return [ECVDevicesDictionary objectForKey:NSStringFromClass(self)];
}
+ (NSDictionary *)matchingDictionary
{
	NSDictionary *const deviceDict = [self deviceDictionary];
	if(!deviceDict) return nil;
	NSMutableDictionary *const matchingDict = [(NSMutableDictionary *)IOServiceMatching(kIOUSBDeviceClassName) autorelease];
	[matchingDict setObject:[deviceDict objectForKey:@"ECVVendorID"] forKey:[NSString stringWithUTF8String:kUSBVendorID]];
	[matchingDict setObject:[deviceDict objectForKey:@"ECVProductID"] forKey:[NSString stringWithUTF8String:kUSBProductID]];
	return matchingDict;
}
+ (NSArray *)devicesWithIterator:(io_iterator_t)iterator
{
	NSMutableArray *const devices = [NSMutableArray array];
	io_service_t service = IO_OBJECT_NULL;
	while((service = IOIteratorNext(iterator))) {
		NSError *error = nil;
		ECVCaptureDevice *const device = [[[self alloc] initWithService:service error:&error] autorelease];
		if(device) [devices addObject:device];
		else if(error) [devices addObject:error];
		IOObjectRelease(service);
	}
	return devices;
}

#pragma mark +NSObject

+ (void)initialize
{
	if(!ECVDeviceClasses) ECVDeviceClasses = [[NSMutableArray alloc] init];
	if(!ECVDevicesDictionary) {
		ECVDevicesDictionary = [[NSDictionary alloc] initWithContentsOfFile:[[NSBundle bundleForClass:self] pathForResource:@"ECVDevices" ofType:@"plist"]];
		for(NSString *const name in ECVDevicesDictionary) [self registerDeviceClass:NSClassFromString(name)];
	}
}

#pragma mark -ECVCaptureDevice

- (id)initWithService:(io_service_t)service error:(out NSError **)outError
{
	if(outError) *outError = nil;
	if(!service) {
		[self release];
		return nil;
	}
	if(!(self = [super init])) return nil;

	_service = service;
	IOObjectRetain(_service);

	NSMutableDictionary *properties = nil;
	ECVIOReturn(IORegistryEntryCreateCFProperties(_service, (CFMutableDictionaryRef *)&properties, kCFAllocatorDefault, kNilOptions));
	[properties autorelease];
	_productName = [[properties objectForKey:[NSString stringWithUTF8String:kUSBProductString]] copy];

	NSString *const mainSuiteName = [[NSBundle bundleForClass:[self class]] ECV_mainSuiteName];
	NSString *const deviceSuiteName = [NSString stringWithFormat:@"%@.%04x.%04x", mainSuiteName, [[properties objectForKey:[NSString stringWithUTF8String:kUSBVendorID]] unsignedIntegerValue], [[properties objectForKey:[NSString stringWithUTF8String:kUSBProductID]] unsignedIntegerValue]];
	_defaults = [[BTUserDefaults alloc] initWithSuites:[NSArray arrayWithObjects:deviceSuiteName, mainSuiteName, nil]]; // TODO: Use the Vendor and Product ID.
	[_defaults registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
		[NSNumber numberWithInteger:ECVLineDoubleHQ], ECVDeinterlacingModeKey,
		[NSNumber numberWithDouble:0.5f], ECVBrightnessKey,
		[NSNumber numberWithDouble:0.5f], ECVContrastKey,
		[NSNumber numberWithDouble:0.5f], ECVHueKey,
		[NSNumber numberWithDouble:0.5f], ECVSaturationKey,
		[NSNumber numberWithDouble:1.0f], ECVVolumeKey,
		[NSNumber numberWithBool:NO], ECVUpconvertsFromMonoKey,
		nil]];

#if !defined(ECV_NO_CONTROLLERS)
	_windowControllersLock = [[ECVReadWriteLock alloc] init];
	_windowControllers2 = [[NSMutableArray alloc] init];
#endif

	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(workspaceWillSleep:) name:NSWorkspaceWillSleepNotification object:[NSWorkspace sharedWorkspace]];

#if defined(ECV_ENABLE_AUDIO)
	[self setVolume:[[self defaults] doubleForKey:ECVVolumeKey]];
	[self setUpconvertsFromMono:[[self defaults] boolForKey:ECVUpconvertsFromMonoKey]];
#endif

#if !defined(ECV_NO_CONTROLLERS)
	ECVIOReturn(IOServiceAddInterestNotification([[ECVController sharedController] notificationPort], service, kIOGeneralInterest, (IOServiceInterestCallback)ECVDeviceRemoved, self, &_deviceRemovedNotification));
#endif

	SInt32 ignored = 0;
	IOCFPlugInInterface **devicePlugInInterface = NULL;
	ECVIOReturn(IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &devicePlugInInterface, &ignored));

	ECVIOReturn((*devicePlugInInterface)->QueryInterface(devicePlugInInterface, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID320), (LPVOID)&_deviceInterface));
	(*devicePlugInInterface)->Release(devicePlugInInterface);
	devicePlugInInterface = NULL;

	ECVIOReturn((*_deviceInterface)->USBDeviceOpen(_deviceInterface));
	ECVIOReturn((*_deviceInterface)->ResetDevice(_deviceInterface));

	IOUSBConfigurationDescriptorPtr configurationDescription = NULL;
	ECVIOReturn((*_deviceInterface)->GetConfigurationDescriptorPtr(_deviceInterface, 0, &configurationDescription));
	ECVIOReturn((*_deviceInterface)->SetConfiguration(_deviceInterface, configurationDescription->bConfigurationValue));

	IOUSBFindInterfaceRequest interfaceRequest = {
		kIOUSBFindInterfaceDontCare,
		kIOUSBFindInterfaceDontCare,
		kIOUSBFindInterfaceDontCare,
		kIOUSBFindInterfaceDontCare,
	};
	io_iterator_t interfaceIterator = IO_OBJECT_NULL;
	ECVIOReturn((*_deviceInterface)->CreateInterfaceIterator(_deviceInterface, &interfaceRequest, &interfaceIterator));
	io_service_t const interface = IOIteratorNext(interfaceIterator);
	NSParameterAssert(interface);

	IOCFPlugInInterface **interfacePlugInInterface = NULL;
	ECVIOReturn(IOCreatePlugInInterfaceForService(interface, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &interfacePlugInInterface, &ignored));

	if(FAILED((*interfacePlugInInterface)->QueryInterface(interfacePlugInInterface, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300), (LPVOID)&_interfaceInterface))) goto ECVGenericError;
	NSParameterAssert(_interfaceInterface);
	ECVIOReturn((*_interfaceInterface)->USBInterfaceOpenSeize(_interfaceInterface));

	ECVIOReturn((*_interfaceInterface)->GetFrameListTime(_interfaceInterface, &_frameTime));
	if([self requiresHighSpeed] && kUSBHighSpeedMicrosecondsInFrame != _frameTime) {
		if(outError) *outError = [NSError errorWithDomain:ECVCaptureDeviceErrorDomain code:0 userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
			NSLocalizedString(@"This device requires a USB 2.0 High Speed port in order to operate.", nil), NSLocalizedDescriptionKey,
			NSLocalizedString(@"Make sure it is plugged into a port that supports high speed.", nil), NSLocalizedRecoverySuggestionErrorKey,
			[NSArray array], NSLocalizedRecoveryOptionsErrorKey,
			nil]];
		[self release];
		return nil;
	}

	ECVIOReturn((*_interfaceInterface)->CreateInterfaceAsyncEventSource(_interfaceInterface, NULL));
	_playLock = [[NSConditionLock alloc] initWithCondition:ECVNotPlaying];

	[self setDeinterlacingMode:[ECVDeinterlacingMode deinterlacingModeWithType:[[self defaults] integerForKey:ECVDeinterlacingModeKey]]];

	return self;

ECVGenericError:
ECVNoDeviceError:
	[self release];
	return nil;
}
- (void)noteDeviceRemoved
{
	[self close];
}
- (void)workspaceWillSleep:(NSNotification *)aNotif
{
	[self setPlaying:NO];
	[self noteDeviceRemoved];
}

#pragma mark -

- (BOOL)isPlaying
{
	switch([_playLock condition]) {
		case ECVNotPlaying:
		case ECVStopPlaying:
			return NO;
		case ECVPlaying:
		case ECVStartPlaying:
			return YES;
	}
	return NO;
}
- (void)setPlaying:(BOOL)flag
{
	[_playLock lock];
	if(flag) {
		if(![self isPlaying]) [self startPlaying];
		else [_playLock unlock];
	} else {
		if([self isPlaying]) {
			[_playLock unlockWithCondition:ECVStopPlaying];
			[_playLock lockWhenCondition:ECVNotPlaying];
		}
		[_playLock unlock];
	}
}
- (void)togglePlaying
{
	[_playLock lock];
	switch([_playLock condition]) {
		case ECVNotPlaying:
		case ECVStopPlaying:
			[self startPlaying];
			break;
		case ECVStartPlaying:
		case ECVPlaying:
			[_playLock unlockWithCondition:ECVStopPlaying];
			[_playLock lockWhenCondition:ECVNotPlaying];
			[_playLock unlock];
			break;
	}
}
@synthesize deinterlacingMode = _deinterlacingMode;
- (void)setDeinterlacingMode:(Class)mode
{
	if(mode == _deinterlacingMode) return;
	ECVPauseWhile(self, { [_deinterlacingMode release]; _deinterlacingMode = [mode copy]; });
	[[self defaults] setInteger:[mode deinterlacingModeType] forKey:ECVDeinterlacingModeKey];
}

#pragma mark -

@synthesize defaults = _defaults;
@synthesize videoStorage = _videoStorage;
- (NSUInteger)simultaneousTransfers
{
	return 32;
}
- (NSUInteger)microframesPerTransfer
{
	return 32;
}

#pragma mark -

- (void)startPlaying
{
	[_videoStorage release];
	_videoStorage = [[[ECVVideoStorage preferredVideoStorageClass] alloc] initWithDeinterlacingMode:[self deinterlacingMode] captureSize:[self captureSize] pixelFormat:[self pixelFormatType] frameRate:[self frameRate]];
	[_playLock unlockWithCondition:ECVStartPlaying];
	[NSThread detachNewThreadSelector:@selector(threadMain_play) toTarget:self withObject:nil];
}
- (void)threadMain_play
{
	NSAutoreleasePool *const pool = [[NSAutoreleasePool alloc] init];
	ECVTransfer *transfers = NULL;
	NSUInteger i;

	[_playLock lock];
	if([_playLock condition] != ECVStartPlaying) {
		[_playLock unlock];
		[pool release];
		return;
	}
	ECVLog(ECVNotice, @"Starting playback.");
	[NSThread setThreadPriority:1.0f];
	if(![self threaded_play]) goto bail;
	[_playLock unlockWithCondition:ECVPlaying];

	UInt8 const pipeIndex = [self isochReadingPipe];
	UInt8 direction = kUSBNone;
	UInt8 pipeNumberIgnored = 0;
	UInt8 transferType = kUSBAnyType;
	UInt16 frameRequestSize = 0;
	UInt8 millisecondInterval = 0;
	ECVIOReturn((*_interfaceInterface)->GetPipeProperties(_interfaceInterface, pipeIndex, &direction, &pipeNumberIgnored, &transferType, &frameRequestSize, &millisecondInterval));
	if(direction != kUSBIn && direction != kUSBAnyDirn) {
		ECVLog(ECVError, @"Invalid pipe direction %lu", (unsigned long)direction);
		goto ECVGenericError;
	}
	if(transferType != kUSBIsoc) {
		ECVLog(ECVError, @"Invalid transfer type %lu", (unsigned long)transferType);
		goto ECVGenericError;
	}
	if(!frameRequestSize) {
		ECVLog(ECVError, @"No USB bandwidth (try a different USB port or unplug other devices)");
		goto ECVGenericError;
	}

	NSUInteger const simultaneousTransfers = [self simultaneousTransfers];
	NSUInteger const microframesPerTransfer = [self microframesPerTransfer];
	transfers = calloc(simultaneousTransfers, sizeof(ECVTransfer));
	for(i = 0; i < simultaneousTransfers; ++i) {
		ECVTransfer *const transfer = transfers + i;
		ECVIOReturn((*_interfaceInterface)->LowLatencyCreateBuffer(_interfaceInterface, (void **)&transfer->list, sizeof(IOUSBLowLatencyIsocFrame) * microframesPerTransfer, kUSBLowLatencyFrameListBuffer));
		ECVIOReturn((*_interfaceInterface)->LowLatencyCreateBuffer(_interfaceInterface, (void **)&transfer->data, frameRequestSize * microframesPerTransfer, kUSBLowLatencyReadBuffer));
		NSUInteger j;
		for(j = 0; j < microframesPerTransfer; ++j) {
			transfer->list[j].frStatus = kIOReturnInvalid; // Ignore them to start out.
			transfer->list[j].frReqCount = frameRequestSize;
		}
	}

	UInt64 currentFrame = 0;
	AbsoluteTime atTimeIgnored;
	ECVIOReturn((*_interfaceInterface)->GetBusFrameNumber(_interfaceInterface, &currentFrame, &atTimeIgnored));
	currentFrame += 10;

#if defined(ECV_ENABLE_AUDIO)
	[self performSelectorOnMainThread:@selector(startAudio) withObject:nil waitUntilDone:YES];
#endif
#if !defined(ECV_NO_CONTROLLERS)
	[self performSelectorOnMainThread:@selector(_startPlayingForControllers) withObject:nil waitUntilDone:YES];
#endif

	while([_playLock condition] == ECVPlaying) {
		NSAutoreleasePool *const innerPool = [[NSAutoreleasePool alloc] init];
		if(![self threaded_watchdog]) {
			ECVLog(ECVError, @"Invalid device watchdog result.");
			[innerPool release];
			break;
		}
		for(i = 0; i < simultaneousTransfers; ++i) {
			ECVTransfer *const transfer = transfers + i;
			NSUInteger j;
			for(j = 0; j < microframesPerTransfer; j++) {
				if(kUSBLowLatencyIsochTransferKey == transfer->list[j].frStatus && j) {
					Nanoseconds const nextUpdateTime = UInt64ToUnsignedWide(UnsignedWideToUInt64(AbsoluteToNanoseconds(transfer->list[j - 1].frTimeStamp)) + millisecondInterval * ECVNanosecondsPerMillisecond);
					mach_wait_until(UnsignedWideToUInt64(NanosecondsToAbsolute(nextUpdateTime)));
				}
				while(kUSBLowLatencyIsochTransferKey == transfer->list[j].frStatus) usleep(100); // In case we haven't slept long enough already.
				[self threaded_readBytes:transfer->data + j * frameRequestSize length:(size_t)transfer->list[j].frActCount];
				transfer->list[j].frStatus = kUSBLowLatencyIsochTransferKey;
			}
			ECVIOReturn((*_interfaceInterface)->LowLatencyReadIsochPipeAsync(_interfaceInterface, pipeIndex, transfer->data, currentFrame, microframesPerTransfer, CLAMP(1, millisecondInterval, 8), transfer->list, ECVDoNothing, NULL));
			currentFrame += microframesPerTransfer / (kUSBFullSpeedMicrosecondsInFrame / _frameTime);
		}
		[innerPool drain];
	}

	[self threaded_pause];
ECVGenericError:
ECVNoDeviceError:
#if defined(ECV_ENABLE_AUDIO)
	[self performSelectorOnMainThread:@selector(stopAudio) withObject:nil waitUntilDone:NO];
#endif
#if !defined(ECV_NO_CONTROLLERS)
	[self performSelectorOnMainThread:@selector(_stopPlayingForControllers) withObject:nil waitUntilDone:NO];
#endif

	if(transfers) {
		for(i = 0; i < simultaneousTransfers; ++i) {
			if(transfers[i].list) (*_interfaceInterface)->LowLatencyDestroyBuffer(_interfaceInterface, transfers[i].list);
			if(transfers[i].data) (*_interfaceInterface)->LowLatencyDestroyBuffer(_interfaceInterface, transfers[i].data);
		}
		free(transfers);
	}
	[_playLock lock];
bail:
	ECVLog(ECVNotice, @"Stopping playback.");
	NSParameterAssert([_playLock condition] != ECVNotPlaying);
	[_playLock unlockWithCondition:ECVNotPlaying];
	[pool drain];
}
- (void)threaded_nextFieldType:(ECVFieldType)fieldType
{
	ECVVideoFrame *const frameToDraw = [_videoStorage finishedFrameWithNextFieldType:fieldType];
	if(frameToDraw) {
#if !defined(ECV_NO_CONTROLLERS)
		[_windowControllersLock readLock];
		[_windowControllers2 makeObjectsPerformSelector:@selector(threaded_pushFrame:) withObject:frameToDraw];
		[_windowControllersLock unlock];
#endif
	}
}
- (void)threaded_drawPixelBuffer:(ECVPixelBuffer *)buffer atPoint:(ECVIntegerPoint)point
{
	[_videoStorage drawPixelBuffer:buffer atPoint:point];
}

#pragma mark -

- (BOOL)setAlternateInterface:(UInt8)alternateSetting
{
	IOReturn const error = (*_interfaceInterface)->SetAlternateInterface(_interfaceInterface, alternateSetting);
	switch(error) {
		case kIOReturnSuccess: return YES;
		case kIOReturnNoDevice:
		case kIOReturnNotResponding: return NO;
	}
	ECVIOReturn(error);
ECVGenericError:
ECVNoDeviceError:
	return NO;
}
- (BOOL)controlRequestWithType:(u_int8_t)type request:(u_int8_t)request value:(u_int16_t)v index:(u_int16_t)i length:(u_int16_t)length data:(void *)data
{
	IOUSBDevRequest r = { type, request, v, i, length, data, 0 };
	IOReturn const error = (*_interfaceInterface)->ControlRequest(_interfaceInterface, 0, &r);
	switch(error) {
		case kIOReturnSuccess: return YES;
		case kIOUSBPipeStalled: ECVIOReturn((*_interfaceInterface)->ClearPipeStall(_interfaceInterface, 0)); return YES;
		case kIOReturnNotResponding: return NO;
	}
	ECVIOReturn(error);
ECVGenericError:
ECVNoDeviceError:
	return NO;
}
- (BOOL)writeIndex:(u_int16_t)i value:(u_int16_t)v
{
	return [self controlRequestWithType:USBmakebmRequestType(kUSBOut, kUSBVendor, kUSBDevice) request:kUSBRqClearFeature value:v index:i length:0 data:NULL];
}
- (BOOL)readIndex:(u_int16_t)i value:(out u_int8_t *)outValue
{
	u_int8_t v = 0;
	BOOL const r = [self controlRequestWithType:USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice) request:kUSBRqGetStatus value:0 index:i length:sizeof(v) data:&v];
	if(outValue) *outValue = v;
	return r;
}
- (BOOL)setFeatureAtIndex:(u_int16_t)i
{
	return [self controlRequestWithType:USBmakebmRequestType(kUSBOut, kUSBStandard, kUSBDevice) request:kUSBRqSetFeature value:0 index:i length:0 data:NULL];
}

#pragma mark -

#if defined(ECV_ENABLE_AUDIO)
- (ECVAudioInput *)audioInputOfCaptureHardware
{
	ECVAudioInput *const input = [ECVAudioInput deviceWithIODevice:_service];
	[input setName:_productName];
	return input;
}
- (ECVAudioInput *)audioInput
{
	if(!_audioInput) {
		NSString *const UID = [[self defaults] objectForKey:ECVAudioInputUIDKey];
		if(UID) _audioInput = [[ECVAudioInput deviceWithUID:UID] retain];
	}
	if(!_audioInput) _audioInput = [[self audioInputOfCaptureHardware] retain];
	if(!_audioInput) _audioInput = [[ECVAudioInput defaultDevice] retain];
	return [[_audioInput retain] autorelease];
}
- (void)setAudioInput:(ECVAudioInput *)input
{
	if(!ECVEqualObjects(input, _audioInput)) {
		ECVPauseWhile(self, {
			[_audioInput release];
			_audioInput = [input retain];
			[_audioPreviewingPipe release];
			_audioPreviewingPipe = nil;
		});
	}
	if(ECVEqualObjects([self audioInputOfCaptureHardware], input)) {
		[[self defaults] removeObjectForKey:ECVAudioInputUIDKey];
	} else {
		[[self defaults] setObject:[input UID] forKey:ECVAudioInputUIDKey];
	}
}
- (ECVAudioOutput *)audioOutput
{
	if(!_audioOutput) return _audioOutput = [[ECVAudioOutput defaultDevice] retain];
	return [[_audioOutput retain] autorelease];
}
- (void)setAudioOutput:(ECVAudioOutput *)output
{
	if(ECVEqualObjects(output, _audioOutput)) return;
	ECVPauseWhile(self, {
		[_audioOutput release];
		_audioOutput = [output retain];
		[_audioPreviewingPipe release];
		_audioPreviewingPipe = nil;
	});
}
- (BOOL)startAudio
{
	NSAssert(!_audioPreviewingPipe, @"Audio pipe should be cleared before restarting audio.");

	NSTimeInterval const timeSinceLastStop = [NSDate ECV_timeIntervalSinceReferenceDate] - _audioStopTime;
	usleep(MAX(0.75f - timeSinceLastStop, 0.0f) * ECVMicrosecondsPerSecond); // Don't let the audio be restarted too quickly.

	ECVAudioInput *const input = [self audioInput];
	ECVAudioOutput *const output = [self audioOutput];

	ECVAudioStream *const inputStream = [[[input streams] objectEnumerator] nextObject];
	if(!inputStream) {
		ECVLog(ECVNotice, @"This device may not support audio (input: %@; stream: %@).", input, inputStream);
		return NO;
	}
	ECVAudioStream *const outputStream = [[[output streams] objectEnumerator] nextObject];
	if(!outputStream) {
		ECVLog(ECVWarning, @"Audio output could not be started (output: %@; stream: %@).", output, outputStream);
		return NO;
	}

	_audioPreviewingPipe = [[ECVAudioPipe alloc] initWithInputDescription:[inputStream basicDescription] outputDescription:[outputStream basicDescription] upconvertFromMono:[self upconvertsFromMono]];
	[_audioPreviewingPipe setVolume:_muted ? 0.0f : _volume];
	[input setDelegate:self];
	[output setDelegate:self];

	if(![input start]) {
		ECVLog(ECVWarning, @"Audio input could not be restarted (input: %@).", input);
		return NO;
	}
	if(![output start]) {
		[output stop];
		ECVLog(ECVWarning, @"Audio output could not be restarted (output: %@).", output);
		return NO;
	}
	return YES;
}
- (void)stopAudio
{
	ECVAudioInput *const input = [self audioInput];
	ECVAudioOutput *const output = [self audioOutput];
	[input stop];
	[output stop];
	[input setDelegate:nil];
	[output setDelegate:nil];
	[_audioPreviewingPipe release];
	_audioPreviewingPipe = nil;
	_audioStopTime = [NSDate ECV_timeIntervalSinceReferenceDate];
}
#endif

#pragma mark -ECVCaptureDevice(Private)

#if !defined(ECV_NO_CONTROLLERS)
- (void)_startPlayingForControllers
{
	[[ECVController sharedController] noteCaptureDeviceStartedPlaying:self];
	[[self windowControllers] makeObjectsPerformSelector:@selector(startPlaying)];
}
- (void)_stopPlayingForControllers
{
	[[self windowControllers] makeObjectsPerformSelector:@selector(stopPlaying)];
	[[ECVController sharedController] noteCaptureDeviceStoppedPlaying:self];
}
#endif

#pragma mark -NSDocument

#if !defined(ECV_NO_CONTROLLERS)
- (void)addWindowController:(NSWindowController *)windowController
{
	[super addWindowController:windowController];
	[_windowControllersLock writeLock];
	if(NSNotFound == [_windowControllers2 indexOfObjectIdenticalTo:windowController]) [_windowControllers2 addObject:windowController];
	[_windowControllersLock unlock];
}
- (void)removeWindowController:(NSWindowController *)windowController
{
	[super removeWindowController:windowController];
	[_windowControllersLock writeLock];
	[_windowControllers2 removeObjectIdenticalTo:windowController];
	[_windowControllersLock unlock];
}
#endif

#pragma mark -

- (void)makeWindowControllers
{
#if !defined(ECV_NO_CONTROLLERS)
	[self addWindowController:[[[ECVCaptureController alloc] init] autorelease]];
#endif
}
- (NSString *)displayName
{
	return _productName ? _productName : @"";
}
- (void)close
{
	[self setPlaying:NO];
	[super close];
}

#pragma mark -NSObject

- (void)dealloc
{
	[[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
#if !defined(ECV_NO_CONTROLLERS)
	ECVConfigController *const config = [ECVConfigController sharedConfigController];
	if([config captureDevice] == self) [config setCaptureDevice:nil];
#endif

	if(_deviceInterface) (*_deviceInterface)->USBDeviceClose(_deviceInterface);
	if(_deviceInterface) (*_deviceInterface)->Release(_deviceInterface);
	if(_interfaceInterface) (*_interfaceInterface)->Release(_interfaceInterface);

	[_defaults release];
#if !defined(ECV_NO_CONTROLLERS)
	[_windowControllersLock release];
	[_windowControllers2 release];
#endif
	IOObjectRelease(_service);
	[_productName release];
	IOObjectRelease(_deviceRemovedNotification);
	[_deinterlacingMode release];
	[_playLock release];
#if defined(ECV_ENABLE_AUDIO)
	[_audioInput release];
	[_audioOutput release];
	[_audioPreviewingPipe release];
#endif
	[super dealloc];
}

#pragma mark -<ECVAudioDeviceDelegate>

#if defined(ECV_ENABLE_AUDIO)
- (void)audioInput:(ECVAudioInput *)sender didReceiveBufferList:(AudioBufferList const *)bufferList atTime:(AudioTimeStamp const *)t
{
	if(sender != _audioInput) return;
	[_audioPreviewingPipe receiveInputBufferList:bufferList];
	[_windowControllersLock readLock];
	[_windowControllers2 makeObjectsPerformSelector:@selector(threaded_pushAudioBufferListValue:) withObject:[NSValue valueWithPointer:bufferList]];
	[_windowControllersLock unlock];
}
- (void)audioOutput:(ECVAudioOutput *)sender didRequestBufferList:(inout AudioBufferList *)bufferList forTime:(AudioTimeStamp const *)t
{
	if(sender != _audioOutput) return;
	[_audioPreviewingPipe requestOutputBufferList:bufferList];
}
#endif

#pragma mark -<ECVCaptureControllerConfiguring>

#if defined(ECV_ENABLE_AUDIO)
- (BOOL)isMuted
{
	return _muted;
}
- (void)setMuted:(BOOL)flag
{
	if(flag == _muted) return;
	_muted = flag;
	[_audioPreviewingPipe setVolume:_muted ? 0.0f : _volume];
	[[NSNotificationCenter defaultCenter] postNotificationName:ECVCaptureDeviceVolumeDidChangeNotification object:self];
}
- (CGFloat)volume
{
	return _volume;
}
- (void)setVolume:(CGFloat)value
{
	_volume = CLAMP(0.0f, value, 1.0f);
	[_audioPreviewingPipe setVolume:_muted ? 0.0f : _volume];
	[[self defaults] setDouble:value forKey:ECVVolumeKey];
	[[NSNotificationCenter defaultCenter] postNotificationName:ECVCaptureDeviceVolumeDidChangeNotification object:self];
}
- (BOOL)upconvertsFromMono
{
	return _upconvertsFromMono;
}
- (void)setUpconvertsFromMono:(BOOL)flag
{
	ECVPauseWhile(self, { _upconvertsFromMono = flag; });
	[[self defaults] setBool:flag forKey:ECVUpconvertsFromMonoKey];
}
#endif

@end
