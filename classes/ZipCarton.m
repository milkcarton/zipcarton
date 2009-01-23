/*
 Copyright (c) 2008-2009 Simon Schoeters
 
 Permission is hereby granted, free of charge, to any person
 obtaining a copy of this software and associated documentation
 files (the "Software"), to deal in the Software without
 restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the
 Software is furnished to do so, subject to the following
 conditions:
 
 The above copyright notice and this permission notice shall be
 included in all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 OTHER DEALINGS IN THE SOFTWARE.
 
 Created by Simon Schoeters on 2008.07.03.
*/

#import "ZipCarton.h"

#define MCLocalizedString(key) \
	[[NSBundle bundleForClass:[self class]] localizedStringForKey:(key) value:nil table:@"Localizable"]

@implementation FindPostalCode

// This action should work on addresses, not on phone numbers or other items.
- (NSString *)actionProperty
{
    return kABAddressProperty;
}

// Menu title will look like Find postal code for <city>.
- (NSString *)titleForPerson:(ABPerson *)person identifier:(NSString *)identifier
{
    ABMultiValue* addresses = [person valueForProperty:[self actionProperty]];
    NSDictionary* address = [addresses valueForIdentifier:identifier];
	NSString *city = [address valueForKey:kABAddressCityKey];
	
	// If the city is not given it would return: Find postal code for (null), this is ugly so don't return anything
	if ([city length]) {
		return [NSString stringWithFormat:MCLocalizedString(@"MENU_LABEL"), city];
	} else {
		return NO;
	}
}

// This method is called when the user selects the action.
- (void)performActionForPerson:(ABPerson *)person identifier:(NSString *)identifier
{
	[self wsType];
    ABMultiValue* tmp = [person valueForProperty:[self actionProperty]];
	ABMutableMultiValue *addresses = [tmp mutableCopy];
    NSDictionary* address = [addresses valueForIdentifier:identifier];

	// Find the postal code for this city.
	NSString *countryISO = [self findISOforCountry:[address valueForKey:kABAddressCountryKey]];
	
	// TODO: Do we look for the postal code if the country ISO is not found? Could use some discussion...
	NSString *postalCode = nil;
	if ([countryISO length] || ![address valueForKey:kABAddressCountryKey]) {
		postalCode = [self postalCodeForCity:[address valueForKey:kABAddressCityKey] country:countryISO];
		
		// Ask confirmation if the code in Address Book is not more accurate then the returned result
		// eg. BD16 4UN is Bingley, UK but GeoNames returns BD16, it's stupid to override the users value in this case
		NSString *ABpostalCode = [address valueForKey:kABAddressZIPKey];
		if ([postalCode caseInsensitiveCompare:ABpostalCode] != NSOrderedSame && [ABpostalCode hasPrefix:postalCode]) {
			int replace = NSRunAlertPanel(MCLocalizedString(@"SHORTEN_CODE_TITLE"),
										  [NSString stringWithFormat:MCLocalizedString(@"SHORTEN_CODE"), postalCode, ABpostalCode],
										  MCLocalizedString(@"REPLACE"),
										  MCLocalizedString(@"CANCEL"),
										  NULL);
			if (replace != NSAlertDefaultReturn) {
				postalCode = @"";
			}
		}
	}

	if ([postalCode length]) {
		// Recreate the kABAddressProperty with all the current values or the address will only be the postal code, that's not what we want.
		NSMutableDictionary *addr = [NSMutableDictionary dictionary];
		if ([address valueForKey:kABAddressStreetKey]) {
			[addr setObject:[address valueForKey:kABAddressStreetKey] forKey:kABAddressStreetKey];
		}
		if ([address valueForKey:kABAddressCityKey]) {
			[addr setObject:[address valueForKey:kABAddressCityKey] forKey:kABAddressCityKey];
		}
		if ([address valueForKey:kABAddressStateKey]) {
			[addr setObject:[address valueForKey:kABAddressStateKey] forKey:kABAddressStateKey];
		}
		[addr setObject:postalCode forKey:kABAddressZIPKey];
		if ([address valueForKey:kABAddressCountryKey]) {
			[addr setObject:[address valueForKey:kABAddressCountryKey] forKey:kABAddressCountryKey];
		}
	
		// Set value in record for the kABAddressProperty.
		BOOL replaced = [addresses replaceValueAtIndex:[addresses indexForIdentifier:identifier] withValue:addr];
		if (replaced) {
			[person setValue:addresses forProperty:kABAddressProperty];
		}
	
		// Add record to the Address Book and save it (Address Book changes it in memory first, not on disk).
		ABAddressBook *ab = [ABAddressBook sharedAddressBook];
		if ([ab addRecord: person]) {
			[ab save];
		}
		[person release];
	} else if(![postalCode length] && ![countryISO length]) {
		NSLog(MCLocalizedString(@"NO_CODE_FOUND"), [address valueForKey:kABAddressCityKey]);
	} else if(![postalCode length] && [countryISO length]) {
		NSLog(MCLocalizedString(@"NO_CODE_FOUND_FOR"), [address valueForKey:kABAddressCityKey], [address valueForKey:kABAddressCountryKey], countryISO);
	}
}

// Disable the action when the city is missing.
- (BOOL)shouldEnableActionForPerson:(ABPerson *)person identifier:(NSString *)identifier
{
	ABMultiValue* addresses = [person valueForProperty:[self actionProperty]];
    NSDictionary* address = [addresses valueForIdentifier:identifier];
	NSString *city = [address valueForKey:kABAddressCityKey];
	
	// Only enable this action when a city value is found.
	if ([city length]) {
		return YES;
	} else {
		return NO;
	}
}

- (NSString *)postalCodeForCity:(NSString *)city country:(NSString *)country
{
	NSString *urlString = [NSString stringWithFormat:@"http://%@.geonames.org/postalCodeSearch?placename=%@&country=%@&style=short", wsType, city, country];
	urlString = [urlString stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
	NSURL *url = [NSURL URLWithString:urlString];
	
	// TODO: Timeout when service is unavailable

	// Initialize our document with the XML data in our URL	
	NSXMLDocument *xmlDoc = [[NSXMLDocument alloc] initWithContentsOfURL:url options:(NSStringEncoding)nil error:nil];

	// Get a reference to the root node and check if there are any results found
	NSXMLElement *rootNode = [xmlDoc rootElement];
	int totalResultsNode = [[[[rootNode elementsForName:@"totalResultsCount"] objectAtIndex:0] objectValue] intValue];
	
	NSString *code = @"";
	if(rootNode != nil && totalResultsNode != 0) {
		NSArray *resultCodes = [rootNode nodesForXPath:@"/geonames/code/postalcode" error:nil];
		
		if (totalResultsNode == 1) {
			code = [[resultCodes objectAtIndex:0] objectValue];
		// More results found so try to limit the results by leaving out placenames that don't match our city exactly
		} else {
			NSArray *resultNames = [rootNode nodesForXPath:@"/geonames/code/name" error:nil];
			NSArray *filteredNames = [self filterList:resultNames filter:city];
			if ([filteredNames count] == 1) {
				NSXMLElement *parent = [[filteredNames objectAtIndex:0] parent];
				code = [[[parent elementsForName:@"postalcode"] objectAtIndex:0] objectValue]; 
			} else {
				// Too many results found, ask the user if he wants to open GeoNames
				code = @"";	
				int pressed = NSRunAlertPanel(MCLocalizedString(@"TOO_MANY_RESULTS_TITLE"),
											  [NSString stringWithFormat:MCLocalizedString(@"TOO_MANY_RESULTS_BODY"), city, totalResultsNode],
											  MCLocalizedString(@"OPEN"),
											  MCLocalizedString(@"CANCEL"),
											  NULL);
				// Open the GeoNames website so that the user can solve it, we failed
				if (pressed == NSAlertDefaultReturn) {
					NSString *geonamesURL = [NSString stringWithFormat:@"http://www.geonames.org/postalcode-search.html?q=%@&country=%@", city, country];
					geonamesURL = [geonamesURL stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
					[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:geonamesURL]];
				}
			}			
		}
	}
	
	[xmlDoc release];
	return code;
}

- (NSString *)findISOforCountry:(NSString *)country
{
	if([country length]) {
		NSString *urlString = [NSString stringWithFormat:@"http://%@.geonames.org/search?q=%@&featureCode=PCLI&maxRows=1", wsType, country];
		urlString = [urlString stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
		NSURL *url = [NSURL URLWithString:urlString];

		// Initialize our document with the XML data in our URL	
		NSXMLDocument *xmlDoc = [[NSXMLDocument alloc] initWithContentsOfURL:url options:(NSStringEncoding)nil error:nil];
		
		// Get a reference to the root node and check if there are any results found
		NSXMLElement *rootNode = [xmlDoc rootElement];
		int totalResultsNode = [[[[rootNode elementsForName:@"totalResultsCount"] objectAtIndex:0] objectValue] intValue];

		NSString *code = @"";
		if(rootNode != nil && totalResultsNode != 0) {
			NSArray *resultNodes = [rootNode nodesForXPath:@"/geonames/geoname/countryCode" error:nil];
			code = [[resultNodes objectAtIndex:0] objectValue];
		} else {
			NSLog(MCLocalizedString(@"NO_ISO_FOR"), country);
		}
 
		[xmlDoc release];
		return code;
	}

	NSLog(MCLocalizedString(@"NO_COUNTRY"));
	return @"";
}

- (NSArray *)filterList:(NSArray *)unfiltered filter:(NSString *)filter
{
	// First filter all non exact matches (San Francisco is not San Francisco - Cupertino)
	NSMutableArray *tmp = [[NSMutableArray alloc] init];
	int i;
	for (i=0; i<[unfiltered count]; i++) {
		NSString *name = [[unfiltered objectAtIndex:i] objectValue];
		if ([name caseInsensitiveCompare:filter] == NSOrderedSame) {
			[tmp addObject:[unfiltered objectAtIndex:i]];
		}
	}
	
	/* TODO
	// Next, check if the remaining postcodes are not all the same, only keep unique ones
	NSMutableArray *filtered = [[NSMutableArray alloc] init];
	int j;
	for (j=0; j<[tmp count]; j++) {
		NSXMLElement *parent = [[tmp objectAtIndex:j] parent];
		NSString *code = [[[parent elementsForName:@"postalcode"] objectAtIndex:0] objectValue]; // Get the postal code for the selected node
	}
	[tmp release];
	 */

	return [tmp copy];
}

- (void)wsType
{
	wsType = @"ws";
	NSString *urlString = @"http://ws.geonames.org/search";
	NSURL *url = [NSURL URLWithString:urlString];
	NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
	NSData *urlData = [NSURLConnection sendSynchronousRequest:request returningResponse:nil error:nil];

	if(urlData == nil) {
		NSLog(@"Fallback to ws5.geonames.org");
		wsType = @"ws5";
		return;
	}
	
	NSXMLDocument *xmlDoc = [[NSXMLDocument alloc] initWithData:urlData options:(NSInteger)nil error:nil];
	NSXMLElement *rootNode = [xmlDoc rootElement];

	if (rootNode == nil) {
		NSLog(@"Fallback to ws5.geonames.org");
		wsType = @"ws5";
	} else {
		NSLog(@"Normal service URL ws.geonames.org works");
	}
}

@end