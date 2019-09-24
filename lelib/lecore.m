//
//  lecore.c
//  lelib
//
//  Created by Petr on 06.01.14.
//  Copyright (c) 2014 Logentries. All rights reserved.
//



#include "LEBackgroundThread.h"
#include "LogFiles.h"

#include "lelib.h"

struct le_context *exception_handler_context;
NSUncaughtExceptionHandler * saved_le_exception_handler;

static bool le_debug_logs = false;

void LE_DEBUG(NSString *format, ...) {
#if DEBUG
    if (le_debug_logs) {
        va_list args;
        va_start(args, format);
        NSLogv(format, args);
        va_end(args);
    }
#endif
}

/*
 Sets ctx.logfile_descriptor to -1 when fails, this means that all subsequent write attempts will fail
 return 0 on success
 */
static int open_file(struct le_context *ctx, const char* path)
{
    mode_t mode = 0664;
    
    ctx->logfile_size = 0;
    
    ctx->logfile_descriptor = open(path, O_CREAT | O_WRONLY, mode);
    if (ctx->logfile_descriptor < 0) {
        LE_DEBUG(@"Unable to open log file.");
        return 1;
    }
    
    ctx->logfile_size = lseek(ctx->logfile_descriptor, 0, SEEK_END);
    if (ctx->logfile_size < 0) {
        LE_DEBUG(@"Unable to seek at end of file.");
        return 1;
    }
    
    LE_DEBUG(@"log file %s opened", path);
    return 0;
}

void le_poke(struct le_context *ctx)
{
    if (!ctx->backgroundThread) {
        ctx->backgroundThread = [LEBackgroundThread new];
        ctx->backgroundThread.token = [NSString stringWithUTF8String:ctx->token];
        ctx->backgroundThread.name = @"Logentries";
                
        NSCondition* initialized = [NSCondition new];
        ctx->backgroundThread.initialized = initialized;
        
        [initialized lock];
        [ctx->backgroundThread start];
        [initialized wait];
        [initialized unlock];
    }
    
    [ctx->backgroundThread performSelector:@selector(poke:) onThread:ctx->backgroundThread withObject:@(ctx->file_order_number) waitUntilDone:NO modes:@[NSDefaultRunLoopMode]];
}

static void le_exception_handler(NSException *exception)
{
    NSString* message = [NSString stringWithFormat:@"Exception name=%@, reason=%@, userInfo=%@ addresses=%@ symbols=%@", [exception name], [exception reason], [exception userInfo], [exception callStackReturnAddresses], [exception callStackSymbols]];
    LE_DEBUG(@"%@", message);
    message = [message stringByReplacingOccurrencesOfString:@"\n" withString:@"\u2028"];
    le_log(exception_handler_context, [message cStringUsingEncoding:NSUTF8StringEncoding]);
    
    if (saved_le_exception_handler) {
        saved_le_exception_handler(exception);
    }
}

int le_init(struct le_context *ctx)
{
    // pesimistic strategy
    int r = 1;

    ctx->le_write_queue = dispatch_queue_create("com.logentries.write", NULL);

    NSString* token = [NSString stringWithUTF8String:ctx->token];
    LogFiles* logFiles = [[LogFiles alloc] initWithToken:token];
    if (!logFiles) {
        LE_DEBUG(@"Error initializing logs directory.");
        return r;
    }

    [logFiles consolidate];

    LogFile* file = [logFiles fileToWrite];
    ctx->file_order_number = (int)file.orderNumber;
    NSString* logFilePath = [file logPath];

    const char* path = [logFilePath cStringUsingEncoding:NSASCIIStringEncoding];
    if (!path) {
        LE_DEBUG(@"Invalid logfile path.");
        return r;
    }

    if (open_file(ctx, path)) {
        return r;
    };

    r = 0;

    le_set_token(ctx, ctx->token);
    return r;
}


void le_handle_crashes(struct le_context *ctx)
{
    exception_handler_context = ctx;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        saved_le_exception_handler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&le_exception_handler);
    });
}

/*
 Takes used_length characters from buffer, appends a space and token and writes in into log. Handles log rotation.
 */
static void write_buffer(struct le_context *ctx, size_t used_length)
{
    if ((size_t)ctx->logfile_size + used_length > MAXIMUM_LOGFILE_SIZE) {
        
        close(ctx->logfile_descriptor);
        ctx->file_order_number++;
        NSString* directory = [LogFiles logsDirectoryWithToken: [NSString stringWithCString:ctx->token encoding:NSASCIIStringEncoding]];
        LogFile* logFile = [[LogFile alloc] initWithNumber:ctx->file_order_number withDirectory:directory];
        NSString* p = [logFile logPath];
        const char* path = [p cStringUsingEncoding:NSASCIIStringEncoding];
        
        open_file(ctx, path);
    }
    
    ssize_t written = write(ctx->logfile_descriptor, ctx->buffer, (size_t)used_length);
    if (written < (ssize_t)used_length) {
        LE_DEBUG(@"Could not write to log, no space left?");
        return;
    }
    
    ctx->logfile_size += written;
}

void le_log(struct le_context *ctx, const char* message)
{
    dispatch_sync(ctx->le_write_queue, ^{
        
        size_t token_length;
        
        if(!is_valid_token(ctx->token,&token_length))
            return ;
        

        size_t max_length = MAXIMUM_LOGENTRY_SIZE - token_length - 2; // minus token length, space separator and lf
        
        size_t length = strlen(message);
        if (max_length < length) {
            LE_DEBUG(@"Too large message, it will be truncated");
            length = max_length;
        }

        memcpy(ctx->buffer, ctx->token, token_length);
        ctx->buffer[token_length] = ' ';
        memcpy(ctx->buffer + token_length + 1, message, length);
        
        size_t total_length = token_length + 1 + length;
        ctx->buffer[total_length++] = '\n';
        
        write_buffer(ctx, total_length);
        le_poke(ctx);
    });
    
}

void le_write_string(struct le_context *ctx, NSString* string)
{
    dispatch_sync(ctx->le_write_queue, ^{
        
        size_t token_length;
        if(!is_valid_token(ctx->token,&token_length))
            return ;
        
        NSUInteger maxLength = MAXIMUM_LOGENTRY_SIZE - token_length - 2; // minus token length, space separator and \n
        if ([string length] > maxLength) {
            LE_DEBUG(@"Too large message, it will be truncated");
        }
        
        memcpy(ctx->buffer, ctx->token, token_length);
        ctx->buffer[token_length] = ' ';

        NSRange range = {.location = 0, .length = [string length]};
        
        NSUInteger usedLength = 0;
        BOOL r = [string getBytes:(ctx->buffer + token_length + 1) maxLength:maxLength usedLength:&usedLength encoding:NSUTF8StringEncoding options:NSStringEncodingConversionAllowLossy range:range remainingRange:NULL];
        
        if (!r) {
            LE_DEBUG(@"Error converting message characters.");
            return;
        }
        
        NSUInteger totalLength = token_length + 1 + usedLength;
        ctx->buffer[totalLength++] = '\n';
        write_buffer(ctx, (size_t)totalLength);
        le_poke(ctx);
    });
}

void le_set_token(struct le_context *ctx, const char* token)
{
    size_t length ;
    if(!is_valid_token(token,&length))
        return;
    
    char* local_buffer = malloc(length + 1);
    if (!local_buffer) {
        LE_DEBUG(@"Can't allocate token buffer.");
        return ;
    }
    strlcpy(local_buffer, token, length + 1);
    
    dispatch_sync(ctx->le_write_queue, ^{
        ctx->token = local_buffer;
    });
}

bool is_valid_token(const char * token,size_t* token_length)
{
    size_t length = 0;
    
    if (token == NULL) {
        NSLog(@"nil token\n");
        LE_DEBUG(@"nil token");
        return false;
    }
    
    length = strlen(token);
    
    if(token_length != NULL)
        *token_length = length;
    
    if (length < TOKEN_LENGTH) {
        LE_DEBUG(@"Invalid token length, it will not be used.");
        return false;
    }
    
    return true;
}

void le_set_debug_logs(bool debug) {
    le_debug_logs = debug;
}
