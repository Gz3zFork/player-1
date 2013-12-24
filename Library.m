//
//  Library.m
//  Pinna
//
//  Created by Peter MacWhinnie on 9/24/10.
//  Copyright 2010 Roundabout Software, LLC. All rights reserved.
//

#import "Library.h"

#import "ExfmSession.h"

#import "Song.h"
#import "Artist.h"
#import "Album.h"

#import "Playlist.h"
#import "ArtworkCache.h"

NSString *const kLibraryLocationBookmarkDataUserDefaultsKey = @"Library_locationBookmarkData";

NSString *const kArtistPlaceholderName = @"Unknown Artist";
NSString *const kAlbumPlaceholderName = @"Unnamed Album";
NSString *const kCompilationPlaceholderName = @"Various Artists";

NSArray *kSongSortDescriptors = nil;
NSArray *kArtistSortDescriptors = nil;
NSArray *kAlbumSortDescriptors = nil;

NSString *const LibraryErrorDidOccurNotification = @"LibraryErrorDidOccurNotification";
NSString *const LibraryDidLoadNotification = @"LibraryDidLoadNotification";

Song *BestMatchForSongInArray(Song *song, NSArray *songArray)
{
	if(!songArray || !song)
		return nil;
	
	NSUInteger matchIndex = [songArray indexOfObjectPassingTest:^BOOL(Song *possibleSong, NSUInteger idx, BOOL *stop) {
		return (possibleSong.songSource != kSongSourceExfm &&
				([possibleSong.uniqueIdentifier isEqualToString:song.uniqueIdentifier] ||
				 ([possibleSong.name caseInsensitiveCompare:song.name] == NSEqualToComparison &&
				  [possibleSong.artist caseInsensitiveCompare:song.artist] == NSEqualToComparison)));
	}];
	
	if(matchIndex == NSNotFound)
		return nil;
	
	return [songArray objectAtIndex:matchIndex];
}

#pragma mark -

NSString *const kCompilationArtistMarker = @"\b≪Autogenerated Compilation≫\b";

@interface Library () //Interface Continuation

- (void)updateLibraryCaches;

///Whether or not the library has loaded.
@property BOOL hasLoaded;

@end

#pragma mark -

NSString *const LibraryDidUpdateNotification = @"LibraryDidUpdateNotification";

@implementation Library

+ (void)load
{
	if(!kSongSortDescriptors)
	{
		@autoreleasepool {
			NSComparator mildlyIntelligentComparator = ^NSComparisonResult(NSString *left, NSString *right) {
				return [RKSanitizeStringForSorting(left) localizedStandardCompare:RKSanitizeStringForSorting(right)];
			};
			
			kArtistSortDescriptors =
			kAlbumSortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES comparator:mildlyIntelligentComparator]];
			
			kSongSortDescriptors = @[
                [NSSortDescriptor sortDescriptorWithKey:@"artist" ascending:YES comparator:mildlyIntelligentComparator],
                [NSSortDescriptor sortDescriptorWithKey:@"album" ascending:YES comparator:mildlyIntelligentComparator],
                [NSSortDescriptor sortDescriptorWithKey:@"discNumber" ascending:YES],
                [NSSortDescriptor sortDescriptorWithKey:@"trackNumber" ascending:YES],
                [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES comparator:mildlyIntelligentComparator],
            ];
		}
	}
}

+ (Library *)sharedLibrary
{
	static Library *sharedLibrary = nil;
	static dispatch_once_t creationPredicate = 0;
	dispatch_once(&creationPredicate, ^{
		sharedLibrary = [Library new];
	});
	return sharedLibrary;
}

#pragma mark - Internal Jiggery

- (void)dealloc
{
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (id)init
{
	if((self = [super init]))
	{
		mExfmSession = [ExfmSession defaultSession];
		mExFMSongsBeingOperatedOn = [NSMutableSet new];
		mExFMSongsWaitingForNotification = [NSMutableSet new];
		
		mExternalAlternateSongSourceIdentifiers = [NSMutableDictionary new];
		
		mCachedSongs = [NSArray new];
		
		mCachedPlaylists = [NSArray new];
		mCacheUpdateQueue = dispatch_queue_create("com.roundabout.pinna.Library.mPlaylistCacheUpdateQueue", NULL);
		dispatch_async(mCacheUpdateQueue, ^{ [self updateLibraryCaches]; });
		
		mCachedArtists = [NSDictionary new];
		
		[NSTimer scheduledTimerWithTimeInterval:5.0 
										 target:self 
									   selector:@selector(maybeUpdateLibraryCaches:) 
									   userInfo:nil 
										repeats:YES];
		
		//From <http://www.mail-archive.com/cocoa-dev@lists.apple.com/msg40523.html>
		[[NSDistributedNotificationCenter defaultCenter] addObserver:self
															selector:@selector(iTunesLibraryChanged:) 
																name:@"com.apple.iTunes.sourceSaved" 
															  object:@"com.apple.iTunes.sources"];
		
		[[NSNotificationCenter defaultCenter] addObserver:self 
												 selector:@selector(sessionDidUpdateLovedSongs:) 
													 name:ExfmSessionUpdatedCachedLovedSongsNotification
												   object:mExfmSession];
	}
	
	return self;
}

#pragma mark - Locating the iTunes Library

#pragma mark • Tools

- (NSDictionary *)contentsOfLibraryAtURL:(NSURL *)url error:(NSError **)error
{
	NSData *libraryContents = [NSData dataWithContentsOfURL:url options:0 error:error];
	if(!libraryContents)
		return nil;
	
	NSDictionary *library = [NSPropertyListSerialization propertyListWithData:libraryContents 
																	  options:NSPropertyListImmutable 
																	   format:NULL 
																		error:error];
	return library;
}

#pragma mark - • Paths

- (NSURL *)musicFolderLocation
{
	return [[[NSFileManager defaultManager] URLsForDirectory:NSMusicDirectory inDomains:NSUserDomainMask] lastObject];
}

- (void)setITunesFolderLocation:(NSURL *)iTunesFolderLocation
{
    [mCustomITunesFolderWithSecurityScope stopAccessingSecurityScopedResource];
    
    if(iTunesFolderLocation)
    {
        NSError *error = nil;
        NSData *bookmarkData = [iTunesFolderLocation bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope | NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess
                                              includingResourceValuesForKeys:nil
                                                               relativeToURL:nil //app-scoped
                                                                       error:&error];
        
        if(bookmarkData)
        {
            mCustomITunesFolderWithSecurityScope = iTunesFolderLocation;
            RKSetPersistentObject(kLibraryLocationBookmarkDataUserDefaultsKey, bookmarkData);
        }
        else
        {
            mCustomITunesFolderWithSecurityScope = nil;
            RKSetPersistentObject(kLibraryLocationBookmarkDataUserDefaultsKey, bookmarkData);
            
            NSLog(@"*** Warning, could not create bookmark. Error %@", [error localizedDescription]);
        }
    }
    else
    {
        mCustomITunesFolderWithSecurityScope = nil;
        RKSetPersistentObject(kLibraryLocationBookmarkDataUserDefaultsKey, nil);
    }
    
    mCachedLibraryLocation = nil;
    
    //We don't wait for the update pulse to tick, the user
    //changed their library so we need to update things now.
    dispatch_async(mCacheUpdateQueue, ^{ [self updateLibraryCaches]; });
}

- (NSURL *)iTunesFolderLocation
{
    if(RKPersistentValueExists(kLibraryLocationBookmarkDataUserDefaultsKey) && !mCustomITunesFolderWithSecurityScope)
    {
        BOOL isStale = NO;
        NSError *error = nil;
        mCustomITunesFolderWithSecurityScope = [NSURL URLByResolvingBookmarkData:RKGetPersistentObject(kLibraryLocationBookmarkDataUserDefaultsKey)
                                                          options:NSURLBookmarkResolutionWithSecurityScope
                                                    relativeToURL:nil //app-scoped bookmark
                                              bookmarkDataIsStale:&isStale
                                                            error:&error];
        [mCustomITunesFolderWithSecurityScope startAccessingSecurityScopedResource];
    }
    
	return mCustomITunesFolderWithSecurityScope ?: [[self musicFolderLocation] URLByAppendingPathComponent:@"iTunes"];
}

#pragma mark - • Determining the Best library

- (NSArray *)knownLibraries
{
	NSURL *iTunesFolderLocation = [self iTunesFolderLocation];
	if(!iTunesFolderLocation)
		return [NSArray array];
	
    [iTunesFolderLocation startAccessingSecurityScopedResource];
	NSError *error = nil;
	NSArray *musicFolderContents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:iTunesFolderLocation 
																 includingPropertiesForKeys:@[NSURLContentModificationDateKey] 
																					options:NSDirectoryEnumerationSkipsHiddenFiles 
																					  error:&error];
	if(!musicFolderContents)
	{
		NSLog(@"Could not enumerate music folder contents");
		
		return nil;
	}
	
	return RKCollectionFilterToArray(musicFolderContents, ^BOOL(NSURL *libraryLocation) {
		return [[libraryLocation lastPathComponent] isLike:@"*iTunes*.xml"];
	});
}

- (NSURL *)iTunesLibraryLocation
{
	if(mCachedLibraryLocation && [mCachedLibraryLocation checkResourceIsReachableAndReturnError:nil])
	{
		return mCachedLibraryLocation;
	}
	
	NSArray *knownLibraries = [self knownLibraries];
	for (NSURL *libraryLocation in knownLibraries)
	{
		NSDictionary *library = [self contentsOfLibraryAtURL:libraryLocation error:nil];
		if(!library)
		{
			continue;
		}
		
		NSURL *musicFolderLocation = [NSURL URLWithString:[library objectForKey:@"Music Folder"]];
		if([musicFolderLocation checkResourceIsReachableAndReturnError:nil])
		{
			mCachedLibraryLocation = libraryLocation;
			return mCachedLibraryLocation;
		}
	}
	
	return nil;
}

#pragma mark - Parsing the Library

- (NSDictionary *)iTunesLibraryContents
{
	NSURL *iTunesLibraryLocation = [self iTunesLibraryLocation];
	if(iTunesLibraryLocation)
	{
		NSError *error = nil;
		NSDictionary *iTunesLibrary = [self contentsOfLibraryAtURL:iTunesLibraryLocation error:&error];
		if(iTunesLibrary)
			return iTunesLibrary;
		else
			NSLog(@"Could not read iTunes library from location %@. Error: %@", iTunesLibraryLocation, error);
	}
	
	return [NSDictionary dictionary];
}

- (BOOL)shouldOmitITunesTrack:(NSDictionary *)track
{
	return (//Songs can be written back to the library xml partially
			//initialized, we need to be check for that.
			[track objectForKey:@"Location"] == nil ||
			//We ignore any videos that aren't music videos
			([[track objectForKey:@"Has Video"] boolValue] && ![[track objectForKey:@"Music Video"] boolValue]) ||
            //We ignore songs in iTunes Match (for now)
            [[track objectForKey:@"Track Type"] isEqualToString:@"Remote"]);
}

- (BOOL)shouldOmitITunesPlaylist:(NSDictionary *)playlist
{
	//We ignore all of iTunes' special playlists with the exception of purchased music.
	return ([[playlist objectForKey:@"Master"] boolValue] ||
			([playlist objectForKey:@"Distinguished Kind"] &&
			 ![[playlist objectForKey:@"Purchased Music"] boolValue]));
}

#pragma mark -

- (void)addSong:(Song *)song toCachedArtists:(NSMutableDictionary *)cachedArtists andCachedAlbums:(NSMutableArray *)cachedAlbums
{
	NSString *compilationArtistName = song.isCompilation? [song.album stringByAppendingString:kCompilationArtistMarker] : nil;
	
	NSString *artistName = compilationArtistName ?: song.albumArtist;
	if(artistName)
	{
		Artist *songArtist = [cachedArtists objectForKey:artistName];
		if(!songArtist)
		{
			songArtist = [[Artist alloc] initWithName:artistName isCompilationContainer:song.isCompilation];
			[cachedArtists setObject:songArtist forKey:artistName];
		}
		
		NSString *albumName = song.album;
		if(albumName)
		{
			Album *songAlbum = [songArtist albumWithName:albumName];
			if(!songAlbum)
			{
				songAlbum = [[Album alloc] initWithName:albumName insertIntoArtist:songArtist isCompilation:song.isCompilation];
				[cachedAlbums addObject:songAlbum];
			}
			
			[[songAlbum mutableArrayValueForKey:@"songs"] addObject:song];
		}
	}
}

#pragma mark -

- (void)updateLibraryCaches
{
	NSDictionary *iTunesLibrary = [self iTunesLibraryContents];
	
	NSMutableDictionary *cachedArtists = [NSMutableDictionary dictionary];
	NSMutableArray *cachedAlbums = [NSMutableArray array];
	
	//Begin iTunes
	
    NSMutableDictionary *iTunesSongMap = [NSMutableDictionary dictionary];
    [[iTunesLibrary objectForKey:@"Tracks"] enumerateKeysAndObjectsUsingBlock:^(id identifier, NSDictionary *track, BOOL *stop) {
        if([self shouldOmitITunesTrack:track])
            return;
        
        Song *song = [[Song alloc] initWithTrackDictionary:track source:kSongSourceITunes];
		if(!song)
			return;
		
		[self addSong:song toCachedArtists:cachedArtists andCachedAlbums:cachedAlbums];
        
        [iTunesSongMap setObject:song forKey:identifier];
    }];
	
	NSArray *iTunesPlaylists = [iTunesLibrary objectForKey:@"Playlists"];
	NSArray *cachedPlaylists = RKCollectionMapToArray(iTunesPlaylists, ^id(NSDictionary *playlist) {
		if([self shouldOmitITunesPlaylist:playlist])
			return nil;
		
		NSArray *iTunesPlaylistTracks = [playlist objectForKey:@"Playlist Items"];
		
		//We ignore empty playlists.
		if([iTunesPlaylistTracks count] == 0)
			return nil;
		
		NSArray *playlistSongs = RKCollectionMapToArray(iTunesPlaylistTracks, ^id(NSDictionary *track) {
			return [iTunesSongMap objectForKey:[[track objectForKey:@"Track ID"] stringValue]];
		});
		
		PlaylistType playlistType = [[playlist objectForKey:@"Purchased Music"] boolValue]? kPlaylistTypePurchasedMusic : kPlaylistTypeDefault;
		return [[Playlist alloc] initWithName:[playlist objectForKey:@"Name"]
                                        songs:playlistSongs
                                 playlistType:playlistType];
	});
	
	//End iTunes
	
	
	//Begin Ex.fm
	
	NSMutableDictionary *alternateSongSourceIdentifiers = [NSMutableDictionary dictionary];
	
	NSArray *iTunesSongs = [iTunesSongMap allValues];
	NSArray *lovedExFMSongs = RKCollectionMapToArray(mExfmSession.cachedLovedSongs, ^id(NSDictionary *track) {
		Song *song = [[Song alloc] initWithTrackDictionary:track source:kSongSourceExfm];
		if(!song)
			return nil;
		
		
		Song *possibleLocalEquivalentSong = BestMatchForSongInArray(song, iTunesSongs);
		if(possibleLocalEquivalentSong)
		{
			if(possibleLocalEquivalentSong.sourceIdentifier && song.sourceIdentifier)
				[alternateSongSourceIdentifiers setObject:song.sourceIdentifier forKey:possibleLocalEquivalentSong.sourceIdentifier];
			
			return possibleLocalEquivalentSong;
		}
		
		[self addSong:song toCachedArtists:cachedArtists andCachedAlbums:cachedAlbums];
		
		return song;
	});
	
	if([lovedExFMSongs count] > 0)
	{
		Playlist *lovedPlaylist = [[Playlist alloc] initWithName:@"Loved"
                                                           songs:lovedExFMSongs
                                                    playlistType:kPlaylistTypeLovedSongs];
		
		cachedPlaylists = [@[lovedPlaylist] arrayByAddingObjectsFromArray:cachedPlaylists];
	}
	
	//End Ex.fm
    
	[[ArtworkCache sharedArtworkCache] cacheArtworkForAlbums:cachedAlbums completionHandler:^{
		[self willChangeValueForKey:@"albums"];
		[self didChangeValueForKey:@"albums"];
	}];
	
	//We have to filter out the songs from ex.fm
	//that we subbed out for local songs.
	NSArray *filteredExFMSongs = RKCollectionFilterToArray(lovedExFMSongs, ^BOOL(Song *song) {
		return song.songSource == kSongSourceExfm;
	});
	
	NSArray *allSongs = [iTunesSongs arrayByAddingObjectsFromArray:filteredExFMSongs];
	NSArray *cachedSongs = [allSongs sortedArrayUsingDescriptors:kSongSortDescriptors];
	dispatch_async(dispatch_get_main_queue(), ^{
		@synchronized(self)
		{
			[self willChangeValueForKey:@"playlists"];
			mCachedPlaylists = cachedPlaylists;
			[self didChangeValueForKey:@"playlists"];
			
			[self willChangeValueForKey:@"songs"];
			mCachedSongs = cachedSongs;
			[self didChangeValueForKey:@"songs"];
			
			[self willChangeValueForKey:@"artists"];
			mCachedArtists = cachedArtists;
			[self didChangeValueForKey:@"artists"];
			
			[self willChangeValueForKey:@"alternateSongSourceIdentifiers"];
			mAlternateSongSourceIdentifiers = alternateSongSourceIdentifiers;
			[self didChangeValueForKey:@"alternateSongSourceIdentifiers"];
		}
		
		@synchronized(mExFMSongsBeingOperatedOn)
		{
			for (Song *song in mExFMSongsWaitingForNotification)
				[mExFMSongsBeingOperatedOn removeObject:song];
			
			[mExFMSongsWaitingForNotification removeAllObjects];
		}
		
		[[NSNotificationCenter defaultCenter] postNotificationName:LibraryDidUpdateNotification object:self];
        
        if(!self.hasLoaded)
        {
            [[NSNotificationCenter defaultCenter] postNotificationName:LibraryDidLoadNotification object:self];
            self.hasLoaded = YES;
        }
	});
}

#pragma mark - • Responding To Changes

- (void)maybeUpdateLibraryCaches:(NSTimer *)timer
{
	if(mCacheIsInvalid)
	{
		dispatch_async(mCacheUpdateQueue, ^{ [self updateLibraryCaches]; });
		mCacheIsInvalid = NO;
	}
}

- (void)iTunesLibraryChanged:(NSNotification *)notification
{
	mCacheIsInvalid = YES;
}

#pragma mark -

- (void)sessionDidUpdateLovedSongs:(NSNotification *)notification
{
	//We don't wait for the next update pulse tick, this
	//notification comes directly from another part of Pinna.
	dispatch_async(mCacheUpdateQueue, ^{ [self updateLibraryCaches]; });
}

#pragma mark - Ex.fm

- (NSString *)exFMIdentifierForSong:(Song *)song
{
	if(song.songSource == kSongSourceExfm)
		return song.sourceIdentifier;
	
	return [self alternateSourceIdentifierForSong:song];
}

- (BOOL)isSongBeingLovedOrUnloved:(Song *)song
{
	@synchronized(mExFMSongsBeingOperatedOn)
	{
		return [mExFMSongsBeingOperatedOn containsObject:song];
	}
}

- (BOOL)isSongLovable:(Song *)song
{
	if(!mExfmSession.isAuthorized)
		return NO;
	
	if(song.songSource == kSongSourceExfm)
		return YES;
	
	if([self alternateSourceIdentifierForSong:song])
		return YES;
	
	return NO;
}

- (BOOL)isSongLoved:(Song *)song
{
	if(song.songSource == kSongSourceExfm)
		return [self.songs containsObject:song];
	
	return ([self alternateSourceIdentifierForSong:song] != nil);
}

#pragma mark -

- (RKPromise *)loveExFMSong:(Song *)song
{
	NSParameterAssert(song);
	NSString *identifier = [self exFMIdentifierForSong:song];
	NSAssert(identifier != nil, @"Non-Ex.fm song %@ passed", song);
	
	@synchronized(mExFMSongsBeingOperatedOn)
	{
		if([mExFMSongsBeingOperatedOn containsObject:song])
			return nil;
		
		[mExFMSongsWaitingForNotification addObject:song];
		[mExFMSongsBeingOperatedOn addObject:song];
	}
	
    RKURLRequestPromise *loveSongPromise = RK_CAST(RKURLRequestPromise, [mExfmSession loveSongWithID:identifier]);
    loveSongPromise.postProcessor = RKPostProcessorBlockChain(loveSongPromise.postProcessor, ^RKPossibility *(RKPossibility *maybeData, RKURLRequestPromise *request) {
        if(maybeData.state == kRKPossibilityStateError)
        {
            @synchronized(mExFMSongsBeingOperatedOn)
            {
                [mExFMSongsWaitingForNotification removeObject:song];
                [mExFMSongsBeingOperatedOn removeObject:song];
            }
        }
        return maybeData;
    });
	return loveSongPromise;
}

- (RKPromise *)unloveExFMSong:(Song *)song
{
	NSParameterAssert(song);
	NSString *identifier = [self exFMIdentifierForSong:song];
	NSAssert(identifier != nil, @"Non-Ex.fm song %@ passed", song);
	
	@synchronized(mExFMSongsBeingOperatedOn)
	{
		if([mExFMSongsBeingOperatedOn containsObject:song])
			return nil;
		
		[mExFMSongsWaitingForNotification addObject:song];
		[mExFMSongsBeingOperatedOn addObject:song];
	}
	
    RKURLRequestPromise *unloveSongPromise = RK_CAST(RKURLRequestPromise, [mExfmSession unloveSongWithID:identifier]);
    unloveSongPromise.postProcessor = RKPostProcessorBlockChain(unloveSongPromise.postProcessor, ^RKPossibility *(RKPossibility *maybeData, RKURLRequestPromise *request) {
        if(maybeData.state == kRKPossibilityStateError)
        {
            @synchronized(mExFMSongsBeingOperatedOn)
            {
                [mExFMSongsWaitingForNotification removeObject:song];
                [mExFMSongsBeingOperatedOn removeObject:song];
            }
        }
        return maybeData;
    });
	return unloveSongPromise;
}

#pragma mark - Accessing Music

- (NSArray *)songs
{
	@synchronized(self)
	{
		return mCachedSongs;
	}
}

- (NSArray *)playlists
{
	@synchronized(self)
	{
		return mCachedPlaylists;
	}
}

#pragma mark -

- (NSArray/*of Artist*/ *)artists
{
	@synchronized(self)
	{
		NSPredicate *filterPredicate = [NSPredicate predicateWithFormat:@"NOT name ENDSWITH %@", kCompilationArtistMarker];
		NSArray *allArtists = [[mCachedArtists allValues] sortedArrayUsingDescriptors:kArtistSortDescriptors];
		return [allArtists filteredArrayUsingPredicate:filterPredicate];
	}
}

- (Artist *)artistWithName:(NSString *)name
{
	@synchronized(self)
	{
		return [mCachedArtists objectForKey:name];
	}
}

#pragma mark -

+ (NSSet *)keyPathsForValuesAffectingAlbums
{
	return [NSSet setWithObjects:@"artists", nil];
}

- (NSArray/*of Artist*/ *)albums
{
	@synchronized(self)
	{
		NSArray *allArtists = [[mCachedArtists allValues] sortedArrayUsingDescriptors:kArtistSortDescriptors];
		return [[allArtists valueForKeyPath:@"@unionOfArrays.albums"] sortedArrayUsingDescriptors:kAlbumSortDescriptors];
	}
}

- (Album *)albumWithName:(NSString *)albumName forArtistNamed:(NSString *)artistName
{
	return [[self artistWithName:artistName] albumWithName:albumName];
}

#pragma mark - Alternate Identifiers

- (void)registerExternalAlternateIdentifier:(NSString *)identifier forSong:(Song *)song
{
	@synchronized(self)
	{
		if(identifier)
			[mExternalAlternateSongSourceIdentifiers setObject:identifier forKey:song.sourceIdentifier];
		else
			[mExternalAlternateSongSourceIdentifiers removeObjectForKey:identifier];
	}
}

- (NSString *)alternateSourceIdentifierForSong:(Song *)song
{
	@synchronized(self)
	{
		NSString *alternateSource = [mAlternateSongSourceIdentifiers objectForKey:song.sourceIdentifier];
		if(alternateSource)
			return alternateSource;
		
		alternateSource = [mExternalAlternateSongSourceIdentifiers objectForKey:song.sourceIdentifier];
		if(alternateSource)
			return alternateSource;
		
		return nil;
	}
}

#pragma mark - URLs

- (NSURL *)exFMURLForSong:(Song *)song
{
	NSString *exFMIdentifier = [self exFMIdentifierForSong:song];
	if(exFMIdentifier)
	{
		return [NSURL URLWithString:[NSString stringWithFormat:@"http://ex.fm/song/%@", [exFMIdentifier stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
	}
	
	NSString *query = [NSString stringWithFormat:@"%@ %@", song.artist ?: @"", song.name ?: @""];
	return [NSURL URLWithString:[NSString stringWithFormat:@"http://ex.fm/search/%@", [query stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
}

- (NSURL *)pinnaURLForSong:(Song *)song
{
	NSString *identifier = [self exFMIdentifierForSong:song];
	
	return [NSURL URLWithString:[NSString stringWithFormat:@"pinna-exfm:%@", [identifier stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
}

@end