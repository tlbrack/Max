/*
 *  $Id$
 *
 *  Copyright (C) 2005, 2006 Stephen F. Booth <me@sbooth.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#import "CompactDiscDocument.h"

#import "CompactDiscDocumentToolbar.h"
#import "CompactDiscController.h"
#import "Track.h"
#import "AudioMetadata.h"
#import "FreeDB.h"
#import "FreeDBMatchSheet.h"
#import "Genres.h"
#import "TaskMaster.h"
#import "Encoder.h"
#import "MediaController.h"

#import "MallocException.h"
#import "IOException.h"
#import "FreeDBException.h"
#import "EmptySelectionException.h"
#import "MissingResourceException.h"

#import "AmazonAlbumArt.h"
#import "UtilityFunctions.h"

#define kEncodeMenuItemTag					1
#define kTrackInfoMenuItemTag				2
#define kQueryFreeDBMenuItemTag				3
#define kEjectDiscMenuItemTag				4
#define kSubmitToFreeDBMenuItemTag			5
#define kSelectNextTrackMenuItemTag			6
#define kSelectPreviousTrackMenuItemTag		7

@interface CompactDiscDocument (Private)
- (void) updateAlbumArtImageRep;
@end

@implementation CompactDiscDocument

+ (void) initialize
{
	NSString				*compactDiscDocumentDefaultsValuesPath;
    NSDictionary			*compactDiscDocumentDefaultsValuesDictionary;
	
	@try {
		// Set up defaults
		compactDiscDocumentDefaultsValuesPath = [[NSBundle mainBundle] pathForResource:@"CompactDiscDocumentDefaults" ofType:@"plist"];
		if(nil == compactDiscDocumentDefaultsValuesPath) {
			@throw [MissingResourceException exceptionWithReason:NSLocalizedStringFromTable(@"Unable to load required resource", @"Exceptions", @"")
														userInfo:[NSDictionary dictionaryWithObject:@"CompactDiscDocumentDefaults.plist" forKey:@"filename"]];
		}
		compactDiscDocumentDefaultsValuesDictionary = [NSDictionary dictionaryWithContentsOfFile:compactDiscDocumentDefaultsValuesPath];
		[[NSUserDefaults standardUserDefaults] registerDefaults:compactDiscDocumentDefaultsValuesDictionary];
		
	}
	
	@catch(NSException *exception) {
		displayExceptionAlert(exception);
	}
}

- (id) init
{
	if((self = [super init])) {
		_tracks			= [[NSMutableArray arrayWithCapacity:20] retain];
		_discInDrive	= [NSNumber numberWithBool:NO];
		_disc			= nil;
		
		return self;
	}
	return nil;
}

- (void) dealloc
{	
	[_tracks removeAllObjects];
	[_tracks release];
	
	if(nil != _disc) {
		[_disc release];
	}
	
	[super dealloc];
}

- (void) awakeFromNib
{
	[_trackTable setAutosaveName:[NSString stringWithFormat: @"Tracks for 0x%.8x", [self discID]]];
	[_trackTable setAutosaveTableColumns:YES];
}

#pragma mark NSDocument overrides

- (BOOL) validateMenuItem:(NSMenuItem *)item
{
	BOOL result;
	
	switch([item tag]) {
		default:								result = [super validateMenuItem:item];			break;
		case kEncodeMenuItemTag:				result = [self encodeAllowed];					break;
		case kQueryFreeDBMenuItemTag:			result = [self queryFreeDBAllowed];				break;
		case kSubmitToFreeDBMenuItemTag:		result = [self submitToFreeDBAllowed];			break;
		case kEjectDiscMenuItemTag:				result = [self ejectDiscAllowed];				break;
		case kSelectNextTrackMenuItemTag:		result = [_trackController canSelectNext];		break;
		case kSelectPreviousTrackMenuItemTag:	result = [_trackController canSelectPrevious];	break;
	}
	
	return result;
}

- (void) makeWindowControllers 
{
	CompactDiscController *controller = [[CompactDiscController alloc] initWithWindowNibName:@"CompactDiscDocument" owner:self];
	[self addObserver:controller forKeyPath:@"title" options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld) context:nil];
	[self addWindowController:[controller autorelease]];
}

- (void) windowControllerDidLoadNib:(NSWindowController *)controller
{
	[controller setShouldCascadeWindows:NO];
	[controller setWindowFrameAutosaveName:[NSString stringWithFormat: NSLocalizedStringFromTable(@"Compact Disc 0x%.8x", @"CompactDisc", @""), [self discID]]];
	
	NSToolbar *toolbar = [[[CompactDiscDocumentToolbar alloc] initWithCompactDiscDocument:self] autorelease];
    
    [toolbar setAllowsUserCustomization: YES];
    [toolbar setAutosavesConfiguration: YES];
    [toolbar setDisplayMode: NSToolbarDisplayModeIconAndLabel];
    
    [toolbar setDelegate:toolbar];
	
    [[controller window] setToolbar:toolbar];
	
}

- (NSData *) dataOfType:(NSString *) typeName error:(NSError **) outError
{
	if([typeName isEqualToString:@"Max CD Information"]) {
		NSData					*data;
		NSString				*error;
		
		data = [NSPropertyListSerialization dataFromPropertyList:[self getDictionary] format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
		if(nil != data) {
			return data;
		}
		else {
			*outError = [NSError errorWithDomain:NSCocoaErrorDomain code:-1 userInfo:[NSDictionary dictionaryWithObject:[error autorelease] forKey:NSLocalizedFailureReasonErrorKey]];
		}
	}
	return nil;
}

- (BOOL) readFromData:(NSData *) data ofType:(NSString *) typeName error:(NSError **) outError
{    
	if([typeName isEqualToString:@"Max CD Information"]) {
		NSDictionary			*dictionary;
		NSPropertyListFormat	format;
		NSString				*error;
		
		dictionary = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListImmutable format:&format errorDescription:&error];
		if(nil != dictionary) {
			[self setPropertiesFromDictionary:dictionary];
		}
		else {
			[error release];
		}
		return YES;
	}
    return NO;
}
#pragma mark Delegate methods

- (void) windowWillClose:(NSNotification *)notification
{
	NSArray *controllers = [self windowControllers];
	if(0 != [controllers count]) {
		[self removeObserver:[controllers objectAtIndex:0] forKeyPath:@"title"];
	}
}

- (void) controlTextDidEndEditing:(NSNotification *)notification
{
	[self updateChangeCount:NSChangeDone];
}

#pragma mark Exception Display

- (void) displayException:(NSException *)exception
{
	NSWindow *window = [self windowForSheet];
	if(nil == window) {
		displayExceptionAlert(exception);
	}
	else {
		displayExceptionSheet(exception, window, self, @selector(alertDidEnd:returnCode:contextInfo:), nil);
	}
}

- (void) alertDidEnd:(NSAlert *)alert returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	// Nothing for now
}

#pragma mark Disc Management

- (int) discID
{
	if([self discInDrive]) {
		return [_disc discID];
	}
	else {
		return [_discID intValue];
	}
}

- (BOOL) discInDrive
{
	return [_discInDrive boolValue];
}

- (void) discEjected
{
	[self setDisc:nil];
}

- (CompactDisc *) getDisc
{
	return _disc;
}

- (void) setDisc:(CompactDisc *) disc
{
	unsigned			i;
	
	if(nil != _disc) {
		[_disc release];
		_disc = nil;
	}

	if(nil == disc) {
		[self setValue:[NSNumber numberWithBool:NO] forKey:@"discInDrive"];
		return;
	}
	
	_disc			= [disc retain];

	[self setValue:[NSNumber numberWithBool:YES] forKey:@"discInDrive"];
	
	[self setValue:[_disc MCN] forKey:@"MCN"];
	
	[self willChangeValueForKey:@"tracks"];
	if(0 == [_tracks count]) {
		for(i = 0; i < [_disc trackCount]; ++i) {
			Track *track = [[Track alloc] init];
			[track setValue:self forKey:@"disc"];
			[_tracks addObject:[[track retain] autorelease]];
		}
	}
	[self didChangeValueForKey:@"tracks"];
	
	for(i = 0; i < [_disc trackCount]; ++i) {
		Track			*track		= [_tracks objectAtIndex:i];
		
		[track setValue:[NSNumber numberWithUnsignedInt:i + 1] forKey:@"number"];
		[track setValue:[NSNumber numberWithUnsignedLong:[_disc firstSectorForTrack:i]] forKey:@"firstSector"];
		[track setValue:[NSNumber numberWithUnsignedLong:[_disc lastSectorForTrack:i]] forKey:@"lastSector"];
		
		[track setValue:[NSNumber numberWithUnsignedInt:[_disc channelsForTrack:i]] forKey:@"channels"];
		[track setValue:[NSNumber numberWithUnsignedInt:[_disc trackHasPreEmphasis:i]] forKey:@"preEmphasis"];
		[track setValue:[NSNumber numberWithUnsignedInt:[_disc trackAllowsDigitalCopy:i]] forKey:@"copyPermitted"];
		[track setValue:[_disc ISRC:i] forKey:@"ISRC"];
	}
}

#pragma mark Track information

- (BOOL) ripInProgress
{
	NSEnumerator	*enumerator		= [_tracks objectEnumerator];
	Track			*track;
	
	while((track = [enumerator nextObject])) {
		if([[track valueForKey:@"ripInProgress"] boolValue]) {
			return YES;
		}
	}
	
	return NO;
}

- (BOOL) encodeInProgress
{
	NSEnumerator	*enumerator		= [_tracks objectEnumerator];
	Track			*track;
	
	while((track = [enumerator nextObject])) {
		if([[track valueForKey:@"encodeInProgress"] boolValue]) {
			return YES;
		}
	}
	
	return NO;
}

- (NSArray *)	tracks					{ return _tracks; }

- (NSArray *) selectedTracks
{
	NSMutableArray	*result			= [NSMutableArray arrayWithCapacity:[_disc trackCount]];
	NSEnumerator	*enumerator		= [_tracks objectEnumerator];
	Track			*track;
	
	while((track = [enumerator nextObject])) {
		if([[track valueForKey:@"selected"] boolValue]) {
			[result addObject: track];
		}
	}
	
	return [[result retain] autorelease];
}

- (BOOL) emptySelection
{
	return (0 == [[self selectedTracks] count]);
}

- (IBAction) selectAll:(id) sender
{
	unsigned	i;
	
	for(i = 0; i < [_tracks count]; ++i) {
		if(NO == [[[_tracks objectAtIndex:i] valueForKey:@"ripInProgress"] boolValue] && NO == [[[_tracks objectAtIndex:i] valueForKey:@"encodeInProgress"] boolValue]) {
			[[_tracks objectAtIndex:i] setValue:[NSNumber numberWithBool:YES] forKey:@"selected"];
		}
	}
}

- (IBAction) selectNone:(id) sender
{
	unsigned	i;
	
	for(i = 0; i < [_tracks count]; ++i) {
		if(NO == [[[_tracks objectAtIndex:i] valueForKey:@"ripInProgress"] boolValue] && NO == [[[_tracks objectAtIndex:i] valueForKey:@"encodeInProgress"] boolValue]) {
			[[_tracks objectAtIndex:i] setValue:[NSNumber numberWithBool:NO] forKey:@"selected"];
		}
	}
}

#pragma mark State

- (BOOL) encodeAllowed
{
	return ([self discInDrive] && (NO == [self emptySelection]) && (NO == [self ripInProgress]) && (NO == [self encodeInProgress]));
}

- (BOOL) queryFreeDBAllowed
{
	return [self discInDrive];
}

- (BOOL) submitToFreeDBAllowed
{
	NSEnumerator	*enumerator				= [_tracks objectEnumerator];
	Track			*track;
	BOOL			trackTitlesValid		= YES;
	
	while((track = [enumerator nextObject])) {
		if(nil == [track valueForKey:@"title"]) {
			trackTitlesValid = NO;
			break;
		}
	}
	
	return ([self discInDrive] && (nil != _title) && (nil != _artist) && (nil != _genre) && trackTitlesValid);
}

- (BOOL) ejectDiscAllowed
{
	return [self discInDrive];	
}

#pragma mark Actions

- (IBAction) encode:(id) sender
{
	Track			*track;
	NSArray			*selectedTracks;
	NSEnumerator	*enumerator;
	
	@try {
		// Do nothing if the disc isn't in the drive, the selection is empty, or a rip/encode is in progress
		if(NO == [self discInDrive]) {
			return;
		}
		else if([self emptySelection]) {
			@throw [EmptySelectionException exceptionWithReason:NSLocalizedStringFromTable(@"Please select one or more tracks to encode", @"Exceptions", @"") userInfo:nil];
		}
		else if([self ripInProgress] || [self encodeInProgress]) {
			@throw [NSException exceptionWithName:@"ActiveTaskException" reason:NSLocalizedStringFromTable(@"A rip or encode operation is already in progress", @"Exceptions", @"") userInfo:nil];
		}
		
		// Iterate through the selected tracks and rip/encode them
		selectedTracks	= [self selectedTracks];
		
		// Create one single file for more than one track
		if([[NSUserDefaults standardUserDefaults] boolForKey:@"singleFileOutput"] && 1 < [selectedTracks count]) {
			
			AudioMetadata *metadata = [[selectedTracks objectAtIndex:0] metadata];
			
			[metadata setValue:[NSNumber numberWithInt:0] forKey:@"trackNumber"];
			[metadata setValue:NSLocalizedStringFromTable(@"Multiple Tracks", @"CompactDisc", @"") forKey:@"trackTitle"];
			[metadata setValue:nil forKey:@"trackArtist"];
			[metadata setValue:nil forKey:@"trackGenre"];
			[metadata setValue:nil forKey:@"trackYear"];
						
			[[TaskMaster sharedController] encodeTracks:selectedTracks metadata:metadata];
		}
		// Create one file per track
		else {			
			enumerator		= [selectedTracks objectEnumerator];
			
			while((track = [enumerator nextObject])) {
				[[TaskMaster sharedController] encodeTrack:track];
			}
		}
	}
	
	@catch(NSException *exception) {
		[self displayException:exception];
	}
}

- (IBAction) ejectDisc:(id) sender
{
	if(NO == [self discInDrive]) {
		return;
	}
	
	if([self ripInProgress]) {
		NSAlert *alert = [[[NSAlert alloc] init] autorelease];
		[alert addButtonWithTitle:NSLocalizedStringFromTable(@"OK", @"General", @"")];
		[alert addButtonWithTitle:NSLocalizedStringFromTable(@"Cancel", @"General", @"")];
		[alert setMessageText:NSLocalizedStringFromTable(@"Really eject the disc?", @"CompactDisc", @"")];
		[alert setInformativeText:NSLocalizedStringFromTable(@"There are active ripping tasks", @"CompactDisc", @"")];
		[alert setAlertStyle:NSWarningAlertStyle];
		
		if(NSAlertSecondButtonReturn == [alert runModal]) {
			return;
		}
		// Stop all associated rip tasks
		else {
			[[TaskMaster sharedController] stopRippingTasksForCompactDiscDocument:self];
		}
	}
	
	[[MediaController sharedController] ejectDiscForCompactDiscDocument:self];
}

- (IBAction) selectNextTrack:(id) sender
{
	[_trackController selectNext:sender];
}

- (IBAction) selectPreviousTrack:(id) sender
{
	[_trackController selectPrevious:sender];	
}

- (IBAction) selectAlbumArt:(id) sender
{
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	
	[panel setAllowsMultipleSelection:NO];
	[panel setCanChooseDirectories:NO];
	[panel setCanChooseFiles:YES];
	
	[panel beginSheetForDirectory:nil file:nil types:[NSImage imageFileTypes] modalForWindow:[self windowForSheet] modalDelegate:self didEndSelector:@selector(openPanelDidEnd:returnCode:contextInfo:) contextInfo:nil];
}

- (void) openPanelDidEnd:(NSOpenPanel *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
    if(NSOKButton == returnCode) {
		NSArray		*filesToOpen	= [sheet filenames];
		int			count			= [filesToOpen count];
		int			i;
		NSImage		*image			= nil;
		
		for(i = 0; i < count; ++i) {
			image = [[NSImage alloc] initWithContentsOfFile:[filesToOpen objectAtIndex:i]];
			if(nil != image) {
				[self setValue:[image autorelease] forKey:@"albumArt"];
				[self albumArtUpdated:self];
			}
		}
	}	
}

- (IBAction) albumArtUpdated:(id) sender
{
	[self updateChangeCount:NSChangeDone];
	[self updateAlbumArtImageRep];
}

- (void) updateAlbumArtImageRep
{
	NSEnumerator		*enumerator;
	NSImageRep			*currentRepresentation		= nil;
	NSBitmapImageRep	*bitmapRep					= nil;
	
	if(nil == _albumArt) {
		[self setValue:nil forKey:@"albumArtBitmap"];
		return;
	}
	
	enumerator = [[_albumArt representations] objectEnumerator];
	while((currentRepresentation = [enumerator nextObject])) {
		if([currentRepresentation isKindOfClass:[NSBitmapImageRep class]]) {
			bitmapRep = (NSBitmapImageRep *)currentRepresentation;
			break;
		}
	}
	
	// Create a bitmap representation if one doesn't exist
	if(nil == bitmapRep) {
		NSSize size = [_albumArt size];
		[_albumArt lockFocus];
		bitmapRep = [[[NSBitmapImageRep alloc] initWithFocusedViewRect:NSMakeRect(0, 0, size.width, size.height)] autorelease];
		[_albumArt unlockFocus];
	}
	
	[self setValue:bitmapRep forKey:@"albumArtBitmap"];
}

- (IBAction) fetchAlbumArt:(id) sender
{
	// http://webservices.amazon.com/onca/xml?Service=AWSECommerceService&AWSAccessKeyId=18PZ5RH3H0X43PS96MR2&Operation=ItemSearch&SearchIndex=Music&ResponseGroup=Images&Artist=Kid+Rock&Title=Cocky

	NSError		*error;
	NSString	*urlString;
	NSURL		*url;

	urlString	= [NSString stringWithFormat:@"http://webservices.amazon.com/onca/xml?Service=AWSECommerceService&AWSAccessKeyId=18PZ5RH3H0X43PS96MR2&Operation=ItemSearch&SearchIndex=Music&ResponseGroup=Images&Artist=%@&Title=%@", _artist, _title];
	url			= [NSURL URLWithString:[urlString stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
	
	NSXMLDocument *xmlDoc = [[NSXMLDocument alloc] initWithContentsOfURL:url options:(NSXMLNodePreserveWhitespace | NSXMLNodePreserveCDATA) error:&error];
	if(nil == xmlDoc) {
		xmlDoc = [[NSXMLDocument alloc] initWithContentsOfURL:url options:NSXMLDocumentTidyXML error:&error];
	}
	if(nil == xmlDoc) {
		if(error) {
//			[self handleError:error];
		}
		return;
	}

	if(error) {
//		[self handleError:error];
	}
	
//	NSLog(@"xmlDoc = %@", xmlDoc);
	
	NSXMLNode				*node, *childNode, *grandChildNode;
	NSEnumerator			*childrenEnumerator, *grandChildrenEnumerator;
	NSMutableDictionary		*dictionary;
	NSMutableArray			*images;
	
	images	= [NSMutableArray arrayWithCapacity:10];
	node	= [xmlDoc rootElement];
	while((node = [node nextNode])) {
		if([[node name] isEqualToString:@"ImageSet"]) {
			// Iterate through children
			childrenEnumerator = [[node children] objectEnumerator];
			while((childNode = [childrenEnumerator nextObject])) {
				dictionary					= [NSMutableDictionary dictionaryWithCapacity:3];
				grandChildrenEnumerator		= [[childNode children] objectEnumerator];
				
				while((grandChildNode = [grandChildrenEnumerator nextObject])) {
					[dictionary setValue:[grandChildNode stringValue] forKey:[grandChildNode name]];
				}
				
				[images addObject:dictionary];
//				NSLog(@"dictionary = %@", dictionary);
			}
		}
	}
	
	AmazonAlbumArt *art = [[[AmazonAlbumArt alloc] initWithCompactDiscDocument:self] autorelease];
	[art setValue:images forKey:@"images"];
	[art showFreeDBMatches];
	//NSLog(@"images = %@", images);
}

#pragma mark FreeDB Functionality

- (void) clearFreeDBData
{
	unsigned i;
	
	[self setValue:nil forKey:@"title"];
	[self setValue:nil forKey:@"artist"];
	[self setValue:nil forKey:@"year"];
	[self setValue:nil forKey:@"genre"];
	[self setValue:nil forKey:@"comment"];
	[self setValue:nil forKey:@"discNumber"];
	[self setValue:nil forKey:@"discsInSet"];
	[self setValue:[NSNumber numberWithBool:NO] forKey:@"multiArtist"];
	
	for(i = 0; i < [_tracks count]; ++i) {
		[[_tracks objectAtIndex:i] clearFreeDBData];
	}
}

- (IBAction) queryFreeDB:(id)sender
{
	FreeDB				*freeDB				= nil;
	NSArray				*matches			= nil;
	FreeDBMatchSheet	*sheet				= nil;
	
	if(NO == [self queryFreeDBAllowed]) {
		return;
	}

	@try {
		[self setValue:[NSNumber numberWithBool:YES] forKey:@"freeDBQueryInProgress"];
		[self setValue:[NSNumber numberWithBool:NO] forKey:@"freeDBQuerySuccessful"];

		freeDB = [[FreeDB alloc] initWithCompactDiscDocument:self];
		
		matches = [freeDB fetchMatches];
		
		if(0 == [matches count]) {
			@throw [FreeDBException exceptionWithReason:NSLocalizedStringFromTable(@"No matches found for this disc", @"Exceptions", @"") userInfo:nil];
		}
		else if(1 == [matches count]) {
			[self updateDiscFromFreeDB:[matches objectAtIndex:0]];
		}
		else {
			sheet = [[[FreeDBMatchSheet alloc] initWithCompactDiscDocument:self] autorelease];
			[sheet setValue:matches forKey:@"matches"];
			[sheet showFreeDBMatches];
		}
	}
	
	@catch(NSException *exception) {
		[self setValue:[NSNumber numberWithBool:NO] forKey:@"freeDBQueryInProgress"];
		[self displayException:exception];
	}
	
	@finally {
		[freeDB release];
	}
}

- (IBAction) submitToFreeDB:(id) sender
{
	FreeDB				*freeDB				= nil;
	
	if(NO == [self submitToFreeDBAllowed]) {
		return;
	}

	@try {
		freeDB = [[FreeDB alloc] initWithCompactDiscDocument:self];		
		[freeDB submitDisc];
	}
	
	@catch(NSException *exception) {
		[self displayException:exception];
	}
	
	@finally {
		[freeDB release];
	}
}

- (void) updateDiscFromFreeDB:(NSDictionary *)info
{
	FreeDB *freeDB;
	
	@try {
		freeDB = [[FreeDB alloc] initWithCompactDiscDocument:self];
	
		[self updateChangeCount:NSChangeReadOtherContents];
		[self clearFreeDBData];
		
		[freeDB updateDisc:info];
		
		[self setValue:[NSNumber numberWithBool:YES] forKey:@"freeDBQuerySuccessful"];
	}
	
	@catch(NSException *exception) {
		[self displayException:exception];
	}
	
	@finally {
		[self setValue:[NSNumber numberWithBool:NO] forKey:@"freeDBQueryInProgress"];
		[freeDB release];		
	}
	
}

#pragma mark Miscellaneous

- (IBAction) toggleTrackInformation:(id) sender
{
	[_trackDrawer toggle:sender];
}

- (IBAction) toggleAlbumArt:(id) sender
{
	[_artDrawer toggle:sender];
}

- (NSString *)		length			{ return [NSString stringWithFormat:@"%u:%.02u", [_disc length] / 60, [_disc length] % 60]; }

- (NSArray *) genres
{
	return [Genres sharedGenres];
}

#pragma mark Save/Restore

- (NSDictionary *) getDictionary
{
	unsigned				i;
	NSMutableDictionary		*result					= [[NSMutableDictionary alloc] init];
	NSMutableArray			*tracks					= [NSMutableArray arrayWithCapacity:[_tracks count]];
	NSData					*data					= nil;
	
	[result setValue:_title forKey:@"title"];
	[result setValue:_artist forKey:@"artist"];
	[result setValue:_year forKey:@"year"];
	[result setValue:_genre forKey:@"genre"];
	[result setValue:_composer forKey:@"composer"];
	[result setValue:_comment forKey:@"comment"];
	[result setValue:_discNumber forKey:@"discNumber"];
	[result setValue:_discsInSet forKey:@"discsInSet"];
	[result setValue:_multiArtist forKey:@"multiArtist"];				
	[result setValue:_MCN forKey:@"MCN"];
	[result setValue:[NSNumber numberWithInt:[self discID]] forKey:@"discID"];

	data = [_albumArtBitmap representationUsingType:NSPNGFileType properties:nil]; 
	[result setValue:data forKey:@"albumArt"];
	
	for(i = 0; i < [_tracks count]; ++i) {
		[tracks addObject:[[_tracks objectAtIndex:i] getDictionary]];
	}
	
	[result setValue:tracks forKey:@"tracks"];
	
	return [[result retain] autorelease];
}

- (void) setPropertiesFromDictionary:(NSDictionary *) properties
{
	unsigned				i;
	NSArray					*tracks			= [properties valueForKey:@"tracks"];
	NSImage					*image			= nil;
	
	if([self discInDrive] && [tracks count] != [_tracks count]) {
		@throw [NSException exceptionWithName:@"NSInternalInconsistencyException" reason:@"Track count mismatch" userInfo:nil];
	}
	else if(0 == [_tracks count]) {
		[self willChangeValueForKey:@"tracks"];
		for(i = 0; i < [tracks count]; ++i) {
			Track *track = [[Track alloc] init];
			[track setValue:self forKey:@"disc"];
			[_tracks addObject:[[track retain] autorelease]];
		}
		[self didChangeValueForKey:@"tracks"];
	}
	
	for(i = 0; i < [tracks count]; ++i) {
		[[_tracks objectAtIndex:i] setPropertiesFromDictionary:[tracks objectAtIndex:i]];
	}
	
	[self setValue:[properties valueForKey:@"title"] forKey:@"title"];
	[self setValue:[properties valueForKey:@"artist"] forKey:@"artist"];
	[self setValue:[properties valueForKey:@"year"] forKey:@"year"];
	[self setValue:[properties valueForKey:@"genre"] forKey:@"genre"];
	[self setValue:[properties valueForKey:@"composer"] forKey:@"composer"];
	[self setValue:[properties valueForKey:@"comment"] forKey:@"comment"];
	[self setValue:[properties valueForKey:@"discNumber"] forKey:@"discNumber"];
	[self setValue:[properties valueForKey:@"discsInSet"] forKey:@"discsInSet"];
	[self setValue:[properties valueForKey:@"multiArtist"] forKey:@"multiArtist"];	
	[self setValue:[properties valueForKey:@"MCN"] forKey:@"MCN"];
	[self setValue:[properties valueForKey:@"discID"] forKey:@"discID"];
	
	// Convert PNG data to an NSImage
	image = [[NSImage alloc] initWithData:[properties valueForKey:@"albumArt"]];
	[self setValue:(nil != image ? [image autorelease] : nil) forKey:@"albumArt"];
	[self updateAlbumArtImageRep];
}

@end
