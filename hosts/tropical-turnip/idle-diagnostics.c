#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <glob.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

#include "ext-idle-notify-v1-client-protocol.h"

/* Observe only: no input devices, surfaces, inhibitors, or power requests. */
static struct wl_seat *seat;
static struct ext_idle_notifier_v1 *notifier;

struct idle_watch {
    const char *name;
    bool idle;
};

static void idled(void *data, struct ext_idle_notification_v1 *notification) {
    (void)notification;
    struct idle_watch *watch = data;
    watch->idle = true;
    printf("idle-watch: %s idled\n", watch->name);
}

static void resumed(void *data, struct ext_idle_notification_v1 *notification) {
    (void)notification;
    struct idle_watch *watch = data;
    watch->idle = false;
    printf("idle-watch: %s resumed\n", watch->name);
}

static const struct ext_idle_notification_v1_listener idle_listener = {
    .idled = idled,
    .resumed = resumed,
};

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data;
    if (!seat && strcmp(interface, "wl_seat") == 0) {
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    } else if (!notifier && strcmp(interface, "ext_idle_notifier_v1") == 0 && version >= 2) {
        notifier = wl_registry_bind(registry, name, &ext_idle_notifier_v1_interface, 2);
    }
}

static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = global,
    .global_remove = global_remove,
};

static time_t monotonic_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        perror("idle-watch: clock_gettime");
        exit(EXIT_FAILURE);
    }
    return now.tv_sec;
}

/* Poll sysfs without waking the display; log only changes, including hotplug. */
static void log_dpms(void) {
    static char *previous;
    char *snapshot = NULL;
    size_t size = 0;
    FILE *out = open_memstream(&snapshot, &size);
    if (!out) {
        perror("idle-watch: open_memstream");
        exit(EXIT_FAILURE);
    }
    glob_t paths = {0};
    int result = glob("/sys/class/drm/card*-*/dpms", 0, NULL, &paths);
    if (result == 0) {
        for (size_t i = 0; i < paths.gl_pathc; ++i) {
            const char *path = paths.gl_pathv[i];
            char value[32];
            FILE *file = fopen(path, "r");
            if (file && fgets(value, sizeof(value), file)) {
                value[strcspn(value, "\r\n")] = '\0';
                fprintf(out, "%s=%s ", path, value);
            } else {
                fprintf(out, "%s=unreadable ", path);
            }
            if (file) fclose(file);
        }
    } else {
        fputs("unavailable", out);
    }
    globfree(&paths);
    if (fclose(out) != 0) {
        perror("idle-watch: snapshot");
        exit(EXIT_FAILURE);
    }
    if (!previous || strcmp(previous, snapshot) != 0) {
        printf("idle-watch: dpms %s\n", snapshot);
        free(previous);
        previous = snapshot;
    } else {
        free(snapshot);
    }
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        perror("idle-watch: wl_display_connect");
        return EXIT_FAILURE;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !seat || !notifier) {
        fputs("idle-watch: requires a seat and ext_idle_notifier_v1 version 2\n", stderr);
        wl_display_disconnect(display);
        return EXIT_FAILURE;
    }

    struct idle_watch normal = {.name = "inhibitor-aware"};
    struct idle_watch input = {.name = "input-only"};
    struct ext_idle_notification_v1 *normal_notification =
        ext_idle_notifier_v1_get_idle_notification(notifier, 30000, seat);
    struct ext_idle_notification_v1 *input_notification =
        ext_idle_notifier_v1_get_input_idle_notification(notifier, 30000, seat);
    ext_idle_notification_v1_add_listener(normal_notification, &idle_listener, &normal);
    ext_idle_notification_v1_add_listener(input_notification, &idle_listener, &input);
    puts("idle-watch: started; timeout=30s; dpms-poll=5s; heartbeat=60s; read-only");

    time_t next_dpms = 0, next_heartbeat = 0;
    for (;;) {
        /* Follow libwayland's prepare/read/cancel pattern; never block in dispatch. */
        while (wl_display_prepare_read(display) != 0) {
            if (wl_display_dispatch_pending(display) < 0) goto failed;
        }
        short events = POLLIN;
        if (wl_display_flush(display) < 0) {
            if (errno != EAGAIN) {
                wl_display_cancel_read(display);
                goto failed;
            }
            events |= POLLOUT;
        }
        struct pollfd fd = {.fd = wl_display_get_fd(display), .events = events};
        int result = poll(&fd, 1, 1000);
        if (result > 0 && (fd.revents & POLLIN)) {
            if (wl_display_read_events(display) < 0) goto failed;
        } else {
            wl_display_cancel_read(display);
        }
        if (result < 0 && errno != EINTR) goto failed;
        if (fd.revents & (POLLERR | POLLHUP | POLLNVAL)) goto failed;
        if (wl_display_dispatch_pending(display) < 0) goto failed;

        time_t now = monotonic_seconds();
        if (now >= next_dpms) {
            log_dpms();
            next_dpms = now + 5;
        }
        if (now >= next_heartbeat) {
            printf("idle-watch: heartbeat inhibitor-aware=%s input-only=%s\n",
                   normal.idle ? "idle" : "active", input.idle ? "idle" : "active");
            next_heartbeat = now + 60;
        }
    }

failed:
    fprintf(stderr, "idle-watch: Wayland connection failed (protocol-error=%d): %s\n",
            wl_display_get_error(display), strerror(errno));
    wl_display_disconnect(display);
    return EXIT_FAILURE;
}
