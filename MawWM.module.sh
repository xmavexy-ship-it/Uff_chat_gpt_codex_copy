#!/usr/bin/env bash
set -euo pipefail

# MawWM Slax module builder
# Builds a stylish X11 Window Manager (MawWM) and packs it into one .sb module file.
# Usage:
#   chmod +x MawWM.module.sh
#   ./MawWM.module.sh
# Optional env:
#   VERSION=1.1.0 ARCH=x86_64 OUT_DIR=$PWD ./MawWM.module.sh

VERSION="${VERSION:-1.1.0}"
ARCH="${ARCH:-$(uname -m)}"
OUT_DIR="${OUT_DIR:-$PWD}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
ROOTFS="$WORK_DIR/rootfs"
SRC_DIR="$WORK_DIR/src"
MODULE_NAME="MawWM-${VERSION}-${ARCH}.sb"
MODULE_PATH="$OUT_DIR/$MODULE_NAME"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  }
}

need_cmd gcc
need_cmd mksquashfs
need_cmd pkg-config
need_cmd strip

if ! pkg-config --exists x11; then
  echo "[ERROR] X11 development package not found (pkg-config x11)." >&2
  echo "        On Slax/Debian install: apt install libx11-dev" >&2
  exit 1
fi

mkdir -p \
  "$ROOTFS/usr/bin" \
  "$ROOTFS/usr/share/xsessions" \
  "$ROOTFS/usr/share/doc/mawwm" \
  "$ROOTFS/etc/mawwm" \
  "$SRC_DIR"

cat > "$SRC_DIR/mawwm.c" <<'C_EOF'
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct Client Client;
struct Client {
    Window win;
    int x, y, w, h;
    int is_floating;
    Client *next;
};

static Display *dpy;
static Window root;
static int screen;
static unsigned int modkey = Mod1Mask; /* Alt */

static Client *clients = NULL;
static Client *focused = NULL;

static int sw, sh;
static int gap_px = 14;
static int border_px = 3;
static float master_ratio = 0.58f;
static int tiling_enabled = 1;

static unsigned long col_focus = 0;
static unsigned long col_normal = 0;

static int running = 1;

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
        fprintf(stderr, "MawWM: another window manager is already running.\n");
        exit(1);
    }
    return 0;
}

static Client *find_client(Window w) {
    for (Client *c = clients; c; c = c->next) if (c->win == w) return c;
    return NULL;
}

static void set_border(Client *c, int focused_state) {
    if (!c) return;
    XSetWindowBorderWidth(dpy, c->win, (unsigned int)border_px);
    XSetWindowBorder(dpy, c->win, focused_state ? col_focus : col_normal);
}

static void focus_client(Client *c) {
    if (!c) return;
    if (focused && focused != c) set_border(focused, 0);
    focused = c;
    set_border(c, 1);
    XRaiseWindow(dpy, c->win);
    XSetInputFocus(dpy, c->win, RevertToPointerRoot, CurrentTime);
}

static void arrange(void) {
    if (!tiling_enabled) return;

    int n = 0;
    for (Client *c = clients; c; c = c->next) if (!c->is_floating) n++;
    if (n == 0) return;

    int x = gap_px;
    int y = gap_px;
    int w = sw - 2 * gap_px;
    int h = sh - 2 * gap_px;

    if (n == 1) {
        for (Client *c = clients; c; c = c->next) {
            if (!c->is_floating) {
                c->x = x; c->y = y; c->w = w - 2 * border_px; c->h = h - 2 * border_px;
                XMoveResizeWindow(dpy, c->win, c->x, c->y, (unsigned int)c->w, (unsigned int)c->h);
            }
        }
        return;
    }

    int mw = (int)(w * master_ratio);
    int sx = x + mw + gap_px;
    int swd = w - mw - gap_px;

    Client *master = NULL;
    for (Client *c = clients; c; c = c->next) {
        if (!c->is_floating) { master = c; break; }
    }
    if (!master) return;

    master->x = x;
    master->y = y;
    master->w = mw - 2 * border_px;
    master->h = h - 2 * border_px;
    XMoveResizeWindow(dpy, master->win, master->x, master->y, (unsigned int)master->w, (unsigned int)master->h);

    int stack_n = n - 1;
    int each_h = (h - gap_px * (stack_n - 1)) / stack_n;
    int i = 0;
    for (Client *c = master->next; c; c = c->next) {
        if (c->is_floating) continue;
        c->x = sx;
        c->y = y + i * (each_h + gap_px);
        c->w = swd - 2 * border_px;
        c->h = each_h - 2 * border_px;
        if (c->h < 60) c->h = 60;
        XMoveResizeWindow(dpy, c->win, c->x, c->y, (unsigned int)c->w, (unsigned int)c->h);
        i++;
    }
}

static void manage(Window w) {
    XWindowAttributes wa;
    if (!XGetWindowAttributes(dpy, w, &wa) || wa.override_redirect || wa.map_state == IsUnmapped) return;
    if (find_client(w)) return;

    Client *c = calloc(1, sizeof(Client));
    if (!c) return;
    c->win = w;
    c->x = wa.x;
    c->y = wa.y;
    c->w = wa.width;
    c->h = wa.height;
    c->is_floating = 0;
    c->next = clients;
    clients = c;

    XSelectInput(dpy, w, EnterWindowMask | FocusChangeMask | PropertyChangeMask);
    set_border(c, 0);
    XMapWindow(dpy, w);
    focus_client(c);
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
    if (!focused && clients) focus_client(clients);
    arrange();
}

static void move_resize_drag(Client *c, XButtonEvent *start, int resize_mode) {
    if (!c || !start) return;

    XEvent ev;
    int sxr = start->x_root;
    int syr = start->y_root;
    int ox = c->x, oy = c->y, ow = c->w, oh = c->h;
    c->is_floating = 1;

    XGrabPointer(dpy, root, False,
                 PointerMotionMask | ButtonReleaseMask,
                 GrabModeAsync, GrabModeAsync,
                 None, None, CurrentTime);

    while (1) {
        XMaskEvent(dpy, PointerMotionMask | ButtonReleaseMask, &ev);
        if (ev.type == MotionNotify) {
            int dx = ev.xmotion.x_root - sxr;
            int dy = ev.xmotion.y_root - syr;
            if (resize_mode) {
                int nw = ow + dx;
                int nh = oh + dy;
                if (nw < 220) nw = 220;
                if (nh < 140) nh = 140;
                c->w = nw;
                c->h = nh;
                XResizeWindow(dpy, c->win, (unsigned int)c->w, (unsigned int)c->h);
            } else {
                c->x = ox + dx;
                c->y = oy + dy;
                XMoveWindow(dpy, c->win, c->x, c->y);
            }
        } else if (ev.type == ButtonRelease) {
            break;
        }
    }

    XUngrabPointer(dpy, CurrentTime);
}

static void kill_focused(void) {
    if (!focused) return;
    Atom *protocols = NULL;
    int n = 0;
    Atom wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    if (XGetWMProtocols(dpy, focused->win, &protocols, &n)) {
        for (int i = 0; i < n; i++) {
            if (protocols[i] == wm_delete) {
                XEvent ev = {0};
                ev.type = ClientMessage;
                ev.xclient.window = focused->win;
                ev.xclient.message_type = XInternAtom(dpy, "WM_PROTOCOLS", True);
                ev.xclient.format = 32;
                ev.xclient.data.l[0] = wm_delete;
                ev.xclient.data.l[1] = CurrentTime;
                XSendEvent(dpy, focused->win, False, NoEventMask, &ev);
                XFree(protocols);
                return;
            }
        }
        XFree(protocols);
    }
    XKillClient(dpy, focused->win);
}

static void focus_next(int dir) {
    if (!clients || !focused) {
        if (clients) focus_client(clients);
        return;
    }

    if (dir > 0) {
        if (focused->next) focus_client(focused->next);
        else focus_client(clients);
        return;
    }

    Client *prev = NULL;
    for (Client *c = clients; c && c != focused; c = c->next) prev = c;
    if (prev) {
        focus_client(prev);
        return;
    }
    Client *last = clients;
    while (last && last->next) last = last->next;
    if (last) focus_client(last);
}

static void grab_keys(void) {
    Window rw = root;
    XUngrabKey(dpy, AnyKey, AnyModifier, rw);

    struct {
        KeySym sym;
        unsigned int mod;
    } keys[] = {
        {XK_Return, modkey},          /* terminal */
        {XK_p, modkey},               /* launcher */
        {XK_b, modkey},               /* browser */
        {XK_j, modkey},               /* focus next */
        {XK_k, modkey},               /* focus prev */
        {XK_space, modkey},           /* toggle floating */
        {XK_t, modkey},               /* toggle tiling */
        {XK_h, modkey},               /* master ratio - */
        {XK_l, modkey},               /* master ratio + */
        {XK_F11, modkey},             /* raise focused */
        {XK_c, modkey | ShiftMask},   /* close */
        {XK_q, modkey | ShiftMask},   /* quit */
    };

    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
        KeyCode kc = XKeysymToKeycode(dpy, keys[i].sym);
        if (!kc) continue;
        XGrabKey(dpy, kc, keys[i].mod, rw, True, GrabModeAsync, GrabModeAsync);
        XGrabKey(dpy, kc, keys[i].mod | LockMask, rw, True, GrabModeAsync, GrabModeAsync);
    }

    XGrabButton(dpy, Button1, modkey, rw, True, ButtonPressMask, GrabModeAsync, GrabModeAsync, None, None);
    XGrabButton(dpy, Button3, modkey, rw, True, ButtonPressMask, GrabModeAsync, GrabModeAsync, None, None);
}

static void handle_key(XKeyEvent *e) {
    KeySym k = XLookupKeysym(e, 0);
    unsigned int st = e->state;

    if ((st & modkey) && !(st & ShiftMask) && k == XK_Return) {
        spawn("alacritty || kitty || xterm");
    } else if ((st & modkey) && !(st & ShiftMask) && k == XK_p) {
        spawn("rofi -show drun || dmenu_run");
    } else if ((st & modkey) && !(st & ShiftMask) && k == XK_b) {
        spawn("xdg-open https://duckduckgo.com >/dev/null 2>&1");
    } else if ((st & modkey) && !(st & ShiftMask) && k == XK_j) {
        focus_next(+1);
    } else if ((st & modkey) && !(st & ShiftMask) && k == XK_k) {
        focus_next(-1);
    } else if ((st & modkey) && !(st & ShiftMask) && k == XK_space) {
        if (focused) {
            focused->is_floating = !focused->is_floating;
            arrange();
        }
    } else if ((st & modkey) && !(st & ShiftMask) && k == XK_t) {
        tiling_enabled = !tiling_enabled;
        arrange();
    } else if ((st & modkey) && !(st & ShiftMask) && k == XK_h) {
        master_ratio -= 0.03f;
        if (master_ratio < 0.35f) master_ratio = 0.35f;
        arrange();
    } else if ((st & modkey) && !(st & ShiftMask) && k == XK_l) {
        master_ratio += 0.03f;
        if (master_ratio > 0.75f) master_ratio = 0.75f;
        arrange();
    } else if ((st & modkey) && !(st & ShiftMask) && k == XK_F11) {
        if (focused) XRaiseWindow(dpy, focused->win);
    } else if ((st & modkey) && (st & ShiftMask) && k == XK_c) {
        kill_focused();
    } else if ((st & modkey) && (st & ShiftMask) && k == XK_q) {
        running = 0;
    }
}

static unsigned long parse_color(const char *hex, const char *fallback) {
    XColor c;
    Colormap cm = DefaultColormap(dpy, screen);
    if (XParseColor(dpy, cm, hex, &c) && XAllocColor(dpy, cm, &c)) return c.pixel;
    if (XParseColor(dpy, cm, fallback, &c) && XAllocColor(dpy, cm, &c)) return c.pixel;
    return BlackPixel(dpy, screen);
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

    col_focus = parse_color("#ff79c6", "#ff5fa2");
    col_normal = parse_color("#44475a", "#3a3d4f");

    XSetWindowAttributes wa;
    wa.event_mask = SubstructureRedirectMask | SubstructureNotifyMask |
                    ButtonPressMask | PointerMotionMask | KeyPressMask;
    XChangeWindowAttributes(dpy, root, CWEventMask, &wa);

    XSetWindowBackground(dpy, root, parse_color("#1e1f2e", "#222222"));
    XClearWindow(dpy, root);

    grab_keys();

    Window r, p, *wins = NULL;
    unsigned int n = 0;
    if (XQueryTree(dpy, root, &r, &p, &wins, &n)) {
        for (unsigned int i = 0; i < n; ++i) manage(wins[i]);
        if (wins) XFree(wins);
    }

    fprintf(stderr,
        "MawWM 1.1 started (beautiful mode).\n"
        "Hotkeys:\n"
        "  Alt+Enter       terminal\n"
        "  Alt+P           app launcher (rofi/dmenu)\n"
        "  Alt+J/K         focus next/prev\n"
        "  Alt+Space       toggle floating\n"
        "  Alt+T           toggle tiling\n"
        "  Alt+H/L         adjust master area\n"
        "  Alt+Shift+C     close window\n"
        "  Alt+Shift+Q     quit MawWM\n"
        "Mouse:\n"
        "  Alt+LMB drag    move\n"
        "  Alt+RMB drag    resize\n");

    while (running) {
        XEvent ev;
        XNextEvent(dpy, &ev);

        switch (ev.type) {
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
                if (c) focus_client(c);
            } break;
            case ConfigureRequest: {
                XConfigureRequestEvent *e = &ev.xconfigurerequest;
                Client *c = find_client(e->window);
                if (c && !c->is_floating && tiling_enabled) {
                    arrange();
                } else {
                    XWindowChanges wc;
                    wc.x = e->x;
                    wc.y = e->y;
                    wc.width = e->width;
                    wc.height = e->height;
                    wc.border_width = border_px;
                    wc.sibling = e->above;
                    wc.stack_mode = e->detail;
                    XConfigureWindow(dpy, e->window, e->value_mask, &wc);
                    if (c) {
                        c->x = wc.x; c->y = wc.y; c->w = wc.width; c->h = wc.height;
                    }
                }
            } break;
            case ButtonPress: {
                Client *c = find_client(ev.xbutton.subwindow);
                if (!c) c = find_client(ev.xbutton.window);
                if (!c) break;
                focus_client(c);
                if ((ev.xbutton.state & modkey) && ev.xbutton.button == Button1)
                    move_resize_drag(c, &ev.xbutton, 0);
                else if ((ev.xbutton.state & modkey) && ev.xbutton.button == Button3)
                    move_resize_drag(c, &ev.xbutton, 1);
            } break;
            case KeyPress:
                handle_key(&ev.xkey);
                break;
            default:
                break;
        }
    }

    XCloseDisplay(dpy);
    return 0;
}
C_EOF

gcc -O2 -Wall -Wextra "$SRC_DIR/mawwm.c" -o "$ROOTFS/usr/bin/mawwm" $(pkg-config --cflags --libs x11)
strip "$ROOTFS/usr/bin/mawwm" || true

cat > "$ROOTFS/usr/bin/start-mawwm" <<'SH_EOF'
#!/usr/bin/env sh
# Session launcher for MawWM (styled)

# Deep theme background
if command -v xsetroot >/dev/null 2>&1; then
  xsetroot -solid "#1e1f2e"
fi

# Optional eye-candy components if installed on system
if command -v picom >/dev/null 2>&1; then
  picom --experimental-backends --config /dev/null >/dev/null 2>&1 &
fi

if command -v tint2 >/dev/null 2>&1; then
  tint2 >/dev/null 2>&1 &
fi

# Autostart helper apps (best-effort)
if command -v nm-applet >/dev/null 2>&1; then
  nm-applet >/dev/null 2>&1 &
fi

exec /usr/bin/mawwm
SH_EOF
chmod +x "$ROOTFS/usr/bin/start-mawwm"

cat > "$ROOTFS/usr/share/xsessions/mawwm.desktop" <<'DESK_EOF'
[Desktop Entry]
Name=MawWM
Comment=Stylish tiling + floating X11 Window Manager for Slax
Exec=/usr/bin/start-mawwm
TryExec=/usr/bin/mawwm
Type=Application
DesktopNames=MawWM
DESK_EOF

cat > "$ROOTFS/etc/mawwm/README.shortcuts" <<'TXT_EOF'
MawWM — shortcuts

Alt+Enter        Launch terminal
Alt+P            Launch app menu (rofi/dmenu)
Alt+J / Alt+K    Focus next/previous window
Alt+Space        Toggle floating for focused window
Alt+T            Toggle global tiling
Alt+H / Alt+L    Decrease/increase master ratio
Alt+F11          Raise focused window
Alt+Shift+C      Close focused window
Alt+Shift+Q      Exit MawWM

Mouse
Alt + Left drag  Move window
Alt + Right drag Resize window
TXT_EOF

cat > "$ROOTFS/usr/share/doc/mawwm/INSTALL.txt" <<'TXT_EOF'
Copy the .sb file to /slax/modules/ and reboot.
Then choose session "MawWM" from your display manager.
TXT_EOF

mksquashfs "$ROOTFS" "$MODULE_PATH" -comp xz -b 1048576 -Xdict-size 100% >/dev/null

echo "[OK] Beautiful MawWM module created: $MODULE_PATH"
echo "Install on Slax: copy to /slax/modules/ and reboot."
