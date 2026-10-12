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

// iOS replacements for the Cocoa-only functions of sys_osx.m

#ifndef __APPLE__
#error This file is for iOS only.
#endif

#include <stdlib.h>

#include "../qcommon/q_shared.h"
#include "../qcommon/qcommon.h"
#include "sys_local.h"

#ifdef USE_INTERNAL_SDL_HEADERS
#	include "SDL.h"
#else
#	include <SDL.h>
#endif

/*
==============
Sys_Dialog

Display a message box through SDL (UIAlertController on iOS)
==============
*/
dialogResult_t Sys_Dialog( dialogType_t type, const char *message, const char *title )
{
	SDL_MessageBoxButtonData buttons[2];
	SDL_MessageBoxData       data;
	int                      numButtons = 1;
	int                      buttonId   = 0;

	buttons[0].flags    = SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT;
	buttons[0].buttonid = 0;
	buttons[0].text     = "OK";
	buttons[1].flags    = SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT;
	buttons[1].buttonid = 1;
	buttons[1].text     = "Cancel";

	switch ( type ) {
	case DT_YES_NO:
		buttons[0].text = "Yes";
		buttons[1].text = "No";
		numButtons      = 2;
		break;
	case DT_OK_CANCEL:
		numButtons = 2;
		break;
	default:
		break;
	}

	data.flags       = ( type == DT_ERROR ) ? SDL_MESSAGEBOX_ERROR : SDL_MESSAGEBOX_WARNING;
	data.window      = NULL;
	data.title       = title;
	data.message     = message;
	data.numbuttons  = numButtons;
	data.buttons     = buttons;
	data.colorScheme = NULL;

	if ( SDL_ShowMessageBox( &data, &buttonId ) < 0 ) {
		return DR_OK;
	}

	// DR_YES == DR_OK == 0, DR_NO == DR_CANCEL == 1
	return ( buttonId == 1 ) ? DR_NO : DR_OK;
}

/*
=================
Sys_StripAppBundle

Used by sys_main.c to find the default base directory (game data). The iOS app bundle is read-only and
holds no game data, so use the app's Documents folder instead (shown in the Files app because of
UIFileSharingEnabled), where the user imports their own main/, mainta/ and maintt/ folders.
=================
*/
char *Sys_StripAppBundle( char *dir )
{
	static char documents[MAX_OSPATH];
	const char *home = getenv( "HOME" );

	if ( !home || !*home ) {
		return dir;
	}

	Com_sprintf( documents, sizeof( documents ), "%s/Documents", home );
	return documents;
}
