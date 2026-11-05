//
//  LNSystemMarqueeLabel.mm
//  LNSystemMarqueeLabel
//
//  Created by Léo Natan on 7/9/25.
//  Copyright © 2025–2026 Léo Natan. All rights reserved.
//

#import "LNSystemMarqueeLabel.h"
#if __has_include("_LNPopupBase64Utils.hh")
#import "_LNPopupBase64Utils.hh"
#else
#include <cstdlib>
#include <array>

namespace lnpopup {

template <size_t N>
struct base64_string : std::array<char, N> {
	consteval base64_string(const char (&input)[N]) : base64_string(input, std::make_index_sequence<N>{}) {}
	template <size_t... Is>
	consteval base64_string(const char (&input)[N], std::index_sequence<Is...>) : std::array<char, N>{ input[Is]... } {}
};

template <size_t N>
consteval const auto base64_encode(const char(&input)[N]) {
	constexpr char encoding_table[] =
	{
		'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
		'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
		'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
		'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
		'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/'
	};
	
	constexpr size_t out_len = 4 * (((N - 1) + 2) / 3) + 1;
	
	size_t in_len = N - 1;
	char output[out_len] {0};
	size_t i = 0;
	char *p = const_cast<char *>(output);
	
	for(i = 0; in_len > 2 && i < in_len - 2; i += 3)
	{
		*p++ = encoding_table[(input[i] >> 2) & 0x3F];
		*p++ = encoding_table[((input[i] & 0x3) << 4) | ((int)(input[i + 1] & 0xF0) >> 4)];
		*p++ = encoding_table[((input[i + 1] & 0xF) << 2) | ((int)(input[i + 2] & 0xC0) >> 6)];
		*p++ = encoding_table[input[i + 2] & 0x3F];
	}
	
	if(i < in_len)
	{
		*p++ = encoding_table[(input[i] >> 2) & 0x3F];
		if(i == (in_len - 1))
		{
			*p++ = encoding_table[((input[i] & 0x3) << 4)];
			*p++ = '=';
		}
		else
		{
			*p++ = encoding_table[((input[i] & 0x3) << 4) | ((int)(input[i + 1] & 0xF0) >> 4)];
			*p++ = encoding_table[((input[i + 1] & 0xF) << 2)];
		}
		*p++ = '=';
	}
	
	return base64_string<out_len>(output);
}

CF_INLINE
auto decode_hidden_string(auto encoded)
{
	return [[NSString alloc] initWithData:[[NSData alloc] initWithBase64EncodedString:@(encoded.data()) options:0] encoding:NSUTF8StringEncoding];
}

} //namespace lnpopup

#define LNPopupHiddenString(input) (lnpopup::decode_hidden_string(lnpopup::base64_encode("" input "")))

#endif

#if __has_include("_LNPopupSwizzlingUtils.h")
#import "_LNPopupSwizzlingUtils.h"
#else
#define LNSwizzleClassGetInstanceMethod class_getInstanceMethod
#endif

#import <objc/message.h>

#define LNSystemMarqueeLabelDebug 0

static NSString* marqueeRepeatCount = LNPopupHiddenString("marqueeRepeatCount");

@interface LNSystemMarqueeLabel ()

@property (nonatomic, strong) NSHashTable<LNSystemMarqueeLabel*>* weakSynchronizedLabels;
@property (nonatomic) BOOL pauseForSync;
@property (nonatomic) BOOL animationRunning;

@end

@interface NSObject ()

@property (weak, nonatomic) LNSystemMarqueeLabel* label;

@end

@implementation LNSystemMarqueeLabel
{
	CGRect _lastDrawnBounds;
}

+ (void)load
{
	@autoreleasepool
	{
#if !LNSystemMarqueeLabelDebug
		if([self instancesRespondToSelector:NSSelectorFromString(marqueeRepeatCount)] == NO)
		{
			//Since marquee scrolling synchronization is unsupported, we skip the swizzling of _UILabelMarqueeAnimationDelegate.
			return;
		}
#endif
		
		Class cls = NSClassFromString(LNPopupHiddenString("_UILabelMarqueeAnimationDelegate"));
		SEL sel = @selector(animationDidStart:);
		Method m = LNSwizzleClassGetInstanceMethod(cls, sel);
		if(m == nil)
		{
			return;
		}
		
		void (*orig)(id, SEL, CAAnimation*) = reinterpret_cast<decltype(orig)>(method_getImplementation(m));
		method_setImplementation(m, imp_implementationWithBlock(^(NSObject* _self, CAAnimation* animation) {
#if LNSystemMarqueeLabelDebug
			NSLog(@"animationDidStart duration: %@", @(animation.duration));
#endif

			if([_self.label isKindOfClass:LNSystemMarqueeLabel.class])
			{
				if(_self.label.pauseForSync == YES)
				{
					//There is a synchronized label that is still animating, so wait for that finish.
					[_self.label _pauseLayer];
				}
				else
				{
					_self.label.animationRunning = YES;
				}
			}
			
			orig(_self, sel, animation);
		}));
		
		sel = @selector(animationDidStop:finished:);
		m = LNSwizzleClassGetInstanceMethod(cls, sel);
		if(m == nil)
		{
			return;
		}
		
		void (*orig2)(id, SEL, CAAnimation*, BOOL) = reinterpret_cast<decltype(orig2)>(method_getImplementation(m));
		method_setImplementation(m, imp_implementationWithBlock(^(NSObject* _self, CAAnimation* animation, BOOL finished) {
#if LNSystemMarqueeLabelDebug
			NSLog(@"animationDidStop");
#endif
			
			if(finished == NO || [_self.label isKindOfClass:LNSystemMarqueeLabel.class] == NO)
			{
				orig2(_self, sel, animation, finished);
				return;
			}
			
			_self.label.animationRunning = NO;
			
			static NSString* suppressEnded = LNPopupHiddenString("suppressEnded");
			[_self setValue:@(finished) forKey:suppressEnded];
			
			orig2(_self, sel, animation, finished);
			
			NSIndexSet* stillRunning = [_self.label.synchronizedLabels indexesOfObjectsPassingTest:^BOOL(LNSystemMarqueeLabel * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
				return obj.isMarqueeScrollEnabled && obj.isRunning && obj.animationRunning;
			}];
			
			_self.label.pauseForSync = stillRunning.count > 0;
			//Start the next animation.
			[_self.label _startNewAnimation];
			
			if(stillRunning.count > 0)
			{
				return;
			}
			
			if(_self.label.isMarqueeScrollEnabled == NO || _self.label.isRunning == NO)
			{
				return;
			}
			
			for (LNSystemMarqueeLabel* obj in _self.label.weakSynchronizedLabels) {
				//Start all other synchronized labels.
				if(obj.isMarqueeScrollEnabled == NO || obj.isRunning == NO)
				{
					return;
				}
				
				obj.pauseForSync = NO;
				[obj _unpauseLayerAndReset:NO];
				obj.animationRunning = YES;
			}
		}));
	}
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if(self)
	{
		self.marqueeScrollEnabled = YES;
		self.running = NO;
		
		static NSString* marqueeUpdatable = LNPopupHiddenString("marqueeUpdatable");
		
		if([self respondsToSelector:NSSelectorFromString(marqueeUpdatable)])
		{
			[self setValue:@YES forKey:marqueeUpdatable];
		}
		if([self respondsToSelector:@selector(marqueeRepeatCount)])
		{
			[self setValue:@0 forKey:marqueeRepeatCount];
		}
	}
	return self;
}

static NSString* marqueeEnabled = LNPopupHiddenString("marqueeEnabled");

- (BOOL)isMarqueeScrollEnabled
{
	return [[self valueForKey:marqueeEnabled] boolValue];
}

- (void)setMarqueeScrollEnabled:(BOOL)enabled
{
	if(self.isMarqueeScrollEnabled == enabled)
	{
		return;
	}
	
	[self setValue:@(enabled) forKey:marqueeEnabled];
	
	self.pauseForSync = NO;
	[self _unpauseLayerAndReset:YES];
}

static NSString* marqueeRunning = LNPopupHiddenString("marqueeRunning");

- (BOOL)isRunning
{
	return [[self valueForKey:marqueeRunning] boolValue];
}

-(void)setRunning:(BOOL)running
{
	if(running == self.isRunning)
	{
		return;
	}
	
	_lastDrawnBounds = CGRectZero;
	
	[self setValue:@(running) forKey:marqueeRunning];
	self.pauseForSync = NO;
	[self _unpauseLayerAndReset:YES];
}

- (NSArray<LNSystemMarqueeLabel *> *)synchronizedLabels
{
	return _weakSynchronizedLabels.allObjects;
}

- (void)setSynchronizedLabels:(NSArray<LNSystemMarqueeLabel *> *)synchronizedLabels
{
	if([self respondsToSelector:NSSelectorFromString(marqueeRepeatCount)] == NO)
	{
		//Older versions do not support limited repeat count. For those operating systems, silently ignore synchronized labels and let it run forever.
		return;
	}
	
	_weakSynchronizedLabels = [NSHashTable weakObjectsHashTable];
	for (id object in synchronizedLabels)
	{
		[_weakSynchronizedLabels addObject:object];
	}

	if(_weakSynchronizedLabels.count == 0)
	{
		[self setValue:@0 forKey:marqueeRepeatCount];
	}
	else
	{
		[self setValue:@1 forKey:marqueeRepeatCount];
	}
}

- (void)reset
{
	self.running = NO;
}

- (void)_startNewAnimation
{
	static void (^startMarqueeIfNecessary)(UILabel*);
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		void (*orig)(id, SEL) = nullptr;
		SEL startMarqueeIfNecessarySEL = NSSelectorFromString(LNPopupHiddenString("_startMarqueeIfNecessary"));
		
		if(@available(iOS 27, *))
		{
			Class cls = NSClassFromString(LNPopupHiddenString("_UILabelDirectImpl"));
			Method m = LNSwizzleClassGetInstanceMethod(cls, startMarqueeIfNecessarySEL);
			if(m != nullptr)
			{
				orig = reinterpret_cast<decltype(orig)>(method_getImplementation(m));
			}
			
			startMarqueeIfNecessary = ^(UILabel* self)
			{
				if(orig == nullptr)
				{
					return;
				}
				
				static NSString* const key = LNPopupHiddenString("_impl");
				id impl = [self valueForKey:key];
				orig(impl, startMarqueeIfNecessarySEL);
			};
		}
		else
		{
			Method m = LNSwizzleClassGetInstanceMethod(UILabel.class, startMarqueeIfNecessarySEL);
			orig = reinterpret_cast<decltype(orig)>(method_getImplementation(m));
			startMarqueeIfNecessary = ^(UILabel* self)
			{
				orig(self, startMarqueeIfNecessarySEL);
			};
		}
		
	});
	
	startMarqueeIfNecessary(self);
}

- (void)setBounds:(CGRect)bounds
{
	[super setBounds:bounds];
	
	_lastDrawnBounds = CGRectZero;
	
	[self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect
{
	if(_lockDrawCalls && self.isRunning && CGRectEqualToRect(_lastDrawnBounds, rect))
	{
		return;
	}
	
#if LNSystemMarqueeLabelDebug
	NSLog(@"drawing %@", @(rect));
#endif
	
	[super drawRect:rect];
	_lastDrawnBounds = rect;
}

- (void)_pauseLayer
{
	CFTimeInterval pausedTime = [self.layer convertTime:CACurrentMediaTime() fromLayer:nil];
	self.layer.speed = 0.0;
	self.layer.timeOffset = pausedTime;
}

- (void)_unpauseLayerAndReset:(BOOL)reset
{
	CFTimeInterval pausedTime = self.layer.timeOffset;
	self.layer.speed = 1.0;
	self.layer.timeOffset = 0.0;
	self.layer.beginTime = 0.0;
	if(!reset)
	{
		CFTimeInterval timeSincePause = [self.layer convertTime:CACurrentMediaTime() fromLayer:nil] - pausedTime;
		self.layer.beginTime = timeSincePause;
	}
}

@end
