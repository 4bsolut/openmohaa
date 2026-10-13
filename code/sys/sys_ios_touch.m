/*
===========================================================================
Copyright (C) 2025 the OpenMoHAA contributors

This file is part of OpenMoHAA source code.

OpenMoHAA source code is free software; you can redistribute it
and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation; either version 2 of the License,
or (at your option) any later version.
===========================================================================
*/

// On-screen touch controls for iOS (layout and HUD editor inspired by Call of Duty: Mobile):
//   - floating movement stick on the left, analog (walk/run by deflection)
//   - drag on the right half to look
//   - buttons: fire (right and left), secondary fire, jump, crouch, reload, use, weapon switch, grenade,
//     lean left/right, scoreboard, menu
//   - optional "lean-strafe": pushing the stick sideways also leans, like binding +moveleft/+leanleft together
//   - HUD editor: drag every control, change its scale and opacity, hide it, nudge it, reset, save
//
// It only injects the same events a keyboard/mouse would (SE_KEY, SE_MOUSE, SE_JOYSTICK_AXIS), so it does not
// change protocol, rules or aiming mechanics. All UIKit callbacks run on the main thread, which is also the
// thread that runs the engine loop (SDL pumps the run loop from IN_Frame), so queueing events here is safe.

#ifndef __APPLE__
#error This file is for iOS only.
#endif

#import <UIKit/UIKit.h>

#include "../qcommon/q_shared.h"
#include "../qcommon/qcommon.h"
#include "../client/keycodes.h"
#include "sys_local.h"

#include <SDL.h>
#include <SDL_syswm.h>

#define MAX_TRACKED_TOUCHES 10
#define STICK_RADIUS        62.0   // points of finger travel for full deflection at scale 1
#define STICK_DEADZONE      0.08
#define STICK_ZONE_WIDTH    0.42   // left fraction of the screen where a touch starts the stick
#define BUTTON_SLOP         10.0   // extra points around a button that still hit it
#define AIM_FIRE_BUTTON     0      // right fire button can also drag the camera
#define KEY_EDIT_LAYOUT     (-1)   // pseudo key: opens the HUD editor
#define LAYOUT_DEFAULTS_KEY @"MohaaTouchLayout.v2"
#define LOOK_DEFAULTS_KEY   @"MohaaTouchLook"
#define LOOK_ADS_DEFAULTS_KEY @"MohaaTouchLookADS"
#define MOVE_FULL_DEFAULTS_KEY @"MohaaTouchMoveFull"

typedef enum {
	ROLE_NONE, ROLE_STICK, ROLE_LOOK, ROLE_LOOK_WAIT, ROLE_BUTTON,
	ROLE_FIRE_LOOK, ROLE_FIRE_WAIT, ROLE_EDIT_DRAG
} touchRole_t;

typedef struct {
	const char *name;   // shown in the editor
	const char *symbol; // SF Symbol, falls back to text
	const char *text;
	CGFloat     radius;
	int         key;
	// default anchor: distance from the safe-area edges
	CGFloat     ax, ay;
	BOOL        fromRight, fromBottom, centered;
} buttonDef_t;

// Default key binds of the game: see default.cfg (MOUSE1 attackprimary, MOUSE2 attacksecondary, SPACE jump,
// LCTRL crouch, r reload, e use, z/c lean, 5 grenade class, MWHEELUP next weapon, TAB scores, ESC menu)
static const buttonDef_t buttonDefs[] = {
	{ "Disparo",           "scope",                       "FIRE",  46, K_MOUSE1,        100, 105, YES, YES, NO  },
	{ "Disparo (izq.)",    "scope",                       "FIRE",  34, K_MOUSE1,         70, 250, NO,  YES, NO  },
	{ "Secundario (cuchillo/zoom)", "emoji:\U0001F52A",     "ALT",   30, K_MOUSE2,        200, 150, YES, YES, NO  },
	{ "Saltar",            "chevron.up",                  "JUMP",  32, K_SPACE,          60, 215, YES, YES, NO  },
	{ "Agacharse",         "chevron.down",                "CRCH",  28, K_CTRL,          215,  55, YES, YES, NO  },
	{ "Recargar",          "arrow.triangle.2.circlepath", "RLD",   26, 'r',             130, 220, YES, YES, NO  },
	{ "Usar",              "hand.tap",                    "USE",   24, 'e',             210,  60, YES, NO,  NO  },
	{ "Granada",           "emoji:\U0001F4A3",           "GREN",  24, '5',             140,  60, YES, NO,  NO  },
	{ "Cambiar arma",      "arrow.left.arrow.right",      "NEXT",  24, K_MWHEELUP,       70,  60, YES, NO,  NO  },
	{ "Marcador",          "list.bullet",                 "TAB",   20, K_TAB,           -55,  34, NO,  NO,  YES },
	{ "Menu",              "gearshape",                   "MENU",  20, K_ESCAPE,         55,  34, NO,  NO,  YES },
	{ "Editar HUD",        "slider.horizontal.3",         "EDIT",  18, KEY_EDIT_LAYOUT,  135, 34, NO,  NO,  YES },
};
#define NUM_BUTTONS ( sizeof( buttonDefs ) / sizeof( buttonDefs[0] ) )
#define STICK_INDEX NUM_BUTTONS // the movement stick is edited like a button
#define NUM_ITEMS   ( NUM_BUTTONS + 1 )

typedef struct {
	BOOL  custom;   // false: use the default anchor (follows safe area/orientation); true: use fx, fy
	float fx, fy;   // centre as a fraction of the safe area (from top-left)
	float scale;    // 0.5 .. 2.0
	float opacity;  // 0.1 .. 1.0
	BOOL  hidden;
} itemCfg_t;

typedef struct {
	UITouch    *touch;
	touchRole_t role;
	int         button;
	CGPoint     origin; // stick centre
	CGPoint     last;   // last position, for look deltas
	CGPoint     grab;   // editor: offset between finger and item centre
} touchState_t;

static cvar_t *touch_look;     // degrees per point of finger travel
static cvar_t *touch_look_ads; // multiplier of touch_look while the secondary fire (aim) button is held
static cvar_t *touch_move_full; // stick travel fraction that reaches full movement speed
static cvar_t *touch_leanstrafe;
static cvar_t *touch_lean_start;
static cvar_t *touch_lean_stop;
static cvar_t *touch_startedit;
static cvar_t *ios_diag;

@class MohaaTouchOverlay;
@interface MohaaTouchOverlay : UIView
@property( nonatomic ) int mode; // 1: gameplay (controls shown); anything else: hidden, touches go to SDL
- (void)releaseAll;
- (void)enterEditor;
- (void)logDiagnostics;
@end

@implementation MohaaTouchOverlay {
	touchState_t   _touches[MAX_TRACKED_TOUCHES];
	itemCfg_t      _cfg[NUM_ITEMS];
	itemCfg_t      _saved[NUM_ITEMS];
	BOOL           _cfgReady;
	CAShapeLayer  *_layers[NUM_ITEMS]; // [STICK_INDEX] is the stick base
	UIView        *_icons[NUM_ITEMS];
	CAShapeLayer  *_stickKnob;
	BOOL           _stickActive;
	int            _keyHold[512];
	float          _lookRemX, _lookRemY;
	int            _leanStrafeKey;
	UIImpactFeedbackGenerator *_haptic;

	// editor
	BOOL           _editing;
	int            _selected;
	UIView        *_panel;
	UILabel       *_panelTitle;
	UISwitch      *_hideSwitch;
	UISlider      *_scaleSlider;
	UISlider      *_opacitySlider;
	UILabel       *_scaleValue;
	UILabel       *_opacityValue;
	UISlider      *_camSlider;
	UISlider      *_adsSlider;
	UISlider      *_moveSlider;
	UILabel       *_camValue;
	UILabel       *_adsValue;
	UILabel       *_moveValue;
	float          _savedLook, _savedAds, _savedMove;
	int            _diagStarted;
	int            _diagLookMoves;
	int            _diagStickMoves;
	int            _diagButtons;
	int            _diagEventAgeCount;
	double         _diagEventAgeTotal;
	double         _diagEventAgeMax;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if ( !self ) {
		return nil;
	}

	self.multipleTouchEnabled = YES;
	self.backgroundColor      = UIColor.clearColor;
	self.autoresizingMask     = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_haptic                   = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
	_selected                 = -1;
	_mode                     = 0;

	for ( size_t i = 0; i < NUM_ITEMS; i++ ) {
		BOOL isStick        = ( i == STICK_INDEX );
		CGFloat radius      = isStick ? STICK_RADIUS + 8 : buttonDefs[i].radius;
		CAShapeLayer *layer = [CAShapeLayer layer];
		layer.strokeColor   = [UIColor colorWithWhite:1 alpha:isStick ? 0.35 : 0.55].CGColor;
		layer.fillColor     = [UIColor colorWithWhite:1 alpha:isStick ? 0.06 : 0.10].CGColor;
		layer.lineWidth     = 2;
		layer.path          = [UIBezierPath bezierPathWithOvalInRect:CGRectMake( -radius, -radius, radius * 2, radius * 2 )].CGPath;
		[self.layer addSublayer:layer];
		_layers[i] = layer;

		if ( isStick ) {
			continue;
		}

		const buttonDef_t *b = &buttonDefs[i];
		UIView *content      = [[UIView alloc] initWithFrame:CGRectMake( 0, 0, b->radius * 2, b->radius * 2 )];
		content.userInteractionEnabled = NO;
		NSString *symbol = b->symbol ? @( b->symbol ) : nil;
		UIImage *img     = ( symbol && ![symbol hasPrefix:@"emoji:"] ) ? [UIImage systemImageNamed:symbol] : nil;
		if ( [symbol hasPrefix:@"emoji:"] ) {
			// SF Symbols has no grenade or knife: use an emoji
			UILabel *lb      = [[UILabel alloc] initWithFrame:content.bounds];
			lb.text          = [symbol substringFromIndex:6];
			lb.textAlignment = NSTextAlignmentCenter;
			lb.font          = [UIFont systemFontOfSize:b->radius * 1.05];
			[content addSubview:lb];
		} else if ( img ) {
			UIImageView *iv = [[UIImageView alloc] initWithImage:img];
			iv.tintColor    = [UIColor colorWithWhite:1 alpha:0.9];
			iv.contentMode  = UIViewContentModeScaleAspectFit;
			iv.frame        = CGRectInset( content.bounds, b->radius * 0.5, b->radius * 0.5 );
			[content addSubview:iv];
		} else {
			UILabel *lb      = [[UILabel alloc] initWithFrame:content.bounds];
			lb.text          = @( b->text );
			lb.textColor     = [UIColor colorWithWhite:1 alpha:0.9];
			lb.textAlignment = NSTextAlignmentCenter;
			lb.font          = [UIFont boldSystemFontOfSize:b->radius * 0.4];
			[content addSubview:lb];
		}
		[self addSubview:content];
		_icons[i] = content;
	}

	_stickKnob           = [CAShapeLayer layer];
	_stickKnob.fillColor = [UIColor colorWithWhite:1 alpha:0.30].CGColor;
	[self.layer addSublayer:_stickKnob];

	[self buildPanel];
	_leanStrafeKey = 0;
	return self;
}

// ---- layout model -------------------------------------------------------------------------------------

- (CGRect)safeRect
{
	return self.safeAreaLayoutGuide.layoutFrame;
}

- (CGPoint)defaultCentreOf:(size_t)i
{
	CGRect s = [self safeRect];
	if ( i == STICK_INDEX ) {
		return CGPointMake( CGRectGetMinX( s ) + 120, CGRectGetMaxY( s ) - 110 );
	}
	const buttonDef_t *b = &buttonDefs[i];
	CGFloat x = b->centered ? ( CGRectGetMidX( s ) + b->ax ) : ( b->fromRight ? CGRectGetMaxX( s ) - b->ax : CGRectGetMinX( s ) + b->ax );
	CGFloat y = b->fromBottom ? CGRectGetMaxY( s ) - b->ay : CGRectGetMinY( s ) + b->ay;
	return CGPointMake( x, y );
}

- (void)resetCfgToDefaults
{
	for ( size_t i = 0; i < NUM_ITEMS; i++ ) {
		_cfg[i].custom  = NO;
		_cfg[i].fx      = 0;
		_cfg[i].fy      = 0;
		_cfg[i].scale   = 1.0f;
		_cfg[i].opacity = 0.6f;
		_cfg[i].hidden  = NO;
	}
}

- (NSString *)keyForItem:(size_t)i
{
	return ( i == STICK_INDEX ) ? @"Joystick" : @( buttonDefs[i].name );
}

- (void)loadCfg
{
	[self resetCfgToDefaults];
	NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:LAYOUT_DEFAULTS_KEY];
	for ( size_t i = 0; i < NUM_ITEMS; i++ ) {
		NSDictionary *d = all[[self keyForItem:i]];
		if ( ![d isKindOfClass:NSDictionary.class] ) continue;
		_cfg[i].custom  = [d[@"custom"] boolValue];
		_cfg[i].fx      = [d[@"fx"] floatValue];
		_cfg[i].fy      = [d[@"fy"] floatValue];
		_cfg[i].scale   = fminf( 2.0f, fmaxf( 0.5f, [d[@"scale"] floatValue] ) );
		_cfg[i].opacity = fminf( 1.0f, fmaxf( 0.1f, [d[@"opacity"] floatValue] ) );
		_cfg[i].hidden  = [d[@"hidden"] boolValue];
	}
	memcpy( _saved, _cfg, sizeof( _cfg ) );

	// look sensitivities live in cvars; the saved values win over the engine config
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	if ( [ud objectForKey:LOOK_DEFAULTS_KEY] ) Cvar_Set( "touch_look", va( "%g", [ud floatForKey:LOOK_DEFAULTS_KEY] ) );
	if ( [ud objectForKey:LOOK_ADS_DEFAULTS_KEY] ) Cvar_Set( "touch_look_ads", va( "%g", [ud floatForKey:LOOK_ADS_DEFAULTS_KEY] ) );
	if ( [ud objectForKey:MOVE_FULL_DEFAULTS_KEY] ) Cvar_Set( "touch_move_full", va( "%g", [ud floatForKey:MOVE_FULL_DEFAULTS_KEY] ) );
	_savedLook = touch_look->value;
	_savedAds  = touch_look_ads->value;
	_savedMove = touch_move_full->value;
}

- (void)saveCfg
{
	NSMutableDictionary *all = [NSMutableDictionary dictionary];
	for ( size_t i = 0; i < NUM_ITEMS; i++ ) {
		all[[self keyForItem:i]] = @{ @"custom" : @( _cfg[i].custom ), @"fx" : @( _cfg[i].fx ), @"fy" : @( _cfg[i].fy ),
		                              @"scale" : @( _cfg[i].scale ), @"opacity" : @( _cfg[i].opacity ), @"hidden" : @( _cfg[i].hidden ) };
	}
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	[ud setObject:all forKey:LAYOUT_DEFAULTS_KEY];
	[ud setFloat:touch_look->value forKey:LOOK_DEFAULTS_KEY];
	[ud setFloat:touch_look_ads->value forKey:LOOK_ADS_DEFAULTS_KEY];
	[ud setFloat:touch_move_full->value forKey:MOVE_FULL_DEFAULTS_KEY];
	memcpy( _saved, _cfg, sizeof( _cfg ) );
	_savedLook = touch_look->value;
	_savedAds  = touch_look_ads->value;
	_savedMove = touch_move_full->value;
}

- (CGPoint)centreOf:(size_t)i
{
	if ( !_cfg[i].custom ) {
		return [self defaultCentreOf:i];
	}
	CGRect s = [self safeRect];
	return CGPointMake( CGRectGetMinX( s ) + _cfg[i].fx * CGRectGetWidth( s ), CGRectGetMinY( s ) + _cfg[i].fy * CGRectGetHeight( s ) );
}

- (CGFloat)radiusOf:(size_t)i
{
	CGFloat base = ( i == STICK_INDEX ) ? STICK_RADIUS : buttonDefs[i].radius;
	return base * _cfg[i].scale;
}

- (BOOL)visible:(size_t)i
{
	return _mode == 1 && ( !_cfg[i].hidden || _editing );
}

- (void)layoutSubviews
{
	[super layoutSubviews];
	if ( !_cfgReady ) {
		[self loadCfg];
		_cfgReady = YES;
	}
	[self refreshItems];
	[self layoutPanel];
}

- (void)refreshItems
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	for ( size_t i = 0; i < NUM_ITEMS; i++ ) {
		CGPoint c       = [self centreOf:i];
		CGFloat s       = _cfg[i].scale;
		BOOL    visible = [self visible:i];
		float   alpha   = _cfg[i].opacity * ( _cfg[i].hidden ? 0.4f : 1.0f );
		BOOL    selected = _editing && (int)i == _selected;

		_layers[i].hidden      = !visible;
		_layers[i].position    = c;
		_layers[i].transform   = CATransform3DMakeScale( s, s, 1 );
		_layers[i].opacity     = alpha;
		_layers[i].strokeColor = selected ? [UIColor colorWithRed:1 green:0.85 blue:0.1 alpha:1].CGColor
		                                  : [UIColor colorWithWhite:1 alpha:( i == STICK_INDEX ) ? 0.35 : 0.55].CGColor;
		_layers[i].lineWidth   = selected ? 4 : 2;

		if ( _icons[i] ) {
			_icons[i].hidden    = !visible;
			_icons[i].center    = c;
			_icons[i].transform = CGAffineTransformMakeScale( s, s );
			_icons[i].alpha     = alpha;
		}
	}
	if ( !_stickActive ) {
		_stickKnob.path      = [UIBezierPath bezierPathWithOvalInRect:CGRectMake( -28, -28, 56, 56 )].CGPath;
		_stickKnob.position  = [self centreOf:STICK_INDEX];
		_stickKnob.transform = CATransform3DMakeScale( _cfg[STICK_INDEX].scale, _cfg[STICK_INDEX].scale, 1 );
		_stickKnob.opacity   = [self visible:STICK_INDEX] ? _cfg[STICK_INDEX].opacity * 0.8f : 0;
		_stickKnob.fillColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
	}
	[CATransaction commit];
}

- (void)setPressed:(BOOL)pressed forButton:(size_t)i
{
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_layers[i].fillColor = [UIColor colorWithWhite:1 alpha:pressed ? 0.45 : 0.10].CGColor;
	[CATransaction commit];
}

// ---- engine events ----------------------------------------------------------------------------------------

- (void)key:(int)key down:(BOOL)down
{
	if ( key < 0 || key >= 512 ) {
		return;
	}
	if ( down ) {
		if ( _keyHold[key]++ == 0 ) {
			Com_QueueEvent( Sys_Milliseconds(), SE_KEY, key, qtrue, 0, NULL );
		}
	} else if ( _keyHold[key] > 0 ) {
		if ( --_keyHold[key] == 0 ) {
			Com_QueueEvent( Sys_Milliseconds(), SE_KEY, key, qfalse, 0, NULL );
		}
	}
}

// desired movement in -127..127 -> axis value that j_forward/j_side turn back into that movement
- (void)sendStickX:(float)x y:(float)y
{
	float jf = Cvar_VariableValue( "j_forward" );
	float js = Cvar_VariableValue( "j_side" );
	if ( fabsf( jf ) < 0.0001f ) jf = -0.25f;
	if ( fabsf( js ) < 0.0001f ) js = 0.25f;

	int fwdAxis  = Cvar_VariableIntegerValue( "j_forward_axis" );
	int sideAxis = Cvar_VariableIntegerValue( "j_side_axis" );
	int t        = Sys_Milliseconds();
	Com_QueueEvent( t, SE_JOYSTICK_AXIS, fwdAxis, (int)( ( -y * 127.0f ) / jf ), 0, NULL );
	Com_QueueEvent( t, SE_JOYSTICK_AXIS, sideAxis, (int)( ( x * 127.0f ) / js ), 0, NULL );

	// lean-strafe: sideways stick also leans (+moveleft/+leanleft, +moveright/+leanright)
	int wantKey = 0;
	if ( touch_leanstrafe && touch_leanstrafe->integer ) {
		int   sideKey = ( x < 0 ) ? 'z' : 'c';
		// hysteresis: start leaning past touch_lean_start, keep it until the stick falls under touch_lean_stop
		if ( _leanStrafeKey && sideKey == _leanStrafeKey && fabsf( x ) > touch_lean_stop->value ) {
			wantKey = _leanStrafeKey;
		} else if ( fabsf( x ) > touch_lean_start->value ) {
			wantKey = sideKey;
		}
	}
	if ( wantKey != _leanStrafeKey ) {
		Com_Printf( "touch: lean-strafe %c -> %c (stick x=%.2f)\n", _leanStrafeKey ? _leanStrafeKey : '-', wantKey ? wantKey : '-', x );
		if ( _leanStrafeKey ) [self key:_leanStrafeKey down:NO];
		if ( wantKey ) [self key:wantKey down:YES];
		_leanStrafeKey = wantKey;
	}
}

- (void)sendLookDX:(CGFloat)dx dy:(CGFloat)dy
{
	float sens    = Cvar_VariableValue( "sensitivity" );
	float m_yaw   = Cvar_VariableValue( "m_yaw" );
	float m_pitch = Cvar_VariableValue( "m_pitch" );
	if ( sens <= 0 ) sens = 5;
	if ( m_yaw <= 0 ) m_yaw = 0.022f;
	if ( m_pitch <= 0 ) m_pitch = 0.022f;

	// degrees per point of finger travel -> mouse counts
	float degPerPoint = touch_look ? touch_look->value : 0.25f;
	if ( _keyHold[K_MOUSE2] > 0 && touch_look_ads ) {
		degPerPoint *= touch_look_ads->value; // aiming down sights/zoom: slower, steadier
	}
	float cx          = dx * degPerPoint / ( m_yaw * sens ) + _lookRemX;
	float cy          = dy * degPerPoint / ( m_pitch * sens ) + _lookRemY;
	int   ix          = (int)cx;
	int   iy          = (int)cy;
	_lookRemX         = cx - ix;
	_lookRemY         = cy - iy;
	if ( ix || iy ) {
		Com_QueueEvent( Sys_Milliseconds(), SE_MOUSE, ix, iy, 0, NULL );
	}
}

- (void)releaseAll
{
	for ( int i = 0; i < MAX_TRACKED_TOUCHES; i++ ) {
		_touches[i].touch = nil;
		_touches[i].role  = ROLE_NONE;
	}
	for ( int k = 0; k < 512; k++ ) {
		if ( _keyHold[k] > 0 ) {
			_keyHold[k] = 0;
			Com_QueueEvent( Sys_Milliseconds(), SE_KEY, k, qfalse, 0, NULL );
		}
	}
	_leanStrafeKey = 0;
	_stickActive   = NO;
	[self sendStickX:0 y:0];
	for ( size_t i = 0; i < NUM_BUTTONS; i++ ) {
		[self setPressed:NO forButton:i];
	}
	[self refreshItems];
}

- (void)setMode:(int)mode
{
	if ( mode == _mode ) {
		return;
	}
	Com_Printf( "touch: mode %d -> %d\n", _mode, mode );
	_mode = mode;
	if ( mode != 1 ) {
		if ( _editing ) {
			[self leaveEditorSaving:NO];
		}
		[self releaseAll];
	}
	self.hidden = ( mode != 1 );
	[self refreshItems];
}

// ---- HUD editor -------------------------------------------------------------------------------------------

- (UIButton *)panelButton:(NSString *)title color:(UIColor *)color textColor:(UIColor *)text action:(SEL)action
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	[b setTitle:title forState:UIControlStateNormal];
	[b setTitleColor:text forState:UIControlStateNormal];
	b.titleLabel.font    = [UIFont boldSystemFontOfSize:13];
	b.backgroundColor    = color;
	b.layer.cornerRadius = 4;
	[b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	return b;
}

- (UILabel *)panelLabel:(NSString *)text size:(CGFloat)size
{
	UILabel *l  = [[UILabel alloc] init];
	l.text      = text;
	l.textColor = UIColor.whiteColor;
	l.font      = [UIFont boldSystemFontOfSize:size];
	return l;
}

- (void)buildPanel
{
	UIColor *yellow = [UIColor colorWithRed:1 green:0.85 blue:0.1 alpha:1];
	UIColor *cyan   = [UIColor colorWithRed:0.62 green:0.84 blue:0.9 alpha:1];

	_panel = [[UIView alloc] initWithFrame:CGRectMake( 0, 0, 470, 296 )];
	_panel.backgroundColor    = [UIColor colorWithWhite:0.18 alpha:0.92];
	_panel.layer.cornerRadius = 8;
	_panel.clipsToBounds      = YES;
	_panel.hidden             = YES;

	UIView *header         = [[UIView alloc] initWithFrame:CGRectMake( 0, 0, 470, 34 )];
	header.backgroundColor = cyan;
	[_panel addSubview:header];
	_panelTitle           = [self panelLabel:@"Toca un boton para editarlo" size:14];
	_panelTitle.textColor = UIColor.blackColor;
	_panelTitle.frame     = CGRectMake( 12, 0, 446, 34 );
	[_panel addSubview:_panelTitle];

	UILabel *hide = [self panelLabel:@"ESCONDER BOTON" size:11];
	hide.frame    = CGRectMake( 12, 44, 120, 24 );
	[_panel addSubview:hide];
	_hideSwitch           = [[UISwitch alloc] init];
	_hideSwitch.transform = CGAffineTransformMakeScale( 0.75, 0.75 );
	_hideSwitch.center    = CGPointMake( 160, 56 );
	[_hideSwitch addTarget:self action:@selector( hideChanged ) forControlEvents:UIControlEventValueChanged];
	[_panel addSubview:_hideSwitch];

	UILabel *scale = [self panelLabel:@"Escala" size:14];
	scale.frame    = CGRectMake( 12, 80, 60, 24 );
	[_panel addSubview:scale];
	_scaleSlider              = [[UISlider alloc] initWithFrame:CGRectMake( 80, 80, 180, 24 )];
	_scaleSlider.minimumValue = 0.5;
	_scaleSlider.maximumValue = 2.0;
	[self styleSlider:_scaleSlider];
	[_scaleSlider addTarget:self action:@selector( scaleChanged ) forControlEvents:UIControlEventValueChanged];
	[_panel addSubview:_scaleSlider];
	_scaleValue       = [self panelLabel:@"100 %" size:12];
	_scaleValue.frame = CGRectMake( 268, 80, 56, 24 );
	[_panel addSubview:_scaleValue];

	UILabel *opacity = [self panelLabel:@"Opacidad" size:14];
	opacity.frame    = CGRectMake( 12, 112, 70, 24 );
	[_panel addSubview:opacity];
	_opacitySlider              = [[UISlider alloc] initWithFrame:CGRectMake( 90, 112, 170, 24 )];
	_opacitySlider.minimumValue = 0.1;
	_opacitySlider.maximumValue = 1.0;
	[self styleSlider:_opacitySlider];
	[_opacitySlider addTarget:self action:@selector( opacityChanged ) forControlEvents:UIControlEventValueChanged];
	[_panel addSubview:_opacitySlider];
	_opacityValue       = [self panelLabel:@"100 %" size:12];
	_opacityValue.frame = CGRectMake( 268, 112, 56, 24 );
	[_panel addSubview:_opacityValue];

	// nudge arrows: tag encodes (dx+2)*10 + (dy+2)
	UIColor *dark   = [UIColor colorWithWhite:0.08 alpha:1];
	NSArray *arrows = @[ @[ @"▲", @( 0 ), @( -1 ), @( 392 ), @( 42 ) ], @[ @"▼", @( 0 ), @( 1 ), @( 392 ), @( 108 ) ],
	                     @[ @"◀", @( -1 ), @( 0 ), @( 340 ), @( 75 ) ], @[ @"▶", @( 1 ), @( 0 ), @( 424 ), @( 75 ) ] ];
	for ( NSArray *a in arrows ) {
		UIButton *b = [self panelButton:a[0] color:dark textColor:UIColor.whiteColor action:@selector( nudge: )];
		b.tag       = ( [a[1] intValue] + 2 ) * 10 + ( [a[2] intValue] + 2 );
		b.frame     = CGRectMake( [a[3] floatValue] - 20, [a[4] floatValue], 40, 30 );
		[_panel addSubview:b];
	}

	// look sensitivity: always editable, they are not tied to a selected button
	UILabel *cam = [self panelLabel:@"Sens. camara" size:13];
	cam.frame    = CGRectMake( 12, 148, 100, 24 );
	[_panel addSubview:cam];
	_camSlider              = [[UISlider alloc] initWithFrame:CGRectMake( 112, 148, 148, 24 )];
	_camSlider.minimumValue = 0.05;
	_camSlider.maximumValue = 0.80;
	[self styleSlider:_camSlider];
	[_camSlider addTarget:self action:@selector( camChanged ) forControlEvents:UIControlEventValueChanged];
	[_panel addSubview:_camSlider];
	_camValue       = [self panelLabel:@"" size:12];
	_camValue.frame = CGRectMake( 268, 148, 70, 24 );
	[_panel addSubview:_camValue];

	UILabel *ads = [self panelLabel:@"Sens. apuntado" size:13];
	ads.frame    = CGRectMake( 12, 180, 110, 24 );
	[_panel addSubview:ads];
	_adsSlider              = [[UISlider alloc] initWithFrame:CGRectMake( 122, 180, 138, 24 )];
	_adsSlider.minimumValue = 0.10;
	_adsSlider.maximumValue = 1.50;
	[self styleSlider:_adsSlider];
	[_adsSlider addTarget:self action:@selector( adsChanged ) forControlEvents:UIControlEventValueChanged];
	[_panel addSubview:_adsSlider];
	_adsValue       = [self panelLabel:@"" size:12];
	_adsValue.frame = CGRectMake( 268, 180, 70, 24 );
	[_panel addSubview:_adsValue];

	UILabel *move = [self panelLabel:@"Recorrido al correr" size:13];
	move.frame = CGRectMake( 12, 212, 135, 24 );
	[_panel addSubview:move];
	_moveSlider = [[UISlider alloc] initWithFrame:CGRectMake( 150, 212, 110, 24 )];
	_moveSlider.minimumValue = 0.45;
	_moveSlider.maximumValue = 1.0;
	[self styleSlider:_moveSlider];
	[_moveSlider addTarget:self action:@selector( moveChanged ) forControlEvents:UIControlEventValueChanged];
	[_panel addSubview:_moveSlider];
	_moveValue = [self panelLabel:@"" size:12];
	_moveValue.frame = CGRectMake( 268, 212, 70, 24 );
	[_panel addSubview:_moveValue];

	UIButton *reset = [self panelButton:@"RESTABLECER" color:[UIColor colorWithRed:0.9 green:0.25 blue:0.25 alpha:1] textColor:UIColor.whiteColor action:@selector( resetPressed )];
	reset.frame     = CGRectMake( 12, 252, 140, 34 );
	[_panel addSubview:reset];
	UIButton *exitBtn = [self panelButton:@"SALIR" color:cyan textColor:UIColor.blackColor action:@selector( exitPressed )];
	exitBtn.frame     = CGRectMake( 165, 252, 140, 34 );
	[_panel addSubview:exitBtn];
	UIButton *save = [self panelButton:@"GUARDAR Y USAR" color:yellow textColor:UIColor.blackColor action:@selector( savePressed )];
	save.frame     = CGRectMake( 318, 252, 140, 34 );
	[_panel addSubview:save];

	[self addSubview:_panel];
}

- (void)styleSlider:(UISlider *)sl
{
	sl.minimumTrackTintColor = [UIColor colorWithRed:1 green:0.85 blue:0.1 alpha:1];
	sl.maximumTrackTintColor = [UIColor colorWithWhite:0.45 alpha:1];
	sl.thumbTintColor        = UIColor.whiteColor;
}

- (void)camChanged
{
	Cvar_Set( "touch_look", va( "%.3f", _camSlider.value ) );
	_camValue.text = [NSString stringWithFormat:@"%.2f °/pt", _camSlider.value];
}

- (void)adsChanged
{
	Cvar_Set( "touch_look_ads", va( "%.3f", _adsSlider.value ) );
	_adsValue.text = [NSString stringWithFormat:@"x%.2f", _adsSlider.value];
}

- (void)moveChanged
{
	Cvar_Set( "touch_move_full", va( "%.3f", _moveSlider.value ) );
	_moveValue.text = [NSString stringWithFormat:@"%d %%", (int)lroundf( _moveSlider.value * 100 )];
}

- (void)layoutPanel
{
	CGRect s      = [self safeRect];
	_panel.center = CGPointMake( CGRectGetMidX( s ), CGRectGetMinY( s ) + 8 + CGRectGetHeight( _panel.bounds ) / 2 );
}

- (void)enterEditor
{
	if ( _editing ) {
		return;
	}
	[self releaseAll];
	memcpy( _saved, _cfg, sizeof( _cfg ) );
	_savedLook    = touch_look->value;
	_savedAds     = touch_look_ads->value;
	_savedMove    = touch_move_full->value;
	_editing      = YES;
	_selected     = -1;
	_panel.hidden = NO;
	[self bringSubviewToFront:_panel];
	[self syncPanel];
	[self refreshItems];
	Com_Printf( "touch: editor opened, panel frame %s hidden=%d alpha=%.2f superview=%s\n", NSStringFromCGRect( _panel.frame ).UTF8String,
	            _panel.hidden, _panel.alpha, _panel.superview == self ? "overlay" : "other" );
}

- (void)leaveEditorSaving:(BOOL)save
{
	Com_Printf( "touch: editor closed (save=%d)\n", save );
	if ( save ) {
		[self saveCfg];
	} else {
		memcpy( _cfg, _saved, sizeof( _cfg ) );
		Cvar_Set( "touch_look", va( "%g", _savedLook ) );
		Cvar_Set( "touch_look_ads", va( "%g", _savedAds ) );
		Cvar_Set( "touch_move_full", va( "%g", _savedMove ) );
	}
	_editing      = NO;
	_selected     = -1;
	_panel.hidden = YES;
	[self refreshItems];
}

- (void)syncPanel
{
	_camSlider.value = touch_look->value;
	_adsSlider.value = touch_look_ads->value;
	_moveSlider.value = touch_move_full->value;
	_camValue.text   = [NSString stringWithFormat:@"%.2f °/pt", touch_look->value];
	_adsValue.text   = [NSString stringWithFormat:@"x%.2f", touch_look_ads->value];
	_moveValue.text  = [NSString stringWithFormat:@"%d %%", (int)lroundf( touch_move_full->value * 100 )];

	BOOL has = _selected >= 0;
	_hideSwitch.enabled    = has;
	_scaleSlider.enabled   = has;
	_opacitySlider.enabled = has;
	if ( !has ) {
		_panelTitle.text = @"Toca un boton para editarlo";
		return;
	}
	_panelTitle.text     = ( (size_t)_selected == STICK_INDEX ) ? @"Joystick de movimiento" : @( buttonDefs[_selected].name );
	_hideSwitch.on       = _cfg[_selected].hidden;
	_scaleSlider.value   = _cfg[_selected].scale;
	_opacitySlider.value = _cfg[_selected].opacity;
	_scaleValue.text     = [NSString stringWithFormat:@"%d %%", (int)lroundf( _cfg[_selected].scale * 100 )];
	_opacityValue.text   = [NSString stringWithFormat:@"%d %%", (int)lroundf( _cfg[_selected].opacity * 100 )];
}

- (void)hideChanged
{
	if ( _selected < 0 ) return;
	_cfg[_selected].hidden = _hideSwitch.on;
	[self refreshItems];
}

- (void)scaleChanged
{
	if ( _selected < 0 ) return;
	_cfg[_selected].scale = _scaleSlider.value;
	_scaleValue.text      = [NSString stringWithFormat:@"%d %%", (int)lroundf( _scaleSlider.value * 100 )];
	[self refreshItems];
}

- (void)opacityChanged
{
	if ( _selected < 0 ) return;
	_cfg[_selected].opacity = _opacitySlider.value;
	_opacityValue.text      = [NSString stringWithFormat:@"%d %%", (int)lroundf( _opacitySlider.value * 100 )];
	[self refreshItems];
}

- (void)nudge:(UIButton *)sender
{
	if ( _selected < 0 ) return;
	int dx   = (int)sender.tag / 10 - 2;
	int dy   = (int)sender.tag % 10 - 2;
	CGRect s = [self safeRect];
	if ( !_cfg[_selected].custom ) {
		CGPoint c = [self defaultCentreOf:_selected];
		_cfg[_selected].custom = YES;
		_cfg[_selected].fx     = ( c.x - CGRectGetMinX( s ) ) / CGRectGetWidth( s );
		_cfg[_selected].fy     = ( c.y - CGRectGetMinY( s ) ) / CGRectGetHeight( s );
	}
	_cfg[_selected].fx = fminf( 1.0f, fmaxf( 0.0f, _cfg[_selected].fx + dx * 2.0f / CGRectGetWidth( s ) ) );
	_cfg[_selected].fy = fminf( 1.0f, fmaxf( 0.0f, _cfg[_selected].fy + dy * 2.0f / CGRectGetHeight( s ) ) );
	[self refreshItems];
}

- (void)resetPressed
{
	[self resetCfgToDefaults];
	Cvar_Set( "touch_look", "0.25" );
	Cvar_Set( "touch_look_ads", "0.6" );
	Cvar_Set( "touch_move_full", "0.65" );
	[self syncPanel];
	[self refreshItems];
}

- (void)exitPressed
{
	[self leaveEditorSaving:NO];
}

- (void)savePressed
{
	[self leaveEditorSaving:YES];
}

// ---- touch handling ---------------------------------------------------------------------------------------

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
	// menus and loading screens: let SDL see the touches, it turns them into mouse events for the UI
	if ( _mode != 1 ) {
		return nil;
	}
	if ( _editing && !_panel.hidden && CGRectContainsPoint( _panel.frame, point ) ) {
		return [_panel hitTest:[self convertPoint:point toView:_panel] withEvent:event];
	}
	return self;
}

// Button hit areas take priority over the stick, including custom layouts.
- (int)itemAt:(CGPoint)p
{
	// A button must keep its hit area even if the movable stick overlaps it.
	for ( int i = (int)NUM_BUTTONS - 1; i >= 0; i-- ) {
		if ( ![self visible:i] ) continue;
		CGPoint c = [self centreOf:i];
		CGFloat r = [self radiusOf:i] + BUTTON_SLOP;
		if ( hypot( p.x - c.x, p.y - c.y ) <= r ) {
			return i;
		}
	}
	if ( [self visible:STICK_INDEX] ) {
		CGPoint c = [self centreOf:STICK_INDEX];
		if ( hypot( p.x - c.x, p.y - c.y ) <= [self radiusOf:STICK_INDEX] + 8 ) {
			return (int)STICK_INDEX;
		}
	}
	return -1;
}

- (BOOL)hasActiveLook
{
	for ( int i = 0; i < MAX_TRACKED_TOUCHES; i++ ) {
		if ( _touches[i].touch && ( _touches[i].role == ROLE_LOOK || _touches[i].role == ROLE_FIRE_LOOK ) ) return YES;
	}
	return NO;
}

- (void)yieldFireLookToFreeLook
{
	for ( int i = 0; i < MAX_TRACKED_TOUCHES; i++ ) {
		if ( _touches[i].touch && _touches[i].role == ROLE_FIRE_LOOK ) {
			_touches[i].role = ROLE_FIRE_WAIT;
		}
	}
}

- (touchState_t *)stateFor:(UITouch *)t create:(BOOL)create
{
	touchState_t *free = NULL;
	for ( int i = 0; i < MAX_TRACKED_TOUCHES; i++ ) {
		if ( _touches[i].touch == t ) return &_touches[i];
		if ( !_touches[i].touch && !free ) free = &_touches[i];
	}
	return create ? free : NULL;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	CGRect s = [self safeRect];
	for ( UITouch *t in touches ) {
		CGPoint p        = [t locationInView:self];
		touchState_t *st = [self stateFor:t create:YES];
		if ( !st ) continue;
		st->touch = t;
		st->role  = ROLE_NONE;
		st->last  = p;

		if ( _editing ) {
			int hit = [self itemAt:p];
			if ( hit >= 0 ) {
				_selected  = hit;
				st->role   = ROLE_EDIT_DRAG;
				st->button = hit;
				CGPoint c  = [self centreOf:hit];
				st->grab   = CGPointMake( c.x - p.x, c.y - p.y );
				[self syncPanel];
				[self refreshItems];
			} else {
				st->role = ROLE_NONE;
			}
			continue;
		}

		int b = [self itemAt:p];
		if ( b >= 0 && (size_t)b != STICK_INDEX ) {
			if ( buttonDefs[b].key == KEY_EDIT_LAYOUT ) {
				[_haptic impactOccurred];
				[self enterEditor];
				st->touch = nil;
				continue;
			}
			st->role   = b == AIM_FIRE_BUTTON ? ( [self hasActiveLook] ? ROLE_FIRE_WAIT : ROLE_FIRE_LOOK ) : ROLE_BUTTON;
			st->button = b;
			if (ios_diag && ios_diag->integer) _diagButtons++;
			Com_Printf( "touch: button %s -> key %d\n", buttonDefs[b].name, buttonDefs[b].key );
			[self key:buttonDefs[b].key down:YES];
			[self setPressed:YES forButton:b];
			[_haptic impactOccurred];
			// weapon-class and wheel keys are one-shot commands: release right away
			if ( buttonDefs[b].key == K_MWHEELUP || buttonDefs[b].key == '5' ) {
				[self key:buttonDefs[b].key down:NO];
			}
		} else if ( !_stickActive && !_cfg[STICK_INDEX].hidden
		            && ( p.x < CGRectGetMinX( s ) + CGRectGetWidth( s ) * STICK_ZONE_WIDTH || b == (int)STICK_INDEX ) ) {
			st->role     = ROLE_STICK;
			st->origin   = ( b == (int)STICK_INDEX ) ? [self centreOf:STICK_INDEX] : p;
			_stickActive = YES;
			[self drawStickKnobAt:p centre:st->origin];
		} else if ( b != (int)STICK_INDEX
		            && p.x >= CGRectGetMinX( s ) + CGRectGetWidth( s ) * STICK_ZONE_WIDTH ) {
			// A separate camera finger takes priority over drag-to-aim on the fire button.
			[self yieldFireLookToFreeLook];
			st->role = [self hasActiveLook] ? ROLE_LOOK_WAIT : ROLE_LOOK;
		}
	}
}

- (void)drawStickKnobAt:(CGPoint)knob centre:(CGPoint)centre
{
	CGFloat s = _cfg[STICK_INDEX].scale;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_layers[STICK_INDEX].position = centre;
	_stickKnob.position           = knob;
	_stickKnob.transform          = CATransform3DMakeScale( s, s, 1 );
	_stickKnob.fillColor          = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
	_stickKnob.opacity            = _cfg[STICK_INDEX].opacity;
	[CATransaction commit];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	CGRect s = [self safeRect];
	for ( UITouch *t in touches ) {
		touchState_t *st = [self stateFor:t create:NO];
		if ( !st ) continue;
		CGPoint p = [t locationInView:self];

		if ( st->role == ROLE_EDIT_DRAG ) {
			CGFloat x           = fminf( CGRectGetMaxX( s ), fmaxf( CGRectGetMinX( s ), p.x + st->grab.x ) );
			CGFloat y           = fminf( CGRectGetMaxY( s ), fmaxf( CGRectGetMinY( s ), p.y + st->grab.y ) );
			_cfg[st->button].custom = YES;
			_cfg[st->button].fx = ( x - CGRectGetMinX( s ) ) / CGRectGetWidth( s );
			_cfg[st->button].fy = ( y - CGRectGetMinY( s ) ) / CGRectGetHeight( s );
			[self refreshItems];
		} else if ( st->role == ROLE_STICK ) {
			if (ios_diag && ios_diag->integer) _diagStickMoves++;
			CGFloat radius = STICK_RADIUS * _cfg[STICK_INDEX].scale;
			CGFloat dx     = ( p.x - st->origin.x ) / radius;
			CGFloat dy     = ( p.y - st->origin.y ) / radius;
			CGFloat m      = hypot( dx, dy );
			if ( m > 1 ) {
				dx /= m;
				dy /= m;
				m = 1;
			}
			float x = 0, y = 0;
			if ( m > STICK_DEADZONE ) {
				float full  = fminf( 1.0f, fmaxf( 0.45f, touch_move_full->value ) );
				float scale = fminf( 1.0f, ( m - STICK_DEADZONE ) / ( full - STICK_DEADZONE ) ) / m;
				x           = dx * scale;
				y           = dy * scale;
			}
			[self sendStickX:x y:y];
			[self drawStickKnobAt:CGPointMake( st->origin.x + dx * radius, st->origin.y + dy * radius ) centre:st->origin];
		} else if ( st->role == ROLE_LOOK || st->role == ROLE_FIRE_LOOK ) {
			if (ios_diag && ios_diag->integer) _diagLookMoves++;
			[self sendLookDX:p.x - st->last.x dy:p.y - st->last.y];
		} else if ( st->role == ROLE_LOOK_WAIT && ![self hasActiveLook] ) {
			// Take over only after the previous look finger lifts; this move sets the origin.
			st->role = ROLE_LOOK;
		} else if ( st->role == ROLE_FIRE_WAIT && ![self hasActiveLook] ) {
			st->role = ROLE_FIRE_LOOK;
		}
		st->last = p;
		if (ios_diag && ios_diag->integer && (st->role == ROLE_STICK || st->role == ROLE_LOOK || st->role == ROLE_FIRE_LOOK)) {
			double age = (CACurrentMediaTime() - t.timestamp) * 1000.0;
			if (age >= 0.0 && age < 1000.0) {
				_diagEventAgeCount++;
				_diagEventAgeTotal += age;
				if (age > _diagEventAgeMax) _diagEventAgeMax = age;
			}
		}
	}
}

- (void)logDiagnostics
{
	if (!ios_diag || !ios_diag->integer || _mode != 1) {
		_diagStarted = 0;
		_diagLookMoves = _diagStickMoves = _diagButtons = _diagEventAgeCount = 0;
		_diagEventAgeTotal = _diagEventAgeMax = 0.0;
		return;
	}

	int now = Sys_Milliseconds();
	if (!_diagStarted) {
		_diagStarted = now;
		return;
	}
	if (now - _diagStarted < 1000) return;

	Com_Printf("IOS_DIAG touch interval_ms=%d look_moves=%d stick_moves=%d buttons=%d event_age_avg_ms=%.1f event_age_max_ms=%.1f\n",
		now - _diagStarted, _diagLookMoves, _diagStickMoves, _diagButtons,
		_diagEventAgeCount ? _diagEventAgeTotal / _diagEventAgeCount : -1.0,
		_diagEventAgeCount ? _diagEventAgeMax : -1.0);
	_diagStarted = now;
	_diagLookMoves = _diagStickMoves = _diagButtons = _diagEventAgeCount = 0;
	_diagEventAgeTotal = _diagEventAgeMax = 0.0;
}

- (void)endTouches:(NSSet<UITouch *> *)touches
{
	for ( UITouch *t in touches ) {
		touchState_t *st = [self stateFor:t create:NO];
		if ( !st ) continue;
		if ( st->role == ROLE_STICK ) {
			[self sendStickX:0 y:0];
			_stickActive = NO;
			[self refreshItems];
		} else if ( st->role == ROLE_BUTTON || st->role == ROLE_FIRE_LOOK || st->role == ROLE_FIRE_WAIT ) {
			int k = buttonDefs[st->button].key;
			if ( k != K_MWHEELUP && k != '5' ) {
				[self key:k down:NO];
			}
			[self setPressed:NO forButton:st->button];
		}
		st->touch = nil;
		st->role  = ROLE_NONE;
	}
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self endTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self endTouches:touches];
}

@end

/*
==============
IOS_TouchControls_Frame

Called once per frame from IN_Frame. The overlay is created lazily because the SDL window does not exist yet
when the input system starts.
==============
*/
void IOS_TouchControls_Frame( int mode )
{
	static MohaaTouchOverlay *overlay = nil;

	if ( !overlay ) {
		SDL_Window *window = SDL_GetKeyboardFocus();
		if ( !window ) {
			return;
		}

		SDL_SysWMinfo info;
		SDL_VERSION( &info.version );
		if ( !SDL_GetWindowWMInfo( window, &info ) || !info.info.uikit.window ) {
			return;
		}

		touch_look                 = Cvar_Get( "touch_look", "0.25", CVAR_ARCHIVE ); // degrees per point
		touch_look_ads             = Cvar_Get( "touch_look_ads", "0.6", CVAR_ARCHIVE );
		touch_move_full           = Cvar_Get( "touch_move_full", "0.65", CVAR_ARCHIVE );
		touch_leanstrafe           = Cvar_Get( "touch_leanstrafe", "1", CVAR_ARCHIVE );
		touch_lean_start           = Cvar_Get( "touch_lean_start", "0.25", CVAR_ARCHIVE );
		touch_lean_stop            = Cvar_Get( "touch_lean_stop", "0.12", CVAR_ARCHIVE );
		touch_startedit            = Cvar_Get( "touch_startedit", "0", CVAR_TEMP ); // open the HUD editor on start (debug)
		ios_diag                   = Cvar_Get( "ios_diag", "0", CVAR_ARCHIVE );

		UIWindow *uiWindow = info.info.uikit.window;
		overlay            = [[MohaaTouchOverlay alloc] initWithFrame:uiWindow.bounds];
		overlay.hidden     = YES;
		[uiWindow addSubview:overlay];
	}

	overlay.mode = mode;
	[overlay logDiagnostics];

	// debug cvar: open the editor once gameplay has been stable for a while (menus can flicker right at spawn)
	static int stableFrames;
	stableFrames = ( mode == 1 ) ? stableFrames + 1 : 0;
	if ( stableFrames > 150 && touch_startedit->integer ) {
		Cvar_Set( "touch_startedit", "0" );
		Com_Printf( "touch: opening the HUD editor\n" );
		[overlay enterEditor];
	}
}
