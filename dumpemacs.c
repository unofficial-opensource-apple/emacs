#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <strings.h>
#include <errno.h>
#include <err.h>
#include <fcntl.h>
#include <launch.h>
#include <sysexits.h>
#include <sys/types.h>
#include <sys/param.h>
#include <sys/wait.h>
#include <pwd.h>

#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/arch.h>

#include "dumpemacs.h"

void usage(void);
int dumpemacs(int debugflag, char *output);
int copythintemacs(int debugflag, const char *src, const char *dst);

int main(int argc, char *argv[]) {

  int debugopt = 0, verboseopt = 0, testopt = 0;
  char output[MAXPATHLEN];
  int ch;
  int ret, fd;

  while ((ch = getopt(argc, argv, "dvn")) != -1) {
    switch (ch) {
    case 'd':
      debugopt = 1;
      verboseopt = 1;
      break;
    case 'v':
      verboseopt = 1;
      break;
    case 'n':
      testopt = 1;
      break;
    default:
      usage();
      break;
    }
  }

  if(!testopt) {
    // must be run as root unless we're not planning on writing
    if(geteuid() != 0)
      errx(1, "Must be run as root unless -n is used");
  }

  

  if(!verboseopt) {
    fd = open("/dev/null", O_RDWR, 0600);
    if(fd < 0)
      err(1, "open(/dev/null)");

    ret = dup2(fd, STDIN_FILENO);
    if(ret == -1)
      err(1, "dup2(/dev/null, stdin)");
    
    ret = dup2(fd, STDOUT_FILENO);
    if(ret == -1)
      err(1, "dup2(/dev/null, stdout)");
    
    ret = dup2(fd, STDERR_FILENO);
    if(ret == -1)
      err(1, "dup2(/dev/null, stderr)");

    ret = close(fd);
    if(ret == -1)
      err(1, "close(/dev/null)");
  }

  printf("Checking if emacs is up-to-date\n");

  if(is_emacs_valid(debugopt)) {
    printf("Emacs is up-to-date. No dumping required\n");
    return 0;
  } else {
    printf("emacs is not up-to-date. Needs dumping\n");
  }

  ret = dumpemacs(debugopt, output);
  if(ret != 0)
    errx(1, "Failed to dump native emacs");

  if(testopt) {
    printf("emacs successfully dumped. Test mode successful.\n");
    return 0;
  }

  ret = chown(output, 0, 0); // reset to root:wheel
  if(ret)
    err(1, "chown(%s)", output);

  const char * newargs[5];
  newargs[0] = "/bin/cp";
  newargs[1] = "-p";
  newargs[2] = output;
  newargs[3] = kEmacsArchPath;
  newargs[4] = NULL;

  if(debugopt) printf("Installing dumped emacs\n");
  ret = runit(newargs, 0);
  if(ret)
    errx(1, "Failed to install dumped emacs");

  return 0;

}

void usage(void)
{
  fprintf(stderr, "Usage: %s [-d] [-v] [-n]\n", getprogname());
  exit(EX_USAGE);
}



int dumpemacs(int debugflag, char *output)
{
  char tempdir[MAXPATHLEN], newpath[MAXPATHLEN];
  char *tmp = NULL;
  int ret;
  struct passwd *nobody = NULL;
  uid_t nobodyUID = 0;

  nobody = getpwnam("nobody");
  if(nobody == NULL)
 	err(1, "Don't know about nobody");

  nobodyUID = nobody->pw_uid;

  tmp = "/tmp";

  snprintf(tempdir, sizeof(tempdir), "%s/emacs.XXXXXX", tmp);

  if(debugflag) printf("Generating random directory with template %s\n", tempdir);
  if(NULL == mkdtemp(tempdir))
    err(1, "mkdtemp(%s) failed", tempdir);
  chown(tempdir, nobodyUID, 0);
  if(debugflag) printf("Directory is %s\n", tempdir);

  snprintf(newpath, sizeof(newpath), "%s/etc", tempdir);
  if(debugflag) printf("Making directory %s\n", newpath);
  ret = mkdir(newpath,  S_IRWXU);
  if(ret)
    err(1, "mkdir(%s)", newpath);
  chown(newpath, nobodyUID, 0);

  snprintf(newpath, sizeof(newpath), "%s/lib-src", tempdir);
  if(debugflag) printf("Making directory %s\n", newpath);
  ret = mkdir(newpath,  S_IRWXU);
  if(ret)
    err(1, "mkdir(%s)", newpath);
  chown(newpath, nobodyUID, 0);

  snprintf(newpath, sizeof(newpath), "%s/src", tempdir);
  if(debugflag) printf("Making directory %s\n", newpath);
  ret = mkdir(newpath,  S_IRWXU);
  if(ret)
    err(1, "mkdir(%s)", newpath);
  chown(newpath, nobodyUID, 0);

  snprintf(newpath, sizeof(newpath), "%s/etc/GNU", tempdir);
  if(debugflag) printf("Making symlink %s -> %s\n",
		       newpath, kEmacsShareDir "/" kEmacsVersion "/etc/GNU");
  ret = symlink(kEmacsShareDir "/" kEmacsVersion "/etc/GNU", newpath);
  if(ret)
    err(1, "symlink(%s)", newpath);

  snprintf(newpath, sizeof(newpath), "%s/etc/DOC", tempdir);
  if(debugflag) printf("Making symlink %s -> %s\n",
		       newpath, kEmacsShareDir "/" kEmacsVersion "/etc/DOC-" kEmacsVersion "." kEmacsVersionMinor);
  ret = symlink(kEmacsShareDir "/" kEmacsVersion "/etc/DOC-" kEmacsVersion "." kEmacsVersionMinor, newpath);
  if(ret)
    err(1, "symlink(%s)", newpath);

  snprintf(newpath, sizeof(newpath), "%s/src/temacs", tempdir);
  ret = copythintemacs(debugflag, kEmacsUndumpedPath, newpath);
  if(ret)
    errx(1, "copythintemacs() failed");

  snprintf(newpath, sizeof(newpath), "%s/src", tempdir);
  ret = chdir(newpath);
  if(ret)
    err(1, "chdir(%s)", newpath);

  ret = setenv("LC_ALL", "C", 1);
  if(ret)
    err(1, "setenv(LC_ALL, C)");

  const char *newargs[6];
  newargs[0] = "./temacs";
  newargs[1] = "-batch";
  newargs[2] = "-l";
  newargs[3] = "loadup";
  newargs[4] = "dump";
  newargs[5] = NULL;

  if(debugflag) printf("Attempting to dump emacs\n");
  ret = runit(newargs, 1);
  if(ret)
    errx(1, "Failed to dump emacs");

  snprintf(output, MAXPATHLEN, "%s/src/emacs", tempdir);
  if(debugflag) printf("emacs dumped as %s\n", output);


  return 0;
}

int copythintemacs(int debugflag, const char *src, const char *dst)
{
  int fd;
  int ret;
  char buffer[4096];
  struct fat_header *fh = (struct fat_header *)buffer;
  struct fat_arch fakearch;
  struct fat_arch *archs = NULL, *bestArch = NULL;
  int archCount = 0;
  ssize_t readBytes;
  int isFat = 0;
  const NXArchInfo *thisArch = NULL;

  bzero(&fakearch, sizeof(fakearch));

  fd = open(src, O_RDONLY, 0400);
  if(fd < 0)
    err(1, "open(%s)", src);

  readBytes = read(fd, buffer, sizeof(buffer));
  if(readBytes != sizeof(buffer))
    err(1, "read failed");

  ret = close(fd);
  if(ret)
    err(1, "close(%s)", src);

  if(fh->magic == FAT_MAGIC || fh->magic == FAT_CIGAM) {
    int i;
    
    archs = (struct fat_arch *)(fh + 1);

    fh->magic = OSSwapBigToHostInt32(fh->magic);
    fh->nfat_arch = OSSwapBigToHostInt32(fh->nfat_arch);
    if(fh->nfat_arch >= 0x10000)
      errx(1, "Illegal fat header");

    for(i=0; i < fh->nfat_arch; i++) {
      archs[i].cputype = OSSwapBigToHostInt32(archs[i].cputype);
      archs[i].cpusubtype = OSSwapBigToHostInt32(archs[i].cpusubtype);
      archs[i].offset = OSSwapBigToHostInt32(archs[i].offset);
      archs[i].size = OSSwapBigToHostInt32(archs[i].size);
      archs[i].align = OSSwapBigToHostInt32(archs[i].align);
    }
    isFat = 1;
    archCount = fh->nfat_arch;
  } else if(fh->magic == MH_MAGIC) {
    struct mach_header *mh = (struct mach_header *)buffer;
    fakearch.cputype = mh->cputype;
    fakearch.cpusubtype = mh->cpusubtype;
    fakearch.offset = 0;
    fakearch.size = 0;
    fakearch.align = 0;
    archs = &fakearch;
    archCount = 1;
  } else if(fh->magic == MH_CIGAM) {
    struct mach_header *mh = (struct mach_header *)buffer;
    fakearch.cputype = OSSwapInt32(mh->cputype);
    fakearch.cpusubtype = OSSwapInt32(mh->cpusubtype);
    fakearch.offset = 0;
    fakearch.size = 0;
    fakearch.align = 0;
    archs = &fakearch;
    archCount = 1;
  } else if(fh->magic == MH_MAGIC_64) {
    struct mach_header_64 *mh = (struct mach_header_64 *)buffer;
    fakearch.cputype = mh->cputype;
    fakearch.cpusubtype = mh->cpusubtype;
    fakearch.offset = 0;
    fakearch.size = 0;
    fakearch.align = 0;
    archs = &fakearch;
    archCount = 1;
  } else if(fh->magic == MH_CIGAM_64) {
    struct mach_header_64 *mh = (struct mach_header_64 *)buffer;
    fakearch.cputype = OSSwapInt32(mh->cputype);
    fakearch.cpusubtype = OSSwapInt32(mh->cpusubtype);
    fakearch.offset = 0;
    fakearch.size = 0;
    fakearch.align = 0;
    archs = &fakearch;
    archCount = 1;
  }

  thisArch = NXGetArchInfoFromName(kEmacsArch);
  if(thisArch == NULL)
    errx(1, "Unknown architecture: %s", kEmacsArch);

  bestArch = NXFindBestFatArch(thisArch->cputype,
			       thisArch->cpusubtype,
			       archs,
			       archCount);
  if(bestArch == NULL)
    errx(1, "No appropriate architecture in %s", src);

  // we need to copy it to dst, either as-is, or thinning
  if(!isFat) {
    const char * newargs[5];
    newargs[0] = "/bin/cp";
    newargs[1] = "-p";
    newargs[2] = src;
    newargs[3] = dst;
    newargs[4] = NULL;
      
    if(debugflag) printf("Copying %s to %s\n", src, dst);
    ret = runit(newargs, 0);
    if(ret)
      errx(1, "copying failed");

  } else {
    const char * newargs[7];
    newargs[0] = "/usr/bin/lipo";
    newargs[1] = src;
    newargs[2] = "-thin";
    newargs[3] = thisArch->name;
    newargs[4] = "-output";
    newargs[5] = dst;
    newargs[6] = NULL;
      
    if(debugflag) printf("Thinning %s to %s\n", src, dst);
    ret = runit(newargs, 0);
    if(ret)
      errx(1, "thinning failed");

  }

  return 0;
}

