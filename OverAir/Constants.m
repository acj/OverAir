//
//  Constants.m
//  OverAir

#import "Constants.h"

@implementation Constants

const int AirPlayPort         = 7000;
const int AirTunesPort        = 5000;
NSString *const AirPlayServiceType  = @"_airplay._tcp.";
NSString *const AirTunesServiceType = @"_raop._tcp";

//NSString *const UseNetworkInterface = @"en0"; // Ethernet
NSString *const UseNetworkInterface = @"en1"; // Wifi

@end
