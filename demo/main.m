//
//  main.m
//  demo
//
//  Created by Petr on 25/11/13.
//  Copyright (c) 2013,2014 Logentries. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "AppDelegate.h"
#import "lecore.h"
#import "LELog.h"

int main(int argc, char * argv[])
{
    @autoreleasepool {
        [LELog sharedInstanceWithToken:@"primary-log"];
        struct le_context ctx = [LELog sharedInstance].ctx;
        le_handle_crashes(&ctx);
        le_log(&ctx, "Hello World");
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
