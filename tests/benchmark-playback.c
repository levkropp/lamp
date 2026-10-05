/* Test-only command bridge to the assembly WASAPI engine and Win32 counters.
 * This executable uses the C runtime; it is never linked into either player. */
#include "lamp-test.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

LAMP_ABI int engine_play(const wchar_t *);
LAMP_ABI void engine_stop(void);
LAMP_ABI void engine_pause(void);
extern volatile uint32_t engine_stop_requested, pause_requested, engine_ready;
extern volatile uint32_t sample_rate, exit_code, decode_error, engine_seek_seconds;
extern volatile uint64_t engine_position, underruns, endpoint_dry;
extern float engine_volume;

static HANDLE playback_thread;
static wchar_t input_path[32768];
static volatile DWORD playback_result;

static uint64_t ticks(FILETIME ft) {
    return ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
}

static DWORD WINAPI play(void *unused) {
    (void)unused;
    playback_result = engine_play(input_path);
    return playback_result;
}

static int stop(void) {
    if (!playback_thread) return 1;
    engine_stop();
    if (WaitForSingleObject(playback_thread, 10000) != WAIT_OBJECT_0) return 0;
    CloseHandle(playback_thread);
    playback_thread = NULL;
    return 1;
}

static void sample(HANDLE process) {
    FILETIME creation, end, kernel, user, idle, system_kernel, system_user;
    PROCESS_MEMORY_COUNTERS_EX memory = {0};
    LARGE_INTEGER now, frequency;
    memory.cb = sizeof(memory);
    if (!GetProcessTimes(process, &creation, &end, &kernel, &user) ||
        !GetProcessMemoryInfo(process, (PROCESS_MEMORY_COUNTERS *)&memory, sizeof(memory)) ||
        !GetSystemTimes(&idle, &system_kernel, &system_user) ||
        !QueryPerformanceCounter(&now) || !QueryPerformanceFrequency(&frequency)) {
        printf("{\"error\":\"counter query failed\",\"win32\":%lu}\n", GetLastError());
        return;
    }
    printf("{\"cpu_100ns\":%llu,\"working_set_bytes\":%llu,\"private_bytes\":%llu,"
           "\"system_idle_100ns\":%llu,\"system_kernel_100ns\":%llu,\"system_user_100ns\":%llu,"
           "\"qpc\":%llu,\"qpc_frequency\":%llu}\n",
           ticks(kernel) + ticks(user), (uint64_t)memory.WorkingSetSize,
           (uint64_t)memory.PrivateUsage, ticks(idle), ticks(system_kernel), ticks(system_user),
           (uint64_t)now.QuadPart, (uint64_t)frequency.QuadPart);
}

int main(int argc, char **argv) {
    char line[131072];
    HANDLE process = GetCurrentProcess();
    int monitor = argc == 3 && !strcmp(argv[1], "--monitor");
    if (monitor) {
        char *tail;
        unsigned long pid = strtoul(argv[2], &tail, 10);
        if (*tail || !pid) return 2;
        process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
        if (!process) return 3;
    } else if (argc != 1) return 2;
    engine_volume = 0.0f; /* Decode nonzero fixtures without emitting loud noise. */
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("{\"bridge_ready\":true,\"pid\":%lu,\"monitor\":%s}\n", GetCurrentProcessId(), monitor ? "true" : "false");
    while (fgets(line, sizeof(line), stdin)) {
        size_t length = strlen(line);
        if (!length || line[length - 1] != '\n') return 4;
        line[--length] = 0;
        if (length && line[length - 1] == '\r') line[--length] = 0;
        if (!strcmp(line, "sample")) sample(process);
        else if (!strcmp(line, "quit")) break;
        else if (monitor) printf("{\"error\":\"monitor accepts sample or quit\"}\n");
        else if (!strcmp(line, "state")) {
            int alive = playback_thread && WaitForSingleObject(playback_thread, 0) == WAIT_TIMEOUT;
            printf("{\"alive\":%s,\"ready\":%s,\"pause_requested\":%s,\"position_frames\":%llu,"
                   "\"sample_rate\":%lu,\"exit_code\":%lu,\"decode_error\":%lu,\"thread_result\":%lu,"
                   "\"underruns\":%llu,\"endpoint_dry\":%llu}\n",
                   alive ? "true" : "false", engine_ready ? "true" : "false", pause_requested ? "true" : "false",
                   engine_position, sample_rate, exit_code, decode_error, playback_result, underruns, endpoint_dry);
        } else if (!strcmp(line, "pause")) {
            engine_pause();
            printf("{\"pause_requested\":%s}\n", pause_requested ? "true" : "false");
        } else if (!strcmp(line, "stop")) {
            if (!stop()) return 5;
            printf("{\"stopped\":true,\"thread_result\":%lu}\n", playback_result);
        } else if (!strncmp(line, "open ", 5)) {
            char *after_seconds, *after_pause = NULL;
            uint64_t seconds = strtoull(line + 5, &after_seconds, 10);
            unsigned long pause = *after_seconds == ' ' ? strtoul(after_seconds + 1, &after_pause, 10) : 2;
            wchar_t next_path[32768];
            if (after_seconds == line + 5 || *after_seconds != ' ' || pause > 1 || seconds > 86400 ||
                after_pause == after_seconds + 1 || *after_pause != ' ' || !after_pause[1] ||
                !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, after_pause + 1, -1,
                                     next_path, (int)(sizeof(next_path) / sizeof(*next_path)))) {
                printf("{\"error\":\"invalid open command\"}\n");
                continue;
            }
            /* One engine at a time. Join the old worker before resetting globals. */
            if (!stop()) return 5;
            wcscpy_s(input_path, sizeof(input_path) / sizeof(*input_path), next_path);
            engine_stop_requested = 0;
            pause_requested = pause;
            engine_ready = 0;
            engine_position = 0;
            engine_seek_seconds = (uint32_t)seconds;
            playback_result = 0;
            playback_thread = CreateThread(NULL, 0, play, NULL, 0, NULL);
            if (!playback_thread) return 6;
            printf("{\"opened\":true}\n");
        } else printf("{\"error\":\"unknown command\"}\n");
    }
    if (!monitor && !stop()) return 5;
    if (monitor) CloseHandle(process);
    return 0;
}
