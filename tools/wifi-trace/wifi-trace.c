/* SPDX-License-Identifier: MIT */
#define _POSIX_C_SOURCE 200809L
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include <bpf/btf.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>
#include "trace.h"
#include "identity.h"

#ifndef BPF_OBJECT_PATH
#error "Set BPF_OBJECT_PATH to the installed BPF object"
#endif
#ifndef CORE_BTF_PATH
#error "Set CORE_BTF_PATH to the identity-matched, packaged CO-RE BTF"
#endif
#define OUTPUT_LIMIT (16UL * 1024 * 1024)
#define FOOTER_RESERVE 4096UL
#define EXPECTED_PROBES 26U

static volatile sig_atomic_t stopping;
static unsigned long output_bytes, userspace_discarded;
static bool output_capped, io_failed, event_error, draining, stream_output;
static const char *names[] = {
    "unknown", "driver_rx", "mt76_rx", "mac80211_rx", "control_port",
    "control_result", "skb_free", "skb_consume", "regd_enter", "clc_enter",
    "regd_return", "resume_enter", "resume_return", "rx_descriptor",
    "window_open", "window_close", "window_limit", "tx_queue_enter",
    "tx_queue_result", "tx_descriptor", "tx_status", "dma_rx", "dma_limit",
    "pm_state", "pm_driver_enter", "pm_driver_return", "pm_firmware_enter",
    "pm_firmware_return", "suspend_enter", "suspend_return",
};
static const char *stat_names[] = {
    "ring_lost", "map_errors", "driver_eapol", "control_eapol", "nested_control",
    "tx_queue_enter", "tx_queue_result", "tx_descriptor", "tx_status",
    "tx_pairing_lost", "tx_decode_miss", "tx_descriptor_read_error",
    "windows_opened", "window_rx_seen", "window_rx_emitted", "window_rx_skipped",
    "window_race", "dma_seen", "dma_emitted", "dma_skipped", "dma_empty",
    "dma_read_error", "dma_pairing_lost", "pm_pairing_lost", "pm_calls",
};
_Static_assert(sizeof(stat_names) / sizeof(stat_names[0]) == STAT_COUNT, "stat ABI");
_Static_assert(sizeof(names) / sizeof(names[0]) == SUSPEND_RETURN + 1, "stage ABI");

static bool validate_identity(void)
{
    struct utsname uts;
    if (uname(&uts) || strcmp(uts.release, "7.2.8") || strcmp(uts.machine, "x86_64"))
        return false;
    for (size_t i = 0; i < sizeof(identity_notes) / sizeof(identity_notes[0]); i++) {
        const struct identity_note *n = &identity_notes[i];
        unsigned char buf[4096];
        if (n->len >= sizeof(buf)) return false;
        FILE *f = fopen(n->path, "rb");
        if (!f) return false;
        size_t got = fread(buf, 1, n->len + 1, f);
        bool good = !ferror(f) && got == n->len && !memcmp(buf, n->bytes, n->len);
        fclose(f);
        if (!good) return false;
    }
    return true;
}

/* Explicit, immutable CO-RE metadata avoids libbpf's CAP_SYS_ADMIN-only
 * module-BTF enumeration. Exact build identities remain mandatory. The build
 * checks every relocation against the full live-BTF reference, without loading
 * probes. No caller/environment override and no vmlinux-only fallback. */
static bool validate_core_btf(const char *path)
{
    struct btf *btf = btf__parse(path, NULL);
    if (!btf || libbpf_get_error(btf)) return false;
    const char *required[] = {"sk_buff", "mt76_dev", "mt76_phy", "mt76_queue",
        "mt76_rx_status", "ieee80211_rx_status", "ieee80211_tx_info",
        "mt792x_dev", "mt76_connac_pm"};
    bool good = true;
    for (size_t i = 0; i < sizeof(required) / sizeof(required[0]); i++)
        if (btf__find_by_name_kind(btf, required[i], BTF_KIND_STRUCT) <= 0) good = false;
    btf__free(btf);
    return good;
}
static struct bpf_object *open_object(void)
{
    const struct bpf_object_open_opts opts = {
        .sz = sizeof(opts), .btf_custom_path = CORE_BTF_PATH,
    };
    return bpf_object__open_file(BPF_OBJECT_PATH, &opts);
}
static void on_signal(int sig) { (void)sig; stopping = 1; }
static unsigned long long clock_ns(clockid_t id)
{
    struct timespec ts;
    if (clock_gettime(id, &ts)) { perror("clock_gettime"); exit(1); }
    return (unsigned long long)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}
static int libbpf_log(enum libbpf_print_level level, const char *fmt, va_list ap)
{
    if (level == LIBBPF_DEBUG) return 0;
    return vfprintf(stderr, fmt, ap);
}
/* Reserve room for loss counters/footer; never emit a partial JSON line to meet
 * the size cap. I/O failure can of course leave a partial external write. */
static int output(unsigned long reserve, const char *fmt, ...)
{
    char line[2048];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= sizeof(line)) {
        event_error = true; stopping = 1; return -1;
    }
    if (!stream_output && (reserve > OUTPUT_LIMIT || output_bytes > OUTPUT_LIMIT - reserve ||
        (unsigned long)n > OUTPUT_LIMIT - reserve - output_bytes)) {
        output_capped = true; stopping = 1; return 0;
    }
    if (fwrite(line, 1, (size_t)n, stdout) != (size_t)n) {
        io_failed = true; stopping = 1; return -1;
    }
    output_bytes += (unsigned int)n;
    return 1;
}
static int event(void *ctx, void *data, size_t size)
{
    (void)ctx;
    if (size != sizeof(struct trace_event)) {
        fprintf(stderr, "Unexpected event size: %zu\n", size);
        event_error = true; stopping = 1; userspace_discarded++; return draining ? 0 : 1;
    }
    if (output_capped || io_failed || event_error) {
        userspace_discarded++; return draining ? 0 : 1;
    }
    const struct trace_event *e = data;
    const struct packet_info *p = &e->packet;
    const char *stage = e->stage < sizeof(names) / sizeof(names[0]) ? names[e->stage] : "unknown";
    unsigned long long wall = clock_ns(CLOCK_REALTIME) - clock_ns(CLOCK_BOOTTIME) + e->time_ns;
    int ret = output(FOOTER_RESERVE,
        "{\"event\":\"%s\",\"epoch_ns\":%llu,\"boot_ns\":%llu,\"packet_id\":%llu,"
        "\"window_id\":%llu,\"cpu\":%u,\"message\":%u,\"replay\":%llu,\"key_info\":%u,"
        "\"decode\":%u,\"skb_len\":%u,\"linear_len\":%u,\"eapol_len\":%u,"
        "\"eapol_version\":%u,\"descriptor_type\":%u,\"rx_type\":%u,"
        "\"rxd\":[%u,%u,%u,%u,%u],\"header_valid\":%u,\"fc\":%u,\"seq_ctrl\":%u,"
        "\"qos_ctrl\":%u,\"ether_type\":%u,\"flags\":%u,\"result\":%d,"
        "\"key_present\":%u,\"txd\":[%u,%u,%u,%u,0,%u,%u,%u],\"phy_state\":%llu,\"free_location\":\"0x%llx\"}\n",
        stage, wall, (unsigned long long)e->time_ns, (unsigned long long)e->packet_id,
        (unsigned long long)p->window_id, e->cpu, p->message, (unsigned long long)p->replay,
        p->key_info, p->decode, p->skb_len, p->linear_len, p->eapol_len,
        p->eapol_version, p->descriptor_type, p->rx_type,
        p->rxd0, p->rxd1, p->rxd2, p->rxd3, p->rxd4, p->header_valid, p->fc,
        p->seq_ctrl, p->qos_ctrl, p->ether_type, e->flags, e->result,
        e->key_present, e->txd[0], e->txd[1], e->txd[2], e->txd[3],
        e->txd[5] & 0xffff, e->txd[6], e->txd[7], (unsigned long long)e->phy_state,
        (unsigned long long)e->location);
    if (ret <= 0) userspace_discarded++;
    /* Break a busy live ring promptly on stop/error/cap. After detaching every
     * producer, drain the finite remainder to account for discarded records. */
    return stopping && !draining ? 1 : 0;
}

static bool print_stats(struct bpf_object *obj)
{
    int ncpu = libbpf_num_possible_cpus();
    int fd = bpf_object__find_map_fd_by_name(obj, "stats");
    if (ncpu <= 0 || fd < 0) return false;
    __u64 *values = calloc((size_t)ncpu, sizeof(*values));
    if (!values) { perror("stats allocation"); return false; }
    bool complete = true;
    for (__u32 k = 0; k < STAT_COUNT; k++) {
        if (bpf_map_lookup_elem(fd, &k, values)) {
            perror("reading BPF statistics"); complete = false; break;
        }
        unsigned long long sum = 0;
        for (int i = 0; i < ncpu; i++) sum += values[i];
        if (output(0, "{\"stat\":\"%s\",\"value\":%llu}\n", stat_names[k], sum) <= 0) {
            complete = false; break;
        }
    }
    free(values);
    return complete;
}

struct probe_health { unsigned long long missed; unsigned int reported; };
static struct probe_health probe_health(struct bpf_link **links, unsigned int nlinks)
{
    struct probe_health health = {0};
    for (unsigned int i = 0; i < nlinks; i++) {
        struct bpf_link_info info = {0};
        __u32 len = sizeof(info);
        int fd = bpf_link__fd(links[i]);
        if (fd < 0 || bpf_link_get_info_by_fd(fd, &info, &len)) continue;
        if (info.type == BPF_LINK_TYPE_PERF_EVENT &&
            (info.perf_event.type == BPF_PERF_EVENT_KPROBE ||
             info.perf_event.type == BPF_PERF_EVENT_KRETPROBE)) {
            health.missed += info.perf_event.kprobe.missed;
            health.reported++;
        }
    }
    return health;
}

static bool stats_checkpoint(struct bpf_object *obj, struct probe_health health, bool final)
{
    if (output(0, "{\"event\":\"stats_begin\",\"boot_ns\":%llu,\"final\":%s}\n",
               clock_ns(CLOCK_BOOTTIME), final ? "true" : "false") <= 0) return false;
    bool complete = print_stats(obj);
    if (output(0, "{\"event\":\"stats_end\",\"boot_ns\":%llu,\"stats_complete\":%s,"
                  "\"probe_missed_snapshot\":%llu,\"probe_missed_reported\":%u,"
                  "\"probe_missed_complete\":%s}\n", clock_ns(CLOCK_BOOTTIME),
               complete ? "true" : "false", health.missed, health.reported,
               health.reported == EXPECTED_PROBES - 2 ? "true" : "false") <= 0) return false;
    return complete;
}

static bool stdout_is_pipe(void)
{
    struct stat st;
    return !fstat(STDOUT_FILENO, &st) && S_ISFIFO(st.st_mode);
}

/* No libsystemd dependency. Type=notify makes systemd-run wait until EVERY probe
 * is attached, so a following necessary PCI rebind can also calibrate the trace.
 * Absent NOTIFY_SOCKET is a normal foreground invocation. */
static int notify_ready(void)
{
    const char *path = getenv("NOTIFY_SOCKET");
    if (!path) return 0;
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    size_t n = strlen(path);
    if (n < 2 || n >= sizeof(addr.sun_path) || (path[0] != '/' && path[0] != '@')) {
        errno = EINVAL; return -1;
    }
    memcpy(addr.sun_path, path, n + 1);
    bool abstract = path[0] == '@';
    if (abstract) addr.sun_path[0] = 0;
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    const char message[] = "READY=1\nSTATUS=Attached 26 read-only probes; calibration still required";
    ssize_t sent = sendto(fd, message, sizeof(message) - 1, MSG_NOSIGNAL,
                          (const struct sockaddr *)&addr,
                          (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n + !abstract));
    int saved = errno;
    close(fd);
    errno = saved;
    return sent == (ssize_t)sizeof(message) - 1 ? 0 : -1;
}

int main(int argc, char **argv)
{
    unsigned long seconds = 0;
    if (argc == 2 && !strcmp(argv[1], "--check")) {
        bool good = validate_identity() && validate_core_btf(CORE_BTF_PATH);
        puts(good ? "Exact x86-64/7.2.8 kernel and seven module identities match; packaged CO-RE BTF readable; no probes attached."
                  : "Kernel/module identity mismatch or CO-RE BTF unavailable; no probes attached.");
        return good ? 0 : 1;
    }
    if (argc == 2 && !strcmp(argv[1], "--help")) {
        puts("Usage: wifi-trace [--check | --seconds N | --stream]\n"
             "Read-only MT7922/Linux 7.2.8 probes; format-3 JSONL to stdout.\n"
             "Requires root, exact build identities, packaged BTF and kprobes. No network changes.\n"
             "8-second RX windows: up to 4096 DMA and 256 rx_check descriptors.\n"
             "No service time limit by default (--seconds 0); positive N sets a limit.\n"
             "Default: stops on Ctrl-C, an optional time limit, or 16 MiB total output.\n"
             "--stream: pipe-only, no cumulative cap; bounded consumer required.\n"
             "Detach before unloading Wi-Fi modules; keep output private.\n"
             "Use the bounded host-capture bundle; see its README for calibration.");
        return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "--stream")) {
        if (!stdout_is_pipe()) {
            fprintf(stderr, "--stream requires a pipe to the bounded recorder; no file fallback.\n"); return 2;
        }
        stream_output = true;
    } else if (argc != 1) {
        char *end = NULL;
        if (argc != 3 || strcmp(argv[1], "--seconds")) {
            fprintf(stderr, "Use --help for usage.\n"); return 2;
        }
        errno = 0;
        seconds = strtoul(argv[2], &end, 10);
        if (errno || end == argv[2] || *end || seconds > UINT_MAX) {
            fprintf(stderr, "--seconds must be between 0 and %u (0 disables the timer).\n", UINT_MAX); return 2;
        }
    }
    if (geteuid() != 0) {
        fprintf(stderr, "Root is required to attach BPF probes; nothing was attached.\n"); return 1;
    }
    if (!validate_identity()) {
        fprintf(stderr, "Exact kernel/module identity guard failed; nothing attached.\n"); return 1;
    }
    if (!validate_core_btf(CORE_BTF_PATH)) {
        fprintf(stderr, "Packaged CO-RE BTF unavailable; nothing attached.\n"); return 1;
    }
    libbpf_set_print(libbpf_log);
    struct bpf_object *obj = open_object();
    if (!obj || libbpf_get_error(obj)) { fprintf(stderr, "Cannot open BPF object.\n"); return 1; }
    struct bpf_link *links[32] = {};
    unsigned int nlinks = 0;
    struct ring_buffer *rb = NULL;
    bool attached = false;
    int rc = 1;
    if (bpf_object__load(obj)) goto out;
    int fd = bpf_object__find_map_fd_by_name(obj, "events");
    rb = ring_buffer__new(fd, event, NULL, NULL);
    if (!rb) { perror("ring buffer"); goto out; }
    struct sigaction sa = {.sa_handler = on_signal};
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL); sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stdout, NULL, _IOLBF, 0);
    struct bpf_program *prog;
    bpf_object__for_each_program(prog, obj) {
        if (nlinks == sizeof(links) / sizeof(links[0])) goto out;
        struct bpf_link *link = bpf_program__attach(prog);
        if (!link || libbpf_get_error(link)) {
            fprintf(stderr, "Attach failed: %s; detaching all probes.\n", bpf_program__name(prog));
            goto out;
        }
        links[nlinks++] = link;
    }
    if (nlinks != EXPECTED_PROBES || stopping) goto out;
    attached = true;
    fprintf(stderr, "Attached %u read-only probes. No connection changes.\n", nlinks);
    if (output(FOOTER_RESERVE,
        "{\"event\":\"started\",\"format\":%u,\"kernel\":\"7.2.8\",\"probes\":%u,"
        "\"seconds\":%lu,\"stream\":%s,\"rx_window_ns\":%llu,\"rx_window_max\":%u,\"dma_window_max\":%u}\n",
        TRACE_FORMAT, nlinks, seconds, stream_output ? "true" : "false", RX_WINDOW_NS, RX_WINDOW_MAX, DMA_WINDOW_MAX) <= 0 || fflush(stdout)) goto out;
    if (stream_output && !stats_checkpoint(obj, probe_health(links, nlinks), false)) goto out;
    if (notify_ready()) { perror("readiness notification"); goto out; }
    unsigned long long started = clock_ns(CLOCK_BOOTTIME), last_stats = started;
    rc = 0;
    while (!stopping && (!seconds || (clock_ns(CLOCK_BOOTTIME) - started) / 1000000000ULL < seconds)) {
        int ret = ring_buffer__poll(rb, 250);
        if (ret < 0 && ret != -EINTR) {
            fprintf(stderr, "ring_buffer__poll: %s\n", strerror(-ret)); rc = 1; break;
        }
        if (ferror(stdout)) { io_failed = true; rc = 1; break; }
        unsigned long long now = clock_ns(CLOCK_BOOTTIME);
        if (stream_output && now - last_stats >= 30000000000ULL) {
            if (!stats_checkpoint(obj, probe_health(links, nlinks), false) || fflush(stdout)) {
                rc = 1; break;
            }
            last_stats = now;
        }
    }
out:;
    /* Best available kernel missed-probe snapshot immediately before detach.
     * Missing support is reported, never silently interpreted as zero loss. */
    struct probe_health health = probe_health(links, nlinks);
    for (unsigned int i = 0; i < nlinks; i++) bpf_link__destroy(links[i]);
    if (rb && attached) {
        draining = true;
        int ret = ring_buffer__consume(rb);
        if (ret < 0) rc = 1;
        bool complete = stream_output ? stats_checkpoint(obj, health, true) : print_stats(obj);
        if (!complete || io_failed || event_error) rc = 1;
        output(0, "{\"event\":\"stopped\",\"output_limit\":%s,\"stats_complete\":%s,"
                  "\"userspace_discarded\":%lu,\"probe_missed_snapshot\":%llu,"
                  "\"probe_missed_reported\":%u,\"probe_missed_complete\":%s,\"error\":%s}\n",
               output_capped ? "true" : "false", complete ? "true" : "false",
               userspace_discarded, health.missed, health.reported,
               health.reported == EXPECTED_PROBES - 2 ? "true" : "false", rc ? "true" : "false");
        fprintf(stderr, "All probes detached.\n");
    }
    ring_buffer__free(rb);
    bpf_object__close(obj);
    if (fflush(stdout) || ferror(stdout) || io_failed || event_error) rc = 1;
    return rc;
}
