/*
 * omarchy-remote: developed by JeoCrypto.
 * mac-display: list and change the main display's mode on macOS (CoreGraphics only).
 * Part of omarchy-remote: lets the remote Mac match the window you view it in.
 *
 *   mac-display current              print the current mode
 *   mac-display list                 list usable modes (HiDPI "looks like" size, backing pixels, Hz)
 *   mac-display set W H              switch to the HiDPI mode that "looks like" WxH (remembers the original)
 *   mac-display best W H             like set, but picks the closest 16:9-or-wider HiDPI mode to WxH
 *   mac-display restore              go back to the mode remembered by the last set/best
 *
 * Changes apply for the current login session only: they revert on logout or reboot.
 * Build:  clang -O2 -framework CoreGraphics -framework CoreFoundation -o mac-display mac-display.c
 * License: MIT
 */
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char state_path[1024];

static void init_state_path(void) {
  const char *home = getenv("HOME");
  snprintf(state_path, sizeof state_path, "%s/.cache/omarchy-mac-display-original", home ? home : "/tmp");
}

static CFArrayRef all_modes(CGDirectDisplayID d) {
  const void *keys[] = { kCGDisplayShowDuplicateLowResolutionModes };
  const void *vals[] = { kCFBooleanTrue };
  CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFArrayRef a = CGDisplayCopyAllDisplayModes(d, opts);
  CFRelease(opts);
  return a;
}

static int is_hidpi(CGDisplayModeRef m) {
  return CGDisplayModeGetPixelWidth(m) >= 2 * CGDisplayModeGetWidth(m);
}

static void describe(CGDisplayModeRef m, char *out, size_t n) {
  snprintf(out, n, "%zux%zu (backing %zux%zu%s, %.0f Hz)", CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
           CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m), is_hidpi(m) ? ", HiDPI" : "",
           CGDisplayModeGetRefreshRate(m));
}

static int apply(CGDirectDisplayID d, CGDisplayModeRef m) {
  CGDisplayConfigRef cfg;
  if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return 1;
  if (CGConfigureDisplayWithDisplayMode(cfg, d, m, NULL) != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return 2; }
  /* kCGConfigureForSession: reverts automatically when the login session ends. */
  if (CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession) != kCGErrorSuccess) return 3;
  return 0;
}

static void remember_original(CGDirectDisplayID d) {
  FILE *f = fopen(state_path, "r");
  if (f) { fclose(f); return; }                       /* keep the first original */
  CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
  f = fopen(state_path, "w");
  if (f && cur) {
    fprintf(f, "%zu %zu %zu %zu %.0f\n", CGDisplayModeGetWidth(cur), CGDisplayModeGetHeight(cur),
            CGDisplayModeGetPixelWidth(cur), CGDisplayModeGetPixelHeight(cur), CGDisplayModeGetRefreshRate(cur));
  }
  if (f) fclose(f);
  if (cur) CGDisplayModeRelease(cur);
}

static CGDisplayModeRef find_mode(CGDirectDisplayID d, size_t w, size_t h, size_t pw, size_t ph, double hz, int want_hidpi) {
  CFArrayRef modes = all_modes(d);
  CGDisplayModeRef found = NULL;
  double best_hz_diff = 1e9;
  for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
    CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
    if (!CGDisplayModeIsUsableForDesktopGUI(m)) continue;
    if (CGDisplayModeGetWidth(m) != w || CGDisplayModeGetHeight(m) != h) continue;
    if (pw && (CGDisplayModeGetPixelWidth(m) != pw || CGDisplayModeGetPixelHeight(m) != ph)) continue;
    if (want_hidpi >= 0 && is_hidpi(m) != want_hidpi) continue;
    double diff = fabs(CGDisplayModeGetRefreshRate(m) - hz);
    if (diff < best_hz_diff) { best_hz_diff = diff; found = m; }
  }
  if (found) CGDisplayModeRetain(found);
  if (modes) CFRelease(modes);
  return found;
}

int main(int argc, char **argv) {
  init_state_path();
  CGDirectDisplayID d = CGMainDisplayID();
  const char *cmd = argc > 1 ? argv[1] : "current";
  char buf[160];

  if (!strcmp(cmd, "current")) {
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    describe(cur, buf, sizeof buf);
    printf("%s\n", buf);
    CGDisplayModeRelease(cur);
    return 0;
  }

  if (!strcmp(cmd, "list")) {
    CFArrayRef modes = all_modes(d);
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
      CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
      if (!CGDisplayModeIsUsableForDesktopGUI(m) || !is_hidpi(m)) continue;
      describe(m, buf, sizeof buf);
      printf("%s%s\n", buf, CGDisplayModeGetIODisplayModeID(m) == CGDisplayModeGetIODisplayModeID(cur) ? "   <- current" : "");
    }
    CGDisplayModeRelease(cur);
    if (modes) CFRelease(modes);
    return 0;
  }

  if ((!strcmp(cmd, "set") || !strcmp(cmd, "best")) && argc >= 4) {
    size_t w = (size_t)atoi(argv[2]), h = (size_t)atoi(argv[3]);
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    double hz = CGDisplayModeGetRefreshRate(cur);
    CGDisplayModeRef target = NULL;

    if (!strcmp(cmd, "set")) {
      target = find_mode(d, w, h, 0, 0, hz, 1);
    } else {
      /* closest HiDPI "looks like" size (by logical width, then height) among usable modes */
      CFArrayRef modes = all_modes(d);
      double best = 1e18;
      for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!CGDisplayModeIsUsableForDesktopGUI(m) || !is_hidpi(m)) continue;
        double dw = (double)CGDisplayModeGetWidth(m) - (double)w, dh = (double)CGDisplayModeGetHeight(m) - (double)h;
        double score = dw * dw + dh * dh + fabs(CGDisplayModeGetRefreshRate(m) - hz) * 1000.0;
        if (score < best) { best = score; target = m; }
      }
      if (target) CGDisplayModeRetain(target);
      if (modes) CFRelease(modes);
    }
    if (!target) { fprintf(stderr, "no matching HiDPI mode for %zux%zu\n", w, h); CGDisplayModeRelease(cur); return 4; }

    describe(target, buf, sizeof buf);
    if (CGDisplayModeGetIODisplayModeID(target) == CGDisplayModeGetIODisplayModeID(cur)) {
      printf("already %s\n", buf);
    } else {
      remember_original(d);
      int rc = apply(d, target);
      if (rc) { fprintf(stderr, "could not switch (error %d)\n", rc); return 5; }
      printf("switched to %s\n", buf);
    }
    CGDisplayModeRelease(target); CGDisplayModeRelease(cur);
    return 0;
  }

  if (!strcmp(cmd, "restore")) {
    FILE *f = fopen(state_path, "r");
    if (!f) { printf("nothing to restore\n"); return 0; }
    size_t w, h, pw, ph; double hz;
    if (fscanf(f, "%zu %zu %zu %zu %lf", &w, &h, &pw, &ph, &hz) != 5) { fclose(f); return 6; }
    fclose(f);
    CGDisplayModeRef target = find_mode(d, w, h, pw, ph, hz, -1);
    if (!target) { fprintf(stderr, "original mode not found\n"); return 4; }
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    int same = CGDisplayModeGetIODisplayModeID(target) == CGDisplayModeGetIODisplayModeID(cur);
    CGDisplayModeRelease(cur);
    int rc = same ? 0 : apply(d, target);
    describe(target, buf, sizeof buf);
    CGDisplayModeRelease(target);
    if (rc) { fprintf(stderr, "could not restore (error %d)\n", rc); return 5; }
    remove(state_path);
    printf("restored %s\n", buf);
    return 0;
  }

  fprintf(stderr, "usage: mac-display current | list | set W H | best W H | restore\n");
  return 1;
}
