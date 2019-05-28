//
//  lecore.h
//  lelib
//
//  Created by Petr on 06.01.14.
//  Copyright (c) 2014 Logentries. All rights reserved.
//

#import <Foundation/Foundation.h>

#ifndef lelib_lecore_h
#define lelib_lecore_h

#define TOKEN_LENGTH                    36
#define MAXIMUM_LOGENTRY_SIZE           8192

#define MAXIMUM_FILE_COUNT              3
#define MAXIMUM_LOGFILE_SIZE            (1024 * 1024)

extern void LE_DEBUG(NSString *format, ...);

@class LEBackgroundThread;

/* Pure C API */

struct le_context {
    LEBackgroundThread* backgroundThread;
    dispatch_queue_t le_write_queue;
    char* token;
    int logfile_descriptor;
    off_t logfile_size;
    int file_order_number;
    char buffer[MAXIMUM_LOGENTRY_SIZE];
    void (*saved_le_exception_handler)(NSException *exception);
};

int le_init(struct le_context *ctx);
void le_handle_crashes(struct le_context *ctx);
void le_poke(struct le_context *ctx);
void le_log(struct le_context *ctx, const char* message);
void le_write_string(struct le_context *ctx, NSString* string);
void le_set_token(struct le_context *ctx, const char* token);
bool is_valid_token(const char* token,size_t *token_length);
void le_set_debug_logs(bool verbose);


#endif
