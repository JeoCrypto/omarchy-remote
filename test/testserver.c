/* omarchy-remote: developed by JeoCrypto.
 * Tiny VNC test server for omarchy-vnc (libvncserver). Prints every input event it receives.
 * Usage: testserver [port] [password]      (no password = no authentication) */
#include <rfb/rfb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define W 800
#define H 500

static void on_key(rfbBool down, rfbKeySym k, rfbClientPtr cl) {
  (void)cl;
  printf("KEY %s 0x%x\n", down ? "down" : "up", (unsigned)k);
  fflush(stdout);
}

static void on_ptr(int mask, int x, int y, rfbClientPtr cl) {
  static int last_mask = -1;
  (void)cl;
  if (mask != last_mask) { printf("PTR mask=%d x=%d y=%d\n", mask, x, y); fflush(stdout); last_mask = mask; }
}

static void on_cut(char *text, int len, rfbClientPtr cl) {
  (void)cl;
  printf("CUT %.*s\n", len, text);
  fflush(stdout);
}

static void on_new_client_gone(rfbClientPtr cl) { (void)cl; printf("CLIENT gone\n"); fflush(stdout); }

static enum rfbNewClientAction on_new_client(rfbClientPtr cl) {
  printf("CLIENT connected\n"); fflush(stdout);
  cl->clientGoneHook = on_new_client_gone;
  return RFB_CLIENT_ACCEPT;
}

int main(int argc, char **argv) {
  int port = argc > 1 ? atoi(argv[1]) : 5999;
  const char *pw = argc > 2 ? argv[2] : NULL;
  int ac = 1;
  rfbScreenInfoPtr s = rfbGetScreen(&ac, argv, W, H, 8, 3, 4);
  if (!s) return 1;
  s->frameBuffer = malloc((size_t)W * H * 4);
  s->port = port;
  s->alwaysShared = TRUE;
  s->kbdAddEvent = on_key;
  s->ptrAddEvent = on_ptr;
  s->setXCutText = on_cut;
  s->newClientHook = on_new_client;
  if (pw) {
    static char *list[2];
    list[0] = strdup(pw); list[1] = NULL;
    s->authPasswdData = (void *)list;
    s->passwordCheck = rfbCheckPasswordByList;
  }
  for (int y = 0; y < H; y++)
    for (int x = 0; x < W; x++) {
      unsigned char *p = (unsigned char *)s->frameBuffer + ((size_t)y * W + x) * 4;
      p[0] = (unsigned char)(x * 255 / W);        /* blue  */
      p[1] = (unsigned char)(y * 255 / H);        /* green */
      p[2] = 80;                                  /* red   */
      p[3] = 0;
      /* thin white frame so scaling and aspect ratio are visible */
      if (x < 4 || y < 4 || x >= W - 4 || y >= H - 4) { p[0] = p[1] = p[2] = 255; }
    }
  rfbInitServer(s);
  printf("LISTENING %d%s\n", port, pw ? " (password)" : ""); fflush(stdout);

  time_t last = time(NULL);
  int tick = 0, sent_cut = 0;
  while (rfbIsActive(s)) {
    rfbProcessEvents(s, 20000);
    if (time(NULL) != last) {
      last = time(NULL); tick++;
      /* animate a moving block so updates keep flowing */
      int bx = (tick * 40) % (W - 60);
      for (int y = 100; y < 160; y++)
        for (int x = 0; x < W; x++) {
          unsigned char *p = (unsigned char *)s->frameBuffer + ((size_t)y * W + x) * 4;
          int in = x >= bx && x < bx + 60;
          p[0] = in ? 255 : 30; p[1] = in ? 255 : 30; p[2] = in ? 0 : 30;
        }
      rfbMarkRectAsModified(s, 0, 100, W, 160);
      if (tick == 3 && !sent_cut) { rfbSendServerCutText(s, "clip-from-server", 16); sent_cut = 1; }
    }
  }
  return 0;
}
