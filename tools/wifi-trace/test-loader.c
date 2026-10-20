/* SPDX-License-Identifier: MIT */
/* Exercise serialization/readiness without root, BPF load, or attachment. */
#define BPF_OBJECT_PATH "wifi-trace.bpf.o"
#define CORE_BTF_PATH "target-core.btf"
#define main tracer_main
#include "wifi-trace.c"
#undef main
#include <assert.h>
#include <sys/time.h>

static void reset_output(void)
{
    stopping = 0; output_bytes = 0; userspace_discarded = 0;
    output_capped = false; io_failed = false; event_error = false; draining = false;
    stream_output = false;
}

int main(void)
{
    /* No PRNG is used. Read object metadata only; never bpf_object__load(). */
    assert(validate_core_btf(CORE_BTF_PATH));
    assert(!validate_core_btf("absent-core.btf"));
    struct bpf_object *obj = open_object();
    assert(obj && !libbpf_get_error(obj));
    unsigned int nprogs = 0;
    struct bpf_program *prog;
    bpf_object__for_each_program(prog, obj) nprogs++;
    assert(nprogs == EXPECTED_PROBES);
    assert(bpf_map__max_entries(bpf_object__find_map_by_name(obj, "events")) == 1U << 20);
    assert(bpf_map__max_entries(bpf_object__find_map_by_name(obj, "packets")) == 1024);
    assert(bpf_map__max_entries(bpf_object__find_map_by_name(obj, "windows")) == 8);
    assert(bpf_map__max_entries(bpf_object__find_map_by_name(obj, "tx_pending")) == 2);
    assert(bpf_map__max_entries(bpf_object__find_map_by_name(obj, "stats")) == STAT_COUNT);
    assert(bpf_map__max_entries(bpf_object__find_map_by_name(obj, "dma_pending")) == 1);
    assert(bpf_map__max_entries(bpf_object__find_map_by_name(obj, "pm_pending")) == 128);
    bpf_object__close(obj);

    assert(fflush(stdout) == 0);
    int original = dup(STDOUT_FILENO);
    assert(original >= 0);
    FILE *capture = fopen("serializer.jsonl", "w+");
    assert(capture && dup2(fileno(capture), STDOUT_FILENO) >= 0);
    assert(!stdout_is_pipe());
    struct trace_event e = {.stage = TX_DESCRIPTOR, .packet_id = 42, .key_present = 1};
    e.packet.message = 2; e.packet.decode = DECODE_KEY; e.packet.eapol_len = 130;
    e.txd[3] = 2; /* protected */
    e.txd[4] = 0xdeadbeef; e.txd[5] = 0xabcd1234; /* must be scrubbed by formatter */
    assert(event(NULL, &e, sizeof(e)) == 0 && !stopping);
    assert(fflush(stdout) == 0);
    long size = ftell(capture);
    assert(size > 0 && output_bytes == (unsigned long)size);
    output_bytes = OUTPUT_LIMIT - FOOTER_RESERVE - 1;
    assert(event(NULL, &e, sizeof(e)) == 1); /* interrupt a busy live ring */
    assert(output_capped && stopping && userspace_discarded == 1);
    draining = true;
    assert(event(NULL, &e, sizeof(e)) == 0 && userspace_discarded == 2);
    assert(fflush(stdout) == 0 && ftell(capture) == size); /* no partial line */
    assert(output(0, "{\"event\":\"test_footer\"}\n") == 1);
    assert(output_bytes <= OUTPUT_LIMIT);
    output_bytes = OUTPUT_LIMIT;
    assert(output(FOOTER_RESERVE, "{}\n") == 0); /* no unsigned underflow */
    assert(fflush(stdout) == 0);
    assert(dup2(original, STDOUT_FILENO) >= 0);
    close(original); fclose(capture);
    reset_output();
    event(NULL, &e, sizeof(e) - 1);
    assert(event_error && stopping && userspace_discarded == 1);
    reset_output();

    /* Pipe mode has no lifetime byte cutoff; the separate consumer owns
     * bounded rotation. Default direct-file mode above retains its cap. */
    int pipefd[2];
    assert(pipe(pipefd) == 0);
    original = dup(STDOUT_FILENO);
    assert(original >= 0 && dup2(pipefd[1], STDOUT_FILENO) >= 0);
    close(pipefd[1]);
    assert(stdout_is_pipe());
    stream_output = true; output_bytes = OUTPUT_LIMIT + 123;
    assert(output(FOOTER_RESERVE, "{}\n") == 1 && !stopping && !output_capped);
    assert(fflush(stdout) == 0);
    char stream_line[3];
    assert(read(pipefd[0], stream_line, sizeof(stream_line)) == 3);
    assert(!memcmp(stream_line, "{}\n", 3));
    assert(dup2(original, STDOUT_FILENO) >= 0);
    close(original); close(pipefd[0]);
    reset_output();

    assert(unsetenv("NOTIFY_SOCKET") == 0 && notify_ready() == 0);
    assert(setenv("NOTIFY_SOCKET", "not-an-absolute-socket", 1) == 0);
    assert(notify_ready() == -1 && errno == EINVAL);
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    assert(fd >= 0);
    struct timeval timeout = {.tv_sec = 2};
    assert(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    char cwd[sizeof(addr.sun_path)];
    assert(getcwd(cwd, sizeof(cwd)));
    int n = snprintf(addr.sun_path, sizeof(addr.sun_path), "%s/notify-test.sock", cwd);
    assert(n > 0 && (size_t)n < sizeof(addr.sun_path));
    assert(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(setenv("NOTIFY_SOCKET", addr.sun_path, 1) == 0 && notify_ready() == 0);
    char message[128] = {0};
    ssize_t got = recv(fd, message, sizeof(message) - 1, 0);
    assert(got > 0 && strstr(message, "READY=1") && strstr(message, "26 read-only probes"));
    close(fd); assert(unlink(addr.sun_path) == 0);

    /* Abstract sockets use a length-delimited name, not a trailing NUL. */
    fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    assert(fd >= 0);
    assert(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    char abstract[64];
    n = snprintf(abstract, sizeof(abstract), "@wifi-trace-test-%ld", (long)getpid());
    memset(&addr, 0, sizeof(addr)); addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, abstract, (size_t)n); addr.sun_path[0] = 0;
    assert(bind(fd, (struct sockaddr *)&addr,
                (socklen_t)(offsetof(struct sockaddr_un, sun_path) + (size_t)n)) == 0);
    assert(setenv("NOTIFY_SOCKET", abstract, 1) == 0 && notify_ready() == 0);
    got = recv(fd, message, sizeof(message) - 1, 0);
    assert(got > 0 && strstr(message, "READY=1"));
    close(fd); unsetenv("NOTIFY_SOCKET");
    puts("26-program object, bounded maps, JSON privacy/cap, ABI error and readiness socket checks passed");
    return 0;
}
