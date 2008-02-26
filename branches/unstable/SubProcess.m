// SubProcess.m
#import "SubProcess.h"

#include <stdlib.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>
#import "Settings.h"

@implementation SubProcess

static SubProcess* instance = nil;

static void signal_handler(int signal) {
  NSLog(@"Caught signal: %d", signal);
  [instance dealloc];
  instance = nil;
  exit(1);
}

int start_process(const char* path, char* const args[], char* const env[]) {
  struct stat st;
  if (stat(path, &st) != 0) {
    fprintf(stderr, "%s: File does not exist\n", path);
    return -1;
  }
  if ((st.st_mode & S_IXUSR) == 0) {
    fprintf(stderr, "%s: Permission denied\n", path);
    return -1;
  }
  if (execve(path, args, env) == -1) {
    perror("execlp:");
    return -1;
  }
  // execve never returns if successful
  return 0;
}

- (id)initWithDelegate:(id)inputDelegate
{
  if (instance != nil) {
    [NSException raise:@"Unsupported" format:@"Only one SubProcess"];
  }
  self = [super init];
  instance = self;
  fd = 0;
  delegate = inputDelegate;

  // Clean up when ^C is pressed during debugging from a console
  signal(SIGINT, &signal_handler);

  Settings* settings = [Settings sharedInstance];

  struct winsize win;
  win.ws_col = [settings width];
  win.ws_row = [settings height];

  pid_t pid = forkpty(&fd, NULL, NULL, &win);
  if (pid == -1) {
    perror("forkpty");
    [self failure:@"[Failed to fork child process]"];
    exit(0);
  } else if (pid == 0) {
    // First try to use /bin/login since its a little nicer.  Fall back to
    // /bin/sh  if that is available.
    char* login_args[] = { "login", "-f", "root", (char*)0, };
    char* sh_args[] = { "sh", (char*)0, };
    char* env[] = { "TERM=vt100", (char*)0 };
    // NOTE: These should never return if successful
    start_process("/usr/bin/login", login_args, env);
    start_process("/bin/login", login_args, env);
    start_process("/bin/sh", sh_args, env);
    exit(0);
  }
  NSLog(@"Child process id: %d\n", pid);
  [NSThread detachNewThreadSelector:@selector(startIOThread:)
                           toTarget:self
                         withObject:delegate];
  return self;
}

- (void)dealloc
{
  [self close];
  [super dealloc];
}

- (void)close
{
  if (fd != 0) {
    close(fd);
    fd = 0;
  }
}

- (BOOL)isRunning
{
  return (fd != 0) ? YES : NO;
}

- (int)write:(const char*)data length:(unsigned int)length
{
  return write(fd, data, length);
}

- (void)startIOThread:(id)inputDelegate
{
  [[NSAutoreleasePool alloc] init];

  NSString* arg = [[Settings sharedInstance]  arguments];
  if (arg != nil) {
    // A command line argument was passed to the program. What to do? 
    const char* path = [arg cString];
    struct stat st;
    if ((stat(path, &st) == 0) && ((st.st_mode & S_IFDIR) != 0)) {
      write(fd, "cd ", 3);
      write(fd, path, [arg length]);
      write(fd, "\n", 1);
    } else {
      write(fd, path, [arg length]);
      write(fd, "; exit\n", 7);
    }
  }

  const int kBufSize = 1024;
  char buf[kBufSize];
  ssize_t nread;
  while (1) {
    // Blocks until a character is ready
    nread = read(fd, buf, kBufSize);
    // On error, give a tribute to OS X terminal
    if (nread == -1) {
      perror("read");
      [self close];
      [self failure:@"[Process completed]"];
      return;
    } else if (nread == 0) {
      [self close];
      [self failure:@"[Process completed]"];
      return;
    }
    [inputDelegate handleStreamOutput:buf length:nread];
  }
}

- (void)failure:(NSString*)message;
{
  // HACK: Just pretend the message came from the child
  [delegate handleStreamOutput:[message cString] length:[message length]];
}

@end