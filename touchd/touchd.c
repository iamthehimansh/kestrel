// touchd: reads touch commands on stdin and injects them as Linux multitouch
// (protocol B) events. It writes to the device's own touchscreen when it can
// (debuggable images). On locked "user" images such as the Google Play ones,
// SELinux blocks that, so it creates its own virtual touchscreen through
// /dev/uinput instead (the adb shell user is in the uhid group).
//
// Usage: touchd <screen_width> <screen_height> [/dev/input/eventN]
// Commands, one per line, coordinates in screen pixels:
//   down <slot> <x> <y>
//   move <slot> <x> <y>
//   up <slot>
//   reset            lift every slot
//   ping             replies "pong" (latency / liveness check)
// Replies "ready <device> <maxx> <maxy> <slots>" once it is ready.

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAX_SLOTS 10
#define BITS_PER_LONG (sizeof(long) * 8)
#define NLONGS(x) (((x) + BITS_PER_LONG - 1) / BITS_PER_LONG)

static int fd = -1;
static int screen_w, screen_h;
static struct input_absinfo abs_x, abs_y;
static int dev_slots = MAX_SLOTS;
static int tracking[MAX_SLOTS];
static int next_tracking_id = 1;
static int cur_slot = -1;

static int test_bit(int bit, const unsigned long *arr) {
    return (arr[bit / BITS_PER_LONG] >> (bit % BITS_PER_LONG)) & 1;
}

static int is_multitouch(int f) {
    unsigned long abs_bits[NLONGS(ABS_CNT)] = {0};
    if (ioctl(f, EVIOCGBIT(EV_ABS, sizeof(abs_bits)), abs_bits) < 0) return 0;
    return test_bit(ABS_MT_SLOT, abs_bits) && test_bit(ABS_MT_POSITION_X, abs_bits) &&
           test_bit(ABS_MT_POSITION_Y, abs_bits) && test_bit(ABS_MT_TRACKING_ID, abs_bits);
}

static int open_device(const char *path) {
    int f = open(path, O_RDWR | O_CLOEXEC);
    if (f < 0) return -1;
    if (!is_multitouch(f)) { close(f); return -1; }
    return f;
}

static int find_device(char *out, size_t outlen) {
    DIR *d = opendir("/dev/input");
    if (!d) return -1;
    struct dirent *e;
    int found = -1;
    // Pick the lowest-numbered multitouch device (the emulator's main display).
    int best = 1 << 30;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "event", 5) != 0) continue;
        int n = atoi(e->d_name + 5);
        char p[64];
        snprintf(p, sizeof p, "/dev/input/%s", e->d_name);
        int f = open_device(p);
        if (f < 0) continue;
        if (n < best) {
            if (found >= 0) close(found);
            found = f;
            best = n;
            snprintf(out, outlen, "%s", p);
        } else {
            close(f);
        }
    }
    closedir(d);
    return found;
}

static int uinput_created = 0;

static int abs_setup(int f, int code, int min, int max) {
    struct uinput_abs_setup a;
    memset(&a, 0, sizeof a);
    a.code = (unsigned short)code;
    a.absinfo.minimum = min;
    a.absinfo.maximum = max;
    return ioctl(f, UI_ABS_SETUP, &a);
}

// Creates a virtual direct-touch screen whose axes are the screen's pixels.
static int create_uinput(int w, int h, char *out, size_t outlen) {
    int f = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (f < 0) return -1;
    int ok = ioctl(f, UI_SET_EVBIT, EV_KEY) == 0 && ioctl(f, UI_SET_KEYBIT, BTN_TOUCH) == 0 &&
             ioctl(f, UI_SET_EVBIT, EV_ABS) == 0 && ioctl(f, UI_SET_PROPBIT, INPUT_PROP_DIRECT) == 0;
    int codes[] = {ABS_MT_SLOT, ABS_MT_TRACKING_ID, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_PRESSURE, ABS_MT_TOUCH_MAJOR};
    for (size_t i = 0; ok && i < sizeof codes / sizeof codes[0]; i++) ok = ioctl(f, UI_SET_ABSBIT, codes[i]) == 0;
    ok = ok && abs_setup(f, ABS_MT_SLOT, 0, MAX_SLOTS - 1) == 0 && abs_setup(f, ABS_MT_TRACKING_ID, 0, 65535) == 0 &&
         abs_setup(f, ABS_MT_POSITION_X, 0, w - 1) == 0 && abs_setup(f, ABS_MT_POSITION_Y, 0, h - 1) == 0 &&
         abs_setup(f, ABS_MT_PRESSURE, 0, 255) == 0 && abs_setup(f, ABS_MT_TOUCH_MAJOR, 0, 255) == 0;
    struct uinput_setup us;
    memset(&us, 0, sizeof us);
    us.id.bustype = BUS_VIRTUAL;
    us.id.vendor = 0x04e8;  // plausible input vendor (Samsung Electronics)
    us.id.product = 0xa001;
    us.id.version = 1;
    snprintf(us.name, sizeof us.name, "sec_touchscreen");
    ok = ok && ioctl(f, UI_DEV_SETUP, &us) == 0 && ioctl(f, UI_DEV_CREATE) == 0;
    if (!ok) { int e = errno; close(f); errno = e; return -1; }
    uinput_created = 1;
    abs_x.minimum = 0; abs_x.maximum = w - 1;
    abs_y.minimum = 0; abs_y.maximum = h - 1;
    snprintf(out, outlen, "uinput:sec_touchscreen");
    // Give Android's InputReader time to pick the new device up.
    usleep(400 * 1000);
    return f;
}

static void emit(int type, int code, int value) {
    struct input_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = (unsigned short)type;
    ev.code = (unsigned short)code;
    ev.value = value;
    if (write(fd, &ev, sizeof ev) != (ssize_t)sizeof ev) {
        fprintf(stderr, "touchd: write failed: %s\n", strerror(errno));
    }
}

static void syn(void) { emit(EV_SYN, SYN_REPORT, 0); }

static int scale(int v, int screen, const struct input_absinfo *a) {
    if (screen <= 1) return a->minimum;
    long range = (long)a->maximum - a->minimum;
    long s = a->minimum + (long)v * range / (screen - 1);
    if (s < a->minimum) s = a->minimum;
    if (s > a->maximum) s = a->maximum;
    return (int)s;
}

static int active_count(void) {
    int n = 0;
    for (int i = 0; i < MAX_SLOTS; i++) n += tracking[i] != 0;
    return n;
}

static void select_slot(int slot) {
    if (slot != cur_slot) { emit(EV_ABS, ABS_MT_SLOT, slot); cur_slot = slot; }
}

static void touch_down(int slot, int x, int y) {
    int was = active_count();
    select_slot(slot);
    if (tracking[slot]) emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
    tracking[slot] = next_tracking_id++;
    if (next_tracking_id > 65535) next_tracking_id = 1;
    emit(EV_ABS, ABS_MT_TRACKING_ID, tracking[slot]);
    emit(EV_ABS, ABS_MT_POSITION_X, scale(x, screen_w, &abs_x));
    emit(EV_ABS, ABS_MT_POSITION_Y, scale(y, screen_h, &abs_y));
    emit(EV_ABS, ABS_MT_PRESSURE, 50);
    emit(EV_ABS, ABS_MT_TOUCH_MAJOR, 5);
    if (was == 0) emit(EV_KEY, BTN_TOUCH, 1);
    syn();
}

static void touch_move(int slot, int x, int y) {
    if (!tracking[slot]) return;
    select_slot(slot);
    emit(EV_ABS, ABS_MT_POSITION_X, scale(x, screen_w, &abs_x));
    emit(EV_ABS, ABS_MT_POSITION_Y, scale(y, screen_h, &abs_y));
    syn();
}

static void touch_up(int slot) {
    if (!tracking[slot]) return;
    select_slot(slot);
    emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
    tracking[slot] = 0;
    if (active_count() == 0) emit(EV_KEY, BTN_TOUCH, 0);
    syn();
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: touchd <screen_width> <screen_height> [/dev/input/eventN]\n");
        return 2;
    }
    screen_w = atoi(argv[1]);
    screen_h = atoi(argv[2]);
    if (screen_w <= 0 || screen_h <= 0) { fprintf(stderr, "touchd: bad screen size\n"); return 2; }

    char dev[64] = {0};
    if (argc >= 4) {
        snprintf(dev, sizeof dev, "%s", argv[3]);
        fd = open_device(dev);
    } else {
        fd = find_device(dev, sizeof dev);
        if (fd < 0) {
            int first = errno;
            fd = create_uinput(screen_w, screen_h, dev, sizeof dev);
            if (fd < 0) {
                fprintf(stderr, "touchd: no writable multitouch device (%s) and /dev/uinput failed (%s)\n",
                        strerror(first), strerror(errno));
                return 1;
            }
        }
    }
    if (fd < 0) {
        fprintf(stderr, "touchd: cannot open %s (%s)\n", dev, strerror(errno));
        return 1;
    }
    if (!uinput_created) {
        if (ioctl(fd, EVIOCGABS(ABS_MT_POSITION_X), &abs_x) < 0 || ioctl(fd, EVIOCGABS(ABS_MT_POSITION_Y), &abs_y) < 0) {
            fprintf(stderr, "touchd: cannot read axis ranges: %s\n", strerror(errno));
            return 1;
        }
        struct input_absinfo slots;
        if (ioctl(fd, EVIOCGABS(ABS_MT_SLOT), &slots) == 0 && slots.maximum + 1 < MAX_SLOTS) dev_slots = slots.maximum + 1;
    }

    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("ready %s %d %d %d\n", dev, abs_x.maximum, abs_y.maximum, dev_slots);

    char line[128];
    while (fgets(line, sizeof line, stdin)) {
        char cmd[16];
        int slot = 0, x = 0, y = 0;
        int n = sscanf(line, "%15s %d %d %d", cmd, &slot, &x, &y);
        if (n < 1) continue;
        if (strcmp(cmd, "ping") == 0) { printf("pong\n"); continue; }
        if (strcmp(cmd, "reset") == 0) {
            for (int i = 0; i < MAX_SLOTS; i++) touch_up(i);
            continue;
        }
        if (n < 2 || slot < 0 || slot >= dev_slots) { fprintf(stderr, "touchd: bad command: %s", line); continue; }
        if (strcmp(cmd, "down") == 0 && n == 4) touch_down(slot, x, y);
        else if (strcmp(cmd, "move") == 0 && n == 4) touch_move(slot, x, y);
        else if (strcmp(cmd, "up") == 0) touch_up(slot);
        else fprintf(stderr, "touchd: bad command: %s", line);
    }
    for (int i = 0; i < MAX_SLOTS; i++) touch_up(i);
    if (uinput_created) ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    return 0;
}
