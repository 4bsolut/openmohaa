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
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

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

/*
=================
IOS_ChooseTargetGame

OpenMoHAA picks the game (and its data folder) from com_target_game, which can only be set at startup:
0 = Allied Assault (main), 1 = Spearhead (mainta), 2 = Breakthrough (maintt).
An iOS app cannot be launched with arguments, so ask before the engine starts. Only the versions whose
folder exists next to main/ are offered; with a single one installed there is nothing to ask.
The last choice is remembered and highlighted. Returns -1 when the command line already set it.
=================
*/
static const char *IOS_ArgValue( int argc, char **argv, const char *name )
{
	for ( int i = 1; i + 2 < argc; i++ ) {
		if ( !strcmp( argv[i], "+set" ) && !strcmp( argv[i + 1], name ) ) {
			return argv[i + 2];
		}
	}
	return NULL;
}

static qboolean IOS_FolderExists( const char *base, const char *dir )
{
	char        path[MAX_OSPATH];
	struct stat st;

	Com_sprintf( path, sizeof( path ), "%s/%s", base, dir );
	return stat( path, &st ) == 0 && S_ISDIR( st.st_mode );
}

int IOS_ChooseTargetGame( int argc, char **argv )
{
	static const char *const folders[3] = { "main", "mainta", "maintt" };
	static const char *const labels[3]  = { "Allied Assault", "Spearhead", "Breakthrough" };
	char                     base[MAX_OSPATH];
	char                     lastPath[MAX_OSPATH];
	const char              *home = getenv( "HOME" );
	const char              *arg;
	SDL_MessageBoxButtonData buttons[3];
	SDL_MessageBoxData       data;
	int                      available[3];
	int                      count = 0, last = 0, buttonId = -1;
	FILE                    *f;

	if ( IOS_ArgValue( argc, argv, "com_target_game" ) ) {
		return -1;
	}

	// same default as Sys_StripAppBundle: <app>/Documents, or fs_basepath when given
	arg = IOS_ArgValue( argc, argv, "fs_basepath" );
	if ( arg ) {
		Q_strncpyz( base, arg, sizeof( base ) );
	} else if ( home && *home ) {
		Com_sprintf( base, sizeof( base ), "%s/Documents", home );
	} else {
		return -1;
	}

	for ( int g = 0; g < 3; g++ ) {
		if ( IOS_FolderExists( base, folders[g] ) ) {
			available[count++] = g;
		}
	}

	// Spearhead and Breakthrough need main/ too: with no expansion there is no choice to make
	if ( count <= 1 ) {
		return -1;
	}

	Com_sprintf( lastPath, sizeof( lastPath ), "%s/Library/Application Support/openmohaa/target_game", home ? home : "." );
	if ( ( f = fopen( lastPath, "r" ) ) != NULL ) {
		int v = 0;
		if ( fscanf( f, "%d", &v ) == 1 && v >= 0 && v <= 2 ) {
			last = v;
		}
		fclose( f );
	}

	for ( int i = 0; i < count; i++ ) {
		buttons[i].flags    = ( available[i] == last ) ? SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT : 0;
		buttons[i].buttonid = available[i];
		buttons[i].text     = labels[available[i]];
	}

	data.flags       = SDL_MESSAGEBOX_INFORMATION;
	data.window      = NULL;
	data.title       = "MOHAA Mobile";
	data.message     = "¿Qué versión del juego quieres cargar?";
	data.numbuttons  = count;
	data.buttons     = buttons;
	data.colorScheme = NULL;

	if ( SDL_ShowMessageBox( &data, &buttonId ) < 0 || buttonId < 0 || buttonId > 2 ) {
		buttonId = last;
	}

	if ( ( f = fopen( lastPath, "w" ) ) != NULL ) {
		fprintf( f, "%d\n", buttonId );
		fclose( f );
	}

	return buttonId;
}
