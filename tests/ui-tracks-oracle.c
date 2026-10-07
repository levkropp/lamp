/* Shipping Windows UI track menu, deferred preference handoff, preflight
   rollback, and per-file queue choices. This C harness is test-only. */
#include "lamp-test.h"
#define CHECK(x) do { if (!(x)) { printf("line %u: %s\n", __LINE__, #x); return 1; } } while (0)
LAMP_ABI void ui_tracks_menu_probe(HMENU);
LAMP_ABI void ui_choose_track_probe(unsigned);
LAMP_ABI void ui_track_apply_probe(void);
LAMP_ABI unsigned ui_track_for_file_probe(unsigned);
LAMP_ABI void ui_tracks_reset_probe(void);
LAMP_ABI void ui_track_opened_probe(void);
LAMP_ABI void ui_worker_capture_probe(void);
LAMP_ABI int decoder_open(const lamp_char *);
LAMP_ABI void decoder_close(void);
LAMP_ABI int queue_begin(const lamp_char **, unsigned);
LAMP_ABI unsigned queue_read(float *, unsigned);
LAMP_ABI void queue_select_track(unsigned);
extern const lamp_char **ui_test_paths, **queue_paths;
extern uint64_t ui_test_count, ui_thread, ui_test_start_ms;
extern uint64_t ui_test_worker_ms;
extern uint64_t ui_test_track_catalog[];
extern unsigned ui_test_track_choices[], ui_count, ui_test_start_index, ui_test_restart;
extern unsigned pause_requested, engine_ready, engine_stop_requested, queue_index;
extern int ui_test_track_pending, ui_test_track_menu_index;
extern unsigned ui_test_worker_index, ui_test_worker_chapter, ui_test_chapter_pending;
extern int ui_test_worker_track;
extern unsigned track_choice, audio_tracks_count, audio_track_selected, queue_failures;
extern unsigned queue_repeat;
extern unsigned (*queue_track_choice)(unsigned);

static HMENU menu(unsigned count, unsigned checked) {
    HMENU root = CreatePopupMenu();
    ui_tracks_menu_probe(root);
    HMENU sub = GetSubMenu(root, 0);
    if (!sub || GetMenuItemCount(sub) != (int)count) { DestroyMenu(root); return NULL; }
    for (unsigned i = 0; i < count; i++) {
        unsigned state = GetMenuState(sub, i, MF_BYPOSITION);
        if ((state & MF_CHECKED) != (i == checked ? MF_CHECKED : 0)) { DestroyMenu(root); return NULL; }
        wchar_t text[64];
        if (!GetMenuStringW(sub, i, text, 64, MF_BYPOSITION)) { DestroyMenu(root); return NULL; }
        if (i == 0 && wcscmp(text, L"Automatic")) { DestroyMenu(root); return NULL; }
        if (i > 0 && i <= 64) {
            wchar_t expected[32]; _snwprintf(expected, 32, L"Track %u", i);
            if (wcscmp(text, expected)) { DestroyMenu(root); return NULL; }
        }
        if (i == 65 && !(state & MF_GRAYED)) { DestroyMenu(root); return NULL; }
    }
    return root;
}

static unsigned char *reference(const lamp_char *a, const lamp_char *b, size_t *bytes) {
    FILE *first = lamp_fopen(a, LT("rb")), *second = lamp_fopen(b, LT("rb"));
    if (!first || !second) return NULL;
    fseek(first, 0, SEEK_END); size_t n = ftell(first); rewind(first);
    fseek(second, 0, SEEK_END); size_t m = ftell(second); rewind(second);
    unsigned char *pcm = malloc(n + m);
    if (!pcm || fread(pcm, 1, n, first) != n || fread(pcm + n, 1, m, second) != m) return NULL;
    fclose(first); fclose(second); *bytes = n + m; return pcm;
}

int lamp_main(int argc, lamp_char **argv) {
    if (argc != 6) return 2;
    const lamp_char *paths[] = {argv[1], argv[3]};
    ui_tracks_reset_probe();
    ui_test_paths = queue_paths = paths; ui_count = 2; ui_test_count = 0;
    queue_index = 0; track_choice = 0;
    CHECK(decoder_open(paths[0])); ui_track_opened_probe(); decoder_close();
    CHECK((unsigned)ui_test_track_catalog[0] == 3 && (unsigned)(ui_test_track_catalog[0] >> 32) == 1);
    engine_ready = 1; pause_requested = 1; ui_thread = 1;
    ui_test_start_index = 0; ui_test_start_ms = 1500;
    HMENU root = menu(4, 0); CHECK(root); DestroyMenu(root); ui_test_track_menu_index = -1;
    ui_choose_track_probe(2);
    CHECK(ui_test_track_pending == 0 && ui_test_start_index == 0 && ui_test_start_ms == 1500);
    CHECK(ui_test_track_choices[0] == 0 && pause_requested == 1 && ui_test_restart == 1);
    ui_thread = 0; ui_test_restart = 0; engine_stop_requested = 0;
    queue_track_choice = ui_track_for_file_probe;
    ui_worker_capture_probe();
    ui_track_apply_probe();
    CHECK(ui_test_track_pending == -1 && ui_test_track_choices[0] == 2 && ui_test_start_ms == 1500);
    CHECK(audio_tracks_count == 3 && audio_track_selected == 2 && pause_requested == 1);
    root = menu(4, 2); CHECK(root); DestroyMenu(root); ui_test_track_menu_index = -1;

    /* A track switch at 5 s into a known 2 s ALAC track cannot skip the file. */
    ui_test_track_choices[0] = 0; ui_test_start_ms = 5000; ui_thread = 1;
    ui_choose_track_probe(2); ui_thread = 0; ui_test_restart = 0; engine_stop_requested = 0;
    ui_worker_capture_probe();
    ui_track_apply_probe();
    CHECK(ui_test_worker_ms == 1999 && ui_test_start_ms == 5000 && ui_test_track_choices[0] == 2 && pause_requested == 1);

    /* A worker's captured seek/chapter/track request cannot consume or
       overwrite a replacement staged by the UI while it is running. */
    ui_test_start_index = 0; ui_test_start_ms = 1500; ui_test_chapter_pending = 6;
    ui_test_track_pending = 0; ui_worker_capture_probe();
    CHECK(ui_test_worker_index == 0 && ui_test_worker_ms == 1500 && ui_test_worker_chapter == 6);
    CHECK(ui_test_worker_track == 0 && ui_test_track_pending == -1 && !ui_test_chapter_pending);
    ui_test_start_index = 1; ui_test_start_ms = 350; ui_test_track_pending = 1; ui_test_chapter_pending = 7;
    ui_track_apply_probe();
    CHECK(ui_test_worker_index == 0 && ui_test_worker_ms == 1500 && ui_test_worker_chapter == 6);
    CHECK(ui_test_start_index == 1 && ui_test_start_ms == 350 && ui_test_track_pending == 1 && ui_test_chapter_pending == 7);
    ui_test_track_choices[0] = 0; ui_test_start_index = 0; ui_test_start_ms = 1500; ui_test_track_pending = 0;
    ui_worker_capture_probe();
    ui_test_start_index = 1; ui_test_start_ms = 350; ui_test_track_pending = 1;
    engine_stop_requested = 1; ui_track_apply_probe(); engine_stop_requested = 0;
    CHECK(ui_test_track_choices[0] == 0 && ui_test_worker_ms == 1500);
    CHECK(ui_test_start_index == 1 && ui_test_start_ms == 350 && ui_test_track_pending == 1);
    ui_test_start_index = 0; ui_test_track_pending = -1; ui_test_chapter_pending = 0;

    /* Unsupported WMA remains visible in the count, but failing it restores
       the preceding automatic choice and heard position. */
    paths[0] = argv[2]; ui_test_track_choices[0] = 0; track_choice = 0;
    CHECK(decoder_open(paths[0])); ui_track_opened_probe(); decoder_close();
    CHECK((unsigned)ui_test_track_catalog[0] == 2);
    ui_test_start_ms = 1500; ui_thread = 1;
    ui_choose_track_probe(2); ui_thread = 0; ui_test_restart = 0; engine_stop_requested = 0;
    ui_worker_capture_probe();
    ui_track_apply_probe();
    CHECK(ui_test_track_choices[0] == 0 && ui_test_start_ms == 1500 && pause_requested == 1);
    queue_select_track(0);
    CHECK(track_choice == 0 && decoder_open(paths[0]) && audio_track_selected == 1);
    decoder_close();

    /* A menu belongs to the file it named, even if playback advances before
       its command arrives. Also bound the menu independently of the count. */
    ui_test_track_catalog[0] = 70; ui_test_track_choices[0] = 0;
    root = menu(66, 0); CHECK(root); DestroyMenu(root);
    ui_test_track_catalog[1] = 2; ui_test_start_index = 1; ui_test_start_ms = 350; ui_thread = 1;
    ui_choose_track_probe(2);
    CHECK(ui_test_track_pending == -1 && ui_test_start_index == 1 && ui_test_start_ms == 350);
    ui_test_track_menu_index = -1; ui_choose_track_probe(65);
    CHECK(ui_test_track_pending == -1);
    ui_test_start_index = 0;
    root = menu(66, 0); CHECK(root); DestroyMenu(root);
    ui_tracks_reset_probe();            /* a new list's file 0 is not the held menu's file 0 */
    ui_test_track_catalog[0] = 2;
    ui_choose_track_probe(2);
    CHECK(ui_test_track_pending == -1 && ui_test_track_choices[0] == 0);
    ui_test_track_menu_index = -1;
    ui_thread = 0;
    CHECK(ui_track_for_file_probe(65536) == 0);

    /* Per-file choices apply on the real queue owner, including its lookahead
       opens: track 2 of MP4 followed by automatic single-track WAVE. */
    paths[0] = argv[1]; ui_test_track_choices[0] = 2; ui_test_track_choices[1] = 0;
    size_t bytes = 0; unsigned char *expected = reference(argv[4], argv[5], &bytes); CHECK(expected);
    queue_repeat = 1;
    CHECK(queue_begin(paths, 2));
    float buffer[4096 * 2]; size_t used = 0; unsigned n;
    while (used < bytes) {
        unsigned capacity = (bytes - used) / 8;
        if (capacity > 4096) capacity = 4096;
        n = queue_read(buffer, capacity); CHECK(n);
        CHECK(used + n * 8 <= bytes && !memcmp(expected + used, buffer, n * 8)); used += n * 8;
    }
    CHECK(used == bytes && !queue_failures && track_choice == 0 && audio_track_selected == 1);
    CHECK(queue_read(buffer, 64) == 64 && !memcmp(expected, buffer, 64 * 8));
    CHECK(track_choice == 2 && audio_track_selected == 2);
    queue_repeat = 0;
    decoder_close(); free(expected); queue_track_choice = NULL;
    ui_tracks_reset_probe();
    CHECK(ui_test_track_choices[0] == 0 && ui_test_track_catalog[0] == 0 && ui_test_track_pending == -1);
    printf("{\"menus\":4,\"menu_limit\":64,\"deferred_switch\":true,\"pause_preserved\":true,"
           "\"shorter_track_clamped_ms\":1999,\"unsupported_track_rollback\":true,"
           "\"menu_file_pairing\":true,\"menu_list_generation\":true,"
           "\"worker_request_isolation\":true,\"cancelled_switch_restores_choice\":true,"
           "\"queue_pcm\":\"exact\",\"queue_frames\":%llu,"
           "\"single_track_following_selected_track\":true,\"repeat_keeps_choice\":true,"
           "\"new_list_clears_choices\":true}\n",
           (unsigned long long)used / 8);
    return 0;
}
