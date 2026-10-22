/* wintool — tiny X11 helper for Claude Monitor (Linux).
 *   wintool list            print "<window id>\t<title>" for every top-level client window
 *   wintool activate <id>   switch to that window's workspace, un-minimize, raise and focus it
 * Build: gcc -O2 -o wintool wintool.c -lX11
 */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static Display *dpy;

static unsigned char *prop(Window w, const char *name, Atom type, unsigned long *n) {
  Atom actual; int fmt; unsigned long after; unsigned char *data = NULL;
  *n = 0;
  if (XGetWindowProperty(dpy, w, XInternAtom(dpy, name, False), 0, 1 << 20, False, type,
                         &actual, &fmt, n, &after, &data) != Success || !data) return NULL;
  return data;
}

static void client_msg(Window w, const char *type, long d0, long d1, long d2) {
  XEvent e; memset(&e, 0, sizeof e);
  e.xclient.type = ClientMessage;
  e.xclient.window = w;
  e.xclient.message_type = XInternAtom(dpy, type, False);
  e.xclient.format = 32;
  e.xclient.data.l[0] = d0; e.xclient.data.l[1] = d1; e.xclient.data.l[2] = d2;
  XSendEvent(dpy, DefaultRootWindow(dpy), False, SubstructureRedirectMask | SubstructureNotifyMask, &e);
}

int main(int argc, char **argv) {
  if (argc < 2 || !(dpy = XOpenDisplay(NULL))) return 2;
  Window root = DefaultRootWindow(dpy);

  if (!strcmp(argv[1], "list")) {
    unsigned long n;
    Window *wins = (Window *)prop(root, "_NET_CLIENT_LIST", XA_WINDOW, &n);
    for (unsigned long i = 0; wins && i < n; i++) {
      unsigned long len;
      unsigned char *t = prop(wins[i], "_NET_WM_NAME", XInternAtom(dpy, "UTF8_STRING", False), &len);
      if (!t) t = prop(wins[i], "WM_NAME", AnyPropertyType, &len);
      printf("0x%lx\t%s\n", wins[i], t ? (char *)t : "");
      if (t) XFree(t);
    }
    if (wins) XFree(wins);
  } else if (!strcmp(argv[1], "activate") && argc > 2) {
    Window w = strtoul(argv[2], NULL, 0);
    unsigned long n;
    long *desk = (long *)prop(w, "_NET_WM_DESKTOP", XA_CARDINAL, &n);
    if (desk && n && *desk >= 0) client_msg(root, "_NET_CURRENT_DESKTOP", *desk, CurrentTime, 0);
    if (desk) XFree(desk);
    XEvent e; memset(&e, 0, sizeof e);   /* _NET_ACTIVE_WINDOW goes to the window itself */
    e.xclient.type = ClientMessage; e.xclient.window = w; e.xclient.format = 32;
    e.xclient.message_type = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
    e.xclient.data.l[0] = 2;             /* source: pager, so the WM honours the request */
    e.xclient.data.l[1] = CurrentTime;
    XSendEvent(dpy, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &e);
    XMapRaised(dpy, w);
  } else return 2;

  XFlush(dpy);
  XCloseDisplay(dpy);
  return 0;
}
