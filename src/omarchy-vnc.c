/*
 * omarchy-remote: developed by JeoCrypto.
 * omarchy-vnc: a tiny, Wayland-native VNC viewer for Omarchy.
 * Built on libvncclient (the same library Remmina uses, with Apple Remote Desktop login)
 * and SDL3 (the same toolkit as sdl-freerdp3). No toolbar, no tabs: just the remote screen.
 *
 * Usage:
 *   omarchy-vnc --host HOST [--port N] [--user NAME] [--class APP_ID] [--title TEXT]
 *               [--cmd ctrl|alt|none] [--fit auto|contain|cover|stretch] [--check] [--selftest]
 *
 * The password is read from the first line of stdin (never from the command line).
 *
 * Exit codes: 0 closed normally / check OK, 2 login rejected, 3 could not connect,
 *             4 connection lost.
 *
 * --cmd chooses which local key acts as the Mac's Command key (Super stays Omarchy's):
 *   ctrl (default): Ctrl+C, Ctrl+V ... become Command+C, Command+V ...
 *   alt:            the left Alt key is Command.
 *   none:           modifiers are sent as they are.
 *
 * License: GPL-2.0-or-later (this program links libvncclient, which is GPL-2.0-or-later)
 */
#include <SDL3/SDL.h>
#include <rfb/rfbclient.h>
#include <rfb/keysym.h>

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

enum { CMD_NONE, CMD_CTRL, CMD_ALT };
enum { FIT_AUTO, FIT_CONTAIN, FIT_COVER, FIT_STRETCH };

typedef struct {
  rfbClient *cl;
  SDL_Window *win;
  SDL_Renderer *ren;
  SDL_Texture *tex;
  int fbw, fbh;
  char user[256];
  char pass[512];
  char title[256];
  char appid[128];
  int cmd_mode;
  int fit_mode;
  int button_mask;
  int mouse_x, mouse_y;
  char *last_clip;
  int dirty;
  int got_first_frame;
  int auth_failed;
  int connect_failed;
  uint32_t held[SDL_SCANCODE_COUNT];   /* keysym we pressed for each scancode, 0 = none */
  char errlog[1024];
} App;

static App A;
static int verbose;

/* ---------- libvncclient logging: capture errors so we can classify failures ---------- */

static void note(const char *msg) {
  if (verbose) fputs(msg, stderr);
  size_t used = strlen(A.errlog);
  if (used < sizeof A.errlog - 1) snprintf(A.errlog + used, sizeof A.errlog - used, "%s", msg);
  if (strcasestr(msg, "authentication") || strcasestr(msg, "password") || strcasestr(msg, "credential") ||
      strcasestr(msg, "auth failed"))
    A.auth_failed = 1;
  if (strcasestr(msg, "unable to connect") || strcasestr(msg, "connection refused") ||
      strcasestr(msg, "timed out") || strcasestr(msg, "no route") || strcasestr(msg, "ConnectClientToTcpAddr"))
    A.connect_failed = 1;
}

static void on_msg(const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  note(buf);
}

/* ---------- credentials ---------- */

static char *get_password(rfbClient *cl) {
  (void)cl;
  return strdup(A.pass);
}

static rfbCredential *get_credential(rfbClient *cl, int type) {
  (void)cl;
  if (type != rfbCredentialTypeUser) return NULL;
  rfbCredential *c = calloc(1, sizeof *c);
  if (!c) return NULL;
  c->userCredential.username = strdup(A.user);
  c->userCredential.password = strdup(A.pass);
  return c;
}


/* How the remote screen fits the window.
 *   contain : whole screen, aspect kept, bars if the shapes differ
 *   cover   : fill the window, crop the overflow
 *   stretch : fill the window, distort slightly
 *   auto    : stretch only when the shapes are within ~4% (distortion not noticeable),
 *             otherwise contain. Re-evaluated whenever the window changes. */
static void apply_fit(void) {
  if (!A.ren || A.fbw <= 0 || A.fbh <= 0) return;
  int pw = 0, ph = 0;
  SDL_GetCurrentRenderOutputSize(A.ren, &pw, &ph);
  SDL_RendererLogicalPresentation mode = SDL_LOGICAL_PRESENTATION_LETTERBOX;
  switch (A.fit_mode) {
    case FIT_COVER:   mode = SDL_LOGICAL_PRESENTATION_OVERSCAN; break;
    case FIT_STRETCH: mode = SDL_LOGICAL_PRESENTATION_STRETCH; break;
    case FIT_AUTO:
      if (pw > 0 && ph > 0) {
        double win = (double)pw / ph, fb = (double)A.fbw / A.fbh;
        double ratio = win > fb ? win / fb : fb / win;
        if (ratio <= 1.04) mode = SDL_LOGICAL_PRESENTATION_STRETCH;
      }
      break;
    default: break;
  }
  SDL_SetRenderLogicalPresentation(A.ren, A.fbw, A.fbh, mode);
}

/* ---------- framebuffer ---------- */

static rfbBool malloc_fb(rfbClient *cl) {
  free(cl->frameBuffer);
  A.fbw = cl->width;
  A.fbh = cl->height;
  cl->frameBuffer = calloc((size_t)A.fbw * A.fbh, 4);
  if (!cl->frameBuffer) return FALSE;

  /* 0x00RRGGBB, matches SDL_PIXELFORMAT_XRGB8888 */
  cl->format.bitsPerPixel = 32;
  cl->format.depth = 24;
  cl->format.bigEndian = 0;
  cl->format.trueColour = 1;
  cl->format.redMax = cl->format.greenMax = cl->format.blueMax = 255;
  cl->format.redShift = 16;
  cl->format.greenShift = 8;
  cl->format.blueShift = 0;
  if (!SetFormatAndEncodings(cl)) return FALSE;

  if (A.ren) {
    if (A.tex) SDL_DestroyTexture(A.tex);
    A.tex = SDL_CreateTexture(A.ren, SDL_PIXELFORMAT_XRGB8888, SDL_TEXTUREACCESS_STREAMING, A.fbw, A.fbh);
    if (A.tex) SDL_SetTextureScaleMode(A.tex, SDL_SCALEMODE_LINEAR);
    apply_fit();
    A.dirty = 1;
  }
  return TRUE;
}

static void got_update(rfbClient *cl, int x, int y, int w, int h) {
  if (!A.tex) return;
  if (x < 0) { w += x; x = 0; }
  if (y < 0) { h += y; y = 0; }
  if (x + w > A.fbw) w = A.fbw - x;
  if (y + h > A.fbh) h = A.fbh - y;
  if (w <= 0 || h <= 0) return;
  SDL_Rect r = { x, y, w, h };
  SDL_UpdateTexture(A.tex, &r, cl->frameBuffer + ((size_t)y * A.fbw + x) * 4, A.fbw * 4);
  A.dirty = 1;
  A.got_first_frame = 1;
}

/* ---------- clipboard ---------- */

static void remember_clip(const char *text) {
  free(A.last_clip);
  A.last_clip = strdup(text);
}

static void got_cut_utf8(rfbClient *cl, const char *buf, int len) {
  (void)cl;
  if (len <= 0) return;
  char *t = malloc((size_t)len + 1);
  if (!t) return;
  memcpy(t, buf, (size_t)len);
  t[len] = 0;
  remember_clip(t);
  SDL_SetClipboardText(t);
  free(t);
}

static void got_cut_latin1(rfbClient *cl, const char *buf, int len) {
  (void)cl;
  if (len <= 0) return;
  char *t = malloc((size_t)len * 2 + 1), *o = t;
  if (!t) return;
  for (int i = 0; i < len; i++) {
    unsigned char c = (unsigned char)buf[i];
    if (c < 0x80) *o++ = (char)c;
    else { *o++ = (char)(0xC0 | (c >> 6)); *o++ = (char)(0x80 | (c & 0x3F)); }
  }
  *o = 0;
  remember_clip(t);
  SDL_SetClipboardText(t);
  free(t);
}

/* UTF-8 -> Latin-1 for servers without the extended clipboard (unmappable characters become '?'). */
static char *utf8_to_latin1(const char *s, int *outlen) {
  size_t n = strlen(s);
  char *o = malloc(n + 1), *w = o;
  if (!o) return NULL;
  const unsigned char *p = (const unsigned char *)s;
  while (*p) {
    uint32_t cp; int len;
    if (*p < 0x80)              { cp = *p;        len = 1; }
    else if ((*p >> 5) == 0x6)  { cp = *p & 0x1F; len = 2; }
    else if ((*p >> 4) == 0xE)  { cp = *p & 0x0F; len = 3; }
    else if ((*p >> 3) == 0x1E) { cp = *p & 0x07; len = 4; }
    else { p++; continue; }
    for (int i = 1; i < len; i++) {
      if ((p[i] & 0xC0) != 0x80) { len = i; break; }
      cp = (cp << 6) | (p[i] & 0x3F);
    }
    p += len;
    *w++ = cp < 0x100 ? (char)cp : '?';
  }
  *w = 0;
  *outlen = (int)(w - o);
  return o;
}

static void send_local_clipboard(void) {
  if (!SDL_HasClipboardText()) return;
  char *t = SDL_GetClipboardText();
  if (t && *t && (!A.last_clip || strcmp(t, A.last_clip) != 0)) {
    remember_clip(t);
    if (!SendClientCutTextUTF8(A.cl, t, (int)strlen(t))) {
      int n = 0;
      char *l = utf8_to_latin1(t, &n);
      if (l) { SendClientCutText(A.cl, l, n); free(l); }
    }
  }
  SDL_free(t);
}

/* ---------- keyboard ---------- */

static uint32_t special_keysym(SDL_Keycode k) {
  switch (k) {
    case SDLK_RETURN: case SDLK_KP_ENTER: return XK_Return;
    case SDLK_ESCAPE: return XK_Escape;
    case SDLK_BACKSPACE: return XK_BackSpace;
    case SDLK_TAB: return XK_Tab;
    case SDLK_DELETE: return XK_Delete;
    case SDLK_HOME: return XK_Home;
    case SDLK_END: return XK_End;
    case SDLK_PAGEUP: return XK_Page_Up;
    case SDLK_PAGEDOWN: return XK_Page_Down;
    case SDLK_INSERT: return XK_Insert;
    case SDLK_LEFT: return XK_Left;
    case SDLK_RIGHT: return XK_Right;
    case SDLK_UP: return XK_Up;
    case SDLK_DOWN: return XK_Down;
    case SDLK_CAPSLOCK: return XK_Caps_Lock;
    case SDLK_F1: return XK_F1;   case SDLK_F2: return XK_F2;   case SDLK_F3: return XK_F3;
    case SDLK_F4: return XK_F4;   case SDLK_F5: return XK_F5;   case SDLK_F6: return XK_F6;
    case SDLK_F7: return XK_F7;   case SDLK_F8: return XK_F8;   case SDLK_F9: return XK_F9;
    case SDLK_F10: return XK_F10; case SDLK_F11: return XK_F11; case SDLK_F12: return XK_F12;
    case SDLK_LSHIFT: return XK_Shift_L;
    case SDLK_RSHIFT: return XK_Shift_R;
    default: return 0;
  }
}

/* Modifier keys, mapped for the Mac. Returns 0 to swallow (AltGr, Super, Menu). */
static uint32_t modifier_keysym(SDL_Keycode k) {
  switch (k) {
    case SDLK_LCTRL:  return A.cmd_mode == CMD_CTRL ? XK_Super_L : XK_Control_L;
    case SDLK_RCTRL:  return A.cmd_mode == CMD_CTRL ? XK_Super_R : XK_Control_R;
    case SDLK_LALT:   return A.cmd_mode == CMD_ALT  ? XK_Super_L : XK_Alt_L;
    case SDLK_RALT:   return 0;           /* AltGr only produces characters through text input */
    default:          return UINT32_MAX;  /* not a modifier */
  }
}

static int is_command_chord(void) {
  SDL_Keymod m = SDL_GetModState();
  if (A.cmd_mode == CMD_CTRL) return (m & SDL_KMOD_CTRL) != 0;
  if (A.cmd_mode == CMD_ALT) return (m & SDL_KMOD_LALT) != 0;
  return (m & (SDL_KMOD_CTRL | SDL_KMOD_ALT)) != 0;
}

static void handle_key(const SDL_KeyboardEvent *e) {
  if (e->scancode >= SDL_SCANCODE_COUNT) return;
  SDL_Keycode k = e->key;

  if (!e->down) {                         /* release exactly what we pressed */
    uint32_t ks = A.held[e->scancode];
    if (ks) { SendKeyEvent(A.cl, ks, FALSE); A.held[e->scancode] = 0; }
    return;
  }
  if (e->repeat && A.held[e->scancode] == 0) return;

  uint32_t ks = modifier_keysym(k);
  if (ks == 0) return;
  if (ks == UINT32_MAX) ks = special_keysym(k);
  if (ks == 0) {
    /* Printable key: normally text input delivers it (layout, accents, AltGr). With a
     * shortcut modifier held there is no text, so send the key itself. */
    if (k < 0x80 && k >= 0x20 && is_command_chord()) ks = (uint32_t)tolower((int)k);
    else if (k >= 0x80 && k < SDLK_SCANCODE_MASK && is_command_chord()) ks = 0x01000000u + (uint32_t)k;
  }
  if (ks == 0) return;
  SendKeyEvent(A.cl, ks, TRUE);
  A.held[e->scancode] = ks;
}

static void handle_text(const char *utf8) {
  const unsigned char *p = (const unsigned char *)utf8;
  while (*p) {
    uint32_t cp; int n;
    if (*p < 0x80)              { cp = *p;               n = 1; }
    else if ((*p >> 5) == 0x6)  { cp = *p & 0x1F;        n = 2; }
    else if ((*p >> 4) == 0xE)  { cp = *p & 0x0F;        n = 3; }
    else if ((*p >> 3) == 0x1E) { cp = *p & 0x07;        n = 4; }
    else { p++; continue; }
    for (int i = 1; i < n; i++) {
      if ((p[i] & 0xC0) != 0x80) { n = i; break; }
      cp = (cp << 6) | (p[i] & 0x3F);
    }
    p += n;
    uint32_t ks = cp < 0x100 ? cp : 0x01000000u + cp;
    SendKeyEvent(A.cl, ks, TRUE);
    SendKeyEvent(A.cl, ks, FALSE);
  }
}

/* ---------- mouse ---------- */

static void send_pointer(void) {
  int x = A.mouse_x < 0 ? 0 : (A.mouse_x >= A.fbw ? A.fbw - 1 : A.mouse_x);
  int y = A.mouse_y < 0 ? 0 : (A.mouse_y >= A.fbh ? A.fbh - 1 : A.mouse_y);
  SendPointerEvent(A.cl, x, y, A.button_mask);
}

static int button_bit(Uint8 b) {
  switch (b) {
    case SDL_BUTTON_LEFT: return 1 << 0;
    case SDL_BUTTON_MIDDLE: return 1 << 1;
    case SDL_BUTTON_RIGHT: return 1 << 2;
    default: return 0;
  }
}

static void scroll_ticks(int bit, int n) {
  for (int i = 0; i < n; i++) {
    SendPointerEvent(A.cl, A.mouse_x < 0 ? 0 : A.mouse_x, A.mouse_y < 0 ? 0 : A.mouse_y, A.button_mask | bit);
    SendPointerEvent(A.cl, A.mouse_x < 0 ? 0 : A.mouse_x, A.mouse_y < 0 ? 0 : A.mouse_y, A.button_mask);
  }
}

/* ---------- main ---------- */

static void usage(void) {
  fprintf(stderr, "usage: omarchy-vnc --host HOST [--port N] [--user NAME] [--class APP_ID] [--title TEXT]\n"
                  "                   [--cmd ctrl|alt|none] [--fit auto|contain|cover|stretch] [--check] [--selftest]\n"
                  "password: first line of stdin\n");
}

static void render(void) {
  SDL_SetRenderDrawColor(A.ren, 0, 0, 0, 255);
  SDL_RenderClear(A.ren);
  if (A.tex) SDL_RenderTexture(A.ren, A.tex, NULL, NULL);
  SDL_RenderPresent(A.ren);
  A.dirty = 0;
}

int main(int argc, char **argv) {
  const char *host = NULL;
  int port = 5900, check = 0, selftest = 0, probe = 0;
  snprintf(A.title, sizeof A.title, "VNC");
  snprintf(A.appid, sizeof A.appid, "omarchy-vnc");
  A.cmd_mode = CMD_CTRL;
  A.fit_mode = FIT_AUTO;

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--host") && i + 1 < argc) host = argv[++i];
    else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--user") && i + 1 < argc) snprintf(A.user, sizeof A.user, "%s", argv[++i]);
    else if (!strcmp(argv[i], "--class") && i + 1 < argc) snprintf(A.appid, sizeof A.appid, "%s", argv[++i]);
    else if (!strcmp(argv[i], "--title") && i + 1 < argc) snprintf(A.title, sizeof A.title, "%s", argv[++i]);
    else if (!strcmp(argv[i], "--cmd") && i + 1 < argc) {
      const char *m = argv[++i];
      A.cmd_mode = !strcmp(m, "alt") ? CMD_ALT : (!strcmp(m, "none") ? CMD_NONE : CMD_CTRL);
    }
    else if (!strcmp(argv[i], "--fit") && i + 1 < argc) {
      const char *m = argv[++i];
      A.fit_mode = !strcmp(m, "contain") ? FIT_CONTAIN : !strcmp(m, "cover") ? FIT_COVER :
                   !strcmp(m, "stretch") ? FIT_STRETCH : FIT_AUTO;
    }
    else if (!strcmp(argv[i], "--check")) check = 1;
    else if (!strcmp(argv[i], "--verbose")) verbose = 1;
    else if (!strcmp(argv[i], "--probe-resize")) probe = 1;
    else if (!strcmp(argv[i], "--selftest")) selftest = 1;
    else { usage(); return 1; }
  }
  if (!host) { usage(); return 1; }

  if (fgets(A.pass, sizeof A.pass, stdin)) A.pass[strcspn(A.pass, "\r\n")] = 0;

  rfbClientLog = on_msg;
  rfbClientErr = on_msg;

  rfbClient *cl = rfbGetClient(8, 3, 4);
  if (!cl) return 3;
  A.cl = cl;
  cl->MallocFrameBuffer = malloc_fb;
  cl->GotFrameBufferUpdate = got_update;
  cl->GetPassword = get_password;
  cl->GetCredential = get_credential;
  cl->GotXCutTextUTF8 = got_cut_utf8;
  cl->GotXCutText = got_cut_latin1;
  cl->canHandleNewFBSize = TRUE;
  cl->appData.useRemoteCursor = FALSE;
  cl->appData.compressLevel = 3;
  cl->appData.qualityLevel = 8;
  cl->appData.encodingsString = "tight zrle ultra copyrect hextile zlib corre rre raw";
  cl->serverHost = strdup(host);
  cl->serverPort = port;

  /* Window first, so the first framebuffer allocation can create its texture. */
  if (!check) {
    SDL_SetHint(SDL_HINT_APP_ID, A.appid);
    SDL_SetAppMetadataProperty(SDL_PROP_APP_METADATA_IDENTIFIER_STRING, A.appid);
    if (!SDL_Init(SDL_INIT_VIDEO)) { fprintf(stderr, "SDL: %s\n", SDL_GetError()); return 3; }
    A.win = SDL_CreateWindow(A.title, 1280, 800, SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (!A.win) { fprintf(stderr, "window: %s\n", SDL_GetError()); return 3; }
    A.ren = SDL_CreateRenderer(A.win, NULL);
    if (!A.ren) { fprintf(stderr, "renderer: %s\n", SDL_GetError()); return 3; }
    SDL_SetRenderVSync(A.ren, 1);
    SDL_StartTextInput(A.win);
  }

  int dummy_argc = 0;
  if (!rfbInitClient(cl, &dummy_argc, NULL)) {
    /* rfbInitClient frees the client on failure */
    if (A.connect_failed) { fprintf(stderr, "could not connect to %s:%d\n", host, port); return 3; }
    if (A.auth_failed)    { fprintf(stderr, "login rejected\n"); return 2; }
    fprintf(stderr, "connection failed: %s\n", A.errlog[0] ? A.errlog : "unknown");
    return 3;
  }

  if (probe) {
    /* Ask for the size the server already has; harmless if honored, ignored if unsupported. */
    int w0 = cl->width, h0 = cl->height, resized = 0;
    printf("connected at %dx%d, sending SetDesktopSize(%d,%d)\n", w0, h0, w0, h0);
    SendExtDesktopSize(cl, (uint16_t)w0, (uint16_t)h0);
    for (int i = 0; i < 40; i++) {
      int n = WaitForMessage(cl, 50000);
      if (n > 0) { if (!HandleRFBServerMessage(cl)) break; }
      if (cl->width != w0 || cl->height != h0) resized = 1;
    }
    printf("after 2s: %dx%d, resize reply seen: %s, server screen id=%u flags=%u\n", cl->width, cl->height,
           resized ? "size changed" : "no size change", (unsigned)cl->screen.id, (unsigned)cl->screen.flags);
    rfbClientCleanup(cl); return 0;
  }
  if (check) { printf("OK %dx%d\n", cl->width, cl->height); rfbClientCleanup(cl); return 0; }

  SDL_Event ev;
  int running = 1, rc = 0;
  Uint64 start = SDL_GetTicks();
  int selftest_stage = 0;

  while (running) {
    while (SDL_WaitEventTimeout(&ev, 4)) {
      switch (ev.type) {
        case SDL_EVENT_QUIT:
        case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
          running = 0; break;
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
          apply_fit(); A.dirty = 1; break;
        case SDL_EVENT_WINDOW_EXPOSED:
          A.dirty = 1; break;
        case SDL_EVENT_MOUSE_MOTION:
          SDL_ConvertEventToRenderCoordinates(A.ren, &ev);
          A.mouse_x = (int)ev.motion.x; A.mouse_y = (int)ev.motion.y;
          send_pointer(); break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP: {
          SDL_ConvertEventToRenderCoordinates(A.ren, &ev);
          A.mouse_x = (int)ev.button.x; A.mouse_y = (int)ev.button.y;
          int bit = button_bit(ev.button.button);
          if (ev.type == SDL_EVENT_MOUSE_BUTTON_DOWN) A.button_mask |= bit; else A.button_mask &= ~bit;
          send_pointer(); break;
        }
        case SDL_EVENT_MOUSE_WHEEL: {
          int vy = (int)(ev.wheel.y < 0 ? ev.wheel.y - 0.5f : ev.wheel.y + 0.5f);
          int vx = (int)(ev.wheel.x < 0 ? ev.wheel.x - 0.5f : ev.wheel.x + 0.5f);
          if (vy == 0 && ev.wheel.y != 0) vy = ev.wheel.y > 0 ? 1 : -1;
          if (vx == 0 && ev.wheel.x != 0) vx = ev.wheel.x > 0 ? 1 : -1;
          if (vy > 0) scroll_ticks(1 << 3, vy);
          if (vy < 0) scroll_ticks(1 << 4, -vy);
          if (vx > 0) scroll_ticks(1 << 6, vx);
          if (vx < 0) scroll_ticks(1 << 5, -vx);
          break;
        }
        case SDL_EVENT_KEY_DOWN:
        case SDL_EVENT_KEY_UP:
          handle_key(&ev.key); break;
        case SDL_EVENT_TEXT_INPUT:
          handle_text(ev.text.text); break;
        case SDL_EVENT_CLIPBOARD_UPDATE:
          send_local_clipboard(); break;
        case SDL_EVENT_WINDOW_FOCUS_LOST:
          /* Release anything still held so nothing sticks on the Mac. */
          for (int s = 0; s < SDL_SCANCODE_COUNT; s++)
            if (A.held[s]) { SendKeyEvent(cl, A.held[s], FALSE); A.held[s] = 0; }
          break;
        default: break;
      }
    }

    int n = WaitForMessage(cl, 0);
    if (n < 0) { fprintf(stderr, "connection lost\n"); rc = 4; break; }
    if (n > 0 && !HandleRFBServerMessage(cl)) { fprintf(stderr, "connection lost\n"); rc = 4; break; }
    while (n > 0 && (n = WaitForMessage(cl, 0)) > 0)
      if (!HandleRFBServerMessage(cl)) { fprintf(stderr, "connection lost\n"); rc = 4; running = 0; break; }

    if (A.dirty) render();

    if (selftest && A.got_first_frame) {          /* synthetic input for automated checks */
      Uint64 t = SDL_GetTicks() - start;
      if (selftest_stage == 0 && t > 1500) { A.mouse_x = 50; A.mouse_y = 60; send_pointer(); A.button_mask = 1; send_pointer(); A.button_mask = 0; send_pointer(); selftest_stage = 1; }
      if (selftest_stage == 1 && t > 2000) { handle_text("hi \xC3\xA7"); SendKeyEvent(cl, XK_Return, TRUE); SendKeyEvent(cl, XK_Return, FALSE); selftest_stage = 2; }
      if (selftest_stage == 2 && t > 2500) { SDL_SetClipboardText("clip-from-viewer"); send_local_clipboard(); selftest_stage = 3; }
      if (selftest_stage == 3 && t > 4500) running = 0;
    }
  }

  if (A.tex) SDL_DestroyTexture(A.tex);
  if (A.ren) SDL_DestroyRenderer(A.ren);
  if (A.win) SDL_DestroyWindow(A.win);
  SDL_Quit();
  rfbClientCleanup(cl);
  return rc;
}
