#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-1.2.0}"
ARCH="${ARCH:-$(uname -m)}"
OUT_DIR="${OUT_DIR:-$PWD/dist}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
ROOTFS="$WORK_DIR/rootfs"
SRC_DIR="$WORK_DIR/src"
MODULE_NAME="MawWM-${VERSION}-${ARCH}.sb"
MODULE_PATH="$OUT_DIR/$MODULE_NAME"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing required command: $1" >&2; exit 1; }
}

need_cmd gcc
need_cmd mksquashfs
need_cmd pkg-config
need_cmd strip

if ! pkg-config --exists x11; then
  echo "[ERROR] X11 development package not found (pkg-config x11)." >&2
  echo "        Install: apt install libx11-dev" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/share/xsessions" "$ROOTFS/usr/share/doc/mawwm" "$ROOTFS/etc/mawwm" "$SRC_DIR"

cat > "$SRC_DIR/mawwm.c" <<'C_EOF'
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/select.h>

typedef struct Client Client;
struct Client {
    Window win;
    int x, y, w, h;
    int floating;
    Client *next;
};

static Display *dpy;
static int screen;
static Window root;
static Window panel;
static Window menu;
static GC gc;

static Client *clients = NULL;
static Client *focused = NULL;

static int sw, sh;
static int panel_h = 36;
static int menu_w = 230;
static int menu_h = 170;
static int menu_open = 0;

static int gap = 12;
static int border = 2;
static float master = 0.58f;
static int tiling = 1;

static unsigned long col_bg, col_panel, col_panel2, col_border, col_text, col_text_dim, col_accent, col_accent2, col_accent3;

static int running = 1;

static unsigned long color(const char *hex, const char *fallback) {
    XColor c;
    Colormap cm = DefaultColormap(dpy, screen);
    if (XParseColor(dpy, cm, hex, &c) && XAllocColor(dpy, cm, &c)) return c.pixel;
    if (XParseColor(dpy, cm, fallback, &c) && XAllocColor(dpy, cm, &c)) return c.pixel;
    return BlackPixel(dpy, screen);
}

static void spawn(const char *cmd) {
    if (!cmd || !*cmd) return;
    if (fork() == 0) {
        if (dpy) close(ConnectionNumber(dpy));
        setsid();
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
}

static int xerror(Display *d, XErrorEvent *ee) {
    (void)d;
    if (ee->error_code == BadAccess) {
        fprintf(stderr, "MawWM: another WM is already running.\n");
        exit(1);
    }
    return 0;
}

static Client *find_client(Window w) {
    for (Client *c = clients; c; c = c->next) if (c->win == w) return c;
    return NULL;
}

static void set_border(Client *c, int active) {
    if (!c) return;
    XSetWindowBorderWidth(dpy, c->win, (unsigned int)border);
    XSetWindowBorder(dpy, c->win, active ? col_accent2 : col_border);
}

static void focus(Client *c) {
    if (!c) return;
    if (focused && focused != c) set_border(focused, 0);
    focused = c;
    set_border(c, 1);
    XRaiseWindow(dpy, c->win);
    XSetInputFocus(dpy, c->win, RevertToPointerRoot, CurrentTime);
}

static int desktop_h(void) { return sh - panel_h; }

static void draw_panel(void) {
    XSetForeground(dpy, gc, col_panel);
    XFillRectangle(dpy, panel, gc, 0, 0, (unsigned int)sw, (unsigned int)panel_h);

    XSetForeground(dpy, gc, col_border);
    XDrawLine(dpy, panel, gc, 0, 0, sw, 0);

    /* Start button */
    XSetForeground(dpy, gc, col_panel2);
    XFillRectangle(dpy, panel, gc, 8, 6, 84, 24);
    XSetForeground(dpy, gc, col_accent);
    XDrawRectangle(dpy, panel, gc, 8, 6, 84, 24);
    XDrawString(dpy, panel, gc, 20, 22, "MawWM", 5);

    /* User label */
    XSetForeground(dpy, gc, col_text_dim);
    XDrawString(dpy, panel, gc, sw - 190, 22, "user@mawwm", 10);

    /* Clock */
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    char clk[32] = {0};
    if (tm) strftime(clk, sizeof(clk), "%H:%M:%S", tm);
    XSetForeground(dpy, gc, col_text);
    XDrawString(dpy, panel, gc, sw - 80, 22, clk, (int)strlen(clk));

    XFlush(dpy);
}

static void draw_menu(void) {
    if (!menu_open) return;
    XSetForeground(dpy, gc, col_panel);
    XFillRectangle(dpy, menu, gc, 0, 0, menu_w, menu_h);
    XSetForeground(dpy, gc, col_border);
    XDrawRectangle(dpy, menu, gc, 0, 0, menu_w - 1, menu_h - 1);

    XSetForeground(dpy, gc, col_accent);
    XDrawString(dpy, menu, gc, 14, 22, "Applications", 12);

    XSetForeground(dpy, gc, col_text);
    XDrawString(dpy, menu, gc, 14, 52, "1) Terminal", 11);
    XDrawString(dpy, menu, gc, 14, 76, "2) Browser", 10);
    XDrawString(dpy, menu, gc, 14, 100, "3) Launcher", 11);
    XDrawString(dpy, menu, gc, 14, 124, "4) System monitor", 17);

    XSetForeground(dpy, gc, col_accent3);
    XDrawString(dpy, menu, gc, 14, 154, "5) Exit MawWM", 13);

    XFlush(dpy);
}

static void toggle_menu(void) {
    menu_open = !menu_open;
    if (menu_open) {
        XMoveWindow(dpy, menu, 8, sh - panel_h - menu_h - 4);
        XMapRaised(dpy, menu);
        draw_menu();
    } else {
        XUnmapWindow(dpy, menu);
    }
}

static void arrange(void) {
    if (!tiling) return;

    int n = 0;
    for (Client *c = clients; c; c = c->next) if (!c->floating) n++;
    if (!n) return;

    int x = gap, y = gap;
    int w = sw - 2 * gap;
    int h = desktop_h() - 2 * gap;

    if (n == 1) {
        for (Client *c = clients; c; c = c->next) if (!c->floating) {
            c->x = x; c->y = y; c->w = w - 2 * border; c->h = h - 2 * border;
            XMoveResizeWindow(dpy, c->win, c->x, c->y, (unsigned int)c->w, (unsigned int)c->h);
        }
        return;
    }

    int mw = (int)(w * master);
    int sx = x + mw + gap;
    int swd = w - mw - gap;

    Client *m = NULL;
    for (Client *c = clients; c; c = c->next) if (!c->floating) { m = c; break; }
    if (!m) return;

    m->x = x; m->y = y; m->w = mw - 2 * border; m->h = h - 2 * border;
    XMoveResizeWindow(dpy, m->win, m->x, m->y, (unsigned int)m->w, (unsigned int)m->h);

    int stack_n = n - 1;
    int each_h = (h - gap * (stack_n - 1)) / stack_n;
    int i = 0;
    for (Client *c = m->next; c; c = c->next) {
        if (c->floating) continue;
        c->x = sx;
        c->y = y + i * (each_h + gap);
        c->w = swd - 2 * border;
        c->h = each_h - 2 * border;
        if (c->h < 70) c->h = 70;
        XMoveResizeWindow(dpy, c->win, c->x, c->y, (unsigned int)c->w, (unsigned int)c->h);
        i++;
    }
}

static void manage(Window w) {
    if (w == panel || w == menu) return;
    XWindowAttributes wa;
    if (!XGetWindowAttributes(dpy, w, &wa) || wa.override_redirect) return;
    if (find_client(w)) return;

    Client *c = calloc(1, sizeof(Client));
    if (!c) return;
    c->win = w;
    c->x = wa.x; c->y = wa.y; c->w = wa.width; c->h = wa.height;
    c->floating = 0;
    c->next = clients;
    clients = c;

    XSelectInput(dpy, w, EnterWindowMask | FocusChangeMask | PropertyChangeMask);
    set_border(c, 0);
    XMapWindow(dpy, w);
    focus(c);
    arrange();
}

static void unmanage(Window w) {
    Client **pc = &clients;
    while (*pc) {
        if ((*pc)->win == w) {
            Client *dead = *pc;
            if (focused == dead) focused = NULL;
            *pc = dead->next;
            free(dead);
            break;
        }
        pc = &(*pc)->next;
    }
    if (!focused && clients) focus(clients);
    arrange();
}

static void drag(Client *c, XButtonEvent *s, int resize) {
    if (!c || !s) return;
    XEvent ev;
    int sx = s->x_root, sy = s->y_root;
    int ox = c->x, oy = c->y, ow = c->w, oh = c->h;
    c->floating = 1;

    XGrabPointer(dpy, root, False, PointerMotionMask | ButtonReleaseMask,
                 GrabModeAsync, GrabModeAsync, None, None, CurrentTime);
    while (1) {
        XMaskEvent(dpy, PointerMotionMask | ButtonReleaseMask, &ev);
        if (ev.type == MotionNotify) {
            int dx = ev.xmotion.x_root - sx;
            int dy = ev.xmotion.y_root - sy;
            if (resize) {
                c->w = ow + dx; if (c->w < 240) c->w = 240;
                c->h = oh + dy; if (c->h < 140) c->h = 140;
                if (c->y + c->h > desktop_h()) c->h = desktop_h() - c->y;
                XResizeWindow(dpy, c->win, (unsigned int)c->w, (unsigned int)c->h);
            } else {
                c->x = ox + dx; c->y = oy + dy;
                if (c->y < 0) c->y = 0;
                if (c->y + c->h > desktop_h()) c->y = desktop_h() - c->h;
                XMoveWindow(dpy, c->win, c->x, c->y);
            }
        } else if (ev.type == ButtonRelease) break;
    }
    XUngrabPointer(dpy, CurrentTime);
}

static void kill_focused(void) {
    if (!focused) return;
    Atom *protos = NULL;
    int n = 0;
    Atom del = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    if (XGetWMProtocols(dpy, focused->win, &protos, &n)) {
        for (int i = 0; i < n; i++) {
            if (protos[i] == del) {
                XEvent ev = {0};
                ev.type = ClientMessage;
                ev.xclient.window = focused->win;
                ev.xclient.message_type = XInternAtom(dpy, "WM_PROTOCOLS", True);
                ev.xclient.format = 32;
                ev.xclient.data.l[0] = del;
                ev.xclient.data.l[1] = CurrentTime;
                XSendEvent(dpy, focused->win, False, NoEventMask, &ev);
                XFree(protos);
                return;
            }
        }
        XFree(protos);
    }
    XKillClient(dpy, focused->win);
}

static void focus_cycle(int dir) {
    if (!clients) return;
    if (!focused) { focus(clients); return; }
    if (dir > 0) {
        if (focused->next) focus(focused->next);
        else focus(clients);
        return;
    }
    Client *prev = NULL;
    for (Client *c = clients; c && c != focused; c = c->next) prev = c;
    if (prev) { focus(prev); return; }
    Client *last = clients;
    while (last && last->next) last = last->next;
    if (last) focus(last);
}

static void grab_inputs(void) {
    XUngrabKey(dpy, AnyKey, AnyModifier, root);
    struct { KeySym k; unsigned int m; } keys[] = {
        {XK_Return, Mod1Mask}, {XK_p, Mod1Mask}, {XK_b, Mod1Mask},
        {XK_j, Mod1Mask}, {XK_k, Mod1Mask}, {XK_space, Mod1Mask},
        {XK_t, Mod1Mask}, {XK_h, Mod1Mask}, {XK_l, Mod1Mask},
        {XK_c, Mod1Mask | ShiftMask}, {XK_q, Mod1Mask | ShiftMask}
    };

    for (size_t i = 0; i < sizeof(keys)/sizeof(keys[0]); i++) {
        KeyCode kc = XKeysymToKeycode(dpy, keys[i].k);
        if (!kc) continue;
        XGrabKey(dpy, kc, keys[i].m, root, True, GrabModeAsync, GrabModeAsync);
        XGrabKey(dpy, kc, keys[i].m | LockMask, root, True, GrabModeAsync, GrabModeAsync);
    }

    XGrabButton(dpy, Button1, Mod1Mask, root, True, ButtonPressMask, GrabModeAsync, GrabModeAsync, None, None);
    XGrabButton(dpy, Button3, Mod1Mask, root, True, ButtonPressMask, GrabModeAsync, GrabModeAsync, None, None);
}

static void handle_key(XKeyEvent *e) {
    KeySym k = XLookupKeysym(e, 0);
    unsigned int st = e->state;

    if ((st & Mod1Mask) && !(st & ShiftMask) && k == XK_Return) spawn("alacritty || kitty || xterm");
    else if ((st & Mod1Mask) && !(st & ShiftMask) && k == XK_p) spawn("rofi -show drun || dmenu_run");
    else if ((st & Mod1Mask) && !(st & ShiftMask) && k == XK_b) spawn("xdg-open https://duckduckgo.com >/dev/null 2>&1");
    else if ((st & Mod1Mask) && !(st & ShiftMask) && k == XK_j) focus_cycle(+1);
    else if ((st & Mod1Mask) && !(st & ShiftMask) && k == XK_k) focus_cycle(-1);
    else if ((st & Mod1Mask) && !(st & ShiftMask) && k == XK_space) { if (focused) { focused->floating = !focused->floating; arrange(); } }
    else if ((st & Mod1Mask) && !(st & ShiftMask) && k == XK_t) { tiling = !tiling; arrange(); }
    else if ((st & Mod1Mask) && !(st & ShiftMask) && k == XK_h) { master -= 0.03f; if (master < 0.35f) master = 0.35f; arrange(); }
    else if ((st & Mod1Mask) && !(st & ShiftMask) && k == XK_l) { master += 0.03f; if (master > 0.75f) master = 0.75f; arrange(); }
    else if ((st & Mod1Mask) && (st & ShiftMask) && k == XK_c) kill_focused();
    else if ((st & Mod1Mask) && (st & ShiftMask) && k == XK_q) running = 0;
}

static int in_rect(int x, int y, int rx, int ry, int rw, int rh) {
    return x >= rx && y >= ry && x < rx + rw && y < ry + rh;
}

static void handle_menu_click(int y) {
    int item = -1;
    if (y >= 38 && y < 62) item = 1;
    else if (y >= 62 && y < 86) item = 2;
    else if (y >= 86 && y < 110) item = 3;
    else if (y >= 110 && y < 138) item = 4;
    else if (y >= 138 && y < 165) item = 5;

    if (item == 1) spawn("alacritty || kitty || xterm");
    else if (item == 2) spawn("xdg-open https://duckduckgo.com >/dev/null 2>&1");
    else if (item == 3) spawn("rofi -show drun || dmenu_run");
    else if (item == 4) spawn("alacritty -e htop || xterm -e top");
    else if (item == 5) running = 0;

    if (item != -1) toggle_menu();
}

int main(void) {
    signal(SIGCHLD, SIG_IGN);
    dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "MawWM: cannot open DISPLAY.\n");
        return 1;
    }
    XSetErrorHandler(xerror);

    screen = DefaultScreen(dpy);
    root = RootWindow(dpy, screen);
    sw = DisplayWidth(dpy, screen);
    sh = DisplayHeight(dpy, screen);

    col_bg = color("#0d0f14", "#111111");
    col_panel = color("#13161e", "#202020");
    col_panel2 = color("#1a1e2a", "#303030");
    col_border = color("#2a2f3f", "#3a3a3a");
    col_text = color("#c8d0e0", "#dddddd");
    col_text_dim = color("#5a6070", "#777777");
    col_accent = color("#5af0a0", "#66ddaa");
    col_accent2 = color("#4a9eff", "#66aaff");
    col_accent3 = color("#ff6b6b", "#ff6666");

    XSetWindowBackground(dpy, root, col_bg);
    XClearWindow(dpy, root);

    XSetWindowAttributes wa;
    wa.event_mask = SubstructureRedirectMask | SubstructureNotifyMask | ButtonPressMask | KeyPressMask | PointerMotionMask;
    XChangeWindowAttributes(dpy, root, CWEventMask, &wa);

    panel = XCreateSimpleWindow(dpy, root, 0, sh - panel_h, (unsigned int)sw, (unsigned int)panel_h, 0, col_border, col_panel);
    XSelectInput(dpy, panel, ExposureMask | ButtonPressMask);
    XMapRaised(dpy, panel);

    menu = XCreateSimpleWindow(dpy, root, 8, sh - panel_h - menu_h - 4, (unsigned int)menu_w, (unsigned int)menu_h, 1, col_border, col_panel);
    XSelectInput(dpy, menu, ExposureMask | ButtonPressMask);

    gc = XCreateGC(dpy, root, 0, NULL);
    XSetForeground(dpy, gc, col_text);

    grab_inputs();
    draw_panel();

    Window r, p, *wins = NULL;
    unsigned int n = 0;
    if (XQueryTree(dpy, root, &r, &p, &wins, &n)) {
        for (unsigned int i = 0; i < n; i++) manage(wins[i]);
        if (wins) XFree(wins);
    }

    fprintf(stderr,
      "MawWM 1.2 started\n"
      "UI: dark wallpaper + bottom panel + start menu + clock\n"
      "Keys: Alt+Enter Alt+P Alt+J/K Alt+Space Alt+T Alt+H/L Alt+Shift+C Alt+Shift+Q\n"
      "Mouse: Alt+LMB move, Alt+RMB resize\n");

    while (running) {
        fd_set fds;
        FD_ZERO(&fds);
        int xfd = ConnectionNumber(dpy);
        FD_SET(xfd, &fds);

        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;

        int sel = select(xfd + 1, &fds, NULL, NULL, &tv);
        if (sel == 0) {
            draw_panel();
            continue;
        }

        while (XPending(dpy)) {
            XEvent ev;
            XNextEvent(dpy, &ev);

            switch (ev.type) {
                case Expose:
                    if (ev.xexpose.window == panel) draw_panel();
                    else if (ev.xexpose.window == menu) draw_menu();
                    break;
                case MapRequest:
                    manage(ev.xmaprequest.window);
                    break;
                case DestroyNotify:
                    unmanage(ev.xdestroywindow.window);
                    break;
                case UnmapNotify:
                    unmanage(ev.xunmap.window);
                    break;
                case EnterNotify: {
                    Client *c = find_client(ev.xcrossing.window);
                    if (c) focus(c);
                } break;
                case ConfigureRequest: {
                    XConfigureRequestEvent *e = &ev.xconfigurerequest;
                    Client *c = find_client(e->window);
                    if (c && !c->floating && tiling) arrange();
                    else {
                        XWindowChanges wc;
                        wc.x = e->x; wc.y = e->y; wc.width = e->width; wc.height = e->height;
                        wc.border_width = border; wc.sibling = e->above; wc.stack_mode = e->detail;
                        XConfigureWindow(dpy, e->window, e->value_mask, &wc);
                        if (c) { c->x = wc.x; c->y = wc.y; c->w = wc.width; c->h = wc.height; }
                    }
                } break;
                case ButtonPress:
                    if (ev.xbutton.window == panel) {
                        if (in_rect(ev.xbutton.x, ev.xbutton.y, 8, 6, 84, 24)) toggle_menu();
                    } else if (ev.xbutton.window == menu) {
                        handle_menu_click(ev.xbutton.y);
                    } else {
                        if (menu_open) toggle_menu();
                        Client *c = find_client(ev.xbutton.subwindow);
                        if (!c) c = find_client(ev.xbutton.window);
                        if (!c) break;
                        focus(c);
                        if ((ev.xbutton.state & Mod1Mask) && ev.xbutton.button == Button1) drag(c, &ev.xbutton, 0);
                        else if ((ev.xbutton.state & Mod1Mask) && ev.xbutton.button == Button3) drag(c, &ev.xbutton, 1);
                    }
                    break;
                case KeyPress:
                    handle_key(&ev.xkey);
                    break;
                default:
                    break;
            }
        }
    }

    XFreeGC(dpy, gc);
    XCloseDisplay(dpy);
    return 0;
}
C_EOF

gcc -O2 -Wall -Wextra "$SRC_DIR/mawwm.c" -o "$ROOTFS/usr/bin/mawwm" $(pkg-config --cflags --libs x11)
strip "$ROOTFS/usr/bin/mawwm" || true

cat > "$ROOTFS/usr/bin/start-mawwm" <<'SH_EOF'
#!/usr/bin/env sh
if command -v xsetroot >/dev/null 2>&1; then
  xsetroot -solid "#0d0f14"
fi
exec /usr/bin/mawwm
SH_EOF
chmod +x "$ROOTFS/usr/bin/start-mawwm"

cat > "$ROOTFS/usr/share/xsessions/mawwm.desktop" <<'DESK_EOF'
[Desktop Entry]
Name=MawWM
Comment=Styled X11 Window Manager with panel, start menu and clock
Exec=/usr/bin/start-mawwm
TryExec=/usr/bin/mawwm
Type=Application
DesktopNames=MawWM
DESK_EOF

cat > "$ROOTFS/etc/mawwm/README.shortcuts" <<'TXT_EOF'
MawWM 1.2 shortcuts

Alt+Enter        Terminal
Alt+P            App launcher
Alt+B            Browser
Alt+J / Alt+K    Focus next/previous
Alt+Space        Toggle floating for focused window
Alt+T            Toggle tiling
Alt+H / Alt+L    Decrease/increase master ratio
Alt+Shift+C      Close focused window
Alt+Shift+Q      Exit MawWM

Mouse
Alt + Left drag  Move window
Alt + Right drag Resize window

Panel
Click "MawWM" on bottom panel to open start menu.
TXT_EOF

cat > "$ROOTFS/usr/share/doc/mawwm/INSTALL.txt" <<'TXT_EOF'
Copy generated .sb file to /slax/modules/ and reboot.
Then choose session "MawWM" in your display manager.
TXT_EOF

mksquashfs "$ROOTFS" "$MODULE_PATH" -comp xz -b 1048576 -Xdict-size 100% >/dev/null

echo "[OK] MawWM module created: $MODULE_PATH"
